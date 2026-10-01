#!/usr/bin/env python3
"""Cheap sanitized mesh monitor snapshot.

This is a manager-side utility for checking bridge/worker state without waking
the worker. It reads only bridge health and message counts/ids, never message
bodies or token values.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


SAFE_LANE_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")


def validate_lane(value: str) -> str:
    if not SAFE_LANE_PATTERN.fullmatch(value):
        raise ValueError("worker lane must contain only letters, numbers, dot, underscore, or hyphen")
    return value


def fetch_bridge_json(base: str, path: str, token: str, timeout: int = 8) -> dict:
    request = Request(
        f"{base.rstrip('/')}{path}",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except HTTPError as exc:
        return {"ok": False, "status": exc.code}
    except (URLError, TimeoutError):
        return {"ok": False, "status": None}


def message_ids(payload: dict) -> list[int]:
    ids = []
    for item in payload.get("messages", []) or []:
        try:
            ids.append(int(item["id"]))
        except (KeyError, TypeError, ValueError):
            continue
    return ids


def messages_from(payload: dict, sender: str) -> list[dict]:
    return [
        item
        for item in payload.get("messages", []) or []
        if item.get("frm") == sender
    ]


def status_ops_metrics(payload: dict) -> dict:
    metrics = payload.get("ops_metrics") if isinstance(payload, dict) else {}
    return metrics if isinstance(metrics, dict) else {}


def stale_workers(metrics: dict) -> list[str]:
    heartbeats = metrics.get("worker_heartbeats") if isinstance(metrics, dict) else {}
    if not isinstance(heartbeats, dict):
        return []
    stale = []
    for worker, heartbeat in heartbeats.items():
        if not isinstance(heartbeat, dict):
            continue
        if heartbeat.get("stale") is True or heartbeat.get("state") == "stale":
            stale.append(str(worker))
    return sorted(stale)


def queue_depth_by_lane(metrics: dict) -> dict[str, int]:
    depths = metrics.get("queue_depth_by_lane") if isinstance(metrics, dict) else {}
    if not isinstance(depths, dict):
        return {}
    normalized: dict[str, int] = {}
    for lane, value in depths.items():
        try:
            normalized[str(lane)] = max(0, int(value))
        except (TypeError, ValueError):
            continue
    return normalized


def dead_letter_count(metrics: dict) -> int:
    dead_letters = metrics.get("dead_letters") if isinstance(metrics, dict) else {}
    if not isinstance(dead_letters, dict):
        return 0
    try:
        return max(0, int(dead_letters.get("count", 0)))
    except (TypeError, ValueError):
        return 0


def fetch_optional_status(fetch_json, token: str) -> dict:
    try:
        payload = fetch_json("/status", token)
    except (KeyError, TypeError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}


def build_snapshot(
    *,
    base: str,
    token: str,
    worker: str,
    since_worker: int,
    since_manager: int,
    fetch_json=None,
    queue_saturation_threshold: int = 5,
) -> dict:
    worker = validate_lane(worker)
    if fetch_json is None:
        fetch_json = lambda path, token: fetch_bridge_json(base, path, token)

    health = fetch_json("/health", token)
    if not health.get("ok"):
        return {
            "ok": False,
            "bridge_health": "down",
            "bridge_time": health.get("time"),
            "classification": "bridge_unhealthy",
            "recommended_action": "check_pi_bridge_before_worker",
        }

    status_payload = fetch_optional_status(fetch_json, token)
    metrics = status_ops_metrics(status_payload)
    dead_letters = dead_letter_count(metrics)
    stale = stale_workers(metrics)
    queue_depths = queue_depth_by_lane(metrics)

    worker_path = f"/messages?to={worker}&since={int(since_worker)}"
    manager_path = f"/messages?to=codex&since={int(since_manager)}"
    worker_payload = fetch_json(worker_path, token)
    manager_payload = fetch_json(manager_path, token)

    worker_ids = message_ids(worker_payload)
    worker_reply_payload = {"messages": messages_from(manager_payload, worker)}
    manager_ids = message_ids(worker_reply_payload)
    all_manager_ids = message_ids(manager_payload)
    non_worker_notification_count = max(0, len(all_manager_ids) - len(manager_ids))
    if dead_letters:
        classification = "dead_letters_present"
        recommended_action = "review_dead_letter_lane"
    elif stale:
        classification = "worker_stale"
        recommended_action = "inspect_worker_heartbeat_before_reping"
    elif queue_depths and max(queue_depths.values()) >= int(queue_saturation_threshold):
        classification = "queue_saturated"
        recommended_action = "pause_new_work_and_drain_queue"
    elif manager_ids:
        classification = "worker_replied"
        recommended_action = "review_worker_reply"
    elif worker_ids:
        classification = "worker_pending_no_reply"
        recommended_action = "do_not_reping_until_worker_or_operator_changes"
    else:
        classification = "healthy_idle"
        recommended_action = "wait_for_actionable_event"

    return {
        "ok": True,
        "bridge_health": "ok",
        "bridge_time": health.get("time"),
        "worker": worker,
        "classification": classification,
        "recommended_action": recommended_action,
        "pending_worker_count": len(worker_ids),
        "pending_worker_ids": worker_ids[-20:],
        "latest_worker_message_id": worker_ids[-1] if worker_ids else None,
        "manager_reply_count": len(manager_ids),
        "manager_reply_ids": manager_ids[-20:],
        "latest_manager_reply_id": manager_ids[-1] if manager_ids else None,
        "non_worker_notification_count": non_worker_notification_count,
        "dead_letter_count": dead_letters,
        "stale_workers": stale,
        "queue_depth_by_lane": queue_depths,
        "ops_status_observed": bool(metrics),
    }


def sanitize_for_output(payload: dict) -> dict:
    return {key: value for key, value in payload.items() if key not in {"token", "authorization", "raw", "messages"}}


def print_json(payload: dict) -> None:
    print(json.dumps(sanitize_for_output(payload), indent=2, sort_keys=True))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Emit a sanitized mesh monitor snapshot.")
    parser.add_argument("--base", required=True, help="Bridge base URL.")
    parser.add_argument("--token-file", type=Path, required=True, help="Manager token file.")
    parser.add_argument("--worker", default="claude", help="Worker lane to inspect.")
    parser.add_argument("--since-worker", type=int, default=0, help="High-water mark for worker-directed messages.")
    parser.add_argument("--since-manager", type=int, default=0, help="High-water mark for Codex-directed replies.")
    args = parser.parse_args(argv)

    token = args.token_file.read_text(encoding="utf-8").strip()
    result = build_snapshot(
        base=args.base,
        token=token,
        worker=args.worker,
        since_worker=args.since_worker,
        since_manager=args.since_manager,
    )
    print_json(result)
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

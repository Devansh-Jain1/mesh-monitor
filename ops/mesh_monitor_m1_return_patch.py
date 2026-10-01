#!/usr/bin/env python3
"""Prepare a pinned M1 receiver patch; no services or remote/device operations.

The default is a read-only dry run including the diff. --apply writes only the
explicit --target after saving a timestamped backup and rollback manifest.
Rollback also defaults to dry run: --target FILE --rollback MANIFEST [--apply].
This helper does not deploy or restart the receiver.

The marker uses its explicit IANA time_zone. pi_addresses must contain explicit
IP literals. The request proves authenticated Pi transport and the button-client
payload shape, not hardware attestation: software on that Pi with its bearer
token could construct the same request. A pending transition recovered after a
receiver restart deliberately loses return_origin; that recovery cannot trigger
a morning brief. Existing completed receipts retain their original provenance.
While a valid current-date arm is active, an unverified short return stays Dark.
No valid active arm retains the receiver's original short-press behavior.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from datetime import datetime, timezone
import uuid


EXPECTED_SOURCE_SHA256 = "17e55eec24f08c65abf97c31973a8823c3a6b65456756f31599be4db804f9e44"
PATCH_ID = "mesh-monitor-m1-return-v1"
MAX_SOURCE_BYTES = 1024 * 1024

# Keep the patch self-contained: applying it does not create a runtime import or
# change the station's service definition, bearer token, existing mode handlers,
# or GETs. The added desktop mode uses the existing display/privacy primitives.
HELPER = '''# BEGIN mesh-monitor-m1-return-v1
# MESH_MONITOR_RETURN_HOOK_V1
def _mesh_monitor_return_arm() -> dict[str, object] | None:
    """Load the complete dated arm independently of untrusted event fields."""
    import ipaddress
    import math
    import stat
    import uuid
    from datetime import date, datetime
    from zoneinfo import ZoneInfo

    def timestamp(value: object) -> bool:
        return type(value) in (int, float) and math.isfinite(value)

    def canonical_uuid(value: object) -> bool:
        return isinstance(value, str) and str(uuid.UUID(value)) == value.lower()

    try:
        now = time.time()
        marker = Path.home() / ".config/mesh-monitor/morning-return.json"
        # A private, regular, bounded local marker is the only arm authority.
        with os.fdopen(os.open(marker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as handle:
            info = os.fstat(handle.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size > 8192):
                return None
            raw = handle.read(8193)
        if len(raw) > 8192:
            return None
        arm = json.loads(raw)
        if not isinstance(arm, dict) or type(arm.get("schema_version")) is not int or arm["schema_version"] != 1:
            return None
        if arm.get("armed") is not True or arm.get("pi_name") != "raspberrypi":
            return None
        if not canonical_uuid(arm.get("session_id")):
            return None
        intended_date = arm.get("intended_date")
        if not isinstance(intended_date, str) or date.fromisoformat(intended_date).isoformat() != intended_date:
            return None
        time_zone = arm.get("time_zone")
        if not isinstance(time_zone, str) or len(time_zone) > 100:
            return None
        if intended_date != datetime.fromtimestamp(now, ZoneInfo(time_zone)).date().isoformat():
            return None
        created_at, expires_at = arm.get("created_at"), arm.get("expires_at")
        if not timestamp(created_at) or not timestamp(expires_at):
            return None
        if not created_at <= now < expires_at:
            return None
        addresses = arm.get("pi_addresses")
        if not isinstance(addresses, list) or not 1 <= len(addresses) <= 16:
            return None
        if any(not isinstance(address, str) or "%" in address for address in addresses):
            return None
        for address in addresses:
            ipaddress.ip_address(address)
        return arm
    except (OSError, ValueError, TypeError, OverflowError, AttributeError, KeyError):
        return None


def _mesh_monitor_return_origin(
    payload: object,
    peer_ip: object,
    *,
    authenticated: bool = False,
    arm: dict[str, object] | None = None,
) -> dict[str, object] | None:
    """Attribute only a fresh authenticated Pi short press under the current arm."""
    import ipaddress
    import math
    import uuid

    try:
        if authenticated is not True or not isinstance(payload, dict):
            return None
        if arm is None:
            arm = _mesh_monitor_return_arm()
        if arm is None or payload.get("action") != "toggle" or payload.get("pi") != arm["pi_name"]:
            return None
        pi = payload["pi"]
        event_id = payload.get("event_id")
        prefix = pi + "-"
        if not isinstance(event_id, str) or not event_id.startswith(prefix):
            return None
        event_uuid = event_id[len(prefix):]
        parsed_uuid = uuid.UUID(event_uuid)
        if str(parsed_uuid) != event_uuid.lower() or parsed_uuid.version != 4:
            return None
        if not isinstance(peer_ip, str) or "%" in peer_ip:
            return None
        peer = ipaddress.ip_address(peer_ip)
        now = time.time()
        detected_at, sent_at = payload.get("detected_at"), payload.get("sent_at")
        if any(type(value) not in (int, float) or not math.isfinite(value) for value in (detected_at, sent_at)):
            return None
        if not now - 30 <= detected_at <= sent_at <= now:
            return None
        if not arm["created_at"] <= detected_at <= now < arm["expires_at"]:
            return None
        allowed = {ipaddress.ip_address(address) for address in arm["pi_addresses"]}
        if peer not in allowed:
            return None
        return {
            "authenticated": True,
            "physical_pi": True,
            "peer_ip": str(peer),
            "pi": pi,
            "detected_at": detected_at,
            "sent_at": sent_at,
            "previous_mode": "dark",
            "monitor_session_id": arm["session_id"],
        }
    except (ValueError, TypeError, OverflowError, AttributeError, KeyError):
        return None
# END mesh-monitor-m1-return-v1


'''


REPLACEMENTS = (
    ("class Station:\n", HELPER + "class Station:\n"),
    (
        '    MODES = {"camera", "hud", "dark"}\n',
        '    MODES = {"camera", "hud", "dark", "desktop"}\n',
    ),
    (
        '            "hud": hud and not camera and not blackout,\n',
        '            "hud": hud and not camera and not blackout,\n'
        '            "desktop": not camera and not hud and not blackout,\n',
    ),
    (
        '            "hud": self._display_hud,\n',
        '            "hud": self._display_hud,\n'
        '            "desktop": self._display_desktop,\n',
    ),
    (
        '    def _display_dark(self) -> None:\n',
        '    def _display_desktop(self) -> None:\n'
        '        self._ensure_keep_awake()\n'
        '        self._ensure_blackout()\n'
        '        self._stop_station_camera_apps()\n'
        '        self._stop_hud()\n'
        '        try:\n'
        '            self._ensure_external_primary()\n'
        '            self._stop_blackout()\n'
        '        except Exception:\n'
        '            self._ensure_blackout()\n'
        '            raise\n'
        '\n'
        '    def _display_dark(self) -> None:\n',
    ),
    (
        '        requested_action: str = "toggle",\n    ) -> dict[str, object]:\n',
        '        requested_action: str = "toggle",\n'
        '        *,\n'
        '        monitor_request: object = None,\n'
        '        monitor_peer_ip: object = None,\n'
        '        monitor_authenticated: bool = False,\n'
        '    ) -> dict[str, object]:\n',
    ),
    (
        '            if requested_action == "toggle":\n'
        '                target_mode = "dark" if self.mode in {"camera", "hud"} else "camera"\n',
        '            return_origin = None\n'
        '            monitor_arm = (_mesh_monitor_return_arm()\n'
        '                           if requested_action == "toggle" and self.mode == "dark" else None)\n'
        '            if (monitor_arm is not None\n'
        '                    and isinstance(monitor_request, dict)\n'
        '                    and monitor_request.get("event_id") == event_id\n'
        '                    and monitor_request.get("detected_at") == detected_at):\n'
        '                return_origin = _mesh_monitor_return_origin(\n'
        '                    monitor_request, monitor_peer_ip,\n'
        '                    authenticated=monitor_authenticated, arm=monitor_arm,\n'
        '                )\n'
        '            if monitor_arm is not None and return_origin is None:\n'
        '                try:\n'
        '                    if not self._private_cover_converged():\n'
        '                        self._ensure_private_cover()\n'
        '                except Exception:\n'
        '                    result = {"ok": False, "event_id": event_id,\n'
        '                              "error": "monitor_return_privacy_reconcile_failed"}\n'
        '                else:\n'
        '                    result = {"ok": True, "ignored": True,\n'
        '                              "reason": "monitor_return_origin_unverified",\n'
        '                              "event_id": event_id, "active": False, "mode": "dark",\n'
        '                              "requested_action": requested_action}\n'
        '                result = self._finalize_button_receipt(\n'
        '                    event_id, action_digest, requested_action, "dark", False, result,\n'
        '                )\n'
        '                self._log("button_ignored" if result.get("ok") else "button_error", **result)\n'
        '                return result\n'
        '            if requested_action == "toggle":\n'
        '                target_mode = "dark" if self.mode in {"camera", "hud", "desktop"} else "camera"\n'
        '                if return_origin is not None:\n'
        '                    target_mode = "desktop"\n',
    ),
    (
        '            self.seen[event_id] = receipt\n            self.mode = target_mode\n',
        '            if return_origin is not None:\n'
        '                receipt["return_origin"] = return_origin\n'
        '            self.seen[event_id] = receipt\n            self.mode = target_mode\n',
    ),
    (
        '        if detected_at is not None:\n'
        '            result["edge_to_ack_ms"] = round((time.time() - detected_at) * 1000, 1)\n',
        '        if (target_mode == "desktop" and requested_action == "toggle"\n'
        '                and isinstance(receipt.get("return_origin"), dict)):\n'
        '            result["return_origin"] = dict(receipt["return_origin"])\n'
        '        if detected_at is not None:\n'
        '            result["edge_to_ack_ms"] = round((time.time() - detected_at) * 1000, 1)\n',
    ),
    (
        '            result = station.button(event_id, detected_at, requested_action)\n',
        '            result = station.button(\n'
        '                event_id, detected_at, requested_action,\n'
        '                monitor_request=payload,\n'
        '                monitor_peer_ip=self.client_address[0],\n'
        '                monitor_authenticated=True,\n'
        '            )\n',
    ),
)


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def _replace_exact(source: str, replacements: tuple[tuple[str, str], ...]) -> str:
    for before, after in replacements:
        if source.count(before) != 1:
            raise ValueError("receiver patch anchor mismatch")
        source = source.replace(before, after, 1)
    return source


def patched_source(source: bytes) -> bytes:
    """Accept only the reviewed original or this exact idempotent transformation."""
    text = source.decode("utf-8")
    if sha256(source) != EXPECTED_SOURCE_SHA256:
        try:
            restored = _replace_exact(text, tuple((b, a) for a, b in reversed(REPLACEMENTS)))
        except ValueError as exc:
            raise ValueError("unrecognized receiver source hash; review required") from exc
        if sha256(restored.encode("utf-8")) != EXPECTED_SOURCE_SHA256:
            raise ValueError("unrecognized receiver source hash; review required")
        if _replace_exact(restored, REPLACEMENTS) != text:
            raise ValueError("receiver patch verification failed")
        return source
    result = _replace_exact(text, REPLACEMENTS)
    compile(result, "<prepared-m1-receiver>", "exec")
    return result.encode("utf-8")


def _read_regular(path: Path, limit: int = MAX_SOURCE_BYTES) -> tuple[bytes, int]:
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("expected bounded regular file")
        result = handle.read(limit + 1)
        if len(result) > limit:
            raise ValueError("file exceeds size limit")
        return result, stat.S_IMODE(info.st_mode)


def _write_new(path: Path, content: bytes, mode: int = 0o600) -> None:
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode), "wb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())


def _sync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_replace(path: Path, content: bytes, mode: int, expected: bytes) -> None:
    fd, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if _read_regular(path)[0] != expected:
            raise ValueError("target changed while preparing replacement")
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def prepare(target: Path, *, apply: bool = False) -> dict[str, object]:
    original, mode = _read_regular(target)
    target = target.absolute()
    candidate = patched_source(original)
    result: dict[str, object] = {
        "patch": PATCH_ID, "target": str(target), "applied": False,
        "already_patched": candidate == original,
        "source_sha256": sha256(original), "candidate_sha256": sha256(candidate),
        "restart_performed": False,
    }
    if candidate == original:
        return result
    if not apply:
        result["diff"] = "".join(difflib.unified_diff(
            original.decode().splitlines(keepends=True), candidate.decode().splitlines(keepends=True),
            fromfile=str(target), tofile=str(target) + " (prepared)",
        ))
        return result
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backup = target.with_name(target.name + "." + PATCH_ID + "." + stamp + "." + uuid.uuid4().hex + ".bak")
    manifest = backup.with_suffix(backup.suffix + ".json")
    rollback_info = {
        "schema": 1, "patch": PATCH_ID, "target": str(target), "backup": str(backup),
        "original_sha256": sha256(original), "patched_sha256": sha256(candidate),
        "original_mode": mode,
    }
    _write_new(backup, original)
    _write_new(manifest, (json.dumps(rollback_info, indent=2, sort_keys=True) + "\n").encode())
    _sync_directory(target.parent)
    _atomic_replace(target, candidate, mode, original)
    result.update(applied=True, backup=str(backup), rollback_manifest=str(manifest))
    return result


def rollback(target: Path, manifest: Path, *, apply: bool = False) -> dict[str, object]:
    current, _ = _read_regular(target)
    data = json.loads(_read_regular(manifest, 8192)[0])
    if (not isinstance(data, dict) or data.get("schema") != 1 or data.get("patch") != PATCH_ID
            or data.get("target") != str(target.absolute())):
        raise ValueError("rollback manifest does not match explicit target")
    backup = Path(data["backup"])
    original, _ = _read_regular(backup)
    candidate = patched_source(original)
    if (sha256(original) != EXPECTED_SOURCE_SHA256
            or data.get("original_sha256") != sha256(original)
            or data.get("patched_sha256") != sha256(candidate)):
        raise ValueError("rollback backup or manifest hash mismatch")
    mode = data.get("original_mode")
    if type(mode) is not int or not 0 <= mode <= 0o777:
        raise ValueError("invalid rollback file mode")
    if current not in (original, candidate):
        raise ValueError("rollback would overwrite unrecognized receiver changes")
    result = {
        "patch": PATCH_ID, "target": str(target.absolute()), "rolled_back": False,
        "already_original": current == original, "original_sha256": sha256(original),
        "restart_performed": False,
    }
    if apply and current != original:
        _atomic_replace(target.absolute(), original, mode, current)
        result["rolled_back"] = True
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path, required=True, help="explicit local receiver file")
    parser.add_argument("--apply", action="store_true", help="write the explicit target (default: dry run)")
    parser.add_argument("--rollback", type=Path, metavar="MANIFEST", help="validate/restore an earlier backup")
    args = parser.parse_args()
    try:
        result = (rollback(args.target, args.rollback, apply=args.apply) if args.rollback
                  else prepare(args.target, apply=args.apply))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"{type(exc).__name__}: {exc}\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

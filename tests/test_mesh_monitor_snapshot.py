import io
import json
import unittest
from contextlib import redirect_stdout

import ops.mesh_monitor_snapshot as snapshot


def fake_fetcher(payloads):
    def fetch(path, token):
        if token != "manager-secret":
            raise AssertionError("unexpected token passed to fetcher")
        return payloads[path]

    return fetch


class MeshMonitorSnapshotTests(unittest.TestCase):
    def test_classifies_pending_worker_messages_without_codex_reply_as_stale(self):
        result = snapshot.build_snapshot(
            base="https://bridge.example",
            token="manager-secret",
            worker="claude",
            since_worker=542,
            since_manager=542,
            fetch_json=fake_fetcher(
                {
                    "/health": {"ok": True, "auth": True, "time": "2026-06-18T18:10:00Z"},
                    "/messages?to=claude&since=542": {
                        "messages": [
                            {"id": 545, "text": "secret message body"},
                            {"id": 555, "text": "latest body"},
                        ]
                    },
                    "/messages?to=codex&since=542": {"messages": []},
                }
            ),
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["classification"], "worker_pending_no_reply")
        self.assertEqual(result["recommended_action"], "do_not_reping_until_worker_or_operator_changes")
        self.assertEqual(result["pending_worker_count"], 2)
        self.assertEqual(result["pending_worker_ids"], [545, 555])
        self.assertEqual(result["manager_reply_count"], 0)
        self.assertNotIn("secret message body", json.dumps(result))

    def test_classifies_worker_reply_as_replied(self):
        result = snapshot.build_snapshot(
            base="https://bridge.example",
            token="manager-secret",
            worker="claude",
            since_worker=542,
            since_manager=542,
            fetch_json=fake_fetcher(
                {
                    "/health": {"ok": True, "auth": True, "time": "2026-06-18T18:10:00Z"},
                    "/messages?to=claude&since=542": {"messages": [{"id": 555}]},
                    "/messages?to=codex&since=542": {"messages": [{"id": 556, "frm": "claude"}]},
                }
            ),
        )

        self.assertEqual(result["classification"], "worker_replied")
        self.assertEqual(result["latest_manager_reply_id"], 556)
        self.assertEqual(result["recommended_action"], "review_worker_reply")

    def test_ignores_sentinel_notifications_when_classifying_worker_reply(self):
        result = snapshot.build_snapshot(
            base="https://bridge.example",
            token="manager-secret",
            worker="claude",
            since_worker=542,
            since_manager=542,
            fetch_json=fake_fetcher(
                {
                    "/health": {"ok": True, "auth": True, "time": "2026-06-18T18:10:00Z"},
                    "/messages?to=claude&since=542": {"messages": [{"id": 555}]},
                    "/messages?to=codex&since=542": {
                        "messages": [{"id": 559, "frm": "pi-sentinel", "kind": "urgent"}]
                    },
                }
            ),
        )

        self.assertEqual(result["classification"], "worker_pending_no_reply")
        self.assertEqual(result["latest_manager_reply_id"], None)
        self.assertEqual(result["manager_reply_count"], 0)
        self.assertEqual(result["non_worker_notification_count"], 1)

    def test_classifies_dead_letters_from_status_without_message_body_scraping(self):
        result = snapshot.build_snapshot(
            base="https://bridge.example",
            token="manager-secret",
            worker="claude",
            since_worker=542,
            since_manager=542,
            fetch_json=fake_fetcher(
                {
                    "/health": {"ok": True, "auth": True, "time": "2026-06-18T18:10:00Z"},
                    "/status": {
                        "ops_metrics": {
                            "queue_depth_by_lane": {"claude": 0},
                            "worker_heartbeats": {},
                            "dead_letters": {"count": 1, "latest": {"source_id": "msg-1", "sanitized_error_summary": "no raw body"}},
                        }
                    },
                    "/messages?to=claude&since=542": {"messages": []},
                    "/messages?to=codex&since=542": {"messages": []},
                }
            ),
        )

        self.assertEqual(result["classification"], "dead_letters_present")
        self.assertEqual(result["recommended_action"], "review_dead_letter_lane")
        self.assertEqual(result["dead_letter_count"], 1)
        self.assertNotIn("latest", result)

    def test_classifies_stale_worker_and_queue_saturation_from_status(self):
        stale_result = snapshot.build_snapshot(
            base="https://bridge.example",
            token="manager-secret",
            worker="claude",
            since_worker=542,
            since_manager=542,
            fetch_json=fake_fetcher(
                {
                    "/health": {"ok": True, "auth": True, "time": "2026-06-18T18:10:00Z"},
                    "/status": {
                        "ops_metrics": {
                            "queue_depth_by_lane": {"claude": 0},
                            "worker_heartbeats": {"claude": {"stale": True, "last_seen_age_s": 180}},
                            "dead_letters": {"count": 0},
                        }
                    },
                    "/messages?to=claude&since=542": {"messages": []},
                    "/messages?to=codex&since=542": {"messages": []},
                }
            ),
        )
        self.assertEqual(stale_result["classification"], "worker_stale")
        self.assertEqual(stale_result["stale_workers"], ["claude"])

        saturated_result = snapshot.build_snapshot(
            base="https://bridge.example",
            token="manager-secret",
            worker="claude",
            since_worker=542,
            since_manager=542,
            fetch_json=fake_fetcher(
                {
                    "/health": {"ok": True, "auth": True, "time": "2026-06-18T18:10:00Z"},
                    "/status": {
                        "ops_metrics": {
                            "queue_depth_by_lane": {"claude": 9},
                            "worker_heartbeats": {"claude": {"stale": False}},
                            "dead_letters": {"count": 0},
                        }
                    },
                    "/messages?to=claude&since=542": {"messages": []},
                    "/messages?to=codex&since=542": {"messages": []},
                }
            ),
        )
        self.assertEqual(saturated_result["classification"], "queue_saturated")
        self.assertEqual(saturated_result["queue_depth_by_lane"], {"claude": 9})

    def test_classifies_bridge_unhealthy_without_querying_messages(self):
        requested = []

        def fetch(path, token):
            requested.append(path)
            return {"ok": False, "auth": True, "time": "2026-06-18T18:10:00Z"}

        result = snapshot.build_snapshot(
            base="https://bridge.example",
            token="manager-secret",
            worker="claude",
            since_worker=542,
            since_manager=542,
            fetch_json=fetch,
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["classification"], "bridge_unhealthy")
        self.assertEqual(requested, ["/health"])

    def test_rejects_unsafe_worker_lane(self):
        with self.assertRaises(ValueError):
            snapshot.build_snapshot(
                base="https://bridge.example",
                token="manager-secret",
                worker="claude&to=codex",
                since_worker=542,
                since_manager=542,
                fetch_json=fake_fetcher({}),
            )

    def test_print_json_does_not_include_token(self):
        stream = io.StringIO()
        with redirect_stdout(stream):
            snapshot.print_json({"token": "manager-secret", "ok": True})

        output = stream.getvalue()
        parsed = json.loads(output)
        self.assertTrue(parsed["ok"])
        self.assertNotIn("manager-secret", output)
        self.assertNotIn("token", parsed)


if __name__ == "__main__":
    unittest.main()

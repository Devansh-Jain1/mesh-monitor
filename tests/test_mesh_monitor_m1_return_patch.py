"""Pinned receiver fixture only; no listener, device, camera, audio, or remote calls."""

from collections import OrderedDict
from datetime import datetime, timezone
from email.message import Message
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import threading
import types
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("return_patch", ROOT / "ops/mesh_monitor_m1_return_patch.py")
patcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patcher)
ORIGINAL = (Path(__file__).parent / "fixtures/mesh_monitor_m1_receiver_original.py.txt").read_bytes()
PREPARED = patcher.patched_source(ORIGINAL)
RETURN_MODE = "desktop"


class PatchArtifactTests(unittest.TestCase):
    def test_pinned_source_and_idempotence(self):
        self.assertEqual(patcher.sha256(ORIGINAL), patcher.EXPECTED_SOURCE_SHA256)
        self.assertNotEqual(PREPARED, ORIGINAL)
        self.assertEqual(patcher.patched_source(PREPARED), PREPARED)
        self.assertEqual(PREPARED.count(b"# BEGIN mesh-monitor-m1-return-v1"), 1)

    def test_unrelated_and_modified_receiver_rejected(self):
        for source in (b"print('unrelated')\n", ORIGINAL + b"# changed\n", PREPARED + b"# changed\n"):
            with self.subTest(source_hash=patcher.sha256(source)), self.assertRaisesRegex(ValueError, "unrecognized"):
                patcher.patched_source(source)

    def test_dry_run_apply_backup_and_verified_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "m1_station_receiver.py"
            target.write_bytes(ORIGINAL)
            target.chmod(0o640)
            dry = patcher.prepare(target)
            self.assertFalse(dry["applied"])
            self.assertIn("_mesh_monitor_return_origin", dry["diff"])
            self.assertEqual(target.read_bytes(), ORIGINAL)
            self.assertEqual(len(list(Path(directory).iterdir())), 1)
            applied = patcher.prepare(target, apply=True)
            self.assertTrue(applied["applied"])
            self.assertEqual(target.read_bytes(), PREPARED)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
            self.assertFalse(applied["restart_performed"])
            backup, manifest = Path(applied["backup"]), Path(applied["rollback_manifest"])
            self.assertEqual(backup.read_bytes(), ORIGINAL)
            self.assertIn("Z.", backup.name)
            for saved in (backup, manifest):
                self.assertEqual(stat.S_IMODE(saved.stat().st_mode), 0o600)
            self.assertTrue(patcher.prepare(target, apply=True)["already_patched"])
            self.assertEqual(len(list(Path(directory).iterdir())), 3)
            self.assertFalse(patcher.rollback(target, manifest)["rolled_back"])
            self.assertEqual(target.read_bytes(), PREPARED)
            self.assertTrue(patcher.rollback(target, manifest, apply=True)["rolled_back"])
            self.assertEqual(target.read_bytes(), ORIGINAL)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
            self.assertTrue(patcher.rollback(target, manifest, apply=True)["already_original"])

    def test_rollback_rejects_changed_target_corrupt_backup_and_other_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "receiver.py"
            target.write_bytes(ORIGINAL)
            applied = patcher.prepare(target, apply=True)
            manifest = Path(applied["rollback_manifest"])
            other = Path(directory) / "other.py"
            other.write_bytes(PREPARED)
            with self.assertRaisesRegex(ValueError, "explicit target"):
                patcher.rollback(other, manifest, apply=True)
            target.write_bytes(PREPARED + b"# later owner change\n")
            with self.assertRaisesRegex(ValueError, "overwrite unrecognized"):
                patcher.rollback(target, manifest, apply=True)
            target.write_bytes(PREPARED)
            Path(applied["backup"]).write_bytes(ORIGINAL + b"# corrupt backup\n")
            with self.assertRaises(ValueError):
                patcher.rollback(target, manifest, apply=True)
            self.assertEqual(target.read_bytes(), PREPARED)

    def test_symlink_target_and_concurrent_changes_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "receiver.py"
            target.write_bytes(ORIGINAL)
            link = Path(directory) / "link.py"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                patcher.prepare(link, apply=True)
            with self.assertRaisesRegex(ValueError, "target changed"):
                patcher._atomic_replace(target, PREPARED, 0o600, b"other expected source")
            self.assertEqual(target.read_bytes(), ORIGINAL)


class ReceiverReturnTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.marker = self.home / ".config/mesh-monitor/morning-return.json"
        self.marker.parent.mkdir(parents=True)
        self.now = datetime(2026, 9, 19, 14, tzinfo=timezone.utc).timestamp()
        self.arm = {
            "schema_version": 1, "armed": True,
            "session_id": "b02a2822-d66f-491a-91e0-02dcb577690c",
            "intended_date": "2026-09-19", "time_zone": "America/New_York",
            "created_at": self.now - 60, "expires_at": self.now + 3600,
            "pi_name": "raspberrypi", "pi_addresses": ["192.0.2.10", "2001:db8::10"],
        }
        self.payload = {
            "event_id": "raspberrypi-d02bc49b-cabb-4ff0-a218-42e22b72d053",
            "pi": "raspberrypi", "action": "toggle",
            "detected_at": self.now - 2, "sent_at": self.now - 1,
        }
        self.module = types.ModuleType("prepared_receiver_fixture")
        exec(compile(PREPARED, "<pinned-receiver-fixture>", "exec"), self.module.__dict__)
        for mocked in (
            patch.object(self.module.Path, "home", return_value=self.home),
            patch.object(self.module.time, "time", return_value=self.now),
            patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("no processes")),
            patch.object(self.module.subprocess, "run", side_effect=AssertionError("no commands")),
        ):
            mocked.start()
            self.addCleanup(mocked.stop)
        self.write_arm()
        self.station = self.module.Station.__new__(self.module.Station)
        self.station.token = "fixture-only-token"
        self.station.mode = "dark"
        self.station.lock = threading.Lock()
        self.station.seen = OrderedDict()
        self.station.camera_launch_consumed = False
        self.station.camera_launch_ready = False
        self.station.state_path = self.home / "state.json"
        self.station._safe_session_state = Mock(return_value={"unlocked": True})
        self.station._mode_converged = Mock(return_value=False)
        self.station._private_cover_converged = Mock(return_value=True)
        self.station._log = Mock()
        self.applied_modes = []

        def fake_mode_apply(mode):
            self.applied_modes.append(mode)
            if mode == "camera":
                self.station.camera_launch_consumed = True
                self.station.camera_launch_ready = True

        self.station._apply_mode = fake_mode_apply

    def write_arm(self):
        self.marker.write_text(json.dumps(self.arm))
        self.marker.chmod(0o600)

    def post(self, payload=None, peer="192.0.2.10", token="fixture-only-token"):
        body = json.dumps(self.payload if payload is None else payload).encode()
        handler = self.module.handler_for(self.station).__new__(self.module.handler_for(self.station))
        handler.path = "/button"
        handler.headers = Message()
        handler.headers["Authorization"] = "Bearer " + token
        handler.headers["Content-Length"] = str(len(body))
        handler.rfile = io.BytesIO(body)
        handler.client_address = (peer, 1)
        handler._json = Mock()
        handler.do_POST()
        return handler._json.call_args.args

    def assert_ordinary(self, payload=None, peer="192.0.2.10"):
        status, result = self.post(payload, peer=peer)
        self.assertEqual(status, 200)
        self.assertEqual(result["mode"], "camera")
        self.assertEqual(result["requested_action"], "toggle")
        self.assertNotIn("return_origin", result)
        self.assertEqual(self.applied_modes, ["camera"])

    def assert_blocked(self, payload=None, peer="192.0.2.10"):
        status, result = self.post(payload, peer=peer)
        self.assertEqual(status, 200)
        self.assertEqual(result["mode"], "dark")
        self.assertEqual(result["requested_action"], "toggle")
        self.assertEqual(result["reason"], "monitor_return_origin_unverified")
        self.assertTrue(result["ignored"])
        self.assertNotIn("return_origin", result)
        self.assertFalse(self.applied_modes)

    def test_authorized_fresh_dark_press_has_origin_and_original_action(self):
        status, result = self.post()
        self.assertEqual(status, 200)
        self.assertEqual(result["mode"], RETURN_MODE)
        self.assertEqual(result["requested_action"], "toggle")
        self.assertEqual(self.applied_modes, [RETURN_MODE])
        self.assertEqual(result["return_origin"], {
            "authenticated": True, "physical_pi": True, "peer_ip": "192.0.2.10",
            "pi": "raspberrypi", "detected_at": self.now - 2, "sent_at": self.now - 1,
            "previous_mode": "dark", "monitor_session_id": self.arm["session_id"],
        })
        persisted = json.loads(self.station.state_path.read_text())
        self.assertEqual(persisted["receipts"][0]["result"], result)
        self.assertEqual(self.post()[1], result)
        self.assertEqual(self.applied_modes, [RETURN_MODE], "Replay must not repeat the transition")

    def test_no_arm_marker_is_ordinary(self):
        self.marker.unlink()
        self.assert_ordinary()

    def test_authentication_cannot_be_supplied_by_body(self):
        status, result = self.post({**self.payload, "authenticated": True}, token="incorrect")
        self.assertEqual(status, 401)
        self.assertEqual(result["error"], "unauthorized")
        self.assertFalse(self.applied_modes)
        self.assertFalse(self.station.state_path.exists())

    def test_direct_button_call_has_no_implicit_authentication(self):
        result = self.station.button(self.payload["event_id"], self.payload["detected_at"],
                                     monitor_request=self.payload, monitor_peer_ip="192.0.2.10")
        self.assertEqual(result["mode"], "dark")
        self.assertTrue(result["ignored"])
        self.assertNotIn("return_origin", result)

    def test_unarmed_invalid_or_wrong_day_marker_is_ordinary(self):
        invalid = [
            {"armed": False}, {"armed": 1}, {"schema_version": True}, {"schema_version": 2},
            {"session_id": "missing"}, {"intended_date": "2026-09-20"},
            {"intended_date": "20260919"}, {"time_zone": "Invalid/Zone"},
            {"time_zone": None}, {"expires_at": self.now}, {"expires_at": float("inf")},
            {"created_at": self.now - 1}, {"created_at": True}, {"created_at": float("nan")},
            {"pi_name": "other"}, {"pi_addresses": []}, {"pi_addresses": ["raspberrypi"]},
            {"pi_addresses": ["192.0.2.10", "bad address"]}, {"pi_addresses": ["2001:db8::10%en0"]},
        ]
        for change in invalid:
            with self.subTest(change=change):
                original_arm = self.arm
                self.arm = {**original_arm, **change}
                self.write_arm()
                self.assertIsNone(self.module._mesh_monitor_return_origin(
                    self.payload, "192.0.2.10", authenticated=True))
                self.arm = original_arm
        self.arm["armed"] = False
        self.write_arm()
        self.assert_ordinary()

    def test_stale_future_and_mismatched_event_rejected(self):
        invalid = [
            {"detected_at": self.now - 31}, {"sent_at": self.now - 31},
            {"sent_at": self.now + 0.01}, {"detected_at": self.now + 1},
            {"detected_at": "timestamp"}, {"detected_at": True}, {"sent_at": float("nan")},
            {"pi": "other"}, {"event_id": "mode-poll-d02bc49b-cabb-4ff0-a218-42e22b72d053"},
            {"event_id": "raspberrypi-not-a-uuid"}, {"event_id": "raspberrypi-00000000-0000-0000-0000-000000000000"},
            {"action": "hud"}, {"action": "wake"},
        ]
        for change in invalid:
            with self.subTest(change=change):
                self.assertIsNone(self.module._mesh_monitor_return_origin(
                    {**self.payload, **change}, "192.0.2.10", authenticated=True))
        self.assert_blocked({**self.payload, "detected_at": self.now - 31})

    def test_wrong_peer_and_proxy_claim_rejected(self):
        self.assert_blocked({**self.payload, "peer_ip": "192.0.2.10"}, peer="192.0.2.11")

    def test_missing_and_synthetic_origin_remain_dark_while_armed(self):
        self.assert_blocked({"event_id": "monitor-poll-fixture", "action": "toggle"})

    def test_blocked_origin_reconciles_cover_without_enabling_camera(self):
        self.station._private_cover_converged.return_value = False
        self.station._ensure_private_cover = Mock()
        self.assert_blocked(peer="192.0.2.11")
        self.station._ensure_private_cover.assert_called_once()

    def test_known_ipv6_peer_accepted(self):
        self.assertEqual(self.post(peer="2001:db8::10")[1]["mode"], RETURN_MODE)

    def test_private_regular_marker_required(self):
        for mode in (0o644, 0o660):
            self.marker.chmod(mode)
            self.assertIsNone(self.module._mesh_monitor_return_origin(
                self.payload, "192.0.2.10", authenticated=True))
        actual = self.marker.with_suffix(".actual")
        self.marker.rename(actual)
        actual.chmod(0o600)
        self.marker.symlink_to(actual)
        self.assert_ordinary()

    def test_malformed_or_oversize_marker_is_ordinary(self):
        for content in (b"not json", b"[]", b" " * 8193):
            self.marker.write_bytes(content)
            self.assertIsNone(self.module._mesh_monitor_return_origin(
                self.payload, "192.0.2.10", authenticated=True))
        self.assert_ordinary()

    def test_lock_gate_remains_no_return_origin(self):
        self.station._safe_session_state.return_value = {"unlocked": False}
        status, result = self.post()
        self.assertEqual(status, 200)
        self.assertTrue(result["ignored"])
        self.assertEqual(result["reason"], "session_locked")
        self.assertNotIn("return_origin", result)
        self.assertEqual(self.applied_modes, [])

    def test_non_dark_or_long_press_retains_existing_behavior(self):
        self.station.mode = "camera"
        self.assertEqual(self.post()[1]["mode"], "dark")
        self.station.seen.clear()
        self.station.mode = "dark"
        status, result = self.post({**self.payload, "action": "hud"})
        self.assertEqual(status, 200)
        self.assertEqual(result["mode"], "hud")
        self.assertNotIn("return_origin", result)

    def test_desktop_next_press_returns_to_dark(self):
        self.assertEqual(self.post()[1]["mode"], "desktop")
        payload = {**self.payload, "event_id": "raspberrypi-37e218b6-431f-477b-ade8-201b1d741a1c"}
        result = self.post(payload)[1]
        self.assertEqual(result["mode"], "dark")
        self.assertEqual(result["requested_action"], "toggle")
        self.assertNotIn("return_origin", result)
        self.assertEqual(self.applied_modes, ["desktop", "dark"])

    def test_desktop_uses_existing_privacy_primitives_without_launches(self):
        calls = []
        names = ("_ensure_keep_awake", "_ensure_blackout", "_stop_station_camera_apps",
                 "_stop_hud", "_ensure_external_primary", "_stop_blackout")
        for name in names:
            setattr(self.station, name, lambda name=name: calls.append(name))
        self.station._display_desktop()
        self.assertEqual(calls, list(names))
        self.module.subprocess.run.assert_not_called()
        self.module.subprocess.Popen.assert_not_called()
        calls.clear()
        self.station._stop_blackout = Mock(side_effect=RuntimeError("fixture failure"))
        with self.assertRaisesRegex(RuntimeError, "fixture failure"):
            self.station._display_desktop()
        self.assertEqual(calls[-1], "_ensure_blackout", "Failed reveal must restore privacy cover")

    def test_desktop_convergence_requires_camera_hud_and_cover_absent(self):
        for camera, hud, blackout, expected in (
            (False, False, False, True), (True, False, False, False),
            (False, True, False, False), (False, False, True, False),
        ):
            self.station.station_camera_app_running = Mock(return_value=camera)
            self.station.hud_running = Mock(return_value=hud)
            self.station.blackout_running = Mock(return_value=blackout)
            self.assertEqual(self.module.Station._mode_converged(self.station, "desktop"), expected)

    def test_pending_restart_recovery_cannot_claim_a_new_physical_return(self):
        actual_apply = self.station._apply_mode
        self.station._apply_mode = Mock(side_effect=RuntimeError("fixture transition failure"))
        status, failed = self.post()
        self.assertEqual(status, 500)
        self.assertNotIn("return_origin", failed)
        self.station.mode, self.station.seen = self.station._load_persisted_state()
        self.assertEqual(self.station.mode, "desktop")
        self.assertNotIn("return_origin", self.station.seen[self.payload["event_id"]])
        self.station._apply_mode = actual_apply
        status, recovered = self.post()
        self.assertEqual(status, 200)
        self.assertEqual(recovered["mode"], "desktop")
        self.assertNotIn("return_origin", recovered)

    def test_health_poll_cannot_generate_return_origin(self):
        self.station.session_state = Mock(return_value={"unlocked": True})
        self.station.station_camera_app_running = Mock(return_value=False)
        self.station.hud_running = Mock(return_value=False)
        self.station.blackout_running = Mock(return_value=True)
        self.station.attention_active = Mock(return_value=False)
        handler_type = self.module.handler_for(self.station)
        handler = handler_type.__new__(handler_type)
        handler.path = "/health"
        handler.headers = Message()
        handler.headers["Authorization"] = "Bearer fixture-only-token"
        handler._json = Mock()
        handler.do_GET()
        status, result = handler._json.call_args.args
        self.assertEqual(status, 200)
        self.assertNotIn("return_origin", result)
        self.assertFalse(self.applied_modes)
        self.assertFalse(self.station.state_path.exists())


if __name__ == "__main__":
    unittest.main()

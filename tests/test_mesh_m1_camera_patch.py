"""Execute the actual pinned receiver hooks with fake camera and legacy resources."""
import importlib.util
from collections import OrderedDict
from pathlib import Path
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import Mock, patch

from test_mesh_m1_camera_station import Harness, module as camera

ROOT = Path(__file__).resolve().parents[1]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path); value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
returns = load("return_patcher_camera_tests", ROOT / "ops/mesh_monitor_m1_return_patch.py")
patcher = load("camera_patcher_tests", ROOT / "ops/mesh_monitor_m1_camera_patch.py")
ORIGINAL = (ROOT / "tests/fixtures/mesh_monitor_m1_receiver_original.py.txt").read_bytes()
RETURNED = returns.patched_source(ORIGINAL)
PATCHED = patcher.patched_source(RETURNED)


class CameraPatchArtifactTests(unittest.TestCase):
    def test_exact_composition_and_idempotence(self):
        self.assertEqual(patcher.sha256(RETURNED), patcher.EXPECTED_SOURCE_SHA256)
        self.assertEqual(patcher.patched_source(PATCHED), PATCHED)
        for source in (ORIGINAL, RETURNED + b"# changed\n", PATCHED + b"# changed\n"):
            with self.assertRaises(ValueError): patcher.patched_source(source)

    def test_dry_run_and_new_candidate_only(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "receiver.py"; source.write_bytes(RETURNED)
            result = patcher.prepare(source); self.assertFalse(result["applied"]); self.assertIn("_mesh_camera_revoke", result["diff"])
            self.assertEqual(source.read_bytes(), RETURNED); self.assertEqual(len(list(Path(folder).iterdir())), 1)
            output = Path(folder) / "candidate.py"; patcher.prepare(source, output)
            self.assertEqual(output.read_bytes(), PATCHED); self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(source.read_bytes(), RETURNED)
            with self.assertRaises(FileExistsError): patcher.prepare(source, source)
            link = Path(folder) / "link"; link.symlink_to(source)
            with self.assertRaises(OSError): patcher.prepare(link)


class CameraReceiverHookTests(unittest.TestCase):
    def setUp(self):
        self.receiver = types.ModuleType("camera_receiver_fixture")
        exec(compile(PATCHED, "<camera-owner-receiver-fixture>", "exec"), self.receiver.__dict__)
        self.h = Harness(); self.station = self.receiver.Station.__new__(self.receiver.Station)
        self.station.__dict__.update(self.h.station.__dict__)
        self.h.station = self.station; self.h.owner.station = self.station
        self.station.mesh_camera_owner = self.h.owner; self.station.mesh_camera_server = Mock()
        self.station._ensure_keep_awake = Mock(); self.station._ensure_blackout = Mock(); self.station._stop_blackout = Mock()
        self.station._stop_station_camera_apps = Mock(); self.station._stop_hud = Mock(); self.station._ensure_external_primary = Mock()
        self.station.station_camera_app_running = Mock(return_value=False); self.station.hud_running = Mock(return_value=False)
        self.station.blackout_running = Mock(return_value=True); self.station._log = Mock(); self.station.keep_awake = None
        self.station.camera_launch_consumed = self.station.camera_launch_ready = False
        self.station.seen = OrderedDict()
        for target in (patch.object(self.receiver.subprocess, "Popen", side_effect=AssertionError("no processes")),
                       patch.object(self.receiver.subprocess, "run", side_effect=AssertionError("no commands"))):
            target.start(); self.addCleanup(target.stop)

    def test_actual_dark_apply_stops_owned_helper_and_keeps_station_running(self):
        child = self.h.start()
        with self.station.lock:
            self.station.mode = "dark"; self.station._apply_mode("dark")
        self.assertIsNone(self.h.owner.child); self.assertEqual(child.closed, 1)
        self.station._ensure_blackout.assert_called(); self.assertFalse(self.station.stop_event.is_set())

    def test_actual_private_cover_stops_even_if_blackout_fails(self):
        child = self.h.start(); self.station._ensure_blackout.side_effect = RuntimeError("fake blackout failure")
        with self.station.lock, self.assertRaises(RuntimeError): self.station._ensure_private_cover()
        self.assertIsNone(self.h.owner.child); self.assertEqual(child.eof, 1)
        self.station._stop_station_camera_apps.assert_called(); self.station._stop_hud.assert_called()

    def test_lock_and_probe_failure_reconcile_stop_without_relaunch_on_unlock(self):
        for sample in ({"unlocked": False, "session_probe_available": True}, {"unlocked": False, "session_probe_available": False}):
            with self.subTest(sample=sample):
                if self.h.owner.identity is not None:
                    self.h.connection = object()
                    self.h.payload = self._new_payload(self.h.payload)
                child = self.h.start()
                with self.station.lock: self.station._reconcile_session_once(sample, reason="fixture")
                self.assertIsNone(self.h.owner.child); before = len(self.h.children)
                self.station.blackout_running.return_value = False
                with self.station.lock: self.station._reconcile_session_once({"unlocked": True, "session_probe_available": True}, reason="fixture")
                self.assertEqual(len(self.h.children), before); self.assertEqual(child.closed, 1)
                self.station.blackout_running.return_value = True

    @staticmethod
    def _new_payload(old):
        def value(op, **changes):
            return old(op, **{"sessionID": "00000000-0000-4000-8000-000000000008", **changes})
        return value

    def test_desktop_convergence_allows_owned_camera_but_dark_never_does(self):
        child = self.h.start(); self.station.blackout_running.return_value = False
        with self.station.lock: self.assertTrue(self.station._mode_converged("desktop"))
        self.station.blackout_running.return_value = True
        with self.station.lock:
            self.assertFalse(self.station._mode_converged("dark")); self.assertFalse(self.station._private_cover_converged())
        self.assertIs(self.h.owner.child, child)

    def test_shutdown_revokes_and_closes_control_server(self):
        self.h.start(); self.station.shutdown()
        self.assertTrue(self.station.stop_event.is_set()); self.assertTrue(self.h.owner.closed)
        self.assertIsNone(self.h.owner.child); self.station.mesh_camera_server.close.assert_called_once()

    def test_stalled_camera_cannot_claim_privacy_convergence(self):
        child = self.h.start(); child.auto_stop = child.term_exits = child.kill_exits = False
        with self.station.lock, self.assertRaisesRegex(RuntimeError, "unconfirmed"): self.station._ensure_private_cover()
        with self.station.lock: self.assertFalse(self.station._private_cover_converged())
        self.station._ensure_blackout.assert_called(); self.assertIs(self.h.owner.child, child)

    def test_start_races_dark_under_same_real_lock(self):
        child = self.h.prepare(); entered = threading.Event(); release = threading.Event()
        def probe(**kwargs):
            entered.set(); self.assertTrue(release.wait(2)); return {"unlocked": True, "session_probe_available": True}
        self.station._safe_session_state = probe
        start = threading.Thread(target=lambda: self.h.send("start")); start.start(); self.assertTrue(entered.wait(2))
        def dark():
            with self.station.lock:
                self.station.mode = "dark"; self.station._apply_mode("dark")
        stop = threading.Thread(target=dark); stop.start(); release.set(); start.join(2); stop.join(2)
        self.assertFalse(start.is_alive()); self.assertFalse(stop.is_alive()); self.assertIsNone(self.h.owner.child)
        self.assertEqual([c["command"] for c in child.commands].count("start"), 1)
        before = len(self.h.children); self.h.send("prepare", sessionID="00000000-0000-4000-8000-000000000009")
        self.assertEqual(len(self.h.children), before); self.assertEqual(self.h.receipts[-1]["reason"], "stationDark")

    def test_optional_attach_hook_calls_module_without_any_runtime_test(self):
        fake = types.SimpleNamespace(attach_station=Mock(return_value=False))
        with patch.dict(sys.modules, {"mesh_monitor_m1_camera_station": fake}): self.station._mesh_camera_attach()
        fake.attach_station.assert_called_once_with(self.station)
        self.assertIn("self._mesh_camera_attach()", PATCHED.decode())


if __name__ == "__main__": unittest.main()

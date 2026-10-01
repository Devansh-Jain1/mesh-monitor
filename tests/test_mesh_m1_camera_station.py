"""Fake subprocess/socket only. No actual listeners, helpers, SSH, camera or TCC."""
import importlib.util
import io
import json
import os
import stat
from pathlib import Path
import tempfile
import threading
import types
import unittest
import uuid
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("camera_station", ROOT / "ops/mesh_monitor_m1_camera_station.py")
module = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(module)


class Clock:
    def __init__(self): self.value = 0
    def __call__(self): return self.value
    def advance(self, seconds): self.value += seconds


class Child:
    def __init__(self, config):
        self.commands = []; self.output = bytearray(); self.code = None
        self.terminated = self.killed = self.closed = self.eof = 0
        self.auto_stop = True; self.term_exits = True; self.kill_exits = True
        self.fail_write = False; self.identity = None; self.state = "idle"
    def receipt(self, event, state, *, active=False, frame=False, reason="ok", **extra):
        value = {"schemaVersion": 1, "event": event, "reason": reason, "state": state,
            "identity": self.identity, "captureActive": active, "frameObserved": frame, **extra}
        self.output.extend(module.encoded(value))
    def write(self, data):
        if self.fail_write: return False
        value = json.loads(data); self.commands.append(value)
        op = value["command"]
        if op == "prepare":
            self.identity = {k: value[k] for k in module.IDENTITY_KEYS}
            self.state = "prepared"
            self.receipt("accepted", "preparing"); self.receipt("listenerReady", "prepared")
        elif op == "start":
            self.state = "capturing"; self.receipt("helperStarted", "capturing", active=True)
        elif op == "stop" and self.auto_stop:
            self.state = "stopped"; self.receipt("stopped", "stopped", reason="parentStop"); self.code = 0
        elif op in ("renew", "status"):
            self.receipt("state", self.state, active=self.state == "capturing")
        return True
    def read(self):
        if not self.output: return None
        data = bytes(self.output[:module.MAX_LINE]); del self.output[:module.MAX_LINE]; return data
    def poll(self): return self.code
    def terminate(self):
        self.terminated += 1
        if self.term_exits: self.code = -15
    def kill(self):
        self.killed += 1
        if self.kill_exits: self.code = -9
    def close_input(self): self.eof += 1
    def close(self): self.closed += 1


class Harness:
    def __init__(self):
        self.clock = Clock(); self.children = []; self.receipts = []; self.connection = object()
        self.station = types.SimpleNamespace(lock=threading.Lock(), mode="desktop", stop_event=threading.Event(),
            _safe_session_state=Mock(return_value={"session_probe_available": True, "unlocked": True}))
        self.config = {"helperExecutable": "/never-executed", "helperSHA256": "0" * 64,
            "cameraID": "EXACT-CAMERA", "port": 18495}
        def factory(config):
            child = Child(config); self.children.append(child); return child
        self.owner = module.StationCameraOwner(self.station, self.config, child_factory=factory, clock=self.clock, sleep=self.clock.advance)
    def payload(self, op, **changes):
        value = {"schemaVersion": 1, "command": op, "sessionID": "00000000-0000-4000-8000-000000000001",
            "generation": "00000000-0000-4000-8000-000000000002", "stationEpoch": self.owner.epoch,
            "cameraID": "EXACT-CAMERA", "controlToken": "a" * 64}
        if op == "prepare": value.update(port=18495, snapshotToken="b" * 64)
        if op == "renew": value["sequence"] = 1
        value.update(changes); return value
    def sink(self, value): self.receipts.append(value); return True
    def send(self, op, **changes):
        self.owner.command(module.encoded(self.payload(op, **changes)), self.connection, self.sink)
    def prepare(self): self.send("prepare"); self.owner.tick(); return self.children[-1]
    def start(self): child = self.prepare(); self.send("start"); self.owner.tick(); return child


class StationLifecycleTests(unittest.TestCase):
    def test_inert_init_hello_and_prepare_before_capture(self):
        h = Harness(); self.assertEqual(h.children, [])
        hello = h.owner.hello()
        self.assertEqual(set(hello), {"schemaVersion", "event", "stationEpoch", "mode", "eligible", "cameraID", "port", "reason"})
        self.assertTrue(hello["eligible"]); self.assertEqual(h.children, [])
        child = h.prepare(); self.assertEqual([c["command"] for c in child.commands], ["prepare"])
        h.send("prepare"); self.assertEqual(len(h.children), 1)
        h.send("start"); h.owner.tick(); h.send("start")
        self.assertEqual([c["command"] for c in child.commands].count("start"), 1)
        self.assertFalse(h.owner.frame_observed)
        child.receipt("firstFrame", "capturing", active=True, frame=True, capturedAt="2026-09-19T12:00:00Z")
        h.owner.tick(); self.assertTrue(h.owner.frame_observed)
        serialized = json.dumps(h.receipts)
        self.assertNotIn("a" * 64, serialized); self.assertNotIn("b" * 64, serialized)

    def test_dark_other_mode_and_console_reject_without_child(self):
        for mode, sample, reason in [("dark", {}, "stationDark"), ("camera", {}, "stationMode"),
                ("hud", {}, "stationMode"), ("desktop", {"session_probe_available": False}, "sessionProbeUnavailable"),
                ("desktop", {"session_probe_available": True, "unlocked": False}, "consoleLocked")]:
            h = Harness(); h.station.mode = mode; h.station._safe_session_state.return_value = sample
            self.assertEqual(h.owner.hello()["reason"], reason)
            h.send("prepare"); self.assertEqual(h.children, []); self.assertEqual(h.receipts[-1]["reason"], reason)

    def test_fresh_console_check_before_start_and_renew(self):
        for op in ("start", "renew"):
            h = Harness(); child = h.prepare(); h.station._safe_session_state.return_value = {"session_probe_available": True, "unlocked": False}
            h.send(op); h.owner.tick()
            self.assertNotIn(op, [x["command"] for x in child.commands]); self.assertIsNone(h.owner.child)
            self.assertTrue(any(r["reason"] == "consoleLocked" for r in h.receipts))

    def test_epoch_device_port_and_malformed_prepare_are_inert(self):
        for change, reason in [({"stationEpoch": "other"}, "stationEpochChanged"), ({"cameraID": "OTHER"}, "sourceMismatch"),
                ({"port": 18496}, "sourceMismatch"), ({"port": True}, "invalidCommand"),
                ({"schemaVersion": True}, "invalidCommand"), ({"snapshotToken": "a" * 64}, "invalidCommand"),
                ({"unexpected": "field"}, "invalidCommand")]:
            h = Harness(); h.send("prepare", **change)
            self.assertEqual(h.children, []); self.assertEqual(h.receipts[-1]["reason"], reason)

    def test_repeated_factory_failure_keeps_retired_sessions_bounded(self):
        h = Harness(); h.owner.child_factory = Mock(side_effect=OSError("unavailable"))
        for _ in range(150):
            h.send("prepare", sessionID=str(uuid.uuid4()))
            self.assertIsNone(h.owner.child)
            self.assertEqual(h.receipts[-1]["reason"], "helperUnavailable")
        self.assertEqual(len(h.owner.retired), 128)
        self.assertIsNone(h.owner.control_token)
        self.assertEqual(h.children, [])

    def test_wrong_session_token_connection_cannot_stop_current(self):
        for changes, reason in [({"generation": "00000000-0000-4000-8000-000000000003"}, "wrongSession"),
                ({"controlToken": "c" * 64}, "unauthorized")]:
            h = Harness(); child = h.start(); h.send("stop", **changes)
            self.assertIs(h.owner.child, child); self.assertEqual(h.receipts[-1]["reason"], reason)
        h.owner.command(module.encoded(h.payload("stop")), object(), h.sink)
        self.assertIs(h.owner.child, child); self.assertEqual(h.receipts[-1]["reason"], "sessionBusy")
        h.owner.disconnected(object()); self.assertEqual(child.eof, 0)

    def test_monotonic_lease_duplicate_renewal_and_no_restart(self):
        h = Harness(); child = h.start(); h.clock.advance(5); h.send("renew"); h.owner.tick()
        h.clock.advance(5); h.send("renew"); self.assertEqual(h.receipts[-1]["reason"], "staleRenewal")
        h.clock.advance(1); h.owner.tick(); h.owner.tick()
        self.assertIsNone(h.owner.child); self.assertEqual(len(h.children), 1)
        h.send("prepare"); self.assertEqual(h.receipts[-1]["reason"], "sessionRetired")
        h.clock.advance(100); h.owner.tick(); self.assertEqual(len(h.children), 1)

    def test_eof_repeated_stop_and_late_frame_do_not_revive(self):
        h = Harness(); child = h.start(); child.auto_stop = False
        h.owner.disconnected(h.connection)
        child.receipt("firstFrame", "capturing", active=True, frame=True, capturedAt="2026-09-19T12:00:00Z")
        h.owner.tick(); self.assertFalse(h.owner.frame_observed)
        with h.station.lock:
            h.owner.revoke_locked("parentStop"); h.owner.revoke_locked("stationDark")
        self.assertEqual([c["command"] for c in child.commands].count("stop"), 1)
        self.assertEqual(child.eof, 1)

    def test_ack_vs_process_exit_are_distinct(self):
        h = Harness(); h.start(); h.send("stop"); h.owner.tick()
        self.assertIn("stopped", [r["event"] for r in h.receipts]); self.assertIn("childExited", [r["event"] for r in h.receipts])
        self.assertIsNone(h.owner.child)
        h = Harness(); child = h.start(); child.code = 7; h.owner.tick()
        self.assertNotIn("stopped", [r["event"] for r in h.receipts]); self.assertEqual(h.receipts[-1]["event"], "childExited")
        self.assertEqual(h.receipts[-1]["exitCode"], 7)

    def test_stall_terminates_then_kills_only_retained_child(self):
        h = Harness(); child = h.start(); child.auto_stop = child.term_exits = False
        with h.station.lock: result = h.owner.revoke_locked("stationDark", wait=True)
        self.assertTrue(result); self.assertEqual((child.terminated, child.killed), (1, 1)); self.assertIsNone(h.owner.child)
        self.assertNotIn("stopped", [r["event"] for r in h.receipts])
        h = Harness(); child = h.start(); child.auto_stop = child.term_exits = child.kill_exits = False
        with h.station.lock: result = h.owner.revoke_locked("stationDark", wait=True)
        self.assertFalse(result); self.assertIs(h.owner.child, child)
        self.assertTrue(any(r["reason"] == "shutdownUnconfirmed" for r in h.receipts))
        h.send("prepare", sessionID="00000000-0000-4000-8000-000000000009")
        self.assertEqual(len(h.children), 1)

    def test_backpressure_and_write_failure_revoke(self):
        h = Harness(); child = h.start(); h.owner.sink = lambda value: False
        h.send("renew"); h.owner.tick(); h.owner.tick()
        self.assertIsNone(h.owner.child); self.assertEqual(child.eof, 1)
        h = Harness(); child = h.prepare(); child.fail_write = True; h.send("start")
        self.assertEqual(h.owner.state, "stopping"); self.assertEqual(child.eof, 1)

    def test_invalid_or_unsolicited_child_receipt_cannot_claim_capture(self):
        for change in [{"identity": {}}, {"reason": {}}, {"state": []}, {"controlToken": "secret"},
                {"event": "helperStarted", "state": "capturing", "captureActive": True},
                {"event": "stopped", "state": "stopped", "captureActive": True}]:
            h = Harness(); child = h.prepare(); child.auto_stop = False
            value = {"schemaVersion": 1, "event": "state", "reason": "ok", "state": "prepared", "identity": child.identity,
                "captureActive": False, "frameObserved": False, **change}
            child.output.extend(module.encoded(value)); h.owner.tick()
            self.assertEqual(h.owner.state, "stopping")
            self.assertTrue(any(r["reason"] == "helperProtocol" for r in h.receipts))

    def test_backend_failure_reason_survives(self):
        h = Harness(); child = h.prepare(); child.auto_stop = False
        h.send("start"); h.owner.tick()
        child.receipt("stopping", "stopping", active=True, reason="cameraPermission")
        h.owner.tick(); self.assertEqual(h.owner.stop_reason, "cameraPermission")
        self.assertTrue(any(r["reason"] == "cameraPermission" for r in h.receipts))

    def test_old_generation_cannot_stop_replacement(self):
        h = Harness(); h.start(); old_stop = h.payload("stop"); h.send("stop"); h.owner.tick()
        changes = {"sessionID": "00000000-0000-4000-8000-000000000005", "generation": "00000000-0000-4000-8000-000000000006"}
        h.send("prepare", **changes); h.owner.tick(); new_child = h.owner.child
        h.owner.command(module.encoded(old_stop), h.connection, h.sink)
        self.assertIs(h.owner.child, new_child); self.assertEqual(h.receipts[-1]["reason"], "wrongSession")

    def test_restart_epoch_rejects_old_prepare(self):
        h = Harness(); old = h.payload("prepare")
        newer = module.StationCameraOwner(h.station, h.config, child_factory=lambda c: self.fail("must not launch"))
        newer.command(module.encoded(old), object(), h.sink)
        self.assertEqual(h.receipts[-1]["reason"], "stationEpochChanged")


class PrivateSetupAndTransportTests(unittest.TestCase):
    def test_private_config_hash_symlink_mode_and_no_autocreate(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); root.chmod(0o700)
            helper = root / "fake-helper"; helper.write_bytes(b"never execute"); helper.chmod(0o700)
            config = {"schema": "mesh.m1-camera-station.v1", "helperExecutable": str(helper),
                "helperSHA256": module.hashlib.sha256(helper.read_bytes()).hexdigest(), "cameraID": "EXACT", "port": 18495}
            path = root / "camera-station.json"; path.write_text(json.dumps(config)); path.chmod(0o600)
            self.assertEqual(module.load_configuration(path), config)
            helper.write_bytes(b"changed")
            with self.assertRaises(ValueError): module.load_configuration(path)
            helper.write_bytes(b"never execute"); path.chmod(0o644)
            with self.assertRaises(ValueError): module.load_configuration(path)
            path.chmod(0o600); link = root / "link"; link.symlink_to(path)
            with self.assertRaises(OSError): module.load_configuration(link)
            with patch.object(module.Path, "home", return_value=root), patch.object(module.socket, "socket", side_effect=AssertionError("no socket")):
                self.assertFalse(module.attach_station(types.SimpleNamespace()))
            self.assertFalse((root / ".config").exists())

    def test_connection_handles_partial_writes_and_bounded_queue_with_fake_socket(self):
        stream = Mock(); stream.send.side_effect = lambda data: min(3, len(data))
        connection = module.Connection(stream)
        self.assertTrue(connection.enqueue({"value": "test"})); expected = bytes(connection.output)
        connection.flush(); self.assertEqual(bytes(connection.output), expected[3:])
        for _ in range(1000):
            if not connection.enqueue({"x": "z" * 1000}): break
        else: self.fail("queue was not bounded")
        self.assertLessEqual(len(connection.output), 16384)
        connection.close(); stream.close.assert_called_once(); self.assertFalse(connection.enqueue({"x": 1}))

    def test_server_existing_path_rejected_before_socket_creation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); root.chmod(0o700); path = root / "camera-control.sock"; path.write_text("owned elsewhere")
            server = module.CameraControlServer(Harness().owner, path)
            with patch.object(module.socket, "socket", side_effect=AssertionError("no real socket")), self.assertRaises(ValueError): server.start()
            server.close(); self.assertEqual(path.read_text(), "owned elsewhere")

    def test_server_serve_routes_fake_ndjson_and_disconnect(self):
        h = Harness(); data = module.encoded(h.payload("prepare"))
        stream = Mock(); stream.recv.side_effect = [data[:30], data[30:], b""]; stream.send.side_effect = lambda data: len(data)
        connection = module.Connection(stream); server = module.CameraControlServer(h.owner, Path("/never-bound"))
        with patch.object(module.select, "select", return_value=([stream], [], [])), patch.object(module.socket, "socket", side_effect=AssertionError("no socket")):
            server._serve(connection)
        self.assertEqual(len(h.children), 1); self.assertEqual(h.owner.state, "stopping"); self.assertEqual(h.children[0].eof, 1)
        self.assertEqual(h.children[0].commands[0]["command"], "prepare")

    def test_server_prepares_owner_private_socket_with_mock_only(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); root.chmod(0o700); path = root / "control.sock"
            info = types.SimpleNamespace(st_mode=stat.S_IFSOCK | 0o600, st_uid=os.getuid(), st_dev=7, st_ino=9)
            original = Path.lstat
            def metadata(candidate): return info if candidate == path else original(candidate)
            listener = Mock(); server = module.CameraControlServer(Harness().owner, path)
            with patch.object(module.socket, "socket", return_value=listener), patch.object(Path, "lstat", metadata), \
                 patch.object(module.os, "chmod") as chmod, patch.object(module.threading, "Thread") as thread:
                server.start()
            listener.bind.assert_called_once_with(str(path)); chmod.assert_called_once_with(path, 0o600)
            listener.listen.assert_called_once_with(4); thread.return_value.start.assert_called_once()
            self.assertEqual(server.inode, (7, 9)); listener.close.assert_not_called()
            server.close(); self.assertFalse(path.exists())

    def test_bridge_drains_final_ack_before_server_eof_without_real_socket(self):
        path = Path("/fixture/control.sock")
        info = types.SimpleNamespace(st_mode=stat.S_IFSOCK | 0o600, st_uid=os.getuid())
        pipe = types.SimpleNamespace(st_mode=stat.S_IFIFO | 0o600)
        stream = Mock(); ack = b'{"event":"stopped"}\n'; stream.recv.side_effect = [ack, b""]
        selections = [([stream], [], []), ([stream], [1], [])]
        writes = []
        def write(fd, data):
            writes.append((fd, bytes(data))); return len(data)
        with patch.object(module, "private_directory"), patch.object(Path, "lstat", return_value=info), \
             patch.object(module.os, "fstat", return_value=pipe), patch.object(module.os, "set_blocking"), \
             patch.object(module.socket, "socket", return_value=stream), patch.object(module, "peer_uid", return_value=os.getuid()), \
             patch.object(module.select, "select", side_effect=selections), patch.object(module.os, "write", side_effect=write):
            self.assertEqual(module.bridge(path), 0)
        self.assertEqual(writes, [(1, ack)])
        stream.close.assert_called_once()

    def test_socket_chmod_failure_removes_only_just_bound_inode(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); root.chmod(0o700); path = root / "control.sock"
            info = types.SimpleNamespace(st_mode=stat.S_IFSOCK | 0o600, st_uid=os.getuid(), st_dev=7, st_ino=9)
            original = Path.lstat
            def metadata(candidate): return info if candidate == path else original(candidate)
            listener = Mock(); server = module.CameraControlServer(Harness().owner, path)
            with patch.object(module.socket, "socket", return_value=listener), patch.object(Path, "lstat", metadata), \
                 patch.object(module.os, "chmod", side_effect=OSError("failed")), patch.object(Path, "unlink") as unlink:
                with self.assertRaises(OSError): server.start()
            listener.close.assert_called_once(); unlink.assert_called_once_with()
            listener.listen.assert_not_called()


if __name__ == "__main__": unittest.main()

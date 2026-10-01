#!/usr/bin/env python3
"""Optional Station-owned camera broker; importing this module is inert.

A reviewed receiver hook calls attach_station only when owner-private configuration
exists. The socket is control-only; prepare/start are explicit. --bridge relays this
private socket over an already authenticated parent's stdio, never launching a camera.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import hmac
import json
import os
from pathlib import Path
import select
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid

MAX_LINE = 4096
LEASE = 6.0
STOP_GRACE = 2.0
TERM_GRACE = 0.25
KILL_GRACE = 0.25
IDENTITY_KEYS = ("sessionID", "generation", "stationEpoch", "cameraID")
HELPER_REASONS = {
    "ok", "invalidCommand", "unauthorized", "wrongSession", "invalidState", "staleRenewal",
    "listenerFailed", "cameraPermission", "cameraMissing", "configuration", "captureFailed",
    "parentEOF", "parentReadFailed", "leaseExpired", "startupExpired", "parentStop", "signal",
    "outputUnavailable", "shutdownUnconfirmed", "invalidParentPipe",
}
STATION_REASONS = {
    "ready", "stationDark", "stationMode", "consoleLocked", "sessionProbeUnavailable",
    "stationShutdown", "privateCover", "configurationUnavailable", "invalidCommand",
    "unauthorized", "wrongSession", "stationEpochChanged", "sourceMismatch", "sessionBusy",
    "sessionRetired", "invalidState", "staleRenewal", "helperUnavailable", "helperProtocol",
    "childWriteFailed", "parentEOF", "parentBackpressure", "leaseExpired", "parentStop",
    "shutdownUnconfirmed", "childExited",
}
STATES = {"idle", "preparing", "prepared", "starting", "capturing", "stopping", "stopped"}


def encoded(value):
    data = json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode() + b"\n"
    if len(data) > MAX_LINE:
        raise ValueError("protocol bounds")
    return data


def decode(line):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate field")
            result[key] = value
        return result
    if not line or len(line) > MAX_LINE:
        raise ValueError("protocol bounds")
    value = json.loads(line, object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError("object required")
    return value


def visible(value, maximum):
    return isinstance(value, str) and 1 <= len(value) <= maximum and all(33 <= ord(c) <= 126 for c in value)


def token(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def command_valid(value):
    base = {"schemaVersion", "command", *IDENTITY_KEYS, "controlToken"}
    extra = {"prepare": {"snapshotToken", "port"}, "renew": {"sequence"}, "start": set(), "stop": set(), "status": set()}
    op = value.get("command")
    if not isinstance(op, str) or op not in extra or set(value) != base | extra[op]:
        return False
    try:
        valid = (type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
                 and all(isinstance(value[k], str) and str(uuid.UUID(value[k])) == value[k].lower() for k in IDENTITY_KEYS[:2])
                 and visible(value["stationEpoch"], 128) and visible(value["cameraID"], 512) and token(value["controlToken"]))
        if op == "prepare":
            valid = valid and token(value["snapshotToken"]) and value["snapshotToken"] != value["controlToken"] and type(value["port"]) is int and 1024 <= value["port"] <= 65535
        if op == "renew":
            valid = valid and type(value["sequence"]) is int and 0 < value["sequence"] <= 2**64 - 1
        return valid
    except (ValueError, TypeError, AttributeError):
        return False


def private_directory(path):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError("absolute directory required")
    current = Path(path.anchor)
    for component in path.parts[1:]:
        if component in (".", ".."):
            raise ValueError("unsafe directory")
        current /= component
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError("directory link refused")
    info = path.lstat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("private directory required")


def read_file(path, *, private=True, limit=8192):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                or info.st_size > limit or info.st_size < 0
                or (stat.S_IMODE(info.st_mode) != 0o600 if private else info.st_mode & 0o022 or not info.st_mode & 0o111)):
            raise ValueError("unsafe file")
        chunks, size = [], 0
        while True:
            chunk = os.read(fd, min(65536, limit + 1 - size))
            if not chunk:
                break
            chunks.append(chunk); size += len(chunk)
            if size > limit:
                raise ValueError("file bounds")
        return b"".join(chunks)
    finally:
        os.close(fd)


def load_configuration(path):
    path = Path(path)
    private_directory(path.parent)
    value = decode(read_file(path))
    if (set(value) != {"schema", "helperExecutable", "helperSHA256", "cameraID", "port"}
            or value["schema"] != "mesh.m1-camera-station.v1" or not visible(value["cameraID"], 512)
            or not token(value["helperSHA256"]) or type(value["port"]) is not int or not 1024 <= value["port"] <= 65535
            or not isinstance(value["helperExecutable"], str) or not Path(value["helperExecutable"]).is_absolute()):
        raise ValueError("invalid configuration")
    verify_helper(value)
    return value


def verify_helper(config):
    path = Path(config["helperExecutable"])
    current = Path(path.anchor)
    for part in path.parts[1:-1]:
        current /= part
        if part in (".", "..") or not stat.S_ISDIR(current.lstat().st_mode):
            raise ValueError("unsafe helper path")
    if hashlib.sha256(read_file(path, private=False, limit=64 * 1024 * 1024)).hexdigest() != config["helperSHA256"]:
        raise ValueError("helper hash mismatch")


class OwnedChild:
    """Only this retained Popen can receive terminate/kill. No PID files or lookup."""
    def __init__(self, config):
        verify_helper(config)
        env = dict(os.environ)
        for key in ("DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"):
            env.pop(key, None)
        self.process = subprocess.Popen([config["helperExecutable"], "--managed"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0, close_fds=True, env=env)
        self.io_ready = False
        try:
            os.set_blocking(self.process.stdin.fileno(), False)
            os.set_blocking(self.process.stdout.fileno(), False)
            self.io_ready = True
        except OSError:
            pass  # Return the owned child; failed write triggers bounded retained cleanup.

    def write(self, data):
        if not self.io_ready:
            return False
        try:
            return os.write(self.process.stdin.fileno(), data) == len(data)
        except (OSError, ValueError):
            return False

    def read(self):
        if not self.io_ready:
            return None
        try:
            return os.read(self.process.stdout.fileno(), MAX_LINE)
        except BlockingIOError:
            return None

    def poll(self):
        return self.process.poll()

    def terminate(self):
        if self.process.poll() is None:
            self.process.terminate()

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()

    def close_input(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()

    def close(self):
        self.close_input()
        if self.process.stdout and not self.process.stdout.closed:
            self.process.stdout.close()


class StationCameraOwner:
    """All *_locked methods run under the real Station.lock, shared with Dark."""
    def __init__(self, station, config, *, child_factory=OwnedChild, clock=time.monotonic, sleep=time.sleep):
        self.station, self.config = station, dict(config)
        self.child_factory, self.clock, self.sleep = child_factory, clock, sleep
        self.epoch = str(uuid.uuid4())
        self.child = None
        self.identity = None
        self.control_token = self.snapshot_token = None
        self.connection = None
        self.sink = None
        self.state = "idle"
        self.deadline = 0.0
        self.sequence = 0
        self.buffer = bytearray()
        self.capture_requested = self.frame_observed = self.acknowledged = False
        self.stop_stage = 0
        self.stop_reason = "parentStop"
        self.closed = False
        self.retired = []

    def eligibility_locked(self):
        if self.closed or self.station.stop_event.is_set():
            return "stationShutdown"
        if self.station.mode == "dark":
            return "stationDark"
        if self.station.mode != "desktop":
            return "stationMode"
        sample = self.station._safe_session_state(reason="mesh_camera")
        if sample.get("session_probe_available") is not True:
            return "sessionProbeUnavailable"
        return "ready" if sample.get("unlocked") is True else "consoleLocked"

    def hello(self):
        with self.station.lock:
            reason = self.eligibility_locked()
            return {"schemaVersion": 1, "event": "stationHello", "stationEpoch": self.epoch,
                "mode": self.station.mode, "eligible": reason == "ready", "cameraID": self.config["cameraID"],
                "port": self.config["port"], "reason": reason}

    def receipt(self, event, reason="ok", **extra):
        result = {"schemaVersion": 1, "event": event, "reason": reason, "state": self.state,
            "captureActive": self.capture_requested and self.child is not None,
            "frameObserved": self.frame_observed}
        if self.identity is not None:
            result["identity"] = dict(self.identity)
        result.update(extra)
        return result

    def emit_locked(self, value):
        if self.sink is not None and not self.sink(value):
            self.sink = None
            self.revoke_locked("parentBackpressure")

    def error(self, sink, reason):
        sink(self.receipt("error", reason))

    def command(self, line, connection, sink):
        with self.station.lock:
            self.tick_locked()
            try:
                value = decode(line)
            except (ValueError, UnicodeError):
                if connection == self.connection:
                    self.revoke_locked("invalidCommand")
                self.error(sink, "invalidCommand"); return
            if not command_valid(value):
                if connection == self.connection:
                    self.revoke_locked("invalidCommand")
                self.error(sink, "invalidCommand"); return
            identity = {k: value[k] for k in IDENTITY_KEYS}
            if value["stationEpoch"] != self.epoch:
                self.error(sink, "stationEpochChanged"); return
            if value["cameraID"] != self.config["cameraID"] or (value["command"] == "prepare" and value["port"] != self.config["port"]):
                self.error(sink, "sourceMismatch"); return
            if self.child is None:
                if value["command"] != "prepare":
                    self.error(sink, "invalidState"); return
                if tuple(identity.values()) in self.retired:
                    self.error(sink, "sessionRetired"); return
                reason = self.eligibility_locked()
                if reason != "ready":
                    self.error(sink, reason); return
                self.identity, self.connection, self.sink = identity, connection, sink
                self.control_token, self.snapshot_token = value["controlToken"], value["snapshotToken"]
                self.state = "preparing"; self.deadline = self.clock() + LEASE; self.sequence = 0
                self.capture_requested = self.frame_observed = self.acknowledged = False
                self.buffer.clear(); self.stop_stage = 0
                try:
                    self.child = self.child_factory(self.config)
                except Exception:
                    self.state = "stopped"; self.retired.append(tuple(identity.values()))
                    self.retired = self.retired[-128:]
                    self.emit_locked(self.receipt("error", "helperUnavailable")); self._release_locked(); return
            else:
                if connection != self.connection:
                    self.error(sink, "sessionBusy"); return
                if identity != self.identity:
                    self.error(sink, "wrongSession"); return
                if not hmac.compare_digest(value["controlToken"], self.control_token):
                    self.error(sink, "unauthorized"); return
                if self.state == "stopping":
                    sink(self.receipt("stopping", self.stop_reason)); return
                if value["command"] == "prepare":
                    if not hmac.compare_digest(value["snapshotToken"], self.snapshot_token):
                        self.error(sink, "unauthorized"); return
                    sink(self.receipt("state")); return
            op = value["command"]
            if op in ("start", "renew"):
                reason = self.eligibility_locked()
                if reason != "ready":
                    self.revoke_locked(reason); return
            if op == "start":
                if self.state in ("starting", "capturing"):
                    sink(self.receipt("state")); return
                if self.state != "prepared":
                    self.error(sink, "invalidState"); return
                self.capture_requested = True; self.state = "starting"
            elif op == "renew":
                if value["sequence"] <= self.sequence:
                    self.error(sink, "staleRenewal"); return
                self.sequence = value["sequence"]; self.deadline = self.clock() + LEASE
            elif op == "stop":
                self.revoke_locked("parentStop"); return
            if not self.child.write(encoded(value)):
                self.revoke_locked("childWriteFailed")

    def disconnected(self, connection):
        with self.station.lock:
            if connection == self.connection:
                self.sink = None
                self.revoke_locked("parentEOF")

    def revoke_locked(self, reason, *, wait=False):
        if reason not in STATION_REASONS | HELPER_REASONS:
            raise ValueError("unknown stop reason")
        if reason == "stationShutdown":
            self.closed = True
        if self.child is None:
            return True
        if self.state != "stopping":
            self.state = "stopping"; self.stop_reason = reason; self.frame_observed = False
            self.deadline = self.clock() + STOP_GRACE; self.stop_stage = 0
            self.emit_locked(self.receipt("stopping", reason))
            command = {"schemaVersion": 1, "command": "stop", **self.identity, "controlToken": self.control_token}
            self.child.write(encoded(command))
            self.child.close_input()  # EOF backs up a lost stop write.
        if wait:
            deadline = self.clock() + STOP_GRACE + TERM_GRACE + KILL_GRACE + 0.1
            while self.child is not None and self.clock() < deadline:
                self.tick_locked(); self.sleep(0.01)
            self.tick_locked()
        return self.child is None

    def tick(self):
        with self.station.lock:
            self.tick_locked()

    def tick_locked(self):
        if self.child is None:
            return
        try:
            # Bound work so a chatty helper cannot delay mode transitions indefinitely.
            for _ in range(4):
                data = self.child.read()
                if data is None or data == b"":
                    break
                self.buffer.extend(data)
                while b"\n" in self.buffer:
                    line, _, rest = self.buffer.partition(b"\n"); self.buffer = bytearray(rest)
                    self._child_receipt_locked(line)
                if len(self.buffer) > MAX_LINE:
                    raise ValueError("helper bounds")
        except (ValueError, TypeError, UnicodeError, OSError):
            self.buffer.clear(); self.revoke_locked("helperProtocol")
        code = self.child.poll()
        if code is not None:
            self.state = "stopped"; self.frame_observed = False; self.capture_requested = False
            child, self.child = self.child, None
            self.emit_locked(self.receipt("childExited", "childExited", exitCode=code))
            self.retired.append(tuple(self.identity.values())); self.retired = self.retired[-128:]
            child.close(); self._release_locked(); return
        if self.clock() >= self.deadline:
            if self.state != "stopping":
                self.revoke_locked("leaseExpired")
            elif self.stop_stage == 0:
                self.child.terminate(); self.stop_stage = 1; self.deadline = self.clock() + TERM_GRACE
            elif self.stop_stage == 1:
                self.child.kill(); self.stop_stage = 2; self.deadline = self.clock() + KILL_GRACE
            elif self.stop_stage == 2:
                self.stop_stage = 3; self.deadline = float("inf")
                self.emit_locked(self.receipt("error", "shutdownUnconfirmed"))

    def _child_receipt_locked(self, line):
        value = decode(line)
        required = {"schemaVersion", "event", "reason", "state", "identity", "captureActive", "frameObserved"}
        if (not required <= set(value) or set(value) - required - {"capturedAt"}
                or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
                or value["identity"] != self.identity or not isinstance(value["reason"], str) or value["reason"] not in HELPER_REASONS
                or not isinstance(value["state"], str) or value["state"] not in STATES or type(value["captureActive"]) is not bool
                or type(value["frameObserved"]) is not bool
                or ("capturedAt" in value and not visible(value["capturedAt"], 64))):
            raise ValueError("invalid helper receipt")
        event = value["event"]
        if event == "stopped":
            if value["state"] != "stopped" or value["captureActive"] or value["frameObserved"]:
                raise ValueError("false stopped receipt")
            self.acknowledged = True; self.frame_observed = False
            if self.state != "stopping":
                self.state = "stopping"; self.stop_reason = value["reason"]
                self.deadline = self.clock() + STOP_GRACE; self.stop_stage = 0
                self.child.close_input()
            self.emit_locked(value)
            return
        if self.state == "stopping":
            return  # Late startup/frames cannot undo local revocation.
        if event == "accepted":
            if self.state != "preparing" or value["state"] != "preparing" or value["captureActive"]:
                raise ValueError("out-of-order helper receipt")
        elif event == "listenerReady":
            if self.state != "preparing" or value["state"] != "prepared" or value["captureActive"]:
                raise ValueError("out-of-order listener")
            self.state = "prepared"
        elif event == "helperStarted":
            if self.state != "starting" or value["state"] != "capturing" or not value["captureActive"]:
                raise ValueError("unsolicited capture")
            self.state = "capturing"
        elif event == "firstFrame":
            if self.state != "capturing" or not value["frameObserved"] or not value["captureActive"] or "capturedAt" not in value:
                raise ValueError("unsolicited frame")
            self.frame_observed = True
        elif event == "stopping":
            self.revoke_locked(value["reason"]); return
        elif event == "error":
            self.emit_locked(value); self.revoke_locked(value["reason"]); return
        elif event == "state":
            if value["captureActive"] and not self.capture_requested or value["frameObserved"] and not self.frame_observed:
                raise ValueError("unsolicited state evidence")
            self.emit_locked(self.receipt("state", value["reason"])); return
        elif event != "state":
            raise ValueError("unknown helper event")
        self.emit_locked(value)

    def _release_locked(self):
        self.connection = self.sink = None
        self.control_token = self.snapshot_token = None
        self.buffer.clear()


def peer_uid(connection):
    if sys.platform == "darwin":
        library = ctypes.CDLL(None, use_errno=True)
        user, group = ctypes.c_uint(), ctypes.c_uint()
        if library.getpeereid(connection.fileno(), ctypes.byref(user), ctypes.byref(group)) != 0:
            raise OSError("peer credentials unavailable")
        return user.value
    if hasattr(socket, "SO_PEERCRED"):
        import struct
        return struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
    raise OSError("peer credentials unavailable")


class Connection:
    def __init__(self, stream):
        self.stream = stream; self.output = bytearray(); self.lock = threading.Lock(); self.closed = False

    def enqueue(self, value):
        data = encoded(value)
        with self.lock:
            if self.closed or len(self.output) + len(data) > 16384:
                return False
            self.output.extend(data); return True

    def flush(self):
        with self.lock:
            if self.output:
                try:
                    count = self.stream.send(self.output)
                except BlockingIOError:
                    return
                if count <= 0:
                    raise OSError("closed output")
                del self.output[:count]

    def close(self):
        with self.lock:
            self.closed = True
            self.stream.close()


class CameraControlServer:
    def __init__(self, owner, path):
        self.owner, self.path = owner, Path(path)
        self.listener = None; self.inode = None
        self.closed = threading.Event(); self.clients = set(); self.clients_lock = threading.Lock()

    def start(self):
        private_directory(self.path.parent)
        if len(os.fsencode(self.path)) >= 104 or os.path.lexists(self.path):
            raise ValueError("existing or invalid socket path")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(self.path))
            info = self.path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("owned socket required")
            self.inode = (info.st_dev, info.st_ino)
            os.chmod(self.path, 0o600)
            info = self.path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                raise ValueError("private socket required")
            if self.inode != (info.st_dev, info.st_ino):
                raise ValueError("socket changed")
            listener.listen(4); listener.settimeout(0.1); self.listener = listener
        except Exception:
            listener.close(); self._remove_owned_socket(); raise
        threading.Thread(target=self._run, name="mesh-camera-control", daemon=True).start()

    def _run(self):
        while not self.closed.is_set():
            self.owner.tick()
            try:
                stream, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                if peer_uid(stream) != os.getuid():
                    raise OSError("wrong peer")
                stream.setblocking(False)
                connection = Connection(stream)
                with self.clients_lock:
                    if len(self.clients) >= 4:
                        stream.close(); continue
                    self.clients.add(connection)
                threading.Thread(target=self._serve, args=(connection,), name="mesh-camera-client", daemon=True).start()
            except OSError:
                stream.close()

    def _serve(self, connection):
        buffer = bytearray()
        connection.enqueue(self.owner.hello())
        try:
            while not self.closed.is_set():
                connection.flush()
                ready, _, _ = select.select([connection.stream], [], [], 0.1)
                if not ready:
                    continue
                data = connection.stream.recv(MAX_LINE)
                if not data:
                    break
                buffer.extend(data)
                while b"\n" in buffer:
                    line, _, rest = buffer.partition(b"\n"); buffer = bytearray(rest)
                    self.owner.command(line, connection, connection.enqueue)
                if len(buffer) > MAX_LINE:
                    raise ValueError("parent bounds")
        except (OSError, ValueError):
            pass
        finally:
            self.owner.disconnected(connection); connection.close()
            with self.clients_lock:
                self.clients.discard(connection)

    def _remove_owned_socket(self):
        try:
            info = self.path.lstat()
            if self.inode == (info.st_dev, info.st_ino) and stat.S_ISSOCK(info.st_mode):
                self.path.unlink()
        except FileNotFoundError:
            pass

    def close(self):
        self.closed.set()
        if self.listener:
            self.listener.close()
        with self.clients_lock:
            for connection in self.clients:
                connection.close()
        self._remove_owned_socket()


def attach_station(station):
    """Explicit receiver integration; absent setup stays disabled, no directory creation."""
    root = Path.home() / ".config/mesh-monitor"
    config_path = root / "camera-station.json"
    if not os.path.lexists(config_path):
        return False
    config = load_configuration(config_path)
    owner = StationCameraOwner(station, config)
    server = CameraControlServer(owner, root / "camera-control.sock")
    station.mesh_camera_owner, station.mesh_camera_server = owner, server
    try:
        server.start()
    except Exception:
        station.mesh_camera_owner = station.mesh_camera_server = None
        server.close(); raise
    return True


def bridge(path=None):
    """Fixed stdio-to-private-socket client. No spawning, station token or camera API."""
    path = Path(path) if path is not None else Path.home() / ".config/mesh-monitor/camera-control.sock"
    private_directory(path.parent)
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError("unsafe socket")
    if not stat.S_ISFIFO(os.fstat(0).st_mode):
        raise ValueError("parent pipe required")
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        stream.settimeout(2); stream.connect(str(path))
        if peer_uid(stream) != os.getuid():
            raise OSError("wrong server peer")
        stream.setblocking(False); os.set_blocking(0, False); os.set_blocking(1, False)
        pending_out, pending_in = bytearray(), bytearray()
        server_closed, flush_deadline = False, None
        while True:
            if server_closed and not pending_out:
                return 0
            if flush_deadline is not None and time.monotonic() >= flush_deadline:
                return 2
            readers, writers, _ = select.select([] if server_closed else [0, stream],
                ([stream] if pending_in and not server_closed else []) + ([1] if pending_out else []), [], 0.1)
            if 0 in readers:
                data = os.read(0, MAX_LINE)
                if not data:
                    return 0
                pending_in.extend(data)
            if stream in readers:
                data = stream.recv(MAX_LINE)
                if not data:
                    server_closed = True; flush_deadline = time.monotonic() + 1
                    pending_in.clear()
                else:
                    pending_out.extend(data)
            if max(len(pending_in), len(pending_out)) > 16384:
                raise ValueError("bridge backpressure")
            if stream in writers and pending_in:
                count = stream.send(pending_in); del pending_in[:count]
            if 1 in writers and pending_out:
                count = os.write(1, pending_out); del pending_out[:count]
    finally:
        stream.close()  # Station treats disconnect as exact-session revocation.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", action="store_true", required=True)
    parser.parse_args()
    try:
        return bridge()
    except (OSError, ValueError):
        try:
            os.write(1, encoded({"schemaVersion": 1, "event": "error", "reason": "configurationUnavailable",
                "state": "idle", "captureActive": False, "frameObserved": False}))
        except OSError:
            pass
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

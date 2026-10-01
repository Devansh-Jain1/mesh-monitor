#!/usr/bin/env python3
"""Prepare an offline camera-owner patch for the exact return-patched receiver.

Default prints a diff. --output writes a NEW candidate only, never modifies its
input, installs a module, reloads Station or starts any service/helper/socket.
"""
from __future__ import annotations
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import stat

EXPECTED_SOURCE_SHA256 = "7a75c92c5766c8a14d234b6d75563b4c23e63c08ae0c1da3397ebad7c3278683"
PATCH_ID = "mesh-monitor-m1-camera-owner-v1"

METHODS = '''    # BEGIN mesh-monitor-m1-camera-owner-v1
    def _mesh_camera_stopped(self) -> bool:
        owner = getattr(self, "mesh_camera_owner", None)
        if owner is None:
            return True
        owner.tick_locked()
        return owner.child is None

    def _mesh_camera_revoke(self, reason: str, *, wait: bool = False) -> None:
        owner = getattr(self, "mesh_camera_owner", None)
        if owner is not None and not owner.revoke_locked(reason, wait=wait) and wait:
            raise RuntimeError("managed camera shutdown unconfirmed")

    def _mesh_camera_attach(self) -> None:
        try:
            from mesh_monitor_m1_camera_station import attach_station
            attach_station(self)
        except (ImportError, OSError, ValueError):
            self._log("mesh_camera_setup_unavailable")
    # END mesh-monitor-m1-camera-owner-v1

'''

OLD_COVER = '''    def _ensure_private_cover(self) -> None:
        self._ensure_keep_awake()
        try:
            self._ensure_blackout()
        except Exception:
            # Camera/HUD must never survive a lock or shutdown, even when the
            # privacy-cover helper itself is unhealthy.
            self._stop_station_camera_apps()
            self._stop_hud()
            raise
        self._stop_station_camera_apps()
        self._stop_hud()
'''
NEW_COVER = '''    def _ensure_private_cover(self) -> None:
        self._mesh_camera_revoke("privateCover")
        try:
            self._ensure_keep_awake()
            try:
                self._ensure_blackout()
            except Exception:
                # Stop camera owners even if the privacy-cover helper failed.
                self._stop_station_camera_apps()
                self._stop_hud()
                raise
            self._stop_station_camera_apps()
            self._stop_hud()
        finally:
            self._mesh_camera_revoke("privateCover", wait=True)
'''
OLD_SHUTDOWN = '''    def shutdown(self) -> None:
        self.stop_event.set()
        with self.lock:
            try:
                self._ensure_private_cover()
                self._log("shutdown_private_cover_ready", mode=self.mode)
            except Exception as exc:
                self._log("shutdown_private_cover_error", error=str(exc), mode=self.mode)
            if self.keep_awake is not None and self.keep_awake.poll() is None:
                self.keep_awake.terminate()
'''
NEW_SHUTDOWN = '''    def shutdown(self) -> None:
        self.stop_event.set()
        with self.lock:
            try:
                self._mesh_camera_revoke("stationShutdown")
                self._ensure_private_cover()
                self._log("shutdown_private_cover_ready", mode=self.mode)
            except Exception as exc:
                self._log("shutdown_private_cover_error", error=str(exc), mode=self.mode)
            if self.keep_awake is not None and self.keep_awake.poll() is None:
                self.keep_awake.terminate()
        server = getattr(self, "mesh_camera_server", None)
        if server is not None:
            server.close()
'''

REPLACEMENTS = (
    ('        self.stop_event = threading.Event()\n',
     '        self.stop_event = threading.Event()\n        self.mesh_camera_owner = None\n        self.mesh_camera_server = None\n'),
    ('        threading.Thread(target=self._reconcile_session_loop, name="session-reconciler", daemon=True).start()\n',
     '        threading.Thread(target=self._reconcile_session_loop, name="session-reconciler", daemon=True).start()\n        self._mesh_camera_attach()\n'),
    ('    def station_camera_app_running(self) -> bool:\n', METHODS + '    def station_camera_app_running(self) -> bool:\n'),
    ('        if not session_state.get("unlocked"):\n',
     '        if not session_state.get("unlocked"):\n            self._mesh_camera_revoke("consoleLocked" if session_state.get("session_probe_available") else "sessionProbeUnavailable")\n'),
    ('        }[mode]\n\n    def _private_cover_converged',
     '        }[mode] and (mode == "desktop" or self._mesh_camera_stopped())\n\n    def _private_cover_converged'),
    ('            and not self.hud_running()\n        )\n\n    def _apply_mode',
     '            and not self.hud_running()\n            and self._mesh_camera_stopped()\n        )\n\n    def _apply_mode'),
    ('    def _apply_mode(self, mode: str) -> None:\n',
     '    def _apply_mode(self, mode: str) -> None:\n        if mode != "desktop":\n            self._mesh_camera_revoke("stationDark" if mode == "dark" else "stationMode", wait=mode != "dark")\n'),
    (OLD_COVER, NEW_COVER),
    ('    def _display_camera(self) -> None:\n',
     '    def _display_camera(self) -> None:\n        self._mesh_camera_revoke("stationMode", wait=True)\n'),
    ('    def _display_hud(self) -> None:\n',
     '    def _display_hud(self) -> None:\n        self._mesh_camera_revoke("stationMode", wait=True)\n'),
    (OLD_SHUTDOWN, NEW_SHUTDOWN),
)


def sha256(source):
    return hashlib.sha256(source).hexdigest()


def replace_exact(source, replacements):
    for before, after in replacements:
        if source.count(before) != 1:
            raise ValueError("camera receiver patch anchor mismatch")
        source = source.replace(before, after, 1)
    return source


def patched_source(source):
    text = source.decode("utf-8")
    if sha256(source) != EXPECTED_SOURCE_SHA256:
        try:
            original = replace_exact(text, [(b, a) for a, b in reversed(REPLACEMENTS)])
        except ValueError as error:
            raise ValueError("unrecognized return-patched receiver; review required") from error
        if sha256(original.encode()) != EXPECTED_SOURCE_SHA256 or replace_exact(original, REPLACEMENTS) != text:
            raise ValueError("unrecognized return-patched receiver; review required")
        return source
    result = replace_exact(text, REPLACEMENTS)
    compile(result, "<camera-owner-receiver>", "exec")
    return result.encode()


def prepare(target, output=None):
    fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
            raise ValueError("bounded regular source required")
        original = handle.read(1024 * 1024 + 1)
    if len(original) > 1024 * 1024:
        raise ValueError("source bounds")
    candidate = patched_source(original)
    result = {"patch": PATCH_ID, "source_sha256": sha256(original), "candidate_sha256": sha256(candidate),
        "already_patched": candidate == original, "applied": False, "restart_performed": False,
        "required_module": "mesh_monitor_m1_camera_station.py"}
    if output is None:
        result["diff"] = "".join(difflib.unified_diff(original.decode().splitlines(True), candidate.decode().splitlines(True),
            fromfile=str(target), tofile=str(target) + " (camera candidate)"))
    else:
        fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(candidate); handle.flush(); os.fsync(handle.fileno())
        result["candidate_file"] = str(output)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--output", type=Path, help="write a new candidate file; never overwrite the target")
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.target, args.output), indent=2, sort_keys=True)); return 0
    except (OSError, ValueError) as error:
        parser.exit(1, type(error).__name__ + ": " + str(error) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())

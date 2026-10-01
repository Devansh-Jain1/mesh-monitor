"""Pure synthetic Swift gate tests: no SSH, caffeinate, sensors, button or audio."""
import platform
from pathlib import Path
from datetime import datetime, timezone
import json
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ops/work_mac_copilot_app/MeshM1ReturnTrigger.swift"


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshM1ReturnTests(unittest.TestCase):
    def test_shutdown_acknowledgement_and_owned_transport(self):
        with tempfile.TemporaryDirectory(prefix="mesh-m1-shutdown-") as directory:
            binary = Path(directory) / "fixture"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library", str(SOURCE),
                str(ROOT / "tests/mesh_m1_return_shutdown_fixture.swift"), "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: synthetic M1 disarm acknowledgement", result.stdout)

    def test_synthetic_return_gate(self):
        with tempfile.TemporaryDirectory(prefix="mesh-m1-return-") as directory:
            binary = Path(directory) / "fixture"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshM1ReturnTrigger.swift"),
                str(ROOT / "tests/mesh_m1_return_fixture.swift"), "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: synthetic physical-return", result.stdout)

    def test_remote_script_exact_session_lock_in_isolated_directory(self):
        script = SOURCE.read_text().split('private static let script = #"""', 1)[1].split('"""#', 1)[0]
        compile(script, "isolated-return-script", "exec")
        definitions, operations = script.split("op=sys.argv[1]\n", 1)
        # Execute the actual fixed script with only Path.home redirected to an isolated
        # fixture. No SSH, station service, button, caffeinate, camera, or audio is used.
        runner = f"""
import sys,time
from pathlib import Path
from contextlib import contextmanager
home=Path(sys.argv[1]);operation=sys.argv[2];hold=sys.argv[3]=='hold'
Path.home=classmethod(lambda cls:home)
space={{'__name__':'__main__'}}
exec({definitions!r},space)
original_read=space['read_private'];original_lock=space['marker_lock']
def observed_read(path,limit):
 value=original_read(path,limit)
 if hold and path==space['marker']:
  (home/'read-started').write_text('read')
  deadline=time.monotonic()+5
  while not (home/'release-read').exists():
   if time.monotonic()>deadline:raise TimeoutError('fixture release timeout')
   time.sleep(.01)
 return value
@contextmanager
def observed_lock(*args,**kwargs):
 if operation=='arm':(home/'arm-attempted').write_text('attempt')
 with original_lock(*args,**kwargs):yield
space['read_private']=observed_read;space['marker_lock']=observed_lock
sys.argv=['fixture',operation]
exec('op=sys.argv[1]\\n'+{operations!r},space)
"""
        with tempfile.TemporaryDirectory(prefix="mesh-m1-marker-") as directory:
            home = Path(directory)
            station = home / "AIYStation"
            station.mkdir()
            (station / "m1_station_receiver.py").write_text("# MESH_MONITOR_RETURN_HOOK_V1\n")
            marker = home / ".config/mesh-monitor/morning-return.json"
            lock = marker.with_name("morning-return.lock")
            def record(session):
                now = time.time()
                return {"schema_version": 1, "armed": True, "session_id": session,
                        "intended_date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                        "time_zone": "UTC", "created_at": now, "expires_at": now + 3600,
                        "pi_name": "fixture-pi", "pi_addresses": ["127.0.0.1"]}
            def command(operation, hold=False):
                return ["/usr/bin/python3", "-I", "-c", runner, str(home), operation, "hold" if hold else "normal"]
            def run(operation, payload):
                result = subprocess.run(command(operation), input=json.dumps(payload), capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout), {"ok": True})
            def wait_for(path):
                deadline = time.monotonic() + 3
                while not path.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(path.exists(), str(path))

            old, new = str(uuid.uuid4()), str(uuid.uuid4())
            run("disarm", {"session_id": old})
            self.assertFalse(marker.parent.exists(), "no-op disarm does not create a remote setup")
            run("arm", record(old))
            lock_inode = lock.stat().st_ino
            self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
            disarm = subprocess.Popen(command("disarm", hold=True), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            newer_arm = None
            try:
                disarm.stdin.write(json.dumps({"session_id": old})); disarm.stdin.close(); disarm.stdin = None
                wait_for(home / "read-started")
                (home / "arm-attempted").unlink()
                newer_arm = subprocess.Popen(command("arm"), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                newer_arm.stdin.write(json.dumps(record(new))); newer_arm.stdin.close(); newer_arm.stdin = None
                wait_for(home / "arm-attempted")
                with self.assertRaises(subprocess.TimeoutExpired):
                    newer_arm.communicate(timeout=.15)
                self.assertEqual(json.loads(marker.read_text())["session_id"], old, "newer arm waits while old disarm owns the lock")
                (home / "release-read").write_text("release")
                for process in [disarm, newer_arm]:
                    stdout, stderr = process.communicate(timeout=3)
                    self.assertEqual(process.returncode, 0, stdout + stderr)
                    self.assertEqual(json.loads(stdout), {"ok": True})
                self.assertEqual(json.loads(marker.read_text())["session_id"], new, "old cleanup cannot unlink the newer arm")
                self.assertEqual(lock.stat().st_ino, lock_inode, "cooperating operations retain one stable lock inode")
                run("disarm", {"session_id": old})
                self.assertEqual(json.loads(marker.read_text())["session_id"], new)
                run("disarm", {"session_id": new})
                self.assertFalse(marker.exists())
                self.assertEqual(lock.stat().st_ino, lock_inode, "disarm never unlinks its lock")
            finally:
                (home / "release-read").write_text("release")
                for process in [disarm, newer_arm]:
                    if process is not None and process.poll() is None:
                        process.terminate(); process.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()

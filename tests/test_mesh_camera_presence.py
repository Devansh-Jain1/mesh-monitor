"""Behavioral tests compile only a tiny harness; no app, model, camera, or network is started."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift frameworks required")
class MeshCameraPresenceTests(unittest.TestCase):
    def test_presence_and_gaze_contracts_without_hardware(self):
        with tempfile.TemporaryDirectory(prefix="mesh-camera-tests-") as directory:
            output = Path(directory) / "harness"
            build = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "module-cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshCameraPresence.swift"),
                str(ROOT / "ops/work_mac_copilot_app/MeshManagedCameraConnection.swift"),
                str(ROOT / "tests/mesh_camera_presence_harness.swift"), "-o", str(output),
            ], text=True, capture_output=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(output)], text=True, capture_output=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS: sensor-free", run.stdout)


if __name__ == "__main__":
    unittest.main()

"""Offline setup state/launch-routing tests; compile but never execute the real helper."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class CameraPermissionSetupTests(unittest.TestCase):
    def test_permission_lifecycle_and_mode_isolation(self):
        with tempfile.TemporaryDirectory(prefix="mesh-camera-permission-") as directory:
            folder = Path(directory)
            base = ["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(folder / "cache"),
                    "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                    str(ROOT / "ops/mesh_monitor_camera_snapshot.swift")]
            # The actual helper must compile; never run it, including its setup UI.
            helper = folder / "helper-compile-only"
            build = subprocess.run(base + ["-o", str(helper)], capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            fixture = folder / "fixture"
            build = subprocess.run(base + ["-D", "MESH_SNAPSHOT_TEST",
                str(ROOT / "tests/mesh_camera_permission_fixture.swift"), "-o", str(fixture)],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(fixture)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("injected providers only, no AppKit launch, camera, TCC, audio, or listeners", run.stdout)


if __name__ == "__main__":
    unittest.main()

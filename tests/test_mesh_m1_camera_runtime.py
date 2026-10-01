"""Real coordinator with fake transport/health only; never connects to SSH or a sensor."""
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class ManagedRuntimeTests(unittest.TestCase):
    def test_session_ownership_and_cancellation(self):
        with tempfile.TemporaryDirectory(prefix="mesh-m1-camera-runtime-") as folder:
            folder = pathlib.Path(folder)
            sources = [ROOT / "ops/work_mac_copilot_app" / name for name in (
                "MeshManagedCameraConnection.swift", "MeshM1CameraRuntime.swift", "MeshM1CameraSSH.swift")]
            build = subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(folder / "cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library", *map(str, sources),
                str(ROOT / "tests/mesh_m1_camera_runtime_fixture.swift"), "-o", str(folder / "fixture")],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(folder / "fixture")], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("no SSH, camera or audio", run.stdout)


if __name__ == "__main__":
    unittest.main()

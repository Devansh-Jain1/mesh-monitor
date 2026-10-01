"""Pure authenticated response verification and synthetic JPEG decode; no network or sensors."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshManagedCameraTests(unittest.TestCase):
    def test_authenticated_snapshot_and_health_contract(self):
        with tempfile.TemporaryDirectory(prefix="mesh-managed-client-tests-") as directory:
            output = Path(directory) / "fixture"
            build = subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshManagedCameraConnection.swift"),
                str(ROOT / "tests/mesh_managed_camera_fixture.swift"), "-o", str(output),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(output)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("synthetic bytes only; no network, camera, TCC or audio", result.stdout)


if __name__ == "__main__":
    unittest.main()

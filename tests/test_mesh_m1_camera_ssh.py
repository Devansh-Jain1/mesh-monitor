"""Local fake children + URLProtocol interception only; never SSH or a network socket."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshM1CameraSSHTests(unittest.TestCase):
    def test_owned_transport_and_bounded_health_without_network(self):
        with tempfile.TemporaryDirectory(prefix="mesh-m1-transport-tests-") as directory:
            folder = Path(directory)
            sources = ROOT / "ops/work_mac_copilot_app"
            command = ["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(folder / "cache"),
                       "-target", "arm64-apple-macosx14.0", "-parse-as-library"]
            command += [str(sources / name) for name in ["MeshManagedCameraConnection.swift", "MeshM1CameraRuntime.swift", "MeshM1CameraSSH.swift"]]
            command += [str(ROOT / "tests/mesh_m1_camera_ssh_fixture.swift"), "-o", str(folder / "fixture")]
            build = subprocess.run(command, text=True, capture_output=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(folder / "fixture")], text=True, capture_output=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS: M1 transport fake children", run.stdout)


if __name__ == "__main__":
    unittest.main()

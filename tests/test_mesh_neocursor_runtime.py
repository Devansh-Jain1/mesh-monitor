"""Compile a sensor-free native lifecycle harness; its only child is a synthetic stdlib script."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift frameworks required")
class MeshNeoCursorRuntimeTests(unittest.TestCase):
    def test_private_configuration_and_owned_process_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="mesh-neocursor-native-") as directory:
            binary = Path(directory) / "fixture"
            build = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "module-cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshNeoCursorRuntime.swift"),
                str(ROOT / "tests/mesh_neocursor_runtime_fixture.swift"), "-o", str(binary),
            ], text=True, capture_output=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary)], text=True, capture_output=True, timeout=25)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS: sensor-free NeoCursor runtime", run.stdout)


if __name__ == "__main__":
    unittest.main()

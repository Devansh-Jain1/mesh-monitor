"""Synthetic reducer test; does not instantiate NSWorkspace observation or inspect apps."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshFocusActivityTests(unittest.TestCase):
    def test_synthetic_application_timing(self):
        with tempfile.TemporaryDirectory(prefix="mesh-focus-activity-") as directory:
            binary = Path(directory) / "fixture"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshFocusActivity.swift"),
                str(ROOT / "tests/mesh_focus_activity_fixture.swift"), "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: synthetic", result.stdout)


if __name__ == "__main__":
    unittest.main()

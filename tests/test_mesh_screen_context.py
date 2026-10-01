"""Foreground capture eligibility compiles the real source; fixture uses metadata only."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshScreenContextTests(unittest.TestCase):
    def test_accessory_foreground_and_capture_selection_boundaries(self):
        with tempfile.TemporaryDirectory(prefix="mesh-screen-context-fixture-") as directory:
            binary = Path(directory) / "fixture"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macos14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshScreenGeometry.swift"),
                str(ROOT / "ops/work_mac_copilot_app/MeshScreenContext.swift"),
                str(ROOT / "tests/mesh_screen_context_fixture.swift"),
                "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("offline screen selection checks; no capture, inputs, app launch, or workspace observation", result.stdout)


if __name__ == "__main__":
    unittest.main()

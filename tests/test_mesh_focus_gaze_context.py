"""Opt-in background gaze projection uses real source types and synthetic values only."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshFocusGazeContextTests(unittest.TestCase):
    def test_optional_matched_fresh_gaze_projection(self):
        with tempfile.TemporaryDirectory(prefix="mesh-focus-gaze-fixture-") as directory:
            binary = Path(directory) / "fixture"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macos14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshCameraPresence.swift"),
                str(ROOT / "ops/work_mac_copilot_app/MeshManagedCameraConnection.swift"),
                str(ROOT / "ops/work_mac_copilot_app/MeshScreenGeometry.swift"),
                str(ROOT / "ops/work_mac_copilot_app/MeshFocusGazeContext.swift"),
                str(ROOT / "tests/mesh_focus_gaze_context_fixture.swift"),
                "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("offline optional focus gaze fixtures; no inputs, imports, or runtime actions", result.stdout)


if __name__ == "__main__":
    unittest.main()

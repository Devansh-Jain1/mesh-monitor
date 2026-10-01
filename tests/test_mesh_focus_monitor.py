"""Synthetic focus-loop and private journal tests; no model, screenshot, audio or network."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshFocusMonitorTests(unittest.TestCase):
    def test_continuous_loop_cancellation_feedback_and_review(self):
        with tempfile.TemporaryDirectory(prefix="mesh-focus-monitor-") as directory:
            binary = Path(directory) / "fixture"
            build = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshFocusMonitor.swift"),
                str(ROOT / "tests/mesh_focus_monitor_fixture.swift"), "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=25)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS: synthetic focus", run.stdout)


if __name__ == "__main__":
    unittest.main()

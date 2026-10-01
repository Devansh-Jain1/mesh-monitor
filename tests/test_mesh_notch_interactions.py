"""Exercise the hosted notch in unshown windows, with inert callbacks and no OS input events."""
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS SwiftUI/AppKit required")
class MeshNotchInteractionTests(unittest.TestCase):
    def test_hosted_controls_and_hit_routing_without_presentation(self):
        with tempfile.TemporaryDirectory(prefix="mesh-notch-interaction-") as directory:
            temporary = Path(directory)
            # Production views remain private; no test-only visibility change.
            source = temporary / "HostedFixture.swift"
            source.write_text(
                (ROOT / "ops/work_mac_copilot_app/MeshNotchController.swift").read_text()
                + "\n" + (ROOT / "tests/mesh_notch_interaction_fixture.swift").read_text()
            )
            binary = temporary / "fixture"
            build = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(temporary / "module-cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library", str(source), "-o", str(binary),
            ], text=True, capture_output=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary)], text=True, capture_output=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS: hosted notch interaction in 4 layouts", run.stdout)
            receipt = json.loads(run.stdout.strip().splitlines()[-1])
            self.assertTrue(receipt["windowsCreated"])
            self.assertEqual(receipt["windowCount"], 5)
            self.assertFalse(receipt["windowsPresented"])
            self.assertTrue(receipt["panelsCreated"])
            for field in ["syntheticOSEvents", "sensorsStarted", "audioPlayed"]:
                self.assertFalse(receipt[field])


if __name__ == "__main__":
    unittest.main()

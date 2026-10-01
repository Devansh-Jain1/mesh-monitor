"""Pure connection/microphone handoff tests; never create any real input or client."""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(platform.system() == "Darwin", "Swift/macOS required")
class VoiceStartTests(unittest.TestCase):
    def test_owned_start_cancel_and_late_callbacks(self):
        with tempfile.TemporaryDirectory(prefix="mesh-voice-start-") as directory:
            binary = Path(directory) / "fixture"
            build = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                "-module-cache-path", str(Path(directory) / "cache"),
                str(ROOT / "ops/work_mac_copilot_app/MeshVoiceStart.swift"),
                str(ROOT / "tests/mesh_voice_start_fixture.swift"), "-o", str(binary)],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: owned Talk startup", result.stdout)

if __name__ == "__main__":
    unittest.main()

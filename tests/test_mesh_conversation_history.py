"""Production text-history persistence using synthetic files, with no app/runtime."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshConversationHistoryTests(unittest.TestCase):
    def test_private_bounded_restart_history(self):
        with tempfile.TemporaryDirectory(prefix="mesh-history-fixture-") as directory:
            binary = Path(directory) / "fixture"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-swift-version", "6", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshConversationHistory.swift"),
                str(ROOT / "tests/mesh_conversation_history_fixture.swift"),
                "-o", str(binary),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary), str(Path(directory).resolve() / "storage")], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS 46 offline conversation history fixtures; synthetic temporary files only", result.stdout)


if __name__ == "__main__":
    unittest.main()

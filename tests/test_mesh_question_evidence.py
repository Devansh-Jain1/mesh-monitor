"""Pure evidence formatting and production input serialization; no agent or sensors."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class MeshQuestionEvidenceTests(unittest.TestCase):
    def test_multibyte_and_escaping_budgets(self):
        with tempfile.TemporaryDirectory(prefix="mesh-question-evidence-") as directory:
            binary = Path(directory) / "fixture"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/MeshQuestionEvidence.swift"),
                str(ROOT / "ops/work_mac_copilot_app/MeshCodexClient.swift"),
                str(ROOT / "tests/mesh_question_evidence_fixture.swift"), "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: dense multibyte", result.stdout)


if __name__ == "__main__":
    unittest.main()

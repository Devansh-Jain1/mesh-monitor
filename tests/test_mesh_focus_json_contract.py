"""Production focus JSON contract with protocol shims; no models, sensors or network."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(
    platform.system() == "Darwin" and platform.machine() == "arm64" and shutil.which("xcrun"),
    "Apple Silicon macOS Swift required",
)
class MeshFocusJSONContractTests(unittest.TestCase):
    def test_schema_and_response_validation(self):
        with tempfile.TemporaryDirectory(prefix="mesh-focus-json-contract-") as directory:
            binary = Path(directory) / "fixture"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                "-target", "arm64-apple-macos14.0", "-D", "M4_LOCAL_VOICE_SESSION",
                "-parse-as-library",
                str(ROOT / "ops/work_mac_copilot_app/M4LFMVisionBrain.swift"),
                str(ROOT / "tests/mesh_focus_json_contract_fixture.swift"),
                "-framework", "AppKit", "-framework", "ApplicationServices", "-framework", "Vision", "-framework", "ImageIO",
                "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS 28 offline focus JSON contract fixtures", result.stdout)
            self.assertIn("PASS 19 offline focus image budget fixtures", result.stdout)


if __name__ == "__main__":
    unittest.main()

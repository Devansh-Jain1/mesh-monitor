"""Silent checks for reminder deadlines and stop/snooze behavior; no real timers or windows."""
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(platform.system() == "Darwin", "macOS native coach")
class FocusCoachTests(unittest.TestCase):
    def test_schedule(self):
        with tempfile.TemporaryDirectory(prefix="mesh-coach-test-") as directory:
            root = Path(directory)
            source = root / "Fixture.swift"
            source.write_text((ROOT / "ops/work_mac_copilot_app/MeshFocusCoach.swift").read_text() + "\n" + (ROOT / "tests/mesh_focus_coach_fixture.swift").read_text())
            result = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(root / "cache"), str(source), "-o", str(root / "fixture")], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr)
            run = subprocess.run([str(root / "fixture")], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("PASS: coaching deadlines", run.stdout)

class RecoveryLaunchAgentTests(unittest.TestCase):
    def test_recovery_only_while_explicit_intent_exists(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("recovery", ROOT / "ops/install_mesh_focus_recovery.py")
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        home = Path("/fixture/home")
        config = module.configuration(home)
        self.assertEqual(config["KeepAlive"], {"PathState": {str(home / "Library/Application Support/MeshMonitor/focus-recovery.json"): True}})
        self.assertFalse(config["RunAtLoad"])
        self.assertEqual(config["ProgramArguments"][1:], ["--recover-focus-session"])
        self.assertEqual(config["LimitLoadToSessionType"], "Aqua")

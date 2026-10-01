"""Managed helper protocol tests; fake backend plus inert invalid/EOF CLI only."""
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "macOS Swift required")
class ManagedSnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="mesh-managed-camera-tests-")
        cls.addClassCleanup(cls.directory.cleanup)
        folder = Path(cls.directory.name)
        cls.helper, cls.fixture = folder / "helper", folder / "fixture"
        base = ["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(folder / "cache"),
                "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                str(ROOT / "ops/mesh_monitor_camera_snapshot.swift")]
        for command in [base + ["-o", str(cls.helper)], base + ["-D", "MESH_SNAPSHOT_TEST",
                str(ROOT / "tests/mesh_snapshot_managed_fixture.swift"), "-o", str(cls.fixture)]]:
            build = subprocess.run(command, capture_output=True, text=True, timeout=90)
            if build.returncode:
                raise AssertionError(build.stdout + build.stderr)

    def test_mock_lifecycle_authentication_and_expiry(self):
        run = subprocess.run([str(self.fixture)], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("mock backends only; no camera, TCC or listeners", run.stdout)

    def test_real_managed_empty_eof_is_inert(self):
        run = subprocess.run([str(self.helper), "--managed"], input="", capture_output=True, text=True, timeout=5)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        receipts = [json.loads(line) for line in run.stdout.splitlines()]
        self.assertEqual([r["event"] for r in receipts], ["stopping", "stopped"])
        self.assertTrue(all(not r["captureActive"] and "identity" not in r for r in receipts))
        self.assertEqual(receipts[-1]["reason"], "parentEOF")

    def test_real_invalid_input_and_oversize_never_prepare(self):
        for text in ["{}\n", "not json\n", "x" * 4097]:
            run = subprocess.run([str(self.helper), "--managed"], input=text, capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
            receipts = [json.loads(line) for line in run.stdout.splitlines()]
            self.assertEqual(receipts[-1]["reason"], "invalidCommand")
            self.assertTrue(all("identity" not in r and not r["captureActive"] for r in receipts))

    def test_managed_rejects_file_stdin_and_mixed_arm_arguments(self):
        with tempfile.TemporaryFile() as source:
            run = subprocess.run([str(self.helper), "--managed"], stdin=source, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 2)
        self.assertEqual(run.stdout, b"")
        run = subprocess.run([str(self.helper), "--managed", "--arm"], input=b"", capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 2)
        self.assertEqual(run.stdout, b"")


if __name__ == "__main__":
    unittest.main()

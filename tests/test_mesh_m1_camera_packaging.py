"""Offline packaging fixtures: fake compiler/signing, no built helper execution or sensors."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = load("m1_camera_packaging_fixture", ROOT / "ops/build_mesh_monitor_m1_camera.py")
returns = load("m1_camera_return_fixture", ROOT / "ops/mesh_monitor_m1_return_patch.py")


class FakeTools:
    def __init__(self, mutate=None, fail_sign=False):
        self.commands = []
        self.mutate = mutate
        self.fail_sign = fail_sign
        self.compiled = None

    def __call__(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == "/usr/bin/xcrun":
            self.compiled = Path(command[-3]).read_bytes()
            Path(command[-1]).write_bytes(b"fixture: never executable helper")
            if self.mutate:
                self.mutate()
            return ""
        if command[0] == "/usr/bin/codesign":
            if self.fail_sign and "--sign" in command:
                raise RuntimeError("fixture sign failure")
            if "--entitlements" in command and "--display" in command:
                return plistlib.dumps(builder.ENTITLEMENTS).decode()
            return "Identifier=" + builder.BUNDLE_ID + "\nfixture signature metadata"
        raise AssertionError("Unexpected tool or attempted helper execution: " + repr(command))


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mesh-m1-package-fixture-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source"
        self.root.mkdir()
        for name in builder.INPUTS:
            target = self.root / name
            target.parent.mkdir(exist_ok=True, parents=True)
            target.write_bytes((ROOT / name).read_bytes())
        self.output = self.root / "artifacts/package"
        self.tools = FakeTools()

    def build(self, **kwargs):
        path = builder.build(self.root, self.output, runner=self.tools, **kwargs)
        receipt = json.loads(path.read_bytes())
        self.addCleanup(shutil.rmtree, Path(receipt["verified_staging_app"]).parent, True)
        return receipt

    def test_complete_signed_bundle_shape_snapshot_and_no_sensor_commands(self):
        receipt = self.build()
        app = Path(receipt["verified_staging_app"])
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], builder.BUNDLE_ID)
        self.assertTrue(info["LSUIElement"])
        self.assertNotIn("NSMicrophoneUsageDescription", info)
        self.assertIsNone(receipt["setup_candidates"])
        self.assertFalse(any(receipt["verification"][k] for k in receipt["verification"] if k != "compiled"))
        self.assertEqual(receipt["signing"]["entitlements"], {"com.apple.security.device.camera": True})
        sign = next(c for c in self.tools.commands if "--sign" in c)
        self.assertEqual(sign[sign.index("--options") + 1], "runtime")
        self.assertIn("--strict", self.tools.commands[2])
        self.assertTrue(all(c[0] in ("/usr/bin/xcrun", "/usr/bin/codesign") for c in self.tools.commands))
        self.assertEqual(stat.S_IMODE((app / "Contents/MacOS" / builder.EXECUTABLE).stat().st_mode), 0o700)
        for record in receipt["sources"]:
            data = (self.output / "source-snapshot" / record["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), record["sha256"])
        with zipfile.ZipFile(self.output / receipt["archive"]["path"]) as package:
            self.assertEqual(sorted(package.namelist()), sorted(r["path"] for r in receipt["files"]))
            for record in receipt["files"]:
                self.assertEqual(hashlib.sha256(package.read(record["path"])).hexdigest(), record["sha256"])

    def test_compiler_uses_frozen_bytes_when_live_source_changes(self):
        source = self.root / "ops/mesh_monitor_camera_snapshot.swift"
        before = source.read_bytes()
        self.tools.mutate = lambda: source.write_bytes(b"changed after snapshot")
        receipt = self.build()
        self.assertEqual(self.tools.compiled, before)
        saved = next(r for r in receipt["sources"] if r["path"].endswith("snapshot.swift"))
        self.assertEqual(saved["sha256"], hashlib.sha256(before).hexdigest())

    def exact_receiver(self):
        original = (ROOT / "tests/fixtures/mesh_monitor_m1_receiver_original.py.txt").read_bytes()
        path = Path(self.temp.name) / "receiver.py"
        # Existing return patch exports patched_source, shared with production preparation.
        path.write_bytes(returns.patched_source(original))
        return path

    def test_exact_receiver_device_and_intended_path_make_private_offline_candidates(self):
        receiver = self.exact_receiver()
        original = receiver.read_bytes()
        intended = "/Users/camera-owner/Applications/" + builder.APP_NAME
        receipt = self.build(receiver=receiver, camera_id="EXACT_EXTERNAL_CAMERA_ID", m1_app=intended)
        setup = receipt["setup_candidates"]
        self.assertFalse(setup["applied"])
        self.assertEqual(receiver.read_bytes(), original)
        config = json.loads((self.output / "setup-candidates/camera-station.candidate.json").read_bytes())
        self.assertEqual(config["helperExecutable"], intended + "/Contents/MacOS/" + builder.EXECUTABLE)
        self.assertEqual(config["helperSHA256"], receipt["helper_executable_sha256"])
        self.assertEqual(config["cameraID"], "EXACT_EXTERNAL_CAMERA_ID")
        self.assertEqual(set(config), {"schema", "helperExecutable", "helperSHA256", "cameraID", "port"})
        self.assertTrue(all(record["mode"] == "0o600" for record in setup["files"]))
        self.assertNotEqual(setup["receiver_source_sha256"], setup["receiver_candidate_sha256"])
        self.assertFalse(Path(intended).exists())

    def test_partial_or_malformed_setup_refused_before_tool_calls(self):
        for kwargs in [dict(camera_id="exact"), dict(receiver=Path("/missing")),
                dict(receiver=Path("/missing"), camera_id="bad\nID", m1_app="/Users/x/" + builder.APP_NAME),
                dict(receiver=Path("/missing"), camera_id="exact", m1_app="/Users/x/../" + builder.APP_NAME),
                dict(receiver=Path("/missing"), camera_id="exact", m1_app="relative/" + builder.APP_NAME),
                dict(port=True), dict(port=0), dict(signing_identity="automatic identity")]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.build(**kwargs)
        self.assertEqual(self.tools.commands, [])
        self.assertFalse(self.output.exists())

    def test_unknown_receiver_refused_without_build_or_candidate(self):
        receiver = Path(self.temp.name) / "unknown.py"
        receiver.write_bytes(b"# unrelated receiver\n")
        with self.assertRaises(ValueError):
            self.build(receiver=receiver, camera_id="exact", m1_app="/Users/x/" + builder.APP_NAME)
        self.assertEqual(self.tools.commands, [])
        self.assertFalse((self.output / "BUILD-RECEIPT.json").exists())
        self.assertFalse((self.output / "setup-candidates").exists())

    def test_no_overwrite_symlink_or_wrong_bundle_identity(self):
        self.output.mkdir(parents=True)
        marker = self.output / "preserve"; marker.write_bytes(b"original")
        with self.assertRaises(ValueError): self.build()
        self.assertEqual(marker.read_bytes(), b"original")
        shutil.rmtree(self.output)
        source = self.root / "ops/mesh_monitor_camera_snapshot.swift"
        source.unlink(); source.symlink_to(ROOT / "ops/mesh_monitor_camera_snapshot.swift")
        with self.assertRaises(OSError): self.build()
        source.unlink(); source.write_bytes(b"fixture")
        plist = self.root / "ops/MeshMonitorM1Camera-Info.plist"
        info = plistlib.loads(plist.read_bytes()); info["CFBundleIdentifier"] = "wrong"
        plist.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError): self.build()
        self.assertEqual(self.tools.commands, [])

    def test_signing_failure_has_no_success_receipt_or_deployment(self):
        self.tools.fail_sign = True
        with self.assertRaisesRegex(RuntimeError, "fixture sign failure"):
            self.build()
        self.assertFalse((self.output / "BUILD-RECEIPT.json").exists())
        self.assertTrue((self.output / "BUILD-FAILED.txt").is_file())
        sign = next(c for c in self.tools.commands if "--sign" in c)
        self.assertFalse(Path(sign[-1]).exists())


if __name__ == "__main__":
    unittest.main()

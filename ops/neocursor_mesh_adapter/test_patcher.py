"""Synthetic application tests. No real NeoCursor assets, Electron, or sensors.

The fixture creates an unrelated temporary Git history and injects its own pin
and hash catalog. Passing these tests is not actual upstream asset preflight.
"""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("mesh_observer_patcher", Path(__file__).with_name("patcher.py"))
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


class PatcherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mesh-neocursor-patcher-fixture-", dir="/private/tmp" if Path("/private/tmp").exists() else None)
        self.base = Path(self.temp.name).resolve()
        self.checkout = self.base / "checkout"
        self.checkout.mkdir(mode=0o700)
        self.glue = self.base / "original-glue"
        self.glue.mkdir(mode=0o700)
        self.sources = {}
        self.assets = {}
        for name in patcher.SOURCE_SHA256:
            data = ("synthetic upstream fixture; not real NeoCursor: " + name + "\n").encode()
            (self.checkout / name).write_bytes(data)
            self.sources[name] = patcher._sha(data)
        for name in patcher.ASSET_BLOBS:
            data = ("synthetic inert asset: " + name + "\n").encode()
            file = self.checkout / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
            self.assets[name] = (len(data), patcher._blob(data))
        for name in patcher.OVERLAY_FILES:
            (self.glue / name).write_text("original synthetic Mesh glue fixture: " + name + "\n")
        self.git("init", "--quiet")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Synthetic Fixture")
        self.git("config", "commit.gpgsign", "false")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "synthetic test only")
        self.pin = self.git("rev-parse", "HEAD").strip()
        self.patches = [patch.object(patcher, "PIN", self.pin),
                        patch.object(patcher, "SOURCE_SHA256", self.sources),
                        patch.object(patcher, "ASSET_BLOBS", self.assets)]
        for item in self.patches:
            item.start()
        self.addCleanup(self.temp.cleanup)
        for item in self.patches:
            self.addCleanup(item.stop)

    def git(self, *args):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
                   GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
        return subprocess.run(["git", "-c", "core.hooksPath=" + os.devnull, "-C", str(self.checkout), *args],
                              check=True, capture_output=True, text=True, timeout=10, env=env).stdout

    def run_prepare(self, apply=False):
        return patcher.prepare(self.checkout, self.glue, apply=apply)

    @property
    def destination(self):
        return self.checkout / patcher.OVERLAY_DIRECTORY

    def test_preflight_is_read_only_and_does_not_require_electron(self):
        before = self.git("status", "--porcelain")
        result = self.run_prepare()
        self.assertEqual(result["action"], "preflight")
        self.assertFalse(result["electronAvailable"])
        self.assertFalse(result["started"])
        self.assertFalse(result["installedDependencies"])
        self.assertFalse(self.destination.exists())
        self.assertEqual(before, self.git("status", "--porcelain"))

    def test_apply_copies_only_original_glue_and_preserves_upstream(self):
        original = {name: (self.checkout / name).read_bytes() for name in self.sources}
        result = self.run_prepare(apply=True)
        self.assertEqual(result["action"], "applied")
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o700)
        expected = set(patcher.OVERLAY_FILES) | {"package.json", "manifest.json", "READY"}
        self.assertEqual({file.name for file in self.destination.iterdir()}, expected)
        for file in self.destination.iterdir():
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
            self.assertEqual(file.stat().st_nlink, 1)
        for name, data in original.items():
            self.assertEqual((self.checkout / name).read_bytes(), data)
        for name in patcher.OVERLAY_FILES:
            self.assertEqual((self.destination / name).read_bytes(), (self.glue / name).read_bytes())
        manifest_bytes = (self.destination / "manifest.json").read_bytes()
        self.assertEqual((self.destination / "READY").read_text().strip(), patcher._sha(manifest_bytes))
        manifest = json.loads(manifest_bytes)
        self.assertEqual(manifest["upstream"]["commit"], self.pin)
        self.assertEqual(manifest["engine"]["faceMeshScript"], str(self.checkout / "mediapipe/face_mesh.js"))
        self.assertEqual(manifest["overlay"]["entry"], "observer-main.cjs")
        self.assertEqual(json.loads((self.destination / "package.json").read_bytes())["main"], "observer-main.cjs")
        self.assertEqual(result["launchArgv"], [str(self.checkout / "node_modules/.bin/electron"), str(self.destination)])
        self.assertEqual(self.git("diff", "--name-only"), "")

    def test_existing_overlay_preflight_allowed_but_apply_never_overwrites(self):
        self.run_prepare(apply=True)
        before = {f.name: f.read_bytes() for f in self.destination.iterdir()}
        self.assertTrue(self.run_prepare()["overlayAlreadyExists"])
        with self.assertRaisesRegex(patcher.PreflightError, "already exists"):
            self.run_prepare(apply=True)
        self.assertEqual(before, {f.name: f.read_bytes() for f in self.destination.iterdir()})

    def test_wrong_revision_rejected(self):
        with patch.object(patcher, "PIN", "0" * 40):
            with self.assertRaisesRegex(patcher.PreflightError, "exactly"):
                self.run_prepare(apply=True)
        self.assertFalse(self.destination.exists())

    def test_dirty_tracked_source_rejected_without_mutation(self):
        file = self.checkout / "main.js"
        file.write_text("user-owned edit")
        with self.assertRaisesRegex(patcher.PreflightError, "dirty"):
            self.run_prepare(apply=True)
        self.assertEqual(file.read_text(), "user-owned edit")
        self.assertFalse(self.destination.exists())

    def test_untracked_non_overlay_rejected(self):
        (self.checkout / "user-notes.txt").write_text("preserve")
        with self.assertRaisesRegex(patcher.PreflightError, "dirty"):
            self.run_prepare(apply=True)

    def test_source_sha_mismatch_rejected_even_with_clean_git(self):
        with patch.object(patcher, "SOURCE_SHA256", {**self.sources, "main.js": "0" * 64}):
            with self.assertRaisesRegex(patcher.PreflightError, "source hash mismatch"):
                self.run_prepare()

    def test_asset_git_blob_mismatch_rejected(self):
        first = next(iter(self.assets))
        bad = {**self.assets, first: (self.assets[first][0], "0" * 40)}
        with patch.object(patcher, "ASSET_BLOBS", bad):
            with self.assertRaisesRegex(patcher.PreflightError, "asset mismatch"):
                self.run_prepare()

    def test_symlink_checkout_and_relative_paths_rejected(self):
        alias = self.base / "alias"
        alias.symlink_to(self.checkout, target_is_directory=True)
        with self.assertRaisesRegex(patcher.PreflightError, "Symbolic links"):
            patcher.prepare(alias, self.glue)
        with self.assertRaisesRegex(patcher.PreflightError, "absolute"):
            patcher.prepare(Path("checkout"), self.glue)

    def test_nested_checkout_root_rejected(self):
        with self.assertRaisesRegex(patcher.PreflightError, "exact upstream"):
            patcher.prepare(self.checkout / "mediapipe", self.glue)

    def test_hardlinked_or_symlinked_glue_rejected(self):
        victim = self.glue / "observer-main.cjs"
        hard = self.base / "hard"
        os.link(victim, hard)
        with self.assertRaisesRegex(patcher.PreflightError, "single-link"):
            self.run_prepare()
        hard.unlink()
        victim.unlink()
        victim.symlink_to(self.glue / "observer-preload.cjs")
        with self.assertRaisesRegex(patcher.PreflightError, "Symbolic links"):
            self.run_prepare()

    def test_missing_or_oversized_glue_rejected(self):
        victim = self.glue / "publisher.cjs"
        victim.unlink()
        with self.assertRaisesRegex(patcher.PreflightError, "unavailable"):
            self.run_prepare()
        victim.write_bytes(b"x" * (patcher.MAX_GLUE_BYTES + 1))
        with self.assertRaisesRegex(patcher.PreflightError, "bounded size"):
            self.run_prepare()

    def test_symlink_destination_is_not_followed_or_replaced(self):
        target = self.base / "unrelated"
        target.mkdir()
        marker = target / "preserve"
        marker.write_text("keep")
        self.destination.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(patcher.PreflightError, "already exists"):
            self.run_prepare(apply=True)
        self.assertEqual(marker.read_text(), "keep")
        self.assertTrue(self.destination.is_symlink())

    def test_fsync_failure_before_publication_has_no_ready_overlay(self):
        with patch.object(patcher.os, "fsync", side_effect=OSError("synthetic fsync failure")):
            with self.assertRaisesRegex(OSError, "fsync"):
                self.run_prepare(apply=True)
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.checkout.glob(".mesh-observer-staging-*")))

    def test_interrupted_publication_is_unready_and_not_overwritten(self):
        original = patcher.os.rename
        calls = 0
        def fail_after_one(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("synthetic publication crash")
            original(source, destination)
        with patch.object(patcher.os, "rename", side_effect=fail_after_one):
            with self.assertRaisesRegex(OSError, "publication crash"):
                self.run_prepare(apply=True)
        self.assertTrue(self.destination.exists())
        self.assertFalse((self.destination / "READY").exists())
        with self.assertRaisesRegex(patcher.PreflightError, "already exists"):
            self.run_prepare(apply=True)

    def test_git_fsmonitor_hook_is_never_executed(self):
        hook = self.base / "fsmonitor"
        marker = self.base / "hook-executed"
        hook.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\n")
        hook.chmod(0o700)
        self.git("config", "core.fsmonitor", str(hook))
        self.run_prepare()
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()

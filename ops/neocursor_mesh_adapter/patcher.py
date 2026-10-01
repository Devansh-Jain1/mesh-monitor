#!/usr/bin/env python3
"""Stage original Mesh observer glue beside an explicitly supplied NeoCursor pin.

This command neither downloads nor installs anything and never starts Electron.
The upstream main/renderer/preload files remain unchanged and unexecuted.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import uuid


PIN = "986db45663cf37b6e47e5e355fa1e9ce0d05de76"
SOURCE_SHA256 = {
    "renderer.js": "a8da3501a3df59077b09967ca1938fa5498998ff4b0185ace3a6e7c00c6f7678",
    "preload.js": "9027a56849ea7a9c062bfc01131d5ef4e0d082dc419899c7f5c507ae0f3662c3",
    "main.js": "22c694bff6ba8f08b1df733a1e4161751f958614ddadf95dfb3722aa19364e63",
    "index.html": "d2833557794c6895310cbab944199712427831e7ed05106b3501bfbe0de73d3c",
    "package.json": "5894d0c7f2caefbd56a8afaad32edec31b0dd3e4a0ae072dd962cb03d3b046ba",
    "server.js": "09549f8948c019c582d0265ee69e0aa03366cdd6c2c645b7db4bf6e9c5b4516b",
}
# Git blob identities from the pinned upstream tree, not downloaded/vendor copies.
ASSET_BLOBS = {
    "mediapipe/camera_utils.js": (7881, "8a7df290a653e7dc93915eb7b63e75c9f557b585"),
    "mediapipe/face_mesh.js": (64913, "869a3bc3c1e8b3a63025445b6cfd067a74d51f86"),
    "mediapipe/face_mesh/face_mesh.binarypb": (939, "5151beb521b0945d5866d1f9ac7c578082464d43"),
    "mediapipe/face_mesh/face_mesh_solution_packed_assets.data": (3986256, "855522fa60cd7c75654925370f11c144e6a9c5ea"),
    "mediapipe/face_mesh/face_mesh_solution_packed_assets_loader.js": (8928, "6a0a65b212505276f6e27e1af7acef9b3054dda8"),
    "mediapipe/face_mesh/face_mesh_solution_simd_wasm_bin.js": (330166, "e019722ec201725a765520e225a17877d14ecd9c"),
    "mediapipe/face_mesh/face_mesh_solution_simd_wasm_bin.wasm": (6161697, "41f7701041a01afe2411d47a44dc8b77f8c8601b"),
}
OVERLAY_FILES = (
    "observer-main.cjs", "observer-preload.cjs", "observer-renderer.js",
    "observer.html", "calibration.cjs", "publisher.cjs",
)
OVERLAY_DIRECTORY = ".mesh-observer"
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_GLUE_BYTES = 512 * 1024


class PreflightError(Exception):
    pass


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _blob(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def _path_without_links(path: Path) -> Path:
    if not path.is_absolute() or ".." in path.parts:
        raise PreflightError("Use an absolute path without '..'.")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except OSError as error:
            raise PreflightError(f"Required path is unavailable: {current}") from error
        if stat.S_ISLNK(info.st_mode):
            raise PreflightError(f"Symbolic links are not accepted in source paths: {current}")
    return path


def _read(path: Path, limit: int = MAX_FILE_BYTES) -> bytes:
    _path_without_links(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise PreflightError(f"Expected an owner-owned regular single-link file: {path}")
        if info.st_size > limit:
            raise PreflightError(f"File exceeds the bounded size: {path}")
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(fd, min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(fd)
        if len(data) > limit or (info.st_size, info.st_mtime_ns, info.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
            raise PreflightError(f"File changed during inspection: {path}")
        return data
    finally:
        os.close(fd)


def _git(checkout: Path, *args: str) -> str:
    executable = shutil.which("git")
    if not executable:
        raise PreflightError("Git is required for the read-only pin check.")
    # Do not inherit alternate repositories, indexes, config injection, or hooks.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
                       GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    command = [executable, "--no-optional-locks", "-c", "core.fsmonitor=false",
               "-c", f"core.hooksPath={os.devnull}", "-c", "core.untrackedCache=false",
               "-C", str(checkout), *args]
    try:
        completed = subprocess.run(command, capture_output=True, timeout=10, env=environment)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PreflightError("Read-only Git verification could not complete.") from error
    if completed.returncode or len(completed.stdout) > 262144 or len(completed.stderr) > 32768:
        raise PreflightError("Read-only Git verification failed or exceeded its output bound.")
    return completed.stdout.decode("utf-8", errors="strict").strip()


def inspect_checkout(checkout: Path) -> dict:
    checkout = _path_without_links(checkout)
    info = checkout.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise PreflightError("Checkout must be an owner-owned directory without group/world write access.")
    top = _git(checkout, "rev-parse", "--show-toplevel")
    if top != str(checkout):
        raise PreflightError("Supply the exact upstream Git checkout root.")
    if _git(checkout, "rev-parse", "HEAD") != PIN:
        raise PreflightError(f"NeoCursor HEAD must be exactly {PIN}.")
    # Existing staged Mesh glue is the sole permitted untracked directory.
    dirty = _git(checkout, "status", "--porcelain=v1", "--untracked-files=normal",
                 "--ignore-submodules=none", "--", ".", f":(exclude){OVERLAY_DIRECTORY}")
    if dirty:
        raise PreflightError("Upstream checkout is dirty outside the dedicated Mesh overlay; preserve it and supply a clean checkout.")
    sources = {}
    for name, expected in SOURCE_SHA256.items():
        actual = _sha(_read(checkout / name))
        if actual != expected:
            raise PreflightError(f"Pinned upstream source hash mismatch: {name}")
        sources[name] = actual
    assets = {}
    for name, (size, expected_blob) in ASSET_BLOBS.items():
        data = _read(checkout / name)
        if len(data) != size or _blob(data) != expected_blob:
            raise PreflightError(f"Pinned local MediaPipe asset mismatch: {name}")
        assets[name] = {"sha256": _sha(data), "gitBlob": expected_blob, "size": size}
    return {"commit": PIN, "checkout": str(checkout), "sources": sources, "assets": assets}


def inspect_glue(directory: Path) -> dict[str, bytes]:
    return {name: _read(directory / name, MAX_GLUE_BYTES) for name in OVERLAY_FILES}


def _json(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _write_new(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        view = memoryview(data)
        while view:
            count = os.write(fd, view)
            if count <= 0:
                raise OSError("Short file write")
            view = view[count:]
        os.fsync(fd)
    finally:
        os.close(fd)


def _sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def prepare(checkout: Path, glue_directory: Path, *, apply: bool = False) -> dict:
    upstream = inspect_checkout(checkout)
    glue = inspect_glue(glue_directory)
    destination = checkout / OVERLAY_DIRECTORY
    package = {"name": "mesh-neocursor-observer", "version": "0.1.0", "private": True,
               "description": "Explicit-start observation-only Mesh adapter for a user-supplied NeoCursor runtime",
               "main": "observer-main.cjs"}
    files = dict(glue)
    files["package.json"] = _json(package)
    manifest = {
        "schema": 1, "mode": "observation-only", "upstream": upstream,
        "engine": {"faceMeshScript": str(checkout / "mediapipe/face_mesh.js"),
                   "assetDirectory": str(checkout / "mediapipe/face_mesh")},
        "overlay": {"entry": "observer-main.cjs", "files": {name: _sha(data) for name, data in files.items()}},
    }
    files["manifest.json"] = _json(manifest)
    result = {"ok": True, "action": "applied" if apply else "preflight", "upstreamCommit": PIN,
              "overlay": str(destination), "overlayAlreadyExists": destination.exists() or destination.is_symlink(),
              "electronAvailable": (checkout / "node_modules/.bin/electron").exists(),
              "launchArgv": [str(checkout / "node_modules/.bin/electron"), str(destination)],
              "started": False, "installedDependencies": False, "manifest": manifest}
    if not apply:
        return result
    if destination.exists() or destination.is_symlink():
        raise PreflightError("The Mesh overlay already exists. It will not be overwritten; use a separate clean checkout for this revision.")
    staging = checkout / f".mesh-observer-staging-{uuid.uuid4()}"
    staging.mkdir(mode=0o700)
    try:
        for name, data in files.items():
            _write_new(staging / name, data)
        _sync_directory(staging)
        # Do not silently replace even an empty directory created while staging.
        if destination.exists() or destination.is_symlink():
            raise PreflightError("Overlay destination appeared during staging; no replacement was attempted.")
        # Use an exclusive directory claim. A ready marker is written last; until
        # it exists, the runtime must refuse launch. This avoids rename-overwrite.
        destination.mkdir(mode=0o700)
        for name in files:
            os.rename(staging / name, destination / name)
        _write_new(destination / "READY", (_sha(files["manifest.json"]) + "\n").encode("ascii"))
        _sync_directory(destination)
        _sync_directory(checkout)
        return result
    except Exception:
        # An incomplete destination remains visibly unready on failure. Never
        # remove/overwrite a path another process may have opened or replaced.
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("preflight", "apply"))
    parser.add_argument("--checkout", required=True, type=Path,
                        help="Absolute path to the user's clean pinned NeoCursor checkout")
    args = parser.parse_args(argv)
    try:
        value = prepare(args.checkout, Path(__file__).resolve().parent, apply=args.action == "apply")
        print(json.dumps(value, indent=2, sort_keys=True))
        return 0
    except (PreflightError, OSError, UnicodeError) as error:
        print(json.dumps({"ok": False, "error": str(error), "started": False}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

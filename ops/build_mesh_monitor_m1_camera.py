#!/usr/bin/env python3
"""Build a signed, never-launched M1 camera helper and optional offline setup candidates."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
import zipfile

APP_NAME = "Mesh Monitor M1 Camera.app"
EXECUTABLE = "MeshMonitorM1Camera"
BUNDLE_ID = "com.devansh.mesh-monitor.m1-camera"
VERSION, BUILD = "1.0.1", "2"
TARGET = "arm64-apple-macos14.0"
INPUTS = (
    "ops/mesh_monitor_camera_snapshot.swift",
    "ops/MeshMonitorM1Camera-Info.plist",
    "ops/build_mesh_monitor_m1_camera.py",
    "ops/mesh_monitor_m1_camera_station.py",
    "ops/mesh_monitor_m1_camera_patch.py",
)
ENTITLEMENTS = {"com.apple.security.device.camera": True}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_regular(path: Path, limit: int = 2 * 1024 * 1024) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
            raise ValueError("Expected bounded regular input file")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Input exceeded size bound")
    return data


def write_new(path: Path, data: bytes, mode: int = 0o600) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def run(command: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f"Build command failed ({result.returncode}): {command[0]}\n{result.stderr[:8192]}")
    # codesign display writes its successful metadata to stderr.
    return (result.stdout + result.stderr).strip()


def validate_setup(receiver: Path | None, camera_id: str | None, m1_app: str | None, port: int) -> None:
    supplied = [receiver is not None, camera_id is not None, m1_app is not None]
    if any(supplied) and not all(supplied):
        raise ValueError("Setup candidates require --receiver-source, --camera-id and --m1-app-path together")
    if type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError("Remote port must be 1024 through 65535")
    if not all(supplied):
        return
    if not camera_id or len(camera_id.encode()) > 512 or any(not 33 <= ord(c) <= 126 for c in camera_id):
        raise ValueError("Camera ID must be the exact nonempty external ID, at most 512 visible ASCII bytes")
    path = Path(m1_app)
    if (not path.is_absolute() or path.name != APP_NAME or str(path) != m1_app
            or any(part in (".", "..") for part in path.parts)
            or any(ord(c) < 32 or ord(c) == 127 for c in m1_app)):
        raise ValueError("M1 app path must be an explicit canonical absolute path ending in the fixed app name")


def validate_info(data: bytes) -> dict:
    info = plistlib.loads(data)
    expected = {
        "CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": EXECUTABLE,
        "CFBundleShortVersionString": VERSION, "CFBundleVersion": BUILD,
        "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
    }
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("Helper Info.plist identity does not match this builder")
    description = info.get("NSCameraUsageDescription")
    if not isinstance(description, str) or not description.strip() or "NSMicrophoneUsageDescription" in info:
        raise ValueError("Helper requires a camera purpose string and no microphone purpose")
    return info


def load_patcher(path: Path):
    spec = importlib.util.spec_from_file_location("mesh_camera_packaging_patcher", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build(source: Path, output: Path, *, receiver: Path | None = None,
          camera_id: str | None = None, m1_app: str | None = None, port: int = 18495,
          signing_identity: str = "-", runner=run) -> Path:
    source, output = source.resolve(), output.resolve()
    if not (output.is_relative_to(source / "artifacts") or output.is_relative_to(Path("/private/tmp"))):
        raise ValueError("Build output must be a fresh directory in checkout artifacts/ or /private/tmp/")
    if output.exists():
        raise ValueError("Output already exists; choose a new build directory")
    if signing_identity != "-" and not re.fullmatch(r"[a-fA-F0-9]{40}", signing_identity):
        raise ValueError("Signing identity must be '-' (ad hoc) or an explicit 40-digit certificate SHA-1")
    validate_setup(receiver, camera_id, m1_app, port)
    # Hold exact bytes before copying or invoking the compiler. Never compile a mutable live source.
    inputs = {name: read_regular(source / name) for name in INPUTS}
    validate_info(inputs["ops/MeshMonitorM1Camera-Info.plist"])
    receiver_bytes = read_regular(receiver, 1024 * 1024) if receiver is not None else None
    output.mkdir(parents=True, mode=0o700)
    snapshot = output / "source-snapshot"
    snapshot.mkdir(mode=0o700)
    for name, data in inputs.items():
        target = snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_new(target, data)
    records = [{"path": name, "sha256": digest(data), "bytes": len(data)} for name, data in inputs.items()]
    staging: Path | None = None
    try:
        candidate = None
        if receiver_bytes is not None:
            # Import only the snapshotted, fixed repository patcher. It accepts the exact known receiver only.
            candidate = load_patcher(snapshot / "ops/mesh_monitor_m1_camera_patch.py").patched_source(receiver_bytes)
        staging = Path(tempfile.mkdtemp(prefix="mesh-m1-camera-sign-", dir="/private/tmp"))
        app = staging / APP_NAME
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True, mode=0o700)
        executable = contents / "MacOS" / EXECUTABLE
        write_new(contents / "Info.plist", inputs["ops/MeshMonitorM1Camera-Info.plist"])
        entitlements = output / "camera.entitlements.plist"
        write_new(entitlements, plistlib.dumps(ENTITLEMENTS, sort_keys=True))
        commands = []
        with tempfile.TemporaryDirectory(prefix="mesh-m1-camera-module-cache-", dir="/private/tmp") as cache:
            command = ["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "6",
                "-module-cache-path", cache, "-target", TARGET, "-parse-as-library", "-O",
                str(snapshot / "ops/mesh_monitor_camera_snapshot.swift"), "-o", str(executable)]
            commands.append(command)
            runner(command)
        binary = read_regular(executable, 64 * 1024 * 1024)
        if not binary:
            raise ValueError("Compiler did not produce a helper executable")
        executable.chmod(0o700)
        sign = ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--identifier", BUNDLE_ID,
            "--options", "runtime", "--timestamp=none", "--entitlements", str(entitlements), str(app)]
        commands.append(sign)
        runner(sign)
        verify = ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)]
        commands.append(verify)
        runner(verify)
        signature = runner(["/usr/bin/codesign", "--display", "--verbose=4", "--requirements", "-", str(app)])
        signed_entitlements = runner(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(app)])
        # No command can launch the helper, enumerate devices, contact Station or inspect/alter TCC.
        write_new(output / "SIGNATURE.txt", (signature + "\n").encode())
        write_new(output / "SIGNED-ENTITLEMENTS.txt", (signed_entitlements + "\n").encode())
        binary_hash = digest(read_regular(executable, 64 * 1024 * 1024))
        files = [{"path": str(path.relative_to(staging)), "sha256": digest(read_regular(path, 64 * 1024 * 1024)),
                  "bytes": path.stat().st_size, "mode": oct(stat.S_IMODE(path.stat().st_mode))}
                 for path in sorted(app.rglob("*")) if path.is_file()]
        archive = output / "Mesh Monitor M1 Camera.zip"
        with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_STORED) as package:
            for record in files:
                package.write(staging / record["path"], record["path"])
        archive.chmod(0o600)
        setup = None
        if candidate is not None:
            folder = output / "setup-candidates"
            folder.mkdir(mode=0o700)
            write_new(folder / "receiver-source.py", receiver_bytes)
            write_new(folder / "receiver-camera-candidate.py", candidate)
            write_new(folder / "mesh_monitor_m1_camera_station.py", inputs["ops/mesh_monitor_m1_camera_station.py"])
            config = {"schema": "mesh.m1-camera-station.v1", "helperExecutable": str(Path(m1_app) / "Contents/MacOS" / EXECUTABLE),
                "helperSHA256": binary_hash, "cameraID": camera_id, "port": port}
            write_new(folder / "camera-station.candidate.json", json_bytes(config))
            setup = {"receiver_source_sha256": digest(receiver_bytes), "receiver_candidate_sha256": digest(candidate),
                "receiver_already_patched": candidate == receiver_bytes, "m1_app_path": m1_app,
                "camera_id": camera_id, "port": port, "applied": False,
                "files": [{"path": str(p.relative_to(output)), "sha256": digest(p.read_bytes()), "mode": oct(stat.S_IMODE(p.stat().st_mode))}
                    for p in sorted(folder.iterdir())]}
        receipt = {
            "schema_version": "mesh-monitor-m1-camera-build.v1", "created_at": datetime.now(timezone.utc).isoformat(),
            "bundle_id": BUNDLE_ID, "version": VERSION, "build": BUILD, "target": TARGET,
            "source_root": str(source), "source_snapshot": "source-snapshot", "sources": records,
            "verified_staging_app": str(app), "helper_executable_sha256": binary_hash,
            "archive": {"path": archive.name, "sha256": digest(archive.read_bytes()), "bytes": archive.stat().st_size},
            "signing": {"identity": signing_identity, "kind": "ad_hoc" if signing_identity == "-" else "certificate",
                "signature_verified_at_build": True, "hardened_runtime_requested": True,
                "entitlements": ENTITLEMENTS, "signature_metadata_sha256": digest((signature + "\n").encode())},
            "verification": {"compiled": True, "installed": False, "helper_launched": False,
                "tcc_requested": False, "tcc_responsible_identity_verified": False, "camera_tested": False,
                "station_contacted": False, "receiver_deployed": False},
            "setup_candidates": setup, "commands": commands, "files": files,
            "remaining_gates": ["Attended native permission-window layout and status verification",
                "M1 attended authorization and responsible-process identity", "Exact deployed receiver readback and candidate review",
                "Owned authenticated session and physical stop/Dark/lock/Quit acceptance"],
        }
        receipt_path = output / "BUILD-RECEIPT.json"
        write_new(receipt_path, json_bytes(receipt))
        return receipt_path
    except Exception:
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)
        write_new(output / "BUILD-FAILED.txt", b"Build failed; no success receipt was issued. No helper was launched.\n")
        raise


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Fresh checkout artifacts/ or /private/tmp directory")
    parser.add_argument("--receiver-source", type=Path, help="Exact saved, return-patched receiver; read only")
    parser.add_argument("--camera-id", help="Exact known external camera ID; never enumerate automatically")
    parser.add_argument("--m1-app-path", help="Intended absolute M1 installation path, never used as a write target")
    parser.add_argument("--remote-port", type=int, default=18495)
    parser.add_argument("--sign-identity", default="-", help="Default ad hoc; optional explicit certificate SHA-1")
    args = parser.parse_args()
    output = args.output or root / "artifacts" / ("mesh-m1-camera-package-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:6])
    receipt = build(root, output, receiver=args.receiver_source, camera_id=args.camera_id,
        m1_app=args.m1_app_path, port=args.remote_port, signing_identity=args.sign_identity)
    print(json.dumps({"status": "built_not_installed_or_launched", "receipt": str(receipt)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build Mesh Monitor from a hashed source snapshot; never install or launch it."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import struct
import tempfile
import time
import uuid
import zipfile

APP_NAME = "Mesh Monitor.app"
EXECUTABLE = "MeshMonitor"
BUNDLE_ID = "com.devansh.m4-local-voice-notch"
VERSION = "0.6.23"
BUILD = "35"
SWIFT_SOURCES = (
    "MeshApplicationChrome.swift", "MeshFocusCoach.swift",
    "MeshMonitorApp.swift", "MeshConversationHistory.swift", "MeshTermination.swift", "MeshFocusMonitor.swift", "MeshFocusGazeContext.swift", "MeshScreenContext.swift", "MeshScreenGeometry.swift", "MeshQuestionEvidence.swift", "MeshVoiceBridge.swift", "MeshVoiceStart.swift",
    "M4LFMVisionBrain.swift", "M4ParakeetSpeechInput.swift", "M4ResidentJSONWorker.swift", "M4LocalVoiceSession.swift",
    "MeshCodexClient.swift", "MeshHomeCalendar.swift", "MeshFocusState.swift",
    "MeshMorningState.swift", "MeshCameraPresence.swift", "MeshManagedCameraConnection.swift", "MeshM1CameraRuntime.swift", "MeshM1CameraSSH.swift", "MeshNeoCursorRuntime.swift", "MeshM1AudioOutput.swift", "MeshRuntimeMetrics.swift", "MeshFocusActivity.swift", "MeshM1ReturnTrigger.swift", "MeshControlRoomClient.swift", "MeshWakeSetup.swift", "MeshNotchController.swift", "MeshCaptionCore.swift", "MeshTranscription.swift", "MeshDashboard.swift", "MeshDesignPreview.swift",
)
FRAMEWORKS = ("SwiftUI", "AppKit", "AVFoundation", "CryptoKit", "ScreenCaptureKit", "Vision", "ImageIO", "ApplicationServices", "EventKit")
RESOURCE_NAMES = ("M4ParakeetWorker", "kokoro.onnx", "kokoro-config.json", "af_bella.bin", "kokoro_onnx_worker.py")
NEOCURSOR_FILES = ("README.md", "upstream-seam.md", "patcher.py", "observer-main.cjs", "observer-preload.cjs", "observer-renderer.js", "observer.html", "calibration.cjs", "publisher.cjs")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, cwd: Path | None = None) -> str:
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if completed.returncode:
        raise RuntimeError(f"Command failed ({completed.returncode}): {' '.join(command)}\n{completed.stderr}\n{completed.stdout}")
    return completed.stdout.strip()


def write_icns(iconset: Path, destination: Path) -> None:
    # Modern ICNS elements contain the original lossless PNG at each scale.
    # iconutil decoding verifies this container; encoding is unavailable in some
    # sandboxed/headless macOS sessions despite a valid iconset.
    entries = (
        ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png"),
    )
    chunks = []
    for element, name in entries:
        png = (iconset / name).read_bytes()
        if not png.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"Icon source is not PNG: {name}")
        chunks.append(element.encode("ascii") + struct.pack(">I", len(png) + 8) + png)
    body = b"".join(chunks)
    destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    with tempfile.TemporaryDirectory(prefix="mesh-monitor-icon-check-") as check:
        run(["/usr/bin/iconutil", "--convert", "iconset", "--output", str(Path(check) / "checked.iconset"), str(destination)])


def build(source: Path, output: Path, resource_app: Path) -> Path:
    # Source is always the checkout owning this script; no import from another repository.
    source = source.resolve()
    output = output.resolve()
    if not output.is_relative_to(source / "artifacts"):
        raise ValueError("Build output must be a fresh directory under this checkout's artifacts/.")
    if output.exists():
        raise ValueError(f"Output already exists; choose a fresh directory: {output}")
    app_sources = source / "ops/work_mac_copilot_app"
    source_files = [app_sources / name for name in SWIFT_SOURCES]
    source_files += [app_sources / "Info-MeshMonitor.plist", app_sources / "MeshMonitorIcon.swift", source / "ops/build_mesh_monitor.py", source / "ops/mesh_monitor_m1_audio_receiver.py"]
    source_files += [source / "ops/neocursor_mesh_adapter" / name for name in NEOCURSOR_FILES]
    for path in source_files:
        if not path.is_file():
            raise FileNotFoundError(f"Missing required build source: {path}")
    with (resource_app / "Contents/Info.plist").open("rb") as stream:
        old_info = plistlib.load(stream)
    if old_info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("Resource donor must be the installed M4 voice app with the stable bundle identifier.")
    for name in RESOURCE_NAMES:
        if not (resource_app / "Contents/Resources" / name).is_file():
            raise FileNotFoundError(f"Missing installed runtime resource: {name}")

    output.mkdir(parents=True, mode=0o700)
    snapshot = output / "source-snapshot"
    snapshot.mkdir(mode=0o700)
    revision = run(["git", "rev-parse", "HEAD"], cwd=source)
    branch = run(["git", "branch", "--show-current"], cwd=source)
    source_paths = [str(path.relative_to(source)) for path in source_files]
    source_status = run(["git", "status", "--porcelain=v1", "--untracked-files=all", "--", *source_paths], cwd=source)
    source_records = []
    for path in source_files:
        relative = path.relative_to(source)
        destination = snapshot / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        source_records.append({"path": str(relative), "sha256": sha256(destination), "bytes": destination.stat().st_size})
    # Compilation uses these exact copies, including any uncommitted source changes.
    sources = snapshot / "ops/work_mac_copilot_app"
    # Desktop File Provider can attach FinderInfo to app directories, which
    # prevents signing. Sign an owned temporary bundle before copying the result.
    staging_root = Path(tempfile.mkdtemp(prefix="mesh-monitor-sign-", dir="/private/tmp"))
    app = staging_root / APP_NAME
    contents = app / "Contents"
    resources = contents / "Resources"
    executable = contents / "MacOS" / EXECUTABLE
    resources.mkdir(parents=True, mode=0o700)
    executable.parent.mkdir(mode=0o700)
    shutil.copy2(sources / "Info-MeshMonitor.plist", contents / "Info.plist")
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": EXECUTABLE, "CFBundleShortVersionString": VERSION, "CFBundleVersion": BUILD, "LSUIElement": False}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("Mesh Monitor Info.plist identity/version does not match this builder.")
    shutil.copy2(snapshot / "ops/mesh_monitor_m1_audio_receiver.py", resources / "mesh_monitor_m1_audio_receiver.py")
    adapter_resources = resources / "NeoCursorAdapter"
    adapter_resources.mkdir(mode=0o700)
    for name in NEOCURSOR_FILES:
        destination = adapter_resources / name
        shutil.copy2(snapshot / "ops/neocursor_mesh_adapter" / name, destination)
        destination.chmod(0o600)
    dependencies = []
    for name in RESOURCE_NAMES:
        origin = resource_app / "Contents/Resources" / name
        destination = resources / name
        shutil.copy2(origin, destination)
        destination.chmod(0o700 if name == "M4ParakeetWorker" else 0o600)
        dependencies.append({"name": name, "origin": str(origin), "sha256": sha256(destination), "bytes": destination.stat().st_size})

    commands = []
    try:
        with tempfile.TemporaryDirectory(prefix="mesh-monitor-module-cache-") as cache:
            icon_generator = output / "MeshMonitorIconGenerator"
            icon_command = ["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-module-cache-path", cache,
                "-target", "arm64-apple-macos14.0", "-parse-as-library", "-framework", "AppKit",
                str(sources / "MeshMonitorIcon.swift"), "-o", str(icon_generator)]
            commands.append(icon_command); run(icon_command)
            iconset = output / "MeshMonitor.iconset"
            run([str(icon_generator), str(iconset)])
            write_icns(iconset, resources / "MeshMonitor.icns")
            command = ["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-module-cache-path", cache,
                "-target", "arm64-apple-macos14.0", "-D", "M4_LOCAL_VOICE_SESSION", "-parse-as-library", "-O"]
            for framework in FRAMEWORKS:
                command += ["-framework", framework]
            command += ["-o", str(executable), *(str(sources / name) for name in SWIFT_SOURCES)]
            commands.append(command); run(command)
        run(["/usr/bin/xattr", "-cr", str(app)])
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", BUNDLE_ID,
             "--requirements", f'=designated => identifier "{BUNDLE_ID}"', str(app)])
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        # A ZIP preserves the exact signed tree without Desktop File Provider
        # attaching bundle attributes inside it. Keep verified staging available
        # for installation if the Desktop copy cannot stabilize its metadata.
        archive = output / "Mesh Monitor.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as package:
            for path in sorted(app.rglob("*")):
                if path.is_file():
                    package.write(path, str(path.relative_to(staging_root)))
        verified_staging_app = app
        final_app = output / APP_NAME
        final_copy_verified = False
        # Copy bytes and ordinary modes only. ditto also tries to preserve
        # donor file metadata that a managed Desktop sandbox can refuse.
        shutil.copytree(app, final_app, copy_function=shutil.copy)
        # File Provider adds this on the destination root even with --noextattr.
        # Remove only our freshly built copy's disallowed signing metadata.
        for attempt in range(10):
            # The File Provider may attach FinderInfo asynchronously immediately
            # after creation. Retry only this metadata error, for at most 2 sec.
            for attribute in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
                subprocess.run(["/usr/bin/xattr", "-d", attribute, str(final_app)], capture_output=True)
            verification = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(final_app)], capture_output=True, text=True)
            if verification.returncode == 0:
                final_copy_verified = True
                break
            if "resource fork, Finder information" not in verification.stderr:
                raise RuntimeError(verification.stderr)
            time.sleep(0.2)
        # The Desktop provider may reattach forbidden FinderInfo even after a
        # successful verification. Installation/QA always uses stable staging.
        app = verified_staging_app
    except Exception as error:
        (output / "BUILD-FAILED.txt").write_text(str(error) + "\n", encoding="utf-8")
        shutil.rmtree(staging_root, ignore_errors=True)
        raise

    files = [{"path": str(Path(APP_NAME) / path.relative_to(verified_staging_app)), "sha256": sha256(path), "bytes": path.stat().st_size}
             for path in sorted(verified_staging_app.rglob("*")) if path.is_file()]
    receipt = {
        "schema_version": "mesh-monitor-build.v1", "created_at": datetime.now(timezone.utc).isoformat(),
        "bundle_id": BUNDLE_ID, "app": APP_NAME, "app_path": str(app), "version": VERSION, "build": BUILD,
        "verified_staging_app": str(verified_staging_app),
        "archive": {"path": archive.name, "sha256": sha256(archive), "bytes": archive.stat().st_size},
        "copied_artifact_app": str(final_app), "copied_artifact_signature_verified_at_build": final_copy_verified,
        "source_root": str(source), "source_revision": revision, "source_branch": branch,
        "source_status": source_status, "source_snapshot": "source-snapshot", "sources": source_records,
        "resource_donor_version": old_info.get("CFBundleShortVersionString"),
        "resource_donor_build": old_info.get("CFBundleVersion"), "resources": dependencies,
        "data_handling": "Local capture and optional local inference; explicitly selected message/context/images may be sent through connected Codex account.",
        "external_local_runtime_dependencies": ["Parakeet models in user Application Support", "Kokoro Python runtime", "llama.cpp and LFM model/projector when local vision is selected"],
        "verification": {"compiled": True, "ad_hoc_signature_verified": True, "installed": False, "launched": False, "sensor_or_model_tested": False},
        "commands": commands, "files": files,
    }
    receipt_path = output / "BUILD-RECEIPT.json"
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    receipt_path.chmod(0o600)
    return app


def main() -> int:
    source = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Fresh directory under this checkout's artifacts/; defaults to a unique timestamped path.")
    parser.add_argument("--resource-app", type=Path, default=Path.home() / "Applications/M4LocalVoiceNotch.app")
    args = parser.parse_args()
    output = args.output or source / "artifacts" / ("mesh-monitor-build-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:6])
    app = build(source, output, args.resource_app.resolve())
    print(json.dumps({"status": "built_not_installed", "app": str(app), "receipt": str(output.resolve() / "BUILD-RECEIPT.json")}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

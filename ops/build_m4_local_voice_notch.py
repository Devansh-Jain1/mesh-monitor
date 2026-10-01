#!/usr/bin/env python3
"""Build the isolated M4 Local Voice Notch application."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


APP_NAME = "M4LocalVoiceNotch.app"
BUNDLE_ID = "com.devansh.m4-local-voice-notch"
EXECUTABLE = "M4LocalVoiceNotch"
SWIFT_SOURCES = (
    "WorkMacPrivateCopilot.swift",
    "WorkMacInferenceRuntime.swift",
    "WorkMacNotchPanel.swift",
    "WorkMacClaudeTranscriptCapture.swift",
    "M4LFMVisionBrain.swift",
    "M4ParakeetSpeechInput.swift", "M4ResidentJSONWorker.swift",
    "M4LocalVoiceSession.swift",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1_048_576), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build(
    source: Path,
    output: Path,
    kokoro_resources: Path,
    parakeet_worker: Path,
) -> Path:
    if output.exists():
        raise SystemExit(f"output already exists: {output}")
    app = output / APP_NAME
    contents = app / "Contents"
    executable = contents / "MacOS" / EXECUTABLE
    resources = contents / "Resources"
    executable.parent.mkdir(parents=True, mode=0o700)
    resources.mkdir(parents=True, mode=0o700)

    app_sources = source / "ops" / "work_mac_copilot_app"
    shutil.copy2(app_sources / "Info-M4LocalVoice.plist", contents / "Info.plist")
    shutil.copy2(
        source / "ops" / "m4_local_voice" / "kokoro_onnx_worker.py",
        resources / "kokoro_onnx_worker.py",
    )
    assets = {
        "kokoro.onnx": kokoro_resources / "kokoro.onnx",
        "kokoro-config.json": kokoro_resources / "kokoro-config.json",
        "af_bella.bin": kokoro_resources / "af_bella.bin",
    }
    for name, path in assets.items():
        if not path.is_file():
            raise SystemExit(f"missing Kokoro asset: {path}")
        shutil.copy2(path, resources / name)
        os.chmod(resources / name, 0o600)
    os.chmod(resources / "kokoro_onnx_worker.py", 0o600)
    if not parakeet_worker.is_file():
        raise SystemExit(f"missing Parakeet worker: {parakeet_worker}")
    shutil.copy2(parakeet_worker, resources / "M4ParakeetWorker")
    os.chmod(resources / "M4ParakeetWorker", 0o700)

    with tempfile.TemporaryDirectory(prefix="m4-local-voice-module-cache-") as cache:
        subprocess.run(
            [
                "/usr/bin/xcrun",
                "--sdk", "macosx",
                "swiftc",
                "-module-cache-path", cache,
                "-target", "arm64-apple-macos14.0",
                "-D", "WORK_MAC_V5_SCOPED_BOOTSTRAP",
                "-D", "M4_LOCAL_VOICE_SESSION",
                "-parse-as-library",
                "-O",
                "-framework", "AppKit",
                "-framework", "AVFoundation",
                "-framework", "CryptoKit",
                "-framework", "ScreenCaptureKit",
                "-framework", "Vision",
                "-framework", "ApplicationServices",
                "-o", str(executable),
                *(str(app_sources / name) for name in SWIFT_SOURCES),
            ],
            check=True,
        )
    subprocess.run(["/usr/bin/xattr", "-cr", str(app)], check=True)
    subprocess.run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign", "-",
            "--identifier", BUNDLE_ID,
            "--requirements",
            f'=designated => identifier "{BUNDLE_ID}"',
            str(app),
        ],
        check=True,
    )
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        check=True,
    )

    files = []
    for path in sorted(app.rglob("*")):
        if path.is_file():
            files.append({
                "path": str(path.relative_to(output)),
                "sha256": sha256(path),
                "bytes": path.stat().st_size,
            })
    manifest = {
        "schema_version": "m4-local-voice-build.v1",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "bundle_id": BUNDLE_ID,
        "app": APP_NAME,
        "module_id": "com.devansh.voice-session",
        "module_version": "0.3.0",
        "brain": "lfm2.5_vl_3b_q4_k_m",
        "stt": "fluidaudio_parakeet_tdt_0.6b_v3_int8",
        "tts": "kokoro_onnx_af_bella",
        "custody": "local_only",
        "files": files,
    }
    (output / "BUILD-RECEIPT.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.chmod(output / "BUILD-RECEIPT.json", 0o600)
    return app


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--kokoro-resources", type=Path, required=True)
    result.add_argument("--parakeet-worker", type=Path, required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    source = Path(__file__).resolve().parents[1]
    app = build(
        source,
        args.output.resolve(),
        args.kokoro_resources.resolve(),
        args.parakeet_worker.resolve(),
    )
    print(json.dumps({"status": "built", "app": str(app)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

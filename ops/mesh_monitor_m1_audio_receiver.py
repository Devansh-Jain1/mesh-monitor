"""Bounded, explicit SSH-stdin WAV player for the selected M1 speakers.

No server, microphone, camera, model, token, or persistent process. `probe` is read-only.
`play UUID BYTE_COUNT` receives the exact WAV followed by an open control channel.
Any control byte or EOF cancels only this invocation's own afplay child.
"""
from __future__ import annotations

import ctypes
import io
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import wave

DEVICE = "MacBook Pro Speakers"
MAX_BYTES = 12 * 1024 * 1024


def fourcc(value: str) -> int:
    return int.from_bytes(value.encode("ascii"), "big")


class Address(ctypes.Structure):
    _fields_ = [("selector", ctypes.c_uint32), ("scope", ctypes.c_uint32), ("element", ctypes.c_uint32)]


def default_output_names() -> tuple[str, str]:
    core = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    core.AudioObjectGetPropertyData.argtypes = [ctypes.c_uint32, ctypes.POINTER(Address), ctypes.c_uint32,
                                                ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
    core.AudioObjectGetPropertyData.restype = ctypes.c_int32
    cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFRelease.argtypes = [ctypes.c_void_p]

    def read(device: int, selector: str, result) -> None:
        size = ctypes.c_uint32(ctypes.sizeof(result))
        address = Address(fourcc(selector), fourcc("glob"), 0)
        if core.AudioObjectGetPropertyData(device, ctypes.byref(address), 0, None,
                                          ctypes.byref(size), ctypes.byref(result)) != 0:
            raise RuntimeError("coreaudio_route_unavailable")

    def name(selector: str) -> str:
        device = ctypes.c_uint32()
        read(1, selector, device)
        value = ctypes.c_void_p()
        read(device.value, "lnam", value)
        if not value.value:
            raise RuntimeError("coreaudio_name_unavailable")
        try:
            buffer = ctypes.create_string_buffer(1024)
            if not cf.CFStringGetCString(value, buffer, len(buffer), 0x08000100):
                raise RuntimeError("coreaudio_name_unavailable")
            return buffer.value.decode("utf-8")
        finally:
            cf.CFRelease(value)
    return name("dOut"), name("sOut")


def volume_settings() -> tuple[int, bool]:
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", "get volume settings"],
                                capture_output=True, text=True, check=True, timeout=3)
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError("volume_unavailable") from error
    volume = re.search(r"output volume:(\d+)", result.stdout)
    mute = re.search(r"output muted:(true|false)", result.stdout)
    if not volume or not mute:
        raise RuntimeError("volume_unavailable")
    return int(volume.group(1)), mute.group(1) == "true"


def validate_wave(data: bytes) -> float:
    if not data or len(data) > MAX_BYTES:
        raise ValueError("invalid_audio_size")
    with wave.open(io.BytesIO(data), "rb") as audio:
        if audio.getnchannels() not in (1, 2) or audio.getsampwidth() != 2 or not 8000 <= audio.getframerate() <= 48000:
            raise ValueError("unsupported_audio_format")
        seconds = audio.getnframes() / audio.getframerate()
        if not 0 < seconds <= 120:
            raise ValueError("invalid_audio_duration")
        if len(audio.readframes(audio.getnframes())) != audio.getnframes() * audio.getnchannels() * audio.getsampwidth():
            raise ValueError("truncated_audio")
        return seconds


def read_exact(length: int) -> bytes:
    if not 1 <= length <= MAX_BYTES:
        raise ValueError("invalid_audio_size")
    chunks = []
    deadline = time.monotonic() + 12
    remaining = length
    while remaining:
        timeout = max(0.0, deadline - time.monotonic())
        if timeout == 0 or not select.select([0], [], [], timeout)[0]:
            raise TimeoutError("audio_transfer_timeout")
        chunk = os.read(0, min(remaining, 64 * 1024))
        if not chunk:
            raise ValueError("audio_transfer_closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def cancelled() -> bool:
    if select.select([0], [], [], 0)[0]:
        os.read(0, 64)  # EOF or any control byte is a stop, never another command.
        return True
    return False


def emit(request_id: str, phase: str, **extra) -> None:
    print(json.dumps({"request_id": request_id, "phase": phase, **extra}), flush=True)


def play(request_id: str, data: bytes) -> None:
    seconds = validate_wave(data)
    if cancelled():
        raise InterruptedError("cancelled")
    selector = Path.home() / "AIYStation/station-audio-output"
    try:
        subprocess.run([str(selector), DEVICE], capture_output=True, text=True, check=True, timeout=5)
    except FileNotFoundError as error:
        raise RuntimeError("speaker_selector_unavailable") from error
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError("speaker_selector_failed") from error
    # Deployed selector may be a silent guard instead of the historical native helper.
    # Its exit status is only a prerequisite; actual CoreAudio readback is authoritative.
    if default_output_names() != (DEVICE, DEVICE):
        raise RuntimeError("selected_output_not_verified")
    if cancelled():
        raise InterruptedError("cancelled")
    try:
        subprocess.run(["/usr/bin/osascript", "-e", "set volume output muted false\nset volume output volume 100"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=3)
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError("speaker_volume_change_failed") from error
    if default_output_names() != (DEVICE, DEVICE) or volume_settings() != (100, False):
        raise RuntimeError("speaker_volume_not_verified")
    process = None
    filename = None
    try:
        fd, filename = tempfile.mkstemp(prefix=f"mesh-monitor-{request_id}-", suffix=".wav")
        with os.fdopen(fd, "wb") as output:
            output.write(data)
        if cancelled():
            raise InterruptedError("cancelled")
        emit(request_id, "ready", device=DEVICE, volume=100, muted=False)
        process = subprocess.Popen(["/usr/bin/afplay", filename], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + seconds + 10
        last_check = 0.0
        while process.poll() is None:
            if cancelled():
                raise InterruptedError("cancelled")
            if time.monotonic() > deadline:
                raise TimeoutError("playback_timeout")
            if time.monotonic() - last_check > 0.4:
                if default_output_names() != (DEVICE, DEVICE):
                    raise RuntimeError("output_route_changed")
                last_check = time.monotonic()
            time.sleep(0.05)
        if process.returncode != 0:
            raise RuntimeError("playback_failed")
        emit(request_id, "complete", device=DEVICE, volume=100)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        if filename is not None:
            Path(filename).unlink(missing_ok=True)


def main() -> int:
    if sys.argv[1:] == ["probe"]:
        output, system = default_output_names()
        volume, muted = volume_settings()
        print(json.dumps({"device": output, "system_device": system, "volume": volume, "muted": muted}))
        return 0
    request_id = "unknown"
    try:
        if len(sys.argv) != 4 or sys.argv[1] not in {"play", "check"}:
            raise ValueError("invalid_arguments")
        request_id = str(uuid.UUID(sys.argv[2]))
        if request_id != sys.argv[2]:
            raise ValueError("invalid_request_id")

        def stop_signal(_signal, _frame):
            raise InterruptedError("cancelled")
        signal.signal(signal.SIGHUP, stop_signal)
        signal.signal(signal.SIGTERM, stop_signal)
        signal.signal(signal.SIGINT, stop_signal)
        data = read_exact(int(sys.argv[3]))
        if sys.argv[1] == "check":
            seconds = validate_wave(data)
            device, system = default_output_names()
            volume, muted = volume_settings()
            emit(request_id, "checked", device=device, system_device=system, volume=volume, muted=muted,
                 audio_bytes=len(data), audio_seconds=seconds,
                 selector_exists=(Path.home() / "AIYStation/station-audio-output").is_file())
            return 0
        play(request_id, data)
        return 0
    except Exception as error:
        # Never return shell commands, WAV path, payload, or raw exception details.
        known = {"cancelled", "invalid_audio_size", "unsupported_audio_format", "invalid_audio_duration",
                 "truncated_audio", "audio_transfer_timeout", "audio_transfer_closed", "playback_timeout",
                 "output_route_changed", "playback_failed", "selected_output_not_verified", "speaker_volume_not_verified",
                 "speaker_selector_unavailable", "speaker_selector_failed", "speaker_selector_output_mismatch",
                 "coreaudio_route_unavailable", "coreaudio_name_unavailable", "volume_unavailable", "speaker_volume_change_failed",
                 "invalid_arguments", "invalid_request_id"}
        code = "invalid_audio_header" if isinstance(error, (wave.Error, EOFError)) else str(error) if str(error) in known else "m1_audio_unavailable"
        emit(request_id, "error", error=code)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

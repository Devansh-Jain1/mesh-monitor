#!/usr/bin/env python3
"""Resident, localhost-free Kokoro ONNX worker for the M4 VoiceSession.

The worker communicates only over stdin/stdout JSON lines.  It loads the
existing Kokoro model once, keeps it resident, writes owner-only temporary WAV
files requested by the native adapter, and never opens a network socket.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import wave
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
from misaki import espeak


SAMPLE_RATE = 24_000
MAX_TEXT_CHARACTERS = 600
MAX_TOKEN_COUNT = 510
STYLE_WIDTH = 256
STYLE_ROWS = 510


class KokoroWorkerError(RuntimeError):
    pass


def _owner_only_regular_file(path: Path) -> Path:
    resolved = path.expanduser().resolve(strict=True)
    stat = resolved.stat()
    if not resolved.is_file() or stat.st_mode & 0o077:
        raise KokoroWorkerError(f"asset_not_owner_only:{resolved.name}")
    return resolved


def _bounded_text(value: Any) -> str:
    if not isinstance(value, str):
        raise KokoroWorkerError("text_required")
    normalized = " ".join(value.split())
    if not normalized:
        raise KokoroWorkerError("text_empty")
    if len(normalized) > MAX_TEXT_CHARACTERS:
        raise KokoroWorkerError("text_too_large")
    return normalized


class KokoroONNX:
    def __init__(self, model: Path, config: Path, voice: Path) -> None:
        model = _owner_only_regular_file(model)
        config = _owner_only_regular_file(config)
        voice = _owner_only_regular_file(voice)
        payload = json.loads(config.read_text(encoding="utf-8"))
        vocab = payload.get("vocab")
        if not isinstance(vocab, dict):
            raise KokoroWorkerError("invalid_vocab")
        self.vocab = {str(key): int(value) for key, value in vocab.items()}
        styles = np.fromfile(voice, dtype=np.float32)
        expected = STYLE_ROWS * STYLE_WIDTH
        if styles.size != expected:
            raise KokoroWorkerError(f"invalid_voice_style:{styles.size}")
        self.styles = styles.reshape(STYLE_ROWS, STYLE_WIDTH)
        options = ort.SessionOptions()
        # The M4 runtime currently exposes CPUExecutionProvider only. Two
        # threads left performance cores idle and made a short reply take about
        # 3.5 seconds to synthesize. Four keeps UI headroom while reducing
        # time-to-first-audio on 10-core Apple Silicon.
        options.intra_op_num_threads = min(4, max(2, (os.cpu_count() or 4) // 2))
        options.inter_op_num_threads = 1
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self.session = ort.InferenceSession(
            str(model),
            sess_options=options,
            providers=["CPUExecutionProvider"],
        )
        self.g2p = espeak.EspeakG2P(language="en-us")

    def synthesize(self, text: str, output: Path, speed: float) -> dict[str, Any]:
        text = _bounded_text(text)
        if not 0.75 <= speed <= 1.35:
            raise KokoroWorkerError("speed_out_of_range")
        phonemes, _ = self.g2p(text)
        token_ids = [self.vocab[char] for char in phonemes if char in self.vocab]
        if not token_ids:
            raise KokoroWorkerError("no_tokens")
        if len(token_ids) > MAX_TOKEN_COUNT:
            raise KokoroWorkerError("too_many_tokens")
        padded = np.asarray([[0, *token_ids, 0]], dtype=np.int64)
        style = self.styles[min(len(token_ids), STYLE_ROWS - 1)][None, :]
        started = time.monotonic()
        waveform = self.session.run(
            ["waveform"],
            {
                "input_ids": padded,
                "ref_s": style.astype(np.float32, copy=False),
                "speed": np.asarray(speed, dtype=np.float32),
            },
        )[0]
        generation_ms = round((time.monotonic() - started) * 1_000)
        samples = np.asarray(waveform, dtype=np.float32).reshape(-1)
        if samples.size == 0:
            raise KokoroWorkerError("empty_waveform")
        raw_peak = float(np.max(np.abs(samples)))
        gain = min(1.0, 0.85 / raw_peak) if raw_peak > 0 else 1.0
        samples = samples * gain
        fade = min(samples.size // 2, SAMPLE_RATE // 200)
        if fade:
            ramp = np.arange(fade, dtype=np.float32) / float(fade)
            samples[:fade] *= ramp
            samples[-fade:] *= ramp[::-1]
        samples = np.clip(samples, -1.0, 1.0)
        pcm = (samples * 32767.0).astype("<i2", copy=False)

        output = output.expanduser().resolve(strict=False)
        output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if output.exists() or output.is_symlink():
            raise KokoroWorkerError("output_must_not_exist")
        with wave.open(str(output), "wb") as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(SAMPLE_RATE)
            stream.writeframes(pcm.tobytes())
        os.chmod(output, 0o600)
        audio_ms = round(samples.size / SAMPLE_RATE * 1_000)
        return {
            "generation_ms": generation_ms,
            "audio_ms": audio_ms,
            "sample_rate": SAMPLE_RATE,
            "token_count": len(token_ids),
            "raw_peak": round(raw_peak, 6),
            "normalization_gain": round(gain, 6),
            "engine": "kokoro_onnx",
            "voice": "af_bella",
        }


def _reply(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True), flush=True)


def run(args: argparse.Namespace) -> int:
    loaded_at = time.monotonic()
    engine = KokoroONNX(args.model, args.config, args.voice)
    _reply({"event": "ready", "load_ms": round((time.monotonic() - loaded_at) * 1_000)})
    for line in sys.stdin:
        request_id = "unknown"
        try:
            request = json.loads(line)
            request_id = str(request.get("id") or "")
            if not request_id or len(request_id) > 128:
                raise KokoroWorkerError("invalid_request_id")
            if request.get("command") == "stop":
                _reply({"id": request_id, "ok": True, "stopped": True})
                return 0
            output = Path(str(request.get("output") or ""))
            if not output.is_absolute():
                raise KokoroWorkerError("absolute_output_required")
            stats = engine.synthesize(
                request.get("text"),
                output,
                float(request.get("speed", 1.05)),
            )
            _reply({"id": request_id, "ok": True, "output": str(output), **stats})
        except Exception as error:  # fail closed at the product boundary
            _reply({
                "id": request_id,
                "ok": False,
                "error": str(error)[:240],
            })
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--model", type=Path, required=True)
    result.add_argument("--config", type=Path, required=True)
    result.add_argument("--voice", type=Path, required=True)
    return result


if __name__ == "__main__":
    raise SystemExit(run(parser().parse_args()))

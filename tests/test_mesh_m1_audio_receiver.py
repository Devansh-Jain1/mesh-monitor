"""No audio/device/network calls: receiver behavior under mocked output operations."""
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
import wave

SPEC = importlib.util.spec_from_file_location("mesh_m1_audio", Path(__file__).resolve().parents[1] / "ops/mesh_monitor_m1_audio_receiver.py")
audio = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audio)


def wav(width=2):
    data = io.BytesIO()
    with wave.open(data, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(width)
        output.setframerate(16000)
        output.writeframes(b"\0" * (1600 * width))
    return data.getvalue()


class FakePlayer:
    def __init__(self, completes=False):
        self.completes = completes
        self.polls = 0
        self.terminated = False
        self.killed = False
        self.returncode = 0

    def poll(self):
        self.polls += 1
        return 0 if self.terminated or (self.completes and self.polls >= 2) else None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout):
        return 0


class MeshM1AudioReceiverTests(unittest.TestCase):
    def setUp(self):
        self.patches = [
            patch.object(audio, "cancelled", return_value=False),
            patch.object(audio, "default_output_names", return_value=(audio.DEVICE, audio.DEVICE)),
            patch.object(audio, "volume_settings", return_value=(100, False)),
            patch.object(audio.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, audio.DEVICE + "\n", "")),
            patch.object(audio.subprocess, "Popen", return_value=FakePlayer(completes=True)),
            patch.object(audio, "emit"),
            patch.object(audio.time, "sleep"),
        ]
        self.cancel, self.route, self.volume, self.run, self.player, self.emit, _ = [p.start() for p in self.patches]
        self.addCleanup(lambda: [p.stop() for p in reversed(self.patches)])

    def test_validates_actual_wave_and_rejects_other_formats(self):
        self.assertAlmostEqual(audio.validate_wave(wav()), 0.1)
        with self.assertRaises(ValueError):
            audio.validate_wave(wav(width=4))
        with self.assertRaises(ValueError):
            audio.validate_wave(b"")
        with self.assertRaises((ValueError, EOFError, wave.Error)):
            audio.validate_wave(wav()[:-100])

    def test_complete_requires_verified_route_and_volume(self):
        audio.play("fixture", wav())
        self.assertEqual([c.args[1] for c in self.emit.call_args_list], ["ready", "complete"])
        self.assertEqual(self.emit.call_args_list[0].kwargs["volume"], 100)
        args = self.player.call_args.args[0]
        self.assertEqual(args[0], "/usr/bin/afplay")
        self.assertFalse(Path(args[1]).exists(), "Temporary audio must be removed")

    def test_wrong_route_never_plays(self):
        self.route.return_value = ("Headphones", "Headphones")
        with self.assertRaisesRegex(RuntimeError, "selected_output_not_verified"):
            audio.play("fixture", wav())
        self.player.assert_not_called()
        self.emit.assert_not_called()

    def test_silent_installed_selector_uses_actual_coreaudio_readback(self):
        self.run.return_value = subprocess.CompletedProcess([], 0, "", "")
        audio.play("fixture", wav())
        self.assertEqual([c.args[1] for c in self.emit.call_args_list], ["ready", "complete"])
        self.assertGreaterEqual(self.route.call_count, 2)

    def test_selector_stdout_cannot_substitute_for_actual_route(self):
        self.run.return_value = subprocess.CompletedProcess([], 0, audio.DEVICE, "")
        self.route.return_value = ("Headphones", "Headphones")
        with self.assertRaisesRegex(RuntimeError, "selected_output_not_verified"):
            audio.play("fixture", wav())
        self.player.assert_not_called()

    def test_selector_failure_is_classified_without_raw_details(self):
        self.run.side_effect = subprocess.CalledProcessError(1, ["private-path"], stderr="private error")
        with self.assertRaisesRegex(RuntimeError, "^speaker_selector_failed$"):
            audio.play("fixture", wav())
        self.player.assert_not_called()

    def test_failed_volume_check_never_plays(self):
        self.volume.return_value = (56, False)
        with self.assertRaisesRegex(RuntimeError, "speaker_volume_not_verified"):
            audio.play("fixture", wav())
        self.player.assert_not_called()

    def test_stop_terminates_only_owned_player(self):
        child = FakePlayer()
        self.player.return_value = child
        self.cancel.side_effect = [False, False, False, True]
        with self.assertRaises(InterruptedError):
            audio.play("fixture", wav())
        self.assertTrue(child.terminated)
        self.assertFalse(child.killed)
        self.assertEqual([c.args[1] for c in self.emit.call_args_list], ["ready"])
        self.assertFalse(Path(self.player.call_args.args[0][1]).exists())

    def test_output_route_change_stops_owned_player(self):
        child = FakePlayer()
        self.player.return_value = child
        self.route.side_effect = [(audio.DEVICE, audio.DEVICE), (audio.DEVICE, audio.DEVICE), ("Headphones", "Headphones")]
        with self.assertRaisesRegex(RuntimeError, "output_route_changed"):
            audio.play("fixture", wav())
        self.assertTrue(child.terminated)
        self.assertNotIn("complete", [c.args[1] for c in self.emit.call_args_list])

    def test_cancel_before_play_does_not_change_route(self):
        self.cancel.return_value = True
        with self.assertRaises(InterruptedError):
            audio.play("fixture", wav())
        self.run.assert_not_called()
        self.player.assert_not_called()

    def test_open_stdin_eof_is_cancellation(self):
        self.patches[0].stop()
        with patch.object(audio.select, "select", return_value=([0], [], [])), patch.object(audio.os, "read", return_value=b""):
            self.assertTrue(audio.cancelled())


if __name__ == "__main__":
    unittest.main()

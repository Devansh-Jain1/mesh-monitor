import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SESSION = ROOT / "ops/work_mac_copilot_app/M4LocalVoiceSession.swift"
VISION = ROOT / "ops/work_mac_copilot_app/M4LFMVisionBrain.swift"
SPEECH = ROOT / "ops/work_mac_copilot_app/M4ParakeetSpeechInput.swift"
PARAKEET_WORKER = ROOT / "ops/work_mac_copilot_app/M4ParakeetWorker.swift"
APP = ROOT / "ops/work_mac_copilot_app/WorkMacPrivateCopilot.swift"
NOTCH = ROOT / "ops/work_mac_copilot_app/WorkMacNotchPanel.swift"
WORKER = ROOT / "ops/m4_local_voice/kokoro_onnx_worker.py"
BUILD = ROOT / "ops/build_m4_local_voice_notch.py"
CONTRACT = ROOT / "contracts/voice-session-event.schema.json"
PRODUCT = ROOT / "contracts/voice-session.odps.yaml"


class M4LocalVoiceSessionTests(unittest.TestCase):
    def test_native_session_is_modular_and_local_only(self):
        source = SESSION.read_text()
        speech = SPEECH.read_text()
        self.assertIn("protocol M4LocalVoiceBrainPort", source)
        self.assertIn("M4ResidentKokoroWorker", source)
        self.assertIn("M4OnDeviceSpeechInput", speech)
        self.assertIn("M4ParakeetCaptureState", speech)
        self.assertIn('"NO_PROXY": "*"', speech)
        self.assertIn('"NO_PROXY": "*"', source)
        self.assertNotIn("100.64.0.12", source)
        self.assertNotIn("VibeVoice", source)

    def test_resident_lfm_vlm_is_loopback_only_and_uses_real_frames(self):
        source = VISION.read_text()
        self.assertIn('private let host = "127.0.0.1"', source)
        self.assertIn('LFM2.5-VL-3B-Q4_K_M.gguf', source)
        self.assertIn('mmproj-LFM2.5-VL-3B-Q8_0.gguf', source)
        self.assertIn('CGDisplayCreateImage(CGMainDisplayID())', source)
        self.assertIn('"type": "image_url"', source)
        self.assertIn('data:image/jpeg;base64', source)
        self.assertIn('"typing", "typed", "text box"', source)
        self.assertIn("transcribe that text verbatim", source)
        self.assertIn("if !includeScreen", source)
        self.assertIn("focusTextEntry: exactVisibleText", source)
        self.assertIn("magnified lower-screen region", source)
        self.assertIn("lastTurnUsedScreen && isVisualFollowUp", source)
        self.assertIn("history.suffix(4)", source)
        self.assertIn("isLikelyStaleRepeat", source)
        self.assertIn("frontmost_application", source)
        self.assertIn("let maximumWidth: CGFloat = focusTextEntry ? 1_600 : 768", source)
        self.assertIn('"again", "check", "look"', source)
        self.assertIn('"cursor", "mouse", "pointer"', source)
        self.assertIn("AXUIElementCreateSystemWide", source)
        self.assertIn("VNRecognizeTextRequest", source)
        self.assertIn("func readinessProbe()", source)
        self.assertIn('brainID: "macos_vision_ocr"', source)
        self.assertIn('"accessibility_value"', source)
        self.assertIn('"vision_ocr"', source)
        self.assertIn('"accessibility_pointer_target"', source)
        self.assertIn('brainID: "macos_native_pointer_evidence"', source)
        self.assertLess(
            source.index("let focusedText = focusedTextValue()"),
            source.index("let screenEvidence = includeScreen"),
        )
        self.assertLess(
            source.index("let pointer = pointerEvidence()"),
            source.index("let screenEvidence = includeScreen"),
        )
        self.assertIn("if !allowsExplicitRepetition(transcript)", source)
        self.assertIn("freshEvidenceFallback", source)
        self.assertIn("request.timeoutInterval = 20", source)
        self.assertNotIn('https://', source)

    def test_raw_debug_conversation_stays_in_owner_only_local_log(self):
        source = SESSION.read_text()
        self.assertIn('recordConversation(role: "user"', source)
        self.assertIn('role: "assistant"', source)
        self.assertIn('fileName: "conversation.jsonl"', source)
        self.assertIn('.posixPermissions: 0o600', source)

    def test_parakeet_is_resident_endpointed_and_observable(self):
        source = SESSION.read_text()
        speech = SPEECH.read_text()
        worker = PARAKEET_WORKER.read_text()
        self.assertIn('record("asr_resident_ready"', source)
        self.assertIn('record("audio_input_ready"', source)
        self.assertIn('record("speech_detected"', source)
        self.assertIn('record("asr_completed"', source)
        self.assertIn('record("brain_requested"', source)
        self.assertIn('"response_sha256": self.sha256(reply.text)', source)
        self.assertIn('"transcript_to_first_audio_ms"', source)
        self.assertIn('"capture_to_first_audio_ms"', source)
        self.assertIn("silenceFor >= 0.72", speech)
        self.assertIn("consecutiveSpeechSamples >= 8", speech)
        self.assertIn("speechArmAt", speech)
        self.assertIn("peakThresholdDB", speech)
        self.assertIn("trimRecording", speech)
        self.assertIn("speechStartedAt.timeIntervalSince(startedAt)", speech)
        self.assertIn("while let line = readLine()", worker)
        self.assertIn("AsrModels.load", worker)

    def test_empty_asr_result_recovers_instead_of_killing_session(self):
        session = SESSION.read_text()
        speech = SPEECH.read_text()
        self.assertIn("var onNoSpeech", speech)
        self.assertIn("self.onNoSpeech?()", speech)
        self.assertIn('record("empty_utterance_ignored"', session)
        self.assertIn('"reason": "empty_utterance_recovery"', session)

    def test_voice_control_interrupts_playback_and_resumes_listening(self):
        source = SESSION.read_text()
        self.assertIn("if phase == .speaking", source)
        self.assertIn('record("interruption_requested"', source)
        self.assertIn('record("playback_interrupted"', source)
        self.assertIn('"reason": "playback_interrupted"', source)

    def test_notch_exposes_red_microphone_state(self):
        session = SESSION.read_text()
        notch = NOTCH.read_text()
        self.assertIn('status("Microphone active • listening locally", .systemRed)', session)
        self.assertIn("collapsedActivityDot.textColor = color", notch)
        self.assertIn("activityDot.textColor = color", notch)
        self.assertIn("voiceStateBar.layer?.backgroundColor = color.cgColor", notch)
        self.assertIn('shortState = "MIC"', notch)
        self.assertIn('shortState = "THINK"', notch)
        self.assertIn('shortState = "TALK"', notch)
        self.assertIn("func collapse()", notch)
        self.assertIn('self?.notchPanel.collapse()', APP.read_text())
        self.assertIn("identity.widthAnchor.constraint(equalTo: detailStack.widthAnchor)", notch)

    def test_startup_gate_reports_screen_admission_or_degraded_voice(self):
        source = SESSION.read_text()
        notch = NOTCH.read_text()
        self.assertIn('record("startup_probe_started"', source)
        self.assertIn('record("startup_probe_completed"', source)
        self.assertIn('record("startup_probe_degraded"', source)
        self.assertIn('record("startup_gate_ready"', source)
        self.assertIn("brain.readinessProbe()", source)
        self.assertIn('"reason": "startup_gate_ready"', source)
        self.assertIn('"reason": "startup_gate_degraded_screen"', source)
        self.assertIn('"screen_context_available": false', source)
        self.assertIn("func runScreenDiagnostic", source)
        self.assertIn('record("diagnostic_completed"', source)
        self.assertLess(source.index('self.runStartupGate()'), source.index('private func beginListening'))
        self.assertIn('"peer_state": "nano_simulated_not_connected"', source)
        self.assertIn("func updateLocalVoiceReadiness", notch)

    def test_application_selects_local_voice_without_fallback(self):
        source = APP.read_text()
        self.assertIn("#if M4_LOCAL_VOICE_SESSION", source)
        self.assertIn("localVoiceSession.toggle()", source)
        self.assertIn('arguments == ["voice-start"]', source)
        self.assertIn("autoStartVoice: autoStartVoice", source)
        self.assertIn("No cloud or Pi fallback was attempted", source)
        self.assertIn("localVoiceSession.cancel()", source)
        self.assertIn("func applicationWillTerminate", source)
        self.assertIn("runFocusedTextDiagnostic", source)
        self.assertIn("runPointerDiagnostic", source)

    def test_worker_has_bounded_pipe_only_contract(self):
        source = WORKER.read_text()
        self.assertIn("for line in sys.stdin", source)
        self.assertIn("MAX_TEXT_CHARACTERS = 600", source)
        self.assertIn("MAX_TOKEN_COUNT = 510", source)
        self.assertIn("options.intra_op_num_threads = min(4", source)
        self.assertIn("options.inter_op_num_threads = 1", source)
        self.assertNotIn("import socket", source)
        self.assertNotIn("import requests", source)
        self.assertNotIn("hf_hub", source)

    def test_build_is_separately_identified_and_asset_explicit(self):
        source = BUILD.read_text()
        self.assertIn('APP_NAME = "M4LocalVoiceNotch.app"', source)
        self.assertIn('BUNDLE_ID = "com.devansh.m4-local-voice-notch"', source)
        self.assertNotIn('BUNDLE_ID = "com.devansh.m4-local-voice-notch.v', source)
        self.assertIn('"-D", "M4_LOCAL_VOICE_SESSION"', source)
        self.assertIn('"kokoro.onnx": kokoro_resources', source)
        self.assertIn('"M4LFMVisionBrain.swift"', source)
        self.assertIn('"M4ParakeetSpeechInput.swift"', source)
        self.assertIn('resources / "M4ParakeetWorker"', source)
        self.assertIn('"brain": "lfm2.5_vl_3b_q4_k_m"', source)
        self.assertIn('"stt": "fluidaudio_parakeet_tdt_0.6b_v3_int8"', source)
        self.assertIn("designated => identifier", source)

    def test_lifecycle_contract_and_product_descriptor_parse(self):
        payload = json.loads(CONTRACT.read_text())
        self.assertEqual(payload["properties"]["schema_version"]["const"], "voice-session-receipt.v1")
        self.assertIn("listening_resumed", payload["properties"]["event"]["enum"])
        self.assertIn("brain_requested", payload["properties"]["event"]["enum"])
        self.assertIn("transcript_to_first_audio_ms", payload["properties"])
        self.assertIn("capture_to_first_audio_ms", payload["properties"])
        product = PRODUCT.read_text()
        self.assertIn("com.devansh.voice-session", product)
        self.assertIn("contracts/voice-session-event.schema.json", product)


if __name__ == "__main__":
    unittest.main()

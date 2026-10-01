import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "ops" / "m4_codex_conversation_capture.swift"
INFO_PLIST = ROOT / "ops" / "m4_codex_conversation_capture_Info.plist"


class M4CodexConversationCaptureContractTests(unittest.TestCase):
    def test_scope_is_one_allowlisted_codex_app_and_one_hour_maximum(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn('allowedBundleID = "com.openai.codex"', source)
        self.assertIn("maximumRunSeconds = 3_600", source)
        self.assertIn("target_not_allowlisted", source)
        self.assertIn("target_not_frontmost", source)
        self.assertIn("frame.width >= 600", source)
        self.assertIn("frame.height >= 400", source)
        self.assertIn("$0.windowID == focusedWindow.0", source)
        self.assertIn("frameMatchedWindow", source)
        self.assertIn("(30...maximumRunSeconds).contains(maxSeconds)", source)

    def test_capture_is_local_ocr_without_audio_or_network(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("VNRecognizeTextRequest", source)
        self.assertIn("streamConfig.showsCursor = true", source)
        self.assertIn("streamConfig.capturesAudio = false", source)
        self.assertIn("network_transport_used: false", source)
        self.assertIn("raw_evidence_local_only: true", source)
        self.assertNotIn("URLSession", source)
        self.assertNotIn("https://", source)

    def test_automation_is_bounded_scroll_and_reversible_tab_probe_only(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("postMouseMove(to: hoverPoint)", source)
        self.assertIn("postScroll(pixels: config.scrollPixels)", source)
        self.assertIn("postControlTab(shift: false)", source)
        self.assertIn("postControlTab(shift: true)", source)
        self.assertIn("lineSimilarity(beforeText, restoredText)", source)
        self.assertIn("restored: restoreVerified", source)
        self.assertIn("typing_or_submission_performed: false", source)
        self.assertNotIn("mouseType: .leftMouseDown", source)
        self.assertNotIn("virtualKey: 36", source)

    def test_receipts_are_durable_and_hash_bound(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn('appendingPathComponent("events.jsonl")', source)
        self.assertIn('appendingPathComponent("timeline.md")', source)
        self.assertIn('appendingPathComponent("receipt.json")', source)
        self.assertIn("SHA256.hash", source)
        self.assertIn("try? eventsHandle.synchronize()", source)
        self.assertIn("output_must_be_new", source)

    def test_stable_test_app_identity_declares_local_screen_capture(self):
        source = INFO_PLIST.read_text(encoding="utf-8")
        self.assertIn("com.devansh.m4-codex-conversation-capture-test", source)
        self.assertIn("NSScreenCaptureUsageDescription", source)
        self.assertIn("one authorized Codex window", source)


if __name__ == "__main__":
    unittest.main()

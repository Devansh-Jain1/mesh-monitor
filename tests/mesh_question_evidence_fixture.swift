import Foundation

@main private struct MeshQuestionEvidenceFixture {
    @MainActor static func main() throws {
        func fields(_ text: String) throws -> [String: [String: Any]] {
            let envelope = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            let values = envelope["fields"] as! [[String: Any]]
            return Dictionary(uniqueKeysWithValues: values.map { ($0["name"] as! String, $0) })
        }
        func verify(_ text: String, maximum: Int, originals: [String: String]) throws {
            assert(text.utf8.count <= maximum)
            for (name, field) in try fields(text) {
                let original = originals[name]!, value = field["value"] as! String
                assert(original.hasPrefix(value), "Excerpt must stay a prefix of its own source")
                assert(field["originalUTF8Bytes"] as! Int == original.utf8.count)
                assert(field["includedUTF8Bytes"] as! Int == value.utf8.count)
                assert(field["truncated"] as! Bool == (value != original))
                assert(String(original.prefix(value.count)) == value, "Excerpt ends on an original Character boundary")
            }
        }

        let task = "Finish the paper introduction."
        let gaze = String(repeating: "Display 7, normalized (0.3,0.4), uncertain calibrated region; crop x0.3 y0.2. ", count: 21)
        let geometry = "Window (100,200,900,600), display 7 (0,0,1440,900), image1440x960."
        let selection = String(repeating: "重点👨🏽‍💻 e\u{301} quotation\"\n", count: 4_000)
        let ocr = String(repeating: "密集屏幕文字👁️\t\n\u{0000}\\\"", count: 8_000)
        var input = MeshQuestionEvidence.Input(task: task, finishCondition: "One complete paragraph.",
            activity: "Safari foreground, duration is not intent.", recentConversation: "You: Explain the introduction.\nAgent: What is the central question?",
            home: "Home today: research at 10 AM.", screenSource: "Image 1, selected Safari document, timestamp.",
            screenGeometry: geometry, selectedText: selection, ocr: ocr,
            room: "Image 2, fresh room frame; no intent inference.", gaze: gaze)
        let packed = try MeshQuestionEvidence.prepare(input)
        let originals = [
            "user_selected_task": input.task, "finish_condition": input.finishCondition,
            "foreground_activity_observation": input.activity, "recent_conversation_reference": input.recentConversation,
            "home_calendar_context": input.home, "screen_source_and_capture_time": input.screenSource,
            "screen_geometry": input.screenGeometry, "selected_text": input.selectedText,
            "ocr_may_be_inaccurate": input.ocr, "room_observation": input.room, "uncertain_calibrated_gaze": input.gaze
        ]
        try verify(packed.contextText, maximum: 24_576, originals: originals)
        try verify(packed.observationText, maximum: 16_384, originals: originals)
        try verify(packed.localText, maximum: 6_000, originals: originals)
        let local = try fields(packed.localText)
        assert(local["user_selected_task"]?["value"] as? String == task)
        assert(local["uncertain_calibrated_gaze"]?["value"] as? String == gaze)
        assert(local["screen_geometry"]?["value"] as? String == geometry)
        assert(local["recent_conversation_reference"]?["value"] as? String == input.recentConversation)
        assert(local["home_calendar_context"]?["value"] as? String == input.home)
        assert(local["ocr_may_be_inaccurate"]?["truncated"] as? Bool == true)
        assert(local["selected_text"]?["truncated"] as? Bool == true)

        // Verify the production wire builder accepts the packed multibyte context
        // without touching user whitespace, original image paths, or image bytes.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("unchanged.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3])
        try bytes.write(to: image)
        let original = "  Explain this exact selected passage.\n保持我的原话 👨🏽‍💻\n"
        let wire = try MeshCodexClient.inputItems(for: MeshAgentRequest(originalMessage: original,
            contextText: packed.contextText, observationText: packed.observationText, localImageURLs: [image]))
        assert(wire[0]["text"] as? String == original)
        assert(wire.last?["path"] as? String == image.standardizedFileURL.path)
        let retainedImage = try Data(contentsOf: image)
        assert(retainedImage == bytes)

        // Every field saturated simultaneously, including JSON escape expansion.
        let giant = String(repeating: "\n\t\r\u{0000}\"\\🔬中", count: 5_000)
        input = MeshQuestionEvidence.Input(task: giant, finishCondition: giant, activity: giant,
            recentConversation: giant, home: giant, screenSource: giant, screenGeometry: giant,
            selectedText: giant, ocr: giant, room: giant, gaze: giant)
        let saturated = try MeshQuestionEvidence.prepare(input)
        for (text, maximum, count) in [(saturated.contextText, 24_576, 5), (saturated.observationText, 16_384, 6), (saturated.localText, 6_000, 11)] {
            let decoded = try fields(text)
            assert(text.utf8.count <= maximum && decoded.count == count)
            assert(decoded.values.allSatisfy { $0["truncated"] as? Bool == true && !($0["value"] as! String).isEmpty })
        }
        let empty = try MeshQuestionEvidence.prepare(.init())
        let emptyContext = try fields(empty.contextText), emptyObservation = try fields(empty.observationText), emptyLocal = try fields(empty.localText)
        assert(emptyContext.isEmpty && emptyObservation.isEmpty && emptyLocal.isEmpty)
        let short = try MeshQuestionEvidence.prepare(.init(selectedText: " \nExact e\u{301} 👨🏽‍💻\n "))
        let shortField = try fields(short.observationText)["selected_text"]!
        assert(shortField["value"] as? String == " \nExact e\u{301} 👨🏽‍💻\n ")
        assert(shortField["truncated"] as? Bool == false)
        print("PASS: dense multibyte and escaped evidence fits production limits; local task/gaze/geometry/history retained; original message and image untouched; explicit truncation and Unicode boundaries.")
    }
}

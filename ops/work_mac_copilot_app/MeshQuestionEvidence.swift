import Foundation

/// Bounded, field-preserving context for a question. The original question and
/// original images deliberately never enter this formatter.
enum MeshQuestionEvidence {
    static let contextByteLimit = 24_576
    static let observationByteLimit = 16_384
    static let localByteLimit = 6_000

    struct Input: Sendable {
        var task = ""
        var finishCondition = ""
        var activity = ""
        var recentConversation = ""
        var home = ""
        var screenSource = ""
        var screenGeometry = ""
        var selectedText = ""
        var ocr = ""
        var room = ""
        var gaze = ""
    }

    struct Prepared: Sendable {
        let contextText: String
        let observationText: String
        let localText: String
    }

    /// Counts describe the supplied field, before this formatter shortened it.
    /// Upstream capture bounds, if any, must still be described by the caller.
    private struct Field: Encodable {
        let name: String
        let value: String
        let truncated: Bool
        let originalUTF8Bytes: Int
        let includedUTF8Bytes: Int
    }

    private struct Envelope: Encodable {
        let schema = "mesh.question.evidence.v1"
        let fields: [Field]
    }

    enum FormattingError: LocalizedError {
        case invalidBudget
        var errorDescription: String? { "Question evidence could not be prepared within its text budget." }
    }

    static func prepare(_ input: Input) throws -> Prepared {
        // Budgets apply to each complete JSON field, including escaped text and
        // truncation metadata. Envelope punctuation is included by the final check.
        let context = try encode([
            ("user_selected_task", input.task, 2_048),
            ("finish_condition", input.finishCondition, 1_024),
            ("foreground_activity_observation", input.activity, 1_024),
            ("recent_conversation_reference", input.recentConversation, 7_168),
            ("home_calendar_context", input.home, 11_000)
        ], maximumBytes: contextByteLimit)
        let observation = try encode([
            ("screen_source_and_capture_time", input.screenSource, 768),
            ("screen_geometry", input.screenGeometry, 2_000),
            ("selected_text", input.selectedText, 4_096),
            ("ocr_may_be_inaccurate", input.ocr, 6_500),
            ("room_observation", input.room, 768),
            ("uncertain_calibrated_gaze", input.gaze, 1_800)
        ], maximumBytes: observationByteLimit)
        // Small-model context has independent reservations. Long OCR must never
        // consume the user's task, calibrated gaze, geometry, or recent exchange.
        let local = try encode([
            ("user_selected_task", input.task, 600),
            ("finish_condition", input.finishCondition, 320),
            ("uncertain_calibrated_gaze", input.gaze, 1_900),
            ("screen_geometry", input.screenGeometry, 650),
            ("selected_text", input.selectedText, 650),
            ("recent_conversation_reference", input.recentConversation, 400),
            ("home_calendar_context", input.home, 400),
            ("screen_source_and_capture_time", input.screenSource, 220),
            ("room_observation", input.room, 200),
            ("foreground_activity_observation", input.activity, 200),
            ("ocr_may_be_inaccurate", input.ocr, 350)
        ], maximumBytes: localByteLimit)
        return Prepared(contextText: context, observationText: observation, localText: local)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func encode(_ inputs: [(String, String, Int)], maximumBytes: Int) throws -> String {
        let encoder = encoder()
        let fields = try inputs.filter { !$0.1.isEmpty }.map { name, value, budget in
            try field(name: name, value: value, maximumBytes: budget, encoder: encoder)
        }
        let data = try encoder.encode(Envelope(fields: fields))
        guard data.count <= maximumBytes else { throw FormattingError.invalidBudget }
        return String(decoding: data, as: UTF8.self)
    }

    private static func field(name: String, value: String, maximumBytes: Int, encoder: JSONEncoder) throws -> Field {
        let originalCount = value.utf8.count
        func candidate(_ rawBytes: Int) -> Field {
            let excerpt = prefix(value, maximumUTF8Bytes: rawBytes)
            let included = excerpt.utf8.count
            return Field(name: name, value: excerpt, truncated: included < originalCount,
                         originalUTF8Bytes: originalCount, includedUTF8Bytes: included)
        }
        // Escaping quotes and control characters may expand JSON substantially;
        // searching the encoded size keeps even those fields within their budget.
        var low = 0, high = min(originalCount, maximumBytes)
        var best = candidate(0)
        guard try encoder.encode(best).count <= maximumBytes else { throw FormattingError.invalidBudget }
        while low <= high {
            let middle = low + (high - low) / 2
            let proposed = candidate(middle)
            if try encoder.encode(proposed).count <= maximumBytes {
                best = proposed; low = middle + 1
            } else { high = middle - 1 }
        }
        return best
    }

    /// End only at a Character boundary; an emoji/combining sequence is not split.
    private static func prefix(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        var end = value.startIndex, used = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let count = value[end..<next].utf8.count
            guard count <= maximumUTF8Bytes - used else { break }
            used += count; end = next
        }
        return String(value[..<end])
    }
}

import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ScreenCaptureKit
import Vision

private let claudeDesktopBundleID = "com.anthropic.claudefordesktop"
private let claudeCaptureHardLimitSeconds = 28_800
private let claudeCaptureMaximumOCRCharacters = 16_000

enum ClaudeTranscriptCaptureError: Error, CustomStringConvertible {
    case invalidChatName
    case accessibilityPermissionMissing
    case screenRecordingPermissionMissing
    case claudeNotRunning
    case claudeNotFrontmost
    case claudeWindowMissing
    case claudeWindowChanged
    case outputFailure(String)

    var description: String {
        switch self {
        case .invalidChatName: return "invalid_chat_name"
        case .accessibilityPermissionMissing:
            return "accessibility_permission_missing"
        case .screenRecordingPermissionMissing:
            return "screen_recording_permission_missing"
        case .claudeNotRunning: return "claude_not_running"
        case .claudeNotFrontmost: return "claude_not_frontmost"
        case .claudeWindowMissing: return "claude_window_missing"
        case .claudeWindowChanged: return "claude_window_changed"
        case .outputFailure(let code): return "output_failure:\(code)"
        }
    }
}

struct ClaudeTranscriptCaptureConfiguration {
    let chatName: String
    let outputRoot: URL
    let maxSeconds: Int
    let scrollIntervalSeconds: Double
    let scrollPixels: Int32

    init(
        chatName: String,
        outputRoot: URL,
        maxSeconds: Int = claudeCaptureHardLimitSeconds,
        scrollIntervalSeconds: Double = 4.0,
        scrollPixels: Int32 = -220
    ) throws {
        let normalizedName = chatName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedName.isEmpty,
              normalizedName.count <= 160,
              !normalizedName.contains("\n"),
              !normalizedName.contains("\r"),
              (60...claudeCaptureHardLimitSeconds).contains(maxSeconds),
              (2.0...15.0).contains(scrollIntervalSeconds),
              (-500 ... -20).contains(scrollPixels),
              outputRoot.path.hasPrefix("/") else {
            throw ClaudeTranscriptCaptureError.invalidChatName
        }
        self.chatName = normalizedName
        self.outputRoot = outputRoot.standardizedFileURL
        self.maxSeconds = maxSeconds
        self.scrollIntervalSeconds = scrollIntervalSeconds
        self.scrollPixels = scrollPixels
    }
}

private struct ClaudeOCRObservation: Codable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct ClaudeOCRFrame: Codable {
    let schema_version: Int
    let sequence: Int
    let observed_at: String
    let text_sha256: String
    let observations: [ClaudeOCRObservation]
}

private struct ClaudeTranscriptMessage: Codable {
    let schema_version: Int
    let message_id: String
    let ordinal: Int
    let chat_name: String
    let role: String
    let role_confidence: Double
    let source_time: String?
    let source_time_confidence: Double
    let observed_at: String
    let text: String
    let text_sha256: String
    let evidence_frame_sequences: [Int]
}

struct ClaudeTranscriptCaptureReceipt: Codable {
    let schema_version: Int
    let status: String
    let capture_id: String
    let chat_name: String
    let target_bundle_id: String
    let target_window_id: UInt32
    let target_window_title_sha256: String
    let started_at: String
    let finished_at: String
    let duration_ms: Int
    let configured_max_seconds: Int
    let hard_limit_seconds: Int
    let frame_count: Int
    let ocr_attempts: Int
    let ocr_failures: Int
    let unique_ocr_frames: Int
    let scroll_events: Int
    let scrolls_with_ocr_change: Int
    let final_no_progress_cycles: Int
    let message_records: Int
    let user_message_records: Int
    let assistant_message_records: Int
    let unknown_role_records: Int
    let timestamped_message_records: Int
    let role_classification_ratio: Double
    let timestamp_observation_ratio: Double
    let duplicate_chunk_count: Int
    let captured_ocr_characters: Int
    let cursor_visible_in_capture: Bool
    let audio_captured: Bool
    let screenshots_or_video_saved: Bool
    let typing_or_submission_performed: Bool
    let application_switching_performed: Bool
    let network_transport_used: Bool
    let model_calls: Int
    let raw_evidence_local_only: Bool
    let starting_boundary_evidence: String
    let ending_boundary_evidence: String
    let completeness_status: String
    let stop_reason: String
    let frames_jsonl: String
    let messages_jsonl: String
    let transcript_markdown: String
    let sha256_manifest: String
}

private struct ClaudeTargetWindow {
    let application: NSRunningApplication
    let window: SCWindow
    let frame: CGRect
    let titleHash: String
}

private func claudeISO8601(_ date: Date = Date()) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func claudeSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func claudeSHA256(_ text: String) -> String {
    claudeSHA256(Data(text.utf8))
}

private func normalizedClaudeOCR(_ text: String) -> String {
    let lines = text
        .split(whereSeparator: \Character.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return String(lines.joined(separator: "\n").prefix(
        claudeCaptureMaximumOCRCharacters
    ))
}

private func safeClaudeTableSlug(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-_")
    )
    let mapped = value.unicodeScalars.map { scalar -> Character in
        allowed.contains(scalar) ? Character(String(scalar).lowercased()) : "-"
    }
    var result = String(mapped)
    while result.contains("--") {
        result = result.replacingOccurrences(of: "--", with: "-")
    }
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String((result.isEmpty ? "claude-chat" : result).prefix(64))
}

private final class ClaudeOCRCollector: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private let handle: FileHandle
    private let chatName: String
    private var hashes: Set<String> = []
    private var messageHashes: Set<String> = []
    private var messages: [ClaudeTranscriptMessage] = []
    private var latestFrameHash: String?
    private var lastProcessedAt = Date.distantPast
    private var _frameCount = 0
    private var _ocrAttempts = 0
    private var _ocrFailures = 0
    private var _uniqueFrameCount = 0
    private var _duplicateChunkCount = 0
    private var _capturedOCRCharacters = 0

    init(framesURL: URL, chatName: String) throws {
        self.chatName = chatName
        guard FileManager.default.createFile(
            atPath: framesURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ClaudeTranscriptCaptureError.outputFailure(
                "frames_file_create_failed"
            )
        }
        handle = try FileHandle(forWritingTo: framesURL)
    }

    deinit { try? handle.close() }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frameCount
    }

    var uniqueFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _uniqueFrameCount
    }

    var extractedMessages: [ClaudeTranscriptMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    var duplicateChunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _duplicateChunkCount
    }

    var capturedOCRCharacters: Int {
        lock.lock()
        defer { lock.unlock() }
        return _capturedOCRCharacters
    }

    var ocrAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _ocrAttempts
    }

    var ocrFailures: Int {
        lock.lock()
        defer { lock.unlock() }
        return _ocrFailures
    }

    func latestHash() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrameHash
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        lock.lock()
        _frameCount += 1
        lock.unlock()
        guard Date().timeIntervalSince(lastProcessedAt) >= 1.0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastProcessedAt = Date()
        lock.lock()
        _ocrAttempts += 1
        lock.unlock()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            ).perform([request])
        } catch {
            lock.lock()
            _ocrFailures += 1
            lock.unlock()
            return
        }
        guard let results = request.results, !results.isEmpty else { return }
        let observations = results.compactMap { observation -> ClaudeOCRObservation? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let text = candidate.string.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return ClaudeOCRObservation(
                text: text,
                confidence: candidate.confidence,
                x: box.minX,
                y: box.minY,
                width: box.width,
                height: box.height
            )
        }.sorted {
            if abs($0.y - $1.y) > 0.012 { return $0.y > $1.y }
            return $0.x < $1.x
        }
        guard !observations.isEmpty else { return }
        let joined = normalizedClaudeOCR(
            observations.map(\.text).joined(separator: "\n")
        )
        guard !joined.isEmpty else { return }
        let digest = claudeSHA256(joined)

        lock.lock()
        guard !hashes.contains(digest) else {
            lock.unlock()
            return
        }
        hashes.insert(digest)
        let frame = ClaudeOCRFrame(
            schema_version: 1,
            sequence: _uniqueFrameCount + 1,
            observed_at: claudeISO8601(),
            text_sha256: digest,
            observations: observations
        )
        _uniqueFrameCount += 1
        latestFrameHash = digest
        _capturedOCRCharacters += observations.reduce(0) {
            $0 + $1.text.count
        }
        for chunk in transcriptChunks(from: frame) {
            let text = normalizedClaudeOCR(
                chunk.map(\.text).joined(separator: "\n")
            )
            guard text.count >= 3 else { continue }
            let messageDigest = claudeSHA256(text.lowercased())
            if messageHashes.contains(messageDigest) {
                _duplicateChunkCount += 1
                continue
            }
            messageHashes.insert(messageDigest)
            let role = classifyClaudeRole(chunk)
            let time = sourceTime(in: text)
            messages.append(ClaudeTranscriptMessage(
                schema_version: 1,
                message_id: "msg-\(String(messageDigest.prefix(16)))",
                ordinal: messages.count + 1,
                chat_name: chatName,
                role: role.role,
                role_confidence: role.confidence,
                source_time: time,
                source_time_confidence: time == nil ? 0 : 0.70,
                observed_at: frame.observed_at,
                text: text,
                text_sha256: messageDigest,
                evidence_frame_sequences: [frame.sequence]
            ))
        }
        lock.unlock()

        if let data = try? JSONEncoder().encode(frame) {
            handle.write(data)
            handle.write(Data([0x0a]))
            try? handle.synchronize()
        }
    }
}

private func ensureClaudeCapturePermissions() throws {
    // Permission prompts are owned by the menu-bar UI before a run is armed.
    // The capture runner only accepts an already-authorized process identity;
    // it must never throw a failure alert on top of a still-pending macOS TCC
    // prompt.
    guard AXIsProcessTrusted() else {
        throw ClaudeTranscriptCaptureError.accessibilityPermissionMissing
    }
    guard CGPreflightScreenCaptureAccess() else {
        throw ClaudeTranscriptCaptureError.screenRecordingPermissionMissing
    }
}

private func resolveClaudeTargetWindow() async throws -> ClaudeTargetWindow {
    guard let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: claudeDesktopBundleID
    ).first(where: { !$0.isTerminated }) else {
        throw ClaudeTranscriptCaptureError.claudeNotRunning
    }
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == claudeDesktopBundleID else {
        throw ClaudeTranscriptCaptureError.claudeNotFrontmost
    }
    guard let ordered = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]],
          let focused = ordered.compactMap({ info -> (CGWindowID, CGRect)? in
              guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                        == app.processIdentifier,
                    (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                    let number = info[kCGWindowNumber as String] as? NSNumber,
                    let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                    let frame = CGRect(dictionaryRepresentation: bounds),
                    frame.width >= 700,
                    frame.height >= 500 else { return nil }
              return (CGWindowID(number.uint32Value), frame)
          }).first else {
        throw ClaudeTranscriptCaptureError.claudeWindowMissing
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
    )
    guard let window = content.windows.first(where: {
        $0.windowID == focused.0
            && $0.owningApplication?.bundleIdentifier == claudeDesktopBundleID
            && $0.isOnScreen
            && $0.windowLayer == 0
    }) else {
        throw ClaudeTranscriptCaptureError.claudeWindowMissing
    }
    return ClaudeTargetWindow(
        application: app,
        window: window,
        frame: focused.1,
        titleHash: claudeSHA256(window.title ?? "")
    )
}

private func validateClaudeTarget(_ target: ClaudeTargetWindow) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == claudeDesktopBundleID,
          !target.application.isTerminated,
          let windows = CGWindowListCopyWindowInfo(
              [.optionOnScreenOnly, .excludeDesktopElements],
              kCGNullWindowID
          ) as? [[String: Any]] else { return false }
    return windows.contains { info in
        guard (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                == target.window.windowID,
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == target.application.processIdentifier,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds)
        else { return false }
        let delta = abs(frame.minX - target.frame.minX)
            + abs(frame.minY - target.frame.minY)
            + abs(frame.width - target.frame.width)
            + abs(frame.height - target.frame.height)
        return delta <= 12
    }
}

private func postClaudeMouseMove(_ point: CGPoint) {
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    )?.post(tap: .cghidEventTap)
}

private func postClaudeScroll(_ pixels: Int32) {
    CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: pixels,
        wheel2: 0,
        wheel3: 0
    )?.post(tap: .cghidEventTap)
}

private let timestampPattern = try! NSRegularExpression(
    pattern: #"(?i)\b(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+)?(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s+\d{1,2}(?:,\s+\d{4})?|\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?)?(?:\s+|^)\d{1,2}:\d{2}(?:\s*[ap]m)?\b"#
)

private func sourceTime(in text: String) -> String? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = timestampPattern.firstMatch(in: text, range: range),
          let swiftRange = Range(match.range, in: text) else { return nil }
    return String(text[swiftRange])
}

private func classifyClaudeRole(_ observations: [ClaudeOCRObservation]) -> (
    role: String,
    confidence: Double
) {
    guard !observations.isEmpty else { return ("unknown", 0) }
    let weighted = observations.reduce((x: 0.0, weight: 0.0)) { result, item in
        let weight = max(0.01, Double(item.text.count))
        return (result.x + (item.x + item.width / 2) * weight, result.weight + weight)
    }
    let midpoint = weighted.x / max(0.01, weighted.weight)
    let narrowRight = observations.allSatisfy { $0.x >= 0.42 || $0.width <= 0.52 }
    if midpoint >= 0.64, narrowRight { return ("user", min(0.95, 0.55 + midpoint / 3)) }
    if midpoint <= 0.55 { return ("assistant", min(0.92, 0.62 + (0.55 - midpoint))) }
    return ("unknown", 0.35)
}

private let claudeChromeFragments = [
    "new chat", "recents", "projects", "artifacts", "settings", "help",
    "send message", "search", "claude", "upgrade",
]

private func transcriptChunks(from frame: ClaudeOCRFrame) -> [[ClaudeOCRObservation]] {
    let content = frame.observations.filter { item in
        guard item.y >= 0.10, item.y <= 0.91,
              item.x >= 0.18, item.x <= 0.97 else { return false }
        let normalized = item.text.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return !claudeChromeFragments.contains(normalized)
    }
    guard !content.isEmpty else { return [] }
    var chunks: [[ClaudeOCRObservation]] = []
    var current: [ClaudeOCRObservation] = []
    var priorY: Double?
    for item in content {
        if let priorY, abs(priorY - item.y) > 0.075, !current.isEmpty {
            chunks.append(current)
            current = []
        }
        current.append(item)
        priorY = item.y
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

private func writeJSONLines<T: Encodable>(_ values: [T], to url: URL) throws {
    guard FileManager.default.createFile(
        atPath: url.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw ClaudeTranscriptCaptureError.outputFailure("jsonl_create_failed")
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for value in values {
        handle.write(try encoder.encode(value))
        handle.write(Data([0x0a]))
    }
    try handle.synchronize()
}

private func writeClaudeTranscript(
    messages: [ClaudeTranscriptMessage],
    chatName: String,
    to url: URL
) throws {
    var value = "# \(chatName)\n\n"
    value += "Local-only OCR reconstruction of one user-selected Claude Desktop conversation.\n\n"
    value += "> Role and source-time confidence are measured. Unknown values remain explicit. Raw OCR evidence is retained in `frames.jsonl`.\n\n"
    for message in messages {
        let time = message.source_time ?? "source time unknown"
        value += "## \(message.ordinal). \(message.role) — \(time)\n\n"
        value += "Message ID: `\(message.message_id)`  \n"
        value += "Text SHA-256: `\(message.text_sha256)`  \n"
        value += "Role confidence: \(String(format: "%.2f", message.role_confidence))  \n"
        value += "Evidence frame: \(message.evidence_frame_sequences.map(String.init).joined(separator: ", "))\n\n"
        value += "\(message.text)\n\n"
    }
    try value.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
}

private func writeClaudeManifest(files: [URL], to url: URL) throws {
    let lines = try files.map { file -> String in
        let data = try Data(contentsOf: file)
        return "\(claudeSHA256(data))  \(file.lastPathComponent)"
    }
    try (lines.joined(separator: "\n") + "\n").write(
        to: url,
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
}

private func isClaudeStreamAlreadyStopped(_ error: Error) -> Bool {
    let nsError = error as NSError
    // ScreenCaptureKit may end a window stream before the bounded runner asks
    // it to stop. In that state stopCapture() reports -3808 even though capture
    // has already stopped successfully. Treat only that exact framework error
    // as an idempotent stop so the local transcript artifacts can be finalized.
    return nsError.domain == SCStreamErrorDomain && nsError.code == -3808
}

final class ClaudeTranscriptCaptureRunner {
    private let stopLock = NSLock()
    private var stopRequested = false

    func requestStop() {
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
    }

    private func shouldStop() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    func run(
        configuration: ClaudeTranscriptCaptureConfiguration
    ) async throws -> ClaudeTranscriptCaptureReceipt {
        try ensureClaudeCapturePermissions()
        let started = Date()
        let captureID = UUID().uuidString.lowercased()
        let runDirectory = configuration.outputRoot
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(
                "\(safeClaudeTableSlug(configuration.chatName))-\(captureID)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let framesURL = runDirectory.appendingPathComponent("frames.jsonl")
        let messagesURL = runDirectory.appendingPathComponent("messages.jsonl")
        let transcriptURL = runDirectory.appendingPathComponent("transcript.md")
        let receiptURL = runDirectory.appendingPathComponent("receipt.json")
        let manifestURL = runDirectory.appendingPathComponent("SHA256SUMS")
        let target = try await resolveClaudeTargetWindow()
        let collector = try ClaudeOCRCollector(
            framesURL: framesURL,
            chatName: configuration.chatName
        )

        let streamConfiguration = SCStreamConfiguration()
        let maximumWidth = 1_728
        let scale = min(
            1.0,
            Double(maximumWidth) / Double(max(1.0, target.window.frame.width))
        )
        streamConfiguration.width = max(
            1,
            Int(target.window.frame.width * scale)
        )
        streamConfiguration.height = max(
            1,
            Int(target.window.frame.height * scale)
        )
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        streamConfiguration.queueDepth = 3
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = false
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let stream = SCStream(
            filter: filter,
            configuration: streamConfiguration,
            delegate: nil
        )
        try stream.addStreamOutput(
            collector,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(
                label: "work-mac.claude-transcript.frames"
            )
        )
        try await stream.startCapture()

        var scrollEvents = 0
        var unchangedCycles = 0
        var scrollsWithOCRChange = 0
        var priorHash = collector.latestHash()
        var stopReason = "configured_deadline"
        let hoverYFractions = [0.25, 0.42, 0.59, 0.76]
        while Date().timeIntervalSince(started) < Double(configuration.maxSeconds) {
            if shouldStop() {
                stopReason = "user_requested_stop"
                break
            }
            guard validateClaudeTarget(target) else {
                stopReason = "target_focus_or_window_changed"
                break
            }
            let hoverY = hoverYFractions[scrollEvents % hoverYFractions.count]
            postClaudeMouseMove(CGPoint(
                x: target.frame.minX + target.frame.width * 0.76,
                y: target.frame.minY + target.frame.height * hoverY
            ))
            try await Task.sleep(nanoseconds: 700_000_000)
            postClaudeScroll(configuration.scrollPixels)
            scrollEvents += 1
            try await Task.sleep(
                nanoseconds: UInt64(
                    configuration.scrollIntervalSeconds * 1_000_000_000
                )
            )
            let latestHash = collector.latestHash()
            if latestHash == priorHash {
                unchangedCycles += 1
            } else {
                unchangedCycles = 0
                scrollsWithOCRChange += 1
                priorHash = latestHash
            }
            if unchangedCycles >= 12, scrollEvents >= 16 {
                stopReason = "repeated_ocr_at_chat_boundary"
                break
            }
        }
        do {
            try await stream.stopCapture()
        } catch {
            guard isClaudeStreamAlreadyStopped(error) else { throw error }
        }

        let messages = collector.extractedMessages
        try writeJSONLines(messages, to: messagesURL)
        try writeClaudeTranscript(
            messages: messages,
            chatName: configuration.chatName,
            to: transcriptURL
        )
        let userCount = messages.filter { $0.role == "user" }.count
        let assistantCount = messages.filter { $0.role == "assistant" }.count
        let unknownCount = messages.filter { $0.role == "unknown" }.count
        let timestampCount = messages.filter { $0.source_time != nil }.count
        let denominator = max(1, messages.count)
        let finished = Date()
        let candidateBottom = stopReason == "repeated_ocr_at_chat_boundary"
        let receipt = ClaudeTranscriptCaptureReceipt(
            schema_version: 1,
            status: candidateBottom
                ? "completed_local_only_unverified"
                : "stopped_local_only_partial",
            capture_id: captureID,
            chat_name: configuration.chatName,
            target_bundle_id: claudeDesktopBundleID,
            target_window_id: target.window.windowID,
            target_window_title_sha256: target.titleHash,
            started_at: claudeISO8601(started),
            finished_at: claudeISO8601(finished),
            duration_ms: max(1, Int(finished.timeIntervalSince(started) * 1_000)),
            configured_max_seconds: configuration.maxSeconds,
            hard_limit_seconds: claudeCaptureHardLimitSeconds,
            frame_count: collector.frameCount,
            ocr_attempts: collector.ocrAttempts,
            ocr_failures: collector.ocrFailures,
            unique_ocr_frames: collector.uniqueFrameCount,
            scroll_events: scrollEvents,
            scrolls_with_ocr_change: scrollsWithOCRChange,
            final_no_progress_cycles: unchangedCycles,
            message_records: messages.count,
            user_message_records: userCount,
            assistant_message_records: assistantCount,
            unknown_role_records: unknownCount,
            timestamped_message_records: timestampCount,
            role_classification_ratio: Double(userCount + assistantCount)
                / Double(denominator),
            timestamp_observation_ratio: Double(timestampCount)
                / Double(denominator),
            duplicate_chunk_count: collector.duplicateChunkCount,
            captured_ocr_characters: collector.capturedOCRCharacters,
            cursor_visible_in_capture: true,
            audio_captured: false,
            screenshots_or_video_saved: false,
            typing_or_submission_performed: false,
            application_switching_performed: false,
            network_transport_used: false,
            model_calls: 0,
            raw_evidence_local_only: true,
            starting_boundary_evidence: "user_declared_top_not_independently_verified",
            ending_boundary_evidence: candidateBottom
                ? "repeated_ocr_candidate_bottom_requires_review"
                : "not_reached_or_not_proven",
            completeness_status: "unverified_requires_attended_review",
            stop_reason: stopReason,
            frames_jsonl: framesURL.path,
            messages_jsonl: messagesURL.path,
            transcript_markdown: transcriptURL.path,
            sha256_manifest: manifestURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: receiptURL.path
        )
        try writeClaudeManifest(
            files: [framesURL, messagesURL, transcriptURL, receiptURL],
            to: manifestURL
        )
        return receipt
    }
}

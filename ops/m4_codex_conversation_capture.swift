import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ScreenCaptureKit
import Vision

private let allowedBundleID = "com.openai.codex"
private let maximumRunSeconds = 3_600
private let maximumOCRCharacters = 20_000

private enum CaptureRunnerError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case accessibilityPermissionMissing
    case screenRecordingPermissionMissing
    case targetNotRunning
    case targetNotFrontmost
    case targetWindowMissing
    case outputFailure(String)

    var description: String {
        switch self {
        case .invalidArguments(let code): return "invalid_arguments:\(code)"
        case .accessibilityPermissionMissing: return "accessibility_permission_missing"
        case .screenRecordingPermissionMissing: return "screen_recording_permission_missing"
        case .targetNotRunning: return "target_not_running"
        case .targetNotFrontmost: return "target_not_frontmost"
        case .targetWindowMissing: return "target_window_missing"
        case .outputFailure(let code): return "output_failure:\(code)"
        }
    }
}

private struct RunnerConfiguration {
    let outputRoot: URL
    let maxSeconds: Int
    let scrollIntervalSeconds: Double
    let scrollPixels: Int32
    let hoverXFraction: Double
    let hoverYFraction: Double
    let tabProbeEnabled: Bool

    static func parse(_ arguments: [String]) throws -> RunnerConfiguration {
        var values: [String: String] = [:]
        var index = 0
        while index + 1 < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), values[key] == nil else {
                throw CaptureRunnerError.invalidArguments("duplicate_or_unknown_key")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard index == arguments.count else {
            throw CaptureRunnerError.invalidArguments("missing_value")
        }
        let allowedKeys: Set<String> = [
            "--output-root",
            "--max-seconds",
            "--scroll-interval-seconds",
            "--scroll-pixels",
            "--hover-x-fraction",
            "--hover-y-fraction",
            "--tab-probe",
            "--target-bundle-id",
        ]
        guard Set(values.keys).isSubset(of: allowedKeys) else {
            throw CaptureRunnerError.invalidArguments("unsupported_key")
        }
        guard values["--target-bundle-id", default: allowedBundleID] == allowedBundleID else {
            throw CaptureRunnerError.invalidArguments("target_not_allowlisted")
        }
        guard let outputPath = values["--output-root"], outputPath.hasPrefix("/") else {
            throw CaptureRunnerError.invalidArguments("absolute_output_required")
        }
        let outputRoot = URL(fileURLWithPath: outputPath, isDirectory: true)
            .standardizedFileURL
        guard !outputRoot.pathComponents.contains("..") else {
            throw CaptureRunnerError.invalidArguments("unsafe_output_path")
        }
        let maxSeconds = Int(values["--max-seconds", default: "600"]) ?? -1
        guard (30...maximumRunSeconds).contains(maxSeconds) else {
            throw CaptureRunnerError.invalidArguments("max_seconds_out_of_range")
        }
        let interval = Double(values["--scroll-interval-seconds", default: "4.0"]) ?? -1
        guard interval >= 2.0, interval <= 15.0 else {
            throw CaptureRunnerError.invalidArguments("scroll_interval_out_of_range")
        }
        let scrollPixels = Int32(values["--scroll-pixels", default: "180"]) ?? 0
        guard (20...500).contains(scrollPixels) else {
            throw CaptureRunnerError.invalidArguments("scroll_pixels_out_of_range")
        }
        let hoverX = Double(values["--hover-x-fraction", default: "0.78"]) ?? -1
        let hoverY = Double(values["--hover-y-fraction", default: "0.52"]) ?? -1
        guard (0.10...0.95).contains(hoverX), (0.10...0.90).contains(hoverY) else {
            throw CaptureRunnerError.invalidArguments("hover_fraction_out_of_range")
        }
        let tabProbeText = values["--tab-probe", default: "on"]
        guard ["on", "off"].contains(tabProbeText) else {
            throw CaptureRunnerError.invalidArguments("invalid_tab_probe")
        }
        return RunnerConfiguration(
            outputRoot: outputRoot,
            maxSeconds: maxSeconds,
            scrollIntervalSeconds: interval,
            scrollPixels: scrollPixels,
            hoverXFraction: hoverX,
            hoverYFraction: hoverY,
            tabProbeEnabled: tabProbeText == "on"
        )
    }
}

private struct OCRReceiptEvent: Codable {
    let observed_at: String
    let sequence: Int
    let text_sha256: String
    let text: String
}

private struct TabProbeReceipt: Codable {
    let attempted: Bool
    let restored: Bool
    let ocr_changed_after_forward_shortcut: Bool
    let before_sha256: String?
    let after_sha256: String?
    let restored_sha256: String?
    let before_after_line_similarity: Double?
    let before_restored_line_similarity: Double?
    let interpretation: String
}

private struct FinalReceipt: Codable {
    let schema_version: Int
    let status: String
    let target_bundle_id: String
    let started_at: String
    let finished_at: String
    let duration_ms: Int
    let configured_max_seconds: Int
    let hard_limit_seconds: Int
    let frame_count: Int
    let unique_ocr_blocks: Int
    let scroll_events: Int
    let cursor_visible_in_capture: Bool
    let audio_captured: Bool
    let typing_or_submission_performed: Bool
    let network_transport_used: Bool
    let raw_evidence_local_only: Bool
    let stop_reason: String
    let tab_probe: TabProbeReceipt
    let events_jsonl: String
    let timeline_markdown: String
}

private func iso8601(_ date: Date = Date()) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func normalizedOCR(_ text: String) -> String {
    let lines = text
        .split(whereSeparator: \Character.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return String(lines.joined(separator: "\n").prefix(maximumOCRCharacters))
}

private final class OCRStreamCollector: NSObject, SCStreamOutput {
    private let queue = DispatchQueue(label: "m4.codex.capture.ocr")
    private let lock = NSLock()
    private let eventsHandle: FileHandle
    private var hashes: Set<String> = []
    private var events: [OCRReceiptEvent] = []
    private var lastProcessedAt = Date.distantPast
    private var _frameCount = 0

    init(eventsURL: URL) throws {
        guard FileManager.default.createFile(
            atPath: eventsURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CaptureRunnerError.outputFailure("events_file_create_failed")
        }
        eventsHandle = try FileHandle(forWritingTo: eventsURL)
    }

    deinit {
        try? eventsHandle.close()
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frameCount
    }

    var uniqueEvents: [OCRReceiptEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func latestHash() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return events.last?.text_sha256
    }

    func latestText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return events.last?.text
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
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        lastProcessedAt = Date()
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
            return
        }
        guard let observations = request.results,
              !observations.isEmpty else { return }
        let text = normalizedOCR(
            observations.compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        )
        guard !text.isEmpty else { return }
        let digest = sha256(text)
        lock.lock()
        guard !hashes.contains(digest) else {
            lock.unlock()
            return
        }
        hashes.insert(digest)
        let event = OCRReceiptEvent(
            observed_at: iso8601(),
            sequence: events.count + 1,
            text_sha256: digest,
            text: text
        )
        events.append(event)
        lock.unlock()
        if let line = try? JSONEncoder().encode(event) {
            eventsHandle.write(line)
            eventsHandle.write(Data([0x0a]))
            try? eventsHandle.synchronize()
        }
    }
}

private func postMouseMove(to point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

private func postScroll(pixels: Int32) {
    CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: pixels,
        wheel2: 0,
        wheel3: 0
    )?.post(tap: .cghidEventTap)
}

private func postControlTab(shift: Bool) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: false) else {
        return
    }
    var flags: CGEventFlags = [.maskControl]
    if shift { flags.insert(.maskShift) }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private func writeTimeline(events: [OCRReceiptEvent], to url: URL) throws {
    var markdown = "# Local Codex conversation capture\n\n"
    markdown += "Raw OCR evidence from one authorized personal Codex conversation. "
    markdown += "It remains local to this Mac. Overlapping blocks are intentionally retained for auditability.\n\n"
    for event in events {
        markdown += "## OCR block \(event.sequence) — \(event.observed_at)\n\n"
        markdown += "SHA-256: `\(event.text_sha256)`\n\n"
        markdown += "```text\n\(event.text)\n```\n\n"
    }
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func lineSimilarity(_ lhs: String?, _ rhs: String?) -> Double? {
    guard let lhs, let rhs else { return nil }
    let left = Set(lhs.split(whereSeparator: \Character.isNewline).map(String.init))
    let right = Set(rhs.split(whereSeparator: \Character.isNewline).map(String.init))
    guard !left.isEmpty || !right.isEmpty else { return 1.0 }
    let union = left.union(right).count
    guard union > 0 else { return 1.0 }
    return Double(left.intersection(right).count) / Double(union)
}

private func ensurePermissions() throws {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        throw CaptureRunnerError.accessibilityPermissionMissing
    }
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        throw CaptureRunnerError.screenRecordingPermissionMissing
    }
}

private func targetWindow() async throws -> (NSRunningApplication, SCWindow) {
    guard let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: allowedBundleID
    ).first(where: { !$0.isTerminated }) else {
        throw CaptureRunnerError.targetNotRunning
    }
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == allowedBundleID else {
        throw CaptureRunnerError.targetNotFrontmost
    }
    guard let orderedWindowInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]],
          let focusedWindow = orderedWindowInfo.compactMap({ info -> (CGWindowID, CGRect)? in
              guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                        == app.processIdentifier,
                    (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                    let number = info[kCGWindowNumber as String] as? NSNumber,
                    let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                    let frame = CGRect(dictionaryRepresentation: bounds),
                    frame.width >= 600,
                    frame.height >= 400 else {
                  return nil
              }
              return (CGWindowID(number.uint32Value), frame)
          }).first else {
        throw CaptureRunnerError.targetWindowMissing
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
    )
    let candidates = content.windows.filter {
        $0.owningApplication?.bundleIdentifier == allowedBundleID
            && $0.isOnScreen
            && $0.windowLayer == 0
            && $0.frame.width >= 600
            && $0.frame.height >= 400
    }
    let exactWindow = candidates.first(where: { $0.windowID == focusedWindow.0 })
    let frameMatchedWindow = candidates.min(by: { lhs, rhs in
        let leftDistance = abs(lhs.frame.minX - focusedWindow.1.minX)
            + abs(lhs.frame.minY - focusedWindow.1.minY)
            + abs(lhs.frame.width - focusedWindow.1.width)
            + abs(lhs.frame.height - focusedWindow.1.height)
        let rightDistance = abs(rhs.frame.minX - focusedWindow.1.minX)
            + abs(rhs.frame.minY - focusedWindow.1.minY)
            + abs(rhs.frame.width - focusedWindow.1.width)
            + abs(rhs.frame.height - focusedWindow.1.height)
        return leftDistance < rightDistance
    })
    guard let window = exactWindow ?? frameMatchedWindow else {
        throw CaptureRunnerError.targetWindowMissing
    }
    return (app, window)
}

private func runCapture(_ config: RunnerConfiguration) async throws -> FinalReceipt {
    try ensurePermissions()
    try FileManager.default.createDirectory(
        at: config.outputRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let eventsURL = config.outputRoot.appendingPathComponent("events.jsonl")
    let timelineURL = config.outputRoot.appendingPathComponent("timeline.md")
    let receiptURL = config.outputRoot.appendingPathComponent("receipt.json")
    guard !FileManager.default.fileExists(atPath: eventsURL.path),
          !FileManager.default.fileExists(atPath: timelineURL.path),
          !FileManager.default.fileExists(atPath: receiptURL.path) else {
        throw CaptureRunnerError.outputFailure("output_must_be_new")
    }
    let started = Date()
    let (_, window) = try await targetWindow()
    let collector = try OCRStreamCollector(eventsURL: eventsURL)
    let streamConfig = SCStreamConfiguration()
    let maximumWidth = 1_728
    let scale = min(1.0, Double(maximumWidth) / Double(max(1.0, window.frame.width)))
    streamConfig.width = max(1, Int(window.frame.width * scale))
    streamConfig.height = max(1, Int(window.frame.height * scale))
    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 2)
    streamConfig.queueDepth = 3
    streamConfig.showsCursor = true
    streamConfig.capturesAudio = false
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
    try stream.addStreamOutput(
        collector,
        type: .screen,
        sampleHandlerQueue: DispatchQueue(label: "m4.codex.capture.frames")
    )
    try await stream.startCapture()

    let hoverPoint = CGPoint(
        x: window.frame.minX + window.frame.width * config.hoverXFraction,
        y: window.frame.minY + window.frame.height * config.hoverYFraction
    )
    postMouseMove(to: hoverPoint)
    try await Task.sleep(nanoseconds: 2_000_000_000)

    var scrollEvents = 0
    var unchangedCycles = 0
    var priorHash = collector.latestHash()
    var stopReason = "configured_deadline"
    var tabReceipt = TabProbeReceipt(
        attempted: false,
        restored: false,
        ocr_changed_after_forward_shortcut: false,
        before_sha256: nil,
        after_sha256: nil,
        restored_sha256: nil,
        before_after_line_similarity: nil,
        before_restored_line_similarity: nil,
        interpretation: "tab_probe_disabled"
    )
    var tabProbeDone = !config.tabProbeEnabled

    while Date().timeIntervalSince(started) < Double(config.maxSeconds) {
        postMouseMove(to: hoverPoint)
        postScroll(pixels: config.scrollPixels)
        scrollEvents += 1
        let delay = UInt64(config.scrollIntervalSeconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: delay)
        let latestHash = collector.latestHash()
        if latestHash == priorHash {
            unchangedCycles += 1
        } else {
            unchangedCycles = 0
            priorHash = latestHash
        }

        if !tabProbeDone, scrollEvents >= 3 {
            tabProbeDone = true
            let before = collector.latestHash()
            let beforeText = collector.latestText()
            postControlTab(shift: false)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let after = collector.latestHash()
            let afterText = collector.latestText()
            postControlTab(shift: true)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let restored = collector.latestHash()
            let restoredText = collector.latestText()
            let forwardSimilarity = lineSimilarity(beforeText, afterText)
            let restoreSimilarity = lineSimilarity(beforeText, restoredText)
            let changed = (forwardSimilarity ?? 1.0) < 0.75
            let restoreVerified = (restoreSimilarity ?? 0.0) >= 0.75
            tabReceipt = TabProbeReceipt(
                attempted: true,
                restored: restoreVerified,
                ocr_changed_after_forward_shortcut: changed,
                before_sha256: before,
                after_sha256: after,
                restored_sha256: restored,
                before_after_line_similarity: forwardSimilarity,
                before_restored_line_similarity: restoreSimilarity,
                interpretation: changed && restoreVerified
                    ? "standard_control_tab_changed_visible_content_and_reverse_shortcut_restored_similar_content"
                    : changed
                        ? "standard_control_tab_changed_visible_content_but_restore_was_not_verified"
                        : "standard_control_tab_did_not_produce_a_meaningfully_distinct_ocr_state"
            )
        }

        if unchangedCycles >= 10, scrollEvents >= 12 {
            stopReason = "repeated_ocr_at_scroll_boundary"
            break
        }
    }

    try await stream.stopCapture()
    let events = collector.uniqueEvents
    try writeTimeline(events: events, to: timelineURL)
    let finished = Date()
    let receipt = FinalReceipt(
        schema_version: 1,
        status: "completed_local_only",
        target_bundle_id: allowedBundleID,
        started_at: iso8601(started),
        finished_at: iso8601(finished),
        duration_ms: max(1, Int(finished.timeIntervalSince(started) * 1_000)),
        configured_max_seconds: config.maxSeconds,
        hard_limit_seconds: maximumRunSeconds,
        frame_count: collector.frameCount,
        unique_ocr_blocks: events.count,
        scroll_events: scrollEvents,
        cursor_visible_in_capture: true,
        audio_captured: false,
        typing_or_submission_performed: false,
        network_transport_used: false,
        raw_evidence_local_only: true,
        stop_reason: stopReason,
        tab_probe: tabReceipt,
        events_jsonl: eventsURL.path,
        timeline_markdown: timelineURL.path
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(receipt)
    try data.write(to: receiptURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    return receipt
}

@main
private struct M4CodexConversationCaptureMain {
    static func main() async {
        do {
            let config = try RunnerConfiguration.parse(Array(CommandLine.arguments.dropFirst()))
            let receipt = try await runCapture(config)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(receipt))
            FileHandle.standardOutput.write(Data([0x0a]))
        } catch {
            FileHandle.standardError.write(Data("CAPTURE_FAILED:\(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}

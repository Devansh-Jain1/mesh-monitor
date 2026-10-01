import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ScreenCaptureKit
import Vision

private let threadID = "019fb1a7-9346-7331-adb3-7d262f4886ec"
#if M4_LOCAL_VOICE_SESSION
private let exactModel = "VoiceSession 0.3 • Parakeet • LFM2.5-VL-3B • Kokoro"
#else
private let exactModel = "gemma4:26b-a4b-it-q4_K_M"
#endif

private enum CopilotError: Error {
    case invalidArguments
    case invalidRequestID
    case invalidOutputDirectory
    case noDisplay
    case writerSetup
    case writerFailed
    case captureFailed
}

private func captureFailureMessage(_ error: Error) -> String {
    let value = error as NSError
    let permission = CGPreflightScreenCaptureAccess()
        ? "granted"
        : "not granted for this app identity"
    return (
        "Screen Recording permission: \(permission).\n"
        + "Failure: \(value.domain) code \(value.code) — "
        + value.localizedDescription
        + "\nNo frame or recording was transmitted."
    )
}

private struct RecordRequest {
    let requestID: String
    let outputDirectory: URL
    let maxSeconds: Int
    let includeAudio: Bool
}

private struct RecordReceipt: Encodable {
    let recording_sha256: String
    let recording_bytes: Int
    let duration_ms: Int
    let frame_count: Int
    let audio_included: Bool
    let visible_indicator_shown: Bool
    let raw_media_local_only: Bool
}

private struct ScreenContextSnapshot {
    let text: String
    let capturedAt: Date
}

private final class LiveScreenContextController: NSObject, SCStreamOutput {
    private let queue = DispatchQueue(label: "work-mac-private.screen-context")
    private let lock = NSLock()
    private var stream: SCStream?
    private var latest: ScreenContextSnapshot?
    private var lastProcessedAt = Date.distantPast
    private(set) var isRunning = false

    func start() async throws {
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CopilotError.captureFailed
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let mainDisplayID = (
            NSScreen.main?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.uint32Value
        guard let display = content.displays.first(where: {
            $0.displayID == mainDisplayID
        }) else {
            throw CopilotError.noDisplay
        }
        let configuration = SCStreamConfiguration()
        let maximumWidth = 1_728
        let scale = min(1.0, Double(maximumWidth) / Double(max(1, display.width)))
        configuration.width = max(1, Int(Double(display.width) * scale))
        configuration.height = max(1, Int(Double(display.height) * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.queueDepth = 2
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        isRunning = false
        clearSnapshot()
    }

    private func clearSnapshot() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    func snapshot(maxAgeSeconds: TimeInterval = 15) -> ScreenContextSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest,
              Date().timeIntervalSince(latest.capturedAt) <= maxAgeSeconds else {
            return nil
        }
        return latest
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              Date().timeIntervalSince(lastProcessedAt) >= 1.0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        lastProcessedAt = Date()
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation]
            else { return }
            let text = observations.compactMap {
                $0.topCandidates(1).first?.string
            }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            let bounded = String(text.prefix(4_000))
            self?.lock.lock()
            self?.latest = ScreenContextSnapshot(text: bounded, capturedAt: Date())
            self?.lock.unlock()
        }
        request.recognitionLevel = .fast
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
    }
}

private let liveScreenContext = LiveScreenContextController()

private func memoryCommand(
    _ command: String,
    payload: [String: Any]
) throws -> [String: Any] {
    let environment = ProcessInfo.processInfo.environment
    guard let python = environment["WORK_MAC_MEMORY_PYTHON"],
          python.hasPrefix("/"),
          let memoryCLI = environment["WORK_MAC_MEMORY_CLI"],
          memoryCLI.hasPrefix("/")
    else {
        throw CopilotError.invalidArguments
    }
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [
        memoryCLI,
        command,
        "--root",
        workspaceRoot().path,
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let body = try JSONSerialization.data(withJSONObject: payload)
    input.fileHandleForWriting.write(body)
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0,
          data.count <= 512 * 1_024,
          let decoded = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          decoded["ok"] as? Bool == true
    else {
        throw CopilotError.captureFailed
    }
    return decoded
}

private func modelCommandData(_ arguments: [String]) throws -> Data {
    let environment = ProcessInfo.processInfo.environment
    guard let python = environment["WORK_MAC_MODEL_PYTHON"],
          python.hasPrefix("/"),
          let modelCLI = environment["WORK_MAC_MODEL_CLI"],
          modelCLI.hasPrefix("/")
    else {
        throw CopilotError.invalidArguments
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [
        modelCLI,
        "--ollama",
        "http://127.0.0.1:11439",
    ] + arguments
    process.environment = [
        "HOME": NSHomeDirectory(),
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "PYTHONNOUSERSITE": "1",
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
        "TMPDIR": NSTemporaryDirectory(),
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let maximumBytes = 1_024 * 1_024
    var data = Data()
    while true {
        let remaining = maximumBytes + 1 - data.count
        let chunk = output.fileHandleForReading.readData(
            ofLength: min(64 * 1_024, remaining)
        )
        if chunk.isEmpty {
            break
        }
        data.append(chunk)
        if data.count > maximumBytes {
            process.terminate()
            process.waitUntilExit()
            throw CopilotError.captureFailed
        }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          !data.isEmpty else {
        throw CopilotError.captureFailed
    }
    return data
}

private func benchmarkCommandData(_ modelSpecs: [String]) throws -> Data {
    guard 1...8 ~= modelSpecs.count,
          modelSpecs.allSatisfy({
              !$0.isEmpty && $0.count <= 224
                  && !$0.contains("\n") && !$0.contains("\r")
          })
    else {
        throw CopilotError.invalidArguments
    }
    let environment = ProcessInfo.processInfo.environment
    guard let python = environment["WORK_MAC_BENCHMARK_PYTHON"],
          python.hasPrefix("/"),
          let benchmarkCLI = environment["WORK_MAC_BENCHMARK_CLI"],
          benchmarkCLI.hasPrefix("/")
    else {
        throw CopilotError.invalidArguments
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [
        benchmarkCLI,
        "--copilot-root", workspaceRoot().path,
        "--data-root", FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/actian", isDirectory: true).path,
    ] + modelSpecs.flatMap { ["--model", $0] }
    process.environment = [
        "HOME": NSHomeDirectory(),
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "PYTHONNOUSERSITE": "1",
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
        "TMPDIR": NSTemporaryDirectory(),
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let maximumBytes = 512 * 1_024
    var data = Data()
    while true {
        let chunk = output.fileHandleForReading.readData(
            ofLength: min(64 * 1_024, maximumBytes + 1 - data.count)
        )
        if chunk.isEmpty { break }
        data.append(chunk)
        if data.count > maximumBytes {
            process.terminate()
            process.waitUntilExit()
            throw CopilotError.captureFailed
        }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let decoded = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          decoded["ok"] as? Bool == true
    else {
        throw CopilotError.captureFailed
    }
    return data
}

private func inferenceCommandData(_ arguments: [String]) throws -> Data {
    let environment = ProcessInfo.processInfo.environment
    guard let python = environment["WORK_MAC_INFERENCE_PYTHON"],
          python.hasPrefix("/"),
          let runtime = environment["WORK_MAC_INFERENCE_CLI"],
          runtime.hasPrefix("/")
    else {
        throw CopilotError.invalidArguments
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [
        runtime,
        "--root",
        workspaceRoot().path,
    ] + arguments
    process.environment = [
        "HOME": NSHomeDirectory(),
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "PYTHONNOUSERSITE": "1",
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
        "TMPDIR": NSTemporaryDirectory(),
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let maximumBytes = 2 * 1_024 * 1_024
    var data = Data()
    while true {
        let remaining = maximumBytes + 1 - data.count
        let chunk = output.fileHandleForReading.readData(
            ofLength: min(64 * 1_024, remaining)
        )
        if chunk.isEmpty { break }
        data.append(chunk)
        if data.count > maximumBytes {
            process.terminate()
            process.waitUntilExit()
            throw CopilotError.captureFailed
        }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0, !data.isEmpty else {
        throw CopilotError.captureFailed
    }
    return data
}

private func inferenceStatusMessage(_ data: Data) throws -> String {
    guard let status = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          status["ok"] as? Bool == true,
          status["network_scope"] as? String == "fixed_loopback_only",
          status["provider_fallback_enabled"] as? Bool == false,
          let active = status["active"] as? [String: Any],
          let provider = active["provider"] as? String,
          let model = active["model"] as? String,
          let providers = status["providers"] as? [[String: Any]],
          providers.count == 3
    else {
        throw CopilotError.captureFailed
    }
    let rows = providers.compactMap { item -> String? in
        guard let name = item["provider"] as? String,
              let origin = item["origin"] as? String,
              origin.hasPrefix("http://127.0.0.1:")
        else { return nil }
        let reachable = item["reachable"] as? Bool == true
        let count = (item["model_count"] as? NSNumber)?.intValue ?? 0
        return "• \(name): \(reachable ? "ready" : "offline") • \(count) models • \(origin)"
    }
    return (
        "Active: \(provider) / \(model)\n\n"
        + rows.joined(separator: "\n")
        + "\n\nSwitching is attended and only accepts a model reported by the selected local server. No automatic fallback or cloud endpoint exists."
    )
}

private func compactModelSize(_ value: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(value))
}

private func modelInventoryMessage(_ data: Data) throws -> String {
    guard let inventory = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          inventory["ollama_origin"] as? String
            == "http://127.0.0.1:11439",
          inventory["model_calls"] as? NSNumber == 0,
          inventory["network_scope"] as? String
            == "controller_to_ollama_loopback_only",
          let manager = inventory["manager_lock"] as? [String: Any],
          manager["model"] as? String == exactModel,
          manager["immutable"] as? Bool == true,
          manager["present"] as? Bool == true,
          let managerDigest = manager["digest"] as? String,
          managerDigest.range(
            of: "^sha256:[0-9a-f]{64}$",
            options: .regularExpression
          ) != nil,
          let models = inventory["models"] as? [[String: Any]],
          let declaredCount = inventory["model_count"] as? NSNumber,
          declaredCount.intValue == models.count,
          models.count <= 128,
          let managerEntry = models.first(where: {
            $0["name"] as? String == exactModel
          }),
          managerEntry["digest_verified"] as? Bool == true,
          managerEntry["digest"] as? String == managerDigest,
          managerEntry["role"] as? String == "manager_locked"
    else {
        throw CopilotError.captureFailed
    }
    let visible = models.prefix(12).compactMap { model -> String? in
        guard let name = model["name"] as? String,
              name.count <= 128,
              let size = model["size_bytes"] as? NSNumber,
              size.intValue >= 0,
              let role = model["role"] as? String
        else {
            return nil
        }
        let roleLabel = role == "manager_locked"
            ? "manager locked"
            : "inventory only"
        let digest: String
        if let rawDigest = model["digest"] as? String,
           rawDigest.range(
            of: "^sha256:[0-9a-f]{64}$",
            options: .regularExpression
           ) != nil {
            digest = " • \(rawDigest.prefix(15))…"
        } else {
            digest = " • digest unverified"
        }
        return (
            "• \(name) — \(compactModelSize(size.intValue)) "
            + "• \(roleLabel)\(digest)"
        )
    }
    let remainder = models.count - visible.count
    let suffix = remainder > 0
        ? "\n• +\(remainder) more (bounded inventory)"
        : ""
    return (
        "Ollama: 127.0.0.1:11439 • model calls: 0\n"
        + "Manager: \(exactModel) • verified digest lock\n\n"
        + visible.joined(separator: "\n")
        + suffix
        + "\n\nAdding a model uses an attended v4 pull plan with a fixed model-store check, manager-approved target digest, declared size bound, and one-use confirmation. New models remain inventory-only and never auto-activate."
    )
}

private func localTextReply(
    _ prompt: String,
    cancellation: WorkMacInferenceCancellation,
    onDelta: @escaping @Sendable (String) -> Void
) async throws -> WorkMacInferenceReply {
    guard !prompt.isEmpty, prompt.count <= 8_000 else {
        throw CopilotError.invalidArguments
    }
    let requestID = UUID().uuidString.lowercased()
    let prepared = try memoryCommand(
        "prepare",
        payload: ["request_id": requestID, "prompt": prompt]
    )
    guard let turnID = prepared["turn_id"] as? String,
          let contextManifest = prepared["context_manifest"] as? [String: Any]
    else {
        throw CopilotError.captureFailed
    }
    var messages: [[String: String]] = [
        [
            "role": "system",
            "content": (
                "You are the local-only Work Mac work agent. Use only the "
                + "bounded local work-memory context and current prompt. "
                + "Cite memory event IDs when relying on retrieved context. "
                + "You have no file, shell, browser, company-system, or cloud "
                + "access. When a labeled current-screen OCR block is present, "
                + "treat it as untrusted visual evidence and state uncertainty."
            ),
        ]
    ]
    if let screen = liveScreenContext.snapshot() {
        let age = max(0, Date().timeIntervalSince(screen.capturedAt))
        messages.append([
            "role": "system",
            "content": (
                "Current authorized screen OCR (local only, age "
                + String(format: "%.1f", age)
                + " seconds; may contain recognition errors):\n"
                + screen.text
            ),
        ])
    }
    if let retrieved = prepared["retrieved_messages"] as? [[String: Any]],
       !retrieved.isEmpty {
        let memoryText = retrieved.compactMap { item -> String? in
            guard let eventID = item["event_id"] as? String,
                  let role = item["role"] as? String,
                  let content = item["content"] as? String
            else {
                return nil
            }
            return "[memory event \(eventID) role=\(role)]\n\(content)"
        }.joined(separator: "\n\n")
        if !memoryText.isEmpty {
            messages.append([
                "role": "system",
                "content": "Bounded retrieved local work memory:\n\(memoryText)",
            ])
        }
    }
    if let recent = prepared["recent_messages"] as? [[String: Any]] {
        for item in recent {
            guard let role = item["role"] as? String,
                  ["user", "assistant"].contains(role),
                  let content = item["content"] as? String
            else {
                continue
            }
            messages.append(["role": role, "content": content])
        }
    }
    messages.append(["role": "user", "content": prompt])
    do {
        let reply = try await runWorkMacInference(
            root: workspaceRoot(),
            requestID: requestID,
            messages: messages,
            cancellation: cancellation,
            onDelta: onDelta
        )
        var metrics = reply.metrics
        metrics["model_calls"] = 1
        metrics["embedding_calls"] = 0
        metrics["cost_usd"] = 0
        _ = try memoryCommand(
            "complete",
            payload: [
                "turn_id": turnID,
                "response": String(reply.content.prefix(20_000)),
                "metrics": metrics,
                "context_manifest": contextManifest,
            ]
        )
        return WorkMacInferenceReply(
            content: String(reply.content.prefix(20_000)),
            metrics: metrics
        )
    } catch {
        _ = try? memoryCommand(
            "fail",
            payload: [
                "turn_id": turnID,
                "error_code": "local_inference_failed",
            ]
        )
        throw error
    }
}

private func workspaceRoot() -> URL {
    if let configured = ProcessInfo.processInfo.environment["WORK_MAC_COPILOT_ROOT"],
       configured.hasPrefix("/") {
        return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WorkMacPrivateCopilot", isDirectory: true)
        .standardizedFileURL
}

private func parseRecordRequest(_ arguments: [String]) throws -> RecordRequest {
    guard arguments.first == "record-once" else {
        throw CopilotError.invalidArguments
    }
    var values: [String: String] = [:]
    var index = 1
    while index + 1 < arguments.count {
        let key = arguments[index]
        guard key.hasPrefix("--"), values[key] == nil else {
            throw CopilotError.invalidArguments
        }
        values[key] = arguments[index + 1]
        index += 2
    }
    guard index == arguments.count,
          Set(values.keys) == Set([
            "--request-id",
            "--output-dir",
            "--scope",
            "--max-seconds",
            "--audio",
          ]),
          values["--scope"] == "main-display",
          let requestID = values["--request-id"],
          requestID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{7,127}$"#,
            options: .regularExpression
          ) != nil,
          let secondsText = values["--max-seconds"],
          let maxSeconds = Int(secondsText),
          (1...300).contains(maxSeconds),
          let audioText = values["--audio"],
          ["on", "off"].contains(audioText),
          let outputPath = values["--output-dir"],
          outputPath.hasPrefix("/")
    else {
        throw CopilotError.invalidArguments
    }
    let outputDirectory = URL(
        fileURLWithPath: outputPath,
        isDirectory: true
    ).standardizedFileURL
    let root = workspaceRoot()
    guard outputDirectory.path.hasPrefix(root.path + "/"),
          outputDirectory.path == root.appendingPathComponent(
            "captures",
            isDirectory: true
          ).path
    else {
        throw CopilotError.invalidOutputDirectory
    }
    guard !requestID.contains("..") else {
        throw CopilotError.invalidRequestID
    }
    return RecordRequest(
        requestID: requestID,
        outputDirectory: outputDirectory,
        maxSeconds: maxSeconds,
        includeAudio: audioText == "on"
    )
}

private final class StreamRecorder: NSObject, SCStreamOutput {
    private let queue = DispatchQueue(label: "work-mac-private.capture")
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private(set) var frameCount = 0

    func record(_ request: RecordRequest) async throws -> RecordReceipt {
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let outputURL = request.outputDirectory.appendingPathComponent(
            "\(request.requestID)-\(timestamp).mov",
            isDirectory: false
        )
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let mainDisplayID = (
            NSScreen.main?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.uint32Value
        guard let display = content.displays.first(where: {
            $0.displayID == mainDisplayID
        }) else {
            throw CopilotError.noDisplay
        }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = request.includeAudio
        configuration.excludesCurrentProcessAudio = true

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: display.width,
                AVVideoHeightKey: display.height,
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw CopilotError.writerSetup
        }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if request.includeAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw CopilotError.writerSetup
            }
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else {
            throw writer.error ?? CopilotError.writerFailed
        }
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: nil
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: queue
        )
        if request.includeAudio {
            try stream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: queue
            )
        }
        let started = Date()
        try await stream.startCapture()
        try await Task.sleep(
            nanoseconds: UInt64(request.maxSeconds) * 1_000_000_000
        )
        do {
            try await stream.stopCapture()
        } catch {
            let stopError = error as NSError
            let alreadyStopped = stopError.code == -3808
                && stopError.domain.contains("ScreenCaptureKit")
            guard alreadyStopped else { throw error }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CopilotError.writerFailed
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let duration = max(1, Int(Date().timeIntervalSince(started) * 1000))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outputURL.path
        )
        return RecordReceipt(
            recording_sha256: hash,
            recording_bytes: byteCount,
            duration_ms: duration,
            frame_count: frameCount,
            audio_included: request.includeAudio,
            visible_indicator_shown: true,
            raw_media_local_only: true
        )
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard let writer, writer.status == .writing else {
            return
        }
        let timestamp = sampleBuffer.presentationTimeStamp
        if !sessionStarted, outputType == .screen {
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }
        guard sessionStarted else {
            return
        }
        if outputType == .screen,
           let videoInput,
           videoInput.isReadyForMoreMediaData,
           videoInput.append(sampleBuffer) {
            frameCount += 1
        } else if outputType == .audio,
                  let audioInput,
                  audioInput.isReadyForMoreMediaData {
            _ = audioInput.append(sampleBuffer)
        }
    }
}

@MainActor
private final class LocalChatWindowController: NSObject {
    private let window: NSWindow
    private let promptField: NSTextField
    private let outputView: NSTextView
    private let sendButton: NSButton
    private let cancelButton: NSButton
    private let statusLabel: NSTextField
    private var activeTask: Task<Void, Never>?
    private var activeCancellation: WorkMacInferenceCancellation?
    private var prewarmStarted = false
    var onAttentionChange: ((WorkMacAttentionState) -> Void)?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        promptField = NSTextField()
        outputView = NSTextView()
        sendButton = NSButton(
            title: "Send locally",
            target: nil,
            action: nil
        )
        cancelButton = NSButton(
            title: "Cancel",
            target: nil,
            action: nil
        )
        statusLabel = NSTextField(
            labelWithString: "One work chat • append-only local memory • no screen"
        )
        super.init()

        window.title = "Work Mac Private Local Agent"
        window.minSize = NSSize(width: 560, height: 380)
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content

        let modelLabel = NSTextField(
            labelWithString: "Runtime: selected local provider/model"
        )
        modelLabel.font = .boldSystemFont(ofSize: 12)
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(modelLabel)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        promptField.placeholderString = "Type a local prompt…"
        promptField.font = .systemFont(ofSize: 14)
        promptField.translatesAutoresizingMaskIntoConstraints = false
        promptField.target = self
        promptField.action = #selector(sendPrompt)
        content.addSubview(promptField)

        sendButton.target = self
        sendButton.action = #selector(sendPrompt)
        sendButton.bezelStyle = .rounded
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sendButton)

        cancelButton.target = self
        cancelButton.action = #selector(cancelPrompt)
        cancelButton.bezelStyle = .rounded
        cancelButton.isEnabled = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancelButton)

        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        outputView.string = (
            "Local chat shell opened; model health is unverified until a "
            + "request succeeds. One persistent Work Mac work conversation uses bounded "
            + "recent + FTS context. Raw memory stays local; nothing is sent "
            + "to the M4 bridge. TurboVec remains gated until an embedding "
            + "identity is explicitly authorized.\n"
        )
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = outputView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            modelLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            modelLabel.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: 16
            ),
            statusLabel.topAnchor.constraint(
                equalTo: modelLabel.bottomAnchor,
                constant: 4
            ),
            statusLabel.leadingAnchor.constraint(equalTo: modelLabel.leadingAnchor),
            promptField.topAnchor.constraint(
                equalTo: statusLabel.bottomAnchor,
                constant: 14
            ),
            promptField.leadingAnchor.constraint(equalTo: modelLabel.leadingAnchor),
            promptField.trailingAnchor.constraint(
                equalTo: cancelButton.leadingAnchor,
                constant: -10
            ),
            cancelButton.trailingAnchor.constraint(
                equalTo: sendButton.leadingAnchor,
                constant: -8
            ),
            cancelButton.centerYAnchor.constraint(equalTo: promptField.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 76),
            sendButton.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -16
            ),
            sendButton.centerYAnchor.constraint(equalTo: promptField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 118),
            scroll.topAnchor.constraint(
                equalTo: promptField.bottomAnchor,
                constant: 12
            ),
            scroll.leadingAnchor.constraint(equalTo: modelLabel.leadingAnchor),
            scroll.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -16
            ),
            scroll.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -16
            ),
        ])
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeFirstResponder(promptField)
        prewarmSelectedModel()
    }

    func prewarmSelectedModel() {
        guard !prewarmStarted else { return }
        prewarmStarted = true
        statusLabel.stringValue = "Loading selected local model…"
        sendButton.isEnabled = false
        onAttentionChange?(.working)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try inferenceCommandData(["prewarm"]) }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                statusLabel.stringValue = "Ready • selected model warm • local only"
                sendButton.isEnabled = true
                onAttentionChange?(.ready)
            case .failure:
                statusLabel.stringValue = (
                    "Prewarm failed • open Models • no cloud fallback"
                )
                sendButton.isEnabled = true
                onAttentionChange?(.blocked)
            }
        }
    }

    @objc private func sendPrompt() {
        let prompt = promptField.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !prompt.isEmpty, activeTask == nil else {
            return
        }
        promptField.stringValue = ""
        sendButton.isEnabled = false
        cancelButton.isEnabled = true
        statusLabel.stringValue = "Thinking locally…"
        onAttentionChange?(.working)
        outputView.string += "\nYou: \(prompt)\n\nWork Mac: "
        let cancellation = WorkMacInferenceCancellation()
        activeCancellation = cancellation
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await localTextReply(
                    prompt,
                    cancellation: cancellation,
                    onDelta: { [weak self] delta in
                        Task { @MainActor in
                            self?.outputView.string += delta
                            self?.outputView.scrollToEndOfDocument(nil)
                        }
                    }
                )
                let timing = compactInferenceMetrics(reply.metrics)
                outputView.string += timing.isEmpty
                    ? "\n"
                    : "\n[\(timing)]\n"
                statusLabel.stringValue = (
                    "Saved locally • \(timing) • no bridge result emitted"
                )
                onAttentionChange?(.completed)
            } catch {
                let code = safeInferenceErrorCode(error)
                outputView.string += (
                    "\nLocal request failed closed [\(code)]. "
                    + "No cloud fallback or data export ran.\n"
                )
                statusLabel.stringValue = "Failed closed • \(code)"
                onAttentionChange?(.blocked)
            }
            sendButton.isEnabled = true
            cancelButton.isEnabled = false
            activeCancellation = nil
            activeTask = nil
            outputView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func cancelPrompt() {
        guard activeTask != nil else { return }
        statusLabel.stringValue = "Cancelling local request…"
        activeCancellation?.cancel()
        activeTask?.cancel()
        cancelButton.isEnabled = false
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let recordRequest: RecordRequest?
    private let autoStartVoice: Bool
    private var statusItem: NSStatusItem?
    private var controlMenu: NSMenu?
    private var recordingPanel: NSPanel?
    private var screenContextPanel: NSPanel?
    private var screenContextMenuItem: NSMenuItem?
    private var claudeCaptureMenuItem: NSMenuItem?
    private var claudeCaptureStatusMenuItem: NSMenuItem?
    private var claudeCaptureArmingTask: Task<Void, Never>?
    private var notchMenuItem: NSMenuItem?
    private var activeRecorder: StreamRecorder?
    private var activeClaudeCapture: ClaudeTranscriptCaptureRunner?
    private lazy var chatWindow: LocalChatWindowController = {
        let controller = LocalChatWindowController()
        controller.onAttentionChange = { [weak self] state in
            self?.notchPanel.updateAttention(state)
        }
        return controller
    }()
    private lazy var notchPanel = WorkMacNotchPanelController(
        managerModel: exactModel,
        onOpenChat: { [weak self] in self?.showTextMode() },
        onMemory: { [weak self] in self?.showMemoryStatus() },
        onModels: { [weak self] in self?.showModelLibrary() },
        onVoice: { [weak self] in self?.showVoiceMode() },
        onCaptureClaude: { [weak self] in self?.captureOpenClaudeChat() },
        onRecord: { [weak self] in self?.recordOnce() },
        onExternalPreview: { [weak self] in self?.showExternalPreview() },
        onEmergencyStop: { [weak self] in self?.emergencyStop() },
        onRefresh: { [weak self] in self?.refreshNotchStatus() }
    )
#if M4_LOCAL_VOICE_SESSION
    private lazy var localVoiceSession: M4LocalVoiceSession = {
        let session = M4LocalVoiceSession()
        session.onStatus = { [weak self] message, color in
            let upper = message.uppercased()
            if upper.contains("THINK") || upper.contains("SCREEN") {
                // Remove our own expanded controls from the evidence frame.
                self?.notchPanel.collapse()
            }
            self?.notchPanel.updateLocalVoiceStatus(message, color: color)
        }
        session.onReadiness = { [weak self] message in
            self?.notchPanel.updateLocalVoiceReadiness(message)
        }
        session.onFailure = { [weak self] reason in
            self?.showNotice(
                title: "Local VoiceSession blocked",
                message: (
                    "\(reason)\n\n"
                    + "No cloud or Pi fallback was attempted. Microphone audio, "
                    + "transcripts, Kokoro audio, and receipts remain on this Mac."
                )
            )
        }
        return session
    }()
#endif

    init(recordRequest: RecordRequest?, autoStartVoice: Bool = false) {
        self.recordRequest = recordRequest
        self.autoStartVoice = autoStartVoice
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let recordRequest {
            showRecordingIndicator()
            Task {
                await runCommandLineRecording(recordRequest)
            }
            return
        }
        installMenuBar()
#if WORK_MAC_V5_SCOPED_BOOTSTRAP
        // V5 has an attended M4 geometry/runtime proof for the physical-notch
        // shell. Present the collapsed local control at login while retaining
        // the compact menu-bar fallback. This starts neither capture nor a
        // model; it only makes the already-installed control discoverable.
        if notchPanel.show() {
            notchMenuItem?.title = "Hide Notch Station"
        }
#if M4_LOCAL_VOICE_SESSION
        notchPanel.updateLocalVoiceStatus(
            "Voice stopped • press Voice to start",
            color: .systemOrange
        )
        if autoStartVoice {
            localVoiceSession.toggle()
            notchPanel.collapse()
        }
#endif
#endif
#if !WORK_MAC_V5_SCOPED_BOOTSTRAP
        chatWindow.prewarmSelectedModel()
#endif
    }

#if M4_LOCAL_VOICE_SESSION
    func applicationWillTerminate(_ notification: Notification) {
        _ = localVoiceSession.cancel()
    }
#endif

    private func installMenuBar() {
        let menu = NSMenu()
#if M4_LOCAL_VOICE_SESSION
        let identityTitle = "M4 Local Realtime Voice Notch"
#else
        let identityTitle = "Private Work Copilot"
#endif
        let identity = NSMenuItem(
            title: identityTitle,
            action: nil,
            keyEquivalent: ""
        )
        identity.isEnabled = false
        menu.addItem(identity)
        let model = NSMenuItem(
            title: "Default model: \(exactModel) • selectable in Models",
            action: nil,
            keyEquivalent: ""
        )
        model.isEnabled = false
        menu.addItem(model)
        menu.addItem(.separator())
        let claudeCapture = NSMenuItem(
            title: "Capture Open Claude Chat…",
            action: #selector(captureOpenClaudeChat),
            keyEquivalent: ""
        )
        claudeCapture.target = self
        menu.addItem(claudeCapture)
        claudeCaptureMenuItem = claudeCapture
        let claudeCaptureStatus = NSMenuItem(
            title: "Claude capture: ready",
            action: nil,
            keyEquivalent: ""
        )
        claudeCaptureStatus.isEnabled = false
        menu.addItem(claudeCaptureStatus)
        claudeCaptureStatusMenuItem = claudeCaptureStatus
        menu.addItem(.separator())
        let notch = NSMenuItem(
            title: "Show Notch Station",
            action: #selector(showNotchStation),
            keyEquivalent: "n"
        )
        notch.target = self
        menu.addItem(notch)
        notchMenuItem = notch
        let calibrateNotch = NSMenuItem(
            title: "Calibrate Physical Notch…",
            action: #selector(showNotchCalibration),
            keyEquivalent: ""
        )
        calibrateNotch.target = self
        menu.addItem(calibrateNotch)
        let text = NSMenuItem(
            title: "Open Local Text Agent…",
            action: #selector(showTextMode),
            keyEquivalent: "t"
        )
        text.target = self
        menu.addItem(text)
        let memory = NSMenuItem(
            title: "Memory Status…",
            action: #selector(showMemoryStatus),
            keyEquivalent: "m"
        )
        memory.target = self
        menu.addItem(memory)
        let benchmark = NSMenuItem(
            title: "Run Actian Model Benchmark…",
            action: #selector(runActianBenchmark),
            keyEquivalent: "b"
        )
        benchmark.target = self
        menu.addItem(benchmark)
#if M4_LOCAL_VOICE_SESSION
        let voiceTitle = "Local VoiceSession — start / stop"
#else
        let voiceTitle = "Voice mode (experimental, not started)"
#endif
        let voice = NSMenuItem(
            title: voiceTitle,
            action: #selector(showVoiceMode),
            keyEquivalent: "v"
        )
        voice.target = self
        menu.addItem(voice)
        let textDiagnostic = NSMenuItem(
            title: "Diagnose Focused Text Evidence",
            action: #selector(runFocusedTextDiagnostic),
            keyEquivalent: ""
        )
        textDiagnostic.target = self
        menu.addItem(textDiagnostic)
        let pointerDiagnostic = NSMenuItem(
            title: "Diagnose Pointer Evidence",
            action: #selector(runPointerDiagnostic),
            keyEquivalent: ""
        )
        pointerDiagnostic.target = self
        menu.addItem(pointerDiagnostic)
        let record = NSMenuItem(
            title: "Record Once…",
            action: #selector(recordOnce),
            keyEquivalent: "r"
        )
        record.target = self
        menu.addItem(record)
        let copilot = NSMenuItem(
            title: "Enable Screen Context…",
            action: #selector(toggleScreenContext),
            keyEquivalent: "c"
        )
        copilot.target = self
        menu.addItem(copilot)
        screenContextMenuItem = copilot
        menu.addItem(.separator())
        let restart = NSMenuItem(
            title: "Restart Copilot After Permission Change",
            action: #selector(restartCopilot),
            keyEquivalent: ""
        )
        restart.target = self
        menu.addItem(restart)
        let context = NSMenuItem(
            title: "Context: dedicated root only",
            action: nil,
            keyEquivalent: ""
        )
        context.isEnabled = false
        menu.addItem(context)
        let thread = NSMenuItem(
            title: "Task: \(threadID.prefix(8))…",
            action: nil,
            keyEquivalent: ""
        )
        thread.isEnabled = false
        menu.addItem(thread)
        let stop = NSMenuItem(
            title: "Emergency Stop Voice Runtime",
            action: #selector(emergencyStop),
            keyEquivalent: "s"
        )
        stop.target = self
        menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Control Shell",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        controlMenu = menu
        menu.delegate = self
        showMenuBarControl()
    }

    private func showMenuBarControl() {
        guard statusItem == nil, let controlMenu else { return }
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        // Keep one compact, always-available recovery control in the menu bar.
        // The notch surface is optional and display-dependent; removing the
        // status item while its own menu action is dispatching can make an
        // off-screen or failed notch presentation look like the app exited.
        item.button?.title = "⌄"
        item.button?.toolTip = "Work Mac Private Copilot"
        item.menu = controlMenu
        statusItem = item
    }

    private func showRecordingIndicator() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 58),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
        ]
        let label = NSTextField(labelWithString: "●  Work Mac recording — local only")
        label.textColor = .systemRed
        label.font = .boldSystemFont(ofSize: 13)
        label.alignment = .center
        label.frame = panel.contentView?.bounds ?? .zero
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)
        panel.center()
        panel.orderFrontRegardless()
        recordingPanel = panel
    }

    private func hideRecordingIndicator() {
        recordingPanel?.orderOut(nil)
        recordingPanel = nil
    }

    private func showClaudeCaptureIndicator(chatName: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 62),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.88)
        panel.hasShadow = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
        ]
        panel.ignoresMouseEvents = true
        let label = NSTextField(
            labelWithString: "●  Claude transcript capture — local only\n\(chatName)"
        )
        label.textColor = .systemRed
        label.font = .boldSystemFont(ofSize: 12)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.frame = panel.contentView?.bounds ?? .zero
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - panel.frame.width - 18,
                y: screen.visibleFrame.maxY - panel.frame.height - 18
            ))
        }
        panel.orderFrontRegardless()
        recordingPanel = panel
    }

    private func showScreenContextIndicator() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 58),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
        ]
        let label = NSTextField(
            labelWithString: "●  Screen context ON — OCR local only"
        )
        label.textColor = .systemGreen
        label.font = .boldSystemFont(ofSize: 13)
        label.alignment = .center
        label.frame = panel.contentView?.bounds ?? .zero
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)
        panel.center()
        panel.orderFrontRegardless()
        screenContextPanel = panel
    }

    private func hideScreenContextIndicator() {
        screenContextPanel?.orderOut(nil)
        screenContextPanel = nil
    }

    @objc private func toggleScreenContext() {
        if liveScreenContext.isRunning {
            Task {
                await liveScreenContext.stop()
                hideScreenContextIndicator()
                screenContextMenuItem?.title = "Enable Screen Context…"
                notchPanel.updateAttention(.ready)
                showNotice(
                    title: "Screen context stopped",
                    message: "The in-memory OCR context was cleared. No recording was saved."
                )
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Enable local screen context?"
        alert.informativeText = (
            "The main display will be sampled locally for on-device OCR. "
            + "Frames are not saved or transmitted. A visible indicator stays on until you stop it."
        )
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notchPanel.updateAttention(.working)
        Task {
            do {
                try await liveScreenContext.start()
                showScreenContextIndicator()
                screenContextMenuItem?.title = "Stop Screen Context"
                notchPanel.updateAttention(.ready)
            } catch {
                hideScreenContextIndicator()
                notchPanel.updateAttention(.blocked)
                showNotice(
                    title: "Screen context failed",
                    message: captureFailureMessage(error)
                )
            }
        }
    }

    private func runCommandLineRecording(_ request: RecordRequest) async {
        do {
            let recorder = StreamRecorder()
            activeRecorder = recorder
            let receipt = try await recorder.record(request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(receipt))
            FileHandle.standardOutput.write(Data([0x0a]))
            hideRecordingIndicator()
            NSApplication.shared.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("RECORD_ONCE_FAILED\n".utf8))
            hideRecordingIndicator()
            Foundation.exit(1)
        }
    }

    @objc private func showTextMode() {
        chatWindow.show()
    }

    @objc private func showNotchStation() {
        if notchPanel.isVisible {
            notchPanel.hide()
            showMenuBarControl()
            notchMenuItem?.title = "Show Notch Station"
        } else {
            let notchVisible = notchPanel.show()
            // The menu-bar control intentionally remains visible as a
            // deterministic fallback until the physical Work Mac rendering
            // has been accepted. It also remains the recovery path if the
            // panel is placed on an unexpected display.
            showMenuBarControl()
            notchMenuItem?.title = notchVisible
                ? "Hide Notch Station"
                : "Show Notch Station"
        }
    }

    @objc private func showNotchCalibration() {
        notchPanel.showCalibration()
        showMenuBarControl()
        notchMenuItem?.title = "Hide Notch Station"
    }

    private func refreshNotchStatus() {
#if M4_LOCAL_VOICE_SESSION
        notchPanel.updateLocalVoiceStatus(
            "Voice ready • press Voice to load Parakeet + LFM2.5-VL-3B + Kokoro",
            color: .systemGreen
        )
        return
#else
        do {
            let status = try memoryCommand("status", payload: [:])
            let eventWatermark = status["event_watermark"] as? NSNumber ?? 0
            let ftsWatermark = status["fts_watermark"] as? NSNumber ?? 0
            let vector = status["vector_status"] as? String ?? "unknown"
            notchPanel.updateMemory(
                eventWatermark: eventWatermark.intValue,
                ftsWatermark: ftsWatermark.intValue,
                vector: vector
            )
            let inferenceData = try inferenceCommandData(["status"])
            guard let inference = try JSONSerialization.jsonObject(
                    with: inferenceData
                  ) as? [String: Any],
                  let active = inference["active_status"] as? [String: Any],
                  active["reachable"] as? Bool == true,
                  active["model_available"] as? Bool == true
            else {
                notchPanel.updateAttention(.blocked)
                return
            }
            notchPanel.updateAttention(.ready)
        } catch {
            notchPanel.markMemoryUnavailable()
            notchPanel.updateAttention(.blocked)
        }
#endif
    }

    @objc private func showMemoryStatus() {
        do {
            let status = try memoryCommand("status", payload: [:])
            let events = status["events"] as? NSNumber ?? 0
            let turns = status["turns"] as? NSNumber ?? 0
            let watermark = status["event_watermark"] as? NSNumber ?? 0
            let vector = status["vector_status"] as? String ?? "unknown"
            let metrics = status["metrics"] as? [String: Any] ?? [:]
            let latest = status["latest_inference"] as? [String: Any] ?? [:]
            let promptTokens = metrics["prompt_eval_count"] as? NSNumber ?? 0
            let generatedTokens = metrics["eval_count"] as? NSNumber ?? 0
            showNotice(
                title: "Local Work Memory",
                message: (
                    "One conversation • events: \(events) • turns: \(turns)\n"
                    + "Ledger/FTS watermark: \(watermark)\n"
                    + "Prompt tokens: \(promptTokens) • generated tokens: \(generatedTokens)\n"
                    + "Latest inference: \(compactInferenceMetrics(latest))\n"
                    + "TurboVec: \(vector)\n"
                    + "Raw content remains on this Work Mac."
                )
            )
        } catch {
            showNotice(
                title: "Memory unavailable",
                message: "The local ledger/index failed closed. No raw content was exported."
            )
        }
    }

    @objc private func showVoiceMode() {
#if M4_LOCAL_VOICE_SESSION
        localVoiceSession.toggle()
        notchPanel.collapse()
#else
        showNotice(
            title: "V4 voice runtime is gated",
            message: (
                "Requested stack: Nemotron VoiceChat 11B Q4 + Supertonic. "
                + "The previous voice failure is preserved as evidence, and no "
                + "checksum-pinned Apple-Silicon Q4 runtime has been validated. "
                + "Voice remains off instead of silently falling back to the old container or cloud speech."
            )
        )
#endif
    }

#if M4_LOCAL_VOICE_SESSION
    @objc private func runFocusedTextDiagnostic() {
        localVoiceSession.runScreenDiagnostic()
    }

    @objc private func runPointerDiagnostic() {
        localVoiceSession.runScreenDiagnostic(pointer: true)
    }
#endif

    @objc private func showModelLibrary() {
        notchPanel.updateAttention(.working)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try inferenceCommandData(["status"])
                DispatchQueue.main.async {
                    guard let self else { return }
                    do {
                        let message = try inferenceStatusMessage(data)
                        self.notchPanel.updateAttention(.ready)
                        let alert = NSAlert()
                        alert.messageText = "Local inference runtimes"
                        alert.informativeText = message
                        alert.addButton(withTitle: "Configure…")
                        alert.addButton(withTitle: "Done")
                        if alert.runModal() == .alertFirstButtonReturn {
                            self.configureInferenceRuntime()
                        }
                    } catch {
                        self.showModelLibraryFailure()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showModelLibraryFailure()
                }
            }
        }
    }

    private func showModelLibraryFailure() {
        notchPanel.updateAttention(.blocked)
        showNotice(
            title: "Local runtimes unavailable",
            message: (
                "The fixed loopback runtime inventory could not be verified. "
                + "No model was invoked and no cloud fallback ran."
            )
        )
    }

    private func configureInferenceRuntime() {
        let provider = NSPopUpButton(frame: NSRect(x: 0, y: 42, width: 360, height: 28))
        provider.addItems(withTitles: ["ollama", "llama_cpp", "lm_studio"])
        let model = NSTextField(frame: NSRect(x: 0, y: 4, width: 360, height: 26))
        model.placeholderString = "Exact model ID reported by that provider"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 76))
        accessory.addSubview(provider)
        accessory.addSubview(model)
        let alert = NSAlert()
        alert.messageText = "Select a local runtime and model"
        alert.informativeText = (
            "This changes only the local active configuration. The server must "
            + "already be running and report the exact model."
        )
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Review Change")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let providerName = provider.titleOfSelectedItem ?? ""
        let modelName = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            showNotice(title: "Selection blocked", message: "Enter the exact local model ID.")
            return
        }
        let phrase = "SELECT LOCAL MODEL \(providerName) \(modelName)"
        let confirm = NSAlert()
        confirm.messageText = "Activate this local model?"
        confirm.informativeText = (
            "Provider: \(providerName)\nModel: \(modelName)\n\n"
            + "The model must appear in the provider inventory. No download or fallback will run."
        )
        confirm.addButton(withTitle: "Activate")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        notchPanel.updateAttention(.working)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try inferenceCommandData([
                    "select",
                    "--provider", providerName,
                    "--model", modelName,
                    "--confirm", phrase,
                ])
                DispatchQueue.main.async {
                    self?.notchPanel.updateAttention(.completed)
                    self?.showNotice(
                        title: "Local runtime selected",
                        message: "\(providerName) / \(modelName) will be used by the next local request."
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self?.notchPanel.updateAttention(.blocked)
                    self?.showNotice(
                        title: "Selection blocked",
                        message: "The provider was offline or did not report that exact model."
                    )
                }
            }
        }
    }

    @objc private func runActianBenchmark() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 26))
        field.placeholderString = (
            "ollama:model-one, ollama:model-two"
        )
        let alert = NSAlert()
        alert.messageText = "Compare local models over the Actian folder?"
        alert.informativeText = (
            "Enter 1–8 exact provider:model identities already reported by a "
            + "running local provider. The runner reads only ~/Desktop/actian, "
            + "does not follow symlinks, and stores raw text and summaries only "
            + "under WorkMacPrivateCopilot/benchmarks. Nothing is returned to "
            + "the M4 bridge or any cloud service."
        )
        alert.accessoryView = field
        alert.addButton(withTitle: "Review Run")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let specs = field.stringValue.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard 1...8 ~= specs.count else {
            showNotice(
                title: "Benchmark blocked",
                message: "Enter between one and eight exact local provider:model identities."
            )
            return
        }
        let confirmation = NSAlert()
        confirmation.messageText = "Run the local Actian comparison now?"
        confirmation.informativeText = (
            specs.joined(separator: "\n")
            + "\n\nThis can take substantial time. No model will be downloaded, "
            + "and no source text or summary leaves this Work Mac."
        )
        confirmation.addButton(withTitle: "Run Locally")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        notchPanel.updateAttention(.working)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try benchmarkCommandData(specs)
                let payload = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
                guard let runID = payload?["run_id"] as? String,
                      runID.hasPrefix("benchmark-"),
                      let sourceCount = payload?["source_count"] as? NSNumber,
                      let modelCount = payload?["model_count"] as? NSNumber
                else {
                    throw CopilotError.captureFailed
                }
                let report = workspaceRoot()
                    .appendingPathComponent("benchmarks/runs", isDirectory: true)
                    .appendingPathComponent(runID, isDirectory: true)
                DispatchQueue.main.async {
                    self?.notchPanel.updateAttention(.completed)
                    let completed = NSAlert()
                    completed.messageText = "Local benchmark completed"
                    completed.informativeText = (
                        "Models: \(modelCount) • sources inventoried: \(sourceCount)\n"
                        + "Raw data and summaries remain local."
                    )
                    completed.addButton(withTitle: "Show Local Report")
                    completed.addButton(withTitle: "Done")
                    if completed.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([report])
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.notchPanel.updateAttention(.blocked)
                    self?.showNotice(
                        title: "Benchmark failed closed",
                        message: (
                            "No cloud fallback or data export ran. Verify "
                            + "~/Desktop/actian exists and every exact local model "
                            + "is reported by its selected provider."
                        )
                    )
                }
            }
        }
    }

    @objc private func showExternalPreview() {
        showNotice(
            title: "External worker scaffold — non-sendable",
            message: (
                "Transport is disabled. This is a heuristic, non-sendable "
                + "packet scaffold, not a PII/privacy proof. Company, private, "
                + "unknown, ambiguous, raw work context, and anything not "
                + "explicitly reviewed remain blocked. Signed manager binding, "
                + "per-task user authorization, replay denial, and a live "
                + "Laguna adapter are not implemented. No bypass is available."
            )
        )
    }

    @objc private func recordOnce() {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            notchPanel.updateAttention(.needsInput)
            claudeCaptureStatusMenuItem?.title = (
                "Screen Recording permission requested — restart after granting"
            )
            return
        }
        let alert = NSAlert()
        alert.messageText = "Record the main display once?"
        alert.informativeText = "The movie stays under the private Work Mac copilot root. macOS may ask for Screen Recording permission."
        alert.addButton(withTitle: "Record 30 seconds")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        let request = RecordRequest(
            requestID: "menu-\(UUID().uuidString.lowercased())",
            outputDirectory: workspaceRoot().appendingPathComponent(
                "captures",
                isDirectory: true
            ),
            maxSeconds: 30,
            includeAudio: false
        )
        notchPanel.updateAttention(.recording)
        showRecordingIndicator()
        Task {
            do {
                let recorder = StreamRecorder()
                activeRecorder = recorder
                let receipt = try await recorder.record(request)
                hideRecordingIndicator()
                notchPanel.updateAttention(.completed)
                showNotice(
                    title: "Recording complete",
                    message: "Local-only movie saved. SHA-256: \(receipt.recording_sha256)"
                )
            } catch {
                hideRecordingIndicator()
                notchPanel.updateAttention(.blocked)
                showNotice(
                    title: "Recording failed",
                    message: captureFailureMessage(error)
                )
            }
        }
    }

    @objc private func captureOpenClaudeChat() {
        if let claudeCaptureArmingTask {
            claudeCaptureArmingTask.cancel()
            self.claudeCaptureArmingTask = nil
            claudeCaptureMenuItem?.title = "Capture Open Claude Chat…"
            claudeCaptureStatusMenuItem?.title = "Claude capture: ready"
            notchPanel.updateAttention(.ready)
            return
        }
        if let activeClaudeCapture {
            activeClaudeCapture.requestStop()
            claudeCaptureMenuItem?.title = "Stop Claude Transcript Capture"
            claudeCaptureStatusMenuItem?.title = "Claude capture: stopping…"
            notchPanel.updateAttention(.working)
            return
        }

        guard prepareClaudeCapturePermissions() else { return }

        let alert = NSAlert()
        alert.messageText = "Capture the currently open Claude chat?"
        alert.informativeText = (
            "Enter a local table/display name. After arming, you have eight "
            + "seconds to make Claude Desktop frontmost with the authorized "
            + "conversation open at its oldest visible message. The copilot "
            + "will move the cursor and scroll downward only. It will not "
            + "click, type, switch chats, invoke a model, save video/audio, "
            + "or transmit transcript data. Capture stops if the app, window, "
            + "or geometry changes."
        )
        let nameField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 420, height: 24)
        )
        nameField.placeholderString = "Example: Internship Claude Chat 01"
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Arm 8-hour local capture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chatName = nameField.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !chatName.isEmpty else {
            showNotice(
                title: "Capture not armed",
                message: "A local chat/table name is required."
            )
            return
        }

        claudeCaptureMenuItem?.title = "Cancel Armed Claude Capture"
        claudeCaptureStatusMenuItem?.title = (
            "Claude capture: armed — switch to Claude now"
        )
        notchPanel.updateAttention(.needsInput)
        let armingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                try Task.checkCancellation()
                self.claudeCaptureArmingTask = nil
                let configuration = try ClaudeTranscriptCaptureConfiguration(
                    chatName: chatName,
                    outputRoot: workspaceRoot().appendingPathComponent(
                        "transcripts",
                        isDirectory: true
                    )
                )
                let runner = ClaudeTranscriptCaptureRunner()
                activeClaudeCapture = runner
                claudeCaptureMenuItem?.title = "Stop Claude Transcript Capture"
                claudeCaptureStatusMenuItem?.title = (
                    "Claude capture: running locally"
                )
                showClaudeCaptureIndicator(chatName: chatName)
                notchPanel.updateAttention(.recording)
                let receipt = try await runner.run(configuration: configuration)
                activeClaudeCapture = nil
                hideRecordingIndicator()
                claudeCaptureMenuItem?.title = "Capture Open Claude Chat…"
                claudeCaptureStatusMenuItem?.title = (
                    "Claude capture: completed locally"
                )
                notchPanel.updateAttention(.completed)
                showNotice(
                    title: "Claude transcript capture complete",
                    message: (
                        "Local-only capture finished: \(receipt.message_records) "
                        + "message records, \(receipt.timestamped_message_records) "
                        + "with visible source times. Role coverage: "
                        + String(
                            format: "%.1f%%",
                            receipt.role_classification_ratio * 100
                        )
                        + ". Stop reason: \(receipt.stop_reason).\n\n"
                        + "Transcript: \(receipt.transcript_markdown)\n"
                        + "No transcript content was sent through the bridge."
                    )
                )
            } catch is CancellationError {
                self.claudeCaptureArmingTask = nil
                claudeCaptureMenuItem?.title = "Capture Open Claude Chat…"
                claudeCaptureStatusMenuItem?.title = "Claude capture: ready"
                notchPanel.updateAttention(.ready)
            } catch {
                self.claudeCaptureArmingTask = nil
                activeClaudeCapture = nil
                hideRecordingIndicator()
                claudeCaptureMenuItem?.title = "Capture Open Claude Chat…"
                claudeCaptureStatusMenuItem?.title = (
                    "Claude capture: stopped or blocked"
                )
                notchPanel.updateAttention(.blocked)
                showNotice(
                    title: "Claude transcript capture stopped",
                    message: (
                        "\(error)\n\nNo video/audio or network transcript "
                        + "transport ran. Keep Claude Desktop frontmost, leave "
                        + "the exact chat window fixed, and retry after verifying "
                        + "Screen Recording and Accessibility permissions."
                    )
                )
            }
        }
        claudeCaptureArmingTask = armingTask
    }

    private func prepareClaudeCapturePermissions() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            claudeCaptureMenuItem?.title = "Capture Open Claude Chat…"
            claudeCaptureStatusMenuItem?.title = (
                "Claude capture: allow Accessibility, then restart"
            )
            notchPanel.updateAttention(.needsInput)
            return false
        }
        guard CGPreflightScreenCaptureAccess() else {
            // CGRequestScreenCaptureAccess returns before the user has resolved
            // the system prompt on current macOS releases. Do not arm a run or
            // put an app-owned error alert over that prompt. The user grants it
            // once, then uses the fixed restart menu item.
            _ = CGRequestScreenCaptureAccess()
            claudeCaptureMenuItem?.title = "Capture Open Claude Chat…"
            claudeCaptureStatusMenuItem?.title = (
                "Claude capture: allow Screen Recording, then restart"
            )
            notchPanel.updateAttention(.needsInput)
            return false
        }
        claudeCaptureMenuItem?.title = "Capture Open Claude Chat…"
        claudeCaptureStatusMenuItem?.title = "Claude capture: ready"
        return true
    }

    @objc private func restartCopilot() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "kickstart",
            "-k",
            "gui/\(getuid())/com.devansh.work-mac-private-copilot-ui",
        ]
        do {
            try process.run()
        } catch {
            showNotice(
                title: "Restart failed closed",
                message: "Quit the copilot and reopen it from ~/Applications."
            )
        }
    }

    @objc private func emergencyStop() {
#if M4_LOCAL_VOICE_SESSION
        if localVoiceSession.cancel() {
            showNotice(
                title: "Local VoiceSession stopped",
                message: "Microphone, Parakeet, LFM, Kokoro, and playback were cancelled."
            )
            return
        }
#endif
        let root = workspaceRoot()
        let compose = root.appendingPathComponent("runtime/compose.yaml")
        let candidates = [
            "/usr/local/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/opt/homebrew/bin/docker",
        ]
        guard let docker = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }), FileManager.default.fileExists(atPath: compose.path) else {
            showNotice(
                title: "Voice runtime not found",
                message: "No fixed local container was stopped."
            )
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = [
            "compose",
            "--project-directory",
            root.appendingPathComponent("runtime").path,
            "-f",
            compose.path,
            "stop",
            "--timeout",
            "10",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            showNotice(
                title: "Emergency stop complete",
                message: process.terminationStatus == 0
                    ? "The fixed local voice runtime is stopped."
                    : "The stop command failed closed."
            )
        } catch {
            showNotice(
                title: "Emergency stop failed closed",
                message: "No alternate command was attempted."
            )
        }
    }

    private func showNotice(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@main
private struct WorkMacPrivateCopilotMain {
    static func main() {
        // A helper that fails closed before reading stdin must not terminate
        // the native UI with SIGPIPE. The caller still observes the helper's
        // nonzero exit status and reports a bounded local failure.
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let autoStartVoice = arguments == ["voice-start"]
        let request: RecordRequest?
        if arguments.isEmpty || autoStartVoice {
            request = nil
        } else {
            do {
                request = try parseRecordRequest(arguments)
            } catch {
                FileHandle.standardError.write(Data("INVALID_RECORD_REQUEST\n".utf8))
                Foundation.exit(2)
            }
        }
        let application = NSApplication.shared
        application.setActivationPolicy(request == nil ? .accessory : .regular)
        let delegate = ApplicationDelegate(
            recordRequest: request,
            autoStartVoice: autoStartVoice
        )
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

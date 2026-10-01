import Foundation

struct WorkMacInferenceReply {
    let content: String
    let metrics: [String: Any]
}

enum WorkMacInferenceError: Error {
    case invalidEnvironment
    case invalidPayload
    case outputTooLarge
    case runtimeFailed(String)
    case missingCompletion
}

final class WorkMacInferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

func safeInferenceErrorCode(_ error: Error) -> String {
    if case let WorkMacInferenceError.runtimeFailed(code) = error,
       code.range(of: "^[a-z0-9_]{3,80}$", options: .regularExpression) != nil {
        return code
    }
    if error is CancellationError {
        return "request_cancelled"
    }
    switch error {
    case WorkMacInferenceError.invalidEnvironment:
        return "invalid_environment"
    case WorkMacInferenceError.invalidPayload:
        return "invalid_runtime_payload"
    case WorkMacInferenceError.outputTooLarge:
        return "runtime_output_too_large"
    case WorkMacInferenceError.missingCompletion:
        return "runtime_missing_completion"
    default:
        return "local_inference_failed"
    }
}

private func inferenceEnvironment() -> [String: String] {
    [
        "HOME": NSHomeDirectory(),
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "PYTHONNOUSERSITE": "1",
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
        "TMPDIR": NSTemporaryDirectory(),
    ]
}

private func parseInferenceLine(
    _ data: Data,
    content: inout String,
    metrics: inout [String: Any]?,
    errorCode: inout String?,
    onDelta: @escaping @Sendable (String) -> Void
) throws {
    guard !data.isEmpty,
          let value = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          let type = value["type"] as? String
    else {
        throw WorkMacInferenceError.invalidPayload
    }
    switch type {
    case "started":
        return
    case "delta":
        guard let delta = value["text"] as? String,
              delta.count <= 16_384 else {
            throw WorkMacInferenceError.invalidPayload
        }
        content += delta
        onDelta(delta)
    case "complete":
        guard let final = value["content"] as? String,
              final.count <= 100_000,
              let finalMetrics = value["metrics"] as? [String: Any]
        else {
            throw WorkMacInferenceError.invalidPayload
        }
        if content.isEmpty {
            content = final
            onDelta(final)
        } else if final != content.trimmingCharacters(in: .whitespacesAndNewlines) {
            // The streamed text is authoritative. A mismatch is a runtime error,
            // not permission to silently replace visible content.
            throw WorkMacInferenceError.invalidPayload
        }
        metrics = finalMetrics
    case "error":
        errorCode = (value["error_code"] as? String) ?? "inference_runtime_failed"
    default:
        throw WorkMacInferenceError.invalidPayload
    }
}

private func runInferenceBlocking(
    root: URL,
    requestID: String,
    messages: [[String: String]],
    cancellation: WorkMacInferenceCancellation,
    onDelta: @escaping @Sendable (String) -> Void
) throws -> WorkMacInferenceReply {
    let environment = ProcessInfo.processInfo.environment
    guard let python = environment["WORK_MAC_INFERENCE_PYTHON"],
          python.hasPrefix("/"),
          let runtime = environment["WORK_MAC_INFERENCE_CLI"],
          runtime.hasPrefix("/")
    else {
        throw WorkMacInferenceError.invalidEnvironment
    }
    let payload: [String: Any] = [
        "request_id": requestID,
        "messages": messages,
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    guard body.count <= 512 * 1_024 else {
        throw WorkMacInferenceError.invalidPayload
    }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [
        runtime,
        "--root",
        root.path,
        "chat",
    ]
    process.environment = inferenceEnvironment()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    cancellation.attach(process)
    defer { cancellation.detach() }
    input.fileHandleForWriting.write(body)
    try input.fileHandleForWriting.close()

    var buffer = Data()
    var totalBytes = 0
    var content = ""
    var metrics: [String: Any]?
    var errorCode: String?
    while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty {
            break
        }
        totalBytes += chunk.count
        if totalBytes > 3 * 1_024 * 1_024 {
            process.terminate()
            process.waitUntilExit()
            throw WorkMacInferenceError.outputTooLarge
        }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            try parseInferenceLine(
                line,
                content: &content,
                metrics: &metrics,
                errorCode: &errorCode,
                onDelta: onDelta
            )
        }
    }
    if !buffer.isEmpty {
        try parseInferenceLine(
            buffer,
            content: &content,
            metrics: &metrics,
            errorCode: &errorCode,
            onDelta: onDelta
        )
    }
    process.waitUntilExit()
    if cancellation.isCancelled {
        throw CancellationError()
    }
    if let errorCode {
        throw WorkMacInferenceError.runtimeFailed(errorCode)
    }
    guard process.terminationStatus == 0,
          !content.isEmpty,
          let metrics else {
        throw WorkMacInferenceError.missingCompletion
    }
    return WorkMacInferenceReply(content: content, metrics: metrics)
}

func runWorkMacInference(
    root: URL,
    requestID: String,
    messages: [[String: String]],
    cancellation: WorkMacInferenceCancellation,
    onDelta: @escaping @Sendable (String) -> Void
) async throws -> WorkMacInferenceReply {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(
                    returning: try runInferenceBlocking(
                        root: root,
                        requestID: requestID,
                        messages: messages,
                        cancellation: cancellation,
                        onDelta: onDelta
                    )
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

func compactInferenceMetrics(_ metrics: [String: Any]) -> String {
    func milliseconds(_ key: String) -> String? {
        guard let value = metrics[key] as? NSNumber else { return nil }
        return String(format: "%.1fs", value.doubleValue / 1_000.0)
    }
    func rate(_ key: String) -> String? {
        guard let value = metrics[key] as? NSNumber else { return nil }
        return String(format: "%.1f tok/s", value.doubleValue)
    }
    var parts: [String] = []
    if let value = milliseconds("wall_latency_ms") {
        parts.append("total \(value)")
    }
    if let value = milliseconds("ttft_ms") {
        parts.append("TTFT \(value)")
    }
    if let value = metrics["load_duration"] as? NSNumber {
        parts.append(String(format: "load %.1fs", value.doubleValue / 1_000_000_000.0))
    }
    if let promptTokens = metrics["prompt_eval_count"] as? NSNumber {
        parts.append("prompt \(promptTokens.intValue) tok")
    }
    if let value = rate("prompt_tokens_per_second") {
        parts.append("prefill \(value)")
    }
    if let value = rate("generation_tokens_per_second") {
        parts.append(value)
    }
    if let provider = metrics["provider"] as? String,
       let model = metrics["model"] as? String {
        parts.append("\(provider)/\(model)")
    }
    return parts.joined(separator: " • ")
}

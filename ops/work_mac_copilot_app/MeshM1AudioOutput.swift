import Combine
import Foundation

enum MeshM1AudioError: LocalizedError {
    case unavailable, invalidAudio, cancelled, timedOut, routeUnverified
    case receiverRejected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "M1 audio unavailable. Check mesh-m1 SSH and the installed speaker selector."
        case .invalidAudio: "The generated speech is missing or exceeds the bounded WAV limit."
        case .cancelled: "M1 speech stopped"
        case .timedOut: "M1 speaker playback timed out and was stopped"
        case .routeUnverified: "M1 speaker route/volume could not be verified; speech was not accepted as played"
        case let .receiverRejected(code):
            "M1 refused speech: \(MeshM1ReceiverReason(rawValue: code)?.explanation ?? "unrecognized receiver failure"). [\(MeshM1ReceiverReason(rawValue: code)?.rawValue ?? "unknown")]"
        }
    }
}

/// Only these fixed protocol codes can enter the UI. Raw stderr and exception text are discarded.
enum MeshM1ReceiverReason: String {
    case cancelled, invalid_audio_size, unsupported_audio_format, invalid_audio_duration, invalid_audio_header
    case truncated_audio, audio_transfer_timeout, audio_transfer_closed, playback_timeout, playback_failed
    case output_route_changed, selected_output_not_verified, speaker_volume_not_verified
    case speaker_selector_unavailable, speaker_selector_failed, speaker_selector_output_mismatch
    case coreaudio_route_unavailable, coreaudio_name_unavailable, volume_unavailable, speaker_volume_change_failed
    case m1_audio_unavailable, invalid_arguments, invalid_request_id

    var explanation: String {
        switch self {
        case .cancelled: "the playback request was cancelled"
        case .invalid_audio_size: "the WAV length is outside the allowed limit"
        case .unsupported_audio_format: "the WAV is not supported mono/stereo PCM16"
        case .invalid_audio_duration: "the WAV duration is outside the allowed limit"
        case .invalid_audio_header: "the WAV header could not be decoded"
        case .truncated_audio: "the WAV contains fewer samples than its header declares"
        case .audio_transfer_timeout: "the WAV transfer did not finish within 12 seconds"
        case .audio_transfer_closed: "the SSH input closed before the complete WAV arrived"
        case .playback_timeout: "the owned player exceeded its time limit"
        case .playback_failed: "the owned player failed"
        case .output_route_changed: "the output changed away from the selected M1 speakers"
        case .selected_output_not_verified: "CoreAudio did not confirm the selected M1 speakers"
        case .speaker_volume_not_verified: "volume 100 and unmuted state were not confirmed"
        case .speaker_selector_unavailable: "the installed M1 speaker selector is missing"
        case .speaker_selector_failed: "the installed M1 speaker selector failed"
        case .speaker_selector_output_mismatch: "the selector returned an unexpected device receipt"
        case .coreaudio_route_unavailable, .coreaudio_name_unavailable: "the actual CoreAudio route could not be read"
        case .volume_unavailable: "the current output volume could not be read"
        case .speaker_volume_change_failed: "the requested speaker volume could not be set"
        case .invalid_arguments, .invalid_request_id: "the receiver request was malformed"
        case .m1_audio_unavailable: "the receiver encountered an unclassified local failure"
        }
    }
}

/// No listener, API token, model, or sensor. Explicit play alone opens a verified SSH connection.
@MainActor
final class MeshM1AudioOutput: ObservableObject {
    @Published private(set) var status = "M1 speakers idle"
    @Published private(set) var isPlaying = false
    private var job: MeshM1AudioJob?
    private var generation = UUID()

    func play(url: URL) async throws {
        stop()
        guard let sourceURL = Bundle.main.url(forResource: "mesh_monitor_m1_audio_receiver", withExtension: "py"),
              let source = try? Data(contentsOf: sourceURL), source.count <= 32_768 else {
            throw MeshM1AudioError.unavailable
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard url.isFileURL, let size = attrs?[.size] as? NSNumber, size.intValue > 0,
              size.intValue <= 12 * 1_024 * 1_024, let data = try? Data(contentsOf: url),
              data.count == size.intValue else { throw MeshM1AudioError.invalidAudio }
        let token = generation
        isPlaying = true
        status = "Connecting to M1 speakers…"
        let job = MeshM1AudioJob(source: source, audio: data)
        self.job = job
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    job.start(onReady: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.status = "Speaking on verified M1 MacBook Pro Speakers · volume 100"
                        }
                    }, onComplete: { result in continuation.resume(with: result) })
                }
            } onCancel: { job.stop() }
            guard generation == token else { throw MeshM1AudioError.cancelled }
            self.job = nil
            isPlaying = false
            status = "M1 playback completed"
        } catch {
            if generation == token {
                self.job = nil
                isPlaying = false
                status = error.localizedDescription
            }
            throw error
        }
    }

    func stop() {
        generation = UUID()
        job?.stop()
        job = nil
        isPlaying = false
        status = "M1 speakers idle"
    }
}

private final class MeshM1AudioJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mesh.monitor.m1-audio", qos: .userInitiated)
    private let requestID = UUID().uuidString.lowercased()
    private let source: Data
    private let audio: Data
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var response = Data()
    private var proofReady = false
    private var proofComplete = false
    private var finished = false
    private var stopped = false
    private var completion: (@Sendable (Result<Void, Error>) -> Void)?
    private var ready: (@Sendable () -> Void)?

    init(source: Data, audio: Data) { self.source = source; self.audio = audio }

    func start(onReady: @escaping @Sendable () -> Void,
               onComplete: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard !stopped else { onComplete(.failure(MeshM1AudioError.cancelled)); return }
            completion = onComplete
            ready = onReady
            let stdin = Pipe(), stdout = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // Only fixed Python source, a generated UUID and a bounded integer enter the remote shell.
            let code = "import base64;exec(base64.b64decode('\(source.base64EncodedString())'))"
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let command = "/usr/bin/python3 -c " + quote(code) + " play " + quote(requestID) + " " + String(audio.count)
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                                 "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2",
                                 "-o", "StrictHostKeyChecking=yes", "mesh-m1", command]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            self.process = process
            do {
                try process.run()
                // One reader owns the pipe. EOF is enqueued after all receipt chunks, preventing
                // a Process termination callback from racing and losing the final receipt.
                let reader = stdout.fileHandleForReading
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    while let bytes = try? reader.read(upToCount: 4_096), !bytes.isEmpty {
                        queue.async { [self] in consume(bytes) }
                    }
                    process.waitUntilExit()
                    try? reader.close()
                    queue.async { [self] in
                        guard !finished else { return }
                        finish(process.terminationStatus == 0 && proofReady && proofComplete
                               ? .success(()) : .failure(MeshM1AudioError.routeUnverified))
                    }
                }
                // Write off the coordination queue so Stop remains responsive during SSH setup.
                let writer = stdin.fileHandleForWriting
                let bytes = audio
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do { try writer.write(contentsOf: bytes) }
                    catch { self?.queue.async { [weak self] in self?.cancel(.unavailable) } }
                    // Keep stdin open: its EOF/any subsequent byte is the remote cancellation signal.
                }
                queue.asyncAfter(deadline: .now() + 150) { [weak self] in
                    guard let self, !self.finished else { return }
                    self.cancel(.timedOut)
                }
            } catch { finish(.failure(MeshM1AudioError.unavailable)) }
        }
    }

    func stop() { queue.async { [self] in stopped = true; cancel(.cancelled) } }

    private func consume(_ bytes: Data) {
        guard !finished else { return }
        guard response.count + bytes.count <= 8_192 else { cancel(.routeUnverified); return }
        response.append(bytes)
        while let end = response.firstIndex(of: 10) {
            let line = response.prefix(upTo: end)
            response.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  value["request_id"] as? String == requestID else { continue }
            let phase = value["phase"] as? String
            if phase == "ready", value["device"] as? String == "MacBook Pro Speakers",
               value["volume"] as? Int == 100, value["muted"] as? Bool == false {
                proofReady = true
                ready?()
            } else if phase == "complete", proofReady,
                      value["device"] as? String == "MacBook Pro Speakers", value["volume"] as? Int == 100 {
                proofComplete = true
            } else if phase == "error" {
                let reason = MeshM1ReceiverReason(rawValue: value["error"] as? String ?? "") ?? .m1_audio_unavailable
                cancel(.receiverRejected(reason.rawValue))
            }
        }
    }

    private func cancel(_ error: MeshM1AudioError) {
        guard !finished else { return }
        // Closing stdin is sufficient: remote EOF cancels only the child this invocation owns.
        try? input?.close()
        let child = process
        queue.asyncAfter(deadline: .now() + 2) { if child?.isRunning == true { child?.terminate() } }
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        try? input?.close()
        // Read handle lives until SSH termination; callbacks ignore the completed generation.
        input = nil
        let callback = completion
        completion = nil
        ready = nil
        callback?(result)
    }
}

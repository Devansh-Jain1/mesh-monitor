import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import Foundation

#if M4_LOCAL_VOICE_SESSION

private enum M4LocalVoicePhase: String {
    case idle
    case starting
    case listening
    case finalizing
    case thinking
    case synthesizing
    case speaking
    case unavailable
}

private enum M4LocalVoiceError: Error, LocalizedError {
    case kokoroRuntimeUnavailable
    case kokoroWorkerFailed(String)
    case emptyTranscript
    case playbackFailed
    case startupProbeFailed

    var errorDescription: String? {
        switch self {
        case .kokoroRuntimeUnavailable: "The isolated local Kokoro runtime is unavailable."
        case let .kokoroWorkerFailed(reason): "Kokoro failed: \(reason)"
        case .emptyTranscript: "No final speech was recognized."
        case .playbackFailed: "Kokoro audio playback failed."
        case .startupProbeFailed: "The screen-aware startup probe did not return visual evidence."
        }
    }
}

struct M4LocalVoiceReply {
    let text: String
    let brainID: String
    let screenContextUsed: Bool
    let inferenceMS: Int
    let screenEvidence: [String]
}

protocol M4LocalVoiceBrainPort {
    func respond(to transcript: String) async throws -> M4LocalVoiceReply
}

struct M4KokoroResult: Decodable {
    let id: String
    let ok: Bool
    let output: String?
    let generationMS: Int?
    let audioMS: Int?
    let engine: String?
    let voice: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, ok, output, engine, voice, error
        case generationMS = "generation_ms"
        case audioMS = "audio_ms"
    }
}

@MainActor
final class M4ResidentKokoroWorker {
    private let worker: M4ResidentJSONWorker
    private var failedOutputs = Set<URL>()
    var isReady: Bool { worker.isReady }
    var hasOwnedProcess: Bool { worker.hasOwnedProcess }

    init(limits: M4ResidentJSONWorker.Limits = .init(),
         launch: (() throws -> M4ResidentJSONWorker.Launch)? = nil) {
        worker = M4ResidentJSONWorker(limits: limits, launch: launch ?? Self.defaultLaunch)
        worker.onExit = { [weak self] in
            guard let self else { return }
            for url in self.failedOutputs { try? FileManager.default.removeItem(at: url) }
            self.failedOutputs.removeAll()
        }
    }
    func start(completion: @escaping (Result<Void, Error>) -> Void) { worker.start(completion) }
    func prepare() async throws { try await worker.prepare() }
    func synthesize(text: String, completion: @escaping (Result<M4KokoroResult, Error>) -> Void) {
        let requestID = UUID().uuidString
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("m4-local-kokoro-\(requestID).wav")
        worker.request(id: requestID, payload: ["text": String(text.prefix(600)), "output": outputURL.path, "speed": 1.05]) { [weak self] result in
            do {
                let value = try JSONDecoder().decode(M4KokoroResult.self, from: result.get())
                guard value.ok else { throw M4LocalVoiceError.kokoroWorkerFailed(value.error ?? "unknown") }
                completion(.success(value))
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                // A stopping child may finish its file after the timeout callback.
                // Remove that output again when this exact owned child has exited.
                if self?.worker.hasOwnedProcess == true { self?.failedOutputs.insert(outputURL) }
                completion(.failure(error))
            }
        }
    }
    func stop() { worker.stop() }

    private static func defaultLaunch() throws -> M4ResidentJSONWorker.Launch {
        guard let resources = Bundle.main.resourceURL,
              let python = pythonExecutable(),
              let script = resource("kokoro_onnx_worker.py", in: resources),
              let model = resource("kokoro.onnx", in: resources),
              let config = resource("kokoro-config.json", in: resources),
              let voice = resource("af_bella.bin", in: resources)
        else { throw M4LocalVoiceError.kokoroRuntimeUnavailable }
        return .init(executable: python,
            arguments: [script.path, "--model", model.path, "--config", config.path, "--voice", voice.path],
            environment: ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                          "PYTHONDONTWRITEBYTECODE": "1", "NO_PROXY": "*"])
    }
    private static func pythonExecutable() -> URL? {
        let candidates = [ProcessInfo.processInfo.environment["M4_LOCAL_VOICE_PYTHON"],
            NSHomeDirectory() + "/Library/Application Support/M4LocalVoiceSession/venv/bin/python",
            "/private/tmp/m4-local-voice-venv/bin/python"].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    private static func resource(_ name: String, in root: URL) -> URL? {
        let url = root.appendingPathComponent(name)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }
}

/// Surface either startup failure immediately and cancel the other owned worker.
/// Both preparations settle their checked continuations on task cancellation.
@MainActor func prepareM4VoiceWorkers(speech: M4OnDeviceSpeechInput, kokoro: M4ResidentKokoroWorker) async throws {
    try Task.checkCancellation()
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await speech.prepare() }
        group.addTask { try await kokoro.prepare() }
        while try await group.next() != nil {}
    }
    try Task.checkCancellation()
}

final class M4LocalAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var completion: (@MainActor (Bool) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.completion?(flag) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.completion?(false) }
    }
}

@MainActor
final class M4LocalVoiceSession: NSObject {
    var onStatus: ((String, NSColor) -> Void)?
    var onReadiness: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let moduleID = "com.devansh.voice-session"
    private let moduleVersion = "0.3.0"
    private let brain = M4ResidentLFMVisionBrain()
    private let speechInput = M4OnDeviceSpeechInput()
    private let kokoro = M4ResidentKokoroWorker()
    private var phase: M4LocalVoicePhase = .idle
    private var player: AVAudioPlayer?
    private var playerDelegate: M4LocalAudioPlayerDelegate?
    private var playingURL: URL?
    private var turnID: UUID?
    private var turnStartedAt: Date?
    private var transcriptFinalAt: Date?
    private var lastAudioLevelReceipt = Date.distantPast

    var isActive: Bool { phase != .idle && phase != .unavailable }

    override init() {
        super.init()
        speechInput.onPartial = { [weak self] text in self?.heardPartial(text) }
        speechInput.onFinal = { [weak self] text in self?.heardFinal(text) }
        speechInput.onFailure = { [weak self] error in self?.handleSpeechFailure(error) }
        speechInput.onNoSpeech = { [weak self] in self?.handleNoSpeech() }
        speechInput.onCaptureReady = { [weak self] in
            self?.record("audio_input_ready", fields: [
                "engine": "fluidaudio_parakeet_tdt_0.6b_v3_int8",
            ])
        }
        speechInput.onSpeechStarted = { [weak self] in
            guard let self, self.phase == .listening else { return }
            self.record("speech_detected", fields: [
                "engine": "energy_endpoint_v1",
            ])
            self.status("Speech detected • listening for the end", .systemRed)
        }
        speechInput.onLevel = { [weak self] rms, peak in
            guard let self, self.phase == .listening else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastAudioLevelReceipt) >= 2 else { return }
            self.lastAudioLevelReceipt = now
            self.record("audio_level", fields: [
                "rms": Double(rms),
                "peak": Double(peak),
            ])
        }
        speechInput.onTranscriptionMetrics = { [weak self] confidence, inferenceMS, audioMS in
            self?.record("asr_completed", fields: [
                "engine": "fluidaudio_parakeet_tdt_0.6b_v3_int8",
                "confidence": Double(confidence),
                "inference_ms": inferenceMS,
                "audio_ms": audioMS,
            ])
        }
    }

    func toggle() {
        if phase == .speaking {
            interruptPlaybackAndResume()
        } else if isActive {
            _ = cancel()
        } else {
            start()
        }
    }

    func start() {
        guard phase == .idle || phase == .unavailable else { return }
        phase = .starting
        status("Loading resident Kokoro + LFM2.5-VL-3B…", .systemOrange)
        record("session_starting")
        kokoro.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.record("kokoro_resident_ready")
                self.readiness("✓ Kokoro • loading Parakeet + LFM")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        self.status("Loading resident Parakeet + LFM2.5-VL-3B…", .systemOrange)
                        async let speechReady: Void = self.speechInput.prepare()
                        async let brainReady: Void = self.brain.start()
                        try await speechReady
                        self.record("asr_resident_ready", fields: [
                            "engine": "fluidaudio_parakeet_tdt_0.6b_v3_int8",
                        ])
                        self.readiness("✓ Kokoro • ✓ Parakeet • loading LFM")
                        try await brainReady
                        self.record("brain_resident_ready", fields: [
                            "brain_id": "lfm2.5_vl_3b_q4_k_m",
                        ])
                        self.readiness("✓ Kokoro • ✓ Parakeet • ✓ LFM • checking screen")
                        self.runStartupGate()
                    } catch {
                        self.fail(error)
                    }
                }
            case let .failure(error):
                self.fail(error)
            }
        }
    }

    private func runStartupGate() {
        phase = .starting
        status("Checking screen evidence • resident LFM ready…", .systemBlue)
        record("startup_probe_started", fields: [
            "coordinator": "local_in_process",
            "peer_state": "nano_simulated_not_connected",
        ])
        do {
            let reply = try brain.readinessProbe()
            guard reply.screenContextUsed else {
                throw M4LocalVoiceError.startupProbeFailed
            }
            record("startup_probe_completed", fields: [
                "brain_id": reply.brainID,
                "screen_context_used": true,
                "screen_evidence": reply.screenEvidence,
                "inference_ms": reply.inferenceMS,
                "coordinator": "local_in_process",
                "peer_state": "nano_simulated_not_connected",
            ])
            readiness(
                "✓ Parakeet • ✓ Screen evidence • ✓ resident LFM • ✓ Kokoro • local orchestration"
            )
            record("startup_gate_ready", fields: [
                "coordinator": "local_in_process",
                "peer_state": "nano_simulated_not_connected",
            ])
            status("Ready • microphone active", .systemRed)
            beginListening(requestAuthorization: true)
            record("listening_resumed", fields: [
                "reason": "startup_gate_ready",
            ])
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            record("startup_probe_degraded", fields: [
                "reason": String(reason.prefix(160)),
                "screen_context_available": false,
                "coordinator": "local_in_process",
                "peer_state": "nano_simulated_not_connected",
            ])
            readiness(
                "✓ Parakeet • ⚠ Screen unavailable • ✓ resident LFM • ✓ Kokoro • voice ready"
            )
            record("startup_gate_ready", fields: [
                "screen_context_available": false,
                "coordinator": "local_in_process",
                "peer_state": "nano_simulated_not_connected",
            ])
            status("Ready without screen • microphone active", .systemRed)
            beginListening(requestAuthorization: true)
            record("listening_resumed", fields: [
                "reason": "startup_gate_degraded_screen",
            ])
        }
    }

    func runScreenDiagnostic(pointer: Bool = false) {
        guard phase == .listening else {
            record("diagnostic_skipped", fields: [
                "reason": "voice_session_not_listening",
            ])
            return
        }
        speechInput.stop()
        phase = .thinking
        turnID = UUID()
        turnStartedAt = Date()
        let request = pointer
            ? "Where is the mouse cursor right now? Use the current screen evidence."
            : "Read exactly what is currently typed in the visible text box."
        status(pointer ? "Checking pointer evidence…" : "Reading focused text…", .systemBlue)
        record("diagnostic_started", fields: [
            "diagnostic": pointer ? "pointer" : "focused_text",
        ])
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.brain.respond(to: request)
                self.recordConversation(
                    role: "diagnostic",
                    text: reply.text,
                    fields: [
                        "brain_id": reply.brainID,
                        "screen_context_used": reply.screenContextUsed,
                        "screen_evidence": reply.screenEvidence,
                        "inference_ms": reply.inferenceMS,
                    ]
                )
                self.record("diagnostic_completed", fields: [
                    "diagnostic": pointer ? "pointer" : "focused_text",
                    "brain_id": reply.brainID,
                    "screen_context_used": reply.screenContextUsed,
                    "screen_evidence": reply.screenEvidence,
                    "inference_ms": reply.inferenceMS,
                    "result_sha256": self.sha256(reply.text),
                ])
                self.status("Diagnostic passed • still listening", .systemGreen)
                self.beginListening()
                self.record("listening_resumed", fields: [
                    "reason": "diagnostic_completed",
                ])
            } catch {
                self.fail(error)
            }
        }
    }

    @discardableResult
    func cancel() -> Bool {
        guard phase != .idle else { return false }
        speechInput.shutdown()
        player?.stop()
        player = nil
        playerDelegate = nil
        removePlayingAudio()
        kokoro.stop()
        brain.stop()
        phase = .idle
        turnID = nil
        record("session_cancelled")
        status("Voice stopped • press Voice to restart", .systemOrange)
        return true
    }

    private func beginListening(requestAuthorization: Bool = false) {
        phase = .listening
        turnID = UUID()
        turnStartedAt = Date()
        transcriptFinalAt = nil
        status("Microphone active • listening locally", .systemRed)
        record("capture_started")
        if requestAuthorization {
            speechInput.requestAuthorizationAndStart()
        } else {
            speechInput.start()
        }
    }

    private func heardPartial(_ text: String) {
        guard phase == .listening else { return }
        let bounded = String(text.prefix(72))
        status("Hearing: \(bounded)", .systemRed)
    }

    private func heardFinal(_ transcript: String) {
        guard phase == .listening else { return }
        phase = .thinking
        transcriptFinalAt = Date()
        record("transcript_final", fields: [
            "characters": transcript.count,
            "transcript_sha256": sha256(transcript),
        ])
        recordConversation(role: "user", text: transcript)
        status("Thinking locally…", .systemBlue)
        record("brain_requested", fields: [
            "request_characters": transcript.count,
            "request_sha256": sha256(transcript),
        ])
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.brain.respond(to: transcript)
                self.record("brain_completed", fields: [
                    "brain_id": reply.brainID,
                    "screen_context_used": reply.screenContextUsed,
                    "screen_evidence": reply.screenEvidence,
                    "inference_ms": reply.inferenceMS,
                    "response_characters": reply.text.count,
                    "response_sha256": self.sha256(reply.text),
                ])
                self.recordConversation(
                    role: "assistant",
                    text: reply.text,
                    fields: [
                        "brain_id": reply.brainID,
                        "screen_context_used": reply.screenContextUsed,
                        "screen_evidence": reply.screenEvidence,
                        "inference_ms": reply.inferenceMS,
                    ]
                )
                self.synthesize(reply)
            } catch {
                self.fail(error)
            }
        }
    }

    private func synthesize(_ reply: M4LocalVoiceReply, startup: Bool = false) {
        phase = .synthesizing
        status("Kokoro is generating…", .systemPurple)
        record("tts_requested", fields: ["engine": "kokoro_onnx", "voice": "af_bella"])
        kokoro.synthesize(text: spokenText(reply.text)) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(value):
                guard let output = value.output else {
                    self.fail(M4LocalVoiceError.kokoroWorkerFailed("missing_output"))
                    return
                }
                self.record("tts_generated", fields: [
                    "engine": value.engine ?? "kokoro_onnx",
                    "voice": value.voice ?? "af_bella",
                    "generation_ms": value.generationMS ?? -1,
                    "audio_ms": value.audioMS ?? -1,
                ])
                self.play(URL(fileURLWithPath: output), startup: startup)
            case let .failure(error): self.fail(error)
            }
        }
    }

    private func spokenText(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = normalized.firstIndex(where: { ".!?".contains($0) }) {
            let sentence = String(normalized[...end])
            if sentence.count <= 180 { return sentence }
        }
        return String(normalized.prefix(180))
    }

    private func play(_ url: URL, startup: Bool) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = M4LocalAudioPlayerDelegate()
            delegate.completion = { [weak self] succeeded in
                try? FileManager.default.removeItem(at: url)
                guard let self else { return }
                if succeeded {
                    self.record("playback_completed")
                    self.player = nil
                    self.playerDelegate = nil
                    self.playingURL = nil
                    if startup {
                        self.record("startup_gate_ready", fields: [
                            "coordinator": "local_in_process",
                            "peer_state": "nano_simulated_not_connected",
                        ])
                        self.beginListening(requestAuthorization: true)
                    } else {
                        self.beginListening()
                    }
                    self.record("listening_resumed")
                } else {
                    self.fail(M4LocalVoiceError.playbackFailed)
                }
            }
            self.player = player
            playerDelegate = delegate
            playingURL = url
            player.delegate = delegate
            player.prepareToPlay()
            guard player.play() else { throw M4LocalVoiceError.playbackFailed }
            phase = .speaking
            var firstAudioFields: [String: Any] = [:]
            if let transcriptFinalAt {
                firstAudioFields["turn_to_first_audio_ms"] = Int(
                    Date().timeIntervalSince(transcriptFinalAt) * 1_000
                )
                firstAudioFields["transcript_to_first_audio_ms"] = Int(
                    Date().timeIntervalSince(transcriptFinalAt) * 1_000
                )
            }
            if let turnStartedAt {
                firstAudioFields["capture_to_first_audio_ms"] = Int(
                    Date().timeIntervalSince(turnStartedAt) * 1_000
                )
            }
            record("first_audio", fields: firstAudioFields)
            status("Kokoro speaking • press Voice to interrupt", .systemPurple)
        } catch {
            try? FileManager.default.removeItem(at: url)
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        speechInput.stop()
        player?.stop()
        player = nil
        playerDelegate = nil
        removePlayingAudio()
        brain.stop()
        phase = .unavailable
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        record("session_failed", fields: ["reason": String(reason.prefix(160))])
        status("Voice blocked • \(reason)", .systemRed)
        onFailure?(reason)
    }

    private func handleSpeechFailure(_ error: Error) {
        fail(error)
    }

    private func handleNoSpeech() {
        guard phase == .listening else { return }
        record("empty_utterance_ignored", fields: [
            "recovery": "listening_restarted",
        ])
        status("No speech recognized • still listening", .systemRed)
        beginListening()
        record("listening_resumed", fields: [
            "reason": "empty_utterance_recovery",
        ])
    }

    private func interruptPlaybackAndResume() {
        guard phase == .speaking else { return }
        record("interruption_requested", fields: [
            "source": "voice_control",
        ])
        playerDelegate?.completion = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        playerDelegate = nil
        removePlayingAudio()
        record("playback_interrupted", fields: [
            "source": "voice_control",
        ])
        status("Interrupted • microphone active", .systemRed)
        beginListening()
        record("listening_resumed", fields: [
            "reason": "playback_interrupted",
        ])
    }

    private func removePlayingAudio() {
        guard let playingURL else { return }
        try? FileManager.default.removeItem(at: playingURL)
        self.playingURL = nil
    }

    private func status(_ message: String, _ color: NSColor) {
        onStatus?(String(message.prefix(240)), color)
    }

    private func readiness(_ message: String) {
        onReadiness?(String(message.prefix(240)))
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func record(_ event: String, fields: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "schema_version": "voice-session-receipt.v1",
            "module_id": moduleID,
            "module_version": moduleVersion,
            "event": event,
            "phase": phase.rawValue,
            "occurred_at": ISO8601DateFormatter().string(from: Date()),
            "turn_id": turnID?.uuidString ?? NSNull(),
        ]
        fields.forEach { payload[$0] = $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("M4LocalVoiceSession", isDirectory: true)
        let url = root.appendingPathComponent("receipts.jsonl")
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            NSLog("[M4LocalVoiceSession] receipt write failed: %@", error.localizedDescription)
        }
    }

    private func recordConversation(
        role: String,
        text: String,
        fields: [String: Any] = [:]
    ) {
        var payload: [String: Any] = [
            "schema_version": "local-voice-conversation.v1",
            "occurred_at": ISO8601DateFormatter().string(from: Date()),
            "turn_id": turnID?.uuidString ?? NSNull(),
            "role": role,
            "text": String(text.prefix(8_000)),
        ]
        fields.forEach { payload[$0] = $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        appendLocalLine(data, fileName: "conversation.jsonl")
    }

    private func appendLocalLine(_ data: Data, fileName: String) {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("M4LocalVoiceSession", isDirectory: true)
        let url = root.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([0x0A]))
            try handle.close()
        } catch {
            NSLog("[M4LocalVoiceSession] local log write failed: %@", error.localizedDescription)
        }
    }
}

#endif

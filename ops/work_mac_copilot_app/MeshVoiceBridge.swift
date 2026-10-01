import AppKit
import AVFoundation
import Combine

enum MeshVoicePhase: String { case off, loading, listening, transcribing, thinking, speaking, failed }

/// Local audio transport. The coordinator, rather than the speech engine, chooses the agent.
@MainActor final class MeshVoiceBridge: ObservableObject {
    @Published private(set) var status = "Voice off"
    @Published private(set) var isActive = false
    @Published private(set) var isListening = false
    @Published private(set) var phase: MeshVoicePhase = .off
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastASRMilliseconds: Int?
    @Published private(set) var lastTTSMilliseconds: Int?
    @Published var useM1Speakers = UserDefaults.standard.bool(forKey: "mesh.monitor.use-m1-speakers") {
        didSet { UserDefaults.standard.set(useM1Speakers, forKey: "mesh.monitor.use-m1-speakers") }
    }
    let m1Output = MeshM1AudioOutput()
    var onUtterance: ((String) async throws -> String)?
    var onFailure: ((String) -> Void)?
    var onSpeechFinished: (() -> Void)?
    private let speech = M4OnDeviceSpeechInput()
    private let kokoro = M4ResidentKokoroWorker()
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private var conversation = false
    private var sessionUsesM1 = false
    private var outputSubscription: AnyCancellable?
    private var chunks: [String] = []
    private var player: AVAudioPlayer?
    private var playerDelegate: M4LocalAudioPlayerDelegate?
    private var audioURL: URL?

    init() {
        outputSubscription = m1Output.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        speech.onPartial = { [weak self] text in
            guard let self, self.isListening else { return }
            self.status = "Hearing: \(text.prefix(100))"
        }
        speech.onFinal = { [weak self] text in self?.heard(text) }
        speech.onLevel = { [weak self] rms, _ in
            guard let self, self.isListening else { return }
            self.inputLevel = min(1, max(0, rms * 16))
        }
        speech.onCaptureReady = { [weak self] in
            guard let self, self.isActive, self.conversation else { return }
            self.isListening = true; self.phase = .listening
            self.status = "Listening · speak into this Mac's microphone"
        }
        speech.onTranscriptionStarted = { [weak self] in
            guard let self, self.isActive, self.conversation else { return }
            self.isListening = false; self.inputLevel = 0; self.phase = .transcribing
            self.status = "Transcribing locally…"
        }
        speech.onFailure = { [weak self] error in
            guard let self, self.isActive else { return }; self.fail(error)
        }
        speech.onNoSpeech = { [weak self] in
            guard let self, self.isActive, self.conversation else { return }; self.listen()
        }
        speech.onTranscriptionMetrics = { [weak self] _, milliseconds, _ in
            self?.lastASRMilliseconds = milliseconds
        }
    }

    func startConversation(useM1SpeakersOverride: Bool? = nil) {
        stop()
        // Ordinary M4 Talk can choose its own speakers without changing the
        // persisted output preference used by a later scheduled briefing.
        sessionUsesM1 = useM1SpeakersOverride ?? useM1Speakers
        conversation = true; isActive = true
        phase = .loading; status = "Starting local voice · microphone is not listening yet"
        let token = epoch
        task = Task { [weak self] in
            guard let self, self.epoch == token, !Task.isCancelled else { return }
            do {
                try await prepareM4VoiceWorkers(speech: self.speech, kokoro: self.kokoro)
                guard self.epoch == token, !Task.isCancelled else { return }
                self.listen(authorize: true)
            } catch { if self.epoch == token { self.fail(error) } }
        }
    }

    /// TTS-only: this never opens the microphone or starts a language model.
    func speak(_ text: String) {
        stop()
        sessionUsesM1 = useM1Speakers
        isActive = true; phase = .loading; status = "Loading local speech…"
        let token = epoch
        task = Task { [weak self] in
            guard let self, self.epoch == token, !Task.isCancelled else { return }
            do {
                try await self.prepareKokoro()
                guard self.epoch == token, !Task.isCancelled else { return }
                self.chunks = Self.speechChunks(text)
                self.speakNext(token)
            } catch { if self.epoch == token { self.fail(error) } }
        }
    }

    func stop() {
        epoch = UUID(); task?.cancel(); task = nil
        conversation = false; isActive = false; isListening = false; phase = .off; inputLevel = 0
        speech.shutdown()
        m1Output.stop()
        playerDelegate?.completion = nil; player?.stop(); player = nil; playerDelegate = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }; audioURL = nil
        chunks.removeAll(); kokoro.stop(); status = "Voice off"
    }

    var hasOwnedWorkers: Bool { speech.hasOwnedProcess || kokoro.hasOwnedProcess }

    /// Give retained speech children time to acknowledge exit before app Quit.
    /// The app's independent outer deadline remains authoritative.
    func finishStop() async {
        stop()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while hasOwnedWorkers, !Task.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
        }
    }

    private func prepareKokoro() async throws {
        try await kokoro.prepare()
    }

    private func listen(authorize: Bool = false) {
        guard isActive, conversation else { return }
        isListening = false; phase = .loading; inputLevel = 0; status = "Opening this Mac's microphone…"
        if authorize { speech.requestAuthorizationAndStart() } else { speech.start() }
    }

    private func heard(_ text: String) {
        guard isActive, conversation, phase == .listening || phase == .transcribing, let onUtterance else { return }
        lastTranscript = text
        isListening = false; inputLevel = 0; phase = .thinking; speech.stop(); status = "Agent is thinking…"
        let token = epoch
        task = Task { [weak self] in
            guard let self, self.epoch == token, !Task.isCancelled else { return }
            do {
                let answer = try await onUtterance(text)
                guard self.epoch == token, !Task.isCancelled else { return }
                self.chunks = Self.speechChunks(answer)
                self.speakNext(token)
            } catch { if self.epoch == token { self.fail(error) } }
        }
    }

    private func speakNext(_ token: UUID) {
        guard epoch == token, isActive else { return }
        guard !chunks.isEmpty else {
            onSpeechFinished?()
            guard epoch == token, isActive else { return }
            if conversation { listen() } else { isActive = false; phase = .off; status = "Finished speaking" }
            return
        }
        phase = .speaking; status = "Generating local speech…"
        kokoro.synthesize(text: chunks.removeFirst()) { [weak self] result in
            guard let self else { return }
            guard self.epoch == token, self.isActive else {
                if case let .success(value) = result, let output = value.output {
                    try? FileManager.default.removeItem(atPath: output)
                }; return
            }
            do {
                let value = try result.get()
                guard let path = value.output else { throw MeshVoiceError.noAudio }
                self.lastTTSMilliseconds = value.generationMS
                let url = URL(fileURLWithPath: path)
                self.audioURL = url
                if self.sessionUsesM1 {
                    self.status = "Sending speech to M1 speakers…"
                    self.task = Task { [weak self] in
                        guard let self, self.epoch == token, !Task.isCancelled else { return }
                        do {
                            try await self.m1Output.play(url: url)
                            try? FileManager.default.removeItem(at: url)
                            guard self.epoch == token, self.isActive else { return }
                            self.audioURL = nil; self.speakNext(token)
                        } catch {
                            try? FileManager.default.removeItem(at: url)
                            if self.epoch == token { self.fail(error) }
                        }
                    }
                    return
                }
                let player = try AVAudioPlayer(contentsOf: url)
                let delegate = M4LocalAudioPlayerDelegate()
                delegate.completion = { [weak self] succeeded in
                    try? FileManager.default.removeItem(at: url)
                    guard let self, self.epoch == token else { return }
                    self.player = nil; self.playerDelegate = nil; self.audioURL = nil
                    if succeeded { self.speakNext(token) } else { self.fail(MeshVoiceError.noAudio) }
                }
                self.player = player; self.playerDelegate = delegate; player.delegate = delegate
                guard player.play() else { throw MeshVoiceError.noAudio }
                self.status = "Speaking · tap Stop to interrupt"
            } catch { self.fail(error) }
        }
    }

    private func fail(_ error: Error) {
        stop(); phase = .failed; status = error.localizedDescription; onFailure?(status)
    }

    /// Keep the whole answer; the old shell silently spoke only its first sentence.
    static func speechChunks(_ text: String) -> [String] {
        let words = text.replacingOccurrences(of: "\n", with: " ").split(whereSeparator: \.isWhitespace)
        var result: [String] = []; var current = ""
        for word in words {
            let parts = stride(from: 0, to: word.count, by: 450).map { start in
                String(word.dropFirst(start).prefix(450))
            }
            for part in parts {
                if current.count + part.count + 1 > 480 { result.append(current); current = "" }
                if !current.isEmpty { current += " " }; current += part
            }
        }
        if !current.isEmpty { result.append(current) }; return result
    }
}

private enum MeshVoiceError: LocalizedError {
    case noAudio
    var errorDescription: String? { "Local speech could not be played. The full reply remains in the conversation." }
}

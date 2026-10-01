@preconcurrency import AVFoundation
import Foundation

#if M4_LOCAL_VOICE_SESSION

private enum M4ParakeetSpeechInputError: Error, LocalizedError {
    case microphoneDenied
    case runtimeMissing
    case modelsMissing
    case workerFailed(String)
    case captureFailed
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone permission was denied."
        case .runtimeMissing: "The bundled Parakeet runtime is unavailable."
        case .modelsMissing: "The local Parakeet model is unavailable."
        case let .workerFailed(reason): "Parakeet failed: \(reason)"
        case .captureFailed: "Microphone capture could not start."
        case .emptyTranscript: "Parakeet returned an empty transcript."
        }
    }
}

private struct M4ParakeetWorkerResult: Decodable {
    let id: String?
    let event: String?
    let ok: Bool?
    let text: String?
    let confidence: Float?
    let durationMS: Int?
    let inferenceMS: Int?
    let engine: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, event, ok, text, confidence, engine, error
        case durationMS = "duration_ms"
        case inferenceMS = "inference_ms"
    }
}

private final class M4ParakeetCaptureState: @unchecked Sendable {
    typealias LevelHandler = @Sendable (Float, Float) -> Void
    typealias SpeechHandler = @Sendable () -> Void
    typealias FinalHandler = @Sendable (URL, Int) -> Void
    typealias FailureHandler = @Sendable (Error) -> Void

    private let lock = NSLock()
    private let levelHandler: LevelHandler
    private let speechHandler: SpeechHandler
    private let finalHandler: FinalHandler
    private let failureHandler: FailureHandler
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFramePosition = 0
    private var writer: AVAudioFile?
    private var outputURL: URL?
    private var speechStarted = false
    private var finished = false
    private var consecutiveSpeechBuffers = 0
    private var lastSpeechAt = Date.distantPast
    private var speechStartedAt = Date.distantPast
    private var noiseFloor: Float = 0.002
    private var lastLevelReport = Date.distantPast

    init(
        levelHandler: @escaping LevelHandler,
        speechHandler: @escaping SpeechHandler,
        finalHandler: @escaping FinalHandler,
        failureHandler: @escaping FailureHandler
    ) {
        self.levelHandler = levelHandler
        self.speechHandler = speechHandler
        self.finalHandler = finalHandler
        self.failureHandler = failureHandler
    }

    func accept(_ source: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, source.frameLength > 0,
              let samples = source.floatChannelData?.pointee
        else { return }

        let count = Int(source.frameLength)
        var sumSquares: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(sumSquares / Float(count))
        let now = Date()
        if now.timeIntervalSince(lastLevelReport) >= 0.5 {
            lastLevelReport = now
            levelHandler(rms, peak)
        }

        if !speechStarted {
            noiseFloor = min(0.02, (noiseFloor * 0.97) + (min(rms, 0.02) * 0.03))
            if let copied = copy(source) {
                preRoll.append(copied)
                preRollFrames += AVAudioFramePosition(copied.frameLength)
                let maximum = AVAudioFramePosition(source.format.sampleRate * 0.45)
                while preRollFrames > maximum, let oldest = preRoll.first {
                    preRoll.removeFirst()
                    preRollFrames -= AVAudioFramePosition(oldest.frameLength)
                }
            }
        }

        let threshold = max(0.006, noiseFloor * 2.7)
        if rms >= threshold {
            consecutiveSpeechBuffers += 1
            lastSpeechAt = now
        } else {
            consecutiveSpeechBuffers = 0
        }

        if !speechStarted, consecutiveSpeechBuffers >= 2 {
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("m4-parakeet-\(UUID().uuidString).caf")
                let file = try AVAudioFile(
                    forWriting: url,
                    settings: source.format.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: source.format.isInterleaved
                )
                for buffer in preRoll { try file.write(from: buffer) }
                preRoll.removeAll(keepingCapacity: false)
                preRollFrames = 0
                writer = file
                outputURL = url
                speechStarted = true
                speechStartedAt = now
                speechHandler()
            } catch {
                finished = true
                failureHandler(error)
                return
            }
        } else if speechStarted {
            do {
                try writer?.write(from: source)
            } catch {
                finished = true
                failureHandler(error)
                return
            }
        }

        guard speechStarted, let outputURL else { return }
        let spokenFor = now.timeIntervalSince(speechStartedAt)
        let silenceFor = now.timeIntervalSince(lastSpeechAt)
        if (spokenFor >= 0.28 && silenceFor >= 0.72) || spokenFor >= 20 {
            finished = true
            writer = nil
            let durationMS = Int(spokenFor * 1_000)
            finalHandler(outputURL, durationMS)
        }
    }

    private func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        result.frameLength = source.frameLength
        let buffers = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        let sources = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        guard buffers.count == sources.count else { return nil }
        for index in 0..<buffers.count {
            guard let destination = buffers[index].mData,
                  let input = sources[index].mData
            else { return nil }
            memcpy(destination, input, Int(sources[index].mDataByteSize))
            buffers[index].mDataByteSize = sources[index].mDataByteSize
        }
        return result
    }
}

@MainActor
private final class M4ParakeetAudioCapture: NSObject, AVAudioRecorderDelegate {
    typealias LevelHandler = (Float, Float) -> Void
    typealias SpeechHandler = () -> Void
    typealias ReadyHandler = () -> Void
    typealias FinalHandler = (URL, Int) -> Void
    typealias FailureHandler = (Error) -> Void

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var outputURL: URL?
    private var startedAt = Date.distantPast
    private var speechStartedAt = Date.distantPast
    private var lastSpeechAt = Date.distantPast
    private var speechStarted = false
    private var consecutiveSpeechSamples = 0
    private var noiseFloorDB: Float = -58
    private var lastLevelReport = Date.distantPast
    private var speechArmAt = Date.distantPast
    private var levelHandler: LevelHandler?
    private var speechHandler: SpeechHandler?
    private var finalHandler: FinalHandler?
    private var failureHandler: FailureHandler?

    var isRunning: Bool { recorder?.isRecording == true }

    func start(
        levelHandler: @escaping LevelHandler,
        speechHandler: @escaping SpeechHandler,
        readyHandler: @escaping ReadyHandler,
        finalHandler: @escaping FinalHandler,
        failureHandler: @escaping FailureHandler
    ) {
        stop()
        self.levelHandler = levelHandler
        self.speechHandler = speechHandler
        self.finalHandler = finalHandler
        self.failureHandler = failureHandler
        speechStarted = false
        consecutiveSpeechSamples = 0
        noiseFloorDB = -58
        lastLevelReport = .distantPast
        // Avoid treating the speaker tail, recorder startup transient, or the
        // immediate post-empty-result room noise as a new user utterance.
        speechArmAt = Date().addingTimeInterval(0.75)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-parakeet-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw M4ParakeetSpeechInputError.captureFailed
            }
            self.recorder = recorder
            outputURL = url
            startedAt = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.sampleLevel() }
            }
            readyHandler()
        } catch {
            try? FileManager.default.removeItem(at: url)
            failureHandler(error)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    private func sampleLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let averageDB = recorder.averagePower(forChannel: 0)
        let peakDB = recorder.peakPower(forChannel: 0)
        let rms = pow(10, averageDB / 20)
        let peak = pow(10, peakDB / 20)
        let now = Date()
        if now.timeIntervalSince(lastLevelReport) >= 0.5 {
            lastLevelReport = now
            levelHandler?(rms, peak)
        }

        if !speechStarted {
            noiseFloorDB = min(-24, (noiseFloorDB * 0.96) + (min(averageDB, -24) * 0.04))
        }
        // A two-sample/-42 dB gate repeatedly promoted keyboard/room noise to
        // speech. Require a sustained average plus a real transient peak.
        let thresholdDB = max(-36, noiseFloorDB + 14)
        let peakThresholdDB: Float = -24
        let armed = now >= speechArmAt
        if armed, averageDB >= thresholdDB, peakDB >= peakThresholdDB {
            consecutiveSpeechSamples += 1
            lastSpeechAt = now
        } else {
            consecutiveSpeechSamples = 0
        }

        if !speechStarted, consecutiveSpeechSamples >= 8 {
            speechStarted = true
            speechStartedAt = now
            speechHandler?()
        }
        guard speechStarted, let outputURL else { return }
        let spokenFor = now.timeIntervalSince(speechStartedAt)
        let silenceFor = now.timeIntervalSince(lastSpeechAt)
        if (spokenFor >= 0.28 && silenceFor >= 0.72) || spokenFor >= 20 {
            timer?.invalidate()
            timer = nil
            recorder.stop()
            self.recorder = nil
            self.outputURL = nil
            do {
                let preRollSeconds = 0.40
                let startOffset = max(
                    0,
                    speechStartedAt.timeIntervalSince(startedAt) - preRollSeconds
                )
                let endOffset = now.timeIntervalSince(startedAt)
                let trimmedURL = try trimRecording(
                    at: outputURL,
                    startOffset: startOffset,
                    endOffset: endOffset
                )
                try? FileManager.default.removeItem(at: outputURL)
                let durationMS = Int((endOffset - startOffset) * 1_000)
                finalHandler?(trimmedURL, durationMS)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                failureHandler?(error)
            }
        }
    }

    private func trimRecording(
        at sourceURL: URL,
        startOffset: TimeInterval,
        endOffset: TimeInterval
    ) throws -> URL {
        let input = try AVAudioFile(forReading: sourceURL)
        let sampleRate = input.processingFormat.sampleRate
        let startFrame = max(
            0,
            AVAudioFramePosition(startOffset * sampleRate)
        )
        let requestedEnd = AVAudioFramePosition(endOffset * sampleRate)
        let endFrame = min(input.length, max(startFrame + 1, requestedEnd))
        input.framePosition = min(startFrame, max(0, input.length - 1))

        let trimmedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-parakeet-trimmed-\(UUID().uuidString).caf")
        let output = try AVAudioFile(
            forWriting: trimmedURL,
            settings: input.fileFormat.settings,
            commonFormat: input.processingFormat.commonFormat,
            interleaved: input.processingFormat.isInterleaved
        )
        var remaining = endFrame - input.framePosition
        let frameCapacity: AVAudioFrameCount = 16_384
        while remaining > 0 {
            let requested = AVAudioFrameCount(min(
                AVAudioFramePosition(frameCapacity),
                remaining
            ))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat,
                frameCapacity: requested
            ) else {
                throw M4ParakeetSpeechInputError.captureFailed
            }
            try input.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return trimmedURL
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.failureHandler?(error ?? M4ParakeetSpeechInputError.captureFailed)
        }
    }
}

/// Local microphone + energy endpointing adapter backed by a resident
/// FluidAudio Parakeet worker. Raw capture is temporary and deleted immediately
/// after the local worker returns a transcript.
@MainActor
final class M4OnDeviceSpeechInput: NSObject {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onLevel: ((Float, Float) -> Void)?
    var onCaptureReady: (() -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onTranscriptionMetrics: ((Float, Int, Int) -> Void)?
    var onTranscriptionStarted: (() -> Void)?
    var onNoSpeech: (() -> Void)?
    // Construct capture only when explicitly starting a microphone, never during prepare/tests.
    private var audioCapture: M4ParakeetAudioCapture?
    private var captureEpoch = UUID()
    private let worker: M4ResidentJSONWorker
    var isRunning: Bool { audioCapture?.isRunning == true }
    var isReady: Bool { worker.isReady }
    var hasOwnedProcess: Bool { worker.hasOwnedProcess }

    init(limits: M4ResidentJSONWorker.Limits = .init(),
         launch: (() throws -> M4ResidentJSONWorker.Launch)? = nil) {
        worker = M4ResidentJSONWorker(limits: limits, launch: launch ?? Self.defaultLaunch)
        super.init()
        worker.onUnexpectedExit = { [weak self] error in
            guard let self, self.isRunning else { return }
            self.stop(); self.onFailure?(error)
        }
    }
    func prepare() async throws { try await worker.prepare() }

    func requestAuthorizationAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized, .notDetermined:
            // Core Audio enforces the TCC grant on this ad-hoc macOS build.
            start()
        case .denied, .restricted: onFailure?(M4ParakeetSpeechInputError.microphoneDenied)
        @unknown default: onFailure?(M4ParakeetSpeechInputError.microphoneDenied)
        }
    }
    func start() {
        stop()
        guard isReady else { onFailure?(M4ParakeetSpeechInputError.runtimeMissing); return }
        let epoch = captureEpoch
        let capture = audioCapture ?? M4ParakeetAudioCapture(); audioCapture = capture
        capture.start(
            levelHandler: { [weak self] rms, peak in
                guard self?.captureEpoch == epoch else { return }; self?.onLevel?(rms, peak)
            },
            speechHandler: { [weak self] in
                guard self?.captureEpoch == epoch else { return }; self?.onSpeechStarted?()
            },
            readyHandler: { [weak self] in
                guard self?.captureEpoch == epoch else { return }; self?.onCaptureReady?()
            },
            finalHandler: { [weak self] url, durationMS in
                guard let self, self.captureEpoch == epoch else { try? FileManager.default.removeItem(at: url); return }
                self.finishCapture(url, durationMS: durationMS)
            },
            failureHandler: { [weak self] error in
                guard self?.captureEpoch == epoch else { return }; self?.onFailure?(error)
            })
    }
    func stop() { captureEpoch = UUID(); audioCapture?.stop() }
    func shutdown() { stop(); worker.stop() }

    private static func defaultLaunch() throws -> M4ResidentJSONWorker.Launch {
        guard let resources = Bundle.main.resourceURL else { throw M4ParakeetSpeechInputError.runtimeMissing }
        let executable = resources.appendingPathComponent("M4ParakeetWorker")
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw M4ParakeetSpeechInputError.runtimeMissing }
        guard FileManager.default.fileExists(atPath: models.path) else { throw M4ParakeetSpeechInputError.modelsMissing }
        return .init(executable: executable, arguments: [models.path],
            environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "NO_PROXY": "*"])
    }
    private func finishCapture(_ url: URL, durationMS: Int) {
        stop(); onTranscriptionStarted?()
        let epoch = captureEpoch
        let requestID = UUID().uuidString
        worker.request(id: requestID, payload: ["input": url.path]) { [weak self] result in
            try? FileManager.default.removeItem(at: url)
            guard let self, self.captureEpoch == epoch else { return }
            do {
                let value = try JSONDecoder().decode(M4ParakeetWorkerResult.self, from: result.get())
                guard value.ok == true else { throw M4ParakeetSpeechInputError.workerFailed(value.error ?? "unknown") }
                let text = (value.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.onTranscriptionMetrics?(value.confidence ?? -1, value.inferenceMS ?? -1, durationMS)
                guard !text.isEmpty else { self.onNoSpeech?(); return }
                self.onFinal?(text)
            } catch { self.onFailure?(error) }
        }
    }
}

#endif

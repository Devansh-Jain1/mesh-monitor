import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit

private enum MeshCaptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Explicit local captions. Construction is inert. There is deliberately no agent or TTS callback.
@MainActor final class MeshTranscription: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case microphone = "Microphone"
        case systemAudio = "Mac audio"
        var id: String { rawValue }
    }
    @Published var source: Source = .microphone
    @Published var largeText = true
    @Published var highContrast = true
    @Published private(set) var isActive = false
    @Published private(set) var status = "Captions off"
    @Published private(set) var partialText = ""
    @Published private(set) var lines: [MeshCaptionLine] = []
    @Published private(set) var level: Float = 0
    @Published private(set) var lastInferenceMilliseconds: Int?
    private var transcript = MeshCaptionTranscript()
    private let worker = MeshCaptionWorker()
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var sink: MeshCaptionAudioSink?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var pending: [MeshCaptionPacket] = []
    private var processing = false
    private var silenceTask: Task<Void, Never>?
    private var lastActivity = Date.distantPast

    func start(source selectedSource: Source) {
        stop(); source = selectedSource; isActive = true; status = "Preparing local captions…"
        let token = generation
        task = Task { [weak self] in
            guard let self, self.generation == token, !Task.isCancelled else { return }
            do {
                if selectedSource == .microphone {
                    let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
                    if authorization == .notDetermined {
                        guard await AVCaptureDevice.requestAccess(for: .audio) else {
                            throw MeshCaptionError.message("Microphone access is off. Enable Mesh Monitor in System Settings → Privacy & Security → Microphone.")
                        }
                    } else if authorization != .authorized {
                        throw MeshCaptionError.message("Microphone access is off. Enable Mesh Monitor in System Settings → Privacy & Security → Microphone.")
                    }
                } else if !CGPreflightScreenCaptureAccess() {
                    // Only an explicit Start invokes the system permission UI.
                    _ = CGRequestScreenCaptureAccess()
                    throw MeshCaptionError.message("Mac audio needs Screen & System Audio Recording access. Enable Mesh Monitor in System Settings, then start captions again. No screen images are read.")
                }
                guard self.generation == token, !Task.isCancelled else { return }
                try await self.worker.prepare()
                guard self.generation == token, !Task.isCancelled else { return }
                let sink = MeshCaptionAudioSink(packet: { [weak self] packet in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.isActive else { return }
                        self.enqueue(packet)
                    }
                }, level: { [weak self] rms in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.isActive else { return }
                        self.level = min(1, rms * 8)
                        if rms >= 0.006 { self.lastActivity = Date() }
                    }
                }, failure: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.isActive else { return }
                        self.fail(error)
                    }
                })
                self.sink = sink
                if selectedSource == .microphone {
                    let engine = AVAudioEngine()
                    let node = engine.inputNode
                    let format = node.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        throw MeshCaptionError.message("No microphone input is available.")
                    }
                    node.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in sink.accept(buffer) }
                    self.engine = engine
                    engine.prepare(); try engine.start()
                } else {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    guard self.generation == token, !Task.isCancelled else { return }
                    guard let display = content.displays.first else {
                        throw MeshCaptionError.message("No display is available for Mac audio capture.")
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let configuration = SCStreamConfiguration()
                    configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
                    configuration.sampleRate = 16_000; configuration.channelCount = 1
                    configuration.width = 2; configuration.height = 2
                    configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
                    configuration.showsCursor = false
                    let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
                    // Only audio output is registered. No video output or screenshot API is used.
                    try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                    self.stream = stream
                    try await stream.startCapture()
                    guard self.generation == token, !Task.isCancelled else {
                        try? await stream.stopCapture(); return
                    }
                }
                self.status = "Listening · \(selectedSource.rawValue) · local only"
                self.lastActivity = Date()
                self.silenceTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let self, self.generation == token, self.isActive, !Task.isCancelled else { return }
                        if Date().timeIntervalSince(self.lastActivity) > 8, !self.processing {
                            self.status = "Waiting for speech · \(selectedSource.rawValue)"
                        }
                    }
                }
            } catch { if self.generation == token { self.fail(error) } }
        }
    }

    func stop() {
        generation = UUID(); isActive = false
        task?.cancel(); task = nil; silenceTask?.cancel(); silenceTask = nil
        // Disable the sink synchronously before asynchronous ScreenCaptureKit teardown.
        sink?.disable(); sink = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        worker.stop(); pending.removeAll(); processing = false; level = 0
        transcript.discardPartial(); partialText = ""; status = "Captions off"
    }
    func clear() {
        // No already-running inference may repopulate a cleared transcript.
        let resume = isActive; let selected = source
        stop(); transcript.clear(); lines = []; partialText = ""
        if resume { start(source: selected) }
    }
    func exportText() -> String { transcript.exportText }

    private func enqueue(_ packet: MeshCaptionPacket) {
        // Keep only the newest queued partial for an utterance; final results are never silently dropped.
        pending.removeAll { $0.utteranceID == packet.utteranceID && !$0.isFinal }
        if !packet.isFinal, pending.contains(where: { $0.utteranceID == packet.utteranceID && $0.isFinal }) { return }
        guard pending.count < 4 else {
            fail(MeshCaptionError.message("Captions paused because local transcription fell behind. Start again to continue.")); return
        }
        pending.append(packet); drain()
    }
    private func drain() {
        guard isActive, !processing, !pending.isEmpty else { return }
        processing = true; status = "Transcribing · local Parakeet"
        let packet = pending.removeFirst(), token = generation
        worker.transcribe(packet) { [weak self] result in
            guard let self, self.generation == token, self.isActive else { return }
            self.processing = false
            switch result {
            case let .success(value):
                self.transcript.apply(value.text, packet: packet)
                self.lines = self.transcript.lines; self.partialText = self.transcript.partialText
                self.lastInferenceMilliseconds = value.inferenceMS
                self.status = value.text.isEmpty ? "Waiting for speech · \(self.source.rawValue)" : "Listening · \(self.source.rawValue) · local only"
                self.drain()
            case let .failure(error): self.fail(error)
            }
        }
    }
    private func fail(_ error: Error) { stop(); status = error.localizedDescription }
}

private final class MeshCaptionAudioSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "mesh.monitor.captions.audio")
    private let lock = NSLock()
    private var enabled = true
    private var segmenter = MeshCaptionSegmenter()
    private var lastLevel = Date.distantPast
    private let packet: @Sendable (MeshCaptionPacket) -> Void
    private let level: @Sendable (Float) -> Void
    private let failure: @Sendable (Error) -> Void
    init(packet: @escaping @Sendable (MeshCaptionPacket) -> Void,
         level: @escaping @Sendable (Float) -> Void, failure: @escaping @Sendable (Error) -> Void) {
        self.packet = packet; self.level = level; self.failure = failure
    }
    func disable() { lock.lock(); enabled = false; segmenter.reset(); lock.unlock() }
    func accept(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.frameLength <= 65_536,
              let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, channelCount <= 32 else { return }
        var mono = [Float](repeating: 0, count: count)
        if buffer.format.isInterleaved {
            for frame in 0..<count {
                for channel in 0..<channelCount { mono[frame] += channels[0][frame * channelCount + channel] / Float(channelCount) }
            }
        } else {
            for channel in 0..<channelCount {
                for frame in 0..<count { mono[frame] += channels[channel][frame] / Float(channelCount) }
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        if Date().timeIntervalSince(lastLevel) > 0.25 {
            lastLevel = Date(); level(sqrt(mono.reduce(0) { $0 + $1 * $1 } / Float(count)))
        }
        for value in segmenter.append(mono, sampleRate: buffer.format.sampleRate) { packet(value) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.channelCount > 0, format.channelCount <= 32 else { return }
        let list = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        defer { list.unsafeMutablePointer.deallocate() }
        var block: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: Int(format.channelCount)),
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
        guard result == noErr,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil) else { return }
        withExtendedLifetime(block) { accept(buffer) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let active = enabled; lock.unlock()
        if active { failure(error) }
    }
}

/// One owned worker, one request at a time, bounded output, private short-lived WAVs.
@MainActor private final class MeshCaptionWorker {
    struct ResultValue { let text: String; let inferenceMS: Int? }
    private struct Reply: Decodable {
        let id: String?; let event: String?; let ok: Bool?; let text: String?; let error: String?
        let inference_ms: Int?
    }
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var ready = false
    private var prepareContinuation: CheckedContinuation<Void, Error>?
    private var callback: ((Result<ResultValue, Error>) -> Void)?
    private var requestID: String?
    private var audioURL: URL?
    private var directory: URL?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()

    func prepare() async throws {
        stop()
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("M4ParakeetWorker"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MeshCaptionError.message("The bundled local Parakeet worker is missing.")
        }
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
        guard FileManager.default.fileExists(atPath: models.path) else {
            throw MeshCaptionError.message("The local Parakeet model is missing. Captions could not start.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-captions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = folder
        let token = generation
        try await withCheckedThrowingContinuation { continuation in
            prepareContinuation = continuation
            let process = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
            process.executableURL = executable; process.arguments = [models.path]
            process.standardInput = stdinPipe; process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "NO_PROXY": "*"]
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.abort(MeshCaptionError.message("Local transcription stopped unexpectedly. Start captions again."))
                }
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }; self.consume(data)
                }
            }
            do {
                try process.run(); self.process = process
                input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
                setDeadline(token)
            } catch { abort(error) }
        }
    }
    func transcribe(_ packet: MeshCaptionPacket, completion: @escaping (Result<ResultValue, Error>) -> Void) {
        guard ready, process?.isRunning == true, callback == nil, let input, let directory else {
            completion(.failure(MeshCaptionError.message("Local captions worker is unavailable."))); return
        }
        let id = UUID().uuidString
        let url = directory.appendingPathComponent("\(id).wav")
        do {
            try Self.wav(packet).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            callback = completion; requestID = id; audioURL = url
            var data = try JSONSerialization.data(withJSONObject: ["id": id, "input": url.path]); data.append(10)
            try input.write(contentsOf: data); setDeadline(generation)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if callback != nil { abort(error) } else { completion(.failure(error)) }
        }
    }
    func stop() { abort(CancellationError()) }
    private func abort(_ error: Error) {
        generation = UUID(); deadline?.cancel(); deadline = nil; ready = false
        output?.readabilityHandler = nil; try? input?.close(); try? output?.close()
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; buffer.removeAll()
        let continuation = prepareContinuation; prepareContinuation = nil
        let callback = self.callback; self.callback = nil; requestID = nil; audioURL = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
        continuation?.resume(throwing: error); callback?(.failure(error))
    }
    private func setDeadline(_ token: UUID) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.abort(MeshCaptionError.message("Local captions timed out. Start again to retry."))
        }
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { abort(MeshCaptionError.message("Local caption response exceeded its limit.")); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else { continue }
            if reply.event == "ready" {
                ready = true; deadline?.cancel(); deadline = nil
                let continuation = prepareContinuation; prepareContinuation = nil; continuation?.resume()
            } else if reply.event == "failed" {
                abort(MeshCaptionError.message("Local Parakeet could not load. \(String((reply.error ?? "Unknown error").prefix(250)))")); return
            } else if reply.id == requestID, let callback {
                deadline?.cancel(); deadline = nil
                if let audioURL { try? FileManager.default.removeItem(at: audioURL) }; audioURL = nil
                self.callback = nil; requestID = nil
                if reply.ok == true { callback(.success(ResultValue(text: reply.text ?? "", inferenceMS: reply.inference_ms))) }
                else { callback(.failure(MeshCaptionError.message("Local transcription failed. \(String((reply.error ?? "Unknown error").prefix(250)))"))) }
            }
        }
    }
    private static func wav(_ packet: MeshCaptionPacket) -> Data {
        var result = Data()
        func ascii(_ value: String) { result.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        let bytes = UInt32(packet.samples.count * 2), rate = UInt32(packet.sampleRate)
        ascii("RIFF"); number(bytes + 36); ascii("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(rate); number(rate * 2)
        number(UInt16(2)); number(UInt16(16)); ascii("data"); number(bytes)
        for sample in packet.samples { number(Int16(max(-1, min(1, sample.isFinite ? sample : 0)) * 32_767)) }
        return result
    }
}

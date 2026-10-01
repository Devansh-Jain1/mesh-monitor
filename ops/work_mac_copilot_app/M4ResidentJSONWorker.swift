import Darwin
import Foundation

/// Readability callbacks run off the main actor. This inbox schedules at most one
/// delivery at a time and bounds bytes before dispatching, including stdout floods.
private final class M4ResidentWorkerInbox: @unchecked Sendable {
    struct Batch { let data: Data; let eof: Bool; let overflow: Bool }
    private let lock = NSLock()
    private let handle: FileHandle
    private let descriptor: Int32
    private var data = Data()
    private var eof = false, overflow = false, scheduled = false, revoked = false
    init(_ handle: FileHandle) throws {
        self.handle = handle; descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw M4ResidentJSONWorker.Failure.invalidOutput
        }
    }
    func readAvailable() -> (schedule: Bool, ended: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !revoked else { return (false, true) }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return (false, false) }
        if count <= 0 { eof = true }
        else if data.count + count > 65_536 { overflow = true; data.removeAll() }
        else if !overflow { data.append(contentsOf: bytes.prefix(count)) }
        let schedule = !scheduled; scheduled = true
        return (schedule, eof || overflow)
    }
    func drain() -> Batch? {
        lock.lock(); defer { lock.unlock() }
        guard !revoked else { return nil }
        let batch = Batch(data: data, eof: eof, overflow: overflow)
        data.removeAll(); eof = false; overflow = false; scheduled = false
        return batch
    }
    func revoke() {
        lock.lock(); defer { lock.unlock() }
        guard !revoked else { return }
        revoked = true; data.removeAll()
        try? handle.close()
    }
}

/// One owned pipe-only worker. No models, microphone, or audio APIs live here.
/// Callbacks settle once; a timed-out child remains owned until its exit is observed.
@MainActor final class M4ResidentJSONWorker {
    struct Launch {
        var executable: URL
        var arguments: [String] = []
        var environment: [String: String] = [:]
    }
    struct Limits {
        var startup: TimeInterval = 60
        var request: TimeInterval = 45
        var terminateGrace: TimeInterval = 1
    }
    enum Failure: Error, LocalizedError {
        case cancelled, stopping, unavailable, busy, startupTimeout, requestTimeout, eof, invalidOutput, writeFailed, terminated
        var errorDescription: String? {
            switch self {
            case .cancelled: "Local speech worker cancelled."
            case .stopping: "The previous local speech worker is still stopping. Try Talk again shortly."
            case .unavailable: "Local speech worker is not ready."
            case .busy: "Local speech worker already has a pending request."
            case .startupTimeout: "Local speech worker took too long to start. Try Talk again."
            case .requestTimeout: "Local speech worker took too long to respond. Try Talk again."
            case .eof: "Local speech worker closed its response pipe. Try Talk again."
            case .invalidOutput: "Local speech worker returned an invalid response. Try Talk again."
            case .writeFailed: "Local speech worker could not receive its request. Try Talk again."
            case .terminated: "Local speech worker exited. Try Talk again."
            }
        }
    }
    private enum State { case idle, starting, ready, stopping }
    private let launch: () throws -> Launch
    private let limits: Limits
    private var state: State = .idle
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var inbox: M4ResidentWorkerInbox?
    private var buffer = Data()
    private var generation = UUID()
    private var startup: [(Result<Void, Error>) -> Void] = []
    private var preparationIDs = Set<UUID>()
    private var pending: (id: String, callback: (Result<Data, Error>) -> Void)?
    private var startupTimer: Task<Void, Never>?
    private var requestTimer: Task<Void, Never>?
    private var stopTimer: Task<Void, Never>?
    var onUnexpectedExit: ((Error) -> Void)?
    var onExit: (() -> Void)?
    var isReady: Bool { state == .ready && process?.isRunning == true }
    var hasOwnedProcess: Bool { process != nil }
    var ownedProcessID: Int32? { process?.processIdentifier }

    init(limits: Limits = Limits(), launch: @escaping () throws -> Launch) {
        self.limits = limits; self.launch = launch
    }
    func prepare() async throws {
        try Task.checkCancellation()
        let preparationID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                preparationIDs.insert(preparationID)
                start { [weak self] result in
                    self?.preparationIDs.remove(preparationID)
                    continuation.resume(with: result)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.preparationIDs.contains(preparationID) else { return }
                self.stop()
            }
        })
    }
    func start(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if isReady { completion(.success(())); return }
        if state == .stopping { completion(.failure(Failure.stopping)); return }
        if state == .ready, process != nil {
            // A dead child may be waiting for its termination callback on this actor.
            // Do not overwrite its handles before that exact generation is retired.
            fail(Failure.terminated); completion(.failure(Failure.terminated)); return
        }
        startup.append(completion)
        if state == .starting { return }
        state = .starting; generation = UUID(); let token = generation
        do {
            let spec = try launch(), child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
            child.executableURL = spec.executable; child.arguments = spec.arguments
            child.environment = spec.environment
            child.standardInput = stdinPipe; child.standardOutput = stdoutPipe
            child.standardError = FileHandle.nullDevice
            input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
            let flags = fcntl(input!.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(input!.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.writeFailed }
            let inbox = try M4ResidentWorkerInbox(stdoutPipe.fileHandleForReading); self.inbox = inbox
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in self?.exited(child, token: token) }
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let event = inbox.readAvailable()
                if event.ended { handle.readabilityHandler = nil }
                guard event.schedule else { return }
                Task { @MainActor in
                    guard let batch = inbox.drain(), let self, self.generation == token else { return }
                    if batch.overflow { self.fail(Failure.invalidOutput); return }
                    if !batch.data.isEmpty { self.received(batch.data, token: token) }
                    if batch.eof { self.received(Data(), token: token) }
                }
            }
            process = child
            try child.run()
            startupTimer = timer(after: limits.startup) { [weak self] in
                guard let self, self.generation == token, self.state == .starting else { return }
                self.fail(Failure.startupTimeout)
            }
        } catch {
            closePipes(); process = nil; state = .idle
            finishStartup(.failure(error))
        }
    }
    func request(id: String, payload: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        guard isReady, let input else { completion(.failure(Failure.unavailable)); return }
        guard pending == nil else { completion(.failure(Failure.busy)); return }
        do {
            var value = payload; value["id"] = id
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            guard data.count <= 16_384 else { throw Failure.writeFailed }
            pending = (id, completion)
            let token = generation
            requestTimer = timer(after: limits.request) { [weak self] in
                guard let self, self.generation == token, self.pending?.id == id else { return }
                self.fail(Failure.requestTimeout)
            }
            // Nonblocking writes cannot freeze the main actor if a child stops reading.
            try input.write(contentsOf: data)
        } catch {
            if pending != nil { fail(Failure.writeFailed) }
            else { completion(.failure(error)) }
        }
    }
    func stop() { fail(Failure.cancelled) }

    private func received(_ data: Data, token: UUID) {
        guard generation == token, state == .starting || state == .ready else { return }
        guard !data.isEmpty else { fail(Failure.eof); return }
        guard buffer.count + data.count <= 65_536 else { fail(Failure.invalidOutput); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard line.count <= 16_384,
                  let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { fail(Failure.invalidOutput); return }
            if value["event"] as? String == "ready" {
                guard state == .starting else { fail(Failure.invalidOutput); return }
                state = .ready; startupTimer?.cancel(); startupTimer = nil
                finishStartup(.success(()))
            } else if value["event"] as? String == "failed" {
                fail(Failure.unavailable); return
            } else {
                guard state == .ready, let id = value["id"] as? String,
                      pending?.id == id else { fail(Failure.invalidOutput); return }
                requestTimer?.cancel(); requestTimer = nil
                let callback = pending?.callback; pending = nil
                callback?(.success(line))
            }
            guard generation == token, state == .starting || state == .ready else { return }
        }
        if buffer.count > 16_384 { fail(Failure.invalidOutput) }
    }
    private func fail(_ error: Error) {
        guard state != .stopping else { return }
        let hadWork = !startup.isEmpty || pending != nil
        let hadReady = state == .ready
        state = process == nil ? .idle : .stopping
        startupTimer?.cancel(); startupTimer = nil; requestTimer?.cancel(); requestTimer = nil
        closePipes()
        let callback = pending?.callback; pending = nil
        finishStartup(.failure(error)); callback?(.failure(error))
        if hadReady && !hadWork {
            if case Failure.cancelled = error {} else { onUnexpectedExit?(error) }
        }
        guard let child = process else { return }
        let token = generation
        if child.isRunning { child.terminate() }
        stopTimer?.cancel()
        stopTimer = timer(after: limits.terminateGrace) { [weak self, child] in
            guard let self, self.generation == token, self.process === child else { return }
            // The retained Process still identifies this owned child. Never signal by a saved PID alone.
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            if !child.isRunning { self.exited(child, token: token) }
        }
    }
    private func exited(_ child: Process, token: UUID) {
        guard generation == token, process === child else { return }
        let wasStopping = state == .stopping
        if !wasStopping { fail(Failure.terminated) }
        stopTimer?.cancel(); stopTimer = nil
        closePipes(); process = nil; state = .idle
        onExit?()
    }
    private func closePipes() {
        output?.readabilityHandler = nil
        try? input?.close()
        if let inbox { inbox.revoke() } else { try? output?.close() }
        inbox = nil
        input = nil; output = nil; buffer.removeAll()
    }
    private func finishStartup(_ result: Result<Void, Error>) {
        let callbacks = startup; startup.removeAll(); callbacks.forEach { $0(result) }
    }
    private func timer(after seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let seconds = seconds.isFinite ? min(300, max(0.01, seconds)) : 60
        return Task {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            action()
        }
    }
}

import Darwin
import Foundation

enum MeshM1CameraTransportError: Error { case closed, invalidLine, backpressure, startup, invalidHealth }

/// A single explicit invocation owns the control pipe and loopback forward.
/// Initialization does no I/O. No credentials or user-supplied shell text enter argv.
final class MeshM1CameraSSH: MeshM1CameraTransport, @unchecked Sendable {
    static let remoteCommand = "/usr/bin/python3 ~/AIYStation/mesh_monitor_m1_camera_station.py --bridge"
    static func arguments(configuration: MeshM1CameraConfiguration) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
         "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2", "-o", "ExitOnForwardFailure=yes",
         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
         "-L", "127.0.0.1:\(configuration.localPort):127.0.0.1:\(configuration.remotePort)",
         "mesh-m1", remoteCommand]
    }

    private let executable: URL
    private let arguments: [String]
    private let eofGrace: TimeInterval
    private let terminateGrace: TimeInterval
    private let afterTestSpawn: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "mesh.m1.camera.ssh")
    private let cancellation = NSLock()
    private var closeRequested = false
    // Remaining mutable state belongs to queue. Callbacks run synchronously on
    // that queue; the transport never creates a callback Task or pending array.
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: DispatchSourceRead?
    private var pending = Data()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onEnd: (@Sendable () -> Void)?
    private var started = false
    private var closing = false
    private var ended = false
    private var rateStarted = ProcessInfo.processInfo.systemUptime
    private var rateLines = 0

    init(configuration: MeshM1CameraConfiguration) {
        executable = URL(fileURLWithPath: "/usr/bin/ssh")
        arguments = Self.arguments(configuration: configuration)
        eofGrace = 0.15; terminateGrace = 1; afterTestSpawn = nil
    }

    /// Local fake-child fixture seam. Production calls the configuration initializer.
    init(testExecutable: URL, arguments: [String], eofGrace: TimeInterval = 0.02, terminateGrace: TimeInterval = 0.05,
         afterSpawn: (@Sendable () -> Void)? = nil) {
        executable = testExecutable; self.arguments = arguments
        self.eofGrace = eofGrace; self.terminateGrace = terminateGrace; afterTestSpawn = afterSpawn
    }

    private var isCancelled: Bool { cancellation.lock(); defer { cancellation.unlock() }; return closeRequested }
    @discardableResult private func requestClose() -> Bool {
        cancellation.lock(); defer { cancellation.unlock() }
        let first = !closeRequested; closeRequested = true; return first
    }

    func start(onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        try queue.sync {
            guard !started else { throw MeshM1CameraTransportError.closed }
            started = true; self.onLine = onLine; self.onEnd = onEnd
            guard !isCancelled else { finishWithoutChild(); throw MeshM1CameraTransportError.closed }
            let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
            let writer = stdinPipe.fileHandleForWriting, readHandle = stdoutPipe.fileHandleForReading
            guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
                  fcntl(writer.fileDescriptor, F_SETFL, fcntl(writer.fileDescriptor, F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(readHandle.fileDescriptor, F_SETFL, fcntl(readHandle.fileDescriptor, F_GETFL) | O_NONBLOCK) == 0 else {
                try? writer.close(); try? readHandle.close()
                try? stdinPipe.fileHandleForReading.close(); try? stdoutPipe.fileHandleForWriting.close()
                finishWithoutChild()
                throw MeshM1CameraTransportError.startup
            }
            child.executableURL = executable; child.arguments = arguments
            child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] child in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, self.process === child else { return }
                    // A final stopped receipt may precede process exit in the pipe.
                    if !self.closing { self.readAvailable() }
                    self.finish(child)
                }
            }
            process = child; input = writer; output = readHandle
            do { try child.run() }
            catch {
                process = nil
                try? stdinPipe.fileHandleForReading.close(); try? stdoutPipe.fileHandleForWriting.close()
                finishWithoutChild()
                throw MeshM1CameraTransportError.startup
            }
            afterTestSpawn?()
            try? stdinPipe.fileHandleForReading.close(); try? stdoutPipe.fileHandleForWriting.close()
            // close() can arrive while Process.run() is in progress.
            if isCancelled { beginClose(); return }
            let source = DispatchSource.makeReadSource(fileDescriptor: readHandle.fileDescriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { try? readHandle.close() }
            reader = source; source.resume()
        }
    }

    /// Accept one JSON object, optionally with its final newline. Partial writes
    /// or a full pipe fail closed rather than buffering commands indefinitely.
    func send(_ line: Data) throws {
        var bytes = line
        if bytes.last == 10 { bytes.removeLast() }
        guard !bytes.isEmpty, bytes.count <= 4096, !bytes.contains(10), !bytes.contains(13),
              (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else { throw MeshM1CameraTransportError.invalidLine }
        bytes.append(10)
        try queue.sync {
            guard !isCancelled, !closing, process?.isRunning == true, let input else { throw MeshM1CameraTransportError.closed }
            var offset = 0, attempts = 0
            while offset < bytes.count && attempts < 8 {
                attempts += 1
                let count = bytes.withUnsafeBytes { raw in Darwin.write(input.fileDescriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                requestClose(); beginClose(); throw MeshM1CameraTransportError.backpressure
            }
            if offset != bytes.count { requestClose(); beginClose(); throw MeshM1CameraTransportError.backpressure }
        }
    }

    func close() {
        guard requestClose() else { return }
        queue.async { [self] in beginClose() }
    }

    private func readAvailable() {
        guard !closing, !isCancelled, let output else { return }
        var chunk = [UInt8](repeating: 0, count: 2048)
        // DispatchSource coalesces readiness; each turn and pending line stay bounded.
        for _ in 0..<8 {
            let count = Darwin.read(output.fileDescriptor, &chunk, chunk.count)
            if count == 0 { requestClose(); beginClose(); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                requestClose(); beginClose(); return
            }
            pending.append(contentsOf: chunk.prefix(count))
            guard pending.count <= 8192 else { requestClose(); beginClose(); return }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                let now = ProcessInfo.processInfo.systemUptime
                if now - rateStarted >= 1 { rateStarted = now; rateLines = 0 }
                rateLines += 1
                guard !line.isEmpty, line.count <= 4096, String(data: line, encoding: .utf8) != nil,
                      rateLines <= 32, !isCancelled else { requestClose(); beginClose(); return }
                onLine?(line)
                if isCancelled { beginClose(); return }
            }
            guard pending.count <= 4096 else { requestClose(); beginClose(); return }
        }
    }

    private func beginClose() {
        guard !closing else { return }
        closing = true; pending.removeAll(); onLine = nil
        try? input?.close(); input = nil
        if let reader { reader.cancel(); self.reader = nil; output = nil }
        else { try? output?.close(); output = nil }
        guard let child = process else { return }
        guard child.isRunning else { finish(child); return }
        queue.asyncAfter(deadline: .now() + eofGrace) { [weak self, weak child] in
            guard let self, let child, self.process === child, child.isRunning else { return }
            child.terminate()
            self.queue.asyncAfter(deadline: .now() + self.terminateGrace) { [weak self, weak child] in
                guard let self, let child, self.process === child, child.isRunning else { return }
                // Process is still retained and running; never kill a persisted PID.
                _ = Darwin.kill(child.processIdentifier, SIGKILL)
            }
        }
    }

    private func finish(_ child: Process) {
        guard process === child, !child.isRunning, !ended else { return }
        ended = true; requestClose(); beginClose()
        process = nil; let callback = onEnd; onEnd = nil
        callback?()
    }

    /// A failed launch still releases the runtime's retained transport through
    /// the same terminal callback. This never asserts a spawned child has exited.
    private func finishWithoutChild() {
        guard process == nil, !ended else { return }
        ended = true; requestClose(); beginClose()
        let callback = onEnd; onEnd = nil; callback?()
    }

    deinit {
        reader?.cancel(); try? input?.close()
        if reader == nil { try? output?.close() }
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminateGrace) {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}

enum MeshM1CameraHealth {
    static func verify(_ connection: MeshManagedCameraConnection) async throws {
        try await verify(connection, testConfiguration: nil, deadline: 6)
    }

    /// A custom URLProtocol fixture can intercept every request without a socket.
    static func verify(_ connection: MeshManagedCameraConnection, testConfiguration: URLSessionConfiguration?, deadline: TimeInterval) async throws {
        let probe = MeshM1CameraHealthProbe(connection: connection,
            configuration: testConfiguration ?? MeshManagedCameraConnection.sessionConfiguration(), deadline: deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in probe.start(continuation) }
        } onCancel: { probe.cancel() }
    }
}

private final class MeshM1CameraHealthProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: MeshManagedCameraConnection
    private let configuration: URLSessionConfiguration
    private let deadline: TimeInterval
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchSourceTimer?
    // URLSession invokes these on a single operation queue.
    private var bytes = Data()
    private var response: HTTPURLResponse?

    init(connection: MeshManagedCameraConnection, configuration: URLSessionConfiguration, deadline: TimeInterval) {
        self.connection = connection; self.configuration = configuration; self.deadline = deadline
    }
    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.dataTask(with: connection.healthRequest())
        self.session = session; self.task = task
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0.01, min(6, deadline)))
        timer.setEventHandler { [weak self] in self?.finish(MeshM1CameraTransportError.invalidHealth) }
        self.timer = timer; timer.resume(); task.resume()
        lock.unlock()
    }
    func cancel() { finish(CancellationError()) }
    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = continuation, session = self.session, task = self.task, timer = self.timer
        continuation = nil; self.session = nil; self.task = nil; self.timer = nil
        lock.unlock()
        timer?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        if let error { callback?.resume(throwing: error) } else { callback?.resume() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil); finish(MeshM1CameraTransportError.invalidHealth)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil); finish(MeshM1CameraTransportError.invalidHealth)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil); finish(MeshM1CameraTransportError.invalidHealth)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == connection.healthURL,
              http.statusCode == 200, http.mimeType == "application/json", http.expectedContentLength <= 4096 else {
            completionHandler(.cancel); finish(MeshM1CameraTransportError.invalidHealth); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 4096 else { finish(MeshM1CameraTransportError.invalidHealth); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error == nil, let response else { finish(MeshM1CameraTransportError.invalidHealth); return }
        do {
            let health = try connection.verifyHealth(response: response, data: bytes)
            guard health.ready && !health.captureActive && !health.fresh else { throw MeshM1CameraTransportError.invalidHealth }
            finish(nil)
        } catch { finish(MeshM1CameraTransportError.invalidHealth) }
    }
}

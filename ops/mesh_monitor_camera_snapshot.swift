// Optional M1 camera helper. Standalone --arm is attended/manual; --managed is inert
// until its exclusive parent pipe supplies prepare and authenticated start commands.
import AppKit
@preconcurrency import AVFoundation
import CoreImage
import Darwin
import Foundation
import Network

struct MeshSnapshotIdentity: Codable, Equatable, Sendable {
    let sessionID: String
    let generation: String
    let stationEpoch: String
    let cameraID: String

    var valid: Bool {
        UUID(uuidString: sessionID) != nil && UUID(uuidString: generation) != nil
            && Self.safe(stationEpoch, maximum: 128) && Self.safe(cameraID, maximum: 512)
    }
    private static func safe(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

struct MeshSnapshotConfiguration: Equatable, Sendable {
    let identity: MeshSnapshotIdentity?
    let deviceID: String
    let port: UInt16
    let controlToken: String?
    let snapshotToken: String?
}

enum MeshSnapshotFailure: String, Error {
    case invalidCommand, unauthorized, wrongSession, invalidState, staleRenewal
    case listenerFailed, cameraPermission, cameraMissing, configuration, captureFailed
    case parentEOF, parentReadFailed, leaseExpired, startupExpired, parentStop, signal, outputUnavailable
    case shutdownUnconfirmed, invalidParentPipe
}

struct MeshSnapshotCommand: Decodable {
    let schemaVersion: Int
    let command: String
    let sessionID: String
    let generation: String
    let stationEpoch: String
    let cameraID: String
    let controlToken: String
    let snapshotToken: String?
    let port: UInt16?
    let sequence: UInt64?

    var identity: MeshSnapshotIdentity {
        MeshSnapshotIdentity(sessionID: sessionID, generation: generation, stationEpoch: stationEpoch, cameraID: cameraID)
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4_096,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MeshSnapshotFailure.invalidCommand }
        let base: Set<String> = ["schemaVersion", "command", "sessionID", "generation", "stationEpoch", "cameraID", "controlToken"]
        let value = try JSONDecoder().decode(Self.self, from: data)
        let extra: Set<String>
        switch value.command {
        case "prepare": extra = ["snapshotToken", "port"]
        case "renew": extra = ["sequence"]
        case "start", "stop", "status": extra = []
        default: throw MeshSnapshotFailure.invalidCommand
        }
        guard Set(object.keys) == base.union(extra), value.schemaVersion == 1, value.identity.valid,
              validToken(value.controlToken) else { throw MeshSnapshotFailure.invalidCommand }
        if value.command == "prepare" {
            guard let token = value.snapshotToken, validToken(token), token != value.controlToken,
                  let port = value.port, port >= 1_024 else { throw MeshSnapshotFailure.invalidCommand }
        }
        if value.command == "renew", value.sequence == nil { throw MeshSnapshotFailure.invalidCommand }
        return value
    }
    static func validToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

func meshSnapshotConstantEqual(_ a: String, _ b: String) -> Bool {
    let left = Array(a.utf8), right = Array(b.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
}

struct MeshSnapshotReceipt: Encodable, Sendable {
    let schemaVersion = 1
    let event: String
    let reason: String
    let state: String
    let identity: MeshSnapshotIdentity?
    let captureActive: Bool
    let frameObserved: Bool
    let capturedAt: String?
}

/// Production and fixtures use this same coordinator; test backends never initialize
/// AVFoundation or Network. Backend completion means teardown, not just a stop request.
protocol MeshSnapshotBackend: AnyObject, Sendable {
    func prepare(_ configuration: MeshSnapshotConfiguration, completion: @escaping @Sendable (Result<Void, MeshSnapshotFailure>) -> Void)
    func start(completion: @escaping @Sendable (Result<Void, MeshSnapshotFailure>) -> Void)
    func stop(completion: @escaping @Sendable () -> Void)
}

final class MeshSnapshotManagedController: @unchecked Sendable {
    enum State: String { case idle, preparing, prepared, starting, capturing, stopping, stopped }
    static let leaseNanoseconds: UInt64 = 6_000_000_000
    static let stopNanoseconds: UInt64 = 2_000_000_000
    private let lock = NSRecursiveLock()
    private let now: @Sendable () -> UInt64
    private let makeBackend: @Sendable () -> any MeshSnapshotBackend
    private let emit: @Sendable (MeshSnapshotReceipt) -> Bool
    private let exit: @Sendable (Int32) -> Void
    private var state: State = .idle
    private var configuration: MeshSnapshotConfiguration?
    private var backend: (any MeshSnapshotBackend)?
    private var deadline: UInt64
    private var renewal: UInt64 = 0
    private var captureRequested = false
    private var frameObserved = false
    private var capturedAt: String?
    private var stopReason: MeshSnapshotFailure = .parentStop
    private var finished = false

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         makeBackend: @escaping @Sendable () -> any MeshSnapshotBackend,
         emit: @escaping @Sendable (MeshSnapshotReceipt) -> Bool,
         exit: @escaping @Sendable (Int32) -> Void) {
        self.now = now; self.makeBackend = makeBackend; self.emit = emit; self.exit = exit
        deadline = now() &+ 10_000_000_000
    }

    func receive(_ line: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, state != .stopping else { return }
        guard !expired() else { return }
        let command: MeshSnapshotCommand
        do { command = try .decode(line) }
        catch { stopLocked(.invalidCommand); return }
        if state == .idle {
            guard command.command == "prepare", let port = command.port else { report("error", .invalidState); return }
            let config = MeshSnapshotConfiguration(identity: command.identity, deviceID: command.cameraID,
                port: port, controlToken: command.controlToken, snapshotToken: command.snapshotToken)
            configuration = config; state = .preparing; deadline = now() &+ Self.leaseNanoseconds
            let worker = makeBackend(); backend = worker
            report("accepted", nil)
            guard state == .preparing else { return }
            worker.prepare(config) { [weak self] result in self?.prepared(result) }
            return
        }
        guard let config = configuration, command.identity == config.identity else { report("error", .wrongSession); return }
        guard let token = config.controlToken, meshSnapshotConstantEqual(command.controlToken, token) else { report("error", .unauthorized); return }
        switch command.command {
        case "prepare":
            guard command.port == config.port, command.snapshotToken == config.snapshotToken else { report("error", .invalidState); return }
            report("state", nil) // Duplicate prepare never renews or creates a second backend.
        case "start":
            if state == .starting || state == .capturing { report("state", nil); return }
            guard state == .prepared else { report("error", .invalidState); return }
            state = .starting; captureRequested = true
            backend?.start { [weak self] result in self?.started(result) }
        case "renew":
            guard let sequence = command.sequence, sequence > renewal else { report("error", .staleRenewal); return }
            renewal = sequence; deadline = now() &+ Self.leaseNanoseconds; report("state", nil)
        case "status": report("state", nil)
        case "stop": stopLocked(.parentStop)
        default: stopLocked(.invalidCommand)
        }
    }

    func firstFrame(at time: Date) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, state == .capturing, !expired(), !frameObserved else { return }
        frameObserved = true; capturedAt = time.ISO8601Format(); report("firstFrame", nil)
    }
    func fail(_ reason: MeshSnapshotFailure) {
        lock.lock(); defer { lock.unlock() }; stopLocked(reason)
    }
    func tick() {
        lock.lock(); defer { lock.unlock() }; _ = expired()
    }
    private func prepared(_ result: Result<Void, MeshSnapshotFailure>) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, state == .preparing, !expired() else { return }
        switch result {
        case .success: state = .prepared; report("listenerReady", nil)
        case let .failure(error): stopLocked(error)
        }
    }
    private func started(_ result: Result<Void, MeshSnapshotFailure>) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, state == .starting, !expired() else { return }
        switch result {
        case .success: state = .capturing; report("helperStarted", nil)
        case let .failure(error): stopLocked(error)
        }
    }
    @discardableResult private func expired() -> Bool {
        guard !finished, now() >= deadline else { return finished }
        if state == .stopping {
            finished = true
            _ = emit(receipt("error", .shutdownUnconfirmed)); exit(3)
        } else { stopLocked(state == .idle ? .startupExpired : .leaseExpired) }
        return true
    }
    private func stopLocked(_ reason: MeshSnapshotFailure) {
        guard !finished, state != .stopping else { return }
        state = .stopping; stopReason = reason; deadline = now() &+ Self.stopNanoseconds
        frameObserved = false; capturedAt = nil
        _ = emit(receipt("stopping", reason))
        guard let backend else { stopped(); return }
        backend.stop { [weak self] in self?.stopped() }
    }
    private func stopped() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, state == .stopping else { return }
        state = .stopped; finished = true; backend = nil
        let wrote = emit(receipt("stopped", stopReason))
        let normal: Set<MeshSnapshotFailure> = [.parentStop, .parentEOF, .signal]
        exit(wrote && normal.contains(stopReason) ? 0 : 2)
    }
    private func receipt(_ event: String, _ reason: MeshSnapshotFailure?) -> MeshSnapshotReceipt {
        MeshSnapshotReceipt(event: event, reason: reason?.rawValue ?? "ok", state: state.rawValue,
            identity: configuration?.identity, captureActive: captureRequested && state != .stopped,
            frameObserved: frameObserved, capturedAt: capturedAt)
    }
    private func report(_ event: String, _ reason: MeshSnapshotFailure?) {
        if !emit(receipt(event, reason)) { stopLocked(.outputUnavailable) }
    }
}

/// HTTP parsing/authentication is shared with the real listener and exercised with bytes only.
enum MeshSnapshotHTTPRoute: Equatable { case health, snapshot, reject(Int) }
func meshSnapshotHTTPRoute(_ data: Data, token: String?) -> MeshSnapshotHTTPRoute {
    guard data.count <= 4_096, let text = String(data: data, encoding: .ascii),
          let end = text.range(of: "\r\n\r\n"), end.upperBound == text.endIndex else { return .reject(400) }
    let lines = text[..<end.lowerBound].components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ").map(String.init)
    guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]) else { return .reject(400) }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
        let key = line[..<colon].lowercased()
        guard !key.isEmpty, headers[key] == nil else { return .reject(400) }
        headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    if let token {
        guard let authorization = headers["authorization"], meshSnapshotConstantEqual(authorization, "Bearer " + token) else { return .reject(401) }
    }
    guard parts[0] == "GET" else { return .reject(405) }
    guard headers["transfer-encoding"] == nil, headers["content-length"].map({ $0 == "0" }) ?? true else { return .reject(400) }
    if parts[1] == "/health" { return .health }
    if parts[1] == "/snapshot.jpg" { return .snapshot }
    return .reject(404)
}

private final class SnapshotHelper: NSObject, MeshSnapshotBackend, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "mesh.monitor.m1-snapshot")
    private let cancellation = NSLock()
    private var revoked = false
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var runtimeObserver: NSObjectProtocol?
    private var context: CIContext?
    private var listener: NWListener?
    private var configuration: MeshSnapshotConfiguration?
    private var jpeg: Data?
    private var capturedAt: Date?
    private var lastFrameAt = Date.distantPast
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var ready = false
    private var closed = false
    private var captureActive = false
    private var stopCompletion: (@Sendable () -> Void)?
    private let onFailure: @Sendable (MeshSnapshotFailure) -> Void
    private let onFrame: @Sendable (Date) -> Void

    init(onFailure: @escaping @Sendable (MeshSnapshotFailure) -> Void,
         onFrame: @escaping @Sendable (Date) -> Void = { _ in }) {
        self.onFailure = onFailure; self.onFrame = onFrame; super.init()
    }
    private var isRevoked: Bool {
        cancellation.lock(); defer { cancellation.unlock() }; return revoked
    }
    func prepare(_ configuration: MeshSnapshotConfiguration, completion: @escaping @Sendable (Result<Void, MeshSnapshotFailure>) -> Void) {
        queue.async { [self] in
            guard !isRevoked, !closed, listener == nil else { completion(.failure(.invalidState)); return }
            self.configuration = configuration
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: configuration.port)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard !self.isRevoked, !self.closed else { return }
                        self.ready = true; completion(.success(()))
                    case .failed:
                        if !self.closed { self.onFailure(.listenerFailed) }
                    case .cancelled:
                        self.listener = nil; self.completeStop()
                    default: break
                    }
                }
                self.listener = listener; listener.start(queue: queue)
            } catch { completion(.failure(.listenerFailed)) }
        }
    }
    func start(completion: @escaping @Sendable (Result<Void, MeshSnapshotFailure>) -> Void) {
        queue.async { [self] in
            guard !isRevoked, !closed, ready, !captureActive, let configuration else { completion(.failure(.invalidState)); return }
            // The first AVFoundation call in managed mode happens here, never on init/prepare.
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { completion(.failure(.cameraPermission)); return }
            guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video,
                position: .unspecified).devices.first(where: { $0.uniqueID == configuration.deviceID }) else {
                completion(.failure(.cameraMissing)); return
            }
            do {
                guard !isRevoked else { completion(.failure(.invalidState)); return }
                let input = try AVCaptureDeviceInput(device: device)
                let session = AVCaptureSession(), output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration(); completion(.failure(.configuration)); return
                }
                session.addInput(input); session.addOutput(output)
                if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                output.setSampleBufferDelegate(self, queue: queue); session.commitConfiguration()
                self.session = session; self.output = output
                runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
                    guard let self, !self.isRevoked else { return }; self.onFailure(.captureFailed)
                }
                context = CIContext(options: [.cacheIntermediates: false])
                guard !isRevoked else { completion(.failure(.invalidState)); return }
                session.startRunning()
                guard session.isRunning else { completion(.failure(.captureFailed)); return }
                captureActive = true; completion(.success(()))
            } catch { completion(.failure(.configuration)) }
        }
    }
    func stop(completion: @escaping @Sendable () -> Void) {
        cancellation.lock(); revoked = true; cancellation.unlock()
        queue.async { [self] in
            guard !closed else { if stopCompletion == nil { completion() }; return }
            closed = true; ready = false; captureActive = false; stopCompletion = completion
            output?.setSampleBufferDelegate(nil, queue: nil)
            if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
            runtimeObserver = nil
            session?.stopRunning(); session = nil; output = nil; context = nil
            jpeg = nil; capturedAt = nil
            for connection in connections.values { connection.stateUpdateHandler = nil; connection.cancel() }
            connections.removeAll()
            if let listener { listener.cancel() } else { completeStop() }
        }
    }
    private func completeStop() {
        guard closed, let completion = stopCompletion else { return }
        stopCompletion = nil; configuration = nil; completion()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard !isRevoked, !closed, captureActive, now.timeIntervalSince(lastFrameAt) >= 0.5,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let context, let session else { return }
        lastFrameAt = now
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.75]),
              data.count <= 4 * 1_024 * 1_024, let clock = session.synchronizationClock else { return }
        let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(clock), CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        guard age.isFinite, (-0.5...3).contains(age) else { return }
        jpeg = data; capturedAt = now.addingTimeInterval(-age)
        onFrame(capturedAt!)
    }
    private func receive(_ connection: NWConnection) {
        guard !isRevoked, !closed, ready, connections.count < 4 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .cancelled, .failed: self?.connections.removeValue(forKey: id); default: break }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak connection] in connection?.cancel() }
        receiveHeaders(connection, data: Data())
    }
    private func receiveHeaders(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_097 - data.count) { [weak self] chunk, _, complete, error in
            guard let self, !self.isRevoked, !self.closed, error == nil else { connection.cancel(); return }
            var bytes = data; if let chunk { bytes.append(chunk) }
            guard bytes.count <= 4_096 else { connection.cancel(); return }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.receiveHeaders(connection, data: bytes) }; return
            }
            let fresh = self.captureActive && (self.capturedAt.map { (-0.5...3).contains(Date().timeIntervalSince($0)) } ?? false)
            switch meshSnapshotHTTPRoute(bytes, token: self.configuration?.snapshotToken) {
            case .health:
                let body = Data("{\"ready\":\(self.ready),\"captureActive\":\(self.captureActive),\"fresh\":\(fresh)}".utf8)
                self.respond(connection, status: self.configuration?.identity != nil || fresh ? 200 : 503,
                             type: "application/json", body: body, identity: true)
            case .snapshot:
                if fresh, let jpeg = self.jpeg {
                    self.respond(connection, status: 200, type: "image/jpeg", body: jpeg, identity: true, capturedAt: self.capturedAt)
                } else { self.respond(connection, status: 503, type: "text/plain", body: Data(), identity: true) }
            case let .reject(code): self.respond(connection, status: code, type: "text/plain", body: Data(), identity: false)
            }
        }
    }
    private func respond(_ connection: NWConnection, status: Int, type: String, body: Data, identity: Bool, capturedAt: Date? = nil) {
        let descriptions = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"]
        var headers = "HTTP/1.1 \(status) \(descriptions[status] ?? "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if identity, let id = configuration?.identity {
            headers += "X-Mesh-Camera-Session: \(id.sessionID)\r\nX-Mesh-Camera-Generation: \(id.generation)\r\nX-Mesh-Camera-ID: \(id.cameraID)\r\nX-Mesh-Station-Epoch: \(id.stationEpoch)\r\n"
        }
        if let capturedAt {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            headers += "X-Mesh-Captured-At: \(formatter.string(from: capturedAt))\r\n"
        }
        connection.send(content: Data((headers + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Bounded line framing shared with inert-process and pure fixtures.
struct MeshSnapshotLineBuffer {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in data {
            if byte == 10 {
                guard !buffer.isEmpty else { throw MeshSnapshotFailure.invalidCommand }
                lines.append(buffer); buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < 4_096 else { throw MeshSnapshotFailure.invalidCommand }
                buffer.append(byte)
            }
        }
        return lines
    }
}

private final class MeshSnapshotManagedProcess: @unchecked Sendable {
    private var controller: MeshSnapshotManagedController!
    private var input: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var lines = MeshSnapshotLineBuffer()
    private let queue = DispatchQueue(label: "mesh.monitor.m1-camera-parent")

    func run() {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK) == 0,
              fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK) == 0,
              fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { Darwin.exit(2) }
        controller = MeshSnapshotManagedController(makeBackend: { [weak self] in
            SnapshotHelper(onFailure: { [weak self] reason in self?.controller.fail(reason) },
                onFrame: { [weak self] time in self?.controller.firstFrame(at: time) })
        }, emit: { receipt in
            guard var data = try? JSONEncoder().encode(receipt) else { return false }
            data.append(10)
            guard data.count <= 4_096 else { return false }
            return data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress!, $0.count) == $0.count }
        }, exit: { Darwin.exit($0) })
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        input.setEventHandler { [weak self] in self?.read() }; self.input = input; input.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.controller.tick() }; self.timer = timer; timer.resume()
        for number in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.controller.fail(.signal) }; source.resume(); signals.append(source)
        }
        withExtendedLifetime(self) { dispatchMain() }
    }
    private func read() {
        // Bounded work per event keeps the independent lease/stop timer responsive.
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count == 0 { input?.cancel(); input = nil; controller.fail(.parentEOF); return }
        if count < 0 {
            if errno != EAGAIN && errno != EINTR { controller.fail(.parentReadFailed) }
            return
        }
        do { for line in try lines.append(Data(bytes.prefix(count))) { controller.receive(line) } }
        catch { controller.fail(.invalidCommand) }
    }
}

/// Dispatch is decided before constructing any UI, camera, listener, or parent bridge.
/// Keeping it pure lets fixtures prove that mixed modes cannot reach a sensor path.
enum MeshSnapshotLaunchMode: Equatable {
    case usage, setup, managed, listDevices, arm(deviceID: String, port: UInt16), invalid

    static func parse(_ arguments: [String], packagedApp: Bool) -> Self {
        if arguments.isEmpty { return packagedApp ? .setup : .usage }
        if arguments == ["--setup"] { return .setup }
        if arguments == ["--managed"] { return .managed }
        if arguments == ["--list-devices"] { return .listDevices }
        if arguments == ["--help"] { return .usage }
        // Standalone capture keeps its explicit arm/device/port contract. Reject
        // duplicate flags, missing values and all unknown or mixed-mode arguments.
        guard arguments.count == 5, arguments.filter({ $0 == "--arm" }).count == 1,
              arguments.filter({ $0 == "--device-id" }).count == 1,
              arguments.filter({ $0 == "--port" }).count == 1 else { return .invalid }
        var deviceID: String?, port: UInt16?, index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--arm": index += 1
            case "--device-id":
                guard index + 1 < arguments.count else { return .invalid }
                let value = arguments[index + 1]
                guard !value.isEmpty, value.utf8.count <= 512, !value.hasPrefix("--") else { return .invalid }
                deviceID = value; index += 2
            case "--port":
                guard index + 1 < arguments.count, let value = UInt16(arguments[index + 1]), value >= 1_024 else { return .invalid }
                port = value; index += 2
            default: return .invalid
            }
        }
        guard let deviceID, let port else { return .invalid }
        return .arm(deviceID: deviceID, port: port)
    }
}

enum MeshCameraPermissionStatus: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted, unknown

    var title: String {
        switch self {
        case .notDetermined: return "Camera permission has not been requested"
        case .authorized: return "Camera permission is granted"
        case .denied: return "Camera permission is denied"
        case .restricted: return "Camera permission is restricted"
        case .unknown: return "Camera permission status is unavailable"
        }
    }
    var detail: String {
        switch self {
        case .notDetermined: return "Choose Allow camera to open the macOS permission dialog. This window does not turn on the camera."
        case .authorized: return "Permission is available to this app. Capture still needs an explicit Start from Mesh Monitor on your M4."
        case .denied: return "You can change Camera access in System Settings, then return here and refresh the status."
        case .restricted: return "A system restriction prevents camera access. This app cannot change that restriction."
        case .unknown: return "macOS returned an unrecognized permission status. Capture remains unavailable."
        }
    }
}

/// Only requestFromUserAction can invoke the injected permission request. This
/// controller has no capture, device discovery, network, audio, or Station API.
@MainActor final class MeshCameraPermissionSetup {
    typealias Completion = @Sendable (Bool) -> Void
    private let readStatus: @MainActor () -> MeshCameraPermissionStatus
    private let requestAccess: @MainActor (@escaping Completion) -> Void
    private var requestID: UUID?
    private(set) var status: MeshCameraPermissionStatus
    private(set) var isRequesting = false
    private(set) var isClosed = false
    private(set) var resultUnresolved = false
    var onChange: (@MainActor () -> Void)?

    init(readStatus: @escaping @MainActor () -> MeshCameraPermissionStatus,
         requestAccess: @escaping @MainActor (@escaping Completion) -> Void) {
        self.readStatus = readStatus; self.requestAccess = requestAccess
        status = readStatus()
    }

    func refresh() {
        guard !isClosed else { return }
        status = readStatus()
        if status != .notDetermined { resultUnresolved = false }
        onChange?()
    }

    func requestFromUserAction() {
        guard !isClosed, !isRequesting else { return }
        // Re-read at click time: a Settings change must not produce another prompt.
        refresh()
        guard !isClosed, !isRequesting, status == .notDetermined else { return }
        let id = UUID(); requestID = id; isRequesting = true; resultUnresolved = false
        onChange?()
        guard !isClosed, requestID == id else { return }
        requestAccess { [weak self] _ in
            // The callback Boolean is not a durable authorization state. Query
            // macOS again on the main actor, and ignore closed/stale completions.
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, self.requestID == id else { return }
                self.requestID = nil; self.isRequesting = false
                self.status = self.readStatus()
                self.resultUnresolved = self.status == .notDetermined
                self.onChange?()
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true; requestID = nil; isRequesting = false; onChange = nil
        // macOS owns an already requested permission dialog; closing this window
        // cannot cancel it. Its eventual callback must not reopen or update UI.
    }
}

@MainActor private final class MeshCameraSetupApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "Allow camera…", target: nil, action: nil)
    private lazy var permission = MeshCameraPermissionSetup(readStatus: {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }, requestAccess: { completion in AVCaptureDevice.requestAccess(for: .video, completionHandler: completion) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mesh Monitor · Camera setup"; window.delegate = self
        window.isReleasedWhenClosed = false; self.window = window
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(wrappingLabelWithString: "Set up your M1 camera")
        title.font = .systemFont(ofSize: 27, weight: .semibold)
        let purpose = NSTextField(wrappingLabelWithString: "Give Mesh Monitor permission here. Start and stop the camera from Inputs on your M4.")
        purpose.font = .systemFont(ofSize: 14); purpose.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 14)
        let boundary = NSTextField(wrappingLabelWithString: "This setup window does not capture. It does not select a device, open a stream, or connect to your M4.")
        boundary.font = .systemFont(ofSize: 13); boundary.textColor = .secondaryLabelColor
        primary.target = self; primary.action = #selector(primaryAction); primary.bezelStyle = .rounded
        primary.controlSize = .large
        let refresh = NSButton(title: "Refresh status", target: self, action: #selector(refreshAction)); refresh.bezelStyle = .rounded
        let close = NSButton(title: "Close", target: self, action: #selector(closeAction)); close.bezelStyle = .rounded
        let buttons = NSStackView(views: [primary, refresh, close]); buttons.orientation = .horizontal; buttons.spacing = 10
        let note = NSTextField(wrappingLabelWithString: "Closing this window does not cancel a macOS permission dialog already requested. Station access still needs an attended check on this Mac.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        for view in [title, purpose, statusLabel, detailLabel, boundary, buttons, note] { stack.addArrangedSubview(view) }
        // A vertical stack's leading alignment alone does not constrain wrapping
        // label width. Pin each paragraph to the available content width.
        for label in [title, purpose, statusLabel, detailLabel, boundary, note] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        permission.onChange = { [weak self] in self?.render() }; render()
        window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }; permission.refresh()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { permission.close() }
    func windowWillClose(_ notification: Notification) { permission.close() }

    private func render() {
        statusLabel.stringValue = permission.isRequesting ? "Waiting for your macOS permission choice…" : permission.status.title
        if permission.isRequesting {
            detailLabel.stringValue = "Respond to the macOS dialog. Camera capture will remain off."
        } else if permission.resultUnresolved {
            detailLabel.stringValue = "macOS has not reported a permission choice. Refresh the status or try Allow camera again."
        } else { detailLabel.stringValue = permission.status.detail }
        switch permission.status {
        case .notDetermined: primary.title = "Allow camera…"; primary.isEnabled = !permission.isRequesting
        case .denied: primary.title = "Open Camera Settings"; primary.isEnabled = !permission.isRequesting
        case .authorized: primary.title = "Permission granted"; primary.isEnabled = false
        case .restricted: primary.title = "Restricted by system"; primary.isEnabled = false
        case .unknown: primary.title = "Status unavailable"; primary.isEnabled = false
        }
    }
    @objc private func primaryAction() {
        guard !permission.isRequesting, !permission.isClosed else { return }
        permission.refresh()
        switch permission.status {
        case .notDetermined: permission.requestFromUserAction()
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
        default: break
        }
    }
    @objc private func refreshAction() { permission.refresh() }
    @objc private func closeAction() { window?.close() }

    static func run() {
        let app = NSApplication.shared; let delegate = MeshCameraSetupApplication()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

#if !MESH_SNAPSHOT_TEST
@main private struct SnapshotHelperMain {
    @MainActor static func main() {
        let mode = MeshSnapshotLaunchMode.parse(Array(CommandLine.arguments.dropFirst()),
            packagedApp: Bundle.main.bundleURL.pathExtension == "app")
        switch mode {
        case .setup: MeshCameraSetupApplication.run(); return
        case .managed:
            let process = MeshSnapshotManagedProcess()
            withExtendedLifetime(process) { process.run() }; return
        case .invalid: Darwin.exit(2)
        case .usage:
            print("Usage: mesh-monitor-camera --setup\n       mesh-monitor-camera --list-devices\n       mesh-monitor-camera --device-id EXACT_EXTERNAL_ID --port PORT --arm\n       mesh-monitor-camera --managed\nSetup never captures; permission is requested only from its Allow camera button. No default camera or auto-start.")
            return
        case .listDevices:
            for device in AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices {
                print("\(device.uniqueID)\t\(device.localizedName)")
            }
            return
        case let .arm(deviceID, port):
            let helper = SnapshotHelper(onFailure: { _ in Darwin.exit(3) })
            helper.prepare(MeshSnapshotConfiguration(identity: nil, deviceID: deviceID, port: port, controlToken: nil, snapshotToken: nil)) { result in
                guard case .success = result else { Darwin.exit(2) }
                helper.start { result in
                    guard case .success = result else { Darwin.exit(2) }
                    print("Explicitly armed external camera. Serving memory-only frames on M1 loopback; use an authenticated SSH tunnel. Ctrl-C stops.")
                }
            }
            dispatchMain()
        }
    }
}
#endif

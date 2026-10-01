import Combine
import CoreFoundation
import Foundation

struct MeshM1CameraConfiguration: Equatable, Sendable {
    let cameraID: String
    let localPort: Int
    let remotePort: Int

    init(cameraID: String, localPort: Int, remotePort: Int) throws {
        guard (1...512).contains(cameraID.utf8.count),
              cameraID.utf8.allSatisfy({ (33...126).contains($0) }),
              (1024...65535).contains(localPort), (1024...65535).contains(remotePort) else {
            throw MeshM1CameraError.invalidConfiguration
        }
        self.cameraID = cameraID; self.localPort = localPort; self.remotePort = remotePort
    }
}

enum MeshM1CameraError: Error { case invalidConfiguration, alreadyOwned, invalidReceipt, unavailable }
enum MeshM1CameraPhase: String { case stopped, connecting, preparing, verifying, starting, awaitingFrame, running, stopping, unavailable }
enum MeshM1CameraShutdown: String { case notNeeded, pending, confirmed, unconfirmed }

/// One retained invocation owns both the forwarding connection and private control stream.
/// Implementations deliver complete bounded lines, never unbounded reads or raw stderr.
protocol MeshM1CameraTransport: AnyObject, Sendable {
    func start(onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) throws
    func send(_ line: Data) throws
    func close()
}

/// Backpressure across the transport queue/MainActor boundary. At most one delivery Task
/// and 16 complete receipts can wait; overflow becomes a single invalid-receipt failure.
private enum MeshM1CameraInput: Sendable { case line(Data), ended }
private final class MeshM1CameraInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [MeshM1CameraInput] = []
    private var scheduled = false
    private var failed = false
    private var terminal = false
    func append(_ event: MeshM1CameraInput) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return false }
        if case .ended = event { terminal = true; pending.append(event) }
        else {
            guard !failed else { return false }
            if pending.count >= 16 { pending = [.line(Data())]; failed = true }
            else { pending.append(event) }
        }
        guard !scheduled else { return false }
        scheduled = true; return true
    }
    func take() -> [MeshM1CameraInput]? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { scheduled = false; return nil }
        let result = pending; pending.removeAll(keepingCapacity: false); return result
    }
}

/// Inert until explicit Start. This is independent of the morning button/briefing arm.
@MainActor final class MeshM1CameraRuntime: ObservableObject {
    @Published private(set) var phase: MeshM1CameraPhase = .stopped
    @Published private(set) var status = "M1 room camera off"
    @Published private(set) var shutdown: MeshM1CameraShutdown = .notNeeded
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var captureMayBeActive = false
    var onSourceReady: ((MeshManagedCameraConnection) -> Void)?
    var onRevoke: (() -> Void)?
    var hasOwnedTransport: Bool { transport != nil }
    var isRunning: Bool { phase == .running }

    private let makeTransport: (MeshM1CameraConfiguration) -> any MeshM1CameraTransport
    private let verifyHealth: @Sendable (MeshManagedCameraConnection) async throws -> Void
    private let now: () -> TimeInterval
    private let automaticTicks: Bool
    private var transport: (any MeshM1CameraTransport)?
    private var timer: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var configuration: MeshM1CameraConfiguration?
    private var connection: MeshManagedCameraConnection?
    private var identity: MeshManagedCameraIdentity?
    private var runID = UUID()
    private var controlToken = ""
    private var snapshotToken = ""
    private var sequence: UInt64 = 0
    private var deadline: TimeInterval = 0
    private var nextRenewal: TimeInterval = 0
    private var closingTransport = false
    private var sourceDelivered = false

    init(makeTransport: @escaping (MeshM1CameraConfiguration) -> any MeshM1CameraTransport = { MeshM1CameraSSH(configuration: $0) },
         verifyHealth: @escaping @Sendable (MeshManagedCameraConnection) async throws -> Void = { try await MeshM1CameraHealth.verify($0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, automaticTicks: Bool = true) {
        self.makeTransport = makeTransport; self.verifyHealth = verifyHealth
        self.now = now; self.automaticTicks = automaticTicks
    }

    func start(configuration: MeshM1CameraConfiguration) throws {
        guard transport == nil else { throw MeshM1CameraError.alreadyOwned }
        runID = UUID(); let run = runID
        self.configuration = configuration; identity = nil; connection = nil
        controlToken = Self.randomToken(); snapshotToken = Self.randomToken()
        sequence = 0; closingTransport = false; sourceDelivered = false; lastFrameAt = nil; captureMayBeActive = false
        shutdown = .notNeeded; phase = .connecting; status = "Connecting to the M1 station"
        deadline = now() + 10
        let channel = makeTransport(configuration); transport = channel
        let inbox = MeshM1CameraInbox()
        let deliver: @Sendable (MeshM1CameraInput) -> Void = { [weak self] event in
            guard inbox.append(event) else { return }
            Task { @MainActor [weak self] in
                while let batch = inbox.take() {
                    for event in batch {
                        switch event {
                        case let .line(data): self?.receive(data, run: run)
                        case .ended: self?.ended(run: run)
                        }
                    }
                }
            }
        }
        do {
            try channel.start(onLine: { deliver(.line($0)) }, onEnd: { deliver(.ended) })
            // A transport may synchronously fail, but callbacks cannot revive this run after Stop.
            if automaticTicks {
                timer = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard !Task.isCancelled, let self, self.runID == run, self.transport != nil else { return }
                        self.tick()
                    }
                }
            }
        } catch {
            // Keep the exact transport until its terminal callback, including launch races.
            beginStop(message: "M1 camera connection could not start", sendStop: false)
            throw MeshM1CameraError.unavailable
        }
    }

    /// Called only after the importer has decoded a fresh, authenticated frame for this identity.
    func receivedFrame(identity: MeshManagedCameraIdentity, capturedAt: Date) {
        guard self.identity == identity, [.awaitingFrame, .running].contains(phase),
              (-0.5...3).contains(Date().timeIntervalSince(capturedAt)),
              lastFrameAt.map({ capturedAt > $0 }) != false else { return }
        lastFrameAt = capturedAt; phase = .running; status = "M1 room camera · fresh verified frame"
        deadline = now() + 5
    }

    func stop() { beginStop(message: "Stopping M1 room camera") }

    /// Repeated Pause/Quit waits for the same retained cleanup, never replaces it.
    func finishStop() async {
        let run = runID
        while runID == run, transport != nil, phase == .stopping {
            tick()
            // A stalled local process remains retained, and a later Start stays disabled.
            if closingTransport && now() >= deadline { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled { cancelPendingStop(); return }
        }
    }

    func cancelPendingStop() {
        guard transport != nil else { return }
        beginStop(message: "M1 camera shutdown could not be confirmed")
        if shutdown != .confirmed { shutdown = .unconfirmed }
        closeTransport()
    }

    /// Shared monotonic deadline logic; fixtures advance a virtual clock without sensors or sleep.
    func tick() {
        guard transport != nil else { return }
        if phase == .stopping {
            if now() >= deadline {
                if shutdown != .confirmed { shutdown = .unconfirmed; status = "M1 camera shutdown unconfirmed · connection closing" }
                closeTransport()
            }
            return
        }
        if now() >= deadline {
            beginStop(message: phase == .running ? "M1 camera frames stopped arriving" : "M1 camera startup timed out")
            return
        }
        if identity != nil, now() >= nextRenewal {
            guard sequence < UInt64.max else { beginStop(message: "M1 camera session ended"); return }
            sequence += 1; nextRenewal = now() + 2
            do { try send(command: "renew", extra: ["sequence": sequence]) }
            catch { beginStop(message: "M1 camera control connection lost") }
        }
    }

    private func receive(_ data: Data, run: UUID) {
        guard run == runID, transport != nil, !closingTransport else { return }
        do {
            guard !data.isEmpty, data.count <= 4096,
                  let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.integer(record["schemaVersion"]) == 1,
                  let event = record["event"] as? String else { throw MeshM1CameraError.invalidReceipt }
            if event == "stationHello" { try hello(record); return }
            guard let identity, let rawIdentity = record["identity"] as? [String: Any],
                  Set(rawIdentity.keys) == Set(["sessionID", "generation", "stationEpoch", "cameraID"]),
                  rawIdentity["sessionID"] as? String == identity.sessionID,
                  rawIdentity["generation"] as? String == identity.generation,
                  rawIdentity["stationEpoch"] as? String == identity.stationEpoch,
                  rawIdentity["cameraID"] as? String == identity.cameraID,
                  let reason = record["reason"] as? String, reason.utf8.count <= 64,
                  let remoteState = record["state"] as? String, remoteState.utf8.count <= 32,
                  let active = Self.boolean(record["captureActive"]),
                  Self.boolean(record["frameObserved"]) != nil else { throw MeshM1CameraError.invalidReceipt }
            switch event {
            case "accepted", "state": break
            case "listenerReady":
                guard phase == .preparing, !active, reason == "ok", let connection else { throw MeshM1CameraError.invalidReceipt }
                phase = .verifying; status = "Verifying the M1 camera connection"; deadline = now() + 6
                let check = verifyHealth
                healthTask = Task { [weak self] in
                    do {
                        try await check(connection); try Task.checkCancellation()
                        guard let self, self.runID == run, self.phase == .verifying else { return }
                        self.phase = .starting; self.status = "Starting the selected M1 camera"
                        self.captureMayBeActive = true; self.deadline = self.now() + 10
                        try self.send(command: "start")
                    } catch {
                        guard let self, self.runID == run, self.phase == .verifying || self.phase == .starting else { return }
                        self.beginStop(message: "M1 camera connection verification failed")
                    }
                }
            case "helperStarted":
                guard phase == .starting, active, reason == "ok" else { throw MeshM1CameraError.invalidReceipt }
                phase = .awaitingFrame; status = "Waiting for the first M1 camera frame"; deadline = now() + 10
            case "firstFrame":
                // This receipt is historical; only a validated image can make the preview ready.
                guard [.awaitingFrame, .running, .stopping].contains(phase) else { throw MeshM1CameraError.invalidReceipt }
                if phase == .awaitingFrame, !sourceDelivered {
                    guard active, reason == "ok", Self.boolean(record["frameObserved"]) == true,
                          let connection else { throw MeshM1CameraError.invalidReceipt }
                    // Starting HTTP polling before this point can race the helper's empty cache.
                    sourceDelivered = true; onSourceReady?(connection)
                }
            case "stopping": beginStop(message: "M1 station is stopping the camera")
            case "stopped":
                guard remoteState == "stopped", !active else { throw MeshM1CameraError.invalidReceipt }
                if phase != .stopping { beginStop(message: "M1 station stopped the camera", sendStop: false) }
                captureMayBeActive = false; shutdown = .confirmed
                status = "M1 camera stopped · station acknowledged"; closeTransport()
            case "childExited":
                beginStop(message: "M1 camera helper exited; teardown acknowledgement unavailable", sendStop: false)
                if shutdown != .confirmed { shutdown = .unconfirmed }
                closeTransport()
            case "error": beginStop(message: Self.failureDescription(reason))
            default: throw MeshM1CameraError.invalidReceipt
            }
        } catch { beginStop(message: "M1 camera returned an invalid session receipt") }
    }

    private func hello(_ record: [String: Any]) throws {
        guard phase == .connecting, identity == nil, let configuration,
              Set(record.keys) == Set(["schemaVersion", "event", "stationEpoch", "mode", "eligible", "cameraID", "port", "reason"]),
              Self.boolean(record["eligible"]) != nil,
              let reason = record["reason"] as? String else { throw MeshM1CameraError.invalidReceipt }
        guard Self.boolean(record["eligible"]) == true, record["mode"] as? String == "desktop", reason == "ready" else {
            beginStop(message: Self.failureDescription(reason), sendStop: false)
            return
        }
        guard
              record["cameraID"] as? String == configuration.cameraID,
              Self.integer(record["port"]) == configuration.remotePort,
              let epoch = record["stationEpoch"] as? String else { throw MeshM1CameraError.invalidReceipt }
        let identity = try MeshManagedCameraIdentity(sessionID: UUID().uuidString.lowercased(),
            generation: runID.uuidString.lowercased(), stationEpoch: epoch, cameraID: configuration.cameraID)
        self.identity = identity
        connection = try MeshManagedCameraConnection(snapshotURL: URL(string: "http://127.0.0.1:\(configuration.localPort)/snapshot.jpg")!,
            identity: identity, snapshotToken: snapshotToken)
        phase = .preparing; status = "Preparing the M1 camera listener · camera off"
        deadline = now() + 8; nextRenewal = now() + 2
        try send(command: "prepare", extra: ["port": configuration.remotePort, "snapshotToken": snapshotToken])
    }

    private func send(command: String, extra: [String: Any] = [:]) throws {
        guard let identity, let transport else { throw MeshM1CameraError.unavailable }
        var record: [String: Any] = ["schemaVersion": 1, "command": command,
            "sessionID": identity.sessionID, "generation": identity.generation,
            "stationEpoch": identity.stationEpoch, "cameraID": identity.cameraID, "controlToken": controlToken]
        record.merge(extra) { _, new in new }
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        guard bytes.count <= 4096 else { throw MeshM1CameraError.invalidConfiguration }
        try transport.send(bytes)
    }

    private func beginStop(message: String, sendStop: Bool = true) {
        guard transport != nil else { return }
        guard phase != .stopping else { return }
        phase = .stopping; status = message; shutdown = .pending; lastFrameAt = nil
        healthTask?.cancel(); healthTask = nil; connection = nil
        onRevoke?(); deadline = now() + 3
        if sendStop, identity != nil { do { try send(command: "stop") } catch { closeTransport() } }
        else { closeTransport() }
    }

    private func closeTransport() {
        guard !closingTransport else { return }
        closingTransport = true; deadline = now() + 3
        transport?.close()
    }

    private func ended(run: UUID) {
        guard runID == run, transport != nil else { return }
        if phase != .stopping { beginStop(message: "M1 camera connection ended", sendStop: false) }
        if shutdown != .confirmed { shutdown = .unconfirmed; status = "M1 camera connection closed · remote shutdown unconfirmed" }
        transport = nil; timer?.cancel(); timer = nil; clearSession()
        phase = shutdown == .confirmed ? .stopped : .unavailable
    }

    private func clearSession() {
        healthTask?.cancel(); healthTask = nil; connection = nil; identity = nil
        configuration = nil; controlToken = ""; snapshotToken = ""; lastFrameAt = nil
    }

    private static func randomToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func failureDescription(_ code: String) -> String {
        switch code {
        case "stationDark", "stationMode": return "M1 camera requires Desktop mode"
        case "consoleLocked", "consoleUnavailable", "sessionProbeUnavailable": return "M1 camera requires an unlocked M1"
        case "permissionMissing", "cameraPermission": return "M1 camera permission is missing"
        case "deviceMissing", "deviceBusy", "cameraMissing": return "Selected M1 camera is unavailable"
        case "helperUnavailable", "configurationUnavailable": return "M1 camera setup is unavailable"
        case "leaseExpired": return "M1 camera session expired"
        case "shutdownUnconfirmed": return "M1 camera shutdown could not be confirmed"
        default: return "M1 camera session could not continue"
        }
    }
}

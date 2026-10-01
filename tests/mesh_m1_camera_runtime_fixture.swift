import Foundation

final class FakeCameraTransport: MeshM1CameraTransport, @unchecked Sendable {
    var onLine: (@Sendable (Data) -> Void)?
    var onEnd: (@Sendable () -> Void)?
    var commands: [[String: Any]] = []
    var closes = 0
    func start(onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        self.onLine = onLine; self.onEnd = onEnd
    }
    func send(_ line: Data) throws { commands.append(try JSONSerialization.jsonObject(with: line) as! [String: Any]) }
    func close() { closes += 1 }
    func emit(_ value: [String: Any]) { onLine?(try! JSONSerialization.data(withJSONObject: value)) }
    func end() { onEnd?() }
    var identity: [String: Any] {
        let prepare = commands.first { $0["command"] as? String == "prepare" }!
        return prepare.filter { ["sessionID", "generation", "stationEpoch", "cameraID"].contains($0.key) }
    }
    func receipt(_ event: String, state: String = "capturing", active: Bool = true, reason: String = "ok") {
        emit(["schemaVersion": 1, "event": event, "reason": reason, "state": state,
              "identity": identity, "captureActive": active, "frameObserved": event == "firstFrame"])
    }
}

actor HealthBarrier {
    var waiting: CheckedContinuation<Void, Never>?
    func check() async { await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}

@MainActor final class FixtureClock { var value: TimeInterval = 10 }

@main struct Fixture {
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    static let hello: [String: Any] = ["schemaVersion": 1, "event": "stationHello",
        "stationEpoch": "epoch-fixture", "mode": "desktop", "eligible": true,
        "cameraID": "camera-fixture", "port": 48882, "reason": "ready"]

    @MainActor static func main() async throws {
        let config = try MeshM1CameraConfiguration(cameraID: "camera-fixture", localPort: 48881, remotePort: 48882)
        let clock = FixtureClock(), channel = FakeCameraTransport()
        var constructed = 0, sources: [MeshManagedCameraConnection] = [], revocations = 0
        let runtime = MeshM1CameraRuntime(makeTransport: { _ in constructed += 1; return channel },
            verifyHealth: { _ in }, now: { clock.value }, automaticTicks: false)
        runtime.onSourceReady = { sources.append($0) }; runtime.onRevoke = { revocations += 1 }
        precondition(constructed == 0 && runtime.phase == .stopped && !runtime.hasOwnedTransport)
        try runtime.start(configuration: config)
        do { try runtime.start(configuration: config); preconditionFailure("duplicate start") } catch MeshM1CameraError.alreadyOwned {}
        channel.emit(hello); await settle()
        precondition(runtime.phase == .preparing && channel.commands.count == 1 && sources.isEmpty)
        let prepare = channel.commands[0]
        precondition((prepare["controlToken"] as! String).count == 64)
        precondition(prepare["controlToken"] as? String != prepare["snapshotToken"] as? String)
        channel.receipt("listenerReady", state: "prepared", active: false); await settle()
        precondition(runtime.phase == .starting && channel.commands.last?["command"] as? String == "start")
        channel.receipt("helperStarted"); await settle()
        precondition(runtime.phase == .awaitingFrame && !runtime.isRunning && sources.isEmpty)
        channel.receipt("firstFrame"); await settle()
        precondition(!runtime.isRunning && sources.count == 1) // A helper receipt is not a verified image.
        let imageTime = Date()
        runtime.receivedFrame(identity: sources[0].identity, capturedAt: imageTime)
        precondition(runtime.isRunning && runtime.lastFrameAt == imageTime)
        clock.value += 2.1; runtime.tick()
        precondition(channel.commands.last?["command"] as? String == "renew")
        precondition(channel.commands.last?["sequence"] as? UInt64 == 1)
        runtime.stop(); runtime.stop()
        precondition(revocations == 1 && runtime.phase == .stopping && runtime.lastFrameAt == nil)
        precondition(channel.commands.filter { $0["command"] as? String == "stop" }.count == 1)
        runtime.receivedFrame(identity: sources[0].identity, capturedAt: Date())
        precondition(!runtime.isRunning)
        channel.receipt("stopped", state: "stopped", active: false); await settle()
        precondition(runtime.shutdown == .confirmed && channel.closes == 1 && runtime.hasOwnedTransport)
        channel.end(); await settle(); await runtime.finishStop()
        precondition(runtime.phase == .stopped && !runtime.hasOwnedTransport)

        // Pause while the health check ignores cancellation: late success cannot send Start.
        let late = FakeCameraTransport(), barrier = HealthBarrier()
        let delayed = MeshM1CameraRuntime(makeTransport: { _ in late }, verifyHealth: { _ in await barrier.check() },
            now: { clock.value }, automaticTicks: false)
        try delayed.start(configuration: config); late.emit(hello); await settle()
        late.receipt("listenerReady", state: "prepared", active: false); await settle()
        precondition(delayed.phase == .verifying)
        delayed.stop(); await barrier.release(); await settle()
        precondition(!late.commands.contains { $0["command"] as? String == "start" })
        clock.value += 3.1; delayed.tick()
        precondition(delayed.shutdown == .unconfirmed && late.closes == 1)
        late.end(); await settle()
        precondition(delayed.phase == .unavailable)

        // Ineligible console never prepares a helper, reconnect never automatically starts.
        let dark = FakeCameraTransport()
        let denied = MeshM1CameraRuntime(makeTransport: { _ in dark }, verifyHealth: { _ in }, automaticTicks: false)
        try denied.start(configuration: config)
        var darkHello = hello; darkHello["eligible"] = false; darkHello["mode"] = "dark"; darkHello["reason"] = "stationDark"
        dark.emit(darkHello); await settle()
        precondition(dark.commands.isEmpty && dark.closes == 1)
        dark.emit(hello); await settle(); precondition(dark.commands.isEmpty)
        dark.end(); await settle()

        // A replaced session's metadata cannot activate the current importer.
        let wrong = FakeCameraTransport()
        let pinned = MeshM1CameraRuntime(makeTransport: { _ in wrong }, verifyHealth: { _ in }, automaticTicks: false)
        try pinned.start(configuration: config); wrong.emit(hello); await settle()
        var staleIdentity = wrong.identity; staleIdentity["generation"] = UUID().uuidString
        wrong.emit(["schemaVersion": 1, "event": "helperStarted", "reason": "ok", "state": "capturing",
            "identity": staleIdentity, "captureActive": true, "frameObserved": false]); await settle()
        precondition(pinned.phase == .stopping && !pinned.isRunning)
        wrong.end(); await settle()

        // Receipt flood is bounded before MainActor delivery and fails closed.
        let flooded = FakeCameraTransport()
        let bounded = MeshM1CameraRuntime(makeTransport: { _ in flooded }, verifyHealth: { _ in }, automaticTicks: false)
        try bounded.start(configuration: config)
        for _ in 0..<1000 { flooded.emit(hello) }
        await settle()
        precondition(bounded.phase == .stopping && flooded.commands.isEmpty && flooded.closes == 1)
        flooded.end(); await settle()
        print("PASS: M1 runtime fake transport only; ownership, health race, verified-image readiness, renewal, stop ACK, timeout, stale generation, bounded inbox; no SSH, camera or audio")
    }
}

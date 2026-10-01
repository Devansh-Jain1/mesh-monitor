import Foundation

private final class Clock: @unchecked Sendable {
    var time: UInt64 = 0
    func advance(_ seconds: Double) { time += UInt64(seconds * 1_000_000_000) }
}
private final class MockBackend: MeshSnapshotBackend, @unchecked Sendable {
    var prepares = 0, starts = 0, stops = 0
    var autoPrepare = true, autoStart = true, autoStop = true
    var onPrepared: (@Sendable (Result<Void, MeshSnapshotFailure>) -> Void)?
    var onStarted: (@Sendable (Result<Void, MeshSnapshotFailure>) -> Void)?
    var onStopped: (@Sendable () -> Void)?
    func prepare(_ configuration: MeshSnapshotConfiguration, completion: @escaping @Sendable (Result<Void, MeshSnapshotFailure>) -> Void) {
        prepares += 1; onPrepared = completion; if autoPrepare { completion(.success(())) }
    }
    func start(completion: @escaping @Sendable (Result<Void, MeshSnapshotFailure>) -> Void) {
        starts += 1; onStarted = completion; if autoStart { completion(.success(())) }
    }
    func stop(completion: @escaping @Sendable () -> Void) {
        stops += 1; onStopped = completion; if autoStop { completion() }
    }
}
private final class Harness: @unchecked Sendable {
    let clock = Clock(), backend = MockBackend()
    var receipts: [MeshSnapshotReceipt] = [], exits: [Int32] = []
    var constructed = 0, outputAvailable = true
    lazy var controller = MeshSnapshotManagedController(now: { [self] in clock.time }, makeBackend: { [self] in
        constructed += 1; return backend
    }, emit: { [self] value in receipts.append(value); return outputAvailable }, exit: { [self] code in exits.append(code) })
    func send(_ operation: String, changes: [String: Any] = [:]) {
        var value: [String: Any] = ["schemaVersion": 1, "command": operation,
            "sessionID": "00000000-0000-4000-8000-000000000001", "generation": "00000000-0000-4000-8000-000000000002",
            "stationEpoch": "receiver-1", "cameraID": "EXACT-EXTERNAL-CAMERA", "controlToken": String(repeating: "a", count: 64)]
        if operation == "prepare" { value["port"] = 18_495; value["snapshotToken"] = String(repeating: "b", count: 64) }
        if operation == "renew" { value["sequence"] = 1 }
        for (key, replacement) in changes { value[key] = replacement }
        controller.receive(try! JSONSerialization.data(withJSONObject: value))
    }
}

@main struct MeshSnapshotManagedFixture {
    static func main() throws {
        var checks = 0
        func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        do {
            let h = Harness(); _ = h.controller
            verify(h.constructed == 0 && h.receipts.isEmpty, "Initialization must be inert")
            h.send("start")
            verify(h.constructed == 0 && h.receipts.last?.reason == "invalidState", "Start cannot skip prepare")
            h.send("prepare")
            verify(h.constructed == 1 && h.backend.prepares == 1 && h.backend.starts == 0, "Prepare creates only the inert listener backend")
            verify(h.receipts.last?.event == "listenerReady" && h.receipts.last?.captureActive == false, "Listener is not camera capture")
            h.send("prepare"); h.send("status")
            verify(h.backend.prepares == 1 && h.backend.starts == 0, "Duplicate prepare/status cannot capture")
            h.send("start"); h.send("start")
            verify(h.backend.starts == 1 && h.receipts.contains { $0.event == "helperStarted" }, "Only one capture start")
            verify(!h.receipts.contains { $0.event == "firstFrame" }, "Start is not a frame proof")
            h.controller.firstFrame(at: Date(timeIntervalSince1970: 1)); h.controller.firstFrame(at: Date(timeIntervalSince1970: 2))
            verify(h.receipts.filter { $0.event == "firstFrame" }.count == 1, "Only first fresh frame metadata is emitted")
            h.send("stop"); h.send("start"); h.controller.firstFrame(at: Date())
            verify(h.backend.stops == 1 && h.backend.starts == 1 && h.exits == [0], "Stop is final and exactly once")
            verify(h.receipts.last?.event == "stopped" && h.receipts.last?.captureActive == false && h.receipts.last?.frameObserved == false, "Stopped clears frame evidence")
            let serialized = try JSONEncoder().encode(h.receipts)
            let text = String(decoding: serialized, as: UTF8.self)
            verify(!text.contains(String(repeating: "a", count: 64)) && !text.contains(String(repeating: "b", count: 64)), "Receipts never contain credentials")
        }
        for field in ["sessionID", "generation", "stationEpoch", "cameraID", "controlToken"] {
            let h = Harness(); h.send("prepare"); h.send("start")
            let replacement = field == "controlToken" ? String(repeating: "c", count: 64) : field == "sessionID" || field == "generation" ? UUID().uuidString : "other"
            h.send("stop", changes: [field: replacement])
            verify(h.backend.stops == 0 && h.exits.isEmpty, "Wrong tuple/token cannot stop this session")
            h.clock.advance(6); h.controller.tick()
            verify(h.backend.stops == 1 && h.receipts.last?.reason == "leaseExpired", "Rejected command cannot renew lease")
        }
        do {
            let h = Harness(); h.send("prepare"); h.clock.advance(5); h.send("renew")
            h.clock.advance(5); h.controller.tick()
            verify(h.exits.isEmpty, "Valid increasing renewal extends lease")
            h.send("renew"); verify(h.receipts.last?.reason == "staleRenewal", "Duplicate renewal rejected")
            h.clock.advance(1); h.controller.tick()
            verify(h.receipts.last?.reason == "leaseExpired", "Duplicate renewal cannot extend lease")
        }
        for phase in ["idle", "preparing", "prepared", "starting", "capturing"] {
            let h = Harness(); h.backend.autoPrepare = phase != "preparing"; h.backend.autoStart = phase != "starting"
            if phase != "idle" { h.send("prepare") }
            if phase == "starting" || phase == "capturing" { h.send("start") }
            h.controller.fail(.parentEOF)
            h.backend.onPrepared?(.success(())); h.backend.onStarted?(.success(()))
            h.controller.firstFrame(at: Date()); h.controller.tick()
            verify(h.exits == [0] && h.receipts.last?.event == "stopped", "EOF must finish every state without a late revival")
            verify(h.backend.starts <= 1 && h.backend.stops == (phase == "idle" ? 0 : 1), "EOF stops only the owned backend")
        }
        do {
            let h = Harness(); h.send("prepare"); h.send("start"); h.backend.autoStop = false
            h.send("stop"); h.send("stop")
            verify(h.backend.stops == 1 && h.exits.isEmpty && h.receipts.last?.event == "stopping", "Pending teardown is not stopped proof")
            h.clock.advance(2); h.controller.tick()
            verify(h.exits == [3] && h.receipts.last?.reason == "shutdownUnconfirmed", "Stalled teardown is bounded and honest")
            h.backend.onStopped?(); h.controller.tick()
            verify(h.exits == [3] && !h.receipts.contains { $0.event == "stopped" }, "Late completion cannot replace timeout")
        }
        do {
            let h = Harness(); h.send("prepare"); h.backend.autoStop = false; h.send("stop")
            verify(h.receipts.last?.captureActive == false, "Stopping a prepared listener must not claim camera capture")
            h.backend.onStopped?(); verify(h.exits == [0], "Orderly completion acknowledged")
        }
        do {
            let h = Harness(); _ = h.controller; h.clock.advance(10); h.controller.tick()
            verify(h.constructed == 0 && h.receipts.last?.reason == "startupExpired", "Silent parent startup expires without initializing sensors")
        }
        do {
            let h = Harness(); h.send("prepare"); h.outputAvailable = false; h.send("status")
            verify(h.backend.stops == 1 && h.exits == [2], "Broken output triggers cleanup without recursion")
        }
        for reason in [MeshSnapshotFailure.cameraPermission, .cameraMissing, .configuration, .captureFailed, .listenerFailed, .signal] {
            let h = Harness(); h.send("prepare"); h.controller.fail(reason)
            verify(h.backend.stops == 1 && h.receipts.last?.reason == reason.rawValue, "Backend failure/signal must close only its session")
        }
        for change: [String: Any] in [["schemaVersion": 2], ["port": 80], ["port": true], ["controlToken": "short"],
            ["snapshotToken": String(repeating: "a", count: 64)], ["cameraID": "bad\r\nheader"], ["stationEpoch": ""], ["unexpected": "value"]] {
            let h = Harness(); h.send("prepare", changes: change)
            verify(h.constructed == 0 && h.exits == [2], "Invalid prepare cannot construct real backend")
        }
        do {
            let h = Harness(); h.controller.receive(Data("{}".utf8))
            verify(h.constructed == 0 && h.exits == [2], "Malformed command is inert")
            var lines = MeshSnapshotLineBuffer()
            let fragment = try lines.append(Data("abc".utf8))
            verify(fragment.isEmpty, "Fragment retained")
            let completed = try lines.append(Data("\ndef\n".utf8))
            verify(completed == [Data("abc".utf8), Data("def".utf8)], "Framing handles fragments and multiple messages")
            do { _ = try lines.append(Data(repeating: 65, count: 4_097)); preconditionFailure("Oversized line accepted") }
            catch { checks += 1 }
        }
        let token = String(repeating: "b", count: 64)
        func request(_ path: String = "/snapshot.jpg", _ headers: String = "", method: String = "GET") -> Data {
            Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n".utf8)
        }
        verify(meshSnapshotHTTPRoute(request(), token: token) == .reject(401), "Managed image requires authorization")
        verify(meshSnapshotHTTPRoute(request("/health"), token: token) == .reject(401), "Health is authenticated too")
        verify(meshSnapshotHTTPRoute(request("/snapshot.jpg", "Authorization: Bearer \(token)\r\n"), token: token) == .snapshot, "Exact bearer succeeds")
        verify(meshSnapshotHTTPRoute(request("/health", "Authorization: Bearer \(token)\r\n"), token: token) == .health, "Prepared health allowed")
        verify(meshSnapshotHTTPRoute(request("/snapshot.jpg?token=\(token)"), token: token) == .reject(401), "URL tokens do not authenticate")
        verify(meshSnapshotHTTPRoute(request("/snapshot.jpg", "Authorization: Bearer \(token)\r\nAuthorization: Bearer \(token)\r\n"), token: token) == .reject(400), "Duplicate authorization rejected")
        verify(meshSnapshotHTTPRoute(request("/snapshot.jpg", "Authorization: Bearer \(token)\r\nContent-Length: 1\r\n"), token: token) == .reject(400), "GET bodies rejected")
        verify(meshSnapshotHTTPRoute(request(), token: nil) == .snapshot, "Standalone snapshot compatibility")
        verify(meshSnapshotHTTPRoute(request("/health"), token: nil) == .health, "Standalone health compatibility")
        verify(meshSnapshotHTTPRoute(request("/other"), token: nil) == .reject(404), "Unknown paths rejected")
        verify(meshSnapshotHTTPRoute(request(method: "POST"), token: nil) == .reject(405), "Only GET")
        print("PASS: \(checks) managed snapshot checks; mock backends only; no camera, TCC or listeners")
    }
}

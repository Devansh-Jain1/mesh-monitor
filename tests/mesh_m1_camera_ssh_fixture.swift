import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "MeshM1CameraSSHFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    private var ends = 0
    func line(_ data: Data) { lock.lock(); lines.append(data); lock.unlock() }
    func end() { lock.lock(); ends += 1; lock.unlock() }
    var snapshot: ([Data], Int) { lock.lock(); defer { lock.unlock() }; return (lines, ends) }
}

private final class HealthFixtureState: @unchecked Sendable {
    let lock = NSLock()
    var mode = "success"
    var requests = 0
    var headers: [String: String] = [:]
    func configure(_ mode: String, headers: [String: String]) { lock.lock(); self.mode = mode; self.headers = headers; requests = 0; lock.unlock() }
    func received() -> (String, [String: String]) { lock.lock(); defer { lock.unlock() }; requests += 1; return (mode, headers) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = HealthFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true } // Every request intercepted; never opens a socket.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (mode, expectedHeaders) = Self.state.received()
        guard request.url?.host == "127.0.0.1", request.url?.path == "/health",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "a", count: 64) else {
            client?.urlProtocol(self, didFailWithError: MeshM1CameraTransportError.invalidHealth); return
        }
        if mode == "hang" { return }
        var headers = expectedHeaders
        if mode == "wrong-identity" { headers["X-Mesh-Camera-Session"] = UUID().uuidString }
        if mode == "declared-large" { headers["Content-Length"] = "99999999" }
        if mode == "redirect" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "http://127.0.0.1:45123/other"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "http://127.0.0.1:45123/other")!), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == "stream-large" {
            // Deliberately no Content-Length: delegate must bound bytes during delivery.
            client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 2048))
            client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 2049))
        } else {
            let text = mode == "active" ? "{\"ready\":true,\"captureActive\":true,\"fresh\":false}" : "{\"ready\":true,\"captureActive\":false,\"fresh\":false}"
            client?.urlProtocol(self, didLoad: Data(text.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct MeshM1CameraSSHFixture {
    static func wait(_ label: String, _ predicate: @Sendable () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw NSError(domain: "FixtureTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/mesh-camera-ssh-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("child.py")
        try Data("""
        import os, signal, sys, time
        mode, marker = sys.argv[1:]
        with open(marker, 'w') as f: f.write(str(os.getpid()))
        if mode == 'stall':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True: time.sleep(1)
        if mode == 'oversize':
            sys.stdout.write('x' * 4097); sys.stdout.flush()
            time.sleep(5)
        elif mode == 'flood':
            sys.stdout.write('{}\\n' * 40); sys.stdout.flush()
            time.sleep(5)
        elif mode == 'truncated':
            sys.stdout.write('{'); sys.stdout.flush()
        else:
            for line in sys.stdin.buffer:
                sys.stdout.buffer.write(line[:2]); sys.stdout.buffer.flush()
                time.sleep(.005)
                sys.stdout.buffer.write(line[2:]); sys.stdout.buffer.flush()
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        func channel(_ mode: String, suffix: String = "") -> (MeshM1CameraSSH, URL) {
            let marker = root.appendingPathComponent(mode + suffix + ".started")
            return (MeshM1CameraSSH(testExecutable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path, mode, marker.path]), marker)
        }
        let configuration = try MeshM1CameraConfiguration(cameraID: "camera-never-in-argv", localPort: 45123, remotePort: 45124)
        let argv = MeshM1CameraSSH.arguments(configuration: configuration)
        try require(argv.suffix(2) == ["mesh-m1", MeshM1CameraSSH.remoteCommand], "fixed SSH host/command")
        try require(argv.contains("127.0.0.1:45123:127.0.0.1:45124") && argv.contains("ControlPath=none") && argv.contains("StrictHostKeyChecking=yes"), "owned authenticated loopback forward")
        try require(!argv.joined().contains(configuration.cameraID), "device fields never enter argv")
        let missing = MeshM1CameraSSH(testExecutable: root.appendingPathComponent("missing-executable"), arguments: [])
        let missingRecord = Recorder()
        do { try missing.start(onLine: missingRecord.line, onEnd: missingRecord.end); throw NSError(domain: "missing executable accepted", code: 1) }
        catch MeshM1CameraTransportError.startup {}
        missing.close(); missing.close()
        try require(missingRecord.snapshot.1 == 1 && missingRecord.snapshot.0.isEmpty, "no-child launch failure ends once")
        let (preCancelled, preCancelledMarker) = channel("echo", suffix: "cancelled"), preCancelledRecord = Recorder()
        preCancelled.close()
        do { try preCancelled.start(onLine: preCancelledRecord.line, onEnd: preCancelledRecord.end); throw NSError(domain: "cancelled launch accepted", code: 1) }
        catch MeshM1CameraTransportError.closed {}
        try require(preCancelledRecord.snapshot.1 == 1 && !FileManager.default.fileExists(atPath: preCancelledMarker.path), "cancel before spawn ends without a child")
        let (echo, marker) = channel("echo"), record = Recorder()
        try require(!FileManager.default.fileExists(atPath: marker.path), "initializer is inert")
        try echo.start(onLine: record.line, onEnd: record.end)
        try echo.send(Data("{\"fixture\":1}".utf8))
        try echo.send(Data("{\"fixture\":2}\n".utf8))
        try await wait("fragmented lines") { record.snapshot.0.count == 2 }
        try require(record.snapshot.0.map { String(decoding: $0, as: UTF8.self) } == ["{\"fixture\":1}", "{\"fixture\":2}"], "line framing strips only newline")
        do { try echo.send(Data("{}\n{}".utf8)); throw NSError(domain: "accepted multiline", code: 1) } catch MeshM1CameraTransportError.invalidLine {}
        echo.close(); echo.close()
        try await wait("echo exit") { record.snapshot.1 == 1 }
        try require(record.snapshot.1 == 1, "end callback exactly once")

        for mode in ["oversize", "flood", "truncated"] {
            let (transport, _) = channel(mode), received = Recorder()
            try transport.start(onLine: received.line, onEnd: received.end)
            try await wait("bounded invalid output \(mode)") { received.snapshot.1 == 1 }
            try require(received.snapshot.0.count <= 32 && (mode == "flood" || received.snapshot.0.isEmpty), "invalid/burst output bounded")
        }
        let (blocked, blockedMarker) = channel("stall"), blockedRecord = Recorder()
        try blocked.start(onLine: blockedRecord.line, onEnd: blockedRecord.end)
        try await wait("stall child started") { FileManager.default.fileExists(atPath: blockedMarker.path) }
        let large = try JSONSerialization.data(withJSONObject: ["padding": String(repeating: "x", count: 3900)])
        var backpressure = false
        for _ in 0..<128 {
            do { try blocked.send(large) }
            catch { backpressure = true; break }
        }
        try require(backpressure, "nonreading stdin cannot accumulate unbounded commands")
        try await wait("retained stalled child killed") { blockedRecord.snapshot.1 == 1 }
        let pid = pid_t(try String(contentsOf: blockedMarker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try require(kill(pid, 0) == -1 && errno == ESRCH, "end waits for actual child exit")

        let spawned = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        let raceRecord = Recorder()
        let race = MeshM1CameraSSH(testExecutable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path, "echo", root.appendingPathComponent("race.started").path], afterSpawn: { spawned.signal(); release.wait() })
        DispatchQueue.global().async { try? race.start(onLine: raceRecord.line, onEnd: raceRecord.end); started.signal() }
        try require(spawned.wait(timeout: .now() + 3) == .success, "spawn barrier reached")
        race.close(); release.signal()
        try require(started.wait(timeout: .now() + 3) == .success, "post-spawn cancellation returns")
        try await wait("post-spawn cancelled child exits") { raceRecord.snapshot.1 == 1 }

        let identity = try MeshManagedCameraIdentity(sessionID: UUID().uuidString, generation: UUID().uuidString, stationEpoch: "fixture-epoch", cameraID: "fixture-camera")
        let connection = try MeshManagedCameraConnection(snapshotURL: URL(string: "http://127.0.0.1:45123/snapshot.jpg")!, identity: identity, snapshotToken: String(repeating: "a", count: 64))
        let headers = ["Content-Type": "application/json", "X-Mesh-Camera-Session": identity.sessionID,
            "X-Mesh-Camera-Generation": identity.generation, "X-Mesh-Camera-ID": identity.cameraID, "X-Mesh-Station-Epoch": identity.stationEpoch]
        func health(_ mode: String, deadline: TimeInterval = 0.15) async throws {
            FixtureURLProtocol.state.configure(mode, headers: headers)
            let configuration = MeshManagedCameraConnection.sessionConfiguration(); configuration.protocolClasses = [FixtureURLProtocol.self]
            try await MeshM1CameraHealth.verify(connection, testConfiguration: configuration, deadline: deadline)
        }
        try await health("success")
        for mode in ["active", "wrong-identity", "declared-large", "stream-large", "redirect", "hang"] {
            var rejected = false
            do { try await health(mode) } catch { rejected = true }
            try require(rejected, "health rejects \(mode)")
            try require(FixtureURLProtocol.state.count == 1, "no redirect or duplicate request escapes interceptor")
        }
        let cancellation = Task { try await health("hang", deadline: 1) }
        try await Task.sleep(nanoseconds: 20_000_000); cancellation.cancel()
        do { try await cancellation.value; throw NSError(domain: "uncancelled health", code: 1) } catch is CancellationError {}
        print("PASS: M1 transport fake children, bounded framing/backpressure, owned exit and cancellation; health synthetic URLProtocol only. No SSH, network, camera or audio.")
    }
}

import Darwin
import Foundation

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw NSError(domain: "M1ShutdownFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@MainActor private func until(_ message: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(4)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    try expect(condition(), "timeout: \(message)")
}
private let good = Data("{\"ok\":true}".utf8)

private final class FakeJob: MeshM1ReturnJob, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var starts = 0, cancellations = 0
    let ignoreCancellation: Bool
    init(response: Data? = nil, ignoreCancellation: Bool = false) {
        result = response.map { .success($0) }; self.ignoreCancellation = ignoreCancellation
    }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); starts += 1
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { waiting = continuation; lock.unlock() }
        }
    }
    func complete(_ result: Result<Data, Error>) {
        lock.lock(); self.result = result; let continuation = waiting; waiting = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock(); cancellations += 1; lock.unlock()
        if !ignoreCancellation { complete(.failure(CancellationError())) }
    }
}
private final class FakeAwake: MeshM1ReturnAwakeAssertion {
    private(set) var isRunning = false
    func start() { isRunning = true }
    func cancel() { isRunning = false }
}
@MainActor private final class FixtureTransport {
    struct Request { let operation: String; let payload: Data; let job: FakeJob }
    var requests: [Request] = []
    var awake: [FakeAwake] = []
    var armResponds = true
    var ignoreDisarmCancellation = false
    func makeJob(_ operation: String, _ payload: Data) -> any MeshM1ReturnJob {
        let job = FakeJob(response: operation == "arm" && armResponds ? good : nil,
                          ignoreCancellation: operation == "disarm" && ignoreDisarmCancellation)
        requests.append(Request(operation: operation, payload: payload, job: job)); return job
    }
    func requests(_ operation: String) -> [Request] { requests.filter { $0.operation == operation } }
    func trigger() -> MeshM1ReturnTrigger {
        MeshM1ReturnTrigger(makeJob: { self.makeJob($0, $1) }, makeKeepAwake: {
            let assertion = FakeAwake(); self.awake.append(assertion); return assertion
        })
    }
}
private final class JobBox: @unchecked Sendable { weak var job: MeshM1ReturnSSH? }

@main struct MeshM1ReturnShutdownFixture {
    @MainActor private static func arm(_ trigger: MeshM1ReturnTrigger, session: UUID = UUID()) async throws {
        try await trigger.arm(sessionID: session, intendedDate: Date(), piName: "fixture-pi", piAddresses: ["127.0.0.1"])
    }
    @MainActor static func main() async throws {
        try await shutdownLifecycle()
        try await boundedTransport()
        print("PASS: synthetic M1 disarm acknowledgement, cancellation, repeated Stop and bounded owned transport")
    }
    @MainActor private static func shutdownLifecycle() async throws {
        let transport = FixtureTransport(), session = UUID(), trigger = transport.trigger()
        await trigger.finishStop(); trigger.cancelPendingDisarm()
        try expect(trigger.disarmStatus == "not_needed" && transport.requests.isEmpty, "inert shutdown must not contact transport")
        try await arm(trigger, session: session)
        trigger.stop(); trigger.stop()
        let request = transport.requests("disarm")[0]
        let payload = try JSONSerialization.jsonObject(with: request.payload) as! [String: String]
        try expect(payload == ["session_id": session.uuidString.lowercased()], "cleanup binds exact owned session")
        try expect(!trigger.isArmed && !trigger.isReady && transport.awake.allSatisfy { !$0.isRunning }
                   && trigger.disarmStatus == "pending" && transport.requests("disarm").count == 1, "repeated Stop preserves pending cleanup")
        var finished = false
        let completion = Task { await trigger.finishStop(); finished = true }
        try await until("disarm starts") { request.job.startCount == 1 }
        try expect(!finished && request.job.cancelCount == 0, "finishStop awaits existing disarm without cancelling it")
        request.job.complete(.success(good)); await completion.value
        try expect(finished && trigger.disarmStatus == "confirmed", "only true acknowledgement confirms cleanup")
        trigger.stop(); await trigger.finishStop()
        try expect(transport.requests("disarm").count == 1 && trigger.disarmStatus == "confirmed", "already-stopped shutdown preserves confirmed outcome")

        for bytes in [Data("{\"ok\":false}".utf8), Data("{\"ok\":1}".utf8), Data("{}".utf8), Data("invalid".utf8)] {
            let t = FixtureTransport(), stopped = t.trigger()
            try await arm(stopped); stopped.stop()
            t.requests("disarm")[0].job.complete(.success(bytes))
            await stopped.finishStop()
            try expect(stopped.disarmStatus == "unconfirmed", "bad acknowledgement must not confirm cleanup")
        }
        let failureTransport = FixtureTransport(), failure = failureTransport.trigger()
        try await arm(failure); failure.stop()
        failureTransport.requests("disarm")[0].job.complete(.failure(MeshM1ReturnError.unavailable))
        await failure.finishStop(); try expect(failure.disarmStatus == "unconfirmed", "transport failure remains visible")

        let cancellation = FixtureTransport(); cancellation.ignoreDisarmCancellation = true
        let cancelled = cancellation.trigger(); try await arm(cancelled); cancelled.stop()
        let late = cancellation.requests("disarm")[0].job
        try await until("cancel fixture starts") { late.startCount == 1 }
        cancelled.cancelPendingDisarm()
        try expect(cancelled.disarmStatus == "unconfirmed" && late.cancelCount == 1, "outer deadline cancels only pending cleanup")
        late.complete(.success(good)); await cancelled.finishStop()
        try expect(cancelled.disarmStatus == "unconfirmed", "late true acknowledgement cannot revive cancelled cleanup")

        let rearmTransport = FixtureTransport(), rearm = rearmTransport.trigger(), newer = UUID()
        try await arm(rearm); rearm.stop()
        let previous = rearmTransport.requests("disarm")[0].job
        let rearming = Task { try await arm(rearm, session: newer) }
        try await until("previous cleanup still pending") { previous.startCount == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(rearmTransport.requests("arm").count == 1 && previous.cancelCount == 0, "new arm awaits previous required cleanup")
        previous.complete(.success(good)); try await rearming.value
        rearm.stop(); let newerRequest = rearmTransport.requests("disarm")[1]
        let newerPayload = try JSONSerialization.jsonObject(with: newerRequest.payload) as! [String: String]
        try expect(newerPayload["session_id"] == newer.uuidString.lowercased(), "new session owns its separate exact disarm")
        newerRequest.job.complete(.success(good)); await rearm.finishStop()

        let armCancellation = FixtureTransport(); armCancellation.armResponds = false
        let interrupted = armCancellation.trigger(), interruptedSession = UUID()
        let arming = Task { try await arm(interrupted, session: interruptedSession) }
        try await until("arm request pending") { armCancellation.requests("arm").first?.job.startCount == 1 }
        interrupted.stop()
        do { try await arming.value; throw MeshM1ReturnError.invalidState } catch is CancellationError { }
        try expect(armCancellation.awake.isEmpty && !interrupted.isArmed, "cancelled arm cannot start keep-awake or polling")
        armCancellation.requests("disarm")[0].job.complete(.success(good)); await interrupted.finishStop()
        try expect(interrupted.disarmStatus == "confirmed", "cancelled arm still has exact-session cleanup")
    }

    @MainActor private static func boundedTransport() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/mesh-m1-shutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-helper")
        let script = #"""
#!/usr/bin/python3
import json,os,signal,sys
from pathlib import Path
marker=Path(sys.argv[1]);mode=sys.argv[2]
marker.with_suffix('.started').write_text('started')
def finish(*args):
 marker.with_suffix('.stopped').write_text('stopped')
 sys.exit(0)
if mode=='stall':
 signal.signal(signal.SIGTERM,lambda *_:signal.alarm(1))
 signal.signal(signal.SIGALRM,finish)
 while True:signal.pause()
if mode=='closed':
 os.close(0);sys.exit(1)
data=sys.stdin.buffer.read()
marker.with_suffix('.payload').write_bytes(data)
if mode=='oversized':print('x'*70000,flush=True)
else:print(json.dumps({'ok':True}),flush=True)
"""#
        try Data(script.utf8).write(to: executable); chmod(executable.path, 0o700)
        func job(_ name: String, _ mode: String, didLaunch: (@Sendable () -> Void)? = nil) -> MeshM1ReturnSSH {
            MeshM1ReturnSSH(operation: "fixture", payload: good, executableURL: executable,
                            arguments: [directory.appendingPathComponent(name).path, mode], timeoutNanoseconds: mode == "stall" ? 1_000_000_000 : 2_000_000_000,
                            didLaunch: didLaunch)
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
        let normal: Data
        do { normal = try await job("normal", "normal").run() }
        catch {
            throw NSError(domain: "M1ShutdownFixture", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "normal fake transport failed: \(error); started=\(exists("normal.started")); payload=\(exists("normal.payload"))"])
        }
        try expect((try JSONSerialization.jsonObject(with: normal) as? [String: Bool])?["ok"] == true, "synthetic runner drains actual output and exit")
        let before = job("before", "normal"); before.cancel()
        do { _ = try await before.run(); throw MeshM1ReturnError.invalidState } catch is CancellationError { }
        try expect(!exists("before.started"), "cancel before spawn launches no child")
        let box = JobBox(), after = job("after", "normal", didLaunch: { box.job?.cancel() }); box.job = after
        do { _ = try await after.run(); throw MeshM1ReturnError.invalidState } catch is CancellationError { }
        try expect(!exists("after.payload"), "post-launch cancellation cannot write payload")
        for (name, mode) in [("closed", "closed"), ("oversized", "oversized"), ("stall", "stall")] {
            let started = Date(); var failed = false
            do { _ = try await job(name, mode).run() } catch { failed = true }
            try expect(failed && Date().timeIntervalSince(started) < 2, "\(mode) transport finishes within bound without blocking read/wait")
            if mode == "stall" { try await until("owned stalled child eventually exits") { exists("stall.stopped") } }
        }
    }
}

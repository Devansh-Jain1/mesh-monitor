import Foundation

@MainActor private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw NSError(domain: message, code: 1) }
}
@MainActor private func until(_ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(2)
    while !condition(), Date() < end { try await Task.sleep(nanoseconds: 1_000_000) }
    try expect(condition(), "Fixture timed out")
}
@MainActor private final class Connection {
    var calls = 0
    var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    func open() async throws {
        calls += 1; let id = calls
        try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func finish(_ id: Int, error: Error? = nil) {
        if let error { pending.removeValue(forKey: id)?.resume(throwing: error) }
        else { pending.removeValue(forKey: id)?.resume() }
    }
}
@main struct Fixture {
    @MainActor static func main() async throws {
        let gate = MeshVoiceStart(), connection = Connection()
        var starts = 0, errors = 0, allowed = true
        func begin() -> Bool {
            gate.begin(connect: { try await connection.open() }, mayActivate: { allowed },
                       activate: { starts += 1 }, failed: { _ in errors += 1 })
        }
        try expect(!gate.isStarting && connection.calls == 0, "Construction is inert")
        try expect(begin() && !begin(), "Repeated Talk joins one owned startup")
        try await until { connection.calls == 1 }
        gate.cancel() // Stop, Captions, Pause or Night.
        try expect(!gate.isStarting, "Stop immediately clears Starting")
        try expect(begin(), "An explicit new Talk can start after Stop")
        try await until { connection.calls == 2 }
        connection.finish(1)
        try await Task.sleep(nanoseconds: 10_000_000)
        try expect(starts == 0 && errors == 0 && gate.isStarting, "Late stopped connection cannot activate or clear the new startup")
        connection.finish(2)
        try await until { starts == 1 }
        try expect(!gate.isStarting && errors == 0, "Current connection activates exactly once")

        try expect(begin(), "Next explicit attempt accepted")
        try await until { connection.calls == 3 }
        allowed = false // A mode/provider change after connection was requested.
        connection.finish(3)
        try await until { !gate.isStarting }
        try expect(starts == 1 && errors == 0, "Changed mode suppresses microphone activation")
        allowed = true
        try expect(begin(), "Recover after mode change")
        try await until { connection.calls == 4 }
        gate.cancel()
        connection.finish(4, error: NSError(domain: "Late failure", code: 1))
        try await Task.sleep(nanoseconds: 10_000_000)
        try expect(starts == 1 && errors == 0 && !gate.isStarting, "A stale failure cannot overwrite UI state")

        try expect(begin(), "Retry after cancelled failure")
        try await until { connection.calls == 5 }
        connection.finish(5, error: NSError(domain: "Current failure", code: 1))
        try await until { errors == 1 }
        try expect(!gate.isStarting && starts == 1, "Current failure is surfaced once and can retry")
        try expect(begin(), "Retry after visible error")
        try await until { connection.calls == 6 }
        gate.cancel(); gate.cancel()
        connection.finish(6)
        try await Task.sleep(nanoseconds: 10_000_000)
        try expect(starts == 1 && errors == 1, "Repeated cancellation stays final")
        print("PASS: owned Talk startup, late callbacks, mode changes, cancellation and recovery; no voice or network")
    }
}

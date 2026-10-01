import Darwin
import Foundation

private enum FixtureError: Error { case failed(String) }
@main struct WorkerFixture {
    static func main() async throws {
        if CommandLine.arguments.count > 1 { child(CommandLine.arguments[1]); return }
        try await tests()
        print("PASS resident worker lifecycle and wrapper checks; fake children only; no capture, models, audio, or network")
    }
    static func child(_ mode: String) {
        let parent = getppid()
        func boundedStall() {
            for _ in 0..<500 { if getppid() != parent { return }; usleep(20_000) }
        }
        func line(_ object: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: object); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
        if mode == "stall" { signal(SIGTERM, SIG_IGN); boundedStall(); return }
        if mode == "eof" { signal(SIGTERM, SIG_IGN); close(STDOUT_FILENO); boundedStall(); return }
        if mode == "failed" { line(["event": "failed"]); usleep(200_000); return }
        if mode == "closed_input" { close(STDIN_FILENO); line(["event": "ready"]); boundedStall(); return }
        line(["event": "ready"])
        while let raw = readLine() {
            let value = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
            let id = value["id"] as! String
            if mode == "no_reply" { signal(SIGTERM, SIG_IGN); boundedStall(); return }
            if mode == "flood" {
                signal(SIGPIPE, SIG_IGN)
                let bytes = [UInt8](repeating: 120, count: 4096)
                for _ in 0..<512 { if Darwin.write(STDOUT_FILENO, bytes, bytes.count) < 0 { return } }
                return
            }
            if mode == "invalid" { print("not-json"); fflush(stdout); usleep(300_000); return }
            if mode == "wrong_id" { line(["id": "other", "ok": true]); usleep(300_000); return }
            if mode == "late" { signal(SIGTERM, SIG_IGN); usleep(250_000) }
            line(["id": id, "ok": true, "text": "fixture transcript", "output": value["output"] ?? "/private/tmp/inert-no-audio.wav", "generation_ms": 1])
        }
    }
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FixtureError.failed(message) }
    }
    @MainActor static func until(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try expect(predicate(), message)
    }
    @MainActor static func spec(_ mode: String) -> M4ResidentJSONWorker.Launch {
        .init(executable: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: [mode], environment: ["PATH":"/usr/bin:/bin"])
    }
    @MainActor static func tests() async throws {
        let short = M4ResidentJSONWorker.Limits(startup: 0.15, request: 0.15, terminateGrace: 0.05)
        let sentinel = M4ResidentJSONWorker(limits: .init()) { spec("healthy") }
        try await sentinel.prepare()
        for mode in ["stall", "eof", "failed"] {
            var calls = 0, failure: M4ResidentJSONWorker.Failure?
            let worker = M4ResidentJSONWorker(limits: short) { spec(mode) }
            worker.start { result in calls += 1; if case let .failure(error) = result { failure = error as? M4ResidentJSONWorker.Failure } }
            try await until("startup failure must settle") { calls > 0 }
            let expected: M4ResidentJSONWorker.Failure = mode == "stall" ? .startupTimeout : (mode == "eof" ? .eof : .unavailable)
            try expect(failure == expected && !worker.isReady, "startup reports its actual failure instead of relying on another timeout")
            try await until("owned failed child must actually exit") { !worker.hasOwnedProcess }
            try expect(calls == 1, "startup callback once after exit")
        }
        for mode in ["no_reply", "invalid", "wrong_id", "late", "closed_input", "flood"] {
            var selected = mode, calls = 0, successes = 0
            var observedFailure: M4ResidentJSONWorker.Failure?
            let limits = M4ResidentJSONWorker.Limits(startup: 1, request: 0.12, terminateGrace: mode == "late" ? 0.5 : 0.05)
            let worker = M4ResidentJSONWorker(limits: limits) { spec(selected) }
            try await worker.prepare()
            worker.request(id: "request", payload: [:]) { result in
                calls += 1
                if case .success = result { successes += 1 }
                if case let .failure(error) = result { observedFailure = error as? M4ResidentJSONWorker.Failure }
            }
            try await until("request failure must settle") { calls == 1 }
            let expected: M4ResidentJSONWorker.Failure = mode == "closed_input" ? .writeFailed : (["invalid", "wrong_id", "flood"].contains(mode) ? .invalidOutput : .requestTimeout)
            try expect(successes == 0 && !worker.isReady && observedFailure == expected, "bad or timed-out reply reports its exact failure")
            try await until("failed request retains ownership until actual exit") { !worker.hasOwnedProcess }
            selected = "healthy"
            try await worker.prepare()
            worker.request(id: "replacement", payload: [:]) { result in calls += 1; if case .success = result { successes += 1 } }
            try await until("restart accepts fresh reply") { calls == 2 }
            try expect(successes == 1, "only new generation succeeds")
            worker.stop(); try await until("healthy restart child exited") { !worker.hasOwnedProcess }
            try expect(calls == 2, "late data/termination cannot double-complete")
        }
        // Stop during startup; retry must not replace an unconfirmed live child.
        var mode = "stall", startCalls = 0, retryRejected = false
        let worker = M4ResidentJSONWorker(limits: .init(startup: 2, request: 1, terminateGrace: 0.1)) { spec(mode) }
        worker.start { _ in startCalls += 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        worker.stop()
        worker.start { result in if case .failure = result { retryRejected = true } }
        try expect(startCalls == 1 && retryRejected && worker.hasOwnedProcess, "stop settles once but retains live owned child")
        try await until("stop escalates only owned child and observes exit") { !worker.hasOwnedProcess }
        mode = "healthy"; try await worker.prepare()
        worker.stop(); try await until("replacement shutdown") { !worker.hasOwnedProcess }

        let duringRequest = M4ResidentJSONWorker(limits: short) { spec("no_reply") }
        try await duringRequest.prepare()
        var stoppedRequestCalls = 0
        duringRequest.request(id: "stop-this", payload: [:]) { result in
            if case .failure = result { stoppedRequestCalls += 1 }
        }
        duringRequest.stop()
        try expect(stoppedRequestCalls == 1, "stop settles in-flight request immediately")
        try await until("stopped request child exited") { !duringRequest.hasOwnedProcess }
        try expect(stoppedRequestCalls == 1, "exit after stop does not deliver another callback")

        // Actual wrappers use injected fake resources. Audio capture is lazy and never constructed.
        for (speechMode, kokoroMode) in [("stall", "failed"), ("failed", "stall")] {
            let longStartup = M4ResidentJSONWorker.Limits(startup: 3, request: 1, terminateGrace: 0.05)
            let speech = M4OnDeviceSpeechInput(limits: longStartup) { spec(speechMode) }
            let failingKokoro = M4ResidentKokoroWorker(limits: longStartup) { spec(kokoroMode) }
            var combinedDone = false, failed = false
            let started = Date()
            let combined = Task { @MainActor in
                do { try await prepareM4VoiceWorkers(speech: speech, kokoro: failingKokoro) }
                catch { failed = true }
                combinedDone = true
            }
            try await until("either startup failure cancels pending sibling prepare") { combinedDone }
            await combined.value
            try expect(failed && Date().timeIntervalSince(started) < 1 && !speech.isRunning,
                       "actual production pair helper surfaces either failure promptly without opening microphone")
            try await until("both failed/cancelled startup children exited") { !speech.hasOwnedProcess && !failingKokoro.hasOwnedProcess }
        }
        let kokoro = M4ResidentKokoroWorker(limits: short) { spec("healthy") }
        var ready = false, spoken = false
        kokoro.start { if case .success = $0 { ready = true } }
        try await until("Kokoro wrapper ready") { ready }
        kokoro.synthesize(text: "inert text") { if case let .success(value) = $0 { spoken = value.ok && value.generationMS == 1 } }
        try await until("Kokoro wrapper decodes response without playing audio") { spoken }
        kokoro.stop(); try await until("Kokoro fake child stopped") { !kokoro.hasOwnedProcess }
        try expect(sentinel.isReady, "another owned worker survives every timeout and stop")
        sentinel.stop(); try await until("sentinel child exited") { !sentinel.hasOwnedProcess }
    }
}

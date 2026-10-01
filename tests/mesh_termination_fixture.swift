import Foundation

@MainActor final class Drain {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}

@main struct Fixture {
    @MainActor static func main() async {
        let completed = MeshTerminationGate(deadlineNanoseconds: 500_000_000)
        let drain = Drain()
        var stopped = 0, cancelled = 0
        var replies: [MeshTerminationGate.Outcome] = []
        let begin = {
            completed.begin(stop: { stopped += 1 }, drain: { await drain.wait() },
                            cancel: { cancelled += 1 }, reply: { replies.append($0) })
        }
        begin(); begin()
        precondition(stopped == 1 && completed.isPending && replies.isEmpty)
        await Task.yield()
        drain.finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(replies == [.completed] && cancelled == 0 && !completed.isPending)
        begin()
        precondition(stopped == 1 && replies.count == 1)

        let deadline = MeshTerminationGate(deadlineNanoseconds: 20_000_000)
        let stalled = Drain()
        var deadlineReplies: [MeshTerminationGate.Outcome] = []
        deadline.begin(stop: { stopped += 1 }, drain: { await stalled.wait() },
                       cancel: { cancelled += 1 }, reply: { deadlineReplies.append($0) })
        // The drain deliberately ignores cancellation. A structured task group
        // would hang here; the independent deadline must still reply.
        try? await Task.sleep(nanoseconds: 80_000_000)
        precondition(deadlineReplies == [.deadline] && cancelled == 1)
        stalled.finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(deadlineReplies == [.deadline] && stopped == 2)
        // The app owns independent wake, camera and speech cleanup paths. Finishing wake cleanup
        // cannot silently abandon a pending camera teardown, including repeated Quit.
        let parallel = MeshTerminationGate(deadlineNanoseconds: 150_000_000)
        let wake = Drain(), camera = Drain(), speech = Drain()
        var parallelReplies: [MeshTerminationGate.Outcome] = [], parallelCancels = 0
        let quit = {
            parallel.begin(stop: {}, drain: {
                async let a: Void = wake.wait()
                async let b: Void = camera.wait()
                async let c: Void = speech.wait()
                _ = await (a, b, c)
            }, cancel: { parallelCancels += 1 }, reply: { parallelReplies.append($0) })
        }
        quit(); quit()
        try? await Task.sleep(nanoseconds: 20_000_000)
        wake.finish(); camera.finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(parallelReplies.isEmpty)
        try? await Task.sleep(nanoseconds: 180_000_000)
        precondition(parallelReplies == [.deadline] && parallelCancels == 1)
        speech.finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(parallelReplies == [.deadline])
        print("PASS: bounded termination, immediate revocation, repeated quit, stalled cleanup, late completion")
    }
}

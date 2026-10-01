import Foundation

/// AppKit keeps its run loop alive after terminateLater. Cleanup is deliberately
/// unstructured: a stalled operation cannot prevent the independent deadline.
@MainActor final class MeshTerminationGate {
    enum Outcome: String { case completed, deadline }
    private(set) var isPending = false
    private(set) var outcome: Outcome?
    private let deadlineNanoseconds: UInt64
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(deadlineNanoseconds: UInt64 = 12_000_000_000) {
        self.deadlineNanoseconds = deadlineNanoseconds
    }

    func begin(stop: () -> Void, drain: @escaping @MainActor () async -> Void,
               cancel: @escaping @MainActor () -> Void,
               reply: @escaping @MainActor (Outcome) -> Void) {
        guard !isPending, outcome == nil else { return }
        isPending = true
        stop() // Revoke inputs immediately, before returning terminateLater.
        cleanupTask = Task { [weak self] in
            await drain()
            self?.finish(.completed, cancel: cancel, reply: reply)
        }
        deadlineTask = Task { [weak self, deadlineNanoseconds] in
            do { try await Task.sleep(nanoseconds: deadlineNanoseconds) }
            catch { return }
            self?.finish(.deadline, cancel: cancel, reply: reply)
        }
    }

    private func finish(_ result: Outcome, cancel: () -> Void, reply: (Outcome) -> Void) {
        guard isPending, outcome == nil else { return }
        outcome = result; isPending = false
        deadlineTask?.cancel(); deadlineTask = nil
        if result == .deadline { cleanupTask?.cancel(); cancel() }
        cleanupTask = nil
        reply(result) // Exactly once, including repeated Quit and late completion.
    }
}

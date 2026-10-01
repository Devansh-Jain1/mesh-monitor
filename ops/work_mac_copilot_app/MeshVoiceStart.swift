import Combine
import Foundation

/// Owns the connection-to-microphone handoff. Opening UI constructs this inertly;
/// cancelled or superseded connections can never activate voice or publish errors.
@MainActor final class MeshVoiceStart: ObservableObject {
    @Published private(set) var isStarting = false
    private var generation = UUID()
    private var task: Task<Void, Never>?

    @discardableResult func begin(connect: @escaping @MainActor () async throws -> Void,
                                  mayActivate: @escaping @MainActor () -> Bool,
                                  activate: @escaping @MainActor () -> Void,
                                  failed: @escaping @MainActor (Error) -> Void) -> Bool {
        guard !isStarting else { return false }
        generation = UUID(); let token = generation
        isStarting = true
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await connect()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.task = nil; self.isStarting = false
                guard mayActivate() else { return }
                activate()
            } catch {
                guard let self, self.generation == token else { return }
                self.task = nil; self.isStarting = false
                guard !(error is CancellationError), !Task.isCancelled else { return }
                failed(error)
            }
        }
        return true
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isStarting = false
    }
    deinit { task?.cancel() }
}

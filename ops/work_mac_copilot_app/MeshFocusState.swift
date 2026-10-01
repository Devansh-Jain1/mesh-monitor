import Combine
import Foundation

enum MeshFocusAction: String, Codable { case done, snooze, help }

struct MeshFocusReceipt: Identifiable, Codable, Equatable {
    let id: UUID
    let occurredAt: Date
    let eventID: String
    let action: MeshFocusAction
    let snoozeUntil: Date?
    // These receipts may only be created from a direct user confirmation.
    let source: String
}

/// A local record of explicit user actions, not a scheduler or inferred progress.
/// No Calendar access. No implicit receipt from gaze, screen activity, or elapsed time.
@MainActor
final class MeshFocusState: ObservableObject {
    @Published private(set) var isPaused = true
    @Published private(set) var receipts: [MeshFocusReceipt] = []
    @Published private(set) var status = "Paused. Start a focus session when ready."
    @Published private(set) var persistenceError: String?

    private struct PauseRecord: Codable { let paused: Bool; let updatedAt: Date }
    private let directory: URL
    private let clock: () -> Date
    private var pauseURL: URL { directory.appendingPathComponent("focus-pause.json") }
    private var receiptsURL: URL { directory.appendingPathComponent("focus-receipts.jsonl") }
    private let archiveLimit = 2_000_000

    init(directory: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor", isDirectory: true)
        self.clock = clock
        restore()
    }

    /// Durable pause must also be checked by the app's actual sensor/action scheduler.
    @discardableResult
    func setPaused(_ paused: Bool) -> Bool {
        // A failed write must never prevent an immediate in-memory pause.
        if paused { isPaused = true }
        do {
            try prepareDirectory()
            let record = PauseRecord(paused: paused, updatedAt: clock())
            try JSONEncoder().encode(record).write(to: pauseURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pauseURL.path)
            isPaused = paused
            persistenceError = nil
            status = paused ? "Paused. Monitoring must remain stopped." : "Focus session active."
            return true
        } catch {
            isPaused = true
            persistenceError = "Could not save pause state: \(error.localizedDescription)"
            status = "Paused. Storage needs attention before resuming."
            return false
        }
    }

    /// The caller invokes this only when a user clicks or verbally confirms the action.
    /// Done records the user's report; it does not modify or delete the Calendar event.
    @discardableResult
    func confirm(_ action: MeshFocusAction, eventID: String, snoozeUntil: Date? = nil) -> Bool {
        let now = clock()
        guard !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Select a task before recording progress."
            return false
        }
        guard (action == .snooze && snoozeUntil != nil && snoozeUntil! > now)
                || (action != .snooze && snoozeUntil == nil) else {
            status = "Choose a future snooze time; other actions do not change timing."
            return false
        }
        let receipt = MeshFocusReceipt(id: UUID(), occurredAt: now, eventID: eventID,
                                       action: action, snoozeUntil: snoozeUntil, source: "human_confirmed")
        do {
            try prepareDirectory()
            var data = try JSONEncoder().encode(receipt)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: receiptsURL.path) {
                guard FileManager.default.createFile(atPath: receiptsURL.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: receiptsURL)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard size + UInt64(data.count) <= UInt64(archiveLimit) else {
                status = "The local receipt archive is full. No progress was recorded."
                return false
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            receipts.append(receipt)
            persistenceError = nil
            switch action {
            case .done: status = "Completion recorded as confirmed by you. Calendar is unchanged."
            case .snooze: status = "Snooze recorded locally. Calendar is unchanged."
            case .help: status = "Help requested. No task completion was inferred."
            }
            return true
        } catch {
            persistenceError = "Could not record progress: \(error.localizedDescription)"
            status = "Progress was not confirmed as saved."
            return false
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func restore() {
        do {
            if FileManager.default.fileExists(atPath: pauseURL.path) {
                isPaused = try JSONDecoder().decode(PauseRecord.self, from: Data(contentsOf: pauseURL)).paused
            }
            if FileManager.default.fileExists(atPath: receiptsURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: receiptsURL.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= archiveLimit else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let data = try Data(contentsOf: receiptsURL)
                // An incomplete/corrupt line is an error, never a fabricated successful receipt.
                receipts = try data.split(separator: 0x0A).map { try JSONDecoder().decode(MeshFocusReceipt.self, from: Data($0)) }
            }
            status = isPaused ? "Paused. Start a focus session when ready." : "Saved focus state restored."
        } catch {
            isPaused = true
            persistenceError = "Local focus state could not be restored: \(error.localizedDescription)"
            status = "Paused. Local focus storage needs attention."
        }
    }
}

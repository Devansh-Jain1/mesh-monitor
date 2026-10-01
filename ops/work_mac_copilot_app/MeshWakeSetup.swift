import Darwin
import Foundation

/// A short-lived, explicit setup request. Consuming it never arms or starts
/// anything itself; the caller owns that action after this returns true.
enum MeshWakeSetup {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor", isDirectory: true)
    }

    struct Request: Codable {
        let schema: String
        let id: String
        let date: String
        let createdAt: String
        let expiresAt: String
    }

    enum SetupError: LocalizedError {
        case invalidArguments, invalidRequest, unsafePublication
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Wake setup requires one explicit UUID argument."
            case .invalidRequest: "Wake setup request is invalid, expired, or belongs to another date."
            case .unsafePublication: "Wake setup could not safely consume or publish its private file."
            }
        }
    }

    static func consume(arguments: [String] = ProcessInfo.processInfo.arguments,
                        directory: URL = defaultDirectory, now: Date = Date()) throws -> Bool {
        let positions = arguments.indices.filter { arguments[$0] == "--consume-wake-setup" }
        guard !positions.isEmpty else { return false }
        guard positions.count == 1, let position = positions.first, position + 1 < arguments.count,
              let requestedID = UUID(uuidString: arguments[position + 1]) else {
            throw SetupError.invalidArguments
        }
        let descriptor = try MeshControlRoomFiles.directory(directory, create: false)
        defer { Darwin.close(descriptor) }
        let pending = "pending-wake-setup.json"
        guard let data = try MeshControlRoomFiles.read(pending, directoryFD: descriptor, maximumBytes: 4_096) else {
            return false // A consumed request never rearms on relaunch.
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: data),
              request.schema == "mesh.wake-setup.v1", UUID(uuidString: request.id) == requestedID,
              request.date == localDay(now),
              let created = parseISO(request.createdAt), let expires = parseISO(request.expiresAt),
              created <= now, now.timeIntervalSince(created) <= 120,
              expires > created, expires.timeIntervalSince(created) <= 120, now < expires else {
            throw SetupError.invalidRequest
        }
        let consumed = "consumed-wake-setup-\(requestedID.uuidString.lowercased()).json"
        guard renameatx_np(descriptor, pending, descriptor, consumed, UInt32(RENAME_EXCL)) == 0 else {
            throw SetupError.unsafePublication
        }
        // Recheck the actual renamed bytes. A concurrent replacement cannot
        // silently change the request being authorized.
        guard try MeshControlRoomFiles.read(consumed, directoryFD: descriptor, maximumBytes: 4_096) == data else {
            throw SetupError.unsafePublication
        }
        guard fsync(descriptor) == 0 else { throw SetupError.unsafePublication }
        return true
    }

    /// The caller supplies a bounded non-sensitive status and its timestamp.
    /// No request, session, or arming state is inferred from this status file.
    static func publishStatus(_ status: [String: Any], directory: URL = defaultDirectory) throws {
        try publish(status, name: "wake-readiness.json", directory: directory)
    }

    static func publishShutdown(_ status: [String: Any], directory: URL = defaultDirectory) throws {
        try publish(status, name: "shutdown-receipt.json", directory: directory)
    }

    private static func publish(_ status: [String: Any], name: String, directory: URL) throws {
        guard JSONSerialization.isValidJSONObject(status) else { throw SetupError.unsafePublication }
        let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
        guard data.count <= 16_384 else { throw SetupError.unsafePublication }
        let descriptor = try MeshControlRoomFiles.directory(directory, create: true)
        defer { Darwin.close(descriptor) }
        _ = try MeshControlRoomFiles.read(name, directoryFD: descriptor, maximumBytes: 16_384)
        let temporary = ".wake-readiness-\(UUID().uuidString.lowercased()).tmp"
        defer { _ = unlinkat(descriptor, temporary, 0) }
        try MeshControlRoomFiles.publish(data, name: temporary, directoryFD: descriptor)
        guard renameat(descriptor, temporary, descriptor, name) == 0,
              fsync(descriptor) == 0 else { throw SetupError.unsafePublication }
    }

    private static func parseISO(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

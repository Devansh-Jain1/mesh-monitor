import Foundation
import Darwin

/// Visible conversation text only. Original images, OCR, model evidence and audio
/// are not fields in this record, and restoring it never replays a backend turn.
struct MeshMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let role: String
    var text: String
    let evidence: String
    let createdAt: Date
    let savedExcerpt: Bool

    init(id: UUID = UUID(), role: String, text: String, evidence: String,
         createdAt: Date = Date(), savedExcerpt: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.evidence = evidence
        self.createdAt = createdAt; self.savedExcerpt = savedExcerpt
    }
}

enum MeshConversationHistoryError: LocalizedError {
    case unsafeStorage, invalidDocument, storageTooLarge, writeFailed
    var errorDescription: String? {
        switch self {
        case .unsafeStorage: "Conversation history needs private local storage. Existing data was left unchanged."
        case .invalidDocument: "Saved conversation history is invalid or unsupported. Existing data was left unchanged."
        case .storageTooLarge: "Saved conversation history exceeds the local size limit. Existing data was left unchanged."
        case .writeFailed: "The conversation remains visible, but its latest messages could not be saved on this Mac."
        }
    }
}

/// Atomic, bounded local snapshots: latest 60 messages within 1 MiB. Oversized
/// individual text becomes an explicitly labelled saved excerpt (128 KiB UTF-8).
/// Reading absent history is inert; directories and lock files are created only
/// for a real append. Invalid existing history is never silently overwritten.
struct MeshConversationHistory {
    static let maximumMessages = 60
    static let maximumFileBytes = 1_048_576
    static let maximumTextBytes = 131_072
    static let filename = "conversation-history.json"
    let directory: URL

    struct Snapshot: Codable, Sendable {
        let schemaVersion: Int
        let messages: [MeshMessage]
        var hasExcerpts: Bool { messages.contains(where: \.savedExcerpt) }
    }

    static func storageEnabled(arguments: [String], environment: [String: String]) -> Bool {
        !arguments.contains("--render-design-preview") && !arguments.contains("--render-ui")
            && environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
    }

    func load() throws -> Snapshot {
        guard let fd = try openDirectory(create: false) else { return Snapshot(schemaVersion: 1, messages: []) }
        defer { Darwin.close(fd) }
        guard let data = try read(in: fd) else { return Snapshot(schemaVersion: 1, messages: []) }
        return try decode(data)
    }

    @discardableResult
    func save(_ messages: [MeshMessage]) throws -> Snapshot {
        try persist(messages, clearing: false)
    }

    /// An explicit user clear may replace corrupt content, but never an unsafe
    /// file or directory. It does not delete or reset any connected agent history.
    func clear() throws {
        _ = try persist([], clearing: true)
    }

    private func persist(_ messages: [MeshMessage], clearing: Bool) throws -> Snapshot {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var retained: [MeshMessage] = [], byteCount = 64 // Versioned envelope and separators.
        for source in messages.suffix(Self.maximumMessages).reversed() {
            let message = Self.savedMessage(source)
            let bytes = try encoder.encode(message).count + 1
            guard byteCount + bytes <= Self.maximumFileBytes else { break }
            retained.append(message); byteCount += bytes
        }
        let snapshot = Snapshot(schemaVersion: 1, messages: retained.reversed())
        let encoded = try encoder.encode(snapshot)
        guard messages.isEmpty || !retained.isEmpty else { throw MeshConversationHistoryError.storageTooLarge }
        guard encoded.count <= Self.maximumFileBytes else { throw MeshConversationHistoryError.storageTooLarge }
        _ = try decode(encoded)
        guard let directoryFD = try openDirectory(create: true) else { throw MeshConversationHistoryError.unsafeStorage }
        defer { Darwin.close(directoryFD) }
        let lock = Darwin.openat(directoryFD, ".conversation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw MeshConversationHistoryError.unsafeStorage }
        defer { Darwin.close(lock) }
        _ = try metadata(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw MeshConversationHistoryError.writeFailed }
        defer { _ = flock(lock, LOCK_UN) }
        // Explicit clear checks custody without reading possibly corrupt/oversize
        // contents. Ordinary saving also validates the prior size and schema.
        if clearing { try validateClearTarget(in: directoryFD) }
        else if let existing = try read(in: directoryFD) { _ = try decode(existing) }
        try publish(encoded, in: directoryFD)
        return snapshot
    }

    private static func savedMessage(_ message: MeshMessage) -> MeshMessage {
        let role = bounded(message.role, bytes: 128)
        let text = bounded(message.text, bytes: maximumTextBytes)
        let evidence = bounded(message.evidence, bytes: 2_048)
        return MeshMessage(id: message.id, role: role, text: text, evidence: evidence,
            createdAt: message.createdAt,
            savedExcerpt: message.savedExcerpt || role != message.role || text != message.text || evidence != message.evidence)
    }

    private static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let notice = "\n[Saved excerpt — local history limit]"
        var prefix = Array(text.utf8.prefix(bytes - notice.utf8.count))
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return String(bytes: prefix, encoding: .utf8)! + notice
    }

    private func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= Self.maximumFileBytes else { throw MeshConversationHistoryError.storageTooLarge }
        do {
            let value = try JSONDecoder().decode(Snapshot.self, from: data)
            guard value.schemaVersion == 1, value.messages.count <= Self.maximumMessages,
                  Set(value.messages.map(\.id)).count == value.messages.count,
                  value.messages.allSatisfy({ message in
                      !message.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && message.role.utf8.count <= 128 && message.text.utf8.count <= Self.maximumTextBytes
                          && message.evidence.utf8.count <= 2_048 && message.createdAt.timeIntervalSince1970.isFinite
                  }) else { throw MeshConversationHistoryError.invalidDocument }
            return value
        } catch { throw MeshConversationHistoryError.invalidDocument }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else {
            throw MeshConversationHistoryError.unsafeStorage
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MeshConversationHistoryError.unsafeStorage }
        do {
            for component in directory.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.contains("/") else { throw MeshConversationHistoryError.unsafeStorage }
                var next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    if !create { Darwin.close(fd); return nil }
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw MeshConversationHistoryError.unsafeStorage }
                    next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw MeshConversationHistoryError.unsafeStorage }
                Darwin.close(fd); fd = next
            }
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
                  value.st_uid == getuid(), value.st_mode & 0o777 == 0o700 else { throw MeshConversationHistoryError.unsafeStorage }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func metadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(),
              value.st_mode & 0o777 == 0o600, value.st_nlink == 1, value.st_size >= 0 else { throw MeshConversationHistoryError.unsafeStorage }
        return value
    }

    private func read(in directoryFD: Int32) throws -> Data? {
        let fd = Darwin.openat(directoryFD, Self.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw MeshConversationHistoryError.unsafeStorage }
        defer { Darwin.close(fd) }
        guard try metadata(fd).st_size <= Self.maximumFileBytes else { throw MeshConversationHistoryError.storageTooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw MeshConversationHistoryError.unsafeStorage }
            guard data.count + count <= Self.maximumFileBytes else { throw MeshConversationHistoryError.storageTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func validateClearTarget(in directoryFD: Int32) throws {
        let fd = Darwin.openat(directoryFD, Self.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return }
        guard fd >= 0 else { throw MeshConversationHistoryError.unsafeStorage }
        defer { Darwin.close(fd) }
        _ = try metadata(fd)
    }

    private func publish(_ data: Data, in directoryFD: Int32) throws {
        let temporary = ".conversation-\(UUID().uuidString).tmp"
        let fd = Darwin.openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MeshConversationHistoryError.writeFailed }
        defer { Darwin.close(fd); _ = unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(fd, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MeshConversationHistoryError.writeFailed }
                remaining -= count; pointer = pointer.advanced(by: count)
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, Self.filename) == 0 else {
            throw MeshConversationHistoryError.writeFailed
        }
        guard fsync(directoryFD) == 0 else { throw MeshConversationHistoryError.writeFailed }
    }
}

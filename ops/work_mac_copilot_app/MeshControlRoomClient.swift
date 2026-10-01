import CryptoKit
import Darwin
import Foundation

enum MeshControlRoomError: LocalizedError {
    case unavailable, sessionRequired, busy, expired, invalid(String), unsafeFile, interrupted
    var errorDescription: String? {
        switch self {
        case .unavailable: "Control Room file bridge is unavailable or its readiness has expired."
        case .sessionRequired: "A verified physical M1 wake-button session is required for Control Room."
        case .busy: "Control Room already has a pending request."
        case .expired: "Control Room did not reply before this request expired. The scheduled bridge may take ten minutes."
        case let .invalid(reason): "Control Room bridge rejected data: \(reason)"
        case .unsafeFile: "Control Room bridge requires private owner-only files and directories without symlinks."
        case .interrupted: "Control Room request cancelled locally. Late replies will not be used."
        }
    }
}

struct MeshControlRoomReadiness: Codable {
    let schema: String
    let targetThreadID: String
    let responder: String
    let mode: String
    let available: Bool
    let updatedAt: String
    let expiresAt: String
    let expectedPollSeconds: Int
}

struct MeshControlRoomRequestFile: Codable {
    struct Context: Codable {
        let currentTask: String
        let homeBrief: String?
        let homeBriefDate: String?
        let homeBriefGeneratedAt: String?
    }
    struct Image: Codable {
        let mimeType: String
        let sha256: String
        let byteCount: Int
        let base64: String
    }
    let schema: String
    let source: String
    let targetThreadID: String
    let requestID: String
    let physicalSessionID: String
    let eventID: String
    let originalMessage: String
    let sourceEpoch: String
    let sessionGeneration: String
    let originalMessageSHA256: String
    let createdAt: String
    let expiresAt: String
    let proof: MeshM1ReturnOrigin
    let context: Context
    let images: [Image]
}

struct MeshControlRoomReplyFile: Codable {
    let schema: String
    let source: String
    let targetThreadID: String
    let requestID: String
    let physicalSessionID: String
    let eventID: String
    let originalMessageSHA256: String
    let sourceEpoch: String
    let sessionGeneration: String
    let createdAt: String
    let text: String
}

private struct MeshControlRoomCancellation: Codable {
    let schema: String
    let source: String
    let targetThreadID: String
    let requestID: String
    let physicalSessionID: String
    let eventID: String
    let originalMessageSHA256: String
    let createdAt: String
    let reason: String
}

struct MeshControlRoomSessionFile: Codable {
    let schema: String
    let source: String
    let targetThreadID: String
    let physicalSessionID: String
    let eventID: String
    var active: Bool
    let createdAt: String
    var updatedAt: String
    let expiresAt: String
    let proof: MeshM1ReturnOrigin
    let sourceEpoch: String
    let generation: String
    var livenessAt: String
}

/// Owner-private descriptor-relative file operations. Every path component is
/// opened without following symlinks; the bridge/subdirectories and files are
/// checked for exact owner permissions. No directory scanning or process launch.
enum MeshControlRoomFiles {
    static func directory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw MeshControlRoomError.unsafeFile }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MeshControlRoomError.unsafeFile }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.contains("/") else { throw MeshControlRoomError.unsafeFile }
                var next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw MeshControlRoomError.unsafeFile }
                    next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw MeshControlRoomError.unsafeFile }
                Darwin.close(fd)
                fd = next
            }
            try privateDirectory(fd)
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    static func subdirectory(_ name: String, in base: URL, create: Bool) throws -> Int32 {
        guard ["requests", "replies", "cancellations"].contains(name) else { throw MeshControlRoomError.unsafeFile }
        let parent = try directory(base, create: create)
        defer { Darwin.close(parent) }
        var fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT, create {
            guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw MeshControlRoomError.unsafeFile }
            fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw MeshControlRoomError.unsafeFile }
        do { try privateDirectory(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }

    static func read(_ name: String, directoryFD: Int32, maximumBytes: Int) throws -> Data? {
        guard validName(name) else { throw MeshControlRoomError.unsafeFile }
        let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw MeshControlRoomError.unsafeFile }
        defer { Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600,
              metadata.st_nlink == 1, metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else { throw MeshControlRoomError.unsafeFile }
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { return result }
            if count < 0, errno == EINTR { continue }
            guard count > 0, result.count + count <= maximumBytes else { throw MeshControlRoomError.unsafeFile }
            result.append(contentsOf: chunk.prefix(count))
        }
    }

    static func publish(_ data: Data, name: String, directoryFD: Int32, replaceSession: Bool = false) throws {
        guard validName(name) else { throw MeshControlRoomError.unsafeFile }
        if replaceSession {
            guard name == "session.json" else { throw MeshControlRoomError.unsafeFile }
            // Validate an existing target before an atomic owned-state replacement.
            _ = try read(name, directoryFD: directoryFD, maximumBytes: 16_384)
        }
        let temporary = ".\(UUID().uuidString.lowercased()).tmp"
        let fd = Darwin.openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MeshControlRoomError.unsafeFile }
        defer { Darwin.close(fd); _ = unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { raw in
            guard var cursor = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(fd, cursor, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MeshControlRoomError.unsafeFile }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }
        guard fsync(fd) == 0,
              renameatx_np(directoryFD, temporary, directoryFD, name, replaceSession ? 0 : UInt32(RENAME_EXCL)) == 0 else {
            throw MeshControlRoomError.unsafeFile
        }
        // File bytes are synchronized before exclusive publication; directory sync
        // improves durability but can be unsupported by a filesystem.
        _ = fsync(directoryFD)
    }

    /// Revoke only the matching current session; a stale client cannot deactivate
    /// a newer physical session. A nonblocking lock prevents interleaved updates.
    static func updateSession(_ record: MeshControlRoomSessionFile, in base: URL, matchingCurrent: Bool) throws {
        let directoryFD = try directory(base, create: !matchingCurrent)
        defer { Darwin.close(directoryFD) }
        let lockFD = Darwin.openat(directoryFD, ".session.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw MeshControlRoomError.unsafeFile }
        defer { Darwin.close(lockFD) }
        var metadata = stat()
        guard fstat(lockFD, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600,
              metadata.st_nlink == 1, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw MeshControlRoomError.unsafeFile
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        if matchingCurrent {
            guard let data = try read("session.json", directoryFD: directoryFD, maximumBytes: 16_384),
                  let current = try? JSONDecoder().decode(MeshControlRoomSessionFile.self, from: data),
                  current.physicalSessionID == record.physicalSessionID, current.eventID == record.eventID,
                  current.generation == record.generation,
                  current.targetThreadID == record.targetThreadID else { return }
        }
        try publish(JSONEncoder().encode(record), name: "session.json", directoryFD: directoryFD, replaceSession: true)
    }

    private static func privateDirectory(_ fd: Int32) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw MeshControlRoomError.unsafeFile
        }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

/// Degraded, scheduled file exchange with the existing Control Room task. This
/// never starts another agent/process, reads a private app pipe, or speaks audio.
@MainActor
final class MeshControlRoomClient: MeshAgentBackend {
    static let targetThreadID = "019fc1eb-2c9f-7250-ae5b-f733dee052ea"
    var onEvent: ((MeshAgentEvent) -> Void)?
    private(set) var connection: MeshAgentConnection?
    private(set) var hasSession = false
    private let baseDirectory: URL
    private let clock: () -> Date
    private let pollIntervalNanoseconds: UInt64
    private var proof: MeshM1ReturnEvent?
    private var sessionExpiresAt: Date?
    private var consumedProofIDs = Set<String>()
    private var generation = UUID()
    private var active: MeshControlRoomRequestFile?
    private var sending = false
    private var sessionRecord: MeshControlRoomSessionFile?
    private var allowedContext = MeshControlRoomRequestFile.Context(currentTask: "", homeBrief: nil, homeBriefDate: nil, homeBriefGeneratedAt: nil)

    init(baseDirectory: URL? = nil, clock: @escaping () -> Date = Date.init,
         pollInterval: TimeInterval = 2) {
        self.baseDirectory = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor/control-room", isDirectory: true)
        self.clock = clock
        // Production default is two seconds. Injection is for silent fixtures only.
        self.pollIntervalNanoseconds = UInt64(max(0.01, pollInterval) * 1_000_000_000)
    }

    /// Receives only the typed proof emitted by the physical M1 return gate.
    /// No session is restored from disk, readiness, a generic poll, or app launch.
    func beginSession(proof event: MeshM1ReturnEvent) throws {
        let now = clock()
        let origin = event.origin
        guard !consumedProofIDs.contains(event.receiptID),
              !event.sourceEpoch.isEmpty, event.sourceEpoch.count <= 256,
              origin.authenticated, origin.physical_pi, origin.previous_mode == "dark",
              origin.monitor_session_id.lowercased() == event.sessionID.uuidString.lowercased(),
              !origin.pi.isEmpty, origin.pi.count <= 64, !origin.peer_ip.isEmpty, origin.peer_ip.count <= 64,
              event.receiptID.hasPrefix(origin.pi + "-"),
              UUID(uuidString: String(event.receiptID.dropFirst(origin.pi.count + 1))) != nil,
              origin.detected_at.isFinite, origin.sent_at.isFinite,
              origin.sent_at >= origin.detected_at, origin.sent_at - origin.detected_at <= 30,
              (-1...30).contains(now.timeIntervalSince1970 - origin.detected_at),
              (-1...30).contains(now.timeIntervalSince1970 - origin.sent_at),
              abs(event.occurredAt.timeIntervalSince1970 - origin.detected_at) < 0.001,
              Calendar.current.isDate(event.occurredAt, inSameDayAs: now),
              let expires = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) else {
            throw MeshControlRoomError.sessionRequired
        }
        revokeSession()
        let record = MeshControlRoomSessionFile(schema: "mesh.control-room.session.v1", source: "MeshMonitor",
            targetThreadID: Self.targetThreadID, physicalSessionID: event.sessionID.uuidString.lowercased(),
            eventID: event.receiptID, active: true, createdAt: Self.iso(now), updatedAt: Self.iso(now),
            expiresAt: Self.iso(expires), proof: origin, sourceEpoch: event.sourceEpoch,
            generation: UUID().uuidString.lowercased(), livenessAt: Self.iso(now))
        try MeshControlRoomFiles.updateSession(record, in: baseDirectory, matchingCurrent: false)
        consumedProofIDs.insert(event.receiptID)
        proof = event
        sessionRecord = record
        sessionExpiresAt = expires
        hasSession = true
        onEvent?(.status("Physical wake session verified · Control Room uses a scheduled, degraded file bridge."))
    }

    /// Only uninterrupted samples from the same physical gate extend liveness.
    /// A saved file or generic desktop poll never restores a session.
    func refreshLiveness(_ update: MeshM1ReturnLiveness) throws {
        guard hasSession else { return }
        guard var record = sessionRecord,
              update.sessionID == proof?.sessionID, update.receiptID == proof?.receiptID,
              update.sourceEpoch == record.sourceEpoch,
              (-1...10).contains(clock().timeIntervalSince(update.observedAt)),
              let last = Self.parseISO(record.livenessAt),
              (-1...12).contains(clock().timeIntervalSince(last)),
              update.observedAt >= last.addingTimeInterval(-1) else {
            revokeSession(); throw MeshControlRoomError.sessionRequired
        }
        record.updatedAt = Self.iso(clock()); record.livenessAt = Self.iso(update.observedAt)
        do { try MeshControlRoomFiles.updateSession(record, in: baseDirectory, matchingCurrent: true) }
        catch { revokeSession(); throw error }
        sessionRecord = record
    }

    /// Only this allowlisted context can accompany original text. Generic captured
    /// observations, image inputs, conversation corpora, and raw audio are rejected.
    func setContext(currentTask: String, homeBrief: MeshHomeDayBrief? = nil) throws {
        guard currentTask.count <= 2_000 else { throw MeshControlRoomError.invalid("Current task exceeds 2000 characters.") }
        if let brief = homeBrief {
            guard brief.canNarrate, let generated = brief.generatedAt, generated <= clock(),
                  clock().timeIntervalSince(generated) <= 86_400,
                  Calendar.current.isDate(brief.date, inSameDayAs: clock()), brief.text.count <= 6_000 else {
                throw MeshControlRoomError.invalid("Home brief must be fresh and belong to today.")
            }
        }
        allowedContext = .init(currentTask: currentTask, homeBrief: homeBrief?.text,
            homeBriefDate: homeBrief.map { Self.iso($0.date) },
            homeBriefGeneratedAt: homeBrief?.generatedAt.map(Self.iso))
    }

    /// Read-only readiness check. Does not create even the bridge directories.
    func connect() async throws -> MeshAgentConnection {
        try Task.checkCancellation()
        let directory: Int32
        do { directory = try MeshControlRoomFiles.directory(baseDirectory, create: false) }
        catch { throw MeshControlRoomError.unavailable }
        defer { Darwin.close(directory) }
        guard let data = try MeshControlRoomFiles.read("readiness.json", directoryFD: directory, maximumBytes: 16_384),
              let ready = try? JSONDecoder().decode(MeshControlRoomReadiness.self, from: data),
              ready.schema == "mesh.control-room.readiness.v1", ready.targetThreadID == Self.targetThreadID,
              ready.responder == "ControlRoom", ready.mode == "scheduled_degraded", ready.available,
              (1...600).contains(ready.expectedPollSeconds),
              let updated = Self.parseISO(ready.updatedAt), let expires = Self.parseISO(ready.expiresAt),
              updated <= clock(), expires > clock(), expires > updated,
              expires.timeIntervalSince(updated) <= 900 else { throw MeshControlRoomError.unavailable }
        let result = MeshAgentConnection(threadID: Self.targetThreadID, authMode: "degraded_private_file_bridge")
        connection = result
        onEvent?(.connected(result))
        onEvent?(.status("Control Room ready · scheduled bridge may take 10 minutes; not realtime."))
        return result
    }

    func send(_ request: MeshAgentRequest) async throws -> MeshAgentReply {
        guard !sending, active == nil else { throw MeshControlRoomError.busy }
        sending = true
        defer { sending = false }
        let session = try currentSession()
        let token = generation
        _ = try await connect()
        try Task.checkCancellation()
        guard generation == token, proof?.sessionID == session.sessionID else { throw MeshControlRoomError.interrupted }
        guard !request.originalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.originalMessage.count <= 16_000 else {
            throw MeshControlRoomError.invalid("Message exceeds its limit or is empty.")
        }
        guard request.contextText.isEmpty, request.observationText.isEmpty, request.localImageURLs.isEmpty else {
            throw MeshControlRoomError.invalid("This bridge accepts original text and allowlisted task/Home context only. Images and observations are disabled.")
        }
        if let generated = allowedContext.homeBriefGeneratedAt.flatMap(Self.parseISO),
           clock().timeIntervalSince(generated) > 86_400 {
            throw MeshControlRoomError.invalid("The prepared Home context expired. Refresh its explicit context before sending.")
        }
        let created = Self.parseISO(Self.iso(clock()))!
        guard let sessionExpiresAt else { throw MeshControlRoomError.sessionRequired }
        let expires = min(created.addingTimeInterval(720), sessionExpiresAt)
        guard expires > created else { throw MeshControlRoomError.sessionRequired }
        let envelope = MeshControlRoomRequestFile(
            schema: "mesh.control-room.request.v1", source: "MeshMonitor", targetThreadID: Self.targetThreadID,
            requestID: UUID().uuidString.lowercased(), physicalSessionID: session.sessionID.uuidString.lowercased(),
            eventID: session.receiptID, originalMessage: request.originalMessage,
            sourceEpoch: session.sourceEpoch, sessionGeneration: sessionRecord!.generation,
            originalMessageSHA256: Self.hash(Data(request.originalMessage.utf8)), createdAt: Self.iso(created), expiresAt: Self.iso(expires),
            proof: session.origin, context: allowedContext, images: []
        )
        // Directories are created only for an authorized physical-session send.
        for name in ["requests", "replies", "cancellations"] {
            let fd = try MeshControlRoomFiles.subdirectory(name, in: baseDirectory, create: true)
            Darwin.close(fd)
        }
        active = envelope
        do {
            try Task.checkCancellation()
            let requests = try MeshControlRoomFiles.subdirectory("requests", in: baseDirectory, create: false)
            defer { Darwin.close(requests) }
            try MeshControlRoomFiles.publish(JSONEncoder().encode(envelope), name: envelope.requestID + ".json", directoryFD: requests)
        } catch { active = nil; throw error }
        onEvent?(.status("Awaiting Control Room · scheduled bridge may take 10 minutes."))
        return try await withTaskCancellationHandler(operation: {
            do {
                while true {
                    try Task.checkCancellation()
                    guard generation == token, active?.requestID == envelope.requestID,
                          try currentSession().sessionID == session.sessionID else { throw MeshControlRoomError.interrupted }
                    guard clock() < expires else { throw MeshControlRoomError.expired }
                    let replies = try MeshControlRoomFiles.subdirectory("replies", in: baseDirectory, create: false)
                    let bytes: Data?
                    do { bytes = try MeshControlRoomFiles.read(envelope.requestID + ".json", directoryFD: replies, maximumBytes: 128_000) }
                    catch { Darwin.close(replies); throw error }
                    Darwin.close(replies)
                    if let bytes {
                        let response = try JSONDecoder().decode(MeshControlRoomReplyFile.self, from: bytes)
                        try validate(response, request: envelope)
                        try Task.checkCancellation()
                        guard generation == token, active?.requestID == envelope.requestID else { throw MeshControlRoomError.interrupted }
                        active = nil
                        onEvent?(.status("Control Room reply received · scheduled bridge."))
                        return MeshAgentReply(text: response.text, threadID: Self.targetThreadID, turnID: envelope.requestID)
                    }
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                }
            } catch {
                cancelPending(id: envelope.requestID, reason: error is CancellationError ? "task_cancelled" : "request_failed_or_expired")
                throw error
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelPending(id: envelope.requestID, reason: "task_cancelled") }
        })
    }

    func cancelCurrentTurn() async { cancelPending(reason: "user_cancelled") }

    func revokeSession() {
        generation = UUID()
        cancelPending(reason: "session_revoked")
        if var record = sessionRecord {
            record.active = false
            record.updatedAt = Self.iso(clock())
            do {
                try MeshControlRoomFiles.updateSession(record, in: baseDirectory, matchingCurrent: true)
            } catch {
                onEvent?(.status("Control Room session revoked locally, but its inactive marker could not be saved. Late replies remain blocked."))
            }
        }
        proof = nil
        sessionRecord = nil
        sessionExpiresAt = nil
        hasSession = false
        connection = nil
        allowedContext = .init(currentTask: "", homeBrief: nil, homeBriefDate: nil, homeBriefGeneratedAt: nil)
    }

    func disconnect() { revokeSession() }

    private func currentSession() throws -> MeshM1ReturnEvent {
        guard hasSession, let proof, let sessionExpiresAt, clock() < sessionExpiresAt,
              let sessionRecord, sessionRecord.sourceEpoch == proof.sourceEpoch,
              let liveness = Self.parseISO(sessionRecord.livenessAt),
              (-1...12).contains(clock().timeIntervalSince(liveness)) else {
            throw MeshControlRoomError.sessionRequired
        }
        return proof
    }

    private func validate(_ reply: MeshControlRoomReplyFile, request: MeshControlRoomRequestFile) throws {
        guard reply.schema == "mesh.control-room.reply.v1", reply.source == "ControlRoom",
              reply.targetThreadID == Self.targetThreadID, reply.requestID == request.requestID,
              reply.physicalSessionID == request.physicalSessionID, reply.eventID == request.eventID,
              reply.originalMessageSHA256 == request.originalMessageSHA256,
              reply.sourceEpoch == request.sourceEpoch, reply.sessionGeneration == request.sessionGeneration,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reply.text.count <= 16_000,
              let replied = Self.parseISO(reply.createdAt), let created = Self.parseISO(request.createdAt),
              let expires = Self.parseISO(request.expiresAt), replied >= created, replied <= expires,
              replied <= clock(), clock() < expires else {
            throw MeshControlRoomError.invalid("Reply correlation, freshness, or text limits do not match the active request.")
        }
    }

    private func cancelPending(id: String? = nil, reason: String) {
        guard let pending = active, id == nil || pending.requestID == id else { return }
        active = nil // Revoke locally even if the disk marker cannot be written.
        let marker = MeshControlRoomCancellation(schema: "mesh.control-room.cancel.v1", source: "MeshMonitor",
            targetThreadID: Self.targetThreadID, requestID: pending.requestID, physicalSessionID: pending.physicalSessionID,
            eventID: pending.eventID, originalMessageSHA256: pending.originalMessageSHA256,
            createdAt: Self.iso(clock()), reason: reason)
        do {
            let fd = try MeshControlRoomFiles.subdirectory("cancellations", in: baseDirectory, create: false)
            defer { Darwin.close(fd) }
            try MeshControlRoomFiles.publish(JSONEncoder().encode(marker), name: pending.requestID + ".json", directoryFD: fd)
            onEvent?(.status("Control Room request cancelled locally; late replies will be ignored."))
        } catch {
            onEvent?(.status("Cancelled locally, but the Control Room cancellation marker could not be saved. Late replies remain blocked."))
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func parseISO(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

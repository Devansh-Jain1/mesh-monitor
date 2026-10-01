import Darwin
import Foundation

@main
private struct MeshControlRoomFixtureTests {
    @MainActor
    static func main() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/mesh-control-room-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        var now = ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!
        let client = MeshControlRoomClient(baseDirectory: base, clock: { now }, pollInterval: 0.01)
        assert(!FileManager.default.fileExists(atPath: base.path) && !client.hasSession)
        do { _ = try await client.connect(); assertionFailure("Missing readiness must fail") } catch { }
        assert(!FileManager.default.fileExists(atPath: base.path), "Connect must not create directories")

        func publish<T: Encodable>(_ value: T, name: String, folder: String? = nil, root: URL? = nil) throws {
            let directory = root ?? base
            let fd = try folder.map { try MeshControlRoomFiles.subdirectory($0, in: directory, create: true) }
                ?? MeshControlRoomFiles.directory(directory, create: true)
            defer { Darwin.close(fd) }
            try MeshControlRoomFiles.publish(JSONEncoder().encode(value), name: name, directoryFD: fd)
        }
        let readiness = MeshControlRoomReadiness(schema: "mesh.control-room.readiness.v1", targetThreadID: MeshControlRoomClient.targetThreadID,
            responder: "ControlRoom", mode: "scheduled_degraded", available: true,
            updatedAt: MeshControlRoomClient.iso(now), expiresAt: MeshControlRoomClient.iso(now.addingTimeInterval(720)), expectedPollSeconds: 600)
        try publish(readiness, name: "readiness.json")
        let connection = try await client.connect()
        assert(connection.threadID == MeshControlRoomClient.targetThreadID && connection.authMode.contains("degraded"))
        assert(!FileManager.default.fileExists(atPath: base.appendingPathComponent("requests").path))
        do { _ = try await client.send(MeshAgentRequest(originalMessage: "hello")); assertionFailure("No physical session") } catch { }

        func proof(physical: Bool = true, session: UUID = UUID(), detected: Date? = nil, sourceEpoch: String = "receiver-1") -> MeshM1ReturnEvent {
            let detected = detected ?? now
            let origin = MeshM1ReturnOrigin(authenticated: true, physical_pi: physical, peer_ip: "192.0.2.10", pi: "raspberrypi",
                detected_at: detected.timeIntervalSince1970, sent_at: detected.timeIntervalSince1970,
                previous_mode: "dark", monitor_session_id: session.uuidString.lowercased())
            return MeshM1ReturnEvent(receiptID: "raspberrypi-\(UUID().uuidString.lowercased())", sessionID: session, occurredAt: detected, origin: origin, sourceEpoch: sourceEpoch)
        }
        do { try client.beginSession(proof: proof(physical: false)); assertionFailure("Invalid physical origin") } catch { }
        do { try client.beginSession(proof: proof(detected: now.addingTimeInterval(-31))); assertionFailure("Stale physical origin") } catch { }
        do { try client.beginSession(proof: proof(sourceEpoch: "")); assertionFailure("Missing receiver epoch") } catch { }
        let physical = proof()
        try client.beginSession(proof: physical)
        assert(client.hasSession)
        let sessionPath = base.appendingPathComponent("session.json")
        var session = try JSONDecoder().decode(MeshControlRoomSessionFile.self, from: Data(contentsOf: sessionPath))
        assert(session.active && session.eventID == physical.receiptID)
        assert(session.sourceEpoch == "receiver-1" && !session.generation.isEmpty)
        assert(MeshControlRoomClient.parseISO(session.livenessAt) == now)

        for rejected in [
            MeshAgentRequest(originalMessage: "hello", contextText: "arbitrary context"),
            MeshAgentRequest(originalMessage: "hello", observationText: "screen observation"),
            MeshAgentRequest(originalMessage: "hello", localImageURLs: [URL(fileURLWithPath: "/not-read.png")])
        ] {
            do { _ = try await client.send(rejected); assertionFailure("Evidence is disabled in v1") } catch { }
        }
        assert(!FileManager.default.fileExists(atPath: base.appendingPathComponent("requests").path))
        let home = MeshHomeDayBrief(state: .ready, date: now, generatedAt: now, text: "Today's synthetic Home fixture.", eventCount: 0)
        try client.setContext(currentTask: "Finish the fixture", homeBrief: home)

        func waitForRequest(excluding: Set<String> = []) async throws -> MeshControlRoomRequestFile {
            for _ in 0..<200 {
                let folder = base.appendingPathComponent("requests")
                if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                   let name = names.first(where: { $0.hasSuffix(".json") && !excluding.contains(String($0.dropLast(5))) }) {
                    return try JSONDecoder().decode(MeshControlRoomRequestFile.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw MeshControlRoomError.invalid("Fixture request not written in time")
        }
        func reply(_ request: MeshControlRoomRequestFile, text: String = "The synthetic reply.", hash: String? = nil,
                   thread: String? = nil, created: String? = nil,
                   epoch: String? = nil, sessionGeneration: String? = nil) -> MeshControlRoomReplyFile {
            MeshControlRoomReplyFile(schema: "mesh.control-room.reply.v1", source: "ControlRoom",
                targetThreadID: thread ?? request.targetThreadID, requestID: request.requestID,
                physicalSessionID: request.physicalSessionID, eventID: request.eventID,
                originalMessageSHA256: hash ?? request.originalMessageSHA256,
                sourceEpoch: epoch ?? request.sourceEpoch, sessionGeneration: sessionGeneration ?? request.sessionGeneration,
                createdAt: created ?? request.createdAt, text: text)
        }

        let exact = "  What does this mean?\nKeep these spaces.  "
        let first = Task { try await client.send(MeshAgentRequest(originalMessage: exact)) }
        let request = try await waitForRequest()
        assert(request.originalMessage == exact && request.originalMessageSHA256 == MeshControlRoomClient.hash(Data(exact.utf8)))
        assert(request.images.isEmpty && request.context.currentTask == "Finish the fixture" && request.context.homeBrief == home.text)
        assert(request.proof.physical_pi && request.physicalSessionID == physical.sessionID.uuidString.lowercased())
        assert(request.sourceEpoch == "receiver-1" && request.sessionGeneration == session.generation)
        assert(MeshControlRoomClient.parseISO(request.expiresAt)!.timeIntervalSince(MeshControlRoomClient.parseISO(request.createdAt)!) == 720)
        do { _ = try await client.send(MeshAgentRequest(originalMessage: "second concurrent request")); assertionFailure("One outstanding only") } catch { }
        try publish(reply(request), name: request.requestID + ".json", folder: "replies")
        let answer = try await first.value
        assert(answer.text == "The synthetic reply." && answer.threadID == MeshControlRoomClient.targetThreadID)

        var seen = Set([request.requestID])
        // Correlation and freshness failures generate cancellation, not a usable reply.
        for mismatch in ["hash", "thread", "future", "text_limit", "epoch", "generation"] {
            let turn = Task { try await client.send(MeshAgentRequest(originalMessage: "validate \(mismatch)")) }
            let next = try await waitForRequest(excluding: seen)
            seen.insert(next.requestID)
            let response = reply(next, text: mismatch == "text_limit" ? String(repeating: "a", count: 16_001) : "test",
                                 hash: mismatch == "hash" ? "wrong" : nil,
                                 thread: mismatch == "thread" ? "another-task" : nil,
                                 created: mismatch == "future" ? MeshControlRoomClient.iso(now.addingTimeInterval(1)) : nil,
                                 epoch: mismatch == "epoch" ? "restarted-receiver" : nil,
                                 sessionGeneration: mismatch == "generation" ? UUID().uuidString.lowercased() : nil)
            try publish(response, name: next.requestID + ".json", folder: "replies")
            do { _ = try await turn.value; assertionFailure("Mismatched reply must fail") } catch { }
            assert(FileManager.default.fileExists(atPath: base.appendingPathComponent("cancellations/\(next.requestID).json").path))
        }

        let cancelled = Task { try await client.send(MeshAgentRequest(originalMessage: "cancel this")) }
        let pending = try await waitForRequest(excluding: seen)
        seen.insert(pending.requestID)
        client.revokeSession()
        assert(!client.hasSession)
        session = try JSONDecoder().decode(MeshControlRoomSessionFile.self, from: Data(contentsOf: sessionPath))
        assert(!session.active)
        try publish(reply(pending, text: "Too late; never return this."), name: pending.requestID + ".json", folder: "replies")
        do { _ = try await cancelled.value; assertionFailure("Revoked session must discard late reply") } catch { }
        do { try client.beginSession(proof: physical); assertionFailure("Old proof cannot reactivate a revoked session") } catch { }
        let restarted = MeshControlRoomClient(baseDirectory: base, clock: { now }, pollInterval: 0.01)
        assert(!restarted.hasSession)
        _ = try await restarted.connect()
        assert(!restarted.hasSession, "Readiness and saved session cannot automatically reactivate a client")

        // A fresh watcher observation updates only this session's liveness/generation.
        func heartbeat(_ event: MeshM1ReturnEvent, sessionID: UUID? = nil, sourceEpoch: String? = nil,
                       receiptID: String? = nil, observedAt: Date? = nil) -> MeshM1ReturnLiveness {
            MeshM1ReturnLiveness(sessionID: sessionID ?? event.sessionID,
                receiptID: receiptID ?? event.receiptID, sourceEpoch: sourceEpoch ?? event.sourceEpoch,
                observedAt: observedAt ?? now)
        }
        let liveProof = proof()
        try client.beginSession(proof: liveProof)
        let originalGeneration = try JSONDecoder().decode(MeshControlRoomSessionFile.self, from: Data(contentsOf: sessionPath)).generation
        now = now.addingTimeInterval(6)
        try client.refreshLiveness(heartbeat(liveProof))
        session = try JSONDecoder().decode(MeshControlRoomSessionFile.self, from: Data(contentsOf: sessionPath))
        assert(session.active && session.generation == originalGeneration && session.sourceEpoch == liveProof.sourceEpoch)
        assert(MeshControlRoomClient.parseISO(session.livenessAt) == now)
        let liveTurn = Task { try await client.send(MeshAgentRequest(originalMessage: "fresh watcher observation")) }
        let liveRequest = try await waitForRequest(excluding: seen)
        seen.insert(liveRequest.requestID)
        try publish(reply(liveRequest), name: liveRequest.requestID + ".json", folder: "replies")
        _ = try await liveTurn.value

        // Wrong ownership, epoch, or original physical receipt revoke immediately.
        for mismatch in ["session", "epoch", "receipt", "future", "stale", "backwards", "gap"] {
            let event = proof()
            try client.beginSession(proof: event)
            if mismatch == "gap" { now = now.addingTimeInterval(13) }
            let observed = mismatch == "future" ? now.addingTimeInterval(2) :
                (mismatch == "stale" ? now.addingTimeInterval(-11) :
                    (mismatch == "backwards" ? now.addingTimeInterval(-2) : now))
            do {
                try client.refreshLiveness(heartbeat(event,
                    sessionID: mismatch == "session" ? UUID() : nil,
                    sourceEpoch: mismatch == "epoch" ? "receiver-restarted" : nil,
                    receiptID: mismatch == "receipt" ? "raspberrypi-\(UUID().uuidString.lowercased())" : nil,
                    observedAt: observed))
                assertionFailure("Mismatched liveness must revoke")
            } catch { }
            assert(!client.hasSession)
            session = try JSONDecoder().decode(MeshControlRoomSessionFile.self, from: Data(contentsOf: sessionPath))
            assert(!session.active)
        }

        // No heartbeat can leave an old physical session authorized indefinitely.
        try client.beginSession(proof: proof())
        now = now.addingTimeInterval(13)
        do { _ = try await client.send(MeshAgentRequest(originalMessage: "stale heartbeat")); assertionFailure("Stale heartbeat blocks request") } catch { }
        let lateProof = proof()
        try client.beginSession(proof: lateProof)
        let staleTurn = Task { try await client.send(MeshAgentRequest(originalMessage: "pending while watcher disappears")) }
        let staleRequest = try await waitForRequest(excluding: seen)
        seen.insert(staleRequest.requestID)
        now = now.addingTimeInterval(13)
        try publish(reply(staleRequest, text: "Late reply after heartbeat expired."), name: staleRequest.requestID + ".json", folder: "replies")
        do { _ = try await staleTurn.value; assertionFailure("Stale heartbeat blocks late reply") } catch { }
        assert(FileManager.default.fileExists(atPath: base.appendingPathComponent("cancellations/\(staleRequest.requestID).json").path))

        let cancellableProof = proof()
        try client.beginSession(proof: cancellableProof)
        let taskCancelled = Task { try await client.send(MeshAgentRequest(originalMessage: "task cancellation")) }
        let taskPending = try await waitForRequest(excluding: seen)
        seen.insert(taskPending.requestID)
        taskCancelled.cancel()
        do { _ = try await taskCancelled.value; assertionFailure("Cancelled task must fail") } catch { }
        assert(FileManager.default.fileExists(atPath: base.appendingPathComponent("cancellations/\(taskPending.requestID).json").path))

        let expired = Task { try await client.send(MeshAgentRequest(originalMessage: "timeout")) }
        let expiring = try await waitForRequest(excluding: seen)
        // Keep liveness healthy so this tests request expiry, not the heartbeat guard.
        for _ in 0..<120 {
            now = now.addingTimeInterval(6)
            try client.refreshLiveness(heartbeat(cancellableProof))
        }
        now = now.addingTimeInterval(1)
        try client.refreshLiveness(heartbeat(cancellableProof))
        do { _ = try await expired.value; assertionFailure("12-minute request expiry") }
        catch MeshControlRoomError.expired { }
        catch { throw error }
        assert(FileManager.default.fileExists(atPath: base.appendingPathComponent("cancellations/\(expiring.requestID).json").path))

        // A prior instance cannot revoke a newer physical session record.
        let newer = MeshControlRoomClient(baseDirectory: base, clock: { now }, pollInterval: 0.01)
        let newerProof = proof()
        try newer.beginSession(proof: newerProof)
        client.revokeSession()
        session = try JSONDecoder().decode(MeshControlRoomSessionFile.self, from: Data(contentsOf: sessionPath))
        assert(session.active && session.physicalSessionID == newerProof.sessionID.uuidString.lowercased())
        newer.revokeSession()
        session = try JSONDecoder().decode(MeshControlRoomSessionFile.self, from: Data(contentsOf: sessionPath))
        assert(!session.active)

        // File safety tests use only this private temporary fixture directory.
        let folder = try MeshControlRoomFiles.directory(base, create: false)
        defer { Darwin.close(folder) }
        do { try MeshControlRoomFiles.publish(Data("replace".utf8), name: "readiness.json", directoryFD: folder); assertionFailure("Exclusive publication must not overwrite") } catch { }
        let readinessPath = base.appendingPathComponent("readiness.json")
        assert(try! JSONDecoder().decode(MeshControlRoomReadiness.self, from: Data(contentsOf: readinessPath)).mode == "scheduled_degraded")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readinessPath.path)
        do { _ = try MeshControlRoomFiles.read("readiness.json", directoryFD: folder, maximumBytes: 16_384); assertionFailure("Public file permissions") } catch { }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readinessPath.path)
        let linked = base.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: readinessPath)
        do { _ = try MeshControlRoomFiles.read("linked.json", directoryFD: folder, maximumBytes: 16_384); assertionFailure("Symlink file") } catch { }
        let sub = base.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: base)
        do { let bad = try MeshControlRoomFiles.directory(sub, create: false); Darwin.close(bad); assertionFailure("Symlink directory") } catch { }
        print("PASS: scheduled readiness only, verified epoch/session and continuous liveness gate, stale-heartbeat request/reply rejection, wrong-heartbeat revocation, exact text/hash, context allowlist/images disabled, request correlation, one outstanding, TTL, cancellation/late reply suppression, session revocation, private modes/no symlinks/exclusive writes. Temporary synthetic files only; no live bridge request, network, process, camera, or audio.")
    }
}

import Combine
import Foundation

struct MeshMorningBriefArtifact: Codable, Equatable {
    let schema: String
    let id: String
    let calendar: String
    let date: String
    let timezone: String
    let generatedAt: String
    let notBefore: String
    let text: String
}

struct MeshMorningAttemptReceipt: Codable, Identifiable, Equatable {
    let id: UUID
    let key: String
    let briefID: String
    let occurredAt: Date
    let arrivalID: UUID?
    let manualReplay: Bool
    /// Optional for backward-compatible decoding of the initial receipt format.
    let trigger: String?
    /// Written before invoking audio. This is not evidence that audio completed.
    let outcome: String
}

private enum MeshMorningError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case let .invalid(message): return message }
    }
}

/// Pure local session state: no EventKit, camera, model, timer, or audio calls.
/// Preparation may happen the night before an explicitly selected day. Delivery
/// requires the actual local day. Camera/automatic arrivals are eligible after
/// 09:00; a proven explicit user Return/Home request may speak earlier. Neither
/// path queues speech on a timer. Signals do not establish identity or waking.
@MainActor
final class MeshMorningState: ObservableObject {
    enum DeliveryState: String { case idle, attempted, finished, failed }

    @Published var intendedDate: Date {
        didSet {
            if dayString(intendedDate) != dayString(oldValue) {
                armed = false
                artifact = nil
                preparedBrief = nil
                status = "Date changed. Prepare Home for the selected day, then arm again."
                deliveryState = .idle
            }
        }
    }
    @Published private(set) var armed = false
    @Published private(set) var status = "Choose a morning date and prepare its Home plan."
    @Published private(set) var preparedBrief: String?
    @Published private(set) var deliveryState: DeliveryState = .idle
    @Published private(set) var lastAttempt: MeshMorningAttemptReceipt?
    @Published private(set) var storageError: String?

    /// Root owns durable pause and must wire this check to MeshFocusState.
    /// Fail closed until the owner supplies that connection.
    var isPaused: () -> Bool = { true }
    var onDelivery: ((String) -> Void)?

    let timeZone: TimeZone
    private let directory: URL
    private let clock: () -> Date
    private var localCalendar: Calendar
    private var artifact: MeshMorningBriefArtifact?
    private var attemptedKeys = Set<String>()
    private var consumedArrivals = Set<UUID>()
    private var receiptsURL: URL { directory.appendingPathComponent("morning-receipts.jsonl") }
    var defaultBriefURL: URL { directory.appendingPathComponent("morning-brief.json") }
    var selectedDay: String { dayString(intendedDate) }
    var hasAttemptForSelectedDay: Bool { attemptedKeys.contains(dayKey) }
    var notBefore: Date? { artifact.flatMap { parseISO($0.notBefore) } }
    /// Read-only context export for the agreed task/brief-only Control Room bridge.
    /// Event count is not represented by the external artifact and remains unknown.
    var contextBrief: MeshHomeDayBrief? {
        guard let artifact, dayString(clock()) == selectedDay,
              (try? validate(artifact, delivering: false)) != nil,
              let generatedAt = parseISO(artifact.generatedAt) else { return nil }
        return MeshHomeDayBrief(state: .ready, date: intendedDate, generatedAt: generatedAt,
                                text: artifact.text, eventCount: 0)
    }
    private var dayKey: String { "Home|\(timeZone.identifier)|\(selectedDay)" }

    init(directory: URL? = nil, timeZone: TimeZone = .current, clock: @escaping () -> Date = Date.init) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor", isDirectory: true)
        self.timeZone = timeZone
        self.clock = clock
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        localCalendar = calendar
        intendedDate = clock()
        restoreReceipts()
        // A launch never restores an armed session, regardless of prior app state.
        armed = false
    }

    @discardableResult
    func prepare(_ brief: MeshHomeDayBrief) -> Bool {
        guard brief.canNarrate, let generatedAt = brief.generatedAt else {
            return preparationFailed("Home has no valid prepared brief. Refresh it before arming.")
        }
        guard dayString(brief.date) == selectedDay else {
            return preparationFailed("The Home brief belongs to another date. Refresh the selected morning.")
        }
        let availableFrom = max(localCalendar.startOfDay(for: intendedDate), clock())
        let envelope = MeshMorningBriefArtifact(
            schema: "mesh.morning-brief.v1", id: "home:\(selectedDay):\(timeZone.identifier)",
            calendar: "Home", date: selectedDay, timezone: timeZone.identifier,
            generatedAt: iso(generatedAt), notBefore: iso(availableFrom), text: brief.text
        )
        return prepare(envelope)
    }

    @discardableResult
    func prepare(_ envelope: MeshMorningBriefArtifact) -> Bool {
        armed = false
        do {
            try validate(envelope, delivering: false)
            artifact = envelope
            preparedBrief = envelope.text
            deliveryState = .idle
            status = hasAttemptForSelectedDay
                ? "A greeting was already attempted for this day. Automatic replay is blocked."
                : "Home plan prepared for \(selectedDay). Explicit user return can speak when ready; automatic arrivals wait until 9 AM. Not armed."
            return true
        } catch {
            return preparationFailed(error.localizedDescription)
        }
    }

    /// Reads an explicitly requested local artifact. Never rewrites it or fetches it.
    @discardableResult
    func importBrief(from url: URL? = nil) -> Bool {
        do {
            return prepare(try readArtifact(url ?? defaultBriefURL))
        } catch {
            return preparationFailed("Morning brief could not be imported: \(error.localizedDescription)")
        }
    }

    /// For an armed session waiting for a publisher. Unlike explicit preparation,
    /// a valid refresh preserves the existing arm. An absent file preserves any
    /// valid cached brief; a present but invalid file fails closed and disarms.
    @discardableResult
    func refreshQueuedBrief(from url: URL? = nil) -> Bool {
        guard deliveryState != .attempted else {
            status = "A morning delivery is still in progress; its brief was not replaced."
            return false
        }
        do {
            let envelope = try readArtifact(url ?? defaultBriefURL)
            try validate(envelope, delivering: false)
            artifact = envelope
            preparedBrief = envelope.text
            status = armed
                ? "Home plan received. Armed; waiting for the selected return. Automatic arrivals wait until 9 AM."
                : "Home plan received. Arm explicitly when ready."
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            if let artifact {
                do { try validate(artifact, delivering: false) }
                catch { return preparationFailed(error.localizedDescription) }
                status = armed
                    ? "Queued file not present. Keeping the valid prepared Home plan; still armed."
                    : "Queued file not present. Keeping the valid prepared Home plan; not armed."
            } else {
                status = armed
                    ? "Armed and waiting for the Home brief. Return again after it is ready; no speech is queued."
                    : "Waiting for the Home brief. Morning is not armed."
            }
            return false
        } catch {
            return preparationFailed("Queued Home brief is invalid or unreadable: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func arm() -> Bool {
        armed = false
        guard !isPaused() else { status = "Monitoring is paused. Resume explicitly before arming morning."; return false }
        guard deliveryState != .attempted else { status = "A morning delivery is still in progress."; return false }
        guard storageError == nil else { status = "Morning receipt storage needs attention. Automatic greeting is blocked."; return false }
        guard onDelivery != nil else { status = "No local audio delivery is connected. Morning is not armed."; return false }
        guard let artifact else { status = "Prepare the selected Home plan before arming."; return false }
        do { try validate(artifact, delivering: false) }
        catch { status = error.localizedDescription; return false }
        guard !hasAttemptForSelectedDay else {
            status = "A greeting was already attempted for this date. Use explicit replay if needed."
            return false
        }
        armed = true
        status = "Armed for \(selectedDay). Waiting for the selected return; automatic arrivals wait until 9 AM."
        return true
    }

    /// Explicitly arms a selected morning even when the publisher has not written
    /// its brief yet. The actual trigger must refresh, then call arrival(UUID).
    @discardableResult
    func armAwaitingBrief() -> Bool {
        armed = false
        guard !isPaused() else { status = "Monitoring is paused. Resume explicitly before arming morning."; return false }
        guard deliveryState != .attempted else { status = "A morning delivery is still in progress."; return false }
        guard storageError == nil else { status = "Morning receipt storage needs attention. Automatic greeting is blocked."; return false }
        guard onDelivery != nil else { status = "No local audio delivery is connected. Morning is not armed."; return false }
        guard selectedDay >= dayString(clock()) else { status = "The selected morning is in the past."; return false }
        guard !hasAttemptForSelectedDay else { status = "This day's greeting was already attempted. Use explicit replay if needed."; return false }
        if let artifact {
            do { try validate(artifact, delivering: false) }
            catch { return preparationFailed(error.localizedDescription) }
        }
        armed = true
        status = artifact == nil
            ? "Armed for \(selectedDay). Waiting for the Home brief and selected return."
            : "Armed for \(selectedDay). Home plan prepared; waiting for the selected return."
        return true
    }

    func disarm() {
        armed = false
        status = "Morning is disarmed. It will not resume automatically."
    }

    /// True means the callback was invoked after persisting an attempted receipt.
    /// False before 9 AM or brief readiness requires a fresh trigger UUID later.
    @discardableResult
    func arrival(_ id: UUID) -> Bool {
        guard !consumedArrivals.contains(id) else { return false }
        consumedArrivals.insert(id)
        // Keep the specific validation/storage failure visible if a queued refresh
        // just disarmed this session before the owner forwarded its trigger.
        guard armed else { return false }
        return deliver(arrivalID: id, manualReplay: false, allowBeforeNine: false, trigger: "automatic_arrival")
    }

    /// Call only for a proven physical user Dark->Home button edge or the app's
    /// explicit Return/Home button. Never call from a generic Home mode poll,
    /// app activation, reconnect, camera presence, or clock change.
    @discardableResult
    func userReturn(_ id: UUID) -> Bool {
        guard !consumedArrivals.contains(id) else { return false }
        consumedArrivals.insert(id)
        guard armed else { return false }
        return deliver(arrivalID: id, manualReplay: false, allowBeforeNine: true, trigger: "user_return")
    }

    /// Explicit manual fallback; this never counts as evidence of camera activation.
    @discardableResult
    func replay(allowBeforeNine: Bool = false) -> Bool {
        deliver(arrivalID: nil, manualReplay: true, allowBeforeNine: allowBeforeNine, trigger: "manual_replay")
    }

    func markDeliveryFinished() {
        guard deliveryState == .attempted else { return }
        deliveryState = .finished
        status = "Local audio reports the morning greeting completed."
    }

    func markDeliveryFailed(_ message: String) {
        guard deliveryState == .attempted else { return }
        armed = false
        deliveryState = .failed
        status = "Morning audio failed: \(String(message.prefix(300))). No automatic retry; replay explicitly."
    }

    private func deliver(arrivalID: UUID?, manualReplay: Bool, allowBeforeNine: Bool, trigger: String) -> Bool {
        guard !isPaused() else { disarm(); status = "Monitoring is paused. No morning audio was sent."; return false }
        guard storageError == nil else { disarm(); status = "Receipt storage needs attention. No morning audio was sent."; return false }
        guard let artifact else {
            status = armed
                ? "Still armed; waiting for the Home brief. Return again when it is ready; no speech is queued."
                : "Prepare a valid Home brief before delivery."
            return false
        }
        guard let onDelivery else { disarm(); status = "Local audio is unavailable. No delivery was attempted."; return false }
        guard deliveryState != .attempted else { status = "A morning delivery is still in progress."; return false }
        do { try validate(artifact, delivering: true, allowBeforeNine: allowBeforeNine) }
        catch {
            status = error.localizedDescription
            // Early arrival leaves the session armed, but no timer or queued speech is created.
            if dayString(clock()) > selectedDay { armed = false }
            return false
        }
        guard manualReplay || !hasAttemptForSelectedDay else {
            disarm()
            status = "This day's greeting was already attempted. Automatic replay is blocked."
            return false
        }
        let receipt = MeshMorningAttemptReceipt(id: UUID(), key: dayKey, briefID: artifact.id,
                                                occurredAt: clock(), arrivalID: arrivalID,
                                                manualReplay: manualReplay, trigger: trigger,
                                                outcome: "attempted_before_delivery")
        do { try persist(receipt) }
        catch {
            armed = false
            storageError = error.localizedDescription
            status = "Could not save the greeting receipt. No audio was sent."
            return false
        }
        attemptedKeys.insert(receipt.key)
        lastAttempt = receipt
        armed = false
        deliveryState = .attempted
        status = "Morning delivery attempted. Waiting for local audio completion."
        onDelivery("Good morning. Here's your Home plan for today. \(artifact.text)")
        return true
    }

    private func validate(_ envelope: MeshMorningBriefArtifact, delivering: Bool, allowBeforeNine: Bool = false) throws {
        let now = clock()
        guard envelope.schema == "mesh.morning-brief.v1", envelope.calendar == "Home" else {
            throw MeshMorningError.invalid("Only a mesh.morning-brief.v1 Home brief is accepted.")
        }
        guard !envelope.id.isEmpty, envelope.id.count <= 200 else {
            throw MeshMorningError.invalid("The Home brief requires a bounded stable ID.")
        }
        guard TimeZone.knownTimeZoneIdentifiers.contains(envelope.timezone), envelope.timezone == timeZone.identifier else {
            throw MeshMorningError.invalid("The Home brief timezone does not match this morning session.")
        }
        guard envelope.date == selectedDay else {
            throw MeshMorningError.invalid("The Home brief date does not match the selected morning.")
        }
        guard selectedDay >= dayString(now) else {
            throw MeshMorningError.invalid("The selected morning is in the past. Prepare the intended day.")
        }
        guard let generatedAt = parseISO(envelope.generatedAt), generatedAt <= now,
              now.timeIntervalSince(generatedAt) <= 86_400 else {
            throw MeshMorningError.invalid("The Home brief timestamp is invalid, in the future, or more than 24 hours old.")
        }
        guard let notBefore = parseISO(envelope.notBefore), dayString(notBefore) == selectedDay,
              let nineAM = localCalendar.date(bySettingHour: 9, minute: 0, second: 0, of: intendedDate) else {
            throw MeshMorningError.invalid("The Home brief availability must be a valid time on the selected local date.")
        }
        guard !envelope.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, envelope.text.count <= 6_000 else {
            throw MeshMorningError.invalid("The Home brief must contain 1–6000 characters.")
        }
        if delivering {
            guard dayString(now) == selectedDay else {
                throw MeshMorningError.invalid("Waiting for the selected morning. A future plan will not be spoken today.")
            }
            guard now >= notBefore else {
                throw MeshMorningError.invalid("Waiting until the brief's stated availability time. Return again when ready; no speech is queued.")
            }
            guard allowBeforeNine || now >= nineAM else {
                throw MeshMorningError.invalid("Automatic arrivals wait until 9 AM. A fresh arrival is required then; no speech is queued.")
            }
        }
    }

    private func readArtifact(_ url: URL) throws -> MeshMorningBriefArtifact {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else {
            throw MeshMorningError.invalid("Morning brief exceeds the local import size limit.")
        }
        return try JSONDecoder().decode(MeshMorningBriefArtifact.self, from: Data(contentsOf: url))
    }

    private func preparationFailed(_ message: String) -> Bool {
        armed = false
        artifact = nil
        preparedBrief = nil
        status = message
        return false
    }

    private func restoreReceipts() {
        guard FileManager.default.fileExists(atPath: receiptsURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: receiptsURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_000_000 else {
                throw MeshMorningError.invalid("Morning receipt archive exceeds its local size limit.")
            }
            let data = try Data(contentsOf: receiptsURL)
            let receipts = try data.split(separator: 0x0A).map {
                try JSONDecoder().decode(MeshMorningAttemptReceipt.self, from: Data($0))
            }
            attemptedKeys = Set(receipts.map(\.key))
            lastAttempt = receipts.last
            if hasAttemptForSelectedDay {
                status = "A morning greeting was already attempted today. Playback completion is unverified after restart."
            }
        } catch {
            storageError = error.localizedDescription
            status = "Morning receipt storage could not be read. Automatic greeting is blocked."
        }
    }

    private func persist(_ receipt: MeshMorningAttemptReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: receiptsURL.path) {
            guard FileManager.default.createFile(atPath: receiptsURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: receiptsURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var data = try JSONEncoder().encode(receipt)
        data.append(0x0A)
        guard size + UInt64(data.count) <= 1_000_000 else {
            throw MeshMorningError.invalid("Morning receipt archive is full.")
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = localCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

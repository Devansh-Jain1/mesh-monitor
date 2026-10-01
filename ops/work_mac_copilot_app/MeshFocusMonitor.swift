import Combine
import Darwin
import Foundation

/// Fixed reasons keep scheduler state distinct from evidence or model failures.
enum MeshFocusDeferralReason: String, Codable, Sendable, CaseIterable {
    case stopping, paused, conversation, screenCapture, voice, noExternalApplication
    var status: String {
        switch self {
        case .stopping: "Screen monitoring is stopping"
        case .paused: "Screen monitoring is paused"
        case .conversation: "Waiting for your conversation to finish"
        case .screenCapture: "Waiting for the current screen capture to finish"
        case .voice: "Waiting while voice is starting or responding"
        case .noExternalApplication: "Waiting for an app window · switch to the app you want to work in"
        }
    }
}

enum MeshFocusRelation: String, Codable, Sendable { case onTask, possibleDetour, unclear }
enum MeshFocusFeedbackRelation: String, Codable, Sendable { case onTask, usefulDetour, distracted }
enum MeshFocusFeedbackSource: String, Codable, Sendable { case button, voice }

struct MeshFocusSample: Sendable {
    let appName: String
    let observation: String
    let relation: MeshFocusRelation
    let reasoning: String
    let inferenceMS: Int?
    let capturedAt: Date
    var gazeStatus: String? = nil
    var gazeSource: String? = nil
    var gazeProvenance: String? = nil
    init(appName: String, observation: String, relation: MeshFocusRelation, reasoning: String,
         inferenceMS: Int? = nil, capturedAt: Date = Date()) {
        self.appName = appName; self.observation = observation; self.relation = relation
        self.reasoning = reasoning; self.inferenceMS = inferenceMS; self.capturedAt = capturedAt
    }
}

struct MeshFocusObservation: Identifiable, Codable, Sendable {
    let id: UUID
    let sessionID: UUID
    let observedAt: Date
    let task: String
    let finishCondition: String
    let appName: String
    let observation: String
    let relation: MeshFocusRelation
    let reasoning: String
    let inferenceMS: Int?
    var gazeStatus: String? = nil
    var gazeSource: String? = nil
    var gazeProvenance: String? = nil
    var sample: MeshFocusSample {
        var value = MeshFocusSample(appName: appName, observation: observation, relation: relation, reasoning: reasoning,
                                    inferenceMS: inferenceMS, capturedAt: observedAt)
        value.gazeStatus = gazeStatus; value.gazeSource = gazeSource; value.gazeProvenance = gazeProvenance
        return value
    }
}

struct MeshFocusCorrection: Identifiable, Codable, Sendable {
    let id: UUID
    let observationID: UUID
    let recordedAt: Date
    let relation: MeshFocusFeedbackRelation
    let note: String
    let source: MeshFocusFeedbackSource
}

/// The callback supplies a short interpretation, never image bytes, OCR dumps, or a voice
/// transcript. These additional redactions cover common credential formats, not arbitrary secrets.
enum MeshFocusSummary {
    static func clean(_ value: String, bytes: Int) -> String {
        var result = String(value.prefix(16_384)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let patterns: [(String, String)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, "[redacted private key]"),
            (#"\b(?:sk|rk|pk|ghp|github_pat|glpat)[_-][A-Za-z0-9_-]{16,}\b"#, "[redacted credential]"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{8,}"#, "Bearer [redacted]"),
            (#"(?i)\b(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|secret)\s*[:=]\s*[\"']?[^\s,;]+"#, "$1=[redacted]"),
            (#"(https?://[^\s?#]+)[?#][^\s]*"#, "$1?[redacted]"),
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        result = String(result.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }).trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = "", used = 0
        for character in result {
            let count = String(character).utf8.count
            if used + count > bytes { break }; bounded.append(character); used += count
        }
        return bounded
    }
}

struct MeshFocusJournalEvent: Codable {
    let schemaVersion: Int
    let id: UUID
    let occurredAt: Date
    let sessionID: UUID
    let kind: String
    let task: String
    let finishCondition: String
    var observation: MeshFocusObservation? = nil
    var correction: MeshFocusCorrection? = nil
    var failureReason: String? = nil
    var deferralReason: MeshFocusDeferralReason? = nil
}

enum MeshFocusMonitorError: LocalizedError {
    case unavailable, invalidSample, unsafeStorage, storageFull
    var errorDescription: String? {
        switch self {
        case .unavailable: "Screen interpretation is not connected."
        case .invalidSample: "The screen interpretation had no usable fresh evidence."
        case .unsafeStorage: "The private focus review log could not be verified or saved."
        case .storageFull: "The focus review log reached its storage limit."
        }
    }
}

/// Private hourly JSONL files keep atomic replacement small. The stable lock serializes
/// append/export/retention, and all file operations stay relative to the verified directory.
struct MeshFocusJournal {
    let directory: URL
    var retentionDays: Int = 7
    var maximumBytes: Int = 20_000_000
    private var maximumFileBytes: Int { min(maximumBytes, 2_000_000) }
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HH"; return formatter
    }
    private func openDirectory(create: Bool) throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else { throw MeshFocusMonitorError.unsafeStorage }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MeshFocusMonitorError.unsafeStorage }
        do {
            for component in directory.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.contains("/") else { throw MeshFocusMonitorError.unsafeStorage }
                var next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw MeshFocusMonitorError.unsafeStorage }
                    next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw MeshFocusMonitorError.unsafeStorage }
                Darwin.close(fd); fd = next
            }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
                throw MeshFocusMonitorError.unsafeStorage
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func locked<T>(create: Bool, _ action: (Int32) throws -> T) throws -> T {
        let directoryFD = try openDirectory(create: create); defer { Darwin.close(directoryFD) }
        let lock = Darwin.openat(directoryFD, ".focus.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw MeshFocusMonitorError.unsafeStorage }; defer { Darwin.close(lock) }
        _ = try metadata(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw MeshFocusMonitorError.unsafeStorage }
        defer { _ = flock(lock, LOCK_UN) }
        return try action(directoryFD)
    }
    private func metadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(),
              value.st_mode & 0o777 == 0o600, value.st_nlink == 1, value.st_size >= 0 else { throw MeshFocusMonitorError.unsafeStorage }
        return value
    }
    private func read(_ name: String, in directoryFD: Int32) throws -> Data? {
        let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw MeshFocusMonitorError.unsafeStorage }; defer { Darwin.close(fd) }
        guard try metadata(fd).st_size <= maximumFileBytes else { throw MeshFocusMonitorError.storageFull }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= maximumFileBytes else { throw MeshFocusMonitorError.unsafeStorage }
            data.append(contentsOf: chunk.prefix(count))
        }
    }
    private func files(in directoryFD: Int32) throws -> [(name: String, hour: Date, size: Int)] {
        let descriptor = dup(directoryFD)
        guard descriptor >= 0 else { throw MeshFocusMonitorError.unsafeStorage }
        guard let stream = fdopendir(descriptor) else { Darwin.close(descriptor); throw MeshFocusMonitorError.unsafeStorage }
        defer { closedir(stream) }
        let formatter = Self.formatter(); var result: [(String, Date, Int)] = [], visited = 0
        while let entry = readdir(stream) {
            visited += 1; guard visited <= 4096 else { throw MeshFocusMonitorError.storageFull }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix("focus-"), name.hasSuffix(".jsonl"), name.count == 25 else { continue }
            let stamp = String(name.dropFirst(6).dropLast(6))
            guard let hour = formatter.date(from: stamp), formatter.string(from: hour) == stamp else { continue }
            let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw MeshFocusMonitorError.unsafeStorage }
            do { let value = try metadata(fd); Darwin.close(fd); result.append((name, hour, Int(value.st_size))) }
            catch { Darwin.close(fd); throw error }
        }
        return result.sorted { $0.1 < $1.1 }
    }
    private func publish(_ data: Data, name: String, in directoryFD: Int32) throws {
        let temporary = ".focus-\(UUID().uuidString).tmp"
        let fd = Darwin.openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MeshFocusMonitorError.unsafeStorage }
        defer { Darwin.close(fd); _ = unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }; var left = bytes.count
            while left > 0 {
                let count = Darwin.write(fd, pointer, left)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MeshFocusMonitorError.unsafeStorage }
                left -= count; pointer = pointer.advanced(by: count)
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw MeshFocusMonitorError.unsafeStorage }
        _ = fsync(directoryFD)
    }
    func append(_ event: MeshFocusJournalEvent) throws {
        try locked(create: true) { fd in
            let name = "focus-\(Self.formatter().string(from: event.occurredAt)).jsonl"
            let cutoff = event.occurredAt.addingTimeInterval(-Double(retentionDays) * 86_400)
            var retained = try files(in: fd)
            for file in retained where file.hour < cutoff {
                guard unlinkat(fd, file.name, 0) == 0 else { throw MeshFocusMonitorError.unsafeStorage }
            }
            retained.removeAll { $0.hour < cutoff }
            var data = try read(name, in: fd) ?? Data()
            // An incomplete existing record is an explicit error, never silently repaired
            // into an apparently complete trial. Atomic publication prevents torn new rows.
            guard data.isEmpty || data.last == 10 else { throw MeshFocusMonitorError.unsafeStorage }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            data.append(try encoder.encode(event)); data.append(10)
            guard data.count <= maximumFileBytes else { throw MeshFocusMonitorError.storageFull }
            var size = retained.filter { $0.name != name }.reduce(0) { $0 + $1.size } + data.count
            for file in retained where size > maximumBytes && file.name != name {
                guard unlinkat(fd, file.name, 0) == 0 else { throw MeshFocusMonitorError.unsafeStorage }; size -= file.size
            }
            guard size <= maximumBytes else { throw MeshFocusMonitorError.storageFull }
            try publish(data, name: name, in: fd)
        }
    }
    func events(since: Date, through now: Date) throws -> [MeshFocusJournalEvent] {
        try locked(create: false) { fd in
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var result: [MeshFocusJournalEvent] = [], total = 0
            for file in try files(in: fd) where file.hour <= now && file.hour.addingTimeInterval(3600) >= since {
                guard let data = try read(file.name, in: fd) else { continue }
                total += data.count; guard total <= maximumBytes else { throw MeshFocusMonitorError.storageFull }
                guard data.isEmpty || data.last == 10 else { throw MeshFocusMonitorError.unsafeStorage }
                for line in data.split(separator: 10) {
                    let event = try decoder.decode(MeshFocusJournalEvent.self, from: Data(line))
                    guard event.schemaVersion == 1 else { throw MeshFocusMonitorError.unsafeStorage }
                    if event.occurredAt >= since && event.occurredAt <= now { result.append(event) }
                }
            }
            return result.sorted { $0.occurredAt < $1.occurredAt }
        }
    }
}

@MainActor private final class MeshFocusDrain {
    var continuation: CheckedContinuation<Bool, Never>?
    var timer: Task<Void, Never>?
    func complete(_ value: Bool) { guard let continuation else { return }; self.continuation = nil; timer?.cancel(); timer = nil; continuation.resume(returning: value) }
}

/// Starts only through an explicit user action. One callback runs at a time, including
/// across Stop/restart, task edits, and foreground interruptions with slow cancellation.
@MainActor final class MeshFocusMonitor: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var status = "Focus monitor stopped"
    @Published private(set) var task = ""
    @Published private(set) var finishCondition = ""
    @Published private(set) var lastObservation: MeshFocusObservation?
    @Published private(set) var lastObservedAt: Date?
    @Published private(set) var lastAnalysisMS: Int?
    @Published private(set) var count = 0
    @Published private(set) var errorCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var deferredCount = 0
    @Published private(set) var observations: [MeshFocusObservation] = []
    @Published private(set) var corrections: [MeshFocusCorrection] = []
    @Published private(set) var persistenceError: String?
    var observe: (@MainActor () async throws -> MeshFocusSample)?
    var deferReason: @MainActor () -> MeshFocusDeferralReason?
    private let clock: @MainActor () -> Date
    private let journal: MeshFocusJournal
    private let intervalNanoseconds: UInt64
    private let drainNanoseconds: UInt64
    private var loop: Task<Void, Never>?
    private var loopID: UUID?
    private var generation = UUID()
    private var sessionID = UUID()
    @Published private(set) var deferralReason: MeshFocusDeferralReason?
    private let memoryLimit = 200

    init(observe: (@MainActor () async throws -> MeshFocusSample)? = nil,
         deferReason: @escaping @MainActor () -> MeshFocusDeferralReason? = { nil }, directory: URL? = nil,
         intervalSeconds: Double = 60, drainTimeoutSeconds: Double = 20,
         clock: @escaping @MainActor () -> Date = Date.init) {
        self.observe = observe; self.deferReason = deferReason; self.clock = clock
        self.intervalNanoseconds = UInt64(max(0.001, min(intervalSeconds.isFinite ? intervalSeconds : 60, 3600)) * 1_000_000_000)
        self.drainNanoseconds = UInt64(max(0.001, min(drainTimeoutSeconds.isFinite ? drainTimeoutSeconds : 20, 20)) * 1_000_000_000)
        self.journal = MeshFocusJournal(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor/focus-trial", isDirectory: true))
    }
    deinit { loop?.cancel() }

    func start(task: String, finishCondition: String) {
        if isRunning { updateTask(task: task, finishCondition: finishCondition); return }
        self.task = MeshFocusSummary.clean(task, bytes: 512); self.finishCondition = MeshFocusSummary.clean(finishCondition, bytes: 512)
        lastObservation = nil; lastObservedAt = nil; lastAnalysisMS = nil; lastError = nil
        sessionID = UUID(); isRunning = true; deferralReason = nil; status = "Focus monitor starting"
        record("session_started"); restartLoop()
    }
    func updateTask(task: String, finishCondition: String) {
        let task = MeshFocusSummary.clean(task, bytes: 512), finish = MeshFocusSummary.clean(finishCondition, bytes: 512)
        guard self.task != task || self.finishCondition != finish else { return }
        self.task = task; self.finishCondition = finish
        lastObservation = nil; lastObservedAt = nil; lastAnalysisMS = nil; lastError = nil
        if isRunning { record("task_changed"); status = "Task updated · checking the next screen sample"; restartLoop() }
    }
    func stop() {
        if isRunning { record("session_stopped") }
        isRunning = false; generation = UUID(); loop?.cancel(); deferralReason = nil
        status = isAnalyzing ? "Focus monitor stopped · cancelling the current analysis" : "Focus monitor stopped"
    }
    /// Invalidate evidence captured before an input or consent change. The old
    /// callback must drain before the next starts, even if it ignores cancellation.
    func contextChanged() {
        lastObservation = nil; lastObservedAt = nil; lastAnalysisMS = nil; lastError = nil
        guard isRunning else { return }
        record("input_context_changed")
        status = "Inputs updated · checking the next screen sample"
        restartLoop()
    }
    @discardableResult func suspendCurrentAnalysis() async -> Bool {
        guard let pending = loop else { return !isAnalyzing }
        pending.cancel(); generation = UUID()
        if isRunning { status = "Waiting for the foreground interaction"; record("analysis_interrupted"); restartLoop() }
        let latch = MeshFocusDrain(), timeout = drainNanoseconds
        let finished = await withCheckedContinuation { continuation in
            latch.continuation = continuation
            latch.timer = Task { try? await Task.sleep(nanoseconds: timeout); guard !Task.isCancelled else { return }; latch.complete(false) }
            Task { await pending.value; latch.complete(true) }
        }
        if !finished && isAnalyzing { status = "Waiting for the previous analysis to finish cancelling" }
        return finished
    }
    @discardableResult func recordFeedback(relation: MeshFocusFeedbackRelation, note: String = "", source: MeshFocusFeedbackSource = .button,
                                          observationID: UUID? = nil) -> Bool {
        guard let id = observationID ?? lastObservation?.id, let original = observations.first(where: { $0.id == id }) else { return false }
        let correction = MeshFocusCorrection(id: UUID(), observationID: id, recordedAt: clock(), relation: relation,
                                             note: MeshFocusSummary.clean(note, bytes: 512), source: source)
        corrections.append(correction); if corrections.count > memoryLimit { corrections.removeFirst(corrections.count - memoryLimit) }
        save(MeshFocusJournalEvent(schemaVersion: 1, id: UUID(), occurredAt: correction.recordedAt, sessionID: original.sessionID,
             kind: "human_correction", task: original.task, finishCondition: original.finishCondition, correction: correction))
        return true
    }
    func exportReview(days: Int = 3) throws -> String {
        let days = max(1, min(days, 7)), now = clock()
        let events = try journal.events(since: now.addingTimeInterval(-Double(days) * 86_400), through: now)
        let samples = events.compactMap(\.observation), feedback = events.compactMap(\.correction)
        var lines = ["# Focus review · \(days) days", "", "\(samples.count) screen observations · \(feedback.count) explicit corrections · \(events.filter { $0.kind == "observation_failed" }.count) failed checks",
                     "", "Screen summaries are model interpretations. Corrections record what you explicitly reported.", ""]
        for event in events {
            let stamp = ISO8601DateFormatter().string(from: event.occurredAt)
            if let observation = event.observation {
                lines.append("- \(stamp) · \(observation.appName) · \(observation.relation.rawValue): \(observation.observation)")
                lines.append("  Task: \(observation.task.isEmpty ? "Not set" : observation.task). Finish: \(observation.finishCondition.isEmpty ? "Not set" : observation.finishCondition). \(observation.reasoning)")
                if let gaze = observation.gazeStatus {
                    lines.append("  Gaze: \(gaze). \(observation.gazeProvenance ?? "")")
                }
            } else if let correction = event.correction {
                lines.append("- \(stamp) · Your \(correction.source.rawValue) correction for \(correction.observationID): \(correction.relation.rawValue). \(correction.note)")
            } else if event.kind == "observation_failed" {
                let reason = event.failureReason.map { MeshFocusSummary.clean($0, bytes: 240) } ?? "Reason was not recorded in this older entry."
                lines.append("- \(stamp) · \(event.kind) · \(event.task) · \(reason)")
            } else if let reason = event.deferralReason {
                lines.append("- \(stamp) · \(event.kind) · \(reason.status)")
            } else { lines.append("- \(stamp) · \(event.kind) · \(event.task)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
    private func restartLoop() {
        let previous = loop; previous?.cancel(); generation = UUID(); let token = generation
        loopID = token
        loop = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                let delay: UInt64
                do {
                    guard let self, self.generation == token, self.isRunning else { break }
                    delay = await self.tick(token)
                }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: delay)
            }
            if let self, self.loopID == token { self.loop = nil; self.loopID = nil }
        }
    }
    private func tick(_ token: UUID) async -> UInt64 {
        if let reason = deferReason() {
            if deferralReason != reason {
                deferralReason = reason; deferredCount += 1
                record("foreground_deferred", deferralReason: reason)
            }
            status = reason.status
            return min(intervalNanoseconds, 5_000_000_000)
        }
        deferralReason = nil; isAnalyzing = true; status = "Checking how the screen relates to your task"
        defer { isAnalyzing = false; if !isRunning { status = "Focus monitor stopped" } }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            guard let observe else { throw MeshFocusMonitorError.unavailable }
            let sample = try await observe()
            guard generation == token, isRunning, !Task.isCancelled else { return intervalNanoseconds }
            let now = clock(), age = now.timeIntervalSince(sample.capturedAt)
            let summary = MeshFocusSummary.clean(sample.observation, bytes: 768)
            guard sample.capturedAt.timeIntervalSince1970.isFinite, (-1...180).contains(age), !summary.isEmpty else { throw MeshFocusMonitorError.invalidSample }
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let inference = sample.inferenceMS.flatMap { (0...600_000).contains($0) ? $0 : nil }
            let observation = MeshFocusObservation(id: UUID(), sessionID: sessionID, observedAt: sample.capturedAt,
                task: task, finishCondition: finishCondition, appName: MeshFocusSummary.clean(sample.appName, bytes: 128),
                observation: summary, relation: task.isEmpty ? .unclear : sample.relation,
                reasoning: task.isEmpty ? "Set a task before comparing screen activity with your plan." : MeshFocusSummary.clean(sample.reasoning, bytes: 768), inferenceMS: inference,
                gazeStatus: sample.gazeStatus.map { MeshFocusSummary.clean($0, bytes: 384) },
                gazeSource: ["neoCursor", "native"].contains(sample.gazeSource ?? "") ? sample.gazeSource : nil,
                gazeProvenance: sample.gazeProvenance.map { MeshFocusSummary.clean($0, bytes: 192) })
            lastObservation = observation; lastObservedAt = observation.observedAt; lastAnalysisMS = inference ?? elapsed
            lastError = nil
            count += 1; observations.append(observation)
            if observations.count > memoryLimit { observations.removeFirst(observations.count - memoryLimit) }
            save(MeshFocusJournalEvent(schemaVersion: 1, id: UUID(), occurredAt: now, sessionID: sessionID,
                kind: "screen_observation", task: task, finishCondition: finishCondition, observation: observation))
            status = task.isEmpty ? "No task set · relevance not evaluated" : "Monitoring · last check \(observation.relation.rawValue)"
        } catch {
            guard generation == token, isRunning, !Task.isCancelled else { return intervalNanoseconds }
            // Capture may reject a frame after the foreground target changes without
            // cancelling this Task. Keep that skip distinct from an inference failure.
            if error is CancellationError {
                deferralReason = nil; deferredCount += 1; record("capture_interrupted")
                status = "Screen capture interrupted · check skipped"
                return intervalNanoseconds
            }
            let detail = MeshFocusSummary.clean(error.localizedDescription, bytes: 240)
            lastError = detail.isEmpty ? "Screen analysis failed." : detail
            errorCount += 1; record("observation_failed", failureReason: lastError)
            status = "Could not check the screen · will retry"
        }
        return intervalNanoseconds
    }
    private func record(_ kind: String, failureReason: String? = nil, deferralReason: MeshFocusDeferralReason? = nil) {
        save(MeshFocusJournalEvent(schemaVersion: 1, id: UUID(), occurredAt: clock(), sessionID: sessionID,
                                  kind: kind, task: task, finishCondition: finishCondition,
                                  failureReason: kind == "observation_failed" ? failureReason.map { MeshFocusSummary.clean($0, bytes: 240) } : nil,
                                  deferralReason: kind == "foreground_deferred" ? deferralReason : nil))
    }
    private func save(_ event: MeshFocusJournalEvent) {
        do { try journal.append(event); persistenceError = nil }
        catch { persistenceError = "Local focus review log unavailable. New observations may exist only in memory." }
    }
}

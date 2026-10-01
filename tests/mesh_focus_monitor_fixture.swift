import Darwin
import Foundation

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw NSError(domain: "MeshFocusFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@MainActor private func until(_ message: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    try expect(condition(), "timed out: \(message)")
}
private func rejects(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }; try expect(false, "accepted unsafe state: \(message)")
}
@MainActor private final class Driver {
    private(set) var calls = 0, active = 0, peak = 0
    private var waiting: [Int: CheckedContinuation<MeshFocusSample, Error>] = [:]
    func observe() async throws -> MeshFocusSample {
        calls += 1; let id = calls; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }
    func reply(_ id: Int, _ sample: MeshFocusSample) { waiting.removeValue(forKey: id)?.resume(returning: sample) }
    func fail(_ id: Int, error: Error = MeshFocusMonitorError.unavailable) { waiting.removeValue(forKey: id)?.resume(throwing: error) }
    func finish(_ sample: MeshFocusSample) { let pending = waiting; waiting = [:]; pending.values.forEach { $0.resume(returning: sample) } }
}

@main struct MeshFocusMonitorFixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static func sample(_ text: String = "A research video is open", relation: MeshFocusRelation = .onTask, capturedAt: Date = now.addingTimeInterval(-3)) -> MeshFocusSample {
        MeshFocusSample(appName: "Browser", observation: text, relation: relation,
                        reasoning: "The visible topic may support the selected research task", inferenceMS: 125, capturedAt: capturedAt)
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/mesh-focus-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try await distinctDeferrals(root)
        try await lifecycle(root)
        try await drainAndBounds(root)
        try await interruptedCapture(root)
        try await changedGazeContext(root)
        try journal(root)
        print("PASS: synthetic focus scheduling, bounded drain, evidence timestamp, corrections and private retained review")
    }

    @MainActor private static func distinctDeferrals(_ root: URL) async throws {
        let directory = root.appendingPathComponent("deferrals"), driver = Driver()
        var reason: MeshFocusDeferralReason? = .noExternalApplication
        let monitor = MeshFocusMonitor(observe: { try await driver.observe() }, deferReason: { reason },
            directory: directory, intervalSeconds: 0.01, clock: { now })
        monitor.start(task: "", finishCondition: "")
        try await until("missing foreground reason") { monitor.deferralReason == .noExternalApplication }
        try expect(monitor.status.contains("switch to the app") && !monitor.status.contains("model"),
                   "missing foreground never claims that the model is busy")
        var expected = 1
        for next in [MeshFocusDeferralReason.conversation, .screenCapture, .voice, .paused, .stopping] {
            reason = next; expected += 1
            try await until("changed deferral reason") { monitor.deferralReason == next }
            try await Task.sleep(nanoseconds: 30_000_000)
            try expect(monitor.status == next.status && monitor.deferredCount == expected
                       && driver.calls == 0 && monitor.errorCount == 0,
                       "each reason is truthful and recorded once; deferral never calls inference")
        }
        reason = nil
        try await until("deferral clears and inference resumes") { driver.calls == 1 }
        try expect(monitor.deferralReason == nil, "active inference has no stale deferral reason")
        driver.reply(1, sample()); try await until("resumed sample accepted") { monitor.count == 1 }
        monitor.stop(); driver.finish(sample())
        try await until("deferral test stopped") { !monitor.isAnalyzing }
        let events = try MeshFocusJournal(directory: directory).events(since: now.addingTimeInterval(-60), through: now)
        let recorded = events.filter { $0.kind == "foreground_deferred" }.compactMap(\.deferralReason)
        try expect(recorded == [.noExternalApplication, .conversation, .screenCapture, .voice, .paused, .stopping],
                   "review retains the actual ordered causes instead of an ambiguous busy event")
        let review = try monitor.exportReview()
        try expect(review.contains("switch to the app") && review.contains("conversation to finish"), "review explains distinct causes")
        let legacy = events.first!
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
        var old = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        old.removeValue(forKey: "deferralReason")
        try expect(try decoder.decode(MeshFocusJournalEvent.self, from: JSONSerialization.data(withJSONObject: old)).deferralReason == nil,
                   "older journal events remain readable without inventing a reason")
    }

    @MainActor private static func lifecycle(_ root: URL) async throws {
        let directory = root.appendingPathComponent("lifecycle"), driver = Driver(); var busy = true
        let monitor = MeshFocusMonitor(observe: { try await driver.observe() }, deferReason: { busy ? .conversation : nil }, directory: directory,
                                       intervalSeconds: 0.01, drainTimeoutSeconds: 0.05, clock: { now })
        monitor.updateTask(task: "", finishCondition: ""); monitor.stop()
        try expect(!FileManager.default.fileExists(atPath: directory.path) && driver.calls == 0, "initialization and stopped configuration remain inert")
        monitor.start(task: "", finishCondition: "")
        try await until("foreground defer") { monitor.deferredCount == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(driver.calls == 0 && monitor.errorCount == 0 && monitor.deferredCount == 1, "voice deferral is not a failure or repeated episode")
        busy = false; try await until("first observation") { driver.calls == 1 }
        driver.reply(1, sample()); try await until("sample accepted") { monitor.count == 1 }
        busy = true
        try expect(monitor.lastObservation?.relation == .unclear && monitor.lastObservedAt == now.addingTimeInterval(-3)
                   && monitor.lastAnalysisMS == 125, "missing task is unclear and evidence time is preserved")
        try expect(monitor.status == "No task set · relevance not evaluated"
                   && monitor.lastObservation?.reasoning == "Set a task before comparing screen activity with your plan.",
                   "no-task relevance is explicitly unevaluated, rather than attributed to a model judgement")
        let original = monitor.lastObservation!.id
        try expect(monitor.recordFeedback(relation: .usefulDetour, note: "This is research; api_key=hidden-value", source: .voice), "explicit correction recorded")
        try expect(monitor.corrections.last?.observationID == original && monitor.corrections.last?.source == .voice
                   && monitor.lastObservation?.relation == .unclear, "user correction preserves original interpretation and linkage")
        try expect(!monitor.recordFeedback(relation: .distracted, observationID: UUID()), "unknown observation cannot receive fabricated feedback")
        let review = try monitor.exportReview()
        try expect(review.contains("usefulDetour") && review.contains("voice correction") && !review.contains("hidden-value"), "explicit review contains bounded redacted feedback")
        monitor.stop(); driver.finish(sample()); try await until("stopped analysis settles") { !monitor.isAnalyzing }
        monitor.start(task: "A different task", finishCondition: "A new result")
        try expect(monitor.lastObservation == nil && monitor.lastObservedAt == nil && monitor.lastAnalysisMS == nil && monitor.observations.count == 1,
                   "new session clears displayed interpretation while retaining review history")
        monitor.stop()

        let late = Driver(), changing = MeshFocusMonitor(observe: { try await late.observe() }, directory: root.appendingPathComponent("late"), intervalSeconds: 0.01, clock: { now })
        changing.start(task: "Old task", finishCondition: "Old finish")
        try await until("old analysis pending") { late.calls == 1 }
        changing.stop(); changing.start(task: "New task", finishCondition: "New finish")
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(late.calls == 1 && changing.count == 0, "restart waits for a noncooperative cancelled callback")
        late.reply(1, sample("old result")); try await until("new analysis starts") { late.calls == 2 }
        try expect(changing.count == 0, "late stopped result never publishes")
        changing.updateTask(task: "Revised task", finishCondition: "Revised finish")
        late.reply(2, sample("superseded result")); try await until("revised analysis starts") { late.calls == 3 }
        try expect(changing.count == 0, "task change invalidates the old interpretation")
        late.reply(3, sample("A matching document is open")); try await until("revised accepted") { changing.count == 1 }
        try expect(changing.lastObservation?.task == "Revised task" && changing.lastObservation?.finishCondition == "Revised finish" && late.peak == 1,
                   "evidence keeps exact task context and callbacks never overlap")
        changing.stop(); late.finish(sample()); try await until("late driver idle") { !changing.isAnalyzing }
    }

    @MainActor private static func drainAndBounds(_ root: URL) async throws {
        let driver = Driver(); var busy = false
        let monitor = MeshFocusMonitor(observe: { try await driver.observe() }, deferReason: { busy ? .conversation : nil }, directory: root.appendingPathComponent("drain"),
                                       intervalSeconds: 0.01, drainTimeoutSeconds: 0.05, clock: { now })
        monitor.start(task: "Research", finishCondition: "Write notes")
        try await until("drain analysis starts") { driver.calls == 1 }
        busy = true
        let drain = Task { await monitor.suspendCurrentAnalysis() }
        try await Task.sleep(nanoseconds: 10_000_000)
        driver.reply(1, sample()); let drained = await drain.value
        try expect(drained && monitor.isRunning && !monitor.isAnalyzing && monitor.count == 0, "foreground cancellation drains without accepting late evidence")
        busy = false; try await until("second analysis starts") { driver.calls == 2 }; busy = true
        let began = Date(), stalled = await monitor.suspendCurrentAnalysis()
        try expect(!stalled && Date().timeIntervalSince(began) < 0.5 && monitor.isAnalyzing && monitor.isRunning,
                   "uncooperative callback produces bounded false drain and truthful analyzing state")
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(driver.calls == 2, "timeout cannot permit a second background analysis")
        driver.reply(2, sample()); try await until("stalled callback settles") { !monitor.isAnalyzing }
        busy = false; try await until("retry analysis starts") { driver.calls == 3 }
        driver.fail(3, error: NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection interrupted: api_key=private-error-token " + String(repeating: "🧠", count: 100)]))
        try await until("failure surfaced") { monitor.errorCount == 1 }
        try expect(monitor.lastError != nil && monitor.lastError!.utf8.count <= 240 && !monitor.lastError!.contains("private-error-token"),
                   "last error is visible, bounded and credential-redacted")
        try await until("loop retries") { driver.calls == 4 }
        driver.reply(4, sample(capturedAt: now.addingTimeInterval(-181)))
        try await until("stale sample rejected") { monitor.errorCount == 2 }
        try expect(monitor.count == 0, "failed and stale samples never become observations")
        try await until("retry after stale sample") { driver.calls == 5 }
        driver.reply(5, sample()); try await until("successful retry") { monitor.count == 1 }
        try expect(monitor.lastError == nil, "a successful observation clears the previous error")
        monitor.stop(); driver.finish(sample()); try await until("drain test stopped") { !monitor.isAnalyzing }
        let recoveredReview = try monitor.exportReview()
        let retainedFailures = try MeshFocusJournal(directory: root.appendingPathComponent("drain"))
            .events(since: now.addingTimeInterval(-60), through: now).filter { $0.kind == "observation_failed" }
        try expect(retainedFailures.count == 2 && retainedFailures[0].failureReason?.contains("Connection interrupted:") == true
                   && retainedFailures.allSatisfy { ($0.failureReason?.utf8.count ?? 241) <= 240 },
                   "failure causes remain in the bounded journal after a successful retry")
        try expect(recoveredReview.contains("Connection interrupted:") && recoveredReview.contains("no usable fresh evidence")
                   && !recoveredReview.contains("private-error-token"), "review exports retained sanitized failure causes without credentials")

        let bounded = MeshFocusMonitor(observe: { sample() }, directory: root.appendingPathComponent("bounded"), intervalSeconds: 0.001, clock: { now })
        bounded.start(task: "Review", finishCondition: "Summary")
        try await until("bounded in-memory history") { bounded.count >= 205 }
        bounded.stop()
        try expect(bounded.observations.count == 200 && bounded.count >= 205, "memory history bounded while total accepted count remains accurate")
        for index in 0..<205 { _ = bounded.recordFeedback(relation: .onTask, note: "Correction \(index)") }
        try expect(bounded.corrections.count == 200, "feedback memory bounded independently")
        let unknown = MeshFocusMonitor(directory: root.appendingPathComponent("unavailable"), intervalSeconds: 0.01, clock: { now })
        unknown.start(task: "Task", finishCondition: "Finish")
        try await until("unconfigured callback error") { unknown.errorCount == 1 }; unknown.stop()
        try expect(unknown.count == 0, "missing observer cannot fabricate evidence")
    }

    @MainActor private static func interruptedCapture(_ root: URL) async throws {
        let driver = Driver(), directory = root.appendingPathComponent("interrupted")
        let monitor = MeshFocusMonitor(observe: { try await driver.observe() }, directory: directory, intervalSeconds: 0.01, clock: { now })
        monitor.start(task: "Research", finishCondition: "Notes")
        try await until("interrupted capture starts") { driver.calls == 1 }
        driver.fail(1, error: CancellationError())
        try await until("capture interruption classified") { monitor.deferredCount == 1 }
        try expect(monitor.isRunning && monitor.errorCount == 0 && monitor.lastError == nil && monitor.count == 0,
                   "capture-level cancellation skips a check without inventing a model failure")
        try await until("capture interruption retries") { driver.calls == 2 }
        driver.reply(2, sample()); try await until("capture retry accepted") { monitor.count == 1 }
        monitor.stop(); driver.finish(sample()); try await until("interrupted test stops") { !monitor.isAnalyzing }
        let events = try MeshFocusJournal(directory: directory).events(since: now.addingTimeInterval(-60), through: now)
        try expect(events.filter { $0.kind == "capture_interrupted" }.count == 1
                   && !events.contains { $0.kind == "observation_failed" || $0.failureReason != nil },
                   "journal distinguishes skipped capture from inference failure")
        try expect(try monitor.exportReview().contains("0 failed checks"), "capture interruption does not inflate trial failure counts")

        let legacyDirectory = root.appendingPathComponent("legacy-failure")
        let legacyJSON: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString,
            "occurredAt": ISO8601DateFormatter().string(from: now), "sessionID": UUID().uuidString,
            "kind": "observation_failed", "task": "Legacy task", "finishCondition": "Legacy finish"]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(MeshFocusJournalEvent.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        try expect(legacy.failureReason == nil, "older journal records decode without a failureReason field")
        try MeshFocusJournal(directory: legacyDirectory).append(legacy)
        let legacyMonitor = MeshFocusMonitor(directory: legacyDirectory, clock: { now })
        try expect(try legacyMonitor.exportReview().contains("Reason was not recorded in this older entry."),
                   "legacy review remains readable without fabricating a historical cause")
    }

    @MainActor private static func changedGazeContext(_ root: URL) async throws {
        let directory = root.appendingPathComponent("gaze-context"), driver = Driver()
        var busy = false
        let monitor = MeshFocusMonitor(observe: { try await driver.observe() }, deferReason: { busy ? .conversation : nil },
            directory: directory, intervalSeconds: 0.01, clock: { now })
        monitor.contextChanged()
        try expect(!FileManager.default.fileExists(atPath: directory.path) && driver.calls == 0,
                   "changing gaze context while stopped is inert")
        monitor.start(task: "Research", finishCondition: "Notes")
        try await until("initial gaze observation starts") { driver.calls == 1 }
        var first = sample("An article related to the task is visible")
        first.gazeStatus = "Approximate NeoCursor gaze region available"
        first.gazeSource = "neoCursor"
        first.gazeProvenance = "Experimental NeoCursor · producer-reported held-out calibration"
        driver.reply(1, first)
        try await until("initial gaze metadata accepted") { monitor.count == 1 }
        busy = true
        try expect(monitor.lastObservation?.gazeSource == "neoCursor", "gaze source is retained with the accepted observation")
        busy = false
        try await until("old input analysis pending") { driver.calls == 2 }
        monitor.contextChanged()
        try expect(monitor.lastObservation == nil && monitor.lastObservedAt == nil && monitor.lastAnalysisMS == nil,
                   "consent/input change immediately clears the displayed prior interpretation")
        monitor.contextChanged()
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(driver.calls == 2 && driver.active == 1 && monitor.isAnalyzing,
                   "repeated context changes wait for the same noncooperative callback")
        var superseded = sample("Superseded gaze result must not enter the journal")
        superseded.gazeStatus = "Superseded gaze metadata"
        superseded.gazeSource = "neoCursor"
        driver.reply(2, superseded)
        try await until("new input analysis starts after the old callback drains") { driver.calls == 3 }
        try expect(monitor.count == 1 && monitor.lastObservation == nil && driver.peak == 1,
                   "late input result is discarded, and replacement callbacks never overlap")
        var fresh = sample("A newly captured task document is visible")
        fresh.gazeStatus = "Approximate Native gaze region available"
        fresh.gazeSource = "native"
        fresh.gazeProvenance = "Experimental native gaze · calibrated display matched"
        driver.reply(3, fresh)
        try await until("current gaze context accepted") { monitor.count == 2 }
        busy = true
        try expect(monitor.lastObservation?.gazeStatus == fresh.gazeStatus
                   && monitor.lastObservation?.gazeSource == fresh.gazeSource
                   && monitor.lastObservation?.gazeProvenance == fresh.gazeProvenance,
                   "accepted metadata retains status, source and provenance")
        monitor.stop(); driver.finish(sample())
        try await until("gaze context fixture stops") { !monitor.isAnalyzing }

        let events = try MeshFocusJournal(directory: directory).events(since: now.addingTimeInterval(-60), through: now)
        let observations = events.compactMap(\.observation)
        try expect(events.filter { $0.kind == "input_context_changed" }.count == 2 && observations.count == 2,
                   "journal records input changes and only accepted observations")
        try expect(observations.last?.gazeStatus == fresh.gazeStatus && observations.last?.gazeSource == "native"
                   && observations.last?.gazeProvenance == fresh.gazeProvenance,
                   "gaze metadata round-trips through private retained JSONL")
        let review = try monitor.exportReview()
        try expect(review.contains("Experimental native gaze") && !review.contains("Superseded gaze"),
                   "review includes accepted provenance without a cancelled interpretation")

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var legacyObject = try JSONSerialization.jsonObject(with: encoder.encode(observations[0])) as! [String: Any]
        for key in ["gazeStatus", "gazeSource", "gazeProvenance"] { legacyObject.removeValue(forKey: key) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(MeshFocusObservation.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        try expect(legacy.gazeStatus == nil && legacy.gazeSource == nil && legacy.gazeProvenance == nil
                   && legacy.id == observations[0].id && legacy.observation == observations[0].observation,
                   "legacy observations decode without inventing gaze provenance")

        let boundedDirectory = root.appendingPathComponent("gaze-bounds")
        var oversized = sample()
        oversized.gazeStatus = String(repeating: "👀", count: 200)
        oversized.gazeSource = "not-a-known-source"
        oversized.gazeProvenance = "api_key=private-value " + String(repeating: "🧠", count: 100)
        let bounded = MeshFocusMonitor(observe: { oversized }, directory: boundedDirectory,
            intervalSeconds: 60, clock: { now })
        bounded.start(task: "Research", finishCondition: "Notes")
        try await until("bounded gaze metadata accepted") { bounded.count == 1 }
        bounded.stop()
        let retained = bounded.lastObservation!
        try expect((retained.gazeStatus?.utf8.count ?? 385) <= 384
                   && (retained.gazeProvenance?.utf8.count ?? 193) <= 192 && retained.gazeSource == nil
                   && retained.gazeProvenance?.contains("private-value") == false,
                   "journal-facing gaze fields are bounded, credential-redacted and source-allowlisted")
    }

    private static func event(_ time: Date, name: String = "Task") -> MeshFocusJournalEvent {
        MeshFocusJournalEvent(schemaVersion: 1, id: UUID(), occurredAt: time, sessionID: UUID(), kind: "session_started", task: name, finishCondition: "Done")
    }
    private static func journal(_ root: URL) throws {
        let directory = root.appendingPathComponent("retention"), journal = MeshFocusJournal(directory: directory)
        try journal.append(event(now.addingTimeInterval(-8 * 86_400), name: "expired"))
        try journal.append(event(now.addingTimeInterval(-4 * 86_400), name: "retained"))
        try journal.append(event(now, name: "recent"))
        let threeDays = try journal.events(since: now.addingTimeInterval(-3 * 86_400), through: now)
        try expect(threeDays.count == 1 && threeDays[0].task == "recent", "three-day review excludes earlier records")
        let all = try journal.events(since: now.addingTimeInterval(-20 * 86_400), through: now)
        try expect(all.map(\.task) == ["retained", "recent"], "seven-day retention removes expired journal files")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "private log directory")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files { try expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private atomic log files") }

        let smallDirectory = root.appendingPathComponent("capacity"), small = MeshFocusJournal(directory: smallDirectory, maximumBytes: 1700)
        for index in 0..<10 { try small.append(event(now.addingTimeInterval(Double(index - 9) * 3600), name: String(repeating: "x", count: 100))) }
        let kept = try small.events(since: now.addingTimeInterval(-86_400), through: now)
        let bytes = try FileManager.default.contentsOfDirectory(at: smallDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
            .reduce(0) { total, file in total + ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0) }
        try expect(bytes <= 1700 && kept.count < 10 && kept.last?.occurredAt == now, "storage bound evicts oldest hours while retaining newest evidence")

        let linkedDirectory = root.appendingPathComponent("linked"), realDirectory = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
        try rejects("symlink directory") { try MeshFocusJournal(directory: linkedDirectory).append(event(now)) }
        let last = files.first { $0.pathExtension == "jsonl" }!
        chmod(last.path, 0o644)
        try rejects("nonprivate log") { _ = try journal.events(since: now.addingTimeInterval(-7 * 86_400), through: now) }
        chmod(last.path, 0o600)
        let hardlink = root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: last, to: hardlink)
        try rejects("hardlinked log") { try journal.append(event(now)) }
        try FileManager.default.removeItem(at: hardlink)
        let outside = root.appendingPathComponent("outside"); try Data("private".utf8).write(to: outside); chmod(outside.path, 0o600)
        try FileManager.default.removeItem(at: last); try FileManager.default.createSymbolicLink(at: last, withDestinationURL: outside)
        try rejects("symlink journal file") { try journal.append(event(now)) }
        try expect(try String(contentsOf: outside, encoding: .utf8) == "private", "journal never overwrites a link target")

        let sensitive = "password=hunter2 sk-123456789012345678901234 Bearer abcdefghijklmno https://example.test/page?token=value\n" + String(repeating: "🧠", count: 100)
        let cleaned = MeshFocusSummary.clean(sensitive, bytes: 200)
        try expect(cleaned.utf8.count <= 200 && !cleaned.contains("hunter2") && !cleaned.contains("123456789012345678901234")
                   && !cleaned.contains("abcdefghijklmno") && !cleaned.contains("token=value") && !cleaned.contains("\n"), "bounded summaries redact common credentials and multiline text")
    }
}

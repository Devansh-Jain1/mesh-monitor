import Foundation

private final class FixtureDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@MainActor
private final class FixtureHomeStore: MeshHomeCalendarStore {
    var authorization = MeshCalendarAuthorization.fullAccess
    var choices: [MeshHomeCalendarChoice] = []
    var fixtures: [MeshHomeEvent] = []
    var requestedAccess = 0
    var enumerations = 0
    var queries: [(String, DateInterval)] = []
    var failRead = false
    func requestAccess() async throws -> Bool { requestedAccess += 1; return authorization == .fullAccess }
    func homeCalendars() -> [MeshHomeCalendarChoice] { enumerations += 1; return choices }
    func events(calendarID: String, interval: DateInterval) throws -> [MeshHomeEvent] {
        queries.append((calendarID, interval))
        if failRead { throw CocoaError(.fileReadUnknown) }
        return fixtures
    }
}

@main
private struct MeshHomeCalendarFixtureTests {
    @MainActor
    static func main() async throws {
        let defaults = FixtureDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parser = ISO8601DateFormatter()
        func date(_ value: String) -> Date { parser.date(from: value)! }
        let now = date("2026-09-19T12:00:00Z")
        let tomorrow = date("2026-09-20T12:00:00Z")
        let home = MeshHomeCalendarChoice(id: "home-1", title: "Home", sourceTitle: "Personal")
        let otherHome = MeshHomeCalendarChoice(id: "home-2", title: "Home", sourceTitle: "Other")
        let family = MeshHomeCalendarChoice(id: "family", title: "Family", sourceTitle: "Personal")
        let store = FixtureHomeStore()
        let adapter = MeshHomeCalendar(provider: store, defaults: defaults, calendar: calendar, clock: { now })
        assert(store.enumerations == 0 && store.queries.isEmpty && store.requestedAccess == 0, "Init must not touch Calendar")
        assert(adapter.compactBrief(for: now, now: now).state == .unavailable)

        store.authorization = .denied
        adapter.refresh(now)
        assert(store.queries.isEmpty && store.enumerations == 0 && store.requestedAccess == 0)
        await adapter.requestAccess()
        assert(store.requestedAccess == 1 && adapter.authorization == .denied)

        store.authorization = .fullAccess
        store.choices = [home, otherHome, family]
        adapter.refresh(now)
        assert(adapter.homeCalendars == [home, otherHome])
        assert(adapter.chosenHomeCalendarID == nil && store.queries.isEmpty, "Duplicate Home sources require explicit choice")
        adapter.selectHomeCalendar(id: "family", for: now)
        assert(store.queries.isEmpty, "Family must never be queried")

        let allDay = MeshHomeEvent(id: "day", calendarID: home.id, title: "Assignment due — time unknown",
                                  start: date("2026-09-19T00:00:00Z"), end: date("2026-09-20T00:00:00Z"), isAllDay: true)
        let current = MeshHomeEvent(id: "current", calendarID: home.id, title: "Applications",
                                   start: date("2026-09-19T11:00:00Z"), end: date("2026-09-19T13:00:00Z"), isAllDay: false)
        let next = MeshHomeEvent(id: "next", calendarID: home.id, title: "Learning",
                                start: date("2026-09-19T14:00:00Z"), end: date("2026-09-19T15:00:00Z"), isAllDay: false)
        let contamination = MeshHomeEvent(id: "private", calendarID: family.id, title: "Should never appear",
                                         start: current.start, end: current.end, isAllDay: false)
        let wrongDay = MeshHomeEvent(id: "tomorrow", calendarID: home.id, title: "Tomorrow only",
                                    start: tomorrow, end: tomorrow.addingTimeInterval(3600), isAllDay: false)
        store.fixtures = [next, allDay, contamination, wrongDay, current]
        adapter.selectHomeCalendar(id: home.id, for: now)
        assert(store.queries.count == 1 && store.queries[0].0 == home.id)
        assert(adapter.events.map(\.id) == ["day", "current", "next"])
        let brief = adapter.compactBrief(for: now, now: now)
        assert(brief.state == .ready && brief.canNarrate && brief.eventCount == 3)
        assert(brief.text.contains("No specific start time is scheduled"))
        assert(!brief.text.contains("Should never appear") && !brief.text.contains("Tomorrow only"))
        assert(adapter.currentBlock(at: now)?.id == current.id)
        assert(adapter.nextBlock(after: now)?.id == next.id)
        assert(adapter.currentBlock(at: current.end) == nil, "End boundary is exclusive")
        assert(adapter.compactBrief(for: tomorrow, now: now).state == .stale, "Must not narrate yesterday's plan")
        assert(adapter.compactBrief(for: now, now: now.addingTimeInterval(86_401)).state == .stale)
        assert(adapter.compactBrief(for: now, now: now.addingTimeInterval(-301)).state == .stale)

        store.fixtures = [allDay]
        adapter.refresh(now)
        assert(adapter.currentBlock(at: now) == nil && adapter.nextBlock(after: now) == nil)
        store.fixtures = []
        adapter.refresh(now)
        assert(adapter.compactBrief(for: now, now: now).state == .noPlan)
        store.failRead = true
        adapter.refresh(now)
        assert(adapter.compactBrief(for: now, now: now).state == .unavailable && adapter.events.isEmpty)
        store.failRead = false
        store.choices = [family]
        adapter.refresh(now)
        assert(adapter.chosenHomeCalendarID == nil && adapter.events.isEmpty)

        store.choices = [home]
        store.fixtures = (0..<20).map { index in
            MeshHomeEvent(id: "long-\(index)", calendarID: home.id, title: String(repeating: "x", count: 500),
                          start: current.start, end: current.end, isAllDay: false)
        }
        adapter.refresh(now)
        let bounded = adapter.compactBrief(for: now, now: now)
        assert(bounded.text.count < 2_000 && bounded.text.contains("12 additional events"))

        // Calendar day boundaries must follow the selected timezone through DST.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let dstDay = date("2026-11-01T17:00:00Z")
        let dst = MeshHomeCalendar(provider: store, defaults: defaults, calendar: newYork, clock: { dstDay })
        dst.refresh(dstDay)
        assert(store.queries.last!.1.duration == 90_000, "DST fall-back date is a 25-hour day")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-focus-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let focus = MeshFocusState(directory: temp, clock: { now })
        assert(focus.isPaused && !FileManager.default.fileExists(atPath: temp.path), "Init must not create storage")
        assert(focus.setPaused(false))
        assert(focus.confirm(.done, eventID: current.id))
        assert(focus.confirm(.help, eventID: next.id))
        assert(!focus.confirm(.snooze, eventID: next.id, snoozeUntil: now.addingTimeInterval(-1)))
        assert(focus.confirm(.snooze, eventID: next.id, snoozeUntil: now.addingTimeInterval(300)))
        assert(focus.setPaused(true))
        let restored = MeshFocusState(directory: temp, clock: { now })
        assert(restored.isPaused && restored.receipts.count == 3)
        assert(restored.receipts.allSatisfy { $0.source == "human_confirmed" })
        assert(Set(restored.receipts.map(\.id)).count == 3)
        let raw = try String(contentsOf: temp.appendingPathComponent("focus-receipts.jsonl"), encoding: .utf8)
        assert(raw.split(separator: "\n").count == 3)
        try Data("broken".utf8).write(to: temp.appendingPathComponent("focus-pause.json"))
        let corrupt = MeshFocusState(directory: temp, clock: { now })
        assert(corrupt.isPaused && corrupt.persistenceError != nil)
        print("PASS: Home isolation, explicit access, duplicates, date/freshness, all-day, bounded brief, DST, and durable human progress fixtures. No live Calendar access.")
    }
}

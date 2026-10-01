import Combine
import EventKit
import Foundation

enum MeshCalendarAuthorization: String {
    case notDetermined, denied, restricted, writeOnly, fullAccess
}

struct MeshHomeCalendarChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceTitle: String
}

struct MeshHomeEvent: Identifiable, Codable, Equatable {
    let id: String
    let calendarID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

struct MeshHomeDayBrief: Equatable {
    enum State: String { case ready, noPlan, stale, unavailable }
    let state: State
    let date: Date
    let generatedAt: Date?
    let text: String
    let eventCount: Int
    var canNarrate: Bool { state == .ready || state == .noPlan }
}

/// The boundary is injectable so tests never instantiate or query an EventKit store.
@MainActor
protocol MeshHomeCalendarStore {
    var authorization: MeshCalendarAuthorization { get }
    func requestAccess() async throws -> Bool
    func homeCalendars() -> [MeshHomeCalendarChoice]
    func events(calendarID: String, interval: DateInterval) throws -> [MeshHomeEvent]
}

private enum MeshHomeCalendarError: LocalizedError {
    case homeUnavailable
    var errorDescription: String? { "The selected Home calendar is no longer available." }
}

@MainActor
private final class MeshEventKitHomeStore: MeshHomeCalendarStore {
    // Deliberately lazy: creating the app or loading a fixture must not open a store.
    private lazy var store = EKEventStore()

    var authorization: MeshCalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .fullAccess
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func homeCalendars() -> [MeshHomeCalendarChoice] {
        guard authorization == .fullAccess else { return [] }
        // Metadata discovery only. No event predicate is ever made for Family or Work.
        return store.calendars(for: .event).filter { $0.title == "Home" }.map {
            MeshHomeCalendarChoice(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title)
        }.sorted { ($0.sourceTitle, $0.id) < ($1.sourceTitle, $1.id) }
    }

    func events(calendarID: String, interval: DateInterval) throws -> [MeshHomeEvent] {
        guard authorization == .fullAccess,
              let selected = store.calendar(withIdentifier: calendarID), selected.title == "Home"
        else { throw MeshHomeCalendarError.homeUnavailable }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: [selected])
        return store.events(matching: predicate).compactMap { event in
            guard event.calendar.calendarIdentifier == calendarID, event.calendar.title == "Home",
                  let start = event.startDate, let end = event.endDate else { return nil }
            return MeshHomeEvent(
                id: event.eventIdentifier ?? "\(calendarID)|\(start.timeIntervalSince1970)|\(event.title ?? "")",
                calendarID: calendarID, title: event.title ?? "Untitled event",
                start: start, end: end, isAllDay: event.isAllDay
            )
        }
    }
}

/// Read-only Home projection. Apple Calendar remains the schedule of record.
/// No access prompt, calendar enumeration, event fetch, or timers occur in init.
@MainActor
final class MeshHomeCalendar: ObservableObject {
    @Published private(set) var authorization: MeshCalendarAuthorization = .notDetermined
    @Published private(set) var status = "Connect Apple Calendar Home to load your day."
    @Published private(set) var events: [MeshHomeEvent] = []
    @Published private(set) var homeCalendars: [MeshHomeCalendarChoice] = []
    @Published private(set) var chosenHomeCalendarID: String?
    @Published private(set) var loadedDate: Date?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var isRequestingAccess = false

    private let provider: any MeshHomeCalendarStore
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let clock: () -> Date
    private let selectionKey = "mesh.monitor.home-calendar-id"
    private var snapshotAvailable = false

    init(provider: (any MeshHomeCalendarStore)? = nil,
         defaults: UserDefaults = .standard,
         calendar: Calendar = .current,
         clock: @escaping () -> Date = Date.init) {
        self.provider = provider ?? MeshEventKitHomeStore()
        self.defaults = defaults
        self.calendar = calendar
        self.clock = clock
        chosenHomeCalendarID = defaults.string(forKey: selectionKey)
    }

    /// Call only from a visible user action. EventKit offers full calendar access;
    /// this adapter narrows all event queries to the selected exact Home calendar.
    func requestAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do {
            authorization = provider.authorization
            if authorization != .fullAccess {
                let granted = try await provider.requestAccess()
                authorization = provider.authorization
                guard granted, authorization == .fullAccess else {
                    invalidate("Calendar access unavailable. Enable calendar read access in System Settings.")
                    return
                }
            }
            refresh(clock())
        } catch {
            authorization = provider.authorization
            invalidate("Calendar access failed: \(error.localizedDescription)")
        }
    }

    /// Read-only; never requests permission. The caller chooses the actual date.
    func refresh(_ date: Date = Date()) {
        authorization = provider.authorization
        guard authorization == .fullAccess else {
            homeCalendars = []
            invalidate(authorization == .notDetermined
                       ? "Connect Apple Calendar Home to load your day."
                       : "Calendar read access is unavailable. No plan is loaded.")
            return
        }
        homeCalendars = provider.homeCalendars().filter { $0.title == "Home" }
        guard !homeCalendars.isEmpty else {
            chosenHomeCalendarID = nil
            defaults.removeObject(forKey: selectionKey)
            invalidate("No calendar named Home was found. Family and Work are excluded.")
            return
        }
        if !homeCalendars.contains(where: { $0.id == chosenHomeCalendarID }) {
            chosenHomeCalendarID = nil
            defaults.removeObject(forKey: selectionKey)
        }
        if chosenHomeCalendarID == nil, homeCalendars.count == 1 {
            chosenHomeCalendarID = homeCalendars[0].id
            defaults.set(chosenHomeCalendarID, forKey: selectionKey)
        }
        guard let chosenHomeCalendarID else {
            invalidate("More than one Home calendar exists. Choose the source to use.")
            return
        }
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            invalidate("Unable to determine the requested calendar day.")
            return
        }
        do {
            events = try provider.events(calendarID: chosenHomeCalendarID, interval: interval)
                .filter { $0.calendarID == chosenHomeCalendarID && $0.start < interval.end && $0.end > interval.start }
                .sorted {
                    if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.id < $1.id
                }
            loadedDate = interval.start
            refreshedAt = clock()
            snapshotAvailable = true
            status = events.isEmpty ? "Home is connected. No events on this date." : "Home is connected. \(events.count) events loaded."
        } catch {
            invalidate("Home could not be read: \(error.localizedDescription)")
        }
    }

    func selectHomeCalendar(id: String, for date: Date = Date()) {
        guard homeCalendars.contains(where: { $0.id == id && $0.title == "Home" }) else {
            invalidate("Choose a Home calendar from the listed sources.")
            return
        }
        chosenHomeCalendarID = id
        defaults.set(id, forKey: selectionKey)
        refresh(date)
    }

    /// Date mismatch or an old snapshot cannot silently become a morning plan.
    /// The default 24-hour bound permits an explicitly prepared overnight brief.
    func compactBrief(for date: Date, now: Date = Date(), maximumAge: TimeInterval = 86_400) -> MeshHomeDayBrief {
        let requestedDay = calendar.startOfDay(for: date)
        guard snapshotAvailable, let loadedDate, let refreshedAt else {
            return MeshHomeDayBrief(state: .unavailable, date: requestedDay, generatedAt: nil, text: "No Home plan is loaded. \(status)", eventCount: 0)
        }
        guard calendar.isDate(loadedDate, inSameDayAs: date),
              now.timeIntervalSince(refreshedAt) >= -300,
              now.timeIntervalSince(refreshedAt) <= maximumAge else {
            return MeshHomeDayBrief(state: .stale, date: requestedDay, generatedAt: refreshedAt,
                                    text: "The Home plan is outdated or belongs to another date. Refresh the requested day before reading it aloud.", eventCount: 0)
        }
        let label = dateLabel(requestedDay)
        guard !events.isEmpty else {
            return MeshHomeDayBrief(state: .noPlan, date: requestedDay, generatedAt: refreshedAt,
                                    text: "There are no Home calendar events for \(label). No work plan has been inferred.", eventCount: 0)
        }
        var lines = ["Home calendar for \(label)."]
        for event in events.prefix(8) {
            let title = cleanTitle(event.title)
            if event.isAllDay {
                lines.append("All day: \(title). No specific start time is scheduled.")
            } else {
                let startsBefore = event.start < requestedDay
                let time = startsBefore ? "Continues from the previous day until \(timeLabel(event.end))" : "\(timeLabel(event.start))–\(timeLabel(event.end))"
                lines.append("\(time): \(title).")
            }
        }
        if events.count > 8 { lines.append("There are \(events.count - 8) additional events in Home.") }
        return MeshHomeDayBrief(state: .ready, date: requestedDay, generatedAt: refreshedAt,
                                text: lines.joined(separator: "\n"), eventCount: events.count)
    }

    /// All-day events have no known work start time and cannot become current blocks.
    func currentBlock(at date: Date = Date()) -> MeshHomeEvent? {
        guard compactBrief(for: date, now: date).canNarrate else { return nil }
        return events.filter { !$0.isAllDay && $0.start <= date && date < $0.end }
            .max { $0.start < $1.start }
    }

    func nextBlock(after date: Date = Date()) -> MeshHomeEvent? {
        guard compactBrief(for: date, now: date).canNarrate else { return nil }
        return events.filter { !$0.isAllDay && $0.start > date }.min { $0.start < $1.start }
    }

    private func invalidate(_ message: String) {
        events = []
        loadedDate = nil
        refreshedAt = nil
        snapshotAvailable = false
        status = message
    }

    private func cleanTitle(_ title: String) -> String {
        let normalized = title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String((normalized.isEmpty ? "Untitled event" : normalized).prefix(160))
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        return formatter.string(from: date)
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

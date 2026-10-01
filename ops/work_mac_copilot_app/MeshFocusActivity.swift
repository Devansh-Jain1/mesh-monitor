import AppKit
import Combine
import Foundation

struct MeshFocusApplication: Equatable, Sendable {
    let name: String
    let bundleID: String?
    let isMonitor: Bool
}

struct MeshFocusAppVisit: Identifiable, Equatable, Sendable {
    let id: UUID
    let application: MeshFocusApplication
    let startedAt: Date
    let endedAt: Date
    let seconds: TimeInterval
}

/// Raw application timing only. Durations use uptime, never wall-clock subtraction.
/// No window titles, browser data, task completion, attention judgement, or agent calls.
struct MeshFocusActivityReducer {
    private(set) var isMonitoring = false
    private(set) var application: MeshFocusApplication?
    private(set) var foregroundStartedAt: Date?
    private(set) var secondsInCurrentApp: TimeInterval = 0
    private(set) var recentSwitches: [MeshFocusAppVisit] = []
    private var foregroundStartedUptime: TimeInterval?
    private var latestUptime: TimeInterval = 0

    mutating func start(application: MeshFocusApplication?, at now: Date, uptime: TimeInterval) {
        guard !isMonitoring else { return }
        stop()
        isMonitoring = true
        latestUptime = uptime.isFinite ? max(0, uptime) : 0
        if let application { observe(application, at: now, uptime: latestUptime) }
    }

    mutating func observe(_ value: MeshFocusApplication, at now: Date, uptime: TimeInterval) {
        guard isMonitoring else { return }
        tick(uptime: uptime)
        // Bundle identity is authoritative when available; a display-name change isn't a switch.
        if let application,
           (application.bundleID != nil && application.bundleID == value.bundleID)
            || (application.bundleID == nil && value.bundleID == nil && application.name == value.name) {
            self.application = value
            return
        }
        if let application, let foregroundStartedAt {
            recentSwitches.append(MeshFocusAppVisit(id: UUID(), application: application,
                startedAt: foregroundStartedAt, endedAt: now, seconds: secondsInCurrentApp))
            if recentSwitches.count > 20 { recentSwitches.removeFirst(recentSwitches.count - 20) }
        }
        application = value
        foregroundStartedAt = now
        foregroundStartedUptime = latestUptime
        secondsInCurrentApp = 0
    }

    mutating func tick(uptime: TimeInterval) {
        guard isMonitoring, uptime.isFinite else { return }
        latestUptime = max(latestUptime, uptime)
        if let foregroundStartedUptime {
            secondsInCurrentApp = max(0, latestUptime - foregroundStartedUptime)
        }
    }

    mutating func stop() {
        isMonitoring = false
        application = nil
        foregroundStartedAt = nil
        foregroundStartedUptime = nil
        secondsInCurrentApp = 0
        latestUptime = 0
        recentSwitches.removeAll()
    }

    var snapshotDescription: String {
        guard isMonitoring else { return "Application timing is stopped; no foreground observation is retained." }
        guard let application else { return "Application timing is active; foreground application is unavailable." }
        let selfLabel = application.isMonitor ? " (Monitor's own interface)" : ""
        return "Observed foreground application: \(application.name)\(selfLabel). "
            + "Current observed visit: \(Int(secondsInCurrentApp)) seconds. "
            + "This is application timing only; it does not establish what content is open or whether it serves the task."
    }
}

/// Construction is inert. The session coordinator explicitly starts and stops observation.
/// Receives OS activation events; samples only elapsed time at five-second intervals.
@MainActor
final class MeshFocusActivity: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var appName: String?
    @Published private(set) var bundleID: String?
    @Published private(set) var foregroundStartedAt: Date?
    @Published private(set) var secondsInCurrentApp: TimeInterval = 0
    @Published private(set) var recentSwitches: [MeshFocusAppVisit] = []
    @Published private(set) var snapshotDescription = "Application timing is stopped; no foreground observation is retained."
    private var reducer = MeshFocusActivityReducer()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var generation = UUID()

    func start() {
        guard !isMonitoring else { return }
        generation = UUID()
        let token = generation
        let workspace = NSWorkspace.shared
        reducer.start(application: Self.application(workspace.frontmostApplication),
                      at: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        publish()
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] event in
            // Copy only the allowed app fields; no titles, content, or process arguments.
            guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let name = app.localizedName ?? "Unknown application"
            let bundle = app.bundleIdentifier
            let own = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            let now = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard let self, self.generation == token, self.isMonitoring else { return }
                self.reducer.observe(MeshFocusApplication(name: name, bundleID: bundle, isMonitor: own), at: now, uptime: uptime)
                self.publish()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token, self.isMonitoring else { return }
                self.reducer.tick(uptime: ProcessInfo.processInfo.systemUptime)
                self.publish()
            }
        }
        timer?.tolerance = 0.5
    }

    func stop() {
        generation = UUID()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        reducer.stop()
        publish()
    }

    private static func application(_ app: NSRunningApplication?) -> MeshFocusApplication? {
        guard let app else { return nil }
        return MeshFocusApplication(name: app.localizedName ?? "Unknown application", bundleID: app.bundleIdentifier,
                                    isMonitor: app.processIdentifier == ProcessInfo.processInfo.processIdentifier)
    }

    private func publish() {
        isMonitoring = reducer.isMonitoring
        appName = reducer.application?.name
        bundleID = reducer.application?.bundleID
        foregroundStartedAt = reducer.foregroundStartedAt
        secondsInCurrentApp = reducer.secondsInCurrentApp
        recentSwitches = reducer.recentSwitches
        snapshotDescription = reducer.snapshotDescription
    }
}

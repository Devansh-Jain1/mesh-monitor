import AppKit
import SwiftUI
import Combine
import AVFoundation

/// Local scheduling and human-confirmed outcomes. Never calls an agent or judges
/// productivity from gaze, an app name, or an unconfirmed model interpretation.
struct MeshCoachSchedule: Codable {
    var nextCheck: Date?
    var nextBreak: Date?
    mutating func start(_ now: Date) { nextCheck = now.addingTimeInterval(15 * 60); nextBreak = now.addingTimeInterval(50 * 60) }
    mutating func stop() { nextCheck = nil; nextBreak = nil }
    mutating func snooze(_ now: Date, minutes: Double) {
        let until = now.addingTimeInterval(minutes * 60)
        nextCheck = until
        if let nextBreak, nextBreak < until { self.nextBreak = until }
    }
    mutating func due(_ now: Date, available: Bool) -> String? {
        guard available, nextCheck != nil else { return nil }
        if let nextBreak, now >= nextBreak {
            self.nextBreak = now.addingTimeInterval(50 * 60)
            nextCheck = now.addingTimeInterval(15 * 60)
            return "Time for a short break. Stand up, get water, then choose your next step."
        }
        if let nextCheck, now >= nextCheck {
            self.nextCheck = now.addingTimeInterval(15 * 60)
            return "Still working toward your plan? If you drifted, come back to one small step."
        }
        return nil
    }
}

/// Desired session state doubles as launchd's opt-in marker. Explicit Quit removes it.
struct MeshFocusRecovery: Codable {
    var schema = 1
    var task: String
    var finish: String
    var schedule: MeshCoachSchedule
    var spoken: Bool
    var resumeAt: Date?
    static var url: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeshMonitor/focus-recovery.json") }
    static func load(from url: URL = url) -> MeshFocusRecovery? {
        guard let data = try? Data(contentsOf: url), data.count < 16_384,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schema == 1,
              !value.task.isEmpty, value.task.count < 4096, value.finish.count < 8192,
              let deadline = value.schedule.nextCheck, deadline.timeIntervalSince1970.isFinite,
              value.resumeAt?.timeIntervalSince1970.isFinite != false else { return nil }
        return value
    }
    func save(to url: URL = Self.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func clear(at url: URL = url) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor final class MeshFocusCoach: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Off · enable check-ins for this work session"
    @Published var spoken = false { didSet { onScheduleChange() } }
    @Published var step = ""
    @Published var taskURL = ""
    @Published private(set) var reviews: [String: String] = [:]
    private var schedule = MeshCoachSchedule()
    var onScheduleChange: () -> Void = {}
    var onBreak: () -> Void = {}
    var recoverySchedule: MeshCoachSchedule {
        var result = schedule
        // Killing an unanswered prompt must not buy a new fifteen-minute delay.
        if panel != nil { result.nextCheck = Date() }
        return result
    }
    private var timer: Timer?
    private var panel: NSPanel?
    @Published private(set) var lastEvent = "No reminder delivered in this launch"
    private var lastReason = ""
    private var events: [[String: String]] = []
    private func record(_ event: String) {
        lastEvent = event
        onScheduleChange()
        let formatter = ISO8601DateFormatter()
        events.append(["time": formatter.string(from: Date()), "event": event])
        events = Array(events.suffix(100))
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor/coach-delivery.json")
        let value: [String: Any] = ["enabled": enabled, "events": events,
            "nextCheck": schedule.nextCheck.map { formatter.string(from: $0) } ?? "",
            "nextBreak": schedule.nextBreak.map { formatter.string(from: $0) } ?? ""]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { lastEvent = event + " · delivery log could not be saved" }
    }
    var task: () -> String = { "your task" }
    var available: () -> Bool = { false }
    private let speaker = AVSpeechSynthesizer()
    func silence() { speaker.stopSpeaking(at: .immediate) }
    var onHelp: () -> Void = {}
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reviews = defaults.dictionary(forKey: "mesh.coach.day-reviews") as? [String: String] ?? [:]
        step = defaults.string(forKey: "mesh.coach.next-step") ?? ""
        taskURL = defaults.string(forKey: "mesh.coach.task-url") ?? ""
    }
    func importTaskContext() -> (String, String)? {
        struct Context: Decodable { let schema: String; let task: String; let finish: String; let nextStep: String; let sourceURL: String }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor/focus-task-context.json")
        guard let data = try? Data(contentsOf: url), data.count < 16_384,
              let value = try? JSONDecoder().decode(Context.self, from: data), value.schema == "mesh.focus-task.v1",
              !value.task.isEmpty, value.task.count < 512, value.finish.count < 1024, value.nextStep.count < 800,
              let source = URL(string: value.sourceURL), source.scheme == "codex", source.host == "threads" else {
            status = "No verified task handoff is available yet"; return nil
        }
        step = value.nextStep; taskURL = value.sourceURL; saveContext()
        status = "Task imported from your linked Codex thread · no model call"
        return (value.task, value.finish)
    }
    func start(restoring saved: MeshCoachSchedule? = nil) {
        guard !task().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Set or import your task first"; return }
        stop(reason: "Restart check-in schedule"); enabled = true; if let saved { schedule = saved } else { schedule.start(Date()) }; saveContext()
        status = "On · check-in every 15 min · break reminder every 50 min · no agent calls"
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        record("Check-ins started"); tick()
    }
    func testDelivery() {
        guard enabled else { return }
        schedule.nextCheck = Date().addingTimeInterval(10)
        record("Timed delivery test scheduled in 10 seconds"); tick()
    }
    func stop(reason: String = "Stop check-ins selected") {
        timer?.invalidate(); timer = nil; schedule.stop(); enabled = false
        dismiss(); status = "Off · check-ins stopped"; record("Check-ins stopped: " + reason)
    }
    func saveContext() {
        defaults.set(String(step.prefix(800)), forKey: "mesh.coach.next-step")
        defaults.set(taskURL, forKey: "mesh.coach.task-url")
    }
    private func tick() {
        guard enabled else { return }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let unlocked = session?["CGSSessionScreenIsLocked"] as? Bool != true
            && session?[kCGSessionOnConsoleKey as String] as? Bool == true
        // Passive reading and video are precisely when a check-in can help.
        // Mouse/keyboard inactivity must not suppress an explicitly active session.
        let reason = !unlocked ? "Waiting: Mac is locked or another session is active"
            : !available() ? "Waiting: voice or another foreground operation is active"
            : panel != nil ? "Check-in open · waiting for your response" : ""
        if !reason.isEmpty {
            status = reason
            if reason != lastReason { lastReason = reason; record(reason) }
            return
        }
        lastReason = ""
        let now = Date()
        if let message = schedule.due(now, available: true) { present(message); return }
        if let deadline = [schedule.nextCheck, schedule.nextBreak].compactMap({ $0 }).min() {
            let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
            status = "On · next reminder in \(seconds / 60)m \(seconds % 60)s · no agent calls"
        }
    }
    func preview() { present("This is your focus check-in. Choose what would help you now.", speak: false) }
    func reset() {
        saveContext()
        present("Reset starts here. You do not need to make up lost time. Pick one small action for the next five minutes.")
        if enabled { schedule.snooze(Date(), minutes: 5) }
    }
    func dismiss() { panel?.orderOut(nil); panel = nil; silence() }
    func respond(_ response: String) {
        dismiss()
        if response == "pause" { onBreak(); return }
        if enabled { schedule.snooze(Date(), minutes: response == "break" ? 10 : 15) }
        if response == "return" {
            if let url = URL(string: taskURL), url.scheme == "codex", url.host == "threads" { NSWorkspace.shared.open(url) }
            else { onHelp() }
        } else if response == "help" { onHelp() }
        record("Action: " + response)
        status = enabled ? "Check-ins on · \(response == "break" ? "10-minute break" : "next check-in in 15 minutes")" : "Check-ins off"
    }
    func review(_ color: String) {
        guard ["green", "yellow", "red"].contains(color) else { return }
        reviews[Self.dayKey(Date())] = color
        defaults.set(reviews, forKey: "mesh.coach.day-reviews")
    }
    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: date)
    }
    private func present(_ message: String, speak: Bool = true) {
        dismiss()
        guard let screen = NSScreen.main else { record("Delivery failed: no display"); return }
        let frame = screen.visibleFrame
        let window = MeshCoachPanel(contentRect: frame,
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Focus Buddy · Check-in"; window.level = .modalPanel
        window.isOpaque = false; window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if #available(macOS 15.0, *) { window.collectionBehavior.insert(.canJoinAllApplications) }
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MeshCoachPrompt(coach: self, message: message, title: task()))
        panel = window; window.orderFrontRegardless(); window.makeKey()
        status = "Check-in open · waiting for your response"
        record(window.isVisible ? "Check-in window presented" : "Delivery failed: window not visible")
        if spoken && speak && available() { speaker.speak(AVSpeechUtterance(string: message + " Your next step: " + (step.isEmpty ? task() : step))) }
    }
}

/// Never closes on inactivity or focus loss. Escape and visible buttons remain exits.
private final class MeshCoachPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct MeshCoachPrompt: View {
    @ObservedObject var coach: MeshFocusCoach
    let message: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("COME BACK TO YOUR PLAN").font(.caption).tracking(3).foregroundStyle(.cyan)
            Text(title).font(.largeTitle.bold()).lineLimit(2)
            Text(message).font(.title3)
            Text(coach.step.isEmpty ? "Choose one achievable next step." : coach.step).foregroundStyle(.secondary)
            HStack {
                Button("Return to task") { coach.respond("return") }.buttonStyle(.borderedProminent)
                Button("Still working") { coach.respond("working") }
                Button("Need help") { coach.respond("help") }
            }
            Text("This check-in stays until you choose. Escape dismisses it for 15 minutes.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Take a break · 10 min") { coach.respond("break") }
                    .accessibilityHint("Closes this check-in. If check-ins are on, the next task check-in is in ten minutes.")
                Spacer()
                Button(coach.enabled ? "Dismiss · next check-in in 15 min" : "Dismiss preview") { coach.respond("dismiss") }
                    .keyboardShortcut(.escape, modifiers: [])
            }.font(.callout)
            Text("To stop completely, choose Quit Mesh Monitor from the menu bar.").font(.caption).foregroundStyle(.secondary)
        }.padding(36).frame(maxWidth: 820, alignment: .leading)
            .background(Color(red: 0.025, green: 0.04, blue: 0.07), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.cyan.opacity(0.5)))
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92)).preferredColorScheme(.dark)
    }
}

struct MeshCoachControls: View {
    @ObservedObject var coach: MeshFocusCoach
    var importTask: () -> Void = {}
    @State private var confirmReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Focus Buddy").font(.title2.bold())
            Text(coach.status).font(.callout).foregroundStyle(.secondary)
            Text(coach.lastEvent).font(.caption).foregroundStyle(.secondary)
            Button("Use linked Codex task", action: importTask)
            TextField("Next small step", text: $coach.step).onSubmit { coach.saveContext() }
            TextField("Linked Codex task URL (optional)", text: $coach.taskURL).onSubmit { coach.saveContext() }
            HStack {
                Button(coach.enabled ? "Break · resumes in 10 min" : "Start check-ins") { if coach.enabled { coach.onBreak() } else { coach.start() } }
                Button("Preview check-in") { coach.preview() }
                Button("Test in 10 seconds") { coach.testDelivery() }.disabled(!coach.enabled)
                Toggle("Speak check-ins · system voice", isOn: $coach.spoken)
            }
            Text("Timed check-ins · breaks resume automatically. Quit Mesh Monitor to stop completely. No paid agent calls.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Your week · you decide how each day went").font(.headline)
            HStack {
                ForEach(0..<7, id: \.self) { offset in
                    let date = Calendar.current.date(byAdding: .day, value: offset - 6, to: Date())!
                    let color = coach.reviews[MeshFocusCoach.dayKey(date)]
                    VStack {
                        Circle().fill(color == "green" ? Color.green : color == "yellow" ? Color.yellow : color == "red" ? Color.red : Color.gray.opacity(0.25)).frame(width: 24, height: 24)
                        Text(date, format: .dateTime.weekday(.abbreviated)).font(.caption)
                    }.accessibilityLabel("\(MeshFocusCoach.dayKey(date)): \(color ?? "not reviewed")")
                }
            }
            HStack {
                Button("Green · met my plan") { coach.review("green") }
                Button("Yellow · some progress") { coach.review("yellow") }
                Button("Red · need a reset") { coach.review("red") }
            }
            Button("Break glass · start again") { confirmReset = true }
                .confirmationDialog("Start with one small step? Your history and streak stay intact.", isPresented: $confirmReset) {
                    Button("Begin a five-minute reset") { coach.reset() }
                }
        }.padding(24).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
    }
}

import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

enum MeshPage: String, CaseIterable, Identifiable {
    case focus = "Focus", conversation = "Conversation", inputs = "Inputs", morning = "Morning", captions = "Captions", connections = "Connections", system = "System"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .focus: "scope"
        case .conversation: "bubble.left.and.bubble.right"
        case .inputs: "viewfinder"
        case .morning: "sun.max"
        case .captions: "captions.bubble"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .system: "waveform.path.ecg"
        }
    }
}

enum MeshEvidenceChoice: String, CaseIterable, Identifiable {
    case none = "Off", screen = "Screen", room = "Room", both = "Both"
    var id: String { rawValue }
    var includesScreen: Bool { self == .screen || self == .both }
    var includesRoom: Bool { self == .room || self == .both }
}

private struct MeshQuestion {
    let original: String
    let images: [Data]
    let observation: String
    let context: String
    let localContext: String
    let capturedAt: Date
}

@MainActor final class MeshMonitor: ObservableObject {
    @Published private(set) var isTerminating = false
    private let termination = MeshTerminationGate()
    @Published var page: MeshPage = .focus
    @Published var taskTitle = ""
    @Published var finishCondition = ""
    @Published var draft = ""
    @Published var provider = "Codex"
    @Published var evidenceChoice: MeshEvidenceChoice = .none
    @Published var messages: [MeshMessage] = []
    @Published private(set) var historyStatus = "Recent text is saved locally · up to 60 messages"
    @Published private(set) var historyError: String?
    @Published var streaming = ""
    @Published var status = "Ready when you are"
    @Published var busy = false
    @Published var connected = false
    @Published var connectionStatus = "Disconnected"
    @Published var controlRoomStatus = "Physical AIY wake required · scheduled replies"
    @Published var cameraID = ""
    @Published var cameraDevices: [MeshCameraDevice] = []
    @Published var useM1 = false
    @Published var manualM1Snapshot = false
    @Published var m1CameraID = ""
    @Published var m1LocalPort = ""
    @Published var m1RemotePort = ""
    @Published var morningTrigger = "AIY button"
    @Published var nightMode = false
    @Published var gazeDisplayID = "" { didSet { if oldValue != gazeDisplayID { backgroundGazeContextChanged() } } }
    @Published var gazeCameraID = "" { didSet { if oldValue != gazeCameraID { backgroundGazeContextChanged() } } }
    @Published var gazeCalibrationID = "" { didSet { if oldValue != gazeCalibrationID { backgroundGazeContextChanged() } } }
    @Published private(set) var backgroundGazeEnabled = false
    @Published private(set) var backgroundGazeStatus = "Off · background checks use the screen only"
    private var backgroundGazeEpoch = UUID()
    @Published var snapshotURL = ""
    @Published var lastResponseMS: Int?
    @Published var firstTokenMS: Int?
    @Published var localStatus = "Stopped · loads only for a local question"
    @Published var lastEvidence = "No evidence sent"
    let home = MeshHomeCalendar()
    let focus = MeshFocusState()
    let coach = MeshFocusCoach()
    let camera = MeshCameraPresence()
    let neoCursorRuntime = MeshNeoCursorRuntime()
    let screen = MeshScreenContext()
    let voice = MeshVoiceBridge()
    let voiceStart = MeshVoiceStart()
    var voiceRequested: Bool { voice.isActive || voiceStart.isStarting }
    var voiceStatus: String { voiceStart.isStarting ? "Connecting conversation · microphone off" : voice.status }
    let transcription = MeshTranscription()
    private var notch: MeshNotchController?
    private var openApp: (() -> Void)?
    var openCaptionPanel: (() -> Void)?
    var openCompanionPanel: (() -> Void)?
    let morning = MeshMorningState()
    let metrics = MeshRuntimeMetrics()
    let activity = MeshFocusActivity()
    let monitor = MeshFocusMonitor()
    let m1Return = MeshM1ReturnTrigger()
    let m1Camera = MeshM1CameraRuntime()
    private var voiceAfterMorning = false
    private let local = M4ResidentLFMVisionBrain()
    private var codex: MeshCodexClient!
    private let controlRoom = MeshControlRoomClient()
    private var subscriptions = Set<AnyCancellable>()
    private var work: Task<Void, Never>?
    private var conversationSetup: Task<MeshAgentConnection, Error>?
    private var conversationSetupID: UUID?
    private var morningArmTask: Task<Void, Never>?
    private var morningArmID = UUID()
    private var epoch = UUID()
    private var activeStarted: Date?
    private var lastQuestion: MeshQuestion?
    private var preparingMorning = false
    private var wakeSetupEnabled = false
    private var spokenMorning = false
    private var calibrationPanel: NSPanel?
    private let conversationHistory: MeshConversationHistory?

    init(persistConversationHistory: Bool = true) {
        let savesHistory = persistConversationHistory && MeshConversationHistory.storageEnabled(
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        conversationHistory = savesHistory ? MeshConversationHistory(directory: Self.dataDirectory) : nil
        if let conversationHistory {
            do {
                let saved = try conversationHistory.load()
                messages = saved.messages
                historyStatus = saved.messages.isEmpty
                    ? "No saved transcript yet · future text is saved locally, up to 60 messages"
                    : "Restored \(saved.messages.count) saved messages · latest 60 locally\(saved.hasExcerpts ? " · includes labelled excerpts" : "")"
            } catch { historyError = error.localizedDescription; historyStatus = "Saved transcript could not be restored" }
        } else { historyStatus = "Design preview · conversation storage off" }
        taskTitle = UserDefaults.standard.string(forKey: "mesh.monitor.task") ?? ""
        finishCondition = UserDefaults.standard.string(forKey: "mesh.monitor.finish") ?? ""
        snapshotURL = UserDefaults.standard.string(forKey: "mesh.monitor.camera-url") ?? ""
        if let setup = Self.savedM1CameraSetup() {
            m1CameraID = setup.cameraID; m1LocalPort = String(setup.localPort); m1RemotePort = String(setup.remotePort)
        }
        codex = MeshCodexClient(workingDirectory: Self.dataDirectory,
                              resumeThreadID: UserDefaults.standard.string(forKey: "mesh.monitor.codex-thread"))
        coach.task = { [weak self] in self?.taskTitle ?? "" }
        coach.available = { [weak self] in
            guard let self else { return false }
            return !self.isTerminating && !self.nightMode && !self.voiceRequested && !self.busy
        }
        coach.onScheduleChange = { [weak self] in self?.persistFocusSession() }
        coach.onBreak = { [weak self] in self?.pauseForBreak() }
        coach.onHelp = { [weak self] in self?.page = .conversation; self?.openApp?() }
        codex.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .status(value): self.connectionStatus = value; self.connected = self.codex.connection != nil
            case let .approvalBlocked(value): self.status = value
            case let .connected(value):
                self.connected = true; self.connectionStatus = "Connected · \(value.authMode)"
                UserDefaults.standard.set(value.threadID, forKey: "mesh.monitor.codex-thread")
            case let .textDelta(value):
                guard self.busy else { return }
                if self.firstTokenMS == nil, let started = self.activeStarted {
                    self.firstTokenMS = Int(Date().timeIntervalSince(started) * 1000)
                }
                self.streaming += value
            }
        }
        controlRoom.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .status(value), let .approvalBlocked(value): self.controlRoomStatus = value
            case .connected: self.controlRoomStatus = "Existing Control Room · scheduled bridge · delivery time unavailable"
            case .textDelta: break
            }
        }
        m1Camera.onSourceReady = { [weak self] connection in
            guard let self else { return }
            guard !self.isTerminating, !self.nightMode, !self.focus.isPaused else { self.m1Camera.stop(); return }
            self.camera.start(source: .managedSnapshot(connection: connection))
        }
        m1Camera.onRevoke = { [weak self] in
            guard let self else { return }
            if case .managedSnapshot = self.camera.source {
                self.closeCalibration(); self.camera.stop(); self.morning.disarm()
                self.backgroundGazeContextChanged()
            }
        }
        camera.onManagedFrame = { [weak self] identity, timestamp in
            self?.m1Camera.receivedFrame(identity: identity, capturedAt: timestamp)
        }
        camera.onManagedFailure = { [weak self] _ in self?.stopCamera() }
        for publisher in [coach.objectWillChange, home.objectWillChange, focus.objectWillChange, camera.objectWillChange, neoCursorRuntime.objectWillChange, screen.objectWillChange, voice.objectWillChange, voiceStart.objectWillChange, transcription.objectWillChange, morning.objectWillChange, metrics.objectWillChange, activity.objectWillChange, monitor.objectWillChange, m1Return.objectWillChange, m1Camera.objectWillChange] {
            publisher.sink { [weak self] _ in
                self?.objectWillChange.send()
                Task { @MainActor [weak self] in self?.publishWakeStatus() }
            }.store(in: &subscriptions)
        }
        objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshNotch() }
        }.store(in: &subscriptions)
        monitor.observe = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.observeFocusScreen()
        }
        monitor.deferReason = { [weak self] in
            guard let self, !self.isTerminating else { return .stopping }
            if self.focus.isPaused { return .paused }
            if self.busy { return .conversation }
            if self.screen.busy { return .screenCapture }
            if self.voiceStart.isStarting || [.loading, .transcribing, .thinking, .speaking].contains(self.voice.phase) { return .voice }
            if !self.screen.hasExternalForeground { return .noExternalApplication }
            return nil
        }
        voice.onUtterance = { [weak self] text in
            guard let self else { throw CancellationError() }
            return try await self.answer(text)
        }
        voice.onFailure = { [weak self] reason in
            self?.status = reason
            if self?.spokenMorning == true { self?.morning.markDeliveryFailed(reason); self?.spokenMorning = false; self?.voiceAfterMorning = false }
        }
        voice.onSpeechFinished = { [weak self] in
            guard let self, self.spokenMorning else { return }
            self.morning.markDeliveryFinished(); self.spokenMorning = false
            if self.voiceAfterMorning {
                self.voiceAfterMorning = false
                self.startVoice()
            }
        }
        morning.isPaused = { [weak self] in self?.focus.isPaused ?? true }
        morning.onDelivery = { [weak self] text in
            guard let self, !self.focus.isPaused else { return }
            self.voiceStart.cancel()
            self.spokenMorning = true
            self.recordMessage(MeshMessage(role: "Home briefing", text: text, evidence: "Prepared Home calendar · spoken locally"))
            self.voice.speak(text)
        }
        camera.onGreetingRequested = { [weak self] arrival in
            guard let self, !self.focus.isPaused else { return }
            guard self.morningTrigger == "Camera arrival" else { return }
            _ = self.morning.refreshQueuedBrief()
            if !self.morning.arrival(arrival), self.morning.armed {
                self.camera.arm(sessionID: UUID())
            }
        }
        m1Return.onReturn = { [weak self] event in
            guard let self, !self.focus.isPaused, self.morning.armed,
                  self.morningTrigger == "AIY button", self.m1Return.isArmed else { return }
            // The gate emits only a fresh authenticated physical Dark-to-desktop edge.
            // Neither file publication nor a clock tick calls this path.
            _ = self.morning.refreshQueuedBrief()
            do {
                // The everyday conversation uses the dedicated direct Codex route.
                // The scheduled Control Room bridge is an optional advanced route.
                if self.provider == "Control Room" { try self.controlRoom.beginSession(proof: event) }
                else { self.provider = "Codex"; self.evidenceChoice = .screen }
                self.voiceAfterMorning = true
            } catch {
                self.voiceAfterMorning = false
                self.controlRoomStatus = error.localizedDescription
            }
            self.nightMode = false; self.page = .morning
            self.notch?.show()
            if !self.morning.userReturn(UUID(uuidString: String(event.receiptID.suffix(36))) ?? UUID()) {
                self.voiceAfterMorning = false; self.controlRoom.revokeSession()
            }
            self.status = self.morning.status
        }
        m1Return.onSessionAlive = { [weak self] update in
            guard let self, self.provider == "Control Room", self.controlRoom.hasSession else { return }
            do { try self.controlRoom.refreshLiveness(update) }
            catch { self.pause(); self.status = "Physical session continuity lost · voice stopped" }
        }
        m1Return.onSessionEnded = { [weak self] in
            guard let self else { return }
            self.pause(); self.nightMode = true
            self.status = "AIY session ended · camera, microphone and speech off"
        }
        if !ProcessInfo.processInfo.arguments.contains("--render-design-preview"),
           !ProcessInfo.processInfo.arguments.contains("--quiet-launch"),
           let saved = MeshFocusRecovery.load() {
            Task { @MainActor [weak self] in self?.recoverFocusSession(saved) }
        }
        // Normal construction is inert. An explicitly supplied, fresh, one-use
        // setup receipt can arm the silent watcher while the Mac remains locked.
        if ProcessInfo.processInfo.arguments.contains("--quiet-launch") {
            // Maintenance relaunch: report state but do not arm, resume, capture,
            // speak, or create a window. Reopening the app still opens its dashboard.
            wakeSetupEnabled = true
            Task { @MainActor [weak self] in self?.publishWakeStatus() }
        }
        if ProcessInfo.processInfo.arguments.contains("--start-focus-session") {
            wakeSetupEnabled = true
            Task { @MainActor [weak self] in self?.startFocusSession() }
        }
        do {
            if try MeshWakeSetup.consume(arguments: ProcessInfo.processInfo.arguments, directory: Self.dataDirectory, now: Date()) {
                wakeSetupEnabled = true; page = .morning
                Task { @MainActor [weak self] in self?.armMorning(); self?.publishWakeStatus() }
            }
        } catch {
            status = "Wake setup refused: \(error.localizedDescription)"
            FileHandle.standardError.write(Data((status + "\n").utf8))
        }
    }

    private func publishWakeStatus() {
        guard wakeSetupEnabled else { return }
        let brief = morning.contextBrief
        let value: [String: Any] = [
            "schema": "mesh.wake-readiness.v1", "version": "0.6.9", "build": "21", "pid": ProcessInfo.processInfo.processIdentifier,
            "observedAt": Date().ISO8601Format(), "intendedDate": morning.selectedDay,
            "armed": morning.armed, "watcherArmed": m1Return.isArmed,
            "ready": morning.armed && m1Return.isReady && nightMode && !focus.isPaused && !voiceRequested && !camera.isRunning && !m1Camera.hasOwnedTransport && !m1Camera.captureMayBeActive && !neoCursorRuntime.isRunning && !neoCursorRuntime.isStarting && !neoCursorRuntime.isStopping && !transcription.isActive && brief != nil,
            "night": nightMode, "paused": focus.isPaused, "trigger": morningTrigger,
            "stationMode": m1Return.lastStationMode ?? "unknown",
            "microphoneActive": voice.isListening || (transcription.isActive && transcription.source == .microphone),
            "conversationBusy": busy,
            "transcriptionActive": transcription.isActive, "voiceActive": voice.isActive,
            "voiceStarting": voiceStart.isStarting, "voiceWorkersOwned": voice.hasOwnedWorkers,
            "cameraActive": camera.isRunning || m1Camera.captureMayBeActive || neoCursorRuntime.captureActive || neoCursorRuntime.isStopping,
            "m1CameraPhase": m1Camera.phase.rawValue, "m1CameraShutdown": m1Camera.shutdown.rawValue,
            "m1CameraTransportOwned": m1Camera.hasOwnedTransport,
            "neoCursorProcessRunning": neoCursorRuntime.isRunning,
            "neoCursorStarting": neoCursorRuntime.isStarting, "neoCursorStopping": neoCursorRuntime.isStopping,
            "neoCursorFrameObserved": neoCursorRuntime.frameObserved, "briefAvailable": brief != nil,
            "neoCursorReadiness": neoCursorRuntime.readiness.rawValue,
            "neoCursorReadinessSummary": neoCursorRuntime.readinessSummary,
            "briefGeneratedAt": brief?.generatedAt?.ISO8601Format() ?? "unavailable",
            "briefNotBefore": morning.notBefore?.ISO8601Format() ?? "unavailable",
            "buttonStatus": m1Return.status, "m1DisarmStatus": m1Return.disarmStatus,
            "terminating": isTerminating, "morningStatus": morning.status,
            "focusMonitorRunning": monitor.isRunning, "focusMonitorAnalyzing": monitor.isAnalyzing,
            "focusObservationCount": monitor.count, "focusMonitorStatus": monitor.status,
            "lastFocusObservedAt": monitor.lastObservedAt?.ISO8601Format() ?? "unavailable",
            "focusLastAnalysisMS": monitor.lastAnalysisMS ?? -1,
            "focusFailedChecks": monitor.errorCount, "focusDeferredChecks": monitor.deferredCount,
            "focusDeferralReason": monitor.deferralReason?.rawValue ?? "none",
            "backgroundGazeEnabled": backgroundGazeEnabled, "backgroundGazeStatus": backgroundGazeStatus,
            "lastFocusGazeSource": monitor.lastObservation?.gazeSource ?? "none",
            "focusLastError": monitor.lastError ?? "", "externalAppForeground": screen.hasExternalForeground,
            "screenPermissionGranted": screen.permissionGranted,
            "directCodexConnected": codex.connection != nil,
            "memoryCurrentRSSMB": metrics.currentMB ?? -1, "memoryPeakSampledRSSMB": metrics.peakMB ?? -1,
            "memoryProcessCount": metrics.processCount, "memoryStatus": metrics.status,
            "conversationProvider": provider, "conversationStatus": conversationSummary,
            "codexSessionModel": codex.connection?.resolvedModel ?? "unreported",
            "codexSessionModelProvider": codex.connection?.modelProvider ?? "unreported",
            "gazeStatus": gazeSummary, "nativeGazeStatus": camera.nativeGazeStatus
        ]
        do { try MeshWakeSetup.publishStatus(value, directory: Self.dataDirectory) }
        catch { status = "Wake state could not be saved: \(error.localizedDescription)" }
    }

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor", isDirectory: true)
    }

    var monitoringSummary: String {
        if focus.isPaused || !monitor.isRunning { return "Paused · Start session to monitor this Mac" }
        if !screen.permissionGranted { return "Waiting for Screen Recording permission" }
        if monitor.isAnalyzing { return monitor.lastError == nil ? "Monitoring · reading a local screen snapshot" : "Retrying the screen check locally" }
        if let reason = monitor.deferralReason { return reason.status }
        if monitor.lastError != nil { return "Last screen check failed · another check is scheduled" }
        if !screen.hasExternalForeground { return "On · waiting for you to use another app" }
        return "Monitoring · a local screen check about every minute"
    }
    var conversationSummary: String {
        if voiceRequested { return "\(provider) · \(voiceStatus)" }
        if provider == "Control Room" { return "Control Room · \(controlRoomStatus)" }
        if provider == "Codex" {
            return codex.connection != nil ? "Codex connected · microphone off until Talk" : "Codex · \(connectionStatus)"
        }
        return "Local 3B · microphone off until Talk"
    }
    var codexSessionModelSummary: String {
        guard let connection = codex.connection else { return "Session model: available after Codex connects" }
        guard let model = connection.resolvedModel else { return "Session model: Codex did not report it" }
        return "Session model: \(model)"
    }
    var conversationModelSummary: String {
        switch provider {
        case "Codex": codexSessionModelSummary
        case "Local 3B": "Local model: LFM2.5-VL-3B · this Mac"
        default: "Control Room model: not reported by the scheduled connection"
        }
    }
    var screenUnderstandingSummary: String {
        guard monitor.isRunning else { return "Off · Start session enables local 3B screen checks" }
        guard screen.permissionGranted else { return "Blocked · allow Screen Recording" }
        if let problem = monitor.lastError { return "Screen check failed · \(problem)" }
        guard let date = monitor.lastObservedAt else {
            return monitor.isAnalyzing ? "Local 3B · first screen check in progress" : monitor.status
        }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let phase = monitor.isAnalyzing ? "Analyzing" : monitor.status
        return "\(phase) · local 3B · last observed \(seconds)s ago · \(monitor.lastAnalysisMS ?? 0) ms"
    }
    var gazeSummary: String {
        if let gaze = camera.neoCursorObservation,
           gaze.isUsable(cameraID: gaze.cameraID, displayID: gaze.displayID, calibrationID: gaze.calibrationID, now: Date()) {
            return "Calibrated gaze · fresh observation"
        }
        if let gaze = camera.nativeGazeObservation, gaze.isUsable(now: Date()) {
            return "Native gaze · fresh calibrated observation"
        }
        if neoCursorRuntime.isRunning {
            return "\(camera.isRunning ? "Webcam preview on · " : "")\(neoCursorRuntime.status) · gaze not calibrated"
        }
        if camera.isRunning { return "Webcam preview on · gaze not calibrated" }
        return "Not enabled · M4 screen trial first, webcam later"
    }
    var latestFocusObservation: String? {
        guard let value = monitor.lastObservation else { return nil }
        return value.sample.observation + "\n" + value.sample.reasoning
    }
    var focusObservationCount: Int { monitor.count }

    private var restoreCoachAfterPause = false
    private var persistentFocusSession = false
    private var focusResumeTimer: Timer?
    private var focusResumeAt: Date?
    private func persistFocusSession() {
        guard persistentFocusSession, !isTerminating, coach.enabled, focusResumeAt == nil else { return }
        do { try MeshFocusRecovery(task: taskTitle, finish: finishCondition, schedule: coach.recoverySchedule, spoken: coach.spoken).save() }
        catch { status = "Session recovery could not be saved: \(error.localizedDescription)" }
    }
    private func recoverFocusSession(_ saved: MeshFocusRecovery) {
        taskTitle = saved.task; finishCondition = saved.finish
        persistentFocusSession = true
        coach.spoken = saved.spoken
        if let until = saved.resumeAt, until > Date() {
            focusResumeAt = until
            _ = focus.setPaused(true)
            status = "On break · monitoring resumes at \(until.formatted(date: .omitted, time: .shortened))"
            armFocusResume(until)
        } else { startFocusSession(restoring: saved.schedule) }
    }
    private func armFocusResume(_ until: Date) {
        focusResumeTimer?.invalidate()
        let timer = Timer(timeInterval: max(1, until.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating, let saved = MeshFocusRecovery.load() else { return }
                self.recoverFocusSession(saved)
            }
        }
        RunLoop.main.add(timer, forMode: .common); focusResumeTimer = timer
    }
    func pauseForBreak(minutes: Double = 10) {
        guard !isTerminating else { return }
        var schedule = coach.recoverySchedule
        if schedule.nextCheck == nil { schedule.start(Date()) }
        schedule.snooze(Date(), minutes: minutes)
        let until = Date().addingTimeInterval(minutes * 60)
        let saved = MeshFocusRecovery(task: taskTitle, finish: finishCondition, schedule: schedule, spoken: coach.spoken, resumeAt: until)
        do { try saved.save() }
        catch { status = "Break could not be scheduled: \(error.localizedDescription)"; return }
        persistentFocusSession = true; focusResumeAt = until
        pause()
        armFocusResume(until)
        status = "On break · monitoring resumes at \(until.formatted(date: .omitted, time: .shortened))"
    }
    var sessionToggleTitle: String { focus.isPaused || !monitor.isRunning ? "Resume monitoring now" : "Break · resumes in 10 min" }
    func toggleMonitoring() {
        if focus.isPaused || !monitor.isRunning { startFocusSession() } else { pauseForBreak() }
    }
    func startFocusSession(restoring saved: MeshCoachSchedule? = nil) {
        guard !isTerminating else { return }
        guard !voiceRequested else { status = "Stop voice before starting a new focus session."; return }
        focusResumeTimer?.invalidate(); focusResumeTimer = nil; focusResumeAt = nil
        resume()
        guard !focus.isPaused else { return }
        persistentFocusSession = true
        provider = "Codex"; evidenceChoice = .screen
        page = .focus; wakeSetupEnabled = true
        home.refresh(Date())
        monitor.start(task: taskTitle, finishCondition: finishCondition)
        coach.start(restoring: saved); restoreCoachAfterPause = false
        persistFocusSession()
        if !screen.permissionGranted { screen.requestPermission() }
        connect()
        _ = notch?.show()
        status = taskTitle.isEmpty ? "M4 monitoring started · set your task to interpret activity" : "M4 monitoring started · Talk when you want help"
        publishWakeStatus()
    }

    private func ensureCodex() async throws -> MeshAgentConnection {
        try await codex.finishCancellation()
        try Task.checkCancellation()
        if let value = codex.connection { return value }
        if let pending = conversationSetup { return try await pending.value }
        let id = UUID()
        let pending = Task { try await codex.connect() }
        conversationSetup = pending; conversationSetupID = id
        defer { if conversationSetupID == id { conversationSetup = nil; conversationSetupID = nil } }
        return try await pending.value
    }

    private func observeFocusScreen() async throws -> MeshFocusSample {
        try Task.checkCancellation()
        guard !focus.isPaused, !isTerminating, !busy else { throw CancellationError() }
        let gazeEpoch = backgroundGazeEpoch
        let frame = try await screen.capture(foregroundOnly: true)
        let observedApplication = screen.targetApplication
        try Task.checkCancellation()
        guard gazeEpoch == backgroundGazeEpoch else { throw CancellationError() }
        let gaze = MeshFocusGazeContext.prepare(enabled: backgroundGazeEnabled,
            expectedCameraID: gazeCameraID, expectedDisplayID: gazeDisplayID, expectedCalibrationID: gazeCalibrationID,
            neoCursor: camera.neoCursorObservation, native: camera.nativeGazeObservation,
            geometry: frame.geometry, screenCapturedAt: frame.capturedAt, now: Date())
        localStatus = "Local 3B · checking screen"
        let result = try await local.observeFocus(image: frame.jpeg, task: monitor.task,
            finishCondition: monitor.finishCondition, appName: observedApplication, screenText: frame.text,
            gazeContext: gaze.modelText)
        try Task.checkCancellation()
        guard gazeEpoch == backgroundGazeEpoch else { throw CancellationError() }
        let data = Data(result.text.utf8)
        struct Interpretation: Decodable { let observation: String; let relation: String; let reasoning: String }
        guard data.count <= 8_000, let value = try? JSONDecoder().decode(Interpretation.self, from: data),
              !value.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeshCodexError.invalidInput("The local model returned an unreadable screen observation. It will retry next minute.")
        }
        let relation: MeshFocusRelation
        switch value.relation {
        case "on_task": relation = .onTask
        case "possible_detour": relation = .possibleDetour
        default: relation = .unclear
        }
        localStatus = "Resident · \(result.inferenceMS) ms last screen check"
        backgroundGazeStatus = "Last screen check: " + gaze.status
        var sample = MeshFocusSample(appName: observedApplication, observation: String(value.observation.prefix(600)),
            relation: relation, reasoning: String(value.reasoning.prefix(600)), inferenceMS: result.inferenceMS,
            capturedAt: frame.capturedAt)
        sample.gazeStatus = gaze.status; sample.gazeSource = gaze.source?.rawValue; sample.gazeProvenance = gaze.provenance
        return sample
    }

    func setBackgroundGazeEnabled(_ enabled: Bool) {
        guard (!isTerminating || !enabled), (!focus.isPaused || !enabled), backgroundGazeEnabled != enabled else { return }
        backgroundGazeEnabled = enabled
        backgroundGazeContextChanged()
    }

    private func backgroundGazeContextChanged() {
        backgroundGazeEpoch = UUID()
        backgroundGazeStatus = backgroundGazeEnabled ? "Waiting for the next screen check · no camera starts automatically" : "Off · background checks use the screen only"
        monitor.contextChanged()
    }

    func stopGazeImport() {
        camera.stopNeoCursorImport()
        backgroundGazeContextChanged()
    }

    func correctObservation(_ label: String) {
        let relation: MeshFocusFeedbackRelation
        switch label {
        case "On task": relation = .onTask
        case "Useful detour": relation = .usefulDetour
        default: relation = .distracted
        }
        monitor.recordFeedback(relation: relation, note: label, source: .button, observationID: monitor.lastObservation?.id)
    }

    func exportFocusReview() {
        do {
            let report = try monitor.exportReview(days: 3)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "Mesh Monitor trial review.md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data(report.utf8).write(to: url, options: .atomic)
            status = "Trial review exported · local observations and your corrections"
        } catch { status = error.localizedDescription }
    }

    func requestTermination(_ app: NSApplication) -> NSApplication.TerminateReply {
        if termination.outcome != nil { return .terminateNow }
        do { try MeshFocusRecovery.clear() }
        catch { status = "Could not disable automatic recovery. Quit cancelled: \(error.localizedDescription)"; return .terminateCancel }
        persistentFocusSession = false
        focusResumeTimer?.invalidate(); focusResumeTimer = nil; focusResumeAt = nil
        termination.begin(stop: { [self] in
            isTerminating = true
            pause()
            notch?.hide()
            status = "Quitting · finishing voice, camera and wake cleanup…"
        }, drain: { [self] in
            async let wake: Void = m1Return.finishStop()
            async let camera: Void = m1Camera.finishStop()
            async let speech: Void = voice.finishStop()
            _ = await (wake, camera, speech)
        }, cancel: { [self] in
            m1Return.cancelPendingDisarm()
            m1Camera.cancelPendingStop()
        }, reply: { [self] outcome in
            let receipt: [String: Any] = [
                "schema": "mesh.shutdown.v1", "observedAt": Date().ISO8601Format(),
                "pid": ProcessInfo.processInfo.processIdentifier,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                "termination": outcome.rawValue, "m1Disarm": m1Return.disarmStatus,
                "m1CameraShutdown": m1Camera.shutdown.rawValue,
                "voiceWorkerShutdown": voice.hasOwnedWorkers ? "unconfirmed" : "exited"
            ]
            do { try MeshWakeSetup.publishShutdown(receipt, directory: Self.dataDirectory) }
            catch { FileHandle.standardError.write(Data("Mesh shutdown receipt could not be saved.\n".utf8)) }
            app.reply(toApplicationShouldTerminate: true)
        })
        return .terminateLater
    }

    func resume() {
        guard !isTerminating else { return }
        guard focus.setPaused(false) else { status = focus.status; return }
        metrics.startMonitoring()
        activity.start(); nightMode = false
        UserDefaults.standard.set(taskTitle, forKey: "mesh.monitor.task")
        UserDefaults.standard.set(finishCondition, forKey: "mesh.monitor.finish")
        status = "Ready · choose an input or start a focus session"
    }

    func pause() {
        restoreCoachAfterPause = restoreCoachAfterPause || coach.enabled
        coach.stop(reason: isTerminating ? "App terminating" : "Session paused")
        voiceStart.cancel()
        let saved = focus.setPaused(true)
        morningArmID = UUID(); morningArmTask?.cancel(); morningArmTask = nil
        interruptMorning()
        closeCalibration()
        epoch = UUID(); work?.cancel(); work = nil
        monitor.stop(); setBackgroundGazeEnabled(false); conversationSetup?.cancel(); conversationSetup = nil; conversationSetupID = nil
        voice.stop(); transcription.stop(); local.stop(); stopCamera(); neoCursorRuntime.stop(); screen.clear(); morning.disarm(); m1Return.stop()
        metrics.stop()
        activity.stop()
        codex.disconnect(); controlRoom.revokeSession(); connected = false; connectionStatus = "Disconnected"
        busy = false; streaming = ""; localStatus = "Stopped"
        status = saved ? (m1Camera.captureMayBeActive || m1Camera.hasOwnedTransport
            ? "Paused · local inputs stopped · M1 camera shutdown pending"
            : "Paused · microphone, camera and agent stopped") : focus.status
    }

    func connect() {
        guard !isTerminating else { return }
        guard !busy else { return }
        let token = epoch
        work = Task {
            do {
                try FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                _ = try await ensureCodex()
            } catch {
                guard token == epoch, !Task.isCancelled else { return }
                connectionStatus = error.localizedDescription; connected = false
            }
        }
    }

    func disconnect() { voiceStart.cancel(); conversationSetup?.cancel(); conversationSetup = nil; conversationSetupID = nil; codex.disconnect(); controlRoom.revokeSession(); connected = false; connectionStatus = "Disconnected" }

    func send() {
        guard !isTerminating else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""; page = .conversation
        work = Task { do { _ = try await answer(text) } catch { status = error.localizedDescription } }
    }

    func askCodexDeeper() {
        guard !isTerminating else { return }
        guard let question = lastQuestion, !busy, !voiceRequested else { return }
        provider = "Codex"; page = .conversation
        work = Task { do { _ = try await answer(question.original, preserved: question) } catch { status = error.localizedDescription } }
    }

    var canAskCodexDeeper: Bool { lastQuestion != nil && !busy && !voiceRequested }

    func clearConversationHistory() {
        guard !isTerminating, !busy, !voiceRequested, let conversationHistory else { return }
        do {
            try conversationHistory.clear()
            messages = []; lastQuestion = nil
            historyError = nil
            historyStatus = "Local history cleared; connected agents keep their own history."
        } catch { historyError = error.localizedDescription; historyStatus = "Local conversation history was not cleared" }
    }

    private func recordMessage(_ message: MeshMessage) {
        messages.append(message)
        if messages.count > MeshConversationHistory.maximumMessages {
            messages.removeFirst(messages.count - MeshConversationHistory.maximumMessages)
        }
        guard let conversationHistory else { return }
        do {
            let saved = try conversationHistory.save(messages)
            historyError = nil
            historyStatus = "Saved \(saved.messages.count) recent messages on this Mac · up to 60\(saved.hasExcerpts ? " · includes labelled excerpts" : "")"
        } catch { historyError = error.localizedDescription; historyStatus = "Latest conversation text is not confirmed saved" }
    }

    private func answer(_ text: String, preserved: MeshQuestion? = nil) async throws -> String {
        try Task.checkCancellation()
        guard !busy else { throw MeshCodexError.busy }
        if focus.isPaused { resume() }
        guard !focus.isPaused else { throw MeshCodexError.invalidInput("Resume the session first.") }
        busy = true; streaming = ""; firstTokenMS = nil; activeStarted = Date()
        let token = epoch
        let chosenProvider = provider
        defer { if epoch == token { busy = false; streaming = "" } }
        do {
            guard await monitor.suspendCurrentAnalysis() else {
                throw MeshCodexError.invalidInput("The local screen check is still stopping. Try again when it has finished.")
            }
            try Task.checkCancellation()
            guard epoch == token else { throw CancellationError() }
            let question: MeshQuestion
            if let preserved { question = preserved }
            else {
                var images: [Data] = []
                var evidence = MeshQuestionEvidence.Input()
                var capturedScreen: MeshScreenFrame?
                let sharesScreen = chosenProvider != "Control Room" && evidenceChoice.includesScreen
                if sharesScreen {
                    status = "Capturing the app you selected…"
                    let frame = try await screen.capture()
                    images.append(frame.jpeg)
                    capturedScreen = frame
                    evidence.screenSource = "Image 1 captured \(frame.capturedAt.ISO8601Format()). OCR and selected text are capture excerpts of at most 8,000 characters each. Screen window: \(frame.source.prefix(180))."
                    evidence.screenGeometry = frame.geometry.description + "\n" + frame.pointer
                    evidence.selectedText = frame.selectedText
                    evidence.ocr = frame.text
                }
                if chosenProvider != "Control Room", evidenceChoice.includesRoom {
                    guard camera.freshness == .fresh, let image = camera.preview,
                          let capturedAt = camera.lastFrameAt, Date().timeIntervalSince(capturedAt) <= 3,
                          let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                          let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
                    else { throw MeshCaptureError.staleRoom }
                    images.append(jpeg)
                    evidence.room = "Image \(images.count): room camera, captured \(capturedAt.ISO8601Format()). Face presence does not establish identity, emotion, understanding, or task intent."
                }
                let gazeTime = Date()
                let neoCursor = camera.neoCursorObservation
                let nativeGaze = camera.nativeGazeObservation
                var gazeDescriptions: [String] = []
                if sharesScreen, let frame = capturedScreen {
                    if let gaze = neoCursor, gaze.isUsable(cameraID: gaze.cameraID, displayID: gaze.displayID,
                                                          calibrationID: gaze.calibrationID, now: gazeTime) {
                        gazeDescriptions.append(frame.geometry.gazeDescription(point: CGPoint(x: gaze.x, y: gaze.y),
                            displayID: gaze.displayID, gazeCapturedAt: gaze.capturedAt,
                            imageCapturedAt: frame.capturedAt, source: "NeoCursor"))
                    }
                    if let gaze = nativeGaze, gaze.isUsable(now: gazeTime) {
                        gazeDescriptions.append(frame.geometry.gazeDescription(point: gaze.point, displayID: gaze.displayID,
                            gazeCapturedAt: gaze.capturedAt, imageCapturedAt: frame.capturedAt, source: "Native"))
                    }
                }
                gazeDescriptions += MeshGazeEvidence.descriptions(sharesScreen: sharesScreen,
                    neoCursor: neoCursor, native: nativeGaze, now: gazeTime)
                evidence.gaze = gazeDescriptions.joined(separator: "\n")
                let brief = home.compactBrief(for: Date())
                evidence.task = taskTitle; evidence.finishCondition = finishCondition
                evidence.activity = activity.snapshotDescription
                if let observation = monitor.lastObservation {
                    evidence.activity += "\nEarlier local-model interpretation at \(observation.observedAt.ISO8601Format()) (may differ from the attached current image; not established task progress): \(observation.observation). \(observation.reasoning)"
                }
                evidence.recentConversation = "Most recent first (reference only):\n" + messages.suffix(6).reversed().map { "\($0.role): \($0.text)" }.joined(separator: "\n")
                evidence.home = chosenProvider == "Control Room" ? "Prepared Home brief: \(morning.preparedBrief ?? "Unavailable")" : (brief.canNarrate ? "Home calendar, read at \(brief.generatedAt?.ISO8601Format() ?? "unknown"): \(brief.text)" : "Home calendar not available for today.")
                let prepared = try MeshQuestionEvidence.prepare(evidence)
                question = MeshQuestion(original: text, images: images, observation: prepared.observationText,
                    context: prepared.contextText, localContext: prepared.localText, capturedAt: Date())
            }
            try Task.checkCancellation(); guard epoch == token else { throw CancellationError() }
            lastQuestion = question
            lastEvidence = "Original message + \(question.images.count) selected image(s) + task context · \(chosenProvider)"
            recordMessage(MeshMessage(role: "You", text: text, evidence: lastEvidence))
            let reply: String
            if chosenProvider == "Codex" || chosenProvider == "Control Room" {
                let backend: any MeshAgentBackend = chosenProvider == "Control Room" ? controlRoom : codex
                status = chosenProvider == "Control Room" ? "Awaiting existing Control Room · delivery time unavailable" : "Codex is working with your original question…"
                try FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if chosenProvider == "Codex" { _ = try await ensureCodex() }
                else { _ = try await backend.connect() }
                try Task.checkCancellation(); guard epoch == token else { throw CancellationError() }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-evidence-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                var urls: [URL] = []
                for (index, image) in question.images.enumerated() {
                    let url = directory.appendingPathComponent("image-\(index + 1).jpg")
                    try image.write(to: url, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); urls.append(url)
                }
                if chosenProvider == "Control Room" {
                    try controlRoom.setContext(currentTask: "\(taskTitle)\nFinish condition: \(finishCondition)", homeBrief: morning.contextBrief)
                    reply = try await backend.send(MeshAgentRequest(originalMessage: question.original)).text
                } else {
                    reply = try await backend.send(MeshAgentRequest(originalMessage: question.original, contextText: question.context, observationText: question.observation, localImageURLs: urls, capturedAt: question.capturedAt)).text
                }
            } else {
                status = "Local 3B is thinking…"; localStatus = "Loading / answering"
                let result = try await local.respond(originalMessage: question.original, images: question.images, evidence: question.localContext)
                reply = result.text; localStatus = "Resident · \(result.inferenceMS) ms last inference"
            }
            try Task.checkCancellation(); guard epoch == token else { throw CancellationError() }
            lastResponseMS = Int(Date().timeIntervalSince(activeStarted ?? Date()) * 1000)
            recordMessage(MeshMessage(role: chosenProvider, text: reply, evidence: lastEvidence))
            status = "Reply ready · \(lastResponseMS ?? 0) ms"
            return reply
        } catch {
            if epoch == token { status = error.localizedDescription }
            throw error
        }
    }

    func startVoice() {
        coach.silence()
        guard !isTerminating, !voiceRequested, !busy else { return }
        transcription.stop()
        interruptMorning()
        nightMode = false
        if focus.isPaused { resume() }
        guard !focus.isPaused else { return }
        metrics.startMonitoring(); activity.start()
        page = .conversation
        let chosenProvider = provider
        status = "Connecting conversation · microphone off"
        voiceStart.begin(connect: { [weak self] in
            guard let self else { throw CancellationError() }
            if chosenProvider == "Control Room" { _ = try await self.controlRoom.connect() }
            else if chosenProvider == "Codex" { _ = try await self.ensureCodex() }
        }, mayActivate: { [weak self] in
            guard let self else { return false }
            return !self.isTerminating && !self.focus.isPaused && !self.nightMode && !self.busy
                && !self.transcription.isActive && self.provider == chosenProvider
        }, activate: { [weak self] in
            guard let self else { return }
            self.voice.startConversation(useM1SpeakersOverride: chosenProvider == "Codex" ? false : nil)
        }, failed: { [weak self] error in
            guard let self else { return }
            if chosenProvider == "Control Room" { self.controlRoomStatus = error.localizedDescription }
            else if chosenProvider == "Codex" { self.connectionStatus = error.localizedDescription }
            self.status = "Voice could not connect: \(error.localizedDescription)"
        })
    }

    func stopVoice() {
        voiceStart.cancel()
        interruptMorning()
        voice.stop(); work?.cancel(); epoch = UUID(); busy = false; streaming = ""
        conversationSetup?.cancel(); conversationSetup = nil; conversationSetupID = nil
        codex.beginCancelCurrentTurn(); controlRoom.revokeSession()
        if !monitor.isRunning { local.stop(); localStatus = "Stopped" }
        status = "Stopped · microphone off"
    }

    func startTranscription() {
        guard !isTerminating else { return }
        // Captions are an explicit local mode, never a second hidden microphone.
        stopVoice()
        if focus.isPaused { resume() }
        guard !focus.isPaused else { return }
        nightMode = false; page = .captions
        transcription.start(source: transcription.source)
    }

    func stopTranscription() { transcription.stop() }
    func showMainWindow() { openApp?() }
    func showNotch() { _ = notch?.show() }
    func showCaptionWindow() {
        if let openCaptionPanel { openCaptionPanel() }
        else { page = .captions; openApp?() }
    }
    func showCompanionWindow() {
        if let openCompanionPanel { openCompanionPanel() }
        else { openApp?() }
    }

    func configureNotch(openApp: @escaping () -> Void, showNow: Bool) {
        self.openApp = openApp
        if notch == nil {
            notch = MeshNotchController(actions: MeshNotchActions(
                onTalk: { [weak self] in
                    guard let self else { return }
                    self.voiceRequested ? self.stopVoice() : self.startVoice()
                },
                onOpenApp: { [weak self] in self?.openApp?() },
                onCaptions: { [weak self] in
                    guard let self else { return }
                    self.page = .captions; self.openApp?()
                },
                onPause: { [weak self] in self?.toggleMonitoring() }
            ))
        }
        refreshNotch()
        if showNow { _ = notch?.show() }
    }

    private func refreshNotch() {
        let phase: MeshNotchPhase
        if transcription.isActive { phase = .captions }
        else if voiceStart.isStarting { phase = .loading }
        else if voice.phase == .failed { phase = .unavailable }
        else if voice.phase == .listening { phase = .listening }
        else if voice.phase == .thinking || voice.phase == .transcribing || busy { phase = .thinking }
        else if voice.phase == .loading { phase = .loading }
        else if voice.phase == .speaking { phase = .speaking }
        else if focus.isPaused { phase = .paused }
        else if monitor.isRunning && monitor.lastError != nil && !monitor.isAnalyzing { phase = .unavailable }
        else if monitor.isRunning { phase = .monitoring }
        else { phase = .off }
        let caption = transcription.partialText.isEmpty ? (transcription.lines.last?.text ?? "") : transcription.partialText
        notch?.update(MeshNotchSnapshot(phase: phase,
            detail: transcription.isActive ? transcription.status : voiceRequested || voice.phase == .failed ? voiceStatus : (nightMode ? "Morning armed · waiting for the AIY button" : monitor.isRunning ? screenUnderstandingSummary : "Start a session in Mesh Monitor · Talk opens the microphone."),
            transcript: transcription.isActive ? caption : voice.lastTranscript,
            provider: provider, captionsEnabled: transcription.isActive, talkEnabled: true, voiceActive: voiceRequested))
    }

    func discoverCameras() { cameraDevices = MeshCameraPresence.availableDevices() }

    func startCamera() {
        guard !isTerminating, !m1Camera.hasOwnedTransport, !camera.isRunning else { return }
        let managed: MeshM1CameraConfiguration?
        if useM1 && !manualM1Snapshot {
            guard let localPort = Int(m1LocalPort), let remotePort = Int(m1RemotePort),
                  let value = try? MeshM1CameraConfiguration(cameraID: m1CameraID, localPort: localPort, remotePort: remotePort) else {
                status = "Complete M1 setup with the exact camera ID and both ports before starting."
                return
            }
            managed = value
        } else { managed = nil }
        nightMode = false
        if focus.isPaused { resume() }
        guard !focus.isPaused else { return }
        backgroundGazeContextChanged()
        if let managed {
            do {
                try Self.saveM1CameraSetup(managed)
                try m1Camera.start(configuration: managed)
                status = m1Camera.status
            } catch { status = "M1 camera could not start · check its setup and station status" }
        } else if useM1 {
            guard let url = URL(string: snapshotURL), url.host != nil else { status = "Enter the M1 snapshot URL from setup."; return }
            UserDefaults.standard.set(snapshotURL, forKey: "mesh.monitor.camera-url")
            camera.start(source: .snapshot(url: url))
        } else { camera.start(source: .native(deviceID: cameraID)) }
    }

    func requestCameraPermission() {
        guard !isTerminating else { return }
        Task { _ = await AVCaptureDevice.requestAccess(for: .video); discoverCameras() }
    }

    /// Setup is owner-private and contains no session capabilities. Loading never starts a source.
    private static func savedM1CameraSetup() -> MeshM1CameraConfiguration? {
        do {
            let descriptor = try MeshControlRoomFiles.directory(dataDirectory, create: false)
            defer { Darwin.close(descriptor) }
            guard let bytes = try MeshControlRoomFiles.read("m1-camera-setup.json", directoryFD: descriptor, maximumBytes: 4096),
                  let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(value.keys) == Set(["schema", "hostAlias", "cameraID", "localPort", "remotePort"]),
                  value["schema"] as? String == "mesh.m1-camera-setup.v1", value["hostAlias"] as? String == "mesh-m1",
                  let cameraID = value["cameraID"] as? String,
                  let localPort = value["localPort"] as? Int, let remotePort = value["remotePort"] as? Int else { return nil }
            return try MeshM1CameraConfiguration(cameraID: cameraID, localPort: localPort, remotePort: remotePort)
        } catch { return nil }
    }

    private static func saveM1CameraSetup(_ setup: MeshM1CameraConfiguration) throws {
        let value: [String: Any] = ["schema": "mesh.m1-camera-setup.v1", "hostAlias": "mesh-m1",
            "cameraID": setup.cameraID, "localPort": setup.localPort, "remotePort": setup.remotePort]
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let descriptor = try MeshControlRoomFiles.directory(dataDirectory, create: true)
        defer { Darwin.close(descriptor) }
        _ = try MeshControlRoomFiles.read("m1-camera-setup.json", directoryFD: descriptor, maximumBytes: 4096)
        let temporary = ".m1-camera-setup-\(UUID().uuidString.lowercased()).tmp"
        defer { _ = unlinkat(descriptor, temporary, 0) }
        try MeshControlRoomFiles.publish(bytes, name: temporary, directoryFD: descriptor)
        guard renameat(descriptor, temporary, descriptor, "m1-camera-setup.json") == 0, fsync(descriptor) == 0 else {
            throw MeshM1CameraError.invalidConfiguration
        }
    }

    func stopCamera() {
        closeCalibration(); camera.stop(); m1Camera.stop(); morning.disarm()
        backgroundGazeContextChanged()
    }

    func prepareMorning() {
        guard !isTerminating else { return }
        home.refresh(morning.intendedDate)
        morning.prepare(home.compactBrief(for: morning.intendedDate))
    }

    func armMorning() {
        guard !isTerminating else { return }
        if morningTrigger == "AIY button" {
            // Arming for sleep first stops every audio/input/model path. This never
            // changes the M1 station mode or manufactures a physical button event.
            enterNight()
            guard focus.setPaused(false) else { status = focus.status; return }
        } else if focus.isPaused { resume() }
        if morningTrigger == "Camera arrival" {
            guard camera.isRunning, camera.freshness == .fresh else { status = "Start and verify the intended camera input before arming Morning."; return }
        } else { stopCamera() }
        _ = morning.refreshQueuedBrief()
        if morning.armAwaitingBrief() {
            if morningTrigger == "Camera arrival" { camera.arm(sessionID: UUID()) }
            if morningTrigger == "AIY button" {
                status = "Preparing the physical AIY wake button…"
                let armID = UUID(); morningArmID = armID
                morningArmTask = Task {
                    guard morningArmID == armID, !Task.isCancelled else { return }
                    do {
                        let addresses = UserDefaults.standard.stringArray(forKey: "mesh.monitor.pi-addresses") ?? []
                        let name = UserDefaults.standard.string(forKey: "mesh.monitor.pi-name") ?? ""
                        try await m1Return.arm(sessionID: UUID(), intendedDate: morning.intendedDate,
                                               piName: name, piAddresses: addresses)
                        guard morningArmID == armID else { return }
                        status = m1Return.status
                    } catch {
                        guard morningArmID == armID else { return }
                        morning.disarm(); m1Return.stop(); status = error.localizedDescription
                    }
                }
            } else { status = "Morning armed · \(morningTrigger) · waiting for a fresh return" }
        }
    }

    func disarmMorning() {
        morningArmID = UUID(); morningArmTask?.cancel(); morningArmTask = nil
        morning.disarm(); camera.disarm(); m1Return.stop(); voiceAfterMorning = false
    }

    func enterNight() {
        pauseForBreak(minutes: 8 * 60)
        voiceStart.cancel()
        monitor.stop(); setBackgroundGazeEnabled(false); conversationSetup?.cancel(); conversationSetup = nil; conversationSetupID = nil
        coach.stop(reason: "Night selected"); interruptMorning(); voice.stop(); transcription.stop(); closeCalibration(); camera.stop(); m1Camera.stop(); neoCursorRuntime.stop(); screen.clear(); local.stop()
        activity.stop(); metrics.stop()
        work?.cancel(); epoch = UUID(); busy = false; streaming = ""; codex.disconnect(); controlRoom.revokeSession(); connected = false
        nightMode = true
        status = m1Camera.captureMayBeActive || m1Camera.hasOwnedTransport
            ? "Night · local inputs off · M1 camera shutdown pending"
            : "Night · inputs off · screen monitoring resumes in 8 hours"
    }

    func returnHome() {
        guard !isTerminating else { return }
        guard morningTrigger != "AIY button" else {
            status = "Waiting for your physical AIY button · this app button does not simulate it"
            return
        }
        nightMode = false; page = .focus
        guard morningTrigger == "Return / Home", morning.armed else { status = "Home · morning is not armed"; return }
        _ = morning.refreshQueuedBrief()
        _ = morning.userReturn(UUID())
        status = morning.status
    }

    func markDone() {
        guard !taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Choose a focus task first."; return }
        _ = focus.confirm(.done, eventID: "focus:\(taskTitle)")
        status = focus.status
    }

    private func interruptMorning() {
        voiceAfterMorning = false
        if spokenMorning { morning.markDeliveryFailed("Interrupted by user"); spokenMorning = false }
    }

    var displays: [(id: String, name: String)] {
        NSScreen.screens.map { (String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0), $0.localizedName) }
    }

    func calibrateNativeGaze() {
        guard !isTerminating else { return }
        guard camera.isRunning else { status = "Start a camera preview before calibration."; return }
        guard let screen = NSScreen.screens.first(where: { String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == gazeDisplayID }) else { status = "Choose the display you will look at."; return }
        closeCalibration()
        backgroundGazeContextChanged()
        camera.beginNativeGazeCalibration(displayID: gazeDisplayID)
        let panel = MeshCalibrationPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: MeshGazeCalibration(camera: camera, close: { [weak self] in
            guard let self else { return }; self.closeCalibration(discard: self.camera.nativeGazeTarget != nil)
        }))
        calibrationPanel = panel; panel.setFrame(screen.frame, display: true); panel.makeKeyAndOrderFront(nil)
    }

    func closeCalibration(discard: Bool = true) {
        calibrationPanel?.close(); calibrationPanel = nil
        if discard { camera.cancelNativeGazeCalibration(); backgroundGazeContextChanged() }
    }

    func openNeoCursor() {
        guard !isTerminating else { return }
        if focus.isPaused { resume() }
        guard !focus.isPaused else { return }
        nightMode = false; page = .inputs
        neoCursorRuntime.start()
    }

    func stopNeoCursor() {
        stopGazeImport()
        neoCursorRuntime.stop()
    }

    func connectManagedGaze() {
        guard !isTerminating else { return }
        let expected = Self.dataDirectory.appendingPathComponent("neocursor/observation.json")
        guard neoCursorRuntime.isRunning, neoCursorRuntime.validated,
              neoCursorRuntime.observationPath == expected.path else {
            status = "Open the eye tracker and finish calibration before using gaze."; return
        }
        connectNeoCursorFile(expected, managed: true)
    }

    func importNeoCursor() {
        guard !isTerminating else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = Self.dataDirectory.appendingPathComponent("neocursor", isDirectory: true)
        panel.message = "Choose the observation file from your running, calibrated NeoCursor observation mode."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connectNeoCursorFile(url, managed: false)
    }

    private func connectNeoCursorFile(_ url: URL, managed: Bool) {
        do {
            let observation = try MeshNeoCursorFile.read(url)
            guard observation.isUsable(cameraID: observation.cameraID, displayID: observation.displayID,
                                       calibrationID: observation.calibrationID, now: Date()) else {
                status = "NeoCursor must be running with a fresh, validated calibration before connecting."; return
            }
            if managed {
                guard observation.cameraID == neoCursorRuntime.cameraID,
                      observation.displayID == neoCursorRuntime.displayID,
                      observation.calibrationID == neoCursorRuntime.calibrationID else {
                    status = "Waiting for the current tracker's calibrated observation."; return
                }
            }
            guard displays.contains(where: { $0.id == observation.displayID }),
                  gazeDisplayID.isEmpty || gazeDisplayID == observation.displayID else {
                status = "The observation belongs to a different display. Choose its calibrated display first."; return
            }
            gazeDisplayID = observation.displayID; gazeCameraID = observation.cameraID
            gazeCalibrationID = observation.calibrationID
            camera.startNeoCursorImport(fileURL: url, cameraID: gazeCameraID, displayID: gazeDisplayID, calibrationID: gazeCalibrationID)
            backgroundGazeContextChanged()
            status = "NeoCursor connected · room camera can remain off · Screen/Both shares gaze with a question"
        } catch { status = error.localizedDescription }
    }
}

struct MeshMonitorApp: App {
    @NSApplicationDelegateAdaptor(MeshApplicationDelegate.self) private var appDelegate
    @StateObject private var model = MeshMonitor()
    var body: some Scene {
        WindowGroup("Mesh Monitor", id: "main") {
            MeshApplicationSurface(model: model)
                .frame(minWidth: 960, minHeight: 700)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(after: .appInfo) { Button(model.sessionToggleTitle) { model.toggleMonitoring() }.keyboardShortcut(".", modifiers: [.command, .shift]) }
        }
        Window("Mesh Companion", id: "companion") {
            MeshMini(model: model).frame(width: 360, height: 230)
        }.windowResizability(.contentSize)
        Window("Mesh Captions", id: "captions") {
            MeshCaptionOverlay(model: model).frame(minWidth: 480, minHeight: 220)
        }.defaultSize(width: 760, height: 300)
        MenuBarExtra("Mesh Monitor", systemImage: model.focus.isPaused ? "pause.circle" : "scope") {
            MeshMenu(model: model).disabled(model.isTerminating)
        }
    }
}

@MainActor final class MeshApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: MeshMonitor?
    func applicationDidFinishLaunching(_ notification: Notification) {
        MeshApplicationChrome.shared.observeFullScreen()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.requestTermination(sender) ?? .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.pause() }
}

private struct MeshApplicationSurface: View {
    @ObservedObject var model: MeshMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        MeshDashboard(model: model).onAppear {
            model.openCaptionPanel = { openWindow(id: "captions") }
            model.openCompanionPanel = { openWindow(id: "companion") }
            model.configureNotch(openApp: {
                openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
            }, showNow: true)
        }
    }
}

/// Explicit command-line wake preparation is a windowless accessory process.
/// It does not unlock or activate the Mac. Normal app launches keep the full UI.
@main enum MeshMonitorLaunch {
    @MainActor static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--recover-focus-session") {
            guard MeshFocusRecovery.load() != nil else { return }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.devansh.m4-local-voice-notch").contains(where: { $0.processIdentifier != ownPID }) { return }
        }
        let quiet = arguments.contains("--quiet-launch")
        if arguments.contains("--start-focus-session") && (quiet || arguments.contains("--consume-wake-setup") || arguments.contains("--render-design-preview")) {
            FileHandle.standardError.write(Data("Focus-session startup cannot be combined with maintenance or wake setup.\n".utf8)); exit(1)
        }
        if quiet && (arguments.contains("--consume-wake-setup") || arguments.contains("--render-design-preview")) {
            FileHandle.standardError.write(Data("Quiet launch cannot be combined with wake setup or design rendering.\n".utf8)); exit(1)
        }
        if let index = arguments.firstIndex(of: "--render-design-preview"), index + 1 < arguments.count {
            do { try MeshDesignPreview.render(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
            catch { FileHandle.standardError.write(Data("Preview failed: \(error.localizedDescription)\n".utf8)); exit(1) }
        } else if quiet || arguments.contains("--consume-wake-setup") || arguments.contains("--start-focus-session") || arguments.contains("--recover-focus-session") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = MeshWakeServiceDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } else { MeshMonitorApp.main() }
    }
}

@MainActor private final class MeshWakeServiceDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var model: MeshMonitor?
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var captionWindow: NSWindow?
    private var companionWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        MeshApplicationChrome.shared.observeFullScreen()
        model = MeshMonitor()
        model?.configureNotch(openApp: { [weak self] in self?.openPanel() }, showNow: false)
        model?.openCaptionPanel = { [weak self] in self?.openCaptionPanel() }
        model?.openCompanionPanel = { [weak self] in self?.openCompanionPanel() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let isWakeGuard = ProcessInfo.processInfo.arguments.contains("--consume-wake-setup")
        item.button?.image = NSImage(systemSymbolName: isWakeGuard ? "moon.circle" : "scope", accessibilityDescription: isWakeGuard ? "Mesh Monitor wake guard" : "Mesh Monitor")
        let menu = NSMenu()
        for (title, action) in [("Open Mesh Monitor", #selector(openPanel)), ("Pause everything", #selector(pause)), ("Quit Mesh Monitor", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item.menu = menu; statusItem = item
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openPanel(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.requestTermination(sender) ?? .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.pause() }
    @objc private func openPanel() {
        guard let model, !model.isTerminating else { return }
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "Mesh Monitor"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: MeshDashboard(model: model).frame(minWidth: 960, minHeight: 700))
            panel.center(); window = panel
        }
        model.configureNotch(openApp: { [weak self] in self?.openPanel() }, showNow: true)
        MeshApplicationChrome.shared.installMenuIfMissing()
        NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(pause) { item.title = model?.sessionToggleTitle ?? "Resume monitoring" }
        return model?.isTerminating != true
    }
    @objc private func pause() { model?.toggleMonitoring() }
    @objc private func quit() { NSApp.terminate(nil) }
    private func openCaptionPanel() {
        guard let model else { return }
        if captionWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 300), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Mesh Captions"; panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: MeshCaptionOverlay(model: model))
            panel.center(); captionWindow = panel
        }
        captionWindow?.orderFrontRegardless()
    }
    private func openCompanionPanel() {
        guard let model else { return }
        if companionWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 230), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Mesh Companion"; panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: MeshMini(model: model))
            panel.center(); companionWindow = panel
        }
        companionWindow?.orderFrontRegardless()
    }
}

private let meshAccent = Color(red: 0.40, green: 0.87, blue: 1.0)

struct MeshMini: View {
    @ObservedObject var model: MeshMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack { Label("Mesh Monitor", systemImage: "scope").foregroundStyle(meshAccent); Spacer(); Button { model.showMainWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") } }
            Text(model.taskTitle.isEmpty ? "Choose your next outcome" : model.taskTitle).font(.title3.weight(.medium)).lineLimit(2)
            Text(model.voiceRequested ? model.voiceStatus : model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack { Button(model.voiceRequested ? "Stop voice" : "Talk to \(model.provider)") { model.voiceRequested ? model.stopVoice() : model.startVoice() }.buttonStyle(.borderedProminent); Button("Done", action: model.markDone); Spacer(); Button(model.sessionToggleTitle, action: model.toggleMonitoring) }
        }.padding(22).background(LinearGradient(colors: [Color(red: 0.04, green: 0.07, blue: 0.13), Color(red: 0.025, green: 0.035, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)).tint(meshAccent).preferredColorScheme(.dark)
    }
}

struct MeshMenu: View {
    @ObservedObject var model: MeshMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Mesh Monitor") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Open companion") { openWindow(id: "companion") }
        Divider()
        Text(model.voice.status)
        Button(model.sessionToggleTitle, action: model.toggleMonitoring)
        Button("Quit Mesh Monitor") { NSApp.terminate(nil) }
    }
}

/// The calibration overlay must receive Space/Escape without a mouse click away
/// from its target. A default borderless NSPanel is not key-eligible.
private final class MeshCalibrationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct MeshGazeCalibration: View {
    @ObservedObject var camera: MeshCameraPresence
    let close: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.93)
                if let point = camera.nativeGazeTarget {
                    Circle().stroke(meshAccent, lineWidth: 4).frame(width: 38, height: 38)
                        .overlay(Circle().fill(.white).frame(width: 7, height: 7))
                        .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                }
                VStack(spacing: 12) {
                    Spacer()
                    Text("Keep looking at the dot. Hold still, then press Space.").font(.title3)
                    Text(camera.nativeGazeStatus).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Record target · Space") { _ = camera.recordNativeGazeTarget() }.disabled(camera.nativeGazeTarget == nil).keyboardShortcut(.space, modifiers: [])
                        Button(camera.nativeGazeTarget == nil ? "Done" : "Cancel", action: close).keyboardShortcut(.escape, modifiers: [])
                    }
                }.padding(40)
            }.foregroundStyle(.white).preferredColorScheme(.dark)
        }
    }
}

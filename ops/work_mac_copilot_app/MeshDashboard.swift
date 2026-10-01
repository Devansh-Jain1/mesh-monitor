import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The full application surface. Opening it never starts an input or a model.
struct MeshDashboard: View {
    @ObservedObject var model: MeshMonitor
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    @AppStorage("mesh.ui.largeText") private var largeText = false
    @AppStorage("mesh.ui.highContrast") private var highContrast = false
    @AppStorage("mesh.ui.reduceMotion") private var reduceMotion = false
    @State private var editingTask = false
    @State private var taskDraft = ""
    @State private var finishDraft = ""
    @State private var confirmingHistoryClear = false
    @State private var captionExportStatus = ""
    @State private var showingNeoCursorSetup = false
    @State private var observationCorrection: String?

    private var contrast: Bool { highContrast || systemContrast == .increased }
    private var scale: CGFloat { largeText ? 1.17 : 1 }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(MeshInk.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            switch model.page {
                            case .focus: focusPage(compact: geometry.size.width < 920)
                            case .conversation: conversationPage
                            case .inputs: inputsPage(compact: geometry.size.width < 850)
                            case .morning: morningPage
                            case .captions: captionsPage
                            case .connections: connectionsPage
                            case .system: systemPage
                            }
                        }
                        .padding(largeText ? 30 : 28)
                        .frame(maxWidth: 1400, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                }
                footer
            }
        }
        .disabled(model.isTerminating)
        .font(.system(size: 14 * scale))
        .foregroundStyle(MeshInk.text)
        .background(background)
        .environment(\.meshDashboardContrast, contrast)
        .environment(\.meshDashboardScale, scale)
        .tint(MeshInk.cyan)
        .preferredColorScheme(.dark)
        .transaction { if reduceMotion || systemReduceMotion { $0.animation = nil } }
        .sheet(isPresented: $editingTask) { taskEditor }
        .sheet(isPresented: $showingNeoCursorSetup) { neoCursorSetup }
        .confirmationDialog("Clear local conversation history?", isPresented: $confirmingHistoryClear) {
            Button("Clear local history", role: .destructive, action: model.clearConversationHistory)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes saved text from this app. Connected agents, including Codex, keep their own conversation history.")
        }
        .onChange(of: model.focusObservationCount) { _, _ in observationCorrection = nil }
    }

    private var background: some View {
        ZStack {
            MeshInk.base
            if !contrast {
                RadialGradient(colors: [MeshInk.violet.opacity(0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 780)
                RadialGradient(colors: [MeshInk.cyan.opacity(0.045), .clear], center: .bottomLeading, startRadius: 0, endRadius: 650)
            }
        }.ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 12) {
                MeshApertureMark().frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("mesh").font(.system(size: 28, weight: .medium, design: .rounded))
                    Text("MONITOR").font(.system(size: 9, weight: .semibold)).tracking(3.4).foregroundStyle(MeshInk.muted)
                }
            }.padding(.horizontal, 9).padding(.top, 16).padding(.bottom, 10)
            VStack(spacing: 7) {
                ForEach(MeshPage.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.icon).font(.system(size: 17, weight: .medium)).frame(width: 23)
                            Text(page.rawValue).font(.system(size: 13 * scale, weight: model.page == page ? .semibold : .regular)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                            if page == .captions && model.transcription.isActive {
                                Circle().fill(MeshInk.cyan).frame(width: 6, height: 6).accessibilityLabel("Captions active")
                            }
                        }.padding(.horizontal, 14).padding(.vertical, 13)
                            .foregroundStyle(model.page == page ? MeshInk.text : MeshInk.muted)
                            .background {
                                if model.page == page {
                                    RoundedRectangle(cornerRadius: 13).fill(contrast ? Color.white.opacity(0.16) : MeshInk.cyan.opacity(0.085))
                                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(MeshInk.cyan.opacity(contrast ? 0.65 : 0.17)))
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 15) {
                Rectangle().fill(LinearGradient(colors: [MeshInk.cyan.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)).frame(width: 52, height: 1)
                Text("A calmer space\nfor your next move.").font(.system(size: 12 * scale)).lineSpacing(5).foregroundStyle(MeshInk.muted)
                Button { model.showCompanionWindow() } label: {
                    Label("Open companion", systemImage: "rectangle.topthird.inset.filled").font(.system(size: 12 * scale))
                }.buttonStyle(.plain).foregroundStyle(MeshInk.cyan).help("Open the separate compact companion")
            }.padding(.horizontal, 10).padding(.bottom, 18)
        }.padding(.horizontal, 15).frame(width: largeText ? 246 : 220)
            .background(contrast ? Color.black : Color.black.opacity(0.21))
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.page == .focus ? "YOUR WORK, IN VIEW" : model.page.rawValue.uppercased())
                    .font(.system(size: 10 * scale, weight: .semibold)).tracking(2.2).foregroundStyle(MeshInk.muted)
                Text(pageSubtitle).font(.system(size: 13 * scale)).foregroundStyle(MeshInk.text)
            }
            Spacer(minLength: 12)
            Button { model.page = .connections } label: {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(model.provider).font(.system(size: 11 * scale, weight: .semibold)).foregroundStyle(MeshInk.cyan)
                    Text(agentStatus).font(.system(size: 10 * scale)).foregroundStyle(MeshInk.muted).lineLimit(1).truncationMode(.tail)
                }.frame(maxWidth: 180, alignment: .trailing)
            }.buttonStyle(.plain).help(agentStatus).accessibilityLabel("\(model.provider): \(agentStatus). Connection settings")
            MeshStatusPill(text: sessionBadge, active: sessionBadgeActive)
            Menu {
                Toggle("Larger text", isOn: $largeText)
                Toggle("Higher contrast", isOn: $highContrast)
                Toggle("Reduce motion", isOn: $reduceMotion)
            } label: { Image(systemName: "accessibility").font(.system(size: 18)).frame(width: 32, height: 32) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Display and accessibility options")
        }.padding(.horizontal, 28).padding(.vertical, 20)
            .overlay(alignment: .bottom) { Rectangle().fill(MeshInk.line).frame(height: 1) }
    }

    private var agentStatus: String {
        if model.provider == "Control Room" { return model.controlRoomStatus }
        if model.provider == "Local 3B" { return model.localStatus }
        return model.connectionStatus
    }

    private var sessionBadge: String {
        if model.isTerminating { return "Closing" }
        if model.nightMode { return "Night mode" }
        if model.monitor.isRunning {
            guard model.screen.permissionGranted else { return "Screen access needed" }
            if model.monitor.lastError != nil { return model.monitor.isAnalyzing ? "Retrying screen check" : "Screen check failed" }
            if model.monitor.isAnalyzing { return "Checking screen" }
            return model.monitor.lastObservedAt == nil ? "Waiting for screen check" : "Monitoring"
        }
        if model.voiceRequested { return model.voiceStart.isStarting ? "Connecting voice" : model.voice.phase.rawValue.capitalized }
        if model.busy { return "Answering" }
        return model.focus.isPaused ? "Paused" : "Ready"
    }

    private var sessionBadgeActive: Bool {
        guard !model.isTerminating, !model.nightMode else { return false }
        if model.monitor.isRunning {
            return model.screen.permissionGranted && (model.monitor.lastError == nil || model.monitor.isAnalyzing)
        }
        return model.voice.isListening || model.busy
    }

    private var pageSubtitle: String {
        switch model.page {
        case .focus: return "Your session starts on this Mac."
        case .conversation: return "Talk through the work in front of you."
        case .inputs: return "Choose what your companion can see."
        case .morning: return "A prepared day, on your signal."
        case .captions: return "A quieter way to follow every word."
        case .connections: return "Your models, voice and schedule."
        case .system: return "A clear view under the hood."
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { model.page = .captions } label: {
                Label(model.transcription.isActive ? "Captions on" : "Captions", systemImage: "captions.bubble")
            }.buttonStyle(.plain).foregroundStyle(model.transcription.isActive ? MeshInk.cyan : MeshInk.muted)
            Rectangle().fill(MeshInk.line).frame(width: 1, height: 16)
            Text(model.voiceRequested ? model.voiceStatus : model.status).lineLimit(1).truncationMode(.middle).foregroundStyle(MeshInk.muted).help(model.voiceRequested ? model.voiceStatus : model.status)
            Spacer(minLength: 4)
            Button { model.nightMode ? model.startFocusSession() : model.enterNight() } label: {
                Label(model.nightMode ? "Resume now" : "Night · 8 hours", systemImage: model.nightMode ? "sun.max" : "moon")
            }.buttonStyle(.plain)
            Button(action: model.toggleMonitoring) { Label(model.sessionToggleTitle, systemImage: model.focus.isPaused ? "play.circle" : "pause.circle") }
                .buttonStyle(.plain).keyboardShortcut(".", modifiers: [.command, .shift])
        }.font(.system(size: 12 * scale)).padding(.horizontal, 28).padding(.vertical, 17)
            .background(Color.black.opacity(contrast ? 1 : 0.18))
            .overlay(alignment: .top) { Rectangle().fill(MeshInk.line).frame(height: 1) }
    }

    @ViewBuilder private func focusPage(compact: Bool) -> some View {
        focusHero
        MeshCoachControls(coach: model.coach, importTask: {
            if let (task, finish) = model.coach.importTaskContext() {
                model.taskTitle = task; model.finishCondition = finish
                model.monitor.updateTask(task: task, finishCondition: finish)
                UserDefaults.standard.set(task, forKey: "mesh.monitor.task")
                UserDefaults.standard.set(finish, forKey: "mesh.monitor.finish")
            }
        })
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), alignment: .top), count: compact ? 2 : 4), spacing: 16) {
            sessionStateCard("Monitoring", icon: "scope", summary: model.monitoringSummary)
            sessionStateCard("Conversation", icon: "bubble.left.and.bubble.right", summary: model.conversationSummary)
            sessionStateCard("Screen understanding", icon: "macwindow", summary: model.screenUnderstandingSummary)
            sessionStateCard("Eyes + webcam", icon: "eye", summary: model.gazeSummary, accent: MeshInk.violet)
        }
        if compact {
            observationCard
            calendarCard
        } else {
            HStack(alignment: .top, spacing: 22) {
                observationCard.frame(maxWidth: .infinity)
                calendarCard.frame(width: largeText ? 310 : 280)
            }
        }
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "web.camera").font(.system(size: 21, weight: .light)).foregroundStyle(MeshInk.violet)
            VStack(alignment: .leading, spacing: 5) {
                Text("Room context and eyes, when you want them.").font(.system(size: 13 * scale, weight: .medium))
                Text("Screen monitoring works on its own. Add a webcam or calibrate gaze from Inputs.")
                    .font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { model.page = .inputs } label: { Label("Optional inputs", systemImage: "arrow.up.right") }
                .buttonStyle(MeshQuietButtonStyle(compact: true))
        }
    }

    private var focusHero: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                MeshEyebrow("M4 WORK SESSION")
                Spacer()
                Button(model.taskTitle.isEmpty ? "Set task + finish line" : "Edit task + finish line", action: beginTaskEditing)
                    .buttonStyle(MeshQuietButtonStyle(compact: true))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.taskTitle.isEmpty ? "What will you finish?" : model.taskTitle)
                    .font(.system(size: 33 * scale, weight: .medium, design: .rounded)).tracking(-0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.finishCondition.isEmpty ? "Set a clear finish line so your companion knows what you are working toward." : "Done means: \(model.finishCondition)")
                    .font(.system(size: 15 * scale)).foregroundStyle(MeshInk.muted).lineSpacing(4)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { focusActions }
                VStack(alignment: .leading, spacing: 12) { focusActions }
            }.padding(.top, 3)
            Text("Start session begins screen monitoring. Use Talk when you want a voice conversation.")
                .font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            if !model.screen.permissionGranted {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Allow screen access so Mesh can understand the app you are working in.")
                        .font(.system(size: 13 * scale)).foregroundStyle(MeshInk.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Allow screen access", action: model.screen.requestPermission)
                        .buttonStyle(MeshQuietButtonStyle(compact: true))
                        .accessibilityHint("Requests macOS Screen Recording permission")
                }
            }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(contrast ? Color.black : MeshInk.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(contrast ? Color.white.opacity(0.55) : MeshInk.cyan.opacity(0.24)))
    }

    @ViewBuilder private var focusActions: some View {
        Button {
            if model.monitor.isRunning { model.pauseForBreak() }
            else if model.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { beginTaskEditing() }
            else { model.startFocusSession() }
        } label: {
            Label(model.monitor.isRunning ? "Break · 10 min" : "Resume monitoring", systemImage: model.monitor.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 15 * scale, weight: .semibold)).frame(minWidth: 130, minHeight: 28)
        }.buttonStyle(MeshPrimaryButtonStyle())
        Button { model.voiceRequested ? model.stopVoice() : model.startVoice() } label: {
            Label(model.voiceRequested ? "Stop voice" : "Talk to \(model.provider)", systemImage: model.voiceRequested ? "stop.fill" : "mic.fill").frame(minHeight: 28)
        }.buttonStyle(MeshQuietButtonStyle())
        Button { model.page = .conversation } label: { Label("Open conversation", systemImage: "bubble.left.and.bubble.right").frame(minHeight: 28) }
            .buttonStyle(MeshQuietButtonStyle())
        if !model.taskTitle.isEmpty {
            Button(action: model.markDone) { Label("Mark done", systemImage: "checkmark").frame(minHeight: 28) }
                .buttonStyle(MeshQuietButtonStyle()).disabled(model.focus.isPaused)
        }
    }

    private func sessionStateCard(_ title: String, icon: String, summary: String, accent: Color = MeshInk.cyan) -> some View {
        MeshGlassCard(title, icon: icon, accent: accent) {
            Text(summary).font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 60, alignment: .topLeading)
                .textSelection(.enabled)
        }
    }

    private var observationCard: some View {
        MeshGlassCard(model.monitor.lastError != nil && model.latestFocusObservation != nil ? "Last successful local observation" : "Local screen observation", icon: "viewfinder") {
            Text("LFM2.5-VL-3B · on this Mac").font(.system(size: 11 * scale, weight: .medium)).foregroundStyle(MeshInk.cyan)
            Text(model.monitor.status).font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            if let observation = model.latestFocusObservation {
                Text(observation).font(.system(size: 19 * scale, weight: .medium)).lineSpacing(5).textSelection(.enabled)
                if let date = model.monitor.lastObservedAt {
                    Text("Observed \(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 11 * scale, design: .monospaced)).foregroundStyle(MeshInk.muted)
                }
                Text("Does this activity belong to your task? You decide.")
                    .font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { observationFeedback }
                    VStack(alignment: .leading, spacing: 8) { observationFeedback }
                }
                if let correction = observationCorrection {
                    Label("Your correction: \(correction)", systemImage: "checkmark.bubble")
                        .font(.system(size: 12 * scale)).foregroundStyle(MeshInk.cyan)
                }
            } else if model.monitor.lastError != nil {
                Text("No screen observation yet.")
                    .font(.system(size: 20 * scale, weight: .medium, design: .rounded)).lineSpacing(4)
                Text(model.monitor.isRunning
                     ? (model.monitor.isAnalyzing ? "The last screen check failed. Trying again now." : "The last screen check failed. Another check is scheduled.")
                     : "The last screen check failed. Start a session to try again.")
                    .font(.system(size: 13 * scale)).foregroundStyle(MeshInk.muted)
            } else {
                Text(model.monitor.isRunning ? "Waiting for the first screen observation…" : "Your work comes into view when you start a session.")
                    .font(.system(size: 20 * scale, weight: .medium, design: .rounded)).lineSpacing(4)
                Text("An app name alone cannot tell whether you are on task. Monitor uses your task and screen context, and you can correct its interpretation.")
                    .font(.system(size: 13 * scale)).foregroundStyle(MeshInk.muted)
            }
            Rectangle().fill(MeshInk.line).frame(height: 1).padding(.vertical, 3)
            HStack(spacing: 12) {
                Button {
                    model.draft = "Help me get unstuck on my current task. Ask what I have tried before assuming the cause."
                    model.page = .conversation
                } label: { Label("Get help", systemImage: "sparkle") }.buttonStyle(.plain).foregroundStyle(MeshInk.cyan)
                Spacer(minLength: 0)
                Button("Export trial review", action: model.exportFocusReview).buttonStyle(MeshQuietButtonStyle(compact: true))
            }
        }
    }

    @ViewBuilder private var observationFeedback: some View {
        ForEach(["On task", "Useful detour", "Distracted"], id: \.self) { correction in
            Button(correction) {
                model.correctObservation(correction)
                observationCorrection = correction
            }.buttonStyle(MeshQuietButtonStyle(compact: true))
                .accessibilityHint("Correct the latest observation to \(correction.lowercased())")
        }
    }

    private var talkButton: some View {
        Button { model.voiceRequested ? model.stopVoice() : model.startVoice() } label: {
            Label(model.voiceRequested ? "Stop voice" : "Talk to \(model.provider)", systemImage: model.voiceRequested ? "stop.fill" : "mic.fill")
                .font(.system(size: 15 * scale, weight: .semibold)).frame(minWidth: 112, minHeight: 28)
        }.buttonStyle(MeshPrimaryButtonStyle()).accessibilityHint(model.voiceRequested ? "Stops the current voice conversation" : "Starts a voice conversation with the selected agent")
    }

    private var calendarCard: some View {
        MeshGlassCard("Today", icon: "calendar", accent: MeshInk.violet) {
            if let date = model.home.loadedDate {
                Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            } else {
                Text("Your Home calendar,\nclose at hand.").font(.system(size: 20 * scale, weight: .medium)).lineSpacing(4)
            }
            if model.home.events.isEmpty {
                Text(model.home.status).font(.system(size: 13 * scale)).foregroundStyle(MeshInk.muted).fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.home.events.prefix(6)) { event in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Circle().fill(MeshInk.violet).frame(width: 7, height: 7).padding(.top, 5)
                                Rectangle().fill(MeshInk.line).frame(width: 1).frame(minHeight: 23)
                            }.frame(width: 8)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.isAllDay ? "ALL DAY" : event.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10 * scale, weight: .medium, design: .monospaced)).foregroundStyle(MeshInk.muted)
                                Text(event.title).font(.system(size: 13 * scale, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            }.padding(.bottom, 20)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if model.home.events.count > 6 { Text("+ \(model.home.events.count - 6) more in Home").font(.caption).foregroundStyle(MeshInk.muted) }
            }
            HStack {
                Button(model.home.loadedDate == nil ? "Connect Home" : "Refresh") {
                    if model.home.loadedDate == nil { Task { await model.home.requestAccess() } } else { model.home.refresh() }
                }.buttonStyle(MeshQuietButtonStyle(compact: true)).disabled(model.home.isRequestingAccess)
                Spacer()
                Button { model.page = .connections } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).accessibilityLabel("Calendar connection settings")
            }
        }
    }

    private var evidenceControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label("Share with this question", systemImage: "viewfinder").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
                Picker("Evidence for each question", selection: $model.evidenceChoice) {
                    ForEach(MeshEvidenceChoice.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 340).disabled(model.busy || model.provider == "Control Room")
                Spacer(minLength: 0)
            }
            Text(evidenceExplanation).font(.system(size: 11 * scale)).foregroundStyle(MeshInk.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var evidenceExplanation: String {
        if model.provider == "Control Room" { return "Control Room receives your exact message, current task and prepared Home brief. Images and gaze observations are off for this connection." }
        if model.provider == "Local 3B" { return "Local 3B reads selected images on this Mac. Ask Codex deeper forwards the original question and the same evidence to Codex." }
        if model.evidenceChoice == .none { return "Images are off. Codex receives your message, current task and connected Home brief." }
        return "Codex receives your message, task, connected Home brief and selected images. Room images leave this Mac only with Room or Both selected."
    }

    private func beginTaskEditing() {
        taskDraft = model.taskTitle
        finishDraft = model.finishCondition
        editingTask = true
    }

    private var taskEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            MeshEyebrow("YOUR SESSION")
            Text("What would make this\na good session?").font(.system(size: 28, weight: .medium, design: .rounded))
            VStack(alignment: .leading, spacing: 8) {
                Text("Outcome").font(.headline)
                TextField("What are you trying to finish?", text: $taskDraft).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Finish condition").font(.headline)
                TextField("Done means…", text: $finishDraft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            }
            HStack {
                Button("Cancel") { editingTask = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save and start session") {
                    model.taskTitle = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.finishCondition = finishDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.startFocusSession()
                    editingTask = false
                }.buttonStyle(MeshPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(32).frame(width: 500).background(MeshInk.base).preferredColorScheme(.dark)
    }

    private var conversationPage: some View {
        Group {
            MeshGlassCard("Conversation", icon: "bubble.left.and.bubble.right") {
                Text(model.conversationSummary).font(.system(size: 14 * scale, weight: .medium)).foregroundStyle(MeshInk.cyan).textSelection(.enabled)
                Text(model.conversationModelSummary).font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted).textSelection(.enabled)
                Text("Speech stays local: Parakeet listens, Kokoro speaks. The answer comes from the provider below.")
                    .font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
                HStack(spacing: 16) {
                    Picker("Answer with", selection: $model.provider) {
                        Text("Codex").tag("Codex")
                        Text("Control Room · scheduled").tag("Control Room")
                        Text("Local 3B").tag("Local 3B")
                    }.frame(maxWidth: 350).disabled(model.busy || model.voiceRequested)
                    Spacer(minLength: 0)
                    talkButton
                }
                HStack(spacing: 10) {
                    MeshStatusPill(text: "Voice · \(model.voiceStart.isStarting ? "Connecting" : model.voice.phase.rawValue.capitalized)", active: model.voice.isListening)
                    Text(model.voiceStatus).font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
                }
                Text(model.screenUnderstandingSummary).font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted).textSelection(.enabled)
                evidenceControl
                if model.provider == "Control Room" { Text(model.controlRoomStatus).font(.callout).foregroundStyle(MeshInk.cyan) }
                if model.evidenceChoice.includesScreen {
                    Label("Screen target: \(model.screen.targetApplication). Use that app, then return here.", systemImage: "macwindow").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.cyan)
                }
                TextField("Ask about this, or talk through your next step…", text: $model.draft, axis: .vertical)
                    .font(.system(size: 16 * scale)).lineLimit(3...8).textFieldStyle(.plain).padding(17)
                    .background(MeshInk.base.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(MeshInk.line))
                    .accessibilityLabel("Message to your companion")
                HStack(spacing: 13) {
                    Button(action: model.send) { Label(model.busy ? "Working…" : "Send message", systemImage: "arrow.up") }
                        .buttonStyle(MeshPrimaryButtonStyle()).disabled(model.busy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Ask Codex deeper", action: model.askCodexDeeper).buttonStyle(MeshQuietButtonStyle()).disabled(!model.canAskCodexDeeper)
                    if model.busy { Button("Stop", action: model.stopVoice).buttonStyle(MeshQuietButtonStyle()) }
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Label(model.historyError ?? model.historyStatus,
                      systemImage: model.historyError == nil ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(model.historyError == nil ? MeshInk.muted : MeshInk.cyan)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Clear local history") { confirmingHistoryClear = true }
                    .buttonStyle(MeshQuietButtonStyle(compact: true))
                    .disabled(model.busy || model.voiceRequested || (model.messages.isEmpty && model.historyError == nil))
            }
            if model.messages.isEmpty && model.streaming.isEmpty {
                MeshEmptyState(symbol: "bubble.left.and.bubble.right", title: "Start with what’s in front of you.", detail: "Your exact question stays with the evidence you choose. Ask a follow-up or invite Codex to go deeper.")
            }
            ForEach(model.messages) { message in
                MeshConversationBubble(role: message.role, text: message.text, evidence: message.evidence, date: message.createdAt, streaming: false)
            }
            if !model.streaming.isEmpty {
                MeshConversationBubble(role: model.provider, text: model.streaming, evidence: "Responding", date: nil, streaming: true)
            }
        }
    }

    @ViewBuilder private func inputsPage(compact: Bool) -> some View {
        pageIntro("Two views. One context.", detail: "Preview your inputs here. Choose Screen, Room or Both when you ask a question.")
        if compact { screenInput; roomInput } else { HStack(alignment: .top, spacing: 20) { screenInput; roomInput } }
        MeshGlassCard("Eyes + cursor", icon: "cursorarrow.rays", accent: MeshInk.violet) {
            Text("Help “this” point to the right thing.").font(.system(size: 22 * scale, weight: .medium, design: .rounded))
            Text("Start with Open eye tracker for NeoCursor calibration. Calibrated gaze can add context to your questions. Background checks have a separate switch below.")
                .font(.callout).foregroundStyle(MeshInk.muted)
            HStack(spacing: 12) {
                Text(model.neoCursorRuntime.status).foregroundStyle(MeshInk.cyan)
                Spacer()
                MeshStatusPill(text: model.neoCursorRuntime.isStopping ? "Stopping tracker" : model.neoCursorRuntime.captureActive ? (model.neoCursorRuntime.frameObserved ? "Camera frame received" : "Camera starting") : "Tracker camera off", active: model.neoCursorRuntime.frameObserved || model.neoCursorRuntime.isStopping)
            }
            HStack(spacing: 12) {
                Button("Open eye tracker", action: model.openNeoCursor).buttonStyle(MeshPrimaryButtonStyle())
                    .disabled(model.neoCursorRuntime.isStarting || model.neoCursorRuntime.isRunning || model.neoCursorRuntime.isStopping)
                Button("Stop tracker", action: model.stopNeoCursor).buttonStyle(MeshQuietButtonStyle())
                    .disabled(!model.neoCursorRuntime.isStarting && !model.neoCursorRuntime.isRunning)
            }
            Text(model.camera.neoCursorStatus).foregroundStyle(MeshInk.muted)
            Picker("Target display", selection: $model.gazeDisplayID) {
                Text("Choose display").tag("")
                ForEach(model.displays, id: \.id) { display in Text("\(display.name) · \(display.id)").tag(display.id) }
            }
            DisclosureGroup("Tracker identifiers") {
                HStack(spacing: 12) {
                    TextField("Tracker camera ID", text: $model.gazeCameraID)
                    TextField("Calibration ID", text: $model.gazeCalibrationID)
                }.textFieldStyle(.roundedBorder)
                Text("Filled from the calibrated observation you choose.").font(.caption).foregroundStyle(MeshInk.muted)
                Button("Import external observation…", action: model.importNeoCursor).buttonStyle(MeshQuietButtonStyle(compact: true))
            }
            HStack(spacing: 12) {
                Button("Use calibrated gaze", action: model.connectManagedGaze).buttonStyle(MeshQuietButtonStyle())
                    .disabled(!model.neoCursorRuntime.validated)
                Button("Stop import", action: model.stopGazeImport).buttonStyle(MeshQuietButtonStyle())
                Button("Setup", systemImage: "info.circle") { showingNeoCursorSetup = true }.buttonStyle(MeshQuietButtonStyle())
            }
            Text("Open the tracker, choose a camera and complete calibration. Then select Use calibrated gaze. Stop tracker, Pause all and Night close the tracker started by this app. Stop import only disconnects its observations.").font(.caption).foregroundStyle(MeshInk.muted)
            Toggle("Include calibrated gaze in background screen checks", isOn: Binding(get: { model.backgroundGazeEnabled }, set: model.setBackgroundGazeEnabled))
                .disabled(model.focus.isPaused)
            Text(model.backgroundGazeStatus).font(.callout).foregroundStyle(MeshInk.cyan)
            Text("Uses an approximate screen region only when calibration and timing match. Does not start a camera. Missing or stale gaze is skipped; it cannot establish attention, boredom or task completion. Pause, Night and relaunch turn this off.").font(.caption).foregroundStyle(MeshInk.muted)
            Rectangle().fill(MeshInk.line).frame(height: 1).padding(.vertical, 4)
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Experimental native eye calibration").font(.headline)
                    Text(model.camera.nativeGazeStatus).font(.callout).foregroundStyle(MeshInk.muted)
                }
                Spacer()
                Button("Calibrate eye target", action: model.calibrateNativeGaze).buttonStyle(MeshPrimaryButtonStyle()).disabled(!model.camera.isRunning)
            }
            Text("NeoCursor import and native eye calibration are separate. Each needs fresh, calibrated evidence. Cursor movement and clicks are disabled in this build.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
        }
    }

    private var neoCursorSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Eyes in context", systemImage: "cursorarrow.rays").font(.title2)
            Text("Open eye tracker uses the prepared local runtime. Its camera stays off until you choose one and press Start chosen camera.").foregroundStyle(MeshInk.muted)
            Text("1. Open the eye tracker from Inputs. If setup is missing, the status explains what is needed.\n\n2. Choose your camera and display, then start and complete the seven calibration targets.\n\n3. Return here and select Use calibrated gaze. Screen or Both adds fresh gaze to your questions.").lineSpacing(4)
            Text("Stop tracker, Pause all, Night and quitting Mesh Monitor close the tracker this app started. A separately launched tracker must be stopped in its own window.").font(.callout).foregroundStyle(MeshInk.cyan)
            HStack {
                Button("Show setup files") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("NeoCursorAdapter"), FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent("README.md")])
                    } else { model.status = "NeoCursor setup files are missing from this app bundle." }
                }.buttonStyle(MeshQuietButtonStyle())
                Spacer()
                Button("Done") { showingNeoCursorSetup = false }.buttonStyle(MeshPrimaryButtonStyle())
            }
        }.padding(32).frame(width: 580).foregroundStyle(MeshInk.text).background(MeshInk.base)
    }

    private var screenInput: some View {
        MeshGlassCard("Screen", icon: "macwindow") {
            MeshDashboardPreview(image: model.screen.preview, symbol: "macwindow", title: "Capture the app you last used", height: 210)
            Text(model.screen.status).foregroundStyle(MeshInk.muted)
            HStack(spacing: 10) {
                Button("Capture") { Task { do { _ = try await model.screen.capture() } catch { model.status = error.localizedDescription } } }
                    .buttonStyle(MeshPrimaryButtonStyle()).disabled(model.screen.busy)
                Button("Clear", action: model.screen.clear).buttonStyle(MeshQuietButtonStyle())
            }
            Button("Screen permission", action: model.screen.requestPermission).buttonStyle(.plain).foregroundStyle(MeshInk.cyan)
            Text("Images include a capture timestamp and pointer location. Selected text is included when Accessibility access is already allowed.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
        }
    }

    private var roomInput: some View {
        MeshGlassCard("Room", icon: "web.camera", accent: MeshInk.violet) {
            MeshDashboardPreview(image: model.camera.preview, symbol: "web.camera", title: "Camera is off until you start it", height: 210)
            Text("\(model.camera.detail) · \(model.camera.freshness.rawValue)").foregroundStyle(MeshInk.muted)
            Toggle("M1 room camera", isOn: $model.useM1).disabled(model.camera.isRunning || model.m1Camera.hasOwnedTransport)
            if model.useM1 {
                Toggle("Advanced: import an existing image URL", isOn: $model.manualM1Snapshot)
                    .disabled(model.camera.isRunning || model.m1Camera.hasOwnedTransport)
                if model.manualM1Snapshot {
                    TextField("http://M1-address:port/frame.jpg", text: $model.snapshotURL).textFieldStyle(.roundedBorder).disabled(model.camera.isRunning).accessibilityLabel("M1 camera snapshot URL")
                    Text("Stop ends this image import. The camera at that URL is controlled separately.")
                        .font(.caption).foregroundStyle(MeshInk.muted)
                } else {
                    Text(model.m1Camera.status).foregroundStyle(MeshInk.cyan)
                    DisclosureGroup("M1 setup") {
                        Text("Requires the managed camera helper and Station integration on your M1, Camera permission, and Desktop mode. Use the exact camera ID and ports recorded during setup.")
                            .font(.caption).foregroundStyle(MeshInk.muted)
                        TextField("Exact M1 camera ID", text: $model.m1CameraID).textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("M4 forwarding port", text: $model.m1LocalPort)
                            TextField("M1 camera port", text: $model.m1RemotePort)
                        }.textFieldStyle(.roundedBorder)
                    }.disabled(model.m1Camera.hasOwnedTransport)
                    Text("Start connects to your configured mesh-m1 Mac. Stop, Pause and Night request camera shutdown; an unconfirmed shutdown stays visible.")
                        .font(.caption).foregroundStyle(MeshInk.muted)
                }
            } else {
                HStack { Button("Find cameras", action: model.discoverCameras); Button("Allow camera", action: model.requestCameraPermission) }.buttonStyle(MeshQuietButtonStyle(compact: true))
                Picker("Camera", selection: $model.cameraID) {
                    Text("Choose a camera").tag("")
                    ForEach(model.cameraDevices) { Text($0.name).tag($0.id) }
                }.disabled(model.camera.isRunning)
            }
            HStack(spacing: 10) {
                Button("Start preview", action: model.startCamera).buttonStyle(MeshPrimaryButtonStyle()).disabled(model.camera.isRunning || model.m1Camera.hasOwnedTransport)
                Button("Stop", action: model.stopCamera).buttonStyle(MeshQuietButtonStyle())
            }
            Text("Previewing alone sends no images to Codex. Sharing the room remains a separate choice in Conversation.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
        }
    }

    private var morningPage: some View {
        Group {
            pageIntro("Your day, when you return.", detail: "Prepare Home ahead of time. Your chosen return signal starts the briefing.")
            MeshGlassCard("Morning delivery", icon: "sun.max", accent: MeshInk.violet) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.morning.armed ? "Ready for your return." : "Set up a gentle beginning.").font(.system(size: 26 * scale, weight: .medium, design: .rounded))
                        Text(model.morning.status).foregroundStyle(MeshInk.cyan)
                    }
                    Spacer()
                    MeshStatusPill(text: model.morning.armed ? "Armed" : "Not armed", active: model.morning.armed)
                }
                DatePicker("Intended morning", selection: Binding(get: { model.morning.intendedDate }, set: { model.morning.intendedDate = $0; model.camera.disarm() }), displayedComponents: .date)
                    .frame(maxWidth: 380).disabled(model.morning.armed || model.morning.deliveryState == .attempted)
                Picker("Return signal", selection: $model.morningTrigger) {
                    Text("Physical AIY button · M1 desktop").tag("AIY button")
                    Text("Return / Home · app button").tag("Return / Home")
                    Text("Camera arrival").tag("Camera arrival")
                }.disabled(model.morning.armed)
                if model.morningTrigger == "AIY button" { Text(model.m1Return.status).font(.callout).foregroundStyle(MeshInk.muted) }
                HStack(spacing: 12) {
                    Button("Prepare from Home", action: model.prepareMorning).buttonStyle(MeshQuietButtonStyle()).disabled(model.morning.armed || model.morning.deliveryState == .attempted)
                    Button("Import brief") { model.morning.importBrief() }.buttonStyle(MeshQuietButtonStyle()).disabled(model.morning.armed || model.morning.deliveryState == .attempted)
                    Spacer(minLength: 0)
                    Button(model.morning.armed ? "Disarm morning" : "Arm morning") { model.morning.armed ? model.disarmMorning() : model.armMorning() }.buttonStyle(MeshPrimaryButtonStyle())
                }
                if let generated = model.morning.contextBrief?.generatedAt {
                    Text("Home last read \(generated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(MeshInk.muted)
                }
                if let text = model.morning.preparedBrief {
                    Text(text).textSelection(.enabled).lineSpacing(5).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(MeshInk.base.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            MeshGlassCard("On your signal", icon: "waveform") {
                HStack(spacing: 14) {
                    Label("Home plan", systemImage: "calendar")
                    Image(systemName: "arrow.right").foregroundStyle(MeshInk.muted)
                    Label("Your return", systemImage: "sunrise")
                    Image(systemName: "arrow.right").foregroundStyle(MeshInk.muted)
                    Label("Spoken briefing", systemImage: "speaker.wave.2")
                }.font(.system(size: 14 * scale, weight: .medium))
                Text("For the physical AIY route, the prepared briefing plays on the M1 first; conversation opens afterward. Camera and microphone stay off overnight. Clock ticks, reconnects and app launches do not start speech.").foregroundStyle(MeshInk.muted)
                HStack(spacing: 12) {
                    Button("Night · resume in 8 hours", action: model.enterNight).buttonStyle(MeshQuietButtonStyle())
                    Button("Return / Home", action: model.returnHome).buttonStyle(MeshQuietButtonStyle())
                    Spacer(minLength: 0)
                }
                Button("Play today’s briefing now") { _ = model.morning.replay(allowBeforeNine: true) }.buttonStyle(.plain).foregroundStyle(MeshInk.cyan)
                Text("Explicit playback counts as today’s delivery. Pause all disarms morning delivery.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            }
        }
    }

    private var captionsPage: some View {
        Group {
            pageIntro("Keep every word in view.", detail: "Local transcription, with readable live captions and an exportable transcript.")
            MeshGlassCard("Live captions", icon: "captions.bubble") {
                HStack(spacing: 16) {
                    Picker("Listen to", selection: Binding(get: { model.transcription.source }, set: { model.transcription.source = $0 })) {
                        Text("Microphone").tag(MeshTranscription.Source.microphone)
                        Text("Mac audio").tag(MeshTranscription.Source.systemAudio)
                    }.pickerStyle(.segmented).frame(maxWidth: 330).disabled(model.transcription.isActive)
                    Spacer(minLength: 0)
                    Button(model.transcription.isActive ? "Stop captions" : "Start captions") {
                        model.transcription.isActive ? model.stopTranscription() : model.startTranscription()
                    }.buttonStyle(MeshPrimaryButtonStyle())
                }
                HStack(spacing: 12) {
                    MeshAudioLevel(level: Double(model.transcription.level), active: model.transcription.isActive).frame(width: 66, height: 20)
                    Text(model.transcription.status).font(.system(size: 13 * scale)).foregroundStyle(MeshInk.muted)
                }
                HStack(spacing: 22) {
                    Toggle("Large captions", isOn: Binding(get: { model.transcription.largeText }, set: { model.transcription.largeText = $0 }))
                    Toggle("High contrast", isOn: Binding(get: { model.transcription.highContrast }, set: { model.transcription.highContrast = $0 }))
                    Spacer(minLength: 0)
                    Button { model.showCaptionWindow() } label: { Label("Float", systemImage: "pip") }.buttonStyle(.plain).foregroundStyle(MeshInk.cyan)
                }.toggleStyle(.checkbox).font(.system(size: 12 * scale))
                VStack(alignment: .leading, spacing: 18) {
                    if model.transcription.lines.isEmpty && model.transcription.partialText.isEmpty {
                        Text(model.transcription.isActive ? "Listening for speech…" : "Your words will appear here.")
                            .foregroundStyle(MeshInk.muted).padding(.vertical, 32)
                    }
                    ForEach(model.transcription.lines.suffix(8)) { line in
                        Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.transcription.partialText.isEmpty {
                        Text(model.transcription.partialText).foregroundStyle(model.transcription.highContrast ? .white : MeshInk.cyan).textSelection(.enabled)
                    }
                }
                .font(.system(size: model.transcription.largeText ? 30 : 22, weight: .medium, design: .rounded))
                .lineSpacing(7).padding(26).frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                .foregroundStyle(.white)
                .background(model.transcription.highContrast ? Color.black : MeshInk.base, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(model.transcription.highContrast ? Color.white : MeshInk.line))
                Text("Choose one audio source. Captions and voice conversation take turns using local transcription.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            }
            MeshGlassCard("Transcript", icon: "text.alignleft", accent: MeshInk.violet) {
                HStack {
                    Text("\(model.transcription.lines.count) completed segments").foregroundStyle(MeshInk.muted)
                    Spacer()
                    Button("Export text", action: exportCaptions).buttonStyle(MeshQuietButtonStyle(compact: true)).disabled(model.transcription.lines.isEmpty)
                    Button("Clear") { model.transcription.clear(); captionExportStatus = "" }.buttonStyle(MeshQuietButtonStyle(compact: true))
                }
                if !captionExportStatus.isEmpty { Text(captionExportStatus).font(.caption).foregroundStyle(MeshInk.cyan) }
                ForEach(model.transcription.lines) { line in
                    HStack(alignment: .top, spacing: 18) {
                        Text(line.timestamp.formatted(date: .omitted, time: .shortened)).font(.system(size: 11 * scale, design: .monospaced)).foregroundStyle(MeshInk.muted).frame(width: 65, alignment: .leading)
                        Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 3)
                }
            }
        }
    }

    private func exportCaptions() {
        let transcript = model.transcription.exportText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Mesh Captions.txt"
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try transcript.write(to: url, atomically: true, encoding: .utf8)
                captionExportStatus = "Transcript exported."
            } catch { captionExportStatus = "Export failed: \(error.localizedDescription)" }
        }
    }

    private var connectionsPage: some View {
        Group {
            pageIntro("Bring your intelligence.", detail: "The conversation, inputs and schedule stay together as your agent changes.")
            MeshGlassCard("Codex", icon: "sparkle") {
                HStack {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Deeper reasoning, in context.").font(.system(size: 23 * scale, weight: .medium, design: .rounded))
                        Text(model.connectionStatus).foregroundStyle(MeshInk.cyan)
                        Text(model.codexSessionModelSummary).font(.callout).foregroundStyle(MeshInk.muted).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Connect", action: model.connect).buttonStyle(MeshPrimaryButtonStyle())
                    Button("Disconnect", action: model.disconnect).buttonStyle(MeshQuietButtonStyle())
                }
                Text("Uses your existing Codex sign-in and a dedicated Mesh Monitor conversation. Your original message travels with the evidence you select.").foregroundStyle(MeshInk.muted)
                Text("This build supports responses and read-only work. Requests requiring approval are declined visibly. Desktop actions and calendar edits are not enabled.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            }
            MeshGlassCard("Control Room", icon: "bubble.left.and.bubble.right", accent: MeshInk.violet) {
                Text(model.controlRoomStatus).font(.system(size: 17 * scale, weight: .medium))
                Text("A verified physical AIY wake opens a session with the existing Control Room. Replies depend on its scheduled watch; delivery time is unavailable. This connection is unavailable until its session is ready. Pause or Stop cancels pending speech.").foregroundStyle(MeshInk.muted)
                Link(destination: URL(string: "codex://threads/019fc1eb-2c9f-7250-ae5b-f733dee052ea")!) { Label("Open Control Room", systemImage: "arrow.up.right") }.foregroundStyle(MeshInk.cyan)
            }
            MeshGlassCard("Voice output", icon: "speaker.wave.2") {
                Text(model.voice.status).foregroundStyle(MeshInk.cyan)
                Toggle("M1 MacBook Pro Speakers · 100%", isOn: Binding(get: { model.voice.useM1Speakers }, set: { model.voice.useM1Speakers = $0 })).disabled(model.voiceRequested)
                Text(model.voice.useM1Speakers ? model.voice.m1Output.status : "This Mac’s current output · volume unchanged").foregroundStyle(MeshInk.muted)
                Text("M1 playback verifies the built-in speaker route before sending audio. Your M4 headphone volume is unchanged.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
                Button("Test selected output · two sentences") {
                    model.voice.speak("Mesh Monitor audio test. This is the second sentence, confirming that the complete message is spoken.")
                }.buttonStyle(MeshQuietButtonStyle()).disabled(model.voiceRequested)
            }
            MeshGlassCard("Home calendar", icon: "calendar", accent: MeshInk.violet) {
                Text(model.home.status).foregroundStyle(MeshInk.muted)
                HStack(spacing: 12) {
                    Button("Connect Apple Calendar") { Task { await model.home.requestAccess() } }.buttonStyle(MeshPrimaryButtonStyle()).disabled(model.home.isRequestingAccess)
                    Button("Refresh Home") { model.home.refresh() }.buttonStyle(MeshQuietButtonStyle())
                }
                if model.home.homeCalendars.count > 1 {
                    ForEach(model.home.homeCalendars) { calendar in
                        Button {
                            model.home.selectHomeCalendar(id: calendar.id)
                        } label: {
                            Label("Home · \(calendar.sourceTitle)", systemImage: model.home.chosenHomeCalendarID == calendar.id ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain).foregroundStyle(MeshInk.cyan)
                    }
                }
                Text("Home is read-only. Calendar access does not create or change events.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            }
            MeshGlassCard("More agents", icon: "puzzlepiece.extension") {
                Text("A home for the agent you choose.").font(.system(size: 20 * scale, weight: .medium, design: .rounded))
                Text("The adapter is separate from capture, voice and task state. Hermes, OpenClaw and Artemis are planned; they are not connected in this build.").foregroundStyle(MeshInk.muted)
            }
        }
    }

    private var systemPage: some View {
        Group {
            pageIntro("Nothing hidden under the hood.", detail: "Actual runtime state and measurements from this session.")
            MeshGlassCard("Display + accessibility", icon: "accessibility") {
                Toggle("Larger interface text", isOn: $largeText)
                Toggle("Higher contrast surfaces", isOn: $highContrast)
                Toggle("Reduce motion", isOn: $reduceMotion)
                Text("System contrast and reduced motion settings are also respected. Captions have their own text size and contrast controls.").font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            }
            MeshGlassCard("Runtime", icon: "waveform.path.ecg") {
                runtimeRow("Primary reasoning", model.connectionStatus)
                runtimeRow("Local vision language model", model.localStatus)
                runtimeRow("Microphone / speech", model.voice.status)
                runtimeRow("Captions", model.transcription.status)
                runtimeRow("Physical AIY wake", model.m1Return.isReady ? "Ready · Dark baseline verified" : model.m1Return.status)
                runtimeRow("M1 wake cleanup", ["not_needed": "No pending cleanup", "pending": "Waiting for M1 acknowledgement", "confirmed": "M1 acknowledged disarm", "unconfirmed": "Remote disarm unconfirmed" ][model.m1Return.disarmStatus] ?? "Unknown")
                runtimeRow("Camera", model.camera.detail)
                runtimeRow("Screen", model.screen.status)
                runtimeRow("Calendar", model.home.status)
            }
            MeshGlassCard("Measured performance", icon: "gauge.with.dots.needle.50percent", accent: MeshInk.violet) {
                runtimeRow("First Codex text", model.firstTokenMS.map { "\($0) ms" } ?? "Not measured")
                runtimeRow("Complete response", model.lastResponseMS.map { "\($0) ms" } ?? "Not measured")
                runtimeRow("Last transcription", model.voice.lastASRMilliseconds.map { "\($0) ms" } ?? "Not measured")
                runtimeRow("Last speech generation", model.voice.lastTTSMilliseconds.map { "\($0) ms per chunk" } ?? "Not measured")
                runtimeRow("Current app + worker memory", model.metrics.currentMB.map { String(format: "%.0f MB", $0) } ?? "Not measured")
                runtimeRow("Peak since launch", model.metrics.peakMB.map { String(format: "%.0f MB", $0) } ?? "Not measured")
                Text(model.metrics.status).font(.system(size: 12 * scale)).foregroundStyle(MeshInk.muted)
            }
            MeshGlassCard("Evidence + control", icon: "checkmark.shield") {
                Text(model.lastEvidence).textSelection(.enabled)
                Text("Selected question images go to your chosen provider. Monitor keeps up to 60 recent conversation messages locally; images are not saved in that history. Codex maintains its own conversation history. Home is read-only.").foregroundStyle(MeshInk.muted)
                Text("App state: ~/Library/Application Support/MeshMonitor").font(.system(size: 12 * scale, design: .monospaced)).foregroundStyle(MeshInk.muted).textSelection(.enabled)
                Button("Pause every input and owned process", action: model.pause).buttonStyle(MeshQuietButtonStyle())
            }
        }
    }

    private func pageIntro(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.system(size: 33 * scale, weight: .medium, design: .rounded)).tracking(-0.6)
            Text(detail).font(.system(size: 15 * scale)).foregroundStyle(MeshInk.muted).lineSpacing(4)
        }.padding(.vertical, 8)
    }

    private func runtimeRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 30) {
            Text(label).foregroundStyle(MeshInk.muted).frame(width: 215, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 13 * scale)).padding(.vertical, 4)
    }
}

private enum MeshInk {
    static let base = Color(red: 0.022, green: 0.039, blue: 0.068)
    static let card = Color(red: 0.051, green: 0.078, blue: 0.122)
    static let text = Color(red: 0.94, green: 0.97, blue: 1)
    static let muted = Color(red: 0.63, green: 0.70, blue: 0.81)
    static let cyan = Color(red: 0.48, green: 0.84, blue: 1)
    static let blue = Color(red: 0.25, green: 0.41, blue: 1)
    static let violet = Color(red: 0.63, green: 0.56, blue: 1)
    static let line = Color(red: 0.29, green: 0.40, blue: 0.56).opacity(0.32)
}

private struct MeshDashboardContrastKey: EnvironmentKey { static let defaultValue = false }
private struct MeshDashboardScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private extension EnvironmentValues {
    var meshDashboardContrast: Bool {
        get { self[MeshDashboardContrastKey.self] }
        set { self[MeshDashboardContrastKey.self] = newValue }
    }
    var meshDashboardScale: CGFloat {
        get { self[MeshDashboardScaleKey.self] }
        set { self[MeshDashboardScaleKey.self] = newValue }
    }
}

private struct MeshGlassCard<Content: View>: View {
    let title: String
    let icon: String
    var accent = MeshInk.cyan
    @ViewBuilder let content: Content
    @Environment(\.meshDashboardContrast) private var contrast
    @Environment(\.meshDashboardScale) private var scale
    init(_ title: String, icon: String, accent: Color = MeshInk.cyan, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.accent = accent; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15 * scale)).foregroundStyle(accent)
                Text(title).font(.system(size: 14 * scale, weight: .semibold))
                Spacer(minLength: 0)
            }
            content
        }.padding(23).frame(maxWidth: .infinity, alignment: .leading)
            .background(contrast ? Color.black : MeshInk.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(contrast ? Color.white.opacity(0.55) : MeshInk.line))
            .overlay(alignment: .top) {
                if !contrast {
                    LinearGradient(colors: [.clear, accent.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing).frame(height: 1).padding(.horizontal, 24)
                }
            }
    }
}

private struct MeshEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(MeshInk.muted) }
}

private struct MeshStatusPill: View {
    let text: String
    let active: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: active ? "circle.fill" : "pause.circle").font(.system(size: active ? 6 : 11)).foregroundStyle(active ? MeshInk.cyan : MeshInk.muted)
            Text(text).font(.system(size: 11, weight: .medium))
        }.padding(.horizontal, 11).padding(.vertical, 7)
            .background(MeshInk.card, in: Capsule()).overlay(Capsule().strokeBorder(MeshInk.line))
    }
}

private struct MeshPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.meshDashboardContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 19).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: contrast ? [Color(red: 0.10, green: 0.22, blue: 0.52), Color(red: 0.10, green: 0.22, blue: 0.52)] : [Color(red: 0.16, green: 0.40, blue: 0.86), MeshInk.blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(contrast ? 0.8 : 0.38)))
            .shadow(color: MeshInk.blue.opacity(enabled && !contrast ? 0.24 : 0), radius: 13, y: 3)
            .opacity(!enabled ? 0.38 : (configuration.isPressed ? 0.72 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct MeshQuietButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.meshDashboardContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, compact ? 12 : 17).padding(.vertical, compact ? 8 : 12)
            .foregroundStyle(MeshInk.text)
            .background(contrast ? Color.black : Color.white.opacity(configuration.isPressed ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: compact ? 10 : 14))
            .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 14).strokeBorder(contrast ? Color.white.opacity(0.7) : MeshInk.line))
            .opacity(enabled ? 1 : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: compact ? 10 : 14))
    }
}

private struct MeshDashboardPreview: View {
    let image: NSImage?
    let symbol: String
    let title: String
    let height: CGFloat
    var body: some View {
        ZStack {
            MeshInk.base
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else {
                VStack(spacing: 12) {
                    Image(systemName: symbol).font(.system(size: 27, weight: .ultraLight)).foregroundStyle(MeshInk.cyan.opacity(0.7))
                    Text(title).font(.system(size: 12)).foregroundStyle(MeshInk.muted).multilineTextAlignment(.center)
                }.padding(16)
            }
        }.frame(maxWidth: .infinity).frame(height: height).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(MeshInk.line.opacity(0.65)))
    }
}

private struct MeshEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34, weight: .ultraLight)).foregroundStyle(MeshInk.cyan)
            Text(title).font(.system(size: 22, weight: .medium, design: .rounded))
            Text(detail).font(.callout).foregroundStyle(MeshInk.muted).multilineTextAlignment(.center).frame(maxWidth: 500)
        }.frame(maxWidth: .infinity).padding(.vertical, 50)
    }
}

private struct MeshConversationBubble: View {
    let role: String
    let text: String
    let evidence: String
    let date: Date?
    let streaming: Bool
    @Environment(\.meshDashboardScale) private var scale
    @Environment(\.meshDashboardContrast) private var contrast
    private var isUser: Bool { role == "You" }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 9) {
                    Image(systemName: isUser ? "person.crop.circle" : "sparkle").foregroundStyle(isUser ? MeshInk.cyan : MeshInk.violet)
                    Text(role).font(.system(size: 12 * scale, weight: .semibold))
                    if streaming { Text("RESPONDING").font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(MeshInk.muted) }
                    Spacer()
                    if let date { Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10 * scale)).foregroundStyle(MeshInk.muted) }
                }
                Text(text).font(.system(size: 15 * scale)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !evidence.isEmpty {
                    Label(evidence, systemImage: "paperclip").font(.system(size: 11 * scale)).foregroundStyle(MeshInk.muted).textSelection(.enabled)
                }
            }.padding(22)
                .background(contrast ? Color.black : (isUser ? MeshInk.cyan.opacity(0.065) : MeshInk.card.opacity(0.75)), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(contrast ? Color.white.opacity(0.5) : MeshInk.line))
            if !isUser { Spacer(minLength: 30) }
        }
    }
}

private struct MeshAudioLevel: View {
    let level: Double
    let active: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<12) { index in
                Capsule().fill(active && level.isFinite && level > Double(index) / 12 ? MeshInk.cyan : MeshInk.muted.opacity(0.25))
                    .frame(width: 3, height: CGFloat(8 + (index % 4) * 4))
            }
        }.accessibilityLabel(active ? "Audio level \(Int(min(1, max(0, level.isFinite ? level : 0)) * 100)) percent" : "Audio input inactive")
    }
}

/// Original aperture/M mark, shared visually with the generated Dock icon.
private struct MeshApertureMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                ForEach(0..<6) { index in
                    MeshApertureBlade().fill(LinearGradient(colors: [MeshInk.cyan, index.isMultiple(of: 2) ? MeshInk.blue : MeshInk.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .rotationEffect(.degrees(Double(index) * 60))
                }
                Path { path in
                    path.move(to: CGPoint(x: side * 0.35, y: side * 0.64))
                    path.addLine(to: CGPoint(x: side * 0.35, y: side * 0.4))
                    path.addLine(to: CGPoint(x: side * 0.5, y: side * 0.53))
                    path.addLine(to: CGPoint(x: side * 0.65, y: side * 0.4))
                    path.addLine(to: CGPoint(x: side * 0.65, y: side * 0.64))
                }.stroke(LinearGradient(colors: [MeshInk.cyan, MeshInk.violet], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: side * 0.065, lineCap: .round, lineJoin: .round))
            }.frame(width: side, height: side)
        }
    }
}

/// A readable companion window. Root owns window level and recording lifecycle.
struct MeshCaptionOverlay: View {
    @ObservedObject var model: MeshMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(model.transcription.isActive ? "LOCAL CAPTIONS" : "CAPTIONS PAUSED", systemImage: "captions.bubble")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(MeshInk.cyan)
                Spacer()
                Button { model.page = .captions; model.showMainWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).accessibilityLabel("Open captions in Mesh Monitor")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.transcription.partialText.isEmpty { Text(model.transcription.partialText) }
                    else if let line = model.transcription.lines.last { Text(line.text) }
                    else { Text(model.transcription.isActive ? "Listening for speech…" : "Start captions to bring speech into view.").foregroundStyle(MeshInk.muted) }
                }.font(.system(size: model.transcription.largeText ? 28 : 21, weight: .medium, design: .rounded))
                    .lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Text(model.transcription.status).font(.system(size: 11)).foregroundStyle(MeshInk.muted).lineLimit(2).help(model.transcription.status)
                Spacer()
                Button(model.transcription.isActive ? "Stop" : "Start captions") {
                    model.transcription.isActive ? model.stopTranscription() : model.startTranscription()
                }.buttonStyle(MeshQuietButtonStyle(compact: true))
            }
        }.padding(22).foregroundStyle(.white)
            .background(model.transcription.highContrast ? Color.black : MeshInk.base)
            .preferredColorScheme(.dark)
    }
}

private struct MeshApertureBlade: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * side, y: y * side) }
        var path = Path()
        path.move(to: p(0.49, 0.07))
        path.addCurve(to: p(0.84, 0.23), control1: p(0.62, 0.055), control2: p(0.75, 0.12))
        path.addLine(to: p(0.58, 0.24))
        path.addCurve(to: p(0.30, 0.41), control1: p(0.45, 0.23), control2: p(0.35, 0.31))
        path.addLine(to: p(0.33, 0.20))
        path.addCurve(to: p(0.49, 0.07), control1: p(0.36, 0.12), control2: p(0.42, 0.09))
        path.closeSubpath()
        return path
    }
}

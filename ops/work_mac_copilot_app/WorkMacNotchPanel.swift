import AppKit

private enum WorkMacNotchSurfaceState {
    case collapsed
    case peek
    case expanded
}

private final class WorkMacNotchHoverView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onBackgroundClick: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: NSView.noIntrinsicMetric
        )
    }

    override var fittingSize: NSSize {
        bounds.size
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

/// A collapsed side control is a single hit target even when its icon is a
/// nested text field. This avoids AppKit delivering the click to the label and
/// leaving the notch visually stuck in its collapsed state.
private final class WorkMacNotchWingView: NSView {
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// macOS normally keeps ordinary windows below the menu bar. A physical-notch
/// surface must be allowed to occupy the hardware cutout band itself.
private final class WorkMacNotchPanel: NSPanel {
    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        frameRect
    }
}

/// Do not let hidden expanded controls advertise a minimum window size while
/// the station is collapsed over the physical camera cutout.
private final class WorkMacNotchHostView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: NSView.noIntrinsicMetric
        )
    }

    override var fittingSize: NSSize {
        bounds.size
    }
}

enum WorkMacAttentionState {
    case checking
    case ready
    case working
    case needsInput
    case completed
    case blocked
    case recording

    var label: String {
        switch self {
        case .checking:
            return "Checking local runtime…"
        case .ready:
            return "Local model ready • bridge independent"
        case .working:
            return "Working locally…"
        case .needsInput:
            return "Needs your approval"
        case .completed:
            return "Done — open chat"
        case .blocked:
            return "Blocked — check local status"
        case .recording:
            return "Recording locally — visible indicator on"
        }
    }

    var color: NSColor {
        switch self {
        case .checking:
            return .systemOrange
        case .ready:
            return .systemGreen
        case .working:
            return .systemBlue
        case .needsInput:
            return .systemOrange
        case .completed:
            return .systemMint
        case .blocked:
            return .systemRed
        case .recording:
            return .systemRed
        }
    }
}

/// A bounded, non-activating attention router anchored to the built-in display
/// notch. Its collapsed surface occupies the hardware notch/menu-bar band and
/// expands downward only on demand. The full local chat remains the work
/// surface. This panel exposes status and typed controls only; it never grants
/// a generic bypass.
@MainActor
final class WorkMacNotchPanelController: NSObject {
    private let fallbackCollapsedHeight: CGFloat = 30
    private let fallbackCollapsedWidth: CGFloat = 190
    private let collapsedWingWidth: CGFloat = 34
    private let peekHeight: CGFloat = 84
    private let peekWidth: CGFloat = 370
    private let expandedHeight: CGFloat = 318
    private let expandedWidth: CGFloat = 560

    private let panel: NSPanel
    // Keep the window geometry independent from the intrinsic size of hidden
    // controls. Without this unconstrained transparent host, AppKit expands the
    // collapsed panel to the detail stack's minimum width and leaves the black
    // surface visibly offset from the physical notch.
    private let hostView = WorkMacNotchHostView()
    private let rootView = WorkMacNotchHoverView()
    private let surfaceContentView = NSView()
    private let activityDot = NSTextField(labelWithString: "●")
    private let collapsedActivityDot = NSTextField(labelWithString: "●")
    private let collapsedChevron = NSTextField(labelWithString: "⌄")
    private let leftWing = WorkMacNotchWingView()
    private let rightWing = WorkMacNotchWingView()
    private let stationLabel = NSTextField(labelWithString: "WM")
    private let activityLabel = NSTextField(
        labelWithString: "Checking local runtime…"
    )
    private let routeBadge = NSTextField(labelWithString: "LOCAL ONLY")
    private let voiceStateBar = NSView()
    private var collapsedRow: NSStackView!
    private let detailStack = NSStackView()
    private let memoryLabel = NSTextField(
        labelWithString: "Ledger/FTS: local • refreshes when expanded"
    )
    private let displayLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton()
    private var shortVoiceState = "LOAD"
    private var surfaceState: WorkMacNotchSurfaceState = .collapsed
    private var delayedCollapse: Task<Void, Never>?
    private var calibrating = false

    private let calibrationXKey = "workMacNotchCalibrationX"
    private let calibrationYKey = "workMacNotchCalibrationY"
    private let calibrationWidthKey = "workMacNotchCalibrationWidth"
    private var calibrationX: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: calibrationXKey))
    }
    private var calibrationY: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: calibrationYKey))
    }
    private var calibrationWidth: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: calibrationWidthKey))
    }

    private let onOpenChat: () -> Void
    private let onMemory: () -> Void
    private let onModels: () -> Void
    private let onVoice: () -> Void
    private let onCaptureClaude: () -> Void
    private let onRecord: () -> Void
    private let onExternalPreview: () -> Void
    private let onEmergencyStop: () -> Void
    private let onRefresh: () -> Void

    init(
        managerModel: String,
        onOpenChat: @escaping () -> Void,
        onMemory: @escaping () -> Void,
        onModels: @escaping () -> Void,
        onVoice: @escaping () -> Void,
        onCaptureClaude: @escaping () -> Void,
        onRecord: @escaping () -> Void,
        onExternalPreview: @escaping () -> Void,
        onEmergencyStop: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.onOpenChat = onOpenChat
        self.onMemory = onMemory
        self.onModels = onModels
        self.onVoice = onVoice
        self.onCaptureClaude = onCaptureClaude
        self.onRecord = onRecord
        self.onExternalPreview = onExternalPreview
        self.onEmergencyStop = onEmergencyStop
        self.onRefresh = onRefresh
        panel = WorkMacNotchPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: fallbackCollapsedWidth,
                height: fallbackCollapsedHeight
            ),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Work Mac Private Station"
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 1
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            // `canJoinAllSpaces` follows this app across ordinary Spaces, but
            // does not by itself join another app's full-screen window set.
            // This is the system-overlay behavior that keeps the station
            // present when Claude Desktop becomes the frontmost/full-screen
            // application.
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.minSize = .zero
        panel.contentMinSize = .zero

        configureRoot(managerModel: managerModel)
        hostView.wantsLayer = true
        hostView.translatesAutoresizingMaskIntoConstraints = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostView
        rootView.frame = hostView.bounds
        rootView.autoresizingMask = [.width, .height]
        hostView.addSubview(rootView)
        rootView.onMouseEntered = { [weak self] in
            self?.handleMouseEntered()
        }
        rootView.onMouseExited = { [weak self] in
            self?.handleMouseExited()
        }
        rootView.onBackgroundClick = { [weak self] in
            self?.handleBackgroundClick()
        }
        leftWing.onClick = { [weak self] in
            self?.handleWingClick()
        }
        rightWing.onClick = { [weak self] in
            self?.handleWingClick()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @discardableResult
    func show() -> Bool {
        setSurfaceState(.collapsed, animated: false)
        guard positionPanel(animated: false) else {
            panel.orderOut(nil)
            return false
        }
        panel.orderFrontRegardless()
        return panel.isVisible
    }

    func hide() {
        delayedCollapse?.cancel()
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func collapse() {
        setSurfaceState(.collapsed)
    }

#if NOTCH_VISUAL_TEST
    func visualTestSetSurfaceState(_ name: String) {
        let state: WorkMacNotchSurfaceState
        switch name {
        case "collapsed": state = .collapsed
        case "peek": state = .peek
        case "expanded": state = .expanded
        default: preconditionFailure("unknown visual test state")
        }
        setSurfaceState(state, animated: false)
    }

    var visualTestPanel: NSPanel { panel }
#endif

    func updateAttention(_ state: WorkMacAttentionState) {
        activityDot.textColor = state.color
        collapsedActivityDot.textColor = state.color
        collapsedChevron.textColor = state.color
        rootView.layer?.borderColor = state.color
            .withAlphaComponent(0.78).cgColor
        activityLabel.stringValue = state.label
        activityLabel.toolTip = state.label
    }

#if M4_LOCAL_VOICE_SESSION
    func updateLocalVoiceStatus(_ message: String, color: NSColor) {
        let bounded = String(message.prefix(240))
        let upper = message.uppercased()
        let shortState: String
        if upper.contains("MICROPHONE") || upper.contains("HEARING")
            || upper.contains("SPEECH DETECTED") {
            shortState = "MIC"
        } else if upper.contains("THINK") || upper.contains("SCREEN") {
            shortState = "THINK"
        } else if upper.contains("KOKORO SPEAKING") {
            shortState = "TALK"
        } else if upper.contains("KOKORO") || upper.contains("GENERATING") {
            shortState = "VOICE"
        } else if upper.contains("BLOCKED") || upper.contains("FAILED") {
            shortState = "ERR"
        } else if upper.contains("STOPPED") {
            shortState = "OFF"
        } else if upper.contains("READY") {
            shortState = "READY"
        } else {
            shortState = "LOAD"
        }
        activityDot.textColor = color
        collapsedActivityDot.textColor = color
        collapsedChevron.textColor = color
        rootView.layer?.borderColor = color
            .withAlphaComponent(0.78).cgColor
        // Preserve the proven Work Mac silhouette: the collapsed left wing is
        // a colored state light, not a second text banner. The exact state is
        // still available through its tooltip and the expanded surface.
        collapsedActivityDot.stringValue = "●"
        shortVoiceState = shortState
        if surfaceState == .collapsed {
            stationLabel.stringValue = shortState
        }
        voiceStateBar.layer?.backgroundColor = color.cgColor
        activityLabel.stringValue = bounded
        activityLabel.toolTip = bounded
        collapsedActivityDot.toolTip = bounded
    }

    func updateLocalVoiceReadiness(_ message: String) {
        let bounded = String(message.prefix(240))
        memoryLabel.stringValue = bounded
        memoryLabel.toolTip = bounded
    }
#endif

    func updateMemory(eventWatermark: Int, ftsWatermark: Int, vector: String) {
        let vectorSummary = vector == "blocked_embedding_identity_not_authorized"
            ? "vector gated"
            : vector
        memoryLabel.stringValue = (
            "Ledger \(eventWatermark) • FTS \(ftsWatermark) • \(vectorSummary)"
        )
    }

    func markMemoryUnavailable() {
        memoryLabel.stringValue = "Ledger/FTS unavailable • failed closed"
    }

    private func configureRoot(managerModel: String) {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.035,
            alpha: 0.98
        ).cgColor
        rootView.layer?.cornerRadius = 17
        rootView.layer?.cornerCurve = .continuous
        rootView.layer?.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
        ]
        rootView.layer?.borderWidth = 0
        rootView.layer?.borderColor = NSColor(
            calibratedWhite: 1,
            alpha: 0.12
        ).cgColor
        surfaceContentView.frame = rootView.bounds
        surfaceContentView.autoresizingMask = [.width, .height]
        rootView.addSubview(surfaceContentView)

        voiceStateBar.wantsLayer = true
        voiceStateBar.layer?.backgroundColor = NSColor.systemOrange.cgColor
        voiceStateBar.frame = NSRect(x: 0, y: 0, width: rootView.bounds.width, height: 3)
        voiceStateBar.autoresizingMask = [.width, .maxYMargin]
        rootView.addSubview(voiceStateBar)

        for wing in [leftWing, rightWing] {
            wing.wantsLayer = true
            wing.layer?.backgroundColor = NSColor.clear.cgColor
            wing.layer?.cornerCurve = .continuous
            rootView.addSubview(wing)
        }

        collapsedActivityDot.font = .systemFont(ofSize: 13, weight: .bold)
        collapsedActivityDot.textColor = .systemOrange
        collapsedActivityDot.alignment = .center
        collapsedActivityDot.setAccessibilityElement(false)
        leftWing.setAccessibilityElement(true)
        leftWing.setAccessibilityRole(.button)
        leftWing.setAccessibilityLabel("Open Work Mac station")
        leftWing.addSubview(collapsedActivityDot)

        collapsedChevron.font = .boldSystemFont(ofSize: 13)
        collapsedChevron.textColor = .systemOrange
        collapsedChevron.alignment = .center
        collapsedChevron.setAccessibilityElement(false)
        rightWing.setAccessibilityElement(true)
        rightWing.setAccessibilityRole(.button)
        rightWing.setAccessibilityLabel("Open Work Mac station")
        rightWing.addSubview(collapsedChevron)

        stationLabel.font = .boldSystemFont(ofSize: 11)
        stationLabel.textColor = .white
        stationLabel.setContentHuggingPriority(.required, for: .horizontal)

        activityDot.font = .systemFont(ofSize: 12, weight: .bold)
        activityDot.textColor = .systemOrange
        activityDot.setContentHuggingPriority(.required, for: .horizontal)

        activityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        activityLabel.textColor = .white
        activityLabel.lineBreakMode = .byTruncatingTail

        routeBadge.font = .boldSystemFont(ofSize: 10)
        routeBadge.textColor = .systemGreen
        routeBadge.alignment = .center
        routeBadge.wantsLayer = true
        routeBadge.layer?.backgroundColor = NSColor.systemGreen
            .withAlphaComponent(0.14).cgColor
        routeBadge.layer?.cornerRadius = 7
        routeBadge.setContentHuggingPriority(.required, for: .horizontal)
        routeBadge.widthAnchor.constraint(equalToConstant: 86).isActive = true
        routeBadge.heightAnchor.constraint(equalToConstant: 22).isActive = true
        activityLabel.isHidden = true
        routeBadge.isHidden = true

        toggleButton.title = "⌄"
        toggleButton.isBordered = false
        toggleButton.font = .boldSystemFont(ofSize: 15)
        toggleButton.contentTintColor = .white
        toggleButton.target = self
        toggleButton.action = #selector(toggleExpanded)
        toggleButton.toolTip = "Expand Work Mac station"
        toggleButton.setContentHuggingPriority(.required, for: .horizontal)

        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowSpacer.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        collapsedRow = NSStackView(views: [
            activityDot,
            stationLabel,
            activityLabel,
            rowSpacer,
            routeBadge,
            toggleButton,
        ])
        collapsedRow.orientation = .horizontal
        collapsedRow.alignment = .centerY
        collapsedRow.spacing = 9
        collapsedRow.translatesAutoresizingMaskIntoConstraints = false
        // The controller starts in `.collapsed`; keep the expanded-row content
        // hidden before the first state application. Otherwise the no-op guard
        // in `setSurfaceState(.collapsed)` leaves a second dot and state label
        // painted over the hardware wings at launch.
        collapsedRow.isHidden = true
        surfaceContentView.addSubview(collapsedRow)

        let identity = NSTextField(
            labelWithString: "One private work conversation • one local manager"
        )
        identity.font = .boldSystemFont(ofSize: 13)
        identity.textColor = .white
        identity.lineBreakMode = .byTruncatingTail
        identity.maximumNumberOfLines = 1

        let model = NSTextField(
            labelWithString: (
                "Default: \(managerModel) • selectable local runtime/model"
            )
        )
        model.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        model.textColor = .secondaryLabelColor
        model.lineBreakMode = .byTruncatingTail
        model.maximumNumberOfLines = 1

        memoryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        memoryLabel.textColor = .secondaryLabelColor
        memoryLabel.lineBreakMode = .byTruncatingTail
        memoryLabel.maximumNumberOfLines = 1

        let localBoundary = boundaryLabel(
            "LOCAL ONLY • chat, memory, files, audio, and frames stay here",
            color: .systemGreen
        )
        let previewBoundary = boundaryLabel(
            "EXTERNAL PREVIEW SCAFFOLD • HEURISTIC • NOT SENDABLE",
            color: .systemOrange
        )
        let blockedBoundary = boundaryLabel(
            "EXTERNAL BLOCKED • company, private, unknown, or ambiguous data",
            color: .systemRed
        )

        let primaryButtons = NSStackView(views: [
            actionButton("Open Chat", action: #selector(openChat)),
            actionButton("Memory", action: #selector(openMemory)),
            actionButton("Models", action: #selector(openModels)),
            actionButton("Voice", action: #selector(openVoice)),
        ])
        primaryButtons.orientation = .horizontal
        primaryButtons.distribution = .fillEqually
        primaryButtons.spacing = 8

        let safetyButtons = NSStackView(views: [
            actionButton(
                "Capture Claude",
                action: #selector(captureClaudeTranscript)
            ),
            actionButton("Record Once", action: #selector(recordOnce)),
            actionButton(
                "External Preview",
                action: #selector(openExternalPreview)
            ),
            actionButton("Stop Voice Runtime", action: #selector(emergencyStop)),
        ])
        safetyButtons.orientation = .horizontal
        safetyButtons.distribution = .fillEqually
        safetyButtons.spacing = 8

        displayLabel.font = .systemFont(ofSize: 10)
        displayLabel.textColor = .tertiaryLabelColor
        displayLabel.alignment = .center

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 9
        detailStack.addArrangedSubview(identity)
        detailStack.addArrangedSubview(model)
        detailStack.addArrangedSubview(memoryLabel)
        detailStack.addArrangedSubview(localBoundary)
        detailStack.addArrangedSubview(previewBoundary)
        detailStack.addArrangedSubview(blockedBoundary)
        detailStack.addArrangedSubview(primaryButtons)
        detailStack.addArrangedSubview(safetyButtons)
        detailStack.addArrangedSubview(displayLabel)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.isHidden = true
        surfaceContentView.addSubview(detailStack)

        let surfaceConstraints = [
            collapsedRow.topAnchor.constraint(
                equalTo: surfaceContentView.topAnchor,
                constant: 8
            ),
            collapsedRow.leadingAnchor.constraint(
                equalTo: surfaceContentView.leadingAnchor,
                constant: 14
            ),
            collapsedRow.trailingAnchor.constraint(
                equalTo: surfaceContentView.trailingAnchor,
                constant: -12
            ),
            detailStack.topAnchor.constraint(
                equalTo: collapsedRow.bottomAnchor,
                constant: 13
            ),
            detailStack.leadingAnchor.constraint(
                equalTo: surfaceContentView.leadingAnchor,
                constant: 18
            ),
            detailStack.trailingAnchor.constraint(
                equalTo: surfaceContentView.trailingAnchor,
                constant: -18
            ),
            primaryButtons.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            safetyButtons.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            localBoundary.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            previewBoundary.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            blockedBoundary.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            displayLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            identity.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            model.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            memoryLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
        ]
        // These constraints describe the expanded layout, but must not become
        // an implicit minimum size for the NSPanel's collapsed hardware-notch
        // frame. Keep them below content-hugging priority so AppKit may break
        // them while the detail stack is hidden instead of silently widening
        // the collapsed panel to the buttons' combined intrinsic width.
        for constraint in surfaceConstraints {
            constraint.priority = NSLayoutConstraint.Priority(249)
        }
        NSLayoutConstraint.activate(surfaceConstraints)
    }

    private func boundaryLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = color
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
        label.layer?.cornerRadius = 6
        label.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return label
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    @objc private func toggleExpanded() {
        setSurfaceState(surfaceState == .expanded ? .collapsed : .expanded)
    }

    private func setSurfaceState(
        _ state: WorkMacNotchSurfaceState,
        animated: Bool = true
    ) {
        // Refresh failures can update attention to `.blocked`. Treat an
        // already-applied state as a no-op so a failed refresh cannot recurse.
        guard surfaceState != state else {
            positionPanel(animated: false)
            return
        }
        delayedCollapse?.cancel()
        surfaceState = state
        collapsedRow.isHidden = state == .collapsed
        detailStack.isHidden = state != .expanded
        activityLabel.isHidden = state == .collapsed
        routeBadge.isHidden = state == .collapsed
        stationLabel.stringValue = state == .expanded
            ? "WORK MAC"
            : shortVoiceState
        toggleButton.title = state == .expanded ? "⌃" : "⌄"
        toggleButton.toolTip = state == .expanded
            ? "Collapse Work Mac station"
            : "Expand Work Mac station"
        panel.hasShadow = state != .collapsed
        rootView.layer?.cornerRadius = state == .collapsed ? 14 : 18
        // A pure-black hardware-notch silhouette visually disappears against
        // dark app menu bars even while the panel remains correctly frontmost.
        // Keep a thin state-colored outline in collapsed mode so presence and
        // phase remain legible across applications and Spaces.
        rootView.layer?.borderWidth = calibrating || state == .expanded
            ? 1
            : 0.8
        positionPanel(animated: animated)
        if state == .expanded {
            // Paint and resize first so status helpers can never make the
            // user's press look ignored. The refresh begins only after the
            // panel is visibly expanded.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 220_000_000)
                self?.onRefresh()
            }
        }
    }

    private func layoutCollapsedSurface(
        width: CGFloat,
        height: CGFloat,
        physicalNotchWidth: CGFloat?
    ) {
        let showWings = surfaceState == .collapsed && physicalNotchWidth != nil
        leftWing.isHidden = !showWings
        rightWing.isHidden = !showWings
        // In collapsed mode the hardware camera housing covers the center.
        // Only the narrow state and disclosure wings should be visible beside
        // it, matching the Work Mac control instead of creating a banner below
        // the menu bar.
        rootView.layer?.backgroundColor = showWings
            ? NSColor.black.cgColor
            : NSColor(calibratedWhite: 0.035, alpha: 0.98).cgColor
        guard showWings else { return }
        let wingWidth = max(0, (width - (physicalNotchWidth ?? width)) / 2)
        leftWing.frame = NSRect(x: 0, y: 0, width: wingWidth, height: height)
        rightWing.frame = NSRect(
            x: width - wingWidth,
            y: 0,
            width: wingWidth,
            height: height
        )
        collapsedActivityDot.frame = leftWing.bounds
        collapsedChevron.frame = rightWing.bounds
    }

    private func handleMouseEntered() {
        delayedCollapse?.cancel()
    }

    private func handleMouseExited() {
        guard surfaceState == .peek, !calibrating else { return }
        delayedCollapse?.cancel()
        delayedCollapse = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.surfaceState == .peek else { return }
                self.setSurfaceState(.collapsed)
            }
        }
    }

    private func handleBackgroundClick() {
        switch surfaceState {
        case .collapsed, .peek:
            setSurfaceState(.expanded)
        case .expanded:
            setSurfaceState(.collapsed)
        }
    }

    private func handleWingClick() {
        delayedCollapse?.cancel()
        setSurfaceState(.expanded)
    }

    private func physicalNotchWidth(on screen: NSScreen) -> CGFloat? {
        guard screen.safeAreaInsets.top > 0 else {
            return nil
        }
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           !left.isEmpty,
           !right.isEmpty {
            let width = right.minX - left.maxX
            if width > 0 {
                return width
            }
        }
        // Some Tahoe builds expose the safe-area inset but leave the
        // auxiliary rectangles empty. Preserve the visible state wings with a
        // conservative, display-scaled cutout estimate; local calibration can
        // then tune the software silhouette without hiding the status entirely.
        return min(220, max(170, screen.frame.width * 0.11))
    }

    @discardableResult
    private func positionPanel(animated: Bool = true) -> Bool {
        let notchedScreen = NSScreen.screens
            .filter { $0.safeAreaInsets.top > 0 }
            .max { $0.safeAreaInsets.top < $1.safeAreaInsets.top }
        guard let screen = notchedScreen
                ?? panel.screen
                ?? NSScreen.main
                ?? NSScreen.screens.first
        else {
            return false
        }
        let safeTop = max(0, screen.safeAreaInsets.top)
        let notchWidth = physicalNotchWidth(on: screen)
        let collapsedWidth = max(
            120,
            (notchWidth.map { $0 + 2 * collapsedWingWidth }
                ?? fallbackCollapsedWidth) + calibrationWidth
        )
        let collapsedHeight = notchWidth == nil
            ? fallbackCollapsedHeight
            : max(24, safeTop)
        let availableWidth = max(320, screen.visibleFrame.width - 40)
        let width: CGFloat
        let height: CGFloat
        switch surfaceState {
        case .collapsed:
            width = collapsedWidth
            height = collapsedHeight
        case .peek:
            width = min(availableWidth, max(peekWidth, collapsedWidth + 150))
            height = peekHeight
        case .expanded:
            width = min(availableWidth, expandedWidth)
            height = expandedHeight
        }
        // Only the collapsed wings occupy the protected hardware-notch band.
        // Peek and expanded controls must begin below it or their first row is
        // hidden behind the camera housing/menu bar.
        let topEdge = surfaceState == .collapsed
            ? screen.frame.maxY + calibrationY
            : screen.frame.maxY - safeTop + calibrationY
        let origin = NSPoint(
            x: screen.frame.midX - width / 2 + calibrationX,
            y: topEdge - height
        )
        displayLabel.stringValue = notchWidth != nil
            ? (
                "Physical notch anchor • x "
                + String(format: "%.0f", calibrationX)
                + " • y " + String(format: "%.0f", calibrationY)
                + " • width " + String(format: "%+.0f", calibrationWidth)
            )
            : "No physical notch detected • use the WM menu-bar fallback"
        let targetFrame = NSRect(
            x: origin.x,
            y: origin.y,
            width: width,
            height: height
        )
        layoutCollapsedSurface(
            width: width,
            height: height,
            physicalNotchWidth: notchWidth
        )
        guard animated, panel.isVisible else {
            panel.setFrame(targetFrame, display: true)
            layoutCollapsedSurface(
                width: width,
                height: height,
                physicalNotchWidth: notchWidth
            )
            return true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            panel.animator().setFrame(targetFrame, display: true)
        }
        return true
    }

    @objc private func displayConfigurationChanged() {
        positionPanel(animated: false)
    }

    func showCalibration() {
        calibrating = true
        show()
        rootView.layer?.borderColor = NSColor.systemOrange.cgColor
        rootView.layer?.borderWidth = 1

        let controls = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 104))
        let positionRow = NSStackView(views: [
            calibrationButton("←", action: #selector(calibrateLeft)),
            calibrationButton("→", action: #selector(calibrateRight)),
            calibrationButton("↑", action: #selector(calibrateUp)),
            calibrationButton("↓", action: #selector(calibrateDown)),
        ])
        positionRow.orientation = .horizontal
        positionRow.distribution = .fillEqually
        positionRow.spacing = 8
        let widthRow = NSStackView(views: [
            calibrationButton("Narrower", action: #selector(calibrateNarrower)),
            calibrationButton("Wider", action: #selector(calibrateWider)),
            calibrationButton("Reset", action: #selector(resetCalibration)),
        ])
        widthRow.orientation = .horizontal
        widthRow.distribution = .fillEqually
        widthRow.spacing = 8
        let stack = NSStackView(views: [positionRow, widthRow])
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 10
        stack.frame = controls.bounds
        stack.autoresizingMask = [.width, .height]
        controls.addSubview(stack)

        let alert = NSAlert()
        alert.messageText = "Calibrate the physical notch anchor"
        alert.informativeText = (
            "Use the arrows and width controls until the orange outline "
            + "matches the built-in camera cutout. Adjustments stay on this Mac."
        )
        alert.accessoryView = controls
        alert.addButton(withTitle: "Save and close")
        alert.runModal()

        calibrating = false
        rootView.layer?.borderColor = NSColor(
            calibratedWhite: 1,
            alpha: 0.12
        ).cgColor
        setSurfaceState(.collapsed, animated: false)
    }

    private func calibrationButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func storeCalibration(
        x: CGFloat? = nil,
        y: CGFloat? = nil,
        width: CGFloat? = nil
    ) {
        if let x {
            UserDefaults.standard.set(max(-24, min(24, x)), forKey: calibrationXKey)
        }
        if let y {
            UserDefaults.standard.set(max(-20, min(12, y)), forKey: calibrationYKey)
        }
        if let width {
            UserDefaults.standard.set(
                max(-40, min(40, width)),
                forKey: calibrationWidthKey
            )
        }
        positionPanel(animated: false)
    }

    @objc private func calibrateLeft() {
        storeCalibration(x: calibrationX - 2)
    }

    @objc private func calibrateRight() {
        storeCalibration(x: calibrationX + 2)
    }

    @objc private func calibrateUp() {
        storeCalibration(y: calibrationY + 1)
    }

    @objc private func calibrateDown() {
        storeCalibration(y: calibrationY - 1)
    }

    @objc private func calibrateNarrower() {
        storeCalibration(width: calibrationWidth - 2)
    }

    @objc private func calibrateWider() {
        storeCalibration(width: calibrationWidth + 2)
    }

    @objc private func resetCalibration() {
        storeCalibration(x: 0, y: 0, width: 0)
    }

    @objc private func openChat() {
        onOpenChat()
    }

    @objc private func openMemory() {
        onMemory()
    }

    @objc private func openModels() {
        onModels()
    }

    @objc private func openVoice() {
        onVoice()
    }

    @objc private func recordOnce() {
        onRecord()
    }

    @objc private func captureClaudeTranscript() {
        onCaptureClaude()
    }

    @objc private func openExternalPreview() {
        onExternalPreview()
    }

    @objc private func emergencyStop() {
        onEmergencyStop()
    }
}

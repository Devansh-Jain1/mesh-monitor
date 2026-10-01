import AppKit
import Combine
import SwiftUI

/// Explicit runtime state. Showing the notch never starts a microphone or model.
enum MeshNotchPhase: String, CaseIterable {
    case off, monitoring, loading, listening, thinking, speaking, captions, paused, unavailable

    var label: String {
        switch self {
        case .off: return "Mic off"
        case .monitoring: return "Monitoring"
        case .loading: return "Starting"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .captions: return "Captioning"
        case .paused: return "Paused"
        case .unavailable: return "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "mic.slash"
        case .monitoring: return "scope"
        case .loading: return "hourglass"
        case .listening: return "waveform"
        case .thinking: return "sparkle"
        case .speaking: return "speaker.wave.2"
        case .captions: return "captions.bubble"
        case .paused: return "pause"
        case .unavailable: return "exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .off, .paused: return Color(red: 0.73, green: 0.78, blue: 0.87)
        case .monitoring, .listening, .captions: return Color(red: 0.40, green: 0.91, blue: 1)
        case .loading, .thinking, .speaking: return Color(red: 0.76, green: 0.68, blue: 1)
        case .unavailable: return Color(red: 1, green: 0.77, blue: 0.44)
        }
    }
}

struct MeshNotchSnapshot: Equatable {
    var phase: MeshNotchPhase = .off
    var detail = "Press Talk to begin."
    var transcript = ""
    var provider = "Codex"
    var captionsEnabled = false
    var talkEnabled = true
    var voiceActive = false

    var statusDescription: String {
        switch phase {
        case .monitoring: "Screen monitoring · local 3B. Microphone off."
        case .off: "Microphone off. Open controls to start a conversation."
        case .paused: "Session paused. Open controls for details."
        case .listening: "Listening for \(provider)."
        case .thinking: "\(provider) is preparing a reply."
        case .speaking: "Speaking a reply from \(provider)."
        case .loading: "Starting voice. The microphone is not listening yet."
        case .captions: "Live captions are active."
        case .unavailable: "Needs attention. Open controls for details."
        }
    }
}

@MainActor final class MeshNotchState: ObservableObject {
    @Published var snapshot = MeshNotchSnapshot()
    @Published fileprivate(set) var expanded = false
    @Published fileprivate(set) var layout = MeshNotchGeometry.layout(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        safeTop: 0, physicalCutoutWidth: nil, expanded: false
    )
}

struct MeshNotchActions {
    var onTalk: () -> Void
    var onOpenApp: () -> Void
    var onCaptions: () -> Void
    var onPause: () -> Void
}

/// Geometry is independent of NSScreen and can be verified without opening UI.
enum MeshNotchGeometry {
    struct Layout: Equatable {
        var frame: CGRect
        /// AppKit coordinates within the panel; transparent padding is not painted.
        var visualFrame: CGRect
        var physicalCutoutWidth: CGFloat
        var leftHitFrame: CGRect
        var rightHitFrame: CGRect
        var hasPhysicalCutout: Bool { physicalCutoutWidth > 0 }
    }

    static let hitSize: CGFloat = 44
    static let wingWidth: CGFloat = 44
    static let visualWingWidth: CGFloat = 34
    static let externalWingWidth: CGFloat = 56

    static func layout(screenFrame: CGRect, safeTop: CGFloat,
                       physicalCutoutWidth: CGFloat?, expanded: Bool) -> Layout {
        let safe = max(0, min(safeTop.isFinite ? safeTop : 0, screenFrame.height / 3))
        let widthEstimate = min(220, max(170, screenFrame.width * 0.11))
        let rawCutout = safe > 0 ? (physicalCutoutWidth ?? widthEstimate) : 0
        let cutout = max(0, min(rawCutout.isFinite ? rawCutout : widthEstimate, max(0, screenFrame.width - 2 * wingWidth)))
        let physical = cutout > 0
        let width = expanded ? min(544, max(288, screenFrame.width - 32)) : (physical ? cutout + 2 * wingWidth : 224)
        let visualHeight: CGFloat = expanded ? 254 : (physical ? max(24, safe) : hitSize)
        let height = max(hitSize, visualHeight)
        let visualWidth = !expanded && physical ? cutout + 2 * visualWingWidth : width
        // Expanded text lives entirely below the camera housing. Collapsed
        // targets flank it; their full 44 pt hit region extends below the bar.
        let top = expanded ? screenFrame.maxY - safe - 8 : screenFrame.maxY
        let frame = CGRect(x: screenFrame.midX - width / 2, y: top - height, width: width, height: height)
        let hitWidth = physical ? wingWidth : externalWingWidth
        return Layout(frame: frame,
                      visualFrame: CGRect(x: (width - visualWidth) / 2, y: height - visualHeight, width: visualWidth, height: visualHeight),
                      physicalCutoutWidth: cutout,
                      leftHitFrame: CGRect(x: 0, y: 0, width: hitWidth, height: height),
                      rightHitFrame: CGRect(x: width - hitWidth, y: 0, width: hitWidth, height: height))
    }
}

/// Public window policy is testable without constructing a window or touching
/// the current display. Never use the screen-saver level or cover system alerts.
enum MeshNotchWindowPolicy {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let collection: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
        .stationary, .ignoresCycle,
    ]
    static let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
}

private final class MeshNotchPanel: NSPanel {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The physical notch paints its chevron in SwiftUI, leaving the native button
/// image empty. NSButtonCell otherwise reports no trackable area for that cell.
/// Preserve standard button mouse-down/up tracking over the whole target.
final class MeshNotchPressCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect,
                          of controlView: NSView) -> NSCell.HitResult {
        guard isEnabled, !controlView.isHiddenOrHasHiddenAncestor,
              controlView.alphaValue > 0,
              cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        return [.contentArea, .trackableArea]
    }
}

/// Native button owns its complete hit rectangle. NSView.hitTest receives a
/// point in the superview's coordinates, including for the offset right wing.
final class MeshNotchPressButton: NSButton {
    private var pointerPressed = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The physical caret is painted by SwiftUI, not by NSButtonCell. Own the
    // pointer lifecycle rather than relying on that empty cell's tracking loop.
    // Keep accessibility performClick on the standard target/action path.
    override func mouseDown(with event: NSEvent) {
        pointerPressed = isEnabled && !isHiddenOrHasHiddenAncestor
            && bounds.contains(convert(event.locationInWindow, from: nil))
        highlight(pointerPressed)
    }
    override func mouseDragged(with event: NSEvent) {
        highlight(pointerPressed && isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) {
        let activate = pointerPressed && isEnabled && !isHiddenOrHasHiddenAncestor
            && bounds.contains(convert(event.locationInWindow, from: nil))
        pointerPressed = false
        highlight(false)
        if activate { sendAction(action, to: target) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// The status wing describes state and has no press action. Keep its tooltip
/// and accessibility description independent from the adjacent expand control.
final class MeshNotchStatusView: NSView {
    func update(description: String) {
        toolTip = description
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Mesh Monitor status")
        setAccessibilityValue(description)
    }
}

private struct MeshNotchStatusTarget: NSViewRepresentable {
    let description: String
    func makeNSView(context: Context) -> MeshNotchStatusView { MeshNotchStatusView() }
    func updateNSView(_ view: MeshNotchStatusView, context: Context) { view.update(description: description) }
}

private struct MeshNotchPressTarget: NSViewRepresentable {
    var symbol: String
    var label: String
    var hidesSymbol = false
    var action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> MeshNotchPressButton {
        let button = MeshNotchPressButton()
        button.cell = MeshNotchPressCell(textCell: "")
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.press)
        return button
    }
    func updateNSView(_ button: MeshNotchPressButton, context: Context) {
        context.coordinator.action = action
        button.image = hidesSymbol ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.image?.isTemplate = true
        button.contentTintColor = NSColor(calibratedRed: 0.68, green: 0.91, blue: 1, alpha: 1)
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }
}

/// Collapsed disclosure is hit-tested by AppKit before SwiftUI's representable
/// routing. The painted caret and this button share the same geometry.
private final class MeshNotchContainer: NSView {
    var disclosure: MeshNotchPressButton?
    override func layout() {
        super.layout()
        for view in subviews where view !== disclosure { view.frame = bounds }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let disclosure, !disclosure.isHidden, disclosure.frame.contains(local) { return disclosure }
        return super.hitTest(point)
    }
}

private final class MeshNotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

@MainActor final class MeshNotchController: NSObject {
    let state: MeshNotchState
    private let panel: NSPanel
    private let container = MeshNotchContainer()
    private let disclosure = MeshNotchPressButton()
    private var wantsVisible = false
    private var manuallySuspended = false
    private var sessionSuspended = false
    private var displayID: CGDirectDisplayID?

    init(state suppliedState: MeshNotchState? = nil, actions: MeshNotchActions) {
        let state = suppliedState ?? MeshNotchState()
        self.state = state
        panel = MeshNotchPanel(contentRect: state.layout.frame, styleMask: MeshNotchWindowPolicy.style, backing: .buffered, defer: false)
        super.init()
        panel.title = "Mesh Monitor Notch"
        panel.level = MeshNotchWindowPolicy.level
        panel.collectionBehavior = MeshNotchWindowPolicy.collection
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.minSize = .zero
        panel.contentMinSize = .zero
        panel.appearance = NSAppearance(named: .darkAqua)
        let view = MeshNotchSurface(state: state, actions: actions, toggle: { [weak self] in self?.toggleExpanded() })
        let host = MeshNotchHostingView(rootView: view)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        // Establish the parent's size before adding an autoresizing child.
        // Starting at zero makes installation as contentView enlarge the host twice.
        container.frame = CGRect(origin: .zero, size: state.layout.frame.size)
        host.frame = container.bounds
        container.addSubview(host)
        disclosure.cell = MeshNotchPressCell(textCell: "")
        disclosure.isBordered = false
        disclosure.title = ""
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(disclosurePressed)
        disclosure.setAccessibilityLabel("Open Mesh controls: Talk, Open app, Captions and Pause")
        disclosure.toolTip = "Open Mesh controls"
        container.addSubview(disclosure)
        container.disclosure = disclosure
        panel.contentView = container
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionHidden), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionHidden), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionReturned), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionReturned), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sessionHidden), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sessionReturned), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        // Geometry changes only through explicit expand/collapse and display
        // notifications; runtime state updates never activate or raise the app.
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    var isVisible: Bool { panel.isVisible }

    func update(_ snapshot: MeshNotchSnapshot) { state.snapshot = snapshot }

    @discardableResult func show(onDisplayID preferred: CGDirectDisplayID? = nil) -> Bool {
        displayID = preferred
        wantsVisible = true
        guard canPresent, position() else { panel.orderOut(nil); return false }
        panel.orderFrontRegardless()
        return panel.isVisible
    }

    func hide() { wantsVisible = false; panel.orderOut(nil) }
    func suspend() { manuallySuspended = true; panel.orderOut(nil) }
    func resume() { manuallySuspended = false; presentIfRequested() }

    private var canPresent: Bool {
        guard !manuallySuspended, !sessionSuspended,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session[kCGSessionOnConsoleKey as String] as? Bool) == true else { return false }
        // Read-only WindowServer session state; never attempts to unlock.
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
    }

    private func presentIfRequested() {
        guard wantsVisible, canPresent, position() else { panel.orderOut(nil); return }
        panel.orderFrontRegardless()
    }
    @objc private func disclosurePressed() { toggleExpanded() }
    func collapse() { setExpanded(false) }
    func toggleExpanded() { setExpanded(!state.expanded) }

    private func setExpanded(_ expanded: Bool) {
        // @Published delivers its value from willSet. Resizing the NSPanel in
        // that publisher synchronously lays out SwiftUI against the OLD state,
        // leaving a collapsed view in an expanded window (or the reverse).
        // Commit state first, then perform AppKit's synchronous resize/layout.
        state.expanded = expanded
        _ = position()
    }

    @discardableResult private func position(expanded: Bool? = nil) -> Bool {
        let screens = NSScreen.screens
        let preferred = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
        guard let screen = preferred ?? screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first else {
            panel.orderOut(nil); return false
        }
        var cutout: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, !left.isEmpty, !right.isEmpty, right.minX > left.maxX {
            cutout = right.minX - left.maxX
        }
        let geometry = MeshNotchGeometry.layout(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top, physicalCutoutWidth: cutout, expanded: expanded ?? state.expanded)
        state.layout = geometry
        panel.hasShadow = expanded ?? state.expanded
        // No implicit view minimum or inherited legacy calibration offsets.
        panel.setFrame(geometry.frame, display: true)
        disclosure.frame = geometry.rightHitFrame
        disclosure.isHidden = state.expanded
        container.layoutSubtreeIfNeeded()
        return true
    }

    @objc private func displayChanged() { presentIfRequested() }
    @objc private func spaceChanged() { presentIfRequested() }
    @objc private func sessionHidden() { sessionSuspended = true; panel.orderOut(nil) }
    @objc private func sessionReturned() { sessionSuspended = false; presentIfRequested() }
}

private struct MeshNotchSurface: View {
    @ObservedObject var state: MeshNotchState
    let actions: MeshNotchActions
    let toggle: () -> Void
    private let cyan = Color(red: 0.40, green: 0.91, blue: 1)
    private let violet = Color(red: 0.66, green: 0.57, blue: 1)

    var body: some View {
        Group {
            if !state.expanded && state.layout.hasPhysicalCutout {
                attachedCollapsed
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: state.expanded ? 24 : 18, style: .continuous)
                        .fill(Color(red: 0.026, green: 0.032, blue: 0.055).opacity(0.98))
                    RoundedRectangle(cornerRadius: state.expanded ? 24 : 18, style: .continuous)
                        .stroke(LinearGradient(colors: [cyan.opacity(0.62), violet.opacity(0.22), cyan.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    if state.expanded { expanded } else { collapsed }
                }
            }
        }
        .frame(width: state.layout.frame.width, height: state.layout.frame.height)
        .clipped()
        .colorScheme(.dark)
    }

    private var attachedCollapsed: some View {
        let visual = state.layout.visualFrame
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14,
                                           bottomTrailingRadius: 14, topTrailingRadius: 0)
        return ZStack(alignment: .topLeading) {
            shape.fill(.black)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(state.snapshot.phase.color).frame(height: 3)
                }
                .clipShape(shape)
                .frame(width: visual.width, height: visual.height)
                .offset(x: visual.minX)
                .allowsHitTesting(false)
            Image(systemName: state.snapshot.phase.symbol)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(state.snapshot.phase.color)
                .frame(width: MeshNotchGeometry.visualWingWidth, height: visual.height)
                .offset(x: visual.minX).allowsHitTesting(false).accessibilityHidden(true)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(state.snapshot.phase.color)
                .frame(width: 26, height: min(24, visual.height - 4))
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.24), lineWidth: 0.7) }
                .frame(width: MeshNotchGeometry.visualWingWidth, height: visual.height)
                .offset(x: visual.maxX - MeshNotchGeometry.visualWingWidth).allowsHitTesting(false).accessibilityHidden(true)
            HStack(spacing: 0) {
                MeshNotchStatusTarget(description: state.snapshot.statusDescription)
                    .frame(width: MeshNotchGeometry.wingWidth, height: state.layout.frame.height)
                Spacer(minLength: state.layout.physicalCutoutWidth)
                MeshNotchPressTarget(symbol: "chevron.down", label: "Open Mesh controls: Talk, Open app, Captions and Pause", hidesSymbol: true, action: toggle)
                    .frame(width: MeshNotchGeometry.wingWidth, height: state.layout.frame.height)
            }
        }
    }

    private var collapsed: some View {
        HStack(spacing: 0) {
            Image(systemName: state.snapshot.phase.symbol)
                .foregroundStyle(state.snapshot.phase.color)
                .frame(width: MeshNotchGeometry.externalWingWidth, height: max(44, state.layout.frame.height))
                .accessibilityHidden(true)
                .overlay { MeshNotchStatusTarget(description: state.snapshot.statusDescription) }
            if state.layout.hasPhysicalCutout {
                Spacer(minLength: state.layout.physicalCutoutWidth)
            } else {
                Text(state.snapshot.phase.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).lineLimit(1).allowsHitTesting(false)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.09))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.24), lineWidth: 0.7) }
                    .frame(width: 30, height: 26).allowsHitTesting(false)
                MeshNotchPressTarget(symbol: "chevron.down", label: "Open Mesh controls: Talk, Open app, Captions and Pause", action: toggle)
            }.frame(width: MeshNotchGeometry.externalWingWidth, height: max(44, state.layout.frame.height))
        }
        .overlay(alignment: .bottom) {
            Capsule().fill(state.snapshot.phase.color).frame(width: 40, height: 2).padding(.bottom, 3).allowsHitTesting(false)
        }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder.circle").font(.system(size: 23, weight: .light)).foregroundStyle(cyan)
                Text("MESH").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(4).foregroundStyle(.white)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: state.snapshot.phase.symbol)
                    Text(state.snapshot.phase.label)
                }.font(.system(size: 11, weight: .semibold)).foregroundStyle(state.snapshot.phase.color)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(state.snapshot.phase.color.opacity(0.09), in: Capsule())
                MeshNotchPressTarget(symbol: "chevron.up", label: "Collapse Mesh Monitor", action: toggle).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(state.snapshot.detail).font(.system(size: 17, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                Text(state.snapshot.transcript.isEmpty ? "\(state.snapshot.provider) · Local speech" : "\(state.snapshot.provider) · \(state.snapshot.transcript)")
                    .font(.system(size: 12)).foregroundStyle(Color(white: 0.76)).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            HStack(spacing: 8) {
                action(state.snapshot.voiceActive ? "Stop voice" : "Talk", symbol: state.snapshot.voiceActive ? "stop.fill" : "mic", prominent: true, enabled: state.snapshot.talkEnabled, callback: actions.onTalk)
                action("Open app", symbol: "arrow.up.right.square", callback: actions.onOpenApp)
                action("Captions", symbol: state.snapshot.captionsEnabled ? "captions.bubble.fill" : "captions.bubble", callback: actions.onCaptions)
                action(state.snapshot.phase == .paused ? "Resume" : "Pause", symbol: state.snapshot.phase == .paused ? "play" : "pause", callback: actions.onPause)
            }
        }.padding(.horizontal, 20).padding(.vertical, 18)
    }

    private func action(_ title: String, symbol: String, prominent: Bool = false, enabled: Bool = true, callback: @escaping () -> Void) -> some View {
        Button(action: callback) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 11, weight: .semibold))
            }.foregroundStyle(prominent ? Color(red: 0.03, green: 0.10, blue: 0.14) : Color.white)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(prominent ? cyan : Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13))
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(title == "Talk" ? "Start voice conversation" : title)
    }
}

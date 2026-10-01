// Concatenate after MeshNotchController.swift. This exercises the actual private
// SwiftUI surface, representables and real controller in unshown windows/panels.
// Never presents a window or synthesizes an operating-system input event.
@main struct MeshNotchInteractionFixture {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        try require(app.windows.isEmpty, "fixture starts with no windows")

        var checked = 0
        let layouts: [(Bool, CGFloat)] = [(true, 24), (true, 32), (true, 40), (false, 0)]
        for (physical, safeTop) in layouts {
            var toggles = 0, actions = 0
            let state = MeshNotchState()
            state.snapshot = MeshNotchSnapshot(phase: .paused, detail: "Fixture only", provider: "Fixture")
            state.layout = MeshNotchGeometry.layout(screenFrame: CGRect(x: -1512, y: 120, width: 1512, height: 982),
                safeTop: safeTop, physicalCutoutWidth: physical ? 190 : nil, expanded: false)
            let callbacks = MeshNotchActions(onTalk: { actions += 1 }, onOpenApp: { actions += 1 },
                onCaptions: { actions += 1 }, onPause: { actions += 1 })
            let surface = MeshNotchSurface(state: state, actions: callbacks, toggle: { toggles += 1 })
            let host = MeshNotchHostingView(rootView: surface)
            host.sizingOptions = []
            let size = state.layout.frame.size
            // A nonzero superview origin catches accidental local/parent point mixing.
            let container = NSView(frame: CGRect(x: 0, y: 0, width: size.width + 80, height: size.height + 80))
            host.frame = CGRect(x: 31, y: 17, width: size.width, height: size.height)
            container.addSubview(host)
            // SwiftUI's outer hosting hit-test graph needs a window context;
            // no orderFront, makeKey, display presentation, or synthetic event.
            let hiddenWindow = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000,
                width: container.frame.width, height: container.frame.height),
                styleMask: .borderless, backing: .buffered, defer: false)
            hiddenWindow.isReleasedWhenClosed = false
            hiddenWindow.contentView = container
            defer { hiddenWindow.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }

            let descendants = descend(host)
            let buttons = descendants.compactMap { $0 as? MeshNotchPressButton }
            let statuses = descendants.compactMap { $0 as? MeshNotchStatusView }
            try require(buttons.count == 1, "collapsed notch must contain exactly one expand button")
            try require(statuses.count == 1, "left wing must expose one native static status")
            let button = buttons[0], status = statuses[0]
            let buttonRect = button.convert(button.bounds, to: host)
            let statusRect = status.convert(status.bounds, to: host)
            try require(buttonRect.width >= 44 && buttonRect.height >= 44, "actual hosted button retains 44-point target")
            try require(near(buttonRect.minX, state.layout.rightHitFrame.minX)
                && near(buttonRect.width, state.layout.rightHitFrame.width), "actual hosted expand geometry matches layout: actual=\(buttonRect), expected=\(state.layout.rightHitFrame), physical=\(physical), safe=\(safeTop)")
            try require(near(buttonRect.minY, 0) && near(buttonRect.height, size.height), "actual button fills the expected vertical hit band")
            try require(near(statusRect.minX, 0) && near(statusRect.width, state.layout.leftHitFrame.width), "actual status stays in left wing")
            try require(near(statusRect.minY, 0) && near(statusRect.height, size.height), "static status retains its full expected slot")
            try require(!(status is NSControl), "static status cannot send a control action")
            try require(status.accessibilityRole() == .staticText, "left status exposes static text to accessibility")
            try require(button.target != nil && button.action != nil, "real representable connects its coordinator")

            func hostedPoint(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x, y: host.isFlipped ? size.height - point.y : point.y)
            }
            func hit(_ point: CGPoint) -> NSView? {
                host.hitTest(host.convert(hostedPoint(point), to: container))
            }
            let visual = state.layout.visualFrame
            let paintedCenter = physical
                ? CGPoint(x: visual.maxX - MeshNotchGeometry.visualWingWidth / 2, y: visual.midY)
                : CGPoint(x: state.layout.rightHitFrame.midX, y: size.height / 2)
            for point in [paintedCenter, CGPoint(x: size.width - 1, y: 1),
                          CGPoint(x: state.layout.rightHitFrame.minX + 1, y: size.height - 1)] {
                let actualHit = hit(point)
                try require(actualHit === button, "host routes visible center and padded target to expand button: physical=\(physical), safe=\(safeTop), local=\(hostedPoint(point)), button=\(buttonRect), hit=\(String(describing: actualHit))")
                // View hit testing and performClick alone bypass NSButtonCell's
                // mouse tracking gate. An image-only cell with no image rejects
                // real clicks even though both of those earlier checks pass.
                let windowPoint = host.convert(hostedPoint(point), to: nil)
                let event = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
                    modifierFlags: [], timestamp: 0, windowNumber: hiddenWindow.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                let cellHit = button.cell!.hitTest(for: event, in: button.bounds, of: button)
                try require(cellHit.contains(.trackableArea),
                    "native cell must track clicks across the visible and padded disclosure target: physical=\(physical)")
                button.isEnabled = false
                try require(button.cell!.hitTest(for: event, in: button.bounds, of: button).isEmpty,
                    "disabled disclosure must reject mouse tracking")
                button.isEnabled = true
                let outsideFrame = button.bounds.offsetBy(dx: size.width * 2, dy: 0)
                try require(button.cell!.hitTest(for: event, in: outsideFrame, of: button).isEmpty,
                    "cell must reject clicks outside its target")
                let before = toggles
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
                    modifierFlags: [], timestamp: 0.01, windowNumber: hiddenWindow.windowNumber,
                    context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
                button.mouseDown(with: event)
                try require(toggles == before, "mouse-down must not expand before release")
                button.mouseUp(with: up)
                try require(toggles == before + 1, "pointer press/release invokes coordinator exactly once")
                button.mouseUp(with: up)
                try require(toggles == before + 1, "unmatched release cannot activate again")
                let outside = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -500, y: -500),
                    modifierFlags: [], timestamp: 0.02, windowNumber: hiddenWindow.windowNumber,
                    context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
                button.mouseDown(with: event)
                button.mouseDragged(with: outside)
                button.mouseUp(with: outside)
                try require(toggles == before + 1, "drag out and release cancels disclosure")
                button.mouseDown(with: event)
                button.isEnabled = false
                button.mouseUp(with: up)
                try require(toggles == before + 1, "disable during press cancels disclosure")
                button.isEnabled = true
                button.performClick(nil)
                try require(toggles == before + 2, "accessibility/programmatic action still invokes coordinator once")
            }
            let before = toggles
            let left = hit(CGPoint(x: state.layout.leftHitFrame.midX, y: size.height / 2))
            try require(!hasPressAncestor(left), "left status has no actionable hit target")
            let gap = hit(CGPoint(x: size.width / 2, y: physical ? size.height - safeTop / 2 : size.height / 2))
            try require(!hasPressAncestor(gap), "hardware gap or external label has no press action")
            try require(toggles == before && actions == 0, "negative hit tests cannot invoke session actions")
            if physical {
                let cutoutLeft = size.width / 2 - state.layout.physicalCutoutWidth / 2
                let cutoutRight = size.width / 2 + state.layout.physicalCutoutWidth / 2
                try require(statusRect.maxX <= cutoutLeft + 0.000001 && buttonRect.minX >= cutoutRight - 0.000001,
                    "hosted controls remain outside hardware cutout")
            }
            try require(!hiddenWindow.isVisible && host.window === hiddenWindow
                && app.windows.allSatisfy { !$0.isVisible }, "offscreen windows must never be presented")
            host.removeFromSuperview()
            checked += 1
        }
        // Exercise the real controller's state -> resize -> hosted-render path.
        // The controller is never shown and callbacks remain inert.
        let controller = MeshNotchController(actions: MeshNotchActions(
            onTalk: {}, onOpenApp: {}, onCaptions: {}, onPause: {}))
        let panel = app.windows.first { $0.title == "Mesh Monitor Notch" }!
        for expanded in [true, false, true, false] {
            controller.toggleExpanded()
            panel.contentView!.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            panel.contentView!.layoutSubtreeIfNeeded()
            let root = panel.contentView!
            let actualHost = root.subviews.first { $0 is MeshNotchHostingView<MeshNotchSurface> }!
            try require(actualHost.frame == root.bounds, "real host must exactly fill container without clipped wings after resize")
            let expected = expanded ? "Collapse Mesh Monitor" : "Open Mesh controls: Talk, Open app, Captions and Pause"
            let labels = descend(panel.contentView!).compactMap { ($0 as? MeshNotchPressButton)?.accessibilityLabel() }
            try require(controller.state.expanded == expanded && labels.contains(expected),
                "real controller must render the correct disclosure after synchronous resize: expected=\(expected), actual=\(labels)")
            try require(!panel.isVisible, "controller test must not present the notch")
        }
        // Exercise root hit routing, not just a representable action.
        let content = panel.contentView!
        let point = CGPoint(x: controller.state.layout.rightHitFrame.midX, y: controller.state.layout.rightHitFrame.midY)
        let rootHit = content.hitTest(point)
        try require(rootHit is MeshNotchPressButton && rootHit?.superview === content,
            "collapsed pointer routing must land on the direct AppKit target")
        panel.close()
        print("PASS: hosted notch interaction in \(checked) layouts; one expand action, static status, center/padding routing.")
        print("{\"windowsCreated\":true,\"windowCount\":\(checked + 1),\"windowsPresented\":false,\"panelsCreated\":true,\"syntheticOSEvents\":false,\"sensorsStarted\":false,\"audioPlayed\":false}")
    }

    @MainActor private static func descend(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descend($0) }
    }
    @MainActor private static func hasPressAncestor(_ view: NSView?) -> Bool {
        var current = view
        while let value = current {
            if value is MeshNotchPressButton { return true }
            current = value.superview
        }
        return false
    }
    // AppKit/SwiftUI may outward-round a representable edge by one Retina pixel.
    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "MeshNotchInteractionFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

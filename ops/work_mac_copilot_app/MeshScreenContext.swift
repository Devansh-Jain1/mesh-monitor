import AppKit
import ApplicationServices
import Combine
import ScreenCaptureKit
import Vision

struct MeshScreenFrame {
    let jpeg: Data
    let capturedAt: Date
    let source: String
    let text: String
    let pointer: String
    let selectedText: String
    let geometry: MeshScreenGeometry
}

/// Pure selection rules shared by capture and the foreground availability check.
/// Accessory applications may own ordinary windows (for example, app helpers).
/// Eligibility alone never selects a window or proves that capture succeeded.
enum MeshScreenCapturePolicy {
    static func eligibleApplication(processID: pid_t?, activationPolicy: NSApplication.ActivationPolicy?, ownPID: pid_t) -> Bool {
        guard let processID, processID > 0, processID != ownPID else { return false }
        return activationPolicy == .regular || activationPolicy == .accessory
    }

    static func eligibleWindow(ownerPID: pid_t?, selectedPID: pid_t?, layer: Int, frame: CGRect) -> Bool {
        guard let selectedPID, selectedPID > 0, ownerPID == selectedPID else { return false }
        return layer == 0 && frame.width > 150 && frame.height > 100
    }

    static func frontmostWindowID(orderedIDs: [CGWindowID], eligibleIDs: Set<CGWindowID>) -> CGWindowID? {
        orderedIDs.first { eligibleIDs.contains($0) }
    }

    static func foregroundStillMatches(selectedPID: pid_t?, foregroundPID: pid_t?) -> Bool {
        guard let selectedPID, selectedPID > 0 else { return false }
        return foregroundPID == selectedPID
    }
}

/// Capture primitive. Explicit questions and the user-started focus monitor call
/// this method; this object has no timer and never uploads a frame itself.
@MainActor final class MeshScreenContext: ObservableObject {
    @Published private(set) var frame: MeshScreenFrame?
    @Published private(set) var preview: NSImage?
    @Published private(set) var status = "Screen capture off"
    @Published private(set) var busy = false
    @Published private(set) var targetApplication = "Last app you used"
    private var lastExternalPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    private var generation = UUID()

    init() {
        noteApplication(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.noteApplication(app) }
        }
    }

    private func noteApplication(_ app: NSRunningApplication?) {
        guard let app, Self.isEligibleApplication(app) else { return }
        lastExternalPID = app.processIdentifier; targetApplication = app.localizedName ?? "Selected application"
    }

    func clear() { generation = UUID(); frame = nil; preview = nil; busy = false; status = "Screen capture off" }

    func requestPermission() { _ = CGRequestScreenCaptureAccess() }
    var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    private static func isEligibleApplication(_ app: NSRunningApplication?) -> Bool {
        MeshScreenCapturePolicy.eligibleApplication(processID: app?.processIdentifier,
            activationPolicy: app?.activationPolicy, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    var hasExternalForeground: Bool { Self.isEligibleApplication(NSWorkspace.shared.frontmostApplication) }

    @discardableResult func capture(foregroundOnly: Bool = false) async throws -> MeshScreenFrame {
        guard !busy else { throw MeshCaptureError.busy }
        guard CGPreflightScreenCaptureAccess() else { throw MeshCaptureError.permission }
        if foregroundOnly {
            let foreground = NSWorkspace.shared.frontmostApplication
            guard Self.isEligibleApplication(foreground) else { throw CancellationError() }
            noteApplication(foreground)
        }
        let selectedPID = lastExternalPID
        busy = true; status = "Capturing \(targetApplication)…"
        let token = generation
        defer { if generation == token { busy = false } }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            let windows = content.windows.filter {
                MeshScreenCapturePolicy.eligibleWindow(ownerPID: $0.owningApplication?.processID,
                    selectedPID: selectedPID, layer: $0.windowLayer, frame: $0.frame)
            }
            // Core Graphics returns front-to-back window order. Never substitute a
            // larger background document from the same application.
            let orderedIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { info -> CGWindowID? in
                guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == selectedPID,
                      let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
                return number.uint32Value
            }
            guard let windowID = MeshScreenCapturePolicy.frontmostWindowID(orderedIDs: orderedIDs,
                    eligibleIDs: Set(windows.map(\.windowID))),
                  let window = windows.first(where: { $0.windowID == windowID })
            else { throw MeshCaptureError.noWindow }
            if foregroundOnly, !MeshScreenCapturePolicy.foregroundStillMatches(selectedPID: selectedPID,
                foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) {
                throw CancellationError()
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = min(1.5, 1440 / max(window.frame.width, 1))
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = true
            // Match the original window rectangle to attached-image pixels:
            // no shadow padding, letterboxing, or clipping at a display edge.
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let capturedAt = Date()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            if foregroundOnly, !MeshScreenCapturePolicy.foregroundStillMatches(selectedPID: selectedPID,
                foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) {
                throw CancellationError()
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw MeshCaptureError.encoding }
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .fast
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let mouse = CGEvent(source: nil)?.location ?? .zero
            let relative = CGPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
            let pointer = window.frame.contains(mouse)
                ? "Pointer within captured window at x=\(Int(relative.x)), y=\(Int(relative.y)) points from its top-left; window size \(Int(window.frame.width))x\(Int(window.frame.height)). Pointer is not eye gaze."
                : "Pointer outside captured window. Pointer is not eye gaze."
            let geometry = MeshScreenGeometry(windowBounds: window.frame,
                imageSize: CGSize(width: image.width, height: image.height),
                displays: content.displays.map { .init(id: String($0.displayID), bounds: CGDisplayBounds($0.displayID)) })
            let value = MeshScreenFrame(jpeg: jpeg, capturedAt: capturedAt, source: "\(window.owningApplication?.applicationName ?? targetApplication) · \(window.title ?? "window")", text: String(text.prefix(8000)), pointer: pointer, selectedText: selection(pid: window.owningApplication?.processID), geometry: geometry)
            frame = value; preview = NSImage(cgImage: image, size: .zero); status = "Captured \(value.source)"
            return value
        } catch { if generation == token { status = error.localizedDescription }; throw error }
    }

    private func selection(pid: pid_t?) -> String {
        guard AXIsProcessTrusted(), let pid else { return "" }
        let application = AXUIElementCreateApplication(pid)
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &element) == .success, let element else { return "" }
        let focused = unsafeBitCast(element, to: AXUIElement.self)
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) != kAXSecureTextFieldSubrole else { return "" }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success else { return "" }
        return String((value as? String ?? "").prefix(8000))
    }
}

enum MeshCaptureError: LocalizedError {
    case permission, noWindow, encoding, busy, staleRoom
    var errorDescription: String? {
        switch self {
        case .permission: "Enable Screen Recording in System Settings, then reopen Monitor."
        case .noWindow: "Open the app you want help with, return here, then capture again. No suitable window was found."
        case .encoding: "The screen image could not be prepared."
        case .busy: "A screen capture is already in progress."
        case .staleRoom: "No fresh room frame is available. Start the chosen camera input first."
        }
    }
}

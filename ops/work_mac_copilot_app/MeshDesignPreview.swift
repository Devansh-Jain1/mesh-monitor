import AppKit
import SwiftUI

/// Offscreen design fixtures, never a screenshot of the user's display. This
/// command opens no window, captures no input, and never arms a wake session.
enum MeshDesignPreview {
    @MainActor static func render(directory: URL) throws {
        guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path),
              !ProcessInfo.processInfo.arguments.contains("--consume-wake-setup") else {
            throw NSError(domain: "MeshPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a new preview directory; wake setup cannot be combined with rendering."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let model = MeshMonitor(persistConversationHistory: false)
        model.taskTitle = "Finish the assignment outline"
        model.finishCondition = "A clear structure and one draft paragraph."
        model.status = "Design preview · inputs off"
        model.provider = "Codex"
        model.connectionStatus = "Disconnected"
        model.messages = [
            MeshMessage(role: "You", text: "Help me work through the introduction.", evidence: "Example message · no capture"),
            MeshMessage(role: "Codex", text: "Start with the question you want the reader to understand. We can build the outline from there.", evidence: "Design fixture · not a model response")
        ]
        for page in [MeshPage.focus, .conversation, .inputs, .morning, .captions, .connections, .system] {
            model.page = page
            model.useM1 = page == .inputs // Render the optional managed controls with no source started.
            model.manualM1Snapshot = false
            let view = NSHostingView(rootView: MeshDashboard(model: model))
            view.frame = NSRect(x: 0, y: 0, width: 1400, height: 1000)
            view.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            // Drain layout work only. No NSWindow is created or presented.
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "MeshPreview", code: 2)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "MeshPreview", code: 3)
            }
            try png.write(to: directory.appendingPathComponent(page.rawValue.lowercased() + ".png"), options: .withoutOverwriting)
        }
        let manifest: [String: Any] = ["kind": "offscreen_design_fixture", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown", "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown", "sensorsStarted": false, "audioPlayed": false, "liveUIAcceptance": false]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }
}

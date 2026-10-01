// Offscreen fixture only. Concatenate this file after MeshNotchController.swift
// in a temporary Swift compilation unit so its private view remains private in
// production. No MeshMonitor, NSPanel, current-screen read, capture, or audio.
@main struct MeshNotchPreviewHarness {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw PreviewError.invalidOutput }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw PreviewError.invalidOutput }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let actions = MeshNotchActions(onTalk: {}, onOpenApp: {}, onCaptions: {}, onPause: {})
        let cases: [(String, MeshNotchPhase, Bool, Bool, String)] = [
            ("physical-paused", .paused, false, true, ""),
            ("physical-monitoring", .monitoring, false, true, ""),
            ("physical-listening", .listening, false, true, ""),
            ("expanded-codex", .listening, true, true, "Help me work through this paragraph."),
            ("external-paused", .paused, false, false, ""),
        ]
        var frames: [[String: Any]] = []
        for (name, phase, expanded, physical, transcript) in cases {
            let state = MeshNotchState()
            state.expanded = expanded
            state.snapshot = MeshNotchSnapshot(phase: phase, detail: "Listening to your question.", transcript: transcript,
                                              provider: "Codex", voiceActive: phase == .listening)
            state.layout = MeshNotchGeometry.layout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                safeTop: physical ? 32 : 0, physicalCutoutWidth: physical ? 190 : nil, expanded: expanded)
            let surface = MeshNotchSurface(state: state, actions: actions, toggle: {})
            let raw = NSHostingView(rootView: surface)
            try render(raw, size: state.layout.frame.size, to: directory.appendingPathComponent(name + "-surface.png"))
            let canvas = NSHostingView(rootView:
                ZStack(alignment: .top) {
                    Color(red: 0.19, green: 0.20, blue: 0.23)
                    if physical {
                        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12,
                                               bottomTrailingRadius: 12, topTrailingRadius: 0)
                            .fill(.black).frame(width: 190, height: 32)
                    }
                    surface.padding(.top, expanded ? 40 : 0)
                }.frame(width: 640, height: expanded ? 320 : 100))
            try render(canvas, size: CGSize(width: 640, height: expanded ? 320 : 100),
                       to: directory.appendingPathComponent(name + ".png"))
            frames.append(["name": name, "panelWidth": state.layout.frame.width, "panelHeight": state.layout.frame.height,
                           "syntheticHardwareCutout": physical, "expanded": expanded])
        }
        let receipt: [String: Any] = ["kind": "offscreen_notch_geometry_fixture", "liveUIAcceptance": false,
            "sensorsStarted": false, "audioPlayed": false, "windowsCreated": false, "frames": frames]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        print("PASS: offscreen notch views rendered; no panel, sensor, or audio created.")
    }

    @MainActor private static func render<V: View>(_ view: NSHostingView<V>, size: CGSize, to url: URL) throws {
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PreviewError.noBitmap }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.noBitmap }
        try png.write(to: url, options: .withoutOverwriting)
    }

    enum PreviewError: Error { case invalidOutput, noBitmap }
}

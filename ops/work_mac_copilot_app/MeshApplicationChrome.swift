import AppKit

/// App-local chrome for both normal SwiftUI and maintenance/wake launches.
/// Never changes the user's global menu-bar or Dock preferences.
@MainActor final class MeshApplicationChrome: NSObject {
    static let shared = MeshApplicationChrome()
    private var observing = false

    func observeFullScreen() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
            name: NSWindow.didEnterFullScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    static func visibleMenuBarOptions(_ options: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        options.subtracting([.hideMenuBar, .autoHideMenuBar])
    }

    @objc private func refresh() {
        // Full-screen transition notifications can precede AppKit's final
        // presentation update. Apply after that update, only for our dashboard.
        DispatchQueue.main.async {
            guard NSApp.isActive,
                  NSApp.windows.contains(where: {
                      $0.isVisible && $0.title == "Mesh Monitor" && $0.styleMask.contains(.fullScreen)
                  }) else { return }
            let options = Self.visibleMenuBarOptions(NSApp.presentationOptions)
            if options != NSApp.presentationOptions { NSApp.presentationOptions = options }
        }
    }

    func installMenuIfMissing() {
        guard NSApp.mainMenu?.items.isEmpty != false else { return }
        let bar = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            parent.submenu = menu; bar.addItem(parent)
            return menu
        }
        let app = submenu("Mesh Monitor")
        let about = app.addItem(withTitle: "About Mesh Monitor",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        app.addItem(.separator())
        let quit = app.addItem(withTitle: "Quit Mesh Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        submenu("File").addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                    ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let view = submenu("View")
        let fullScreen = view.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        let windows = submenu("Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windows
    }
}

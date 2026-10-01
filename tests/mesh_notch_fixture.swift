import AppKit
import Foundation

@main struct MeshNotchFixture {
    @MainActor static func main() {
        func require(_ condition: @autoclosure () -> Bool, _ note: String) {
            precondition(condition(), note)
        }
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let closed = MeshNotchGeometry.layout(screenFrame: screen, safeTop: 32, physicalCutoutWidth: 190, expanded: false)
        require(closed.frame.maxY == screen.maxY, "Collapsed notch remains attached to display top")
        require(closed.frame.midX == screen.midX, "Physical camera centered")
        require(closed.frame.height >= 44, "All targets at least 44 pt tall")
        require(closed.frame.width == 190 + 2 * 44, "Accessible outer wings stay compact")
        require(closed.visualFrame.width == 190 + 2 * 34, "Visible wings restore the earlier 34 pt silhouette")
        require(closed.visualFrame.height == 32, "Visible body stays inside the hardware band")
        require(closed.visualFrame.maxY == closed.frame.height, "Visible body attaches to the display top")
        require(closed.visualFrame.minY == 12, "Extra click height is transparent below the body")
        require(closed.visualFrame.minX == 10, "Extra click width is transparent outside each wing")
        require(CGRect(origin: .zero, size: closed.frame.size).contains(closed.visualFrame), "Visible body remains inside its click window")
        let cutout = CGRect(x: closed.frame.width / 2 - 95, y: closed.frame.height - 32, width: 190, height: 32)
        require(!closed.leftHitFrame.intersects(cutout), "Left target outside hardware cutout")
        require(!closed.rightHitFrame.intersects(cutout), "Right target outside hardware cutout")
        require(closed.rightHitFrame.width >= 44 && closed.leftHitFrame.width >= 44, "Targets at least 44 pt wide")
        require(closed.leftHitFrame.contains(CGPoint(x: 2, y: 2)), "Transparent outer padding remains part of the left target")
        require(closed.rightHitFrame.contains(CGPoint(x: closed.frame.width - 2, y: 2)), "Transparent outer padding remains part of the right target")
        let opened = MeshNotchGeometry.layout(screenFrame: screen, safeTop: 32, physicalCutoutWidth: 190, expanded: true)
        require(opened.frame.maxY < screen.maxY - 32, "All expanded content is below camera housing")
        require(screen.contains(opened.frame), "Expanded surface inside screen")

        let external = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        for expanded in [true, false] {
            let layout = MeshNotchGeometry.layout(screenFrame: external, safeTop: 0, physicalCutoutWidth: nil, expanded: expanded)
            require(external.contains(layout.frame), "Negative-origin external display clamps correctly")
            require(layout.frame.midX == external.midX, "External display center preserved")
            require(layout.physicalCutoutWidth == 0, "External display has no invented notch")
            require(layout.visualFrame == CGRect(origin: .zero, size: layout.frame.size), "External pill and expanded panel preserve their full visible footprint")
        }
        let fallback = MeshNotchGeometry.layout(screenFrame: screen, safeTop: 32, physicalCutoutWidth: nil, expanded: false)
        require(fallback.physicalCutoutWidth >= 170 && fallback.physicalCutoutWidth <= 220, "Missing auxiliary rectangles get conservative wings")
        for width in stride(from: 800, through: 3456, by: 83) {
            for height in [600, 982, 1440] {
                for safeTop: CGFloat in [0, 24, 32, 40] {
                    let frame = CGRect(x: -2100, y: 247, width: width, height: height)
                    for expanded in [false, true] {
                        let layout = MeshNotchGeometry.layout(screenFrame: frame, safeTop: safeTop, physicalCutoutWidth: nil, expanded: expanded)
                        require(frame.contains(layout.frame), "Geometry stays on the selected display")
                        require(layout.frame.midX == frame.midX, "Geometry stays centered at all sizes")
                        require(CGRect(origin: .zero, size: layout.frame.size).contains(layout.visualFrame), "Visible surface remains inside the accessible window")
                        require(layout.visualFrame.maxY == layout.frame.height, "Visible surface stays top-aligned")
                        require(layout.leftHitFrame.height >= 44 && layout.rightHitFrame.height >= 44, "Transparent padding retains accessible target heights")
                        if !expanded && safeTop > 0 {
                            require(layout.visualFrame.height == max(24, safeTop), "Physical silhouette follows the hardware band")
                            let gapStart = layout.frame.width / 2 - layout.physicalCutoutWidth / 2
                            let gap = CGRect(x: gapStart, y: layout.frame.height - safeTop, width: layout.physicalCutoutWidth, height: safeTop)
                            // Fractional estimated cutout widths can differ by a few
                            // floating-point ULPs at the shared, non-overlapping edge.
                            require(layout.leftHitFrame.maxX <= gap.minX + 0.000001
                                && layout.rightHitFrame.minX >= gap.maxX - 0.000001,
                                "Neither enlarged click target overlaps the camera cutout")
                        }
                    }
                }
            }
        }

        require(MeshNotchWindowPolicy.style.contains(.nonactivatingPanel), "Panel never takes application activation")
        require(MeshNotchWindowPolicy.collection.contains(.canJoinAllSpaces), "Ordinary Spaces eligible")
        require(MeshNotchWindowPolicy.collection.contains(.fullScreenAuxiliary), "Full screen eligible")
        require(MeshNotchWindowPolicy.collection.contains(.canJoinAllApplications), "Other application full screen eligible")
        require(MeshNotchWindowPolicy.level.rawValue > NSWindow.Level.statusBar.rawValue, "Not buried under application/menu bar")
        require(MeshNotchWindowPolicy.level.rawValue < NSWindow.Level.screenSaver.rawValue, "Never competes with lock screen")

        // No NSApplication, NSPanel, display read, UI presentation, recording, or
        // playback. Exercise AppKit coordinate conversion on unattached views.
        let container = NSView(frame: CGRect(origin: .zero, size: closed.frame.size))
        let button = MeshNotchPressButton(frame: closed.rightHitFrame)
        button.image = nil // The restored silhouette draws its icon separately.
        container.addSubview(button)
        require(button.hitTest(CGPoint(x: closed.rightHitFrame.midX, y: 22)) === button, "Offset right caret accepts click in superview coordinates")
        require(button.hitTest(CGPoint(x: 22, y: 22)) == nil, "Right caret rejects unrelated left-wing click")
        require(button.hitTest(CGPoint(x: closed.frame.width - 1, y: 1)) === button, "Transparent outer and lower padding remains clickable without a native button image")
        require(button.hitTest(CGPoint(x: closed.frame.width / 2, y: 22)) == nil, "Right caret rejects the camera cutout")
        require(button.acceptsFirstMouse(for: nil), "First click works while another app is active")
        button.isHidden = true
        require(button.hitTest(CGPoint(x: closed.rightHitFrame.midX, y: 22)) == nil, "Hidden targets do not steal clicks")
        print("PASS: notch geometry, full-screen/Spaces policy, 44 pt targets, offset-caret hit regression. No window or audio created.")
    }
}

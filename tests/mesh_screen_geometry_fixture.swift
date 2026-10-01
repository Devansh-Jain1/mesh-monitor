import Foundation

@main struct MeshScreenGeometryFixture {
    static func main() {
        let geometry = MeshScreenGeometry(
            windowBounds: CGRect(x: -900, y: 200, width: 800, height: 400),
            imageSize: CGSize(width: 1600, height: 800),
            displays: [.init(id: "main", bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
                       .init(id: "left", bounds: CGRect(x: -1000, y: 100, width: 1000, height: 800))])
        // Negative-origin secondary display and a 2x screenshot. Display center
        // is global (-500,500), i.e. screenshot pixel (800,600), not its center.
        assert(geometry.imagePoint(normalizedGaze: CGPoint(x: 0.5, y: 0.5), displayID: "left") == CGPoint(x: 800, y: 600))
        assert(geometry.imagePoint(normalizedGaze: CGPoint(x: 0.5, y: 0.5), displayID: "main") == nil)
        assert(geometry.imagePoint(normalizedGaze: CGPoint(x: 0.5, y: 0.5), displayID: "disconnected") == nil)
        assert(geometry.imagePoint(normalizedGaze: CGPoint(x: 1.1, y: 0.5), displayID: "left") == nil)
        assert(geometry.imagePoint(normalizedGaze: CGPoint(x: .nan, y: 0.5), displayID: "left") == nil)
        let now = Date(timeIntervalSince1970: 1_789_800_000)
        let mapped = geometry.gazeDescription(point: CGPoint(x: 0.5, y: 0.5), displayID: "left", gazeCapturedAt: now, imageCapturedAt: now, source: "Native")
        assert(mapped.contains("x=800, y=600") && mapped.contains("not exact word selection"))
        let stale = geometry.gazeDescription(point: CGPoint(x: 0.5, y: 0.5), displayID: "left", gazeCapturedAt: now, imageCapturedAt: now.addingTimeInterval(2), source: "Native")
        assert(stale.contains("not mapped") && !stale.contains("x=800"))
        let offscreen = geometry.gazeDescription(point: CGPoint(x: 0.5, y: 0.5), displayID: "main", gazeCapturedAt: now, imageCapturedAt: now, source: "Native")
        assert(offscreen.contains("no point inside"))
        let invalid = MeshScreenGeometry(windowBounds: .zero, imageSize: .zero, displays: geometry.displays)
        assert(invalid.imagePoint(normalizedGaze: CGPoint(x: 0.5, y: 0.5), displayID: "left") == nil)
        print("PASS: screen/gaze projection; no screen or camera capture")
    }
}

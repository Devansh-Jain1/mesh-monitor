import Foundation
import CoreGraphics

/// Coordinates are Quartz desktop points, with a top-left origin on the main
/// display. A different display can have a negative origin. Image coordinates
/// are pixels in the original attached screenshot, not the resized UI preview.
struct MeshScreenGeometry: Sendable {
    struct Display: Sendable {
        let id: String
        let bounds: CGRect
    }
    let windowBounds: CGRect
    let imageSize: CGSize
    let displays: [Display]

    func imagePoint(normalizedGaze: CGPoint, displayID: String) -> CGPoint? {
        guard normalizedGaze.x.isFinite, normalizedGaze.y.isFinite,
              (0...1).contains(normalizedGaze.x), (0...1).contains(normalizedGaze.y),
              valid(windowBounds), imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              let display = displays.first(where: { $0.id == displayID }), valid(display.bounds) else { return nil }
        let global = CGPoint(x: display.bounds.minX + normalizedGaze.x * display.bounds.width,
                             y: display.bounds.minY + normalizedGaze.y * display.bounds.height)
        guard windowBounds.contains(global) else { return nil }
        return CGPoint(x: (global.x - windowBounds.minX) / windowBounds.width * imageSize.width,
                       y: (global.y - windowBounds.minY) / windowBounds.height * imageSize.height)
    }

    var description: String {
        let screens = displays.prefix(8).map { "display \($0.id): \(rect($0.bounds))" }.joined(separator: "; ")
        return "Screenshot geometry: Quartz desktop points, top-left origin; window \(rect(windowBounds)); attached image \(Int(imageSize.width))x\(Int(imageSize.height)) pixels. \(screens)."
    }

    func gazeDescription(point: CGPoint, displayID: String, gazeCapturedAt: Date, imageCapturedAt: Date, source: String) -> String {
        guard abs(gazeCapturedAt.timeIntervalSince(imageCapturedAt)) <= 1 else {
            return "\(source) gaze was not mapped to Image 1: gaze and screenshot are more than one second apart."
        }
        guard displays.contains(where: { $0.id == displayID }) else {
            return "\(source) gaze was not mapped to Image 1: its calibrated display is absent from the screenshot geometry."
        }
        guard let mapped = imagePoint(normalizedGaze: point, displayID: displayID) else {
            return "\(source) gaze has no point inside Image 1; do not assume the user is looking at this window."
        }
        return "\(source) approximate gaze region in Image 1: x=\(Int(mapped.x)), y=\(Int(mapped.y)) pixels from its top-left. Gaze captured \(gazeCapturedAt.ISO8601Format()); screenshot captured \(imageCapturedAt.ISO8601Format()). This geometric projection is not exact word selection, calibrated accuracy proof, or evidence of understanding."
    }

    private func valid(_ value: CGRect) -> Bool {
        [value.origin.x, value.origin.y, value.width, value.height].allSatisfy(\.isFinite)
            && value.width > 0 && value.height > 0
    }
    private func rect(_ value: CGRect) -> String {
        "x=\(value.origin.x),y=\(value.origin.y),width=\(value.width),height=\(value.height)"
    }
}

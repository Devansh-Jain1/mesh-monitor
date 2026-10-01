import Foundation
import CoreGraphics

/// A pure, opt-in projection for a single background screenshot. This neither
/// imports observations nor starts tracking. The caller journals status/source
/// only: modelText and normalizedImagePoint contain ephemeral gaze context.
enum MeshFocusGazeContext {
    enum Source: String, Sendable { case neoCursor, native }

    struct Result: Sendable {
        let modelText: String
        let status: String
        let provenance: String
        let normalizedImagePoint: CGPoint?
        let source: Source?
        var used: Bool { normalizedImagePoint != nil && source != nil }
    }

    static func prepare(enabled: Bool, expectedCameraID: String, expectedDisplayID: String,
                        expectedCalibrationID: String, neoCursor: MeshNeoCursorObservation?,
                        native: MeshNativeGazeObservation?, geometry: MeshScreenGeometry,
                        screenCapturedAt: Date, now: Date) -> Result {
        guard enabled else {
            return Result(modelText: "", status: "Gaze context off", provenance: "Not shared",
                          normalizedImagePoint: nil, source: nil)
        }
        guard !expectedDisplayID.isEmpty else { return omitted("Choose the calibrated display first") }
        guard now.timeIntervalSince1970.isFinite, screenCapturedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince(screenCapturedAt) >= -0.25 else {
            return omitted("Screenshot timing is invalid")
        }
        guard valid(geometry.windowBounds), geometry.imageSize.width.isFinite, geometry.imageSize.height.isFinite,
              geometry.imageSize.width > 0, geometry.imageSize.height > 0 else {
            return omitted("Screenshot geometry is invalid")
        }
        let displays = geometry.displays.filter { $0.id == expectedDisplayID }
        guard displays.count == 1, let display = displays.first, valid(display.bounds) else {
            return omitted("The calibrated display is absent or ambiguous in this screenshot")
        }

        var neoReason = "no sample"
        if let observation = neoCursor {
            if expectedCameraID.isEmpty || expectedCalibrationID.isEmpty
                || observation.cameraID != expectedCameraID || observation.displayID != expectedDisplayID
                || observation.calibrationID != expectedCalibrationID || observation.source != "neocursor" {
                neoReason = "source identity does not match"
            } else if observation.schemaVersion != 2 || !observation.calibrated
                || observation.confidence != nil || observation.validation?.isUsable != true {
                // Legacy confidence-only schema 1 is not held-out calibration proof.
                neoReason = "held-out calibration is unavailable"
            } else if !observation.isUsable(cameraID: expectedCameraID, displayID: expectedDisplayID,
                                            calibrationID: expectedCalibrationID, now: now) {
                neoReason = "sample is stale or invalid"
            } else if abs(observation.capturedAt.timeIntervalSince(screenCapturedAt)) > 1 {
                neoReason = "sample and screenshot are over one second apart"
            } else if let point = normalizedPoint(CGPoint(x: observation.x, y: observation.y),
                                                  displayID: expectedDisplayID, geometry: geometry) {
                return included(point, source: .neoCursor)
            } else { neoReason = "gaze falls outside the captured window" }
        }

        var nativeReason = "no sample"
        if let observation = native {
            if observation.displayID != expectedDisplayID {
                nativeReason = "calibrated display does not match"
            } else if !observation.isUsable(now: now) {
                nativeReason = "sample is stale or invalid"
            } else if abs(observation.capturedAt.timeIntervalSince(screenCapturedAt)) > 1 {
                nativeReason = "sample and screenshot are over one second apart"
            } else if let point = normalizedPoint(observation.point, displayID: expectedDisplayID, geometry: geometry) {
                // This type is emitted by the native producer only after its
                // attended calibration succeeds. It carries no camera/calibration
                // IDs, so do not invent matching provenance for those fields.
                return included(point, source: .native)
            } else { nativeReason = "gaze falls outside the captured window" }
        }
        return omitted("NeoCursor: \(neoReason); native: \(nativeReason)")
    }

    private static func normalizedPoint(_ point: CGPoint, displayID: String,
                                        geometry: MeshScreenGeometry) -> CGPoint? {
        guard let pixel = geometry.imagePoint(normalizedGaze: point, displayID: displayID) else { return nil }
        let normalized = CGPoint(x: pixel.x / geometry.imageSize.width, y: pixel.y / geometry.imageSize.height)
        guard normalized.x.isFinite, normalized.y.isFinite,
              (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
        return normalized
    }

    private static func included(_ point: CGPoint, source: Source) -> Result {
        let label = source == .neoCursor ? "NeoCursor" : "Native"
        let provenance = source == .neoCursor
            ? "Experimental NeoCursor · producer-reported held-out calibration · matching source IDs"
            : "Experimental native gaze · calibrated display matched · camera/calibration IDs unavailable"
        let coordinate = String(format: "x=%.3f, y=%.3f", locale: Locale(identifier: "en_US_POSIX"), point.x, point.y)
        let text = "Optional experimental \(label) gaze: approximate region \(coordinate), normalized 0–1 from the screenshot's top-left, independent of image resize. Sample is fresh and within one second of this screenshot. This is a geometric estimate, not exact word selection or evidence of attention, emotion, understanding, task relation or completion."
        return Result(modelText: text, status: "Approximate \(label) gaze region available", provenance: provenance,
                      normalizedImagePoint: point, source: source)
    }

    private static func omitted(_ reason: String) -> Result {
        Result(modelText: "Optional gaze context omitted: \(reason). No gaze coordinates are available.",
               status: "Gaze omitted · \(reason)", provenance: "No usable gaze shared",
               normalizedImagePoint: nil, source: nil)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}

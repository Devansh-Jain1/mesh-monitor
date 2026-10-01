import Foundation

@main struct FocusGazeContextFixture {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let geometry = MeshScreenGeometry(
            windowBounds: CGRect(x: -900, y: 200, width: 800, height: 400),
            imageSize: CGSize(width: 1600, height: 800),
            displays: [.init(id: "left", bounds: CGRect(x: -1000, y: 100, width: 1000, height: 800)),
                       .init(id: "main", bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000))])
        let validation = MeshNeoCursorObservation.Validation(kind: "held-out-screen-error", maxError: 0.1,
            trainingTargets: 5, heldOutTargets: 2, minSamplesPerTarget: 12, coordinateOrigin: "top-left")
        func neo(camera: String = "camera", display: String = "left", calibration: String = "calibration",
                 source: String = "neocursor", schema: Int = 2, calibrated: Bool = true,
                 point: CGPoint = CGPoint(x: 0.5, y: 0.5), offset: Double = 0,
                 confidence: Double? = nil, quality: MeshNeoCursorObservation.Validation? = validation) -> MeshNeoCursorObservation {
            MeshNeoCursorObservation(schemaVersion: schema, source: source, capturedAt: now.addingTimeInterval(offset),
                cameraID: camera, displayID: display, calibrationID: calibration, calibrated: calibrated,
                x: point.x, y: point.y, confidence: confidence, validation: quality)
        }
        func native(display: String = "left", point: CGPoint = CGPoint(x: 0.5, y: 0.5), offset: Double = 0) -> MeshNativeGazeObservation {
            MeshNativeGazeObservation(point: point, displayID: display, capturedAt: now.addingTimeInterval(offset))
        }
        func prepare(enabled: Bool = true, camera: String = "camera", display: String = "left", calibration: String = "calibration",
                     neo: MeshNeoCursorObservation? = nil, native: MeshNativeGazeObservation? = nil,
                     captured: Date = now, image: MeshScreenGeometry = geometry, current: Date = now) -> MeshFocusGazeContext.Result {
            MeshFocusGazeContext.prepare(enabled: enabled, expectedCameraID: camera, expectedDisplayID: display,
                expectedCalibrationID: calibration, neoCursor: neo, native: native, geometry: image,
                screenCapturedAt: captured, now: current)
        }
        var checks = 0
        func omitted(_ result: MeshFocusGazeContext.Result, reason: String) {
            assert(!result.used && result.source == nil && result.normalizedImagePoint == nil)
            assert(result.status.contains(reason), result.status)
            assert(!result.modelText.contains("x=") && !result.modelText.contains("y="))
            assert(result.modelText.utf8.count <= 768 && result.status.utf8.count <= 384)
            checks += 1
        }
        let off = prepare(enabled: false, neo: neo(), native: native())
        omitted(off, reason: "off"); assert(off.modelText.isEmpty)
        omitted(prepare(), reason: "no sample")
        omitted(prepare(display: "", neo: neo()), reason: "display first")
        omitted(prepare(camera: "", neo: neo()), reason: "identity")
        omitted(prepare(calibration: "", neo: neo()), reason: "identity")

        let selected = prepare(neo: neo(), native: native(point: CGPoint(x: 0.2, y: 0.2)))
        assert(selected.used && selected.source == .neoCursor)
        assert(selected.normalizedImagePoint == CGPoint(x: 0.5, y: 0.75))
        assert(selected.modelText.contains("x=0.500, y=0.750") && selected.modelText.contains("not exact word selection"))
        assert(!selected.modelText.contains("camera") && !selected.modelText.contains("calibration"))
        assert(selected.modelText.utf8.count <= 768 && selected.provenance.utf8.count <= 256)
        checks += 1
        let resizedGeometry = MeshScreenGeometry(windowBounds: geometry.windowBounds,
            imageSize: CGSize(width: 768, height: 384), displays: geometry.displays)
        let resized = prepare(neo: neo(), image: resizedGeometry)
        assert(resized.normalizedImagePoint == selected.normalizedImagePoint); checks += 1

        for invalid in [neo(camera: "other-camera"), neo(display: "main"), neo(calibration: "other-fit"), neo(source: "other")] {
            omitted(prepare(neo: invalid), reason: "identity")
        }
        for invalid in [neo(schema: 1, confidence: 0.99), neo(calibrated: false), neo(quality: nil), neo(confidence: 0.99)] {
            omitted(prepare(neo: invalid), reason: "held-out calibration")
        }
        let invalidQuality = MeshNeoCursorObservation.Validation(kind: "held-out-screen-error", maxError: 0.16,
            trainingTargets: 5, heldOutTargets: 2, minSamplesPerTarget: 12, coordinateOrigin: "top-left")
        omitted(prepare(neo: neo(quality: invalidQuality)), reason: "held-out calibration")
        for invalid in [neo(offset: -1.01), neo(offset: 0.26), neo(point: CGPoint(x: .nan, y: 0.5)), neo(point: CGPoint(x: 1.1, y: 0.5))] {
            omitted(prepare(neo: invalid), reason: "stale or invalid")
        }
        omitted(prepare(neo: neo(), captured: now.addingTimeInterval(-1.01)), reason: "one second apart")
        let boundary = prepare(neo: neo(offset: -1), captured: now)
        assert(boundary.used); checks += 1
        omitted(prepare(neo: neo(point: CGPoint(x: 0.95, y: 0.95))), reason: "outside the captured window")

        let fallback = prepare(neo: neo(offset: -2), native: native())
        assert(fallback.used && fallback.source == .native && fallback.normalizedImagePoint == selected.normalizedImagePoint)
        assert(fallback.provenance.contains("Experimental native") && fallback.provenance.contains("IDs unavailable"))
        assert(fallback.modelText.utf8.count <= 768); checks += 1
        omitted(prepare(native: native(display: "main")), reason: "display does not match")
        omitted(prepare(native: native(offset: -1.01)), reason: "stale or invalid")
        omitted(prepare(native: native(point: CGPoint(x: CGFloat.infinity, y: 0))), reason: "stale or invalid")
        omitted(prepare(native: native(), captured: now.addingTimeInterval(-1.01)), reason: "one second apart")
        omitted(prepare(native: native(point: CGPoint(x: 0, y: 0))), reason: "outside the captured window")
        let nativeWithoutNeoIDs = prepare(camera: "", calibration: "", native: native())
        assert(nativeWithoutNeoIDs.used && nativeWithoutNeoIDs.source == .native); checks += 1

        let noDisplay = MeshScreenGeometry(windowBounds: geometry.windowBounds, imageSize: geometry.imageSize, displays: [])
        omitted(prepare(neo: neo(), image: noDisplay), reason: "absent or ambiguous")
        let duplicates = MeshScreenGeometry(windowBounds: geometry.windowBounds, imageSize: geometry.imageSize,
            displays: [geometry.displays[0], geometry.displays[0]])
        omitted(prepare(neo: neo(), image: duplicates), reason: "absent or ambiguous")
        let invalidImage = MeshScreenGeometry(windowBounds: geometry.windowBounds, imageSize: .zero, displays: geometry.displays)
        omitted(prepare(neo: neo(), image: invalidImage), reason: "geometry is invalid")
        let invalidWindow = MeshScreenGeometry(windowBounds: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), imageSize: geometry.imageSize, displays: geometry.displays)
        omitted(prepare(neo: neo(), image: invalidWindow), reason: "geometry is invalid")
        omitted(prepare(neo: neo(), captured: now.addingTimeInterval(0.26)), reason: "timing is invalid")
        omitted(prepare(neo: neo(), current: Date(timeIntervalSince1970: .nan)), reason: "timing is invalid")
        print("PASS \(checks) offline optional focus gaze fixtures; no inputs, imports, or runtime actions")
    }
}

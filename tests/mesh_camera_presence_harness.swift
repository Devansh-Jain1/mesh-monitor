import Foundation

@main
struct MeshCameraPresenceHarness {
    @MainActor static func main() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let id = UUID()
        func observation(_ seconds: Double, present: Bool = true, confidence: Double = 0.9,
                         timestamp: Bool = true) -> MeshPresenceObservation {
            MeshPresenceObservation(capturedAt: timestamp ? start.addingTimeInterval(seconds) : nil,
                receivedAt: start.addingTimeInterval(seconds), personPresent: present, confidence: confidence,
                faceCount: present ? 1 : 0, personCount: present ? 1 : 0)
        }
        func feed(_ gate: inout MeshPresenceGreetingGate, _ time: Double, present: Bool = true) -> UUID? {
            gate.consume(observation(time, present: present), now: start.addingTimeInterval(time))
        }
        var gate = MeshPresenceGreetingGate()
        assert(feed(&gate, 0) == nil, "Unarmed presence must be inert")
        gate.arm(sessionID: id, alreadyGreeted: false, at: start)
        for time in [0.0, 0.6, 1.2, 2.0] { assert(feed(&gate, time) == nil, "Arming in view must not greet") }
        assert(feed(&gate, 3, present: false) == nil)
        assert(feed(&gate, 4, present: false) == nil)
        assert(feed(&gate, 4.5) == nil)
        assert(feed(&gate, 5.1) == nil)
        assert(feed(&gate, 5.8) == id, "An absent-to-present transition should greet once")
        assert(feed(&gate, 6.4) == nil)
        gate.disarm()
        gate.arm(sessionID: id, alreadyGreeted: false, requiresArrival: false, at: start.addingTimeInterval(7))
        for time in [7.0, 7.6, 8.4] { assert(feed(&gate, time) == nil, "Rearm of delivered session must not duplicate") }
        var restored = MeshPresenceGreetingGate()
        restored.arm(sessionID: id, alreadyGreeted: true, requiresArrival: false, at: start)
        for time in [0.0, 0.6, 1.3] { assert(feed(&restored, time) == nil, "Persisted receipt must suppress restart greeting") }

        func armed() -> MeshPresenceGreetingGate {
            var value = MeshPresenceGreetingGate()
            value.arm(sessionID: id, alreadyGreeted: false, requiresArrival: false, at: start)
            return value
        }
        gate = armed()
        for _ in 0..<10 { assert(feed(&gate, 0) == nil, "Duplicate frames must not accumulate dwell") }
        assert(feed(&gate, 0.5) == nil)
        assert(feed(&gate, 1.3) == id)
        gate = armed()
        assert(feed(&gate, 0) == nil)
        assert(feed(&gate, 0.6) == nil)
        assert(feed(&gate, 5) == nil, "A long gap must reset dwell")
        assert(feed(&gate, 5.6) == nil)
        assert(feed(&gate, 6.3) == id)
        gate = armed()
        assert(feed(&gate, 0) == nil)
        assert(feed(&gate, 0.6) == nil)
        assert(gate.consume(observation(1.3, timestamp: false), now: start.addingTimeInterval(1.3)) == nil)
        assert(feed(&gate, 1.4) == nil)
        assert(feed(&gate, 2) == nil)
        assert(feed(&gate, 2.7) == id)
        gate = armed()
        assert(gate.consume(observation(1), now: start.addingTimeInterval(8)) == nil, "Old capture must be rejected")
        assert(gate.consume(observation(20), now: start) == nil, "Future capture must be rejected")
        assert(feed(&gate, -1) == nil, "Pre-arm frame must be rejected")
        gate.disarm()
        assert(feed(&gate, 1) == nil)

        func gaze(time: Date = start, camera: String = "camera", confidence: Double = 0.9,
                  calibrated: Bool = true, x: Double = 0.5) -> MeshNeoCursorObservation {
            MeshNeoCursorObservation(schemaVersion: 1, source: "neocursor", capturedAt: time,
                cameraID: camera, displayID: "display", calibrationID: "calibration", calibrated: calibrated,
                x: x, y: 0.5, confidence: confidence)
        }
        func usable(_ value: MeshNeoCursorObservation) -> Bool {
            value.isUsable(cameraID: "camera", displayID: "display", calibrationID: "calibration", now: start)
        }
        assert(usable(gaze()))
        assert(!usable(gaze(time: start.addingTimeInterval(-2))))
        assert(!usable(gaze(time: start.addingTimeInterval(1))))
        assert(!usable(gaze(camera: "another-camera")))
        assert(!usable(gaze(confidence: 0.4)))
        assert(!usable(gaze(calibrated: false)))
        assert(!usable(gaze(x: .nan)))
        assert(!usable(gaze(x: 2)))

        let validation: [String: Any] = ["kind": "held-out-screen-error", "maxError": 0.10,
            "trainingTargets": 5, "heldOutTargets": 2, "minSamplesPerTarget": 12, "coordinateOrigin": "top-left"]
        let schema2Payload: [String: Any] = ["schemaVersion": 2, "source": "neocursor",
            "capturedAt": start.ISO8601Format(), "cameraID": "camera", "displayID": "display",
            "calibrationID": "calibration", "calibrated": true, "x": 0.4, "y": 0.6, "validation": validation]
        func schema2(_ edit: (inout [String: Any]) -> Void = { _ in }) -> MeshNeoCursorObservation? {
            var payload = schema2Payload; edit(&payload)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let bytes = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return try? decoder.decode(MeshNeoCursorObservation.self, from: bytes)
        }
        let calibrated2 = schema2()!
        assert(usable(calibrated2) && calibrated2.confidence == nil)
        assert(calibrated2.validation?.maxError == 0.10)
        assert(calibrated2.qualityDescription.contains("producer-reported normalized held-out screen error"))
        assert(calibrated2.qualityDescription.contains("not independently verified live"))
        let schema2Evidence = MeshGazeEvidence.descriptions(sharesScreen: true, neoCursor: calibrated2, native: nil, now: start)
        assert(schema2Evidence.count == 1 && !schema2Evidence[0].contains("tracking confidence"))
        assert(MeshGazeEvidence.descriptions(sharesScreen: false, neoCursor: calibrated2, native: nil, now: start).isEmpty)
        assert(MeshGazeEvidence.descriptions(sharesScreen: true, neoCursor: gaze(), native: nil, now: start)[0].contains("tracking confidence"))
        let invalidSchema2: [(inout [String: Any]) -> Void] = [
            { $0.removeValue(forKey: "validation") },
            { $0["validation"] = "not an object" },
            { $0["confidence"] = 0.9 },
            { $0["schemaVersion"] = 3 },
            { $0["source"] = "another tracker" },
            { $0["calibrated"] = false },
            { $0["cameraID"] = "other camera" },
            { $0["displayID"] = "other display" },
            { $0["calibrationID"] = "other calibration" },
            { $0["capturedAt"] = start.addingTimeInterval(-2).ISO8601Format() },
            { $0["capturedAt"] = start.addingTimeInterval(2).ISO8601Format() }
        ]
        for edit in invalidSchema2 {
            if let candidate = schema2(edit) { assert(!usable(candidate), "Invalid v2 identity, freshness or quality accepted") }
        }
        for key in validation.keys {
            let candidate = schema2 { payload in
                var damaged = validation; damaged.removeValue(forKey: key); payload["validation"] = damaged
            }
            assert(candidate == nil, "Every validation field is required")
        }
        let malformedValidation: [[String: Any]] = [
            ["kind": "confidence"], ["maxError": -0.01], ["maxError": 0.151], ["maxError": "0.1"],
            ["trainingTargets": 4], ["heldOutTargets": 1], ["minSamplesPerTarget": 11],
            ["coordinateOrigin": "bottom-left"], ["unexpected": true]
        ]
        for changes in malformedValidation {
            let candidate = schema2 { payload in
                var damaged = validation; damaged.merge(changes) { _, new in new }; payload["validation"] = damaged
            }
            if let candidate { assert(!usable(candidate), "Malformed or insufficient held-out validation accepted") }
        }
        assert(usable(schema2 { payload in var value = validation; value["maxError"] = 0.0; payload["validation"] = value }!))
        assert(usable(schema2 { payload in var value = validation; value["maxError"] = 0.15; payload["validation"] = value }!))
        let nonfinite = MeshNeoCursorObservation(schemaVersion: 2, source: "neocursor", capturedAt: start,
            cameraID: "camera", displayID: "display", calibrationID: "calibration", calibrated: true, x: 0.5, y: 0.5,
            validation: .init(kind: "held-out-screen-error", maxError: .nan, trainingTargets: 5,
                              heldOutTargets: 2, minSamplesPerTarget: 12, coordinateOrigin: "top-left"))
        assert(!usable(nonfinite))
        let missingV1Confidence = MeshNeoCursorObservation(schemaVersion: 1, source: "neocursor", capturedAt: start,
            cameraID: "camera", displayID: "display", calibrationID: "calibration", calibrated: true, x: 0.5, y: 0.5)
        assert(!usable(missingV1Confidence), "Schema 1 still requires its real confidence")

        // The producer owns its camera. Import must not require starting a second camera here.
        let passiveCamera = MeshCameraPresence()
        assert(!passiveCamera.isRunning && passiveCamera.state == .stopped)
        assert(!passiveCamera.importNeoCursor(calibrated2, now: start), "An arbitrary file must not configure its own identity")
        passiveCamera.configureNeoCursor(cameraID: "camera", displayID: "display", calibrationID: "calibration")
        assert(passiveCamera.importNeoCursor(calibrated2, now: start))
        assert(!passiveCamera.isRunning && passiveCamera.state == .stopped && passiveCamera.preview == nil,
               "Explicit identity configuration and observation import never start camera capture")
        assert(passiveCamera.neoCursorObservation == calibrated2)
        assert(passiveCamera.importNeoCursor(calibrated2, now: start.addingTimeInterval(0.5)), "An unchanged fresh latest-value file stays usable")
        assert(!passiveCamera.importNeoCursor(calibrated2, now: start.addingTimeInterval(2)), "Repeated unchanged samples must expire even with room camera stopped")
        assert(passiveCamera.neoCursorObservation == nil)
        passiveCamera.configureNeoCursor(cameraID: "other camera", displayID: "display", calibrationID: "calibration")
        assert(!passiveCamera.importNeoCursor(calibrated2, now: start), "Configured tracker identity must still match")
        passiveCamera.configureNeoCursor(cameraID: "camera", displayID: "display", calibrationID: "calibration")
        assert(passiveCamera.importNeoCursor(calibrated2, now: start))
        passiveCamera.stop()
        assert(passiveCamera.neoCursorObservation == nil && !passiveCamera.isRunning)
        assert(!passiveCamera.importNeoCursor(calibrated2, now: start), "Stop/Pause revokes the independent import configuration")

        // Exercise the actual production routing gate, not a duplicate fixture implementation.
        var selectedDisplay = "calibrated-display"
        let native = MeshNativeGazeObservation(point: CGPoint(x: 0.2, y: 0.8), displayID: selectedDisplay,
                                               capturedAt: start.addingTimeInterval(-0.5))
        selectedDisplay = "another-display"
        let shared = MeshGazeEvidence.descriptions(sharesScreen: true, neoCursor: gaze(), native: native, now: start)
        assert(shared.count == 2, "Screen-sharing can attach both fresh gaze sources")
        assert(shared[1].contains("display calibrated-display"), "Native evidence retains its calibrated physical display")
        assert(!shared[1].contains(selectedDisplay), "Changing the UI picker cannot relabel a calibrated sample")
        assert(shared[1].contains(native.capturedAt.ISO8601Format()), "Use sample capture time, not current preview time")
        assert(MeshGazeEvidence.descriptions(sharesScreen: false, neoCursor: gaze(), native: native, now: start).isEmpty,
               "Off, Room-only, and Control Room do not attach gaze")
        assert(MeshGazeEvidence.descriptions(sharesScreen: true, neoCursor: gaze(time: start.addingTimeInterval(-2)),
                                            native: native, now: start.addingTimeInterval(2)).isEmpty,
               "Previously usable observations must expire before sharing")
        for bad in [
            MeshNativeGazeObservation(point: CGPoint(x: 0.2, y: 0.8), displayID: "", capturedAt: start),
            MeshNativeGazeObservation(point: CGPoint(x: 0.2, y: 0.8), displayID: "display", capturedAt: start.addingTimeInterval(2)),
            MeshNativeGazeObservation(point: CGPoint(x: Double.nan, y: 0.8), displayID: "display", capturedAt: start),
            MeshNativeGazeObservation(point: CGPoint(x: 1.1, y: 0.8), displayID: "display", capturedAt: start)
        ] {
            assert(MeshGazeEvidence.descriptions(sharesScreen: true, neoCursor: nil, native: bad, now: start).isEmpty,
                   "Missing provenance, future time, and invalid coordinates do not become evidence")
        }
        assert(MeshGazeEvidence.descriptions(sharesScreen: true, neoCursor: gaze(calibrated: false), native: nil, now: start).isEmpty)

        let targets = Array(MeshNativeGazeCalibration.targets.prefix(5))
        let raw = targets.map { CGPoint(x: $0.x * 0.5 + 0.2, y: $0.y * 0.3 + 0.3) }
        let fit = MeshNativeGazeCalibration.fit(raw)!
        let holdout = fit.project(CGPoint(x: 0.3 * 0.5 + 0.2, y: 0.5 * 0.3 + 0.3))
        assert(abs(holdout.x - 0.3) < 0.0001 && abs(holdout.y - 0.5) < 0.0001)
        assert(MeshNativeGazeCalibration.fit(Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 5)) == nil)

        let accepted = MeshNativeGazeCalibration.assess(raw)
        assert(accepted.fit != nil && accepted.diagnostic == nil)
        let flat = MeshNativeGazeCalibration.assess(Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 5))
        assert(flat.fit == nil && flat.diagnostic?.outcome == .insufficientVariation)
        assert(flat.diagnostic?.horizontalSpan == 0 && flat.diagnostic?.verticalSpan == 0)
        assert(flat.diagnostic!.minimumPivot! <= 0.00001, "The singularity threshold must remain unchanged")

        // Distinct but collinear samples still cannot separate the two screen axes.
        let collinear = MeshNativeGazeCalibration.assess((0..<5).map { CGPoint(x: 0.2 + Double($0) * 0.1, y: 0.2 + Double($0) * 0.1) })
        assert(collinear.fit == nil && collinear.diagnostic?.outcome == .insufficientVariation)
        assert(collinear.diagnostic!.horizontalSpan! > 0.3 && collinear.diagnostic!.verticalSpan! > 0.3)

        // A full-rank set can fail the fit gate: this must not be diagnosed as flat signals.
        var inconsistent = raw
        inconsistent.swapAt(1, 2)
        let poorFit = MeshNativeGazeCalibration.assess(inconsistent)
        assert(poorFit.fit == nil && poorFit.diagnostic?.outcome == .poorTrainingFit)
        assert(poorFit.diagnostic!.minimumPivot! > 0.00001)
        assert(poorFit.diagnostic!.maximumError! > 0.15, "The fit-error threshold must remain unchanged")
        let invalid = MeshNativeGazeCalibration.assess([CGPoint(x: Double.nan, y: 0)] + Array(raw.dropFirst()))
        assert(invalid.fit == nil && invalid.diagnostic?.outcome == .invalidSamples)
        _ = try JSONEncoder().encode(invalid.diagnostic!)
        assert(MeshNativeGazeCalibration.assess(Array(raw.prefix(4))).diagnostic?.outcome == .invalidSamples)

        // Failure cleanup is exercised on an inert camera object: no device or worker starts.
        let diagnosticCamera = MeshCameraPresence()
        diagnosticCamera.cancelNativeGazeCalibration(preserving: poorFit.diagnostic)
        assert(!diagnosticCamera.isRunning && diagnosticCamera.nativeGazeTarget == nil && diagnosticCamera.nativeGazeObservation == nil)
        assert(diagnosticCamera.nativeGazeCalibrationDiagnostic == poorFit.diagnostic)
        assert(diagnosticCamera.nativeGazeStatus == poorFit.diagnostic!.summary)
        diagnosticCamera.cancelNativeGazeCalibration()
        assert(diagnosticCamera.nativeGazeCalibrationDiagnostic == poorFit.diagnostic, "Closing the failed overlay must preserve its failure branch")
        let savedDiagnostic = try JSONEncoder().encode(diagnosticCamera.nativeGazeCalibrationDiagnostic!)
        let decodedDiagnostic = try JSONDecoder().decode(MeshNativeGazeCalibrationDiagnostic.self, from: savedDiagnostic)
        assert(decodedDiagnostic == poorFit.diagnostic!)
        diagnosticCamera.beginNativeGazeCalibration(displayID: "synthetic-display")
        assert(diagnosticCamera.nativeGazeCalibrationDiagnostic == nil && !diagnosticCamera.isRunning,
               "A new attempt clears stale diagnostics without starting a camera")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("observation.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(gaze()).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let loaded = try MeshNeoCursorFile.read(file)
        assert(loaded.cameraID == "camera")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        do { _ = try MeshNeoCursorFile.read(file); fatalError("World-readable input accepted") } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try MeshNeoCursorFile.read(link); fatalError("Symlink accepted") } catch {}
        try Data(repeating: 65, count: 8_193).write(to: file)
        do { _ = try MeshNeoCursorFile.read(file); fatalError("Oversize input accepted") } catch {}
        try JSONSerialization.data(withJSONObject: schema2Payload).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let imported2 = try MeshNeoCursorFile.read(file)
        assert(imported2.schemaVersion == 2 && usable(imported2) && imported2.confidence == nil,
               "Actual private-file importer accepts the producer's schema 2 JSON")
        print("PASS: sensor-free presence, replay, timing, gaze calibration, schema 1/2 quality validation, screen-sharing gate, immutable display/time provenance, and private-file tests")
    }
}

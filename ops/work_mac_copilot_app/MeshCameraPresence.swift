import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreImage
import Darwin
import Foundation
import ImageIO
@preconcurrency import Vision

struct MeshCameraDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isExternal: Bool
}

enum MeshCameraSource: Equatable, Sendable {
    case native(deviceID: String)
    /// Explicitly configured image endpoint. No endpoint discovery or remote camera activation.
    case snapshot(url: URL)
    /// A parent-owned session with authenticated, identity-checked snapshots only.
    case managedSnapshot(connection: MeshManagedCameraConnection)
}

enum MeshCameraState: String, Sendable { case stopped, starting, running, unavailable }
enum MeshFrameFreshness: String, Sendable { case none, fresh, stale, unverified }

struct MeshPresenceObservation: Equatable, Sendable {
    let capturedAt: Date?
    let receivedAt: Date
    let personPresent: Bool
    let confidence: Double
    let faceCount: Int
    let personCount: Int
}

/// A pure reducer: no sensor, speech, identity, network, calendar, or persistence side effects.
/// The caller persists the emitted session receipt before attempting to speak.
struct MeshPresenceGreetingGate {
    private(set) var sessionID: UUID?
    private(set) var greeted = false
    private var consumedSessions: Set<UUID> = []
    private var armedAt = Date.distantFuture
    private var awaitingArrival = true
    private var absentSince: Date?
    private var presentSince: Date?
    private var lastCapture: Date?
    private var presenceSamples = 0

    mutating func arm(sessionID: UUID, alreadyGreeted: Bool, requiresArrival: Bool = true, at now: Date) {
        if alreadyGreeted { consumedSessions.insert(sessionID) }
        self.sessionID = sessionID
        greeted = consumedSessions.contains(sessionID)
        armedAt = now
        awaitingArrival = requiresArrival
        resetDwell()
    }

    mutating func disarm() {
        sessionID = nil
        resetDwell()
    }

    mutating func resetDwell() {
        absentSince = nil
        presentSince = nil
        presenceSamples = 0
        lastCapture = nil
    }

    mutating func consume(_ observation: MeshPresenceObservation, now: Date) -> UUID? {
        guard let sessionID, !greeted else { return nil }
        guard let capturedAt = observation.capturedAt,
              capturedAt >= armedAt,
              (-0.5...3.0).contains(now.timeIntervalSince(capturedAt)) else {
            resetDwell()
            return nil
        }
        // Duplicate or reordered snapshots never contribute new evidence.
        if let lastCapture, capturedAt <= lastCapture { return nil }
        if let lastCapture, capturedAt.timeIntervalSince(lastCapture) > 3 { resetDwell() }
        lastCapture = capturedAt

        guard observation.personPresent, observation.confidence >= 0.65 else {
            presentSince = nil
            presenceSamples = 0
            if !observation.personPresent {
                if absentSince == nil { absentSince = capturedAt }
                if let absentSince, capturedAt.timeIntervalSince(absentSince) >= 1 {
                    awaitingArrival = false
                }
            } else {
                absentSince = nil
            }
            return nil
        }
        absentSince = nil
        guard !awaitingArrival else { return nil }
        if presentSince == nil { presentSince = capturedAt }
        presenceSamples += 1
        guard let presentSince, presenceSamples >= 3,
              capturedAt.timeIntervalSince(presentSince) >= 1.2 else { return nil }
        greeted = true
        consumedSessions.insert(sessionID)
        return sessionID
    }
}

/// Adapter input, NOT a claim that native Vision presence detection supplies calibrated gaze.
/// Coordinates are normalized to the named display, with (0,0) at its top-left.
struct MeshNeoCursorObservation: Codable, Equatable, Sendable {
    struct Validation: Codable, Equatable, Sendable {
        let kind: String
        let maxError: Double
        let trainingTargets: Int
        let heldOutTargets: Int
        let minSamplesPerTarget: Int
        let coordinateOrigin: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, maxError, trainingTargets, heldOutTargets, minSamplesPerTarget, coordinateOrigin
        }
        private struct AnyKey: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(kind: String, maxError: Double, trainingTargets: Int, heldOutTargets: Int,
             minSamplesPerTarget: Int, coordinateOrigin: String) {
            self.kind = kind; self.maxError = maxError; self.trainingTargets = trainingTargets
            self.heldOutTargets = heldOutTargets; self.minSamplesPerTarget = minSamplesPerTarget
            self.coordinateOrigin = coordinateOrigin
        }
        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: AnyKey.self)
            guard Set(keys.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "NeoCursor validation fields do not match schema 2"))
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(String.self, forKey: .kind)
            maxError = try values.decode(Double.self, forKey: .maxError)
            trainingTargets = try values.decode(Int.self, forKey: .trainingTargets)
            heldOutTargets = try values.decode(Int.self, forKey: .heldOutTargets)
            minSamplesPerTarget = try values.decode(Int.self, forKey: .minSamplesPerTarget)
            coordinateOrigin = try values.decode(String.self, forKey: .coordinateOrigin)
        }
        var isUsable: Bool {
            kind == "held-out-screen-error" && maxError.isFinite && (0...0.15).contains(maxError)
                && trainingTargets == 5 && heldOutTargets == 2 && minSamplesPerTarget == 12
                && coordinateOrigin == "top-left"
        }
    }

    let schemaVersion: Int
    let source: String
    let capturedAt: Date
    let cameraID: String
    let displayID: String
    let calibrationID: String
    let calibrated: Bool
    let x: Double
    let y: Double
    let confidence: Double?
    let validation: Validation?

    init(schemaVersion: Int, source: String, capturedAt: Date, cameraID: String, displayID: String,
         calibrationID: String, calibrated: Bool, x: Double, y: Double,
         confidence: Double? = nil, validation: Validation? = nil) {
        self.schemaVersion = schemaVersion; self.source = source; self.capturedAt = capturedAt
        self.cameraID = cameraID; self.displayID = displayID; self.calibrationID = calibrationID
        self.calibrated = calibrated; self.x = x; self.y = y
        self.confidence = confidence; self.validation = validation
    }

    func isUsable(cameraID: String, displayID: String, calibrationID: String, now: Date) -> Bool {
        guard source == "neocursor", calibrated,
              !cameraID.isEmpty, !displayID.isEmpty, !calibrationID.isEmpty,
              self.cameraID == cameraID, self.displayID == displayID, self.calibrationID == calibrationID,
              x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              (-0.25...1).contains(now.timeIntervalSince(capturedAt)) else { return false }
        switch schemaVersion {
        case 1:
            return confidence.map { $0.isFinite && (0.7...1).contains($0) } == true
        case 2:
            return confidence == nil && validation?.isUsable == true
        default:
            return false
        }
    }

    var qualityDescription: String {
        if schemaVersion == 2, let validation {
            return "producer-reported normalized held-out screen error \(validation.maxError) across \(validation.heldOutTargets) validation targets; not independently verified live and not an attention probability"
        }
        if let confidence { return "producer-reported tracking confidence \(confidence); not an attention probability" }
        return "tracking quality unavailable"
    }
}

/// Immutable provenance belongs to the calibrated sample, not a mutable display picker.
struct MeshNativeGazeObservation: Equatable, Sendable {
    let point: CGPoint
    let displayID: String
    let capturedAt: Date

    func isUsable(now: Date) -> Bool {
        !displayID.isEmpty && point.x.isFinite && point.y.isFinite
            && (0...1).contains(point.x) && (0...1).contains(point.y)
            && (-0.25...1).contains(now.timeIntervalSince(capturedAt))
    }
}

/// The production question builder uses this gate for both gaze sources.
/// Off, Room-only, and Control Room never share either observation.
enum MeshGazeEvidence {
    static func descriptions(sharesScreen: Bool, neoCursor: MeshNeoCursorObservation?,
                             native: MeshNativeGazeObservation?, now: Date) -> [String] {
        guard sharesScreen else { return [] }
        var result: [String] = []
        if let gaze = neoCursor, gaze.isUsable(cameraID: gaze.cameraID, displayID: gaze.displayID,
                                              calibrationID: gaze.calibrationID, now: now) {
            result.append("Calibrated NeoCursor observation on display \(gaze.displayID): normalized \(gaze.x),\(gaze.y), \(gaze.qualityDescription), \(gaze.capturedAt.ISO8601Format()). This is uncertain gaze evidence, not proof of attention; its coordinate space differs from any window crop.")
        }
        if let gaze = native, gaze.isUsable(now: now) {
            result.append("Native calibrated eye estimate, display \(gaze.displayID), normalized x=\(gaze.point.x), y=\(gaze.point.y), captured \(gaze.capturedAt.ISO8601Format()). Experimental native gaze; approximate region only, cursor actions disabled. This estimates a display region; it is not a reliable exact word selection or evidence of understanding.")
        }
        return result
    }
}

struct MeshNativeGazeSample: Sendable {
    let capturedAt: Date
    let point: CGPoint
    let confidence: Double
}

/// A measured failure branch, not a diagnosis of the user's eyes or camera.
struct MeshNativeGazeCalibrationDiagnostic: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case invalidSamples, insufficientVariation, poorTrainingFit, heldOutMiss }
    let outcome: Outcome
    let sampleCount: Int
    let horizontalSpan: Double?
    let verticalSpan: Double?
    let minimumPivot: Double?
    let maximumError: Double?

    var summary: String {
        switch outcome {
        case .invalidSamples:
            return "Calibration could not use the collected eye samples. Start again."
        case .insufficientVariation:
            return "Calibration could not separate horizontal and vertical eye movement across the targets. Keep looking at each target while recording, then retry."
        case .poorTrainingFit:
            return "Calibration points varied, but did not map consistently to the targets. Keep looking at each target while recording, then retry."
        case .heldOutMiss:
            return "Calibration did not pass the check targets. Gaze remains unavailable."
        }
    }
}

/// Small least-squares affine fit. Image-space pupil ratios are not screen gaze until calibrated.
struct MeshNativeGazeCalibration {
    let xCoefficients: [Double]
    let yCoefficients: [Double]
    static let targets = [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                          CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.15, y: 0.85),
                          CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.3, y: 0.5),
                          CGPoint(x: 0.7, y: 0.5)]

    static func fit(_ raw: [CGPoint]) -> MeshNativeGazeCalibration? {
        assess(raw).fit
    }

    static func assess(_ raw: [CGPoint]) -> (fit: MeshNativeGazeCalibration?, diagnostic: MeshNativeGazeCalibrationDiagnostic?) {
        guard raw.count == 5, raw.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return (nil, MeshNativeGazeCalibrationDiagnostic(outcome: .invalidSamples, sampleCount: raw.count,
                horizontalSpan: nil, verticalSpan: nil, minimumPivot: nil, maximumError: nil))
        }
        let horizontalSpan = Double(raw.map(\.x).max()! - raw.map(\.x).min()!)
        let verticalSpan = Double(raw.map(\.y).max()! - raw.map(\.y).min()!)
        var minimumPivot = Double.infinity
        func failure(_ outcome: MeshNativeGazeCalibrationDiagnostic.Outcome, error: Double? = nil)
            -> (fit: MeshNativeGazeCalibration?, diagnostic: MeshNativeGazeCalibrationDiagnostic?) {
            (nil, MeshNativeGazeCalibrationDiagnostic(outcome: outcome, sampleCount: raw.count,
                horizontalSpan: horizontalSpan.isFinite ? horizontalSpan : nil,
                verticalSpan: verticalSpan.isFinite ? verticalSpan : nil,
                minimumPivot: minimumPivot.isFinite ? minimumPivot : nil,
                maximumError: error.flatMap { $0.isFinite ? $0 : nil }))
        }
        let rows = raw.map { [Double($0.x), Double($0.y), 1] }
        var matrix = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for row in rows { for i in 0..<3 { for j in 0..<3 { matrix[i][j] += row[i] * row[j] } } }
        func solve(_ values: [Double]) -> [Double]? {
            var augmented = (0..<3).map { i in matrix[i] + [zip(rows, values).reduce(0) { $0 + $1.0[i] * $1.1 }] }
            for column in 0..<3 {
                let pivot = (column..<3).max { abs(augmented[$0][column]) < abs(augmented[$1][column]) }!
                minimumPivot = min(minimumPivot, abs(augmented[pivot][column]))
                guard abs(augmented[pivot][column]) > 0.00001 else { return nil }
                augmented.swapAt(column, pivot)
                let scale = augmented[column][column]
                for j in column..<4 { augmented[column][j] /= scale }
                for i in 0..<3 where i != column {
                    let factor = augmented[i][column]
                    for j in column..<4 { augmented[i][j] -= factor * augmented[column][j] }
                }
            }
            return augmented.map { $0[3] }
        }
        guard let x = solve(targets.prefix(5).map { Double($0.x) }),
              let y = solve(targets.prefix(5).map { Double($0.y) }) else { return failure(.insufficientVariation) }
        let fit = MeshNativeGazeCalibration(xCoefficients: x, yCoefficients: y)
        let error = zip(raw, targets).map { sample, target in
            let point = fit.project(sample)
            return hypot(point.x - target.x, point.y - target.y)
        }.max() ?? 1
        guard error.isFinite, error <= 0.15 else { return failure(.poorTrainingFit, error: error) }
        return (fit, nil)
    }

    func project(_ point: CGPoint) -> CGPoint {
        CGPoint(x: xCoefficients[0] * point.x + xCoefficients[1] * point.y + xCoefficients[2],
                y: yCoefficients[0] * point.x + yCoefficients[1] * point.y + yCoefficients[2])
    }
}

/// Creating this object is inert. Only explicit start(source:) accesses a selected source.
/// Camera permission is checked, never requested here. Native and M1 frames stay in memory.
@MainActor
final class MeshCameraPresence: ObservableObject {
    @Published private(set) var state: MeshCameraState = .stopped
    @Published private(set) var detail = "Camera stopped"
    @Published private(set) var source: MeshCameraSource?
    @Published private(set) var preview: NSImage?
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var lastReceivedAt: Date?
    @Published private(set) var freshness: MeshFrameFreshness = .none
    @Published private(set) var presence: MeshPresenceObservation?
    @Published private(set) var isRunning = false
    @Published private(set) var isArmed = false
    @Published private(set) var hasGreeted = false
    @Published private(set) var neoCursorObservation: MeshNeoCursorObservation?
    @Published private(set) var neoCursorStatus = "Unavailable — no calibrated NeoCursor adapter connected"
    @Published private(set) var nativeGazeTarget: CGPoint?
    @Published private(set) var nativeGazeCalibrationStep = 0
    @Published private(set) var nativeGazeStatus = "Native gaze unavailable — camera and attended calibration required"
    @Published private(set) var nativeGazeCalibrationDiagnostic: MeshNativeGazeCalibrationDiagnostic?
    @Published private(set) var nativeGazeObservation: MeshNativeGazeObservation?
    var nativeGazePoint: CGPoint? { nativeGazeObservation?.point }
    @Published private(set) var rawGazeAvailable = false

    var onGreetingRequested: ((UUID) -> Void)?
    var onManagedFrame: ((MeshManagedCameraIdentity, Date) -> Void)?
    var onManagedFailure: ((MeshManagedCameraIdentity) -> Void)?
    private var worker: MeshCameraWorker?
    private var generation = UUID()
    private var gate = MeshPresenceGreetingGate()
    private var freshnessTimer: Timer?
    private var startedAt: Date?
    private var gazeContext: (cameraID: String, displayID: String, calibrationID: String)?
    private var neoCursorReader: MeshNeoCursorFileReader?
    private var neoCursorGeneration = UUID()
    private var gazeSamples: [MeshNativeGazeSample] = []
    private var gazeTrainingPoints: [CGPoint] = []
    private var nativeGazeFit: MeshNativeGazeCalibration?
    private var nativeGazeDisplayID: String?
    private var gazeStepStartedAt = Date.distantFuture
    private var nativeGazeValidated = false

    static func availableDevices() -> [MeshCameraDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices.map {
            MeshCameraDevice(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external)
        }
    }

    func start(source: MeshCameraSource) {
        stop()
        self.source = source
        switch source {
        case let .native(deviceID):
            guard !deviceID.isEmpty else { fail("Select a specific camera first"); return }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                fail("Camera permission is not granted. Enable it in System Settings, then start again.")
                return
            }
            guard Self.availableDevices().contains(where: { $0.id == deviceID }) else {
                fail("The selected camera is unavailable. No substitute camera was opened.")
                return
            }
        case let .snapshot(url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil,
                  url.fragment == nil else {
                fail("Enter an explicit HTTP(S) image endpoint without embedded credentials or a fragment.")
                return
            }
        case .managedSnapshot:
            break // Construction already validates the pinned identity and explicit loopback URL.
        }
        let run = generation
        isRunning = true
        state = .starting
        detail = "Waiting for the selected camera"
        startedAt = Date()
        let worker = MeshCameraWorker(source: source, onFrame: { [weak self] frame in
            Task { @MainActor in
                guard let self, self.generation == run, self.isRunning else { return }
                self.accept(frame)
            }
        }, onError: { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == run, self.isRunning else { return }
                if case .managedSnapshot = self.source { self.failManagedFrame(message); return }
                self.gate.resetDwell()
                self.state = .unavailable
                self.detail = message
            }
        })
        self.worker = worker
        worker.start()
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFreshness(now: Date()) }
        }
    }

    /// Clears frames immediately and rejects already queued results from the previous generation.
    /// The worker closes the capture session / network session on its serial queue.
    func stop() {
        generation = UUID()
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        worker?.stop()
        worker = nil
        if case .managedSnapshot = source { source = nil }
        isRunning = false
        state = .stopped
        detail = "Camera stopped"
        preview = nil
        presence = nil
        lastFrameAt = nil
        lastReceivedAt = nil
        freshness = .none
        startedAt = nil
        stopNeoCursorImport()
        cancelNativeGazeCalibration()
        disarm()
    }

    /// Parent owns date selection, durable pause, and the persisted receipt across app restarts.
    /// Starting a source disarms; arm only after the selected source has started.
    func arm(sessionID: UUID, alreadyGreeted: Bool = false, requiresArrival: Bool = true) {
        guard isRunning else { return }
        gate.arm(sessionID: sessionID, alreadyGreeted: alreadyGreeted, requiresArrival: requiresArrival, at: Date())
        isArmed = true
        hasGreeted = gate.greeted
    }

    func disarm() {
        gate.disarm()
        isArmed = false
    }

    func beginNativeGazeCalibration(displayID: String) {
        nativeGazeCalibrationDiagnostic = nil
        cancelNativeGazeCalibration()
        guard isRunning, !displayID.isEmpty else { return }
        nativeGazeDisplayID = displayID
        nativeGazeCalibrationStep = 0
        nativeGazeTarget = MeshNativeGazeCalibration.targets[0]
        gazeStepStartedAt = Date()
        nativeGazeStatus = "Look at dot 1 of 7 for two seconds, then press Space while still looking at the dot. Keep your head still."
    }

    /// The caller must draw the target on the named physical display, not inside a scaled preview.
    @discardableResult
    func recordNativeGazeTarget() -> Bool {
        guard nativeGazeTarget != nil, nativeGazeDisplayID != nil else { return false }
        let now = Date()
        let samples = gazeSamples.filter {
            $0.capturedAt >= gazeStepStartedAt && (-0.25...4).contains(now.timeIntervalSince($0.capturedAt))
                && $0.confidence >= 0.75
        }
        guard samples.count >= 4, let first = samples.first, let last = samples.last,
              last.capturedAt.timeIntervalSince(first.capturedAt) >= 1.2,
              now.timeIntervalSince(last.capturedAt) <= 1.0 else {
            nativeGazeStatus = "Need two seconds of fresh, visible pupil landmarks at this target"
            return false
        }
        let xs = samples.map { $0.point.x }.sorted(), ys = samples.map { $0.point.y }.sorted()
        guard (xs.last! - xs.first!) <= 0.18, (ys.last! - ys.first!) <= 0.18 else {
            nativeGazeStatus = "Eye position was unstable; hold the target and retry"
            return false
        }
        let point = CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
        if nativeGazeCalibrationStep < 5 {
            gazeTrainingPoints.append(point)
            if gazeTrainingPoints.count == 5 {
                let assessment = MeshNativeGazeCalibration.assess(gazeTrainingPoints)
                guard let fit = assessment.fit else {
                    cancelNativeGazeCalibration(preserving: assessment.diagnostic)
                    return false
                }
                nativeGazeFit = fit
            }
        } else {
            guard let fit = nativeGazeFit, let target = nativeGazeTarget else { return false }
            let predicted = fit.project(point)
            let error = hypot(predicted.x - target.x, predicted.y - target.y)
            guard error.isFinite, error <= 0.15 else {
                cancelNativeGazeCalibration(preserving: MeshNativeGazeCalibrationDiagnostic(outcome: .heldOutMiss,
                    sampleCount: samples.count, horizontalSpan: Double(xs.last! - xs.first!), verticalSpan: Double(ys.last! - ys.first!),
                    minimumPivot: nil, maximumError: error.isFinite ? Double(error) : nil))
                return false
            }
        }
        nativeGazeCalibrationStep += 1
        gazeSamples.removeAll()
        gazeStepStartedAt = now
        if nativeGazeCalibrationStep < MeshNativeGazeCalibration.targets.count {
            nativeGazeTarget = MeshNativeGazeCalibration.targets[nativeGazeCalibrationStep]
            nativeGazeStatus = "Look at dot \(nativeGazeCalibrationStep + 1) of 7 for two seconds, then press Space while still looking at the dot"
        } else {
            nativeGazeValidated = true
            nativeGazeTarget = nil
            nativeGazeStatus = "Experimental native gaze calibrated; approximate region only, cursor actions disabled"
        }
        return true
    }

    func cancelNativeGazeCalibration(preserving diagnostic: MeshNativeGazeCalibrationDiagnostic? = nil) {
        if let diagnostic { nativeGazeCalibrationDiagnostic = diagnostic }
        gazeSamples.removeAll()
        gazeTrainingPoints.removeAll()
        nativeGazeFit = nil
        nativeGazeValidated = false
        nativeGazeDisplayID = nil
        nativeGazeTarget = nil
        nativeGazeObservation = nil
        rawGazeAvailable = false
        nativeGazeCalibrationStep = 0
        nativeGazeStatus = nativeGazeCalibrationDiagnostic?.summary ?? "Native gaze unavailable — camera and attended calibration required"
    }

    /// Explicit tracker identity selection is independent of Monitor room-camera capture.
    func configureNeoCursor(cameraID: String, displayID: String, calibrationID: String) {
        neoCursorObservation = nil
        guard !cameraID.isEmpty, !displayID.isEmpty, !calibrationID.isEmpty else {
            gazeContext = nil
            neoCursorStatus = "Unavailable — select and calibrate the intended camera and display"
            return
        }
        gazeContext = (cameraID, displayID, calibrationID)
        neoCursorStatus = "Waiting for calibrated NeoCursor observations"
    }

    /// Explicit import of an adapter's atomically replaced, owner-private latest-observation file.
    /// This does not launch NeoCursor, capture a camera, or move the pointer.
    func startNeoCursorImport(fileURL: URL, cameraID: String, displayID: String, calibrationID: String) {
        stopNeoCursorImport()
        configureNeoCursor(cameraID: cameraID, displayID: displayID, calibrationID: calibrationID)
        guard gazeContext != nil, fileURL.isFileURL else {
            neoCursorStatus = "Unavailable — choose a local observation file and calibrated camera/display"
            return
        }
        let run = neoCursorGeneration
        let reader = MeshNeoCursorFileReader(url: fileURL) { [weak self] result in
            Task { @MainActor in
                guard let self, self.neoCursorGeneration == run, self.gazeContext != nil else { return }
                switch result {
                case let .success(observation):
                    // Recheck identical frames too: freshness must expire without a room camera timer.
                    self.importNeoCursor(observation)
                case let .failure(error):
                    self.neoCursorObservation = nil
                    self.neoCursorStatus = error.localizedDescription
                }
            }
        }
        neoCursorReader = reader
        reader.start()
    }

    func stopNeoCursorImport() {
        neoCursorGeneration = UUID()
        neoCursorReader?.stop()
        neoCursorReader = nil
        gazeContext = nil
        neoCursorObservation = nil
        neoCursorStatus = "Unavailable — no calibrated NeoCursor adapter connected"
    }

    @discardableResult
    func importNeoCursor(_ observation: MeshNeoCursorObservation, now: Date = Date()) -> Bool {
        guard let context = gazeContext,
              observation.isUsable(cameraID: context.cameraID, displayID: context.displayID,
                                   calibrationID: context.calibrationID, now: now),
              neoCursorObservation.map({ observation.capturedAt > $0.capturedAt || observation == $0 }) ?? true else {
            neoCursorObservation = nil
            neoCursorStatus = "Unavailable — observation is stale, uncalibrated, or belongs to another setup"
            return false
        }
        if neoCursorObservation == observation { return true }
        neoCursorObservation = observation
        neoCursorStatus = "Calibrated observation imported · \(observation.qualityDescription) · cursor actions disabled"
        return true
    }

    private func fail(_ message: String) {
        state = .unavailable
        detail = message
    }

    private func accept(_ frame: MeshCameraFrame) {
        let acceptedGeneration = generation
        // The main actor may have been delayed after worker decode/analysis. Never publish a
        // managed frame that expired while queued, or a repeated/rewound capture timestamp.
        if case .managedSnapshot = source {
            guard let timestamp = frame.observation.capturedAt else {
                failManagedFrame(MeshManagedCameraError.invalidTimestamp.localizedDescription); return
            }
            do { try MeshManagedCameraConnection.verifyFreshness(capturedAt: timestamp, now: Date(), after: lastFrameAt) }
            catch {
                failManagedFrame(error.localizedDescription)
                return
            }
        }
        preview = NSImage(cgImage: frame.image, size: .zero)
        presence = frame.observation
        lastFrameAt = frame.observation.capturedAt
        lastReceivedAt = frame.observation.receivedAt
        state = .running
        detail = "Local presence detection; no identity or emotion inference"
        refreshFreshness(now: Date())
        guard generation == acceptedGeneration, isRunning else { return }
        acceptNativeGaze(frame.gaze, now: Date())
        if case let .managedSnapshot(connection) = source, let timestamp = frame.observation.capturedAt {
            onManagedFrame?(connection.identity, timestamp)
        }
        guard generation == acceptedGeneration, isRunning else { return }
        if let session = gate.consume(frame.observation, now: Date()) {
            hasGreeted = true
            onGreetingRequested?(session)
        }
    }

    private func failManagedFrame(_ message: String) {
        guard case let .managedSnapshot(connection) = source else { return }
        // Stop our input first even if the owner has not installed a callback. Its generation
        // changes synchronously; in-flight work can no longer publish or invoke callbacks.
        stop()
        state = .unavailable; detail = message
        onManagedFailure?(connection.identity)
    }

    private func acceptNativeGaze(_ sample: MeshNativeGazeSample?, now: Date) {
        guard let sample, (-0.25...1).contains(now.timeIntervalSince(sample.capturedAt)), sample.confidence >= 0.75 else {
            rawGazeAvailable = false
            nativeGazeObservation = nil
            if nativeGazeValidated { nativeGazeStatus = "Native gaze unavailable — fresh pupil landmarks not detected" }
            return
        }
        rawGazeAvailable = true
        if gazeSamples.last.map({ sample.capturedAt > $0.capturedAt }) ?? true {
            gazeSamples.append(sample)
            if gazeSamples.count > 12 { gazeSamples.removeFirst(gazeSamples.count - 12) }
        }
        if nativeGazeValidated, let fit = nativeGazeFit, let displayID = nativeGazeDisplayID {
            let point = fit.project(sample.point)
            if (0...1).contains(point.x), (0...1).contains(point.y) {
                nativeGazeObservation = MeshNativeGazeObservation(point: point, displayID: displayID, capturedAt: sample.capturedAt)
                nativeGazeStatus = "Experimental native gaze; approximate region only, cursor actions disabled"
            } else {
                nativeGazeObservation = nil
                nativeGazeStatus = "Gaze is outside the calibrated display; recalibrate if camera or posture changed"
            }
        }
    }

    private func refreshFreshness(now: Date) {
        guard isRunning else { return }
        if let lastFrameAt {
            freshness = (-0.5...3).contains(now.timeIntervalSince(lastFrameAt)) ? .fresh : .stale
        } else {
            freshness = lastReceivedAt == nil ? .none : .unverified
        }
        if freshness == .stale || lastReceivedAt.map({ now.timeIntervalSince($0) > 5 }) == true {
            freshness = .stale
            state = .unavailable
            detail = "Camera frame is stale; morning trigger suspended"
            gate.resetDwell()
            rawGazeAvailable = false
            nativeGazeObservation = nil
            if case .managedSnapshot = source { failManagedFrame(detail); return }
        } else if freshness == .unverified {
            detail = "Preview only: missing source capture timestamp; morning trigger suspended"
        } else if lastReceivedAt == nil, let startedAt, now.timeIntervalSince(startedAt) > 8 {
            state = .unavailable
            detail = "No camera frame received; morning trigger suspended"
            if case .managedSnapshot = source { failManagedFrame(detail); return }
        }
        if let observation = neoCursorObservation,
           !(-0.25...1).contains(now.timeIntervalSince(observation.capturedAt)) {
            neoCursorObservation = nil
            neoCursorStatus = "Unavailable — calibrated NeoCursor observation expired"
        }
    }
}

enum MeshNeoCursorImportError: Error, LocalizedError {
    case unavailable, unsafeFile, malformed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Unavailable — NeoCursor observation file is missing or unreadable"
        case .unsafeFile: "Unavailable — use an owner-private regular file (not a symlink or FIFO), at most 8 KiB"
        case .malformed: "Unavailable — NeoCursor observation does not match the supported schema"
        }
    }
}

/// Reads only an explicit latest-value file. It must never attach to the M1 control FIFO:
/// a second FIFO consumer would steal input from the existing accessibility runtime.
enum MeshNeoCursorFile {
    static func read(_ url: URL) throws -> MeshNeoCursorObservation {
        guard url.isFileURL else { throw MeshNeoCursorImportError.unsafeFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw MeshNeoCursorImportError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0, metadata.st_size <= 8_192 else {
            throw MeshNeoCursorImportError.unsafeFile
        }
        guard let data = try handle.read(upToCount: 8_193), data.count <= 8_192 else {
            throw MeshNeoCursorImportError.unsafeFile
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let text = try container.decode(String.self)
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: text) { return date }
            parser.formatOptions = [.withInternetDateTime]
            guard let date = parser.date(from: text) else { throw MeshNeoCursorImportError.malformed }
            return date
        }
        do { return try decoder.decode(MeshNeoCursorObservation.self, from: data) }
        catch { throw MeshNeoCursorImportError.malformed }
    }
}

private final class MeshNeoCursorFileReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mesh.monitor.neocursor-import", qos: .utility)
    private let url: URL
    private let callback: @Sendable (Result<MeshNeoCursorObservation, Error>) -> Void
    private var timer: DispatchSourceTimer?

    init(url: URL, callback: @escaping @Sendable (Result<MeshNeoCursorObservation, Error>) -> Void) {
        self.url = url
        self.callback = callback
    }
    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.callback(Result { try MeshNeoCursorFile.read(self.url) })
            }
            self.timer = timer
            timer.resume()
        }
    }
    func stop() {
        queue.async { [self] in timer?.cancel(); timer = nil }
    }
}

private struct MeshCameraFrame: @unchecked Sendable {
    let image: CGImage
    let observation: MeshPresenceObservation
    let gaze: MeshNativeGazeSample?
}

/// All AVFoundation, Vision, HTTP, and mutable worker state is confined to queue.
/// No microphone capture, disk output, image upload, or device default selection exists here.
private final class MeshCameraWorker: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate, URLSessionDataDelegate {
    private let source: MeshCameraSource
    private let onFrame: @Sendable (MeshCameraFrame) -> Void
    private let onError: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "mesh.monitor.camera", qos: .utility)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var running = false
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var runtimeObserver: NSObjectProtocol?
    private var networkSession: URLSession?
    private var snapshotTimer: DispatchSourceTimer?
    private var requestTask: URLSessionDataTask?
    private var responseData = Data()
    private var responseCapturedAt: Date?
    private var responseFailure: String?
    private var managedResponse: HTTPURLResponse?
    private var lastManagedCaptureAt: Date?
    private var lastNativeFrame = Date.distantPast
    private let maxImageBytes = 4 * 1_024 * 1_024

    init(source: MeshCameraSource, onFrame: @escaping @Sendable (MeshCameraFrame) -> Void,
         onError: @escaping @Sendable (String) -> Void) {
        self.source = source
        self.onFrame = onFrame
        self.onError = onError
        super.init()
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            switch source {
            case let .native(deviceID): startNative(deviceID: deviceID)
            case let .snapshot(url): startSnapshots(url: url)
            case let .managedSnapshot(connection): startSnapshots(url: connection.snapshotURL)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            captureSession?.stopRunning()
            captureSession = nil
            videoOutput = nil
            if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
            runtimeObserver = nil
            snapshotTimer?.cancel()
            snapshotTimer = nil
            requestTask?.cancel()
            requestTask = nil
            networkSession?.invalidateAndCancel()
            networkSession = nil
            responseData.removeAll(keepingCapacity: false)
            managedResponse = nil
        }
    }

    private func startNative(deviceID: String) {
        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices.first(where: { $0.uniqueID == deviceID }) else {
            onError("The selected camera disconnected. No substitute camera was opened.")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            let output = AVCaptureVideoDataOutput()
            session.beginConfiguration()
            if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                onError("The selected camera cannot provide video frames")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: queue)
            session.commitConfiguration()
            captureSession = session
            videoOutput = output
            runtimeObserver = NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [self] in
                    if self.running { self.onError("Camera capture failed; stop and reselect the camera") }
                }
            }
            session.startRunning()
            if !session.isRunning { onError("The selected camera did not start") }
        } catch {
            onError("The selected camera cannot be opened; check its connection and permission")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running else { return }
        let receivedAt = Date()
        guard receivedAt.timeIntervalSince(lastNativeFrame) >= 0.5,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastNativeFrame = receivedAt
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = imageContext.createCGImage(input, from: input.extent) else {
            onError("Camera frame could not be decoded")
            return
        }
        var capturedAt: Date?
        if let clock = captureSession?.synchronizationClock {
            let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(clock), CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
            if age.isFinite, age >= -0.5 { capturedAt = receivedAt.addingTimeInterval(-age) }
        }
        // A queued sample must retain its capture age instead of acquiring a new arrival timestamp.
        analyze(image: image, capturedAt: capturedAt, receivedAt: receivedAt)
    }

    private func startSnapshots(url: URL) {
        let managed: Bool
        if case .managedSnapshot = source { managed = true } else { managed = false }
        let configuration = MeshManagedCameraConnection.sessionConfiguration(managed: managed)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        networkSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.requestSnapshot(url: url) }
        snapshotTimer = timer
        timer.resume()
    }

    private func requestSnapshot(url: URL) {
        guard running, requestTask == nil else { return }
        responseData.removeAll(keepingCapacity: false)
        responseFailure = nil
        responseCapturedAt = nil
        managedResponse = nil
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("image/jpeg, image/png", forHTTPHeaderField: "Accept")
        if case let .managedSnapshot(connection) = source { request = connection.snapshotRequest() }
        requestTask = networkSession?.dataTask(with: request)
        requestTask?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if case .managedSnapshot = source { completionHandler(.cancelAuthenticationChallenge, nil) }
        else { completionHandler(.performDefaultHandling, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        responseFailure = "Snapshot redirect rejected; configure the final image endpoint explicitly"
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if case let .managedSnapshot(connection) = source {
            guard running, requestTask === dataTask, let http = response as? HTTPURLResponse else {
                completionHandler(.cancel); return
            }
            do {
                responseCapturedAt = try connection.verifySnapshot(response: http, now: Date(), after: lastManagedCaptureAt)
                managedResponse = http
                completionHandler(.allow)
            } catch {
                responseFailure = error.localizedDescription
                completionHandler(.cancel)
            }
            return
        }
        guard running, requestTask === dataTask, let http = response as? HTTPURLResponse,
              http.statusCode == 200, ["image/jpeg", "image/png"].contains(http.mimeType ?? ""),
              http.expectedContentLength <= Int64(maxImageBytes) else {
            responseFailure = responseFailure ?? "Snapshot unavailable or not a supported bounded image"
            completionHandler(.cancel)
            return
        }
        // Arrival time is NOT proof of a fresh remote frame. Missing header allows preview only.
        if let text = http.value(forHTTPHeaderField: "X-Mesh-Captured-At") {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            responseCapturedAt = parser.date(from: text)
            if responseCapturedAt == nil {
                parser.formatOptions = [.withInternetDateTime]
                responseCapturedAt = parser.date(from: text)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard running, requestTask === dataTask else { return }
        guard responseData.count + data.count <= maxImageBytes else {
            responseFailure = "Snapshot exceeded the 4 MiB limit"
            dataTask.cancel()
            return
        }
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard running, requestTask === task else { return }
        requestTask = nil
        defer { responseData.removeAll(keepingCapacity: false) }
        guard error == nil, responseFailure == nil else {
            onError(responseFailure ?? "M1 image endpoint is unavailable; no new camera frame received")
            return
        }
        if case let .managedSnapshot(connection) = source {
            do {
                guard let response = managedResponse else { throw MeshManagedCameraError.invalidResponse }
                let frame = try connection.decodeSnapshot(data: responseData, response: response, after: lastManagedCaptureAt)
                analyze(image: frame.image, capturedAt: frame.capturedAt, receivedAt: Date())
            } catch { onError(error.localizedDescription) }
            managedResponse = nil
            return
        }
        guard let source = CGImageSourceCreateWithData(responseData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= 32_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 960
              ] as CFDictionary) else {
            onError("M1 snapshot could not be decoded within image limits")
            return
        }
        analyze(image: image, capturedAt: responseCapturedAt, receivedAt: Date())
    }

    private func analyze(image: CGImage, capturedAt: Date?, receivedAt: Date) {
        guard running else { return }
        let faces = VNDetectFaceLandmarksRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([faces, people])
            let faceResults = faces.results ?? []
            let personResults = people.results ?? []
            let confidence = max(faceResults.map(\.confidence).max() ?? 0, personResults.map(\.confidence).max() ?? 0)
            let observation = MeshPresenceObservation(
                capturedAt: capturedAt, receivedAt: receivedAt, personPresent: confidence >= 0.5,
                confidence: Double(confidence), faceCount: faceResults.count, personCount: personResults.count
            )
            let gaze = capturedAt.flatMap { timestamp in
                // Multiple faces cannot establish whose eyes refer to the selected display.
                faceResults.count == 1 ? eyeSample(faceResults[0], capturedAt: timestamp) : nil
            }
            if case .managedSnapshot = source {
                guard let capturedAt else { throw MeshManagedCameraError.invalidTimestamp }
                try MeshManagedCameraConnection.verifyFreshness(capturedAt: capturedAt, now: Date(), after: lastManagedCaptureAt)
                lastManagedCaptureAt = capturedAt
            }
            onFrame(MeshCameraFrame(image: image, observation: observation, gaze: gaze))
        } catch let error as MeshManagedCameraError {
            onError(error.localizedDescription)
        } catch {
            onError("Local presence analysis failed; morning trigger suspended")
        }
    }

    private func eyeSample(_ face: VNFaceObservation, capturedAt: Date) -> MeshNativeGazeSample? {
        guard face.confidence >= 0.75, let landmarks = face.landmarks else { return nil }
        func ratio(eye: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let eye, let pupil, eye.pointCount >= 4, pupil.pointCount >= 1 else { return nil }
            let eyePoints = eye.normalizedPoints
            let pupilPoints = pupil.normalizedPoints
            let loX = eyePoints.map(\.x).min()!, hiX = eyePoints.map(\.x).max()!
            let loY = eyePoints.map(\.y).min()!, hiY = eyePoints.map(\.y).max()!
            guard hiX - loX > 0.005, hiY - loY > 0.003 else { return nil }
            let center = pupilPoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let x = (center.x / CGFloat(pupil.pointCount) - loX) / (hiX - loX)
            let y = (center.y / CGFloat(pupil.pointCount) - loY) / (hiY - loY)
            guard (0...1).contains(x), (0...1).contains(y) else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard let left = ratio(eye: landmarks.leftEye, pupil: landmarks.leftPupil),
              let right = ratio(eye: landmarks.rightEye, pupil: landmarks.rightPupil) else { return nil }
        return MeshNativeGazeSample(capturedAt: capturedAt,
            point: CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2), confidence: Double(face.confidence))
    }
}

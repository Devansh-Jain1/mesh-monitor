import Combine
import CryptoKit
import Darwin
import Foundation

struct MeshNeoCursorRuntimeConfiguration: Decodable, Sendable {
    let schema: String
    let electronExecutable: String
    let electronVersion: String
    let overlayDirectory: String
    let overlayManifestSHA256: String
    let electronExecutableSHA256: String
}

enum MeshNeoCursorRuntimeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case let .invalid(reason) = self { return "NeoCursor setup unavailable: \(reason)" }; return nil
    }
}

/// Validates only local bytes. No executable, model, permission, or sensor is started.
enum MeshNeoCursorRuntimeFiles {
    static let upstreamPin = "986db45663cf37b6e47e5e355fa1e9ce0d05de76"
    static let glue = ["observer-main.cjs", "observer-preload.cjs", "observer-renderer.js", "observer.html", "calibration.cjs", "publisher.cjs"]
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func require(_ value: Bool, _ reason: String) throws {
        guard value else { throw MeshNeoCursorRuntimeError.invalid(reason) }
    }
    static func supportedVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]), let minor = Int(components[1]), Int(components[2]) != nil else { return false }
        return major == 41 && minor >= 4
    }
    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
    }
    private static func openDirectory(_ path: String, privateOwner: Bool = false) throws -> Int32 {
        try require(path.hasPrefix("/") && !path.contains("\0"), "use absolute local paths")
        let components = path.split(separator: "/")
        try require(!components.contains("..") && !components.contains("."), "relative path components are not allowed")
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try require(descriptor >= 0, "path cannot be opened")
        do {
            for component in components {
                let next = Darwin.openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(next >= 0, "directory is missing or contains a symbolic link")
                Darwin.close(descriptor); descriptor = next
            }
            var metadata = stat()
            try require(fstat(descriptor, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR,
                        "expected a directory")
            if privateOwner {
                try require(metadata.st_uid == getuid() && metadata.st_mode & 0o777 == 0o700,
                            "configuration folder must be owner-private (0700)")
            } else {
                try require(metadata.st_mode & 0o022 == 0, "directory must not allow group or public writes")
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    static func read(_ url: URL, limit: Int, privateOwner: Bool = false, executable: Bool = false) throws -> Data {
        try Task.checkCancellation()
        try require(url.isFileURL && !url.lastPathComponent.isEmpty, "expected a local file")
        let parent = try openDirectory(url.deletingLastPathComponent().path, privateOwner: privateOwner)
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(descriptor >= 0, "file is missing or is a symbolic link")
        defer { Darwin.close(descriptor) }
        var before = stat()
        try require(fstat(descriptor, &before) == 0 && before.st_mode & S_IFMT == S_IFREG && before.st_nlink == 1,
                    "expected a regular single-link file")
        try require(before.st_uid == getuid() || (!privateOwner && before.st_uid == 0), "unexpected file owner")
        try require(before.st_size >= 0 && before.st_size <= limit, "file exceeds its size limit")
        try require(privateOwner ? before.st_mode & 0o777 == 0o600 : before.st_mode & 0o022 == 0,
                    "unsafe file permissions")
        if executable { try require(before.st_mode & 0o111 != 0, "Electron is not executable") }
        var result = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            try require(count > 0 && result.count + count <= limit, "file read failed or exceeded its limit")
            result.append(contentsOf: chunk.prefix(count))
        }
        var after = stat()
        try require(fstat(descriptor, &after) == 0 && after.st_size == before.st_size && after.st_ino == before.st_ino
                    && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                    "file changed during validation")
        return result
    }
    static func validate(configurationURL: URL, expectedAssetsDirectory: URL) throws -> MeshNeoCursorRuntimeConfiguration {
        let raw = try read(configurationURL, limit: 16_384, privateOwner: true)
        let configuration: MeshNeoCursorRuntimeConfiguration
        do { configuration = try JSONDecoder().decode(MeshNeoCursorRuntimeConfiguration.self, from: raw) }
        catch { throw MeshNeoCursorRuntimeError.invalid("configuration JSON is invalid") }
        try require(configuration.schema == "mesh.neocursor-runtime.v1", "configuration schema is unsupported")
        try require(supportedVersion(configuration.electronVersion), "Electron 41.4 or later within 41.x is required")
        try require(validHash(configuration.overlayManifestSHA256) && validHash(configuration.electronExecutableSHA256), "invalid pinned SHA256")
        try require(configuration.overlayDirectory.hasPrefix("/") && configuration.electronExecutable.hasPrefix("/"), "runtime paths must be absolute")
        let overlay = URL(fileURLWithPath: configuration.overlayDirectory, isDirectory: true)
        let manifestBytes = try read(overlay.appendingPathComponent("manifest.json"), limit: 65_536)
        let ready = try read(overlay.appendingPathComponent("READY"), limit: 128)
        try require(sha(manifestBytes) == configuration.overlayManifestSHA256
            && String(data: ready, encoding: .utf8) == configuration.overlayManifestSHA256 + "\n", "overlay manifest or READY differs from the pinned setup")
        guard let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              manifest["schema"] as? Int == 1, manifest["mode"] as? String == "observation-only",
              let upstream = manifest["upstream"] as? [String: Any], upstream["commit"] as? String == upstreamPin,
              let overlayManifest = manifest["overlay"] as? [String: Any], overlayManifest["entry"] as? String == "observer-main.cjs",
              let files = overlayManifest["files"] as? [String: String], Set(files.keys) == Set(glue + ["package.json"]) else {
            throw MeshNeoCursorRuntimeError.invalid("overlay mode, upstream pin or entry point is invalid")
        }
        for name in glue {
            let expected = try read(expectedAssetsDirectory.appendingPathComponent(name), limit: 524_288)
            let staged = try read(overlay.appendingPathComponent(name), limit: 524_288)
            try require(sha(expected) == files[name] && staged == expected, "restage the bundled tracker adapter: \(name) changed")
        }
        let packageBytes = try read(overlay.appendingPathComponent("package.json"), limit: 8_192)
        guard sha(packageBytes) == files["package.json"],
              let package = try JSONSerialization.jsonObject(with: packageBytes) as? [String: Any],
              package["name"] as? String == "mesh-neocursor-observer", package["main"] as? String == "observer-main.cjs",
              package["private"] as? Bool == true else {
            throw MeshNeoCursorRuntimeError.invalid("overlay package entry point changed")
        }
        let executable = try read(URL(fileURLWithPath: configuration.electronExecutable), limit: 536_870_912, executable: true)
        try require(sha(executable) == configuration.electronExecutableSHA256, "Electron executable differs from the pinned SHA256")
        return configuration
    }
}

enum MeshNeoCursorReadiness: String, Decodable, Sendable {
    case unknown
    case cameraOff = "camera-off", waitingFrame = "waiting-frame", noFace = "no-face", multipleFaces = "multiple-faces"
    case eyesUnavailable = "eyes-unavailable", readyToCalibrate = "ready-to-calibrate", placingTarget = "placing-target"
    case collecting, validated, projectionUnavailable = "projection-unavailable", staleFrame = "stale-frame"

    var summary: String {
        switch self {
        case .unknown: return "Tracking readiness unavailable from this tracker version"
        case .cameraOff: return "Tracker open · camera off"
        case .waitingFrame: return "Camera started · waiting for a processed frame"
        case .noFace: return "No face found · face the chosen camera and check lighting"
        case .multipleFaces: return "Multiple faces found · keep only your face in view"
        case .eyesUnavailable: return "Eye landmarks unavailable · keep both eyes visible and adjust camera or lighting"
        case .readyToCalibrate: return "Eyes visible · ready to calibrate"
        case .placingTarget: return "Placing the calibration target on the chosen display"
        case .collecting: return "Collecting eye samples · keep looking at the dot, then press Space"
        case .validated: return "Calibration passed · producer reports usable gaze"
        case .projectionUnavailable: return "Calibration passed · no usable screen coordinate; look at the chosen display"
        case .staleFrame: return "Waiting for a fresh frame · no current gaze shared"
        }
    }
}

enum MeshNeoCursorCalibrationIssue: String, Decodable, Sendable {
    case targetNotActive = "target-not-active", needSamples = "need-12-fresh-samples", needSpan = "need-1200ms-span"
    case staleSample = "latest-sample-stale", unstable = "unstable-eye-features", degenerate = "degenerate-calibration"
    case missing = "missing-calibration", heldOut = "held-out-error", focusLost = "focus-lost"

    var summary: String {
        switch self {
        case .targetNotActive: return "Wait for the target to be placed"
        case .needSamples: return "Need more usable eye samples; keep looking at the dot and retry"
        case .needSpan: return "Hold your gaze for two seconds and retry"
        case .staleSample: return "Wait for fresh eye samples before saving the target"
        case .unstable: return "Eye samples moved too much; keep your head still and retry"
        case .degenerate: return "Samples could not distinguish the targets; adjust your setup and restart calibration"
        case .missing: return "Calibration fit unavailable; restart calibration"
        case .heldOut: return "Accuracy check failed; adjust your setup and restart calibration"
        case .focusLost: return "Calibration lost focus; return to the tracker and restart calibration"
        }
    }
}

struct MeshNeoCursorRuntimeEvent: Decodable, Sendable {
    let schemaVersion: Int
    let event: String
    let reason: String
    let captureActive: Bool
    let frameObserved: Bool
    let calibrating: Bool
    let validated: Bool
    let cameraID: String?
    let selectedCameraID: String?
    let displayID: String?
    let calibrationID: String?
    let output: String?
    let completedTargets: Int
    let totalTargets: Int
    // Additive schema-1 fields: old staged overlays remain readable, with unknown readiness.
    let readinessCode: MeshNeoCursorReadiness?
    let calibrationIssue: MeshNeoCursorCalibrationIssue?
    let sampleCount: Int?

    func validate() throws {
        try MeshNeoCursorRuntimeFiles.require(schemaVersion == 1 && ["ready", "state", "error", "exit"].contains(event), "invalid tracker event")
        try MeshNeoCursorRuntimeFiles.require(!reason.isEmpty && reason.utf8.count <= 160
            && reason.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }, "invalid tracker reason")
        for value in [cameraID, selectedCameraID, displayID, calibrationID, output].compactMap({ $0 }) {
            try MeshNeoCursorRuntimeFiles.require(value.utf8.count <= 2_048 && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), "invalid tracker identity")
        }
        if validated {
            try MeshNeoCursorRuntimeFiles.require(captureActive && frameObserved && !calibrating && cameraID?.isEmpty == false
                && displayID?.isEmpty == false && calibrationID?.isEmpty == false && output?.hasPrefix("/") == true,
                "validated tracker state is missing its setup identity")
        }
        try MeshNeoCursorRuntimeFiles.require(totalTargets == 7 && (0...7).contains(completedTargets), "invalid tracker calibration progress")
        if frameObserved { try MeshNeoCursorRuntimeFiles.require(captureActive && cameraID?.isEmpty == false && cameraID == selectedCameraID, "observed frame has no matching camera identity") }
        else { try MeshNeoCursorRuntimeFiles.require(cameraID == nil, "camera identity cannot precede an observed frame") }
        if !captureActive { try MeshNeoCursorRuntimeFiles.require(!calibrating && !validated && !frameObserved, "inactive tracker cannot be calibrated") }
        if let sampleCount { try MeshNeoCursorRuntimeFiles.require((0...96).contains(sampleCount), "invalid tracker sample count") }
        if let readinessCode {
            switch readinessCode {
            case .unknown: break
            case .cameraOff: try MeshNeoCursorRuntimeFiles.require(!captureActive, "camera-off readiness with active capture")
            case .waitingFrame, .staleFrame: try MeshNeoCursorRuntimeFiles.require(captureActive, "frame readiness without capture")
            default: try MeshNeoCursorRuntimeFiles.require(captureActive && frameObserved, "tracking readiness without an observed frame")
            }
            if readinessCode == .validated || readinessCode == .projectionUnavailable {
                try MeshNeoCursorRuntimeFiles.require(validated, "gaze readiness without validated calibration")
            }
            if readinessCode == .collecting || readinessCode == .placingTarget {
                try MeshNeoCursorRuntimeFiles.require(calibrating, "target readiness outside calibration")
            }
            if readinessCode == .readyToCalibrate {
                try MeshNeoCursorRuntimeFiles.require(!validated && !calibrating, "ready-to-calibrate contradicts calibration state")
            }
        }
        if event == "exit" {
            try MeshNeoCursorRuntimeFiles.require(!captureActive && !calibrating && !validated, "stopped tracker still reports capture")
        }
    }
}

/// Explicitly opens one observation-only tracker. Configuration checks and initialization are inert.
@MainActor final class MeshNeoCursorRuntime: ObservableObject {
    @Published private(set) var status = "Tracker closed"
    @Published private(set) var error: String?
    @Published private(set) var isConfigured = false
    @Published private(set) var isStarting = false
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var captureActive = false
    /// The producer has observed a frame in this capture session; not a live freshness guarantee.
    @Published private(set) var frameObserved = false
    @Published private(set) var calibrating = false
    @Published private(set) var validated = false
    @Published private(set) var observationPath: String?
    @Published private(set) var cameraID: String?
    @Published private(set) var selectedCameraID: String?
    @Published private(set) var displayID: String?
    @Published private(set) var calibrationID: String?
    @Published private(set) var completedTargets = 0
    @Published private(set) var totalTargets = 7
    /// Last producer report, not a replacement for observation-file freshness checks.
    @Published private(set) var readiness: MeshNeoCursorReadiness = .unknown
    @Published private(set) var calibrationIssue: MeshNeoCursorCalibrationIssue?
    /// Count at the last state/milestone receipt; the tracker window shows every sample.
    @Published private(set) var sampleCount = 0
    var readinessSummary: String {
        [readiness.summary, calibrationIssue?.summary].compactMap { $0 }.joined(separator: " · ")
    }
    var onValidated: (() -> Void)?
    private let configurationURL: URL
    private let expectedAssetsDirectory: URL
    private let stopGraceNanoseconds: UInt64
    private let startupTimeoutNanoseconds: UInt64
    private let terminationTimeoutNanoseconds: UInt64
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var validation: Task<MeshNeoCursorRuntimeConfiguration, Error>?
    private var startup: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var expectedExit = false

    init(configurationURL: URL? = nil, expectedAssetsDirectory: URL? = nil,
         stopGraceNanoseconds: UInt64 = 1_500_000_000, startupTimeoutNanoseconds: UInt64 = 30_000_000_000,
         terminationTimeoutNanoseconds: UInt64 = 2_000_000_000) {
        self.configurationURL = configurationURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshMonitor/neocursor-runtime.json")
        self.expectedAssetsDirectory = expectedAssetsDirectory ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("NeoCursorAdapter", isDirectory: true)
        self.stopGraceNanoseconds = stopGraceNanoseconds; self.startupTimeoutNanoseconds = startupTimeoutNanoseconds
        self.terminationTimeoutNanoseconds = terminationTimeoutNanoseconds
    }

    deinit {
        validation?.cancel(); startup?.cancel(); deadline?.cancel(); stopping?.cancel()
        output?.readabilityHandler = nil
        try? input?.write(contentsOf: Data("{\"command\":\"quit\"}\n".utf8)); try? input?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    func start() {
        guard process == nil && !isStarting else {
            status = isStopping ? (error ?? "Stopping tracker…") : isRunning ? "Tracker is already open" : "Tracker is starting"
            return
        }
        beginValidation(launch: true)
    }
    func refreshConfiguration() {
        guard process == nil && !isStarting else { return }
        beginValidation(launch: false)
    }
    private func beginValidation(launch: Bool) {
        generation = UUID(); let token = generation
        error = nil; isStarting = true; status = "Checking tracker setup…"
        let url = configurationURL, assets = expectedAssetsDirectory
        let check = Task.detached(priority: .utility) { try MeshNeoCursorRuntimeFiles.validate(configurationURL: url, expectedAssetsDirectory: assets) }
        validation = check
        startup = Task { [weak self] in
            do {
                let configuration = try await check.value
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.validation = nil; self.isConfigured = true
                if launch { try self.launch(configuration, token: token) }
                else { self.isStarting = false; self.status = "Tracker setup verified · ready to open" }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.validation = nil; self.isConfigured = false; self.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        generation = UUID(); validation?.cancel(); validation = nil; startup?.cancel(); startup = nil
        deadline?.cancel(); deadline = nil; expectedExit = true
        isStarting = false
        let previousCaptureActive = captureActive
        clearObservation()
        guard let process else { isStopping = false; isRunning = false; status = "Tracker closed"; error = nil; return }
        // A quit request revokes all usable evidence immediately. Until the owned process
        // exits, keep its last capture state visible under a truthful stopping status.
        captureActive = previousCaptureActive; isRunning = process.isRunning
        guard !isStopping else { return }
        isStopping = true; status = "Stopping tracker…"; error = nil
        do { try input?.write(contentsOf: Data("{\"command\":\"quit\"}\n".utf8)) } catch { }
        try? input?.close(); input = nil
        let grace = stopGraceNanoseconds, terminationTimeout = terminationTimeoutNanoseconds
        stopping?.cancel()
        stopping = Task { [weak self, weak process] in
            try? await Task.sleep(nanoseconds: grace)
            guard !Task.isCancelled, let process, process.isRunning else { return }
            process.terminate()
            try? await Task.sleep(nanoseconds: terminationTimeout)
            guard !Task.isCancelled, let self, self.process === process, process.isRunning else { return }
            self.isRunning = true; self.isStopping = true
            self.error = "Tracker has not exited after Stop; its process is still running"
            self.status = self.error!
        }
    }

    private func launch(_ configuration: MeshNeoCursorRuntimeConfiguration, token: UUID) throws {
        guard generation == token, !Task.isCancelled else { return }
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        // A child can close stdin before a queued Stop reaches us. Avoid a process-wide
        // SIGPIPE handler: this one owned pipe reports EPIPE to FileHandle.write instead.
        try MeshNeoCursorRuntimeFiles.require(fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
                                              "could not prepare the tracker control pipe")
        child.executableURL = URL(fileURLWithPath: configuration.electronExecutable)
        child.arguments = [configuration.overlayDirectory, "--mesh-managed"]
        child.currentDirectoryURL = URL(fileURLWithPath: configuration.overlayDirectory, isDirectory: true)
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = FileHandle.nullDevice
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
        expectedExit = false; buffer.removeAll()
        child.terminationHandler = { [weak self] process in
            Task { @MainActor in self?.terminated(process) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.process === child else { return }
                if data.isEmpty { self.eof(child) }
                else if self.generation == token { self.consume(data) }
            }
        }
        self.process = child; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        do { try child.run() }
        catch {
            output?.readabilityHandler = nil; self.process = nil; input = nil; output = nil
            throw error
        }
        status = "Opening tracker setup · camera stays off until you start it"
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.startupTimeoutNanoseconds ?? 0)
            guard !Task.isCancelled, let self, self.generation == token, self.isStarting else { return }
            self.fail("Tracker startup timed out")
        }
    }
    private func consume(_ data: Data) {
        let token = generation
        buffer.append(data)
        guard buffer.count <= 65_536 else { fail("Tracker output exceeded its limit"); return }
        while let newline = buffer.firstIndex(of: 10) {
            guard generation == token && !isStopping else { return }
            let bytes = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard bytes.count <= 16_384 else { fail("Tracker event exceeded its limit"); return }
            guard let line = String(data: bytes, encoding: .utf8) else { fail("Tracker output is not UTF-8"); return }
            guard line.hasPrefix("MESH_OBSERVER ") else { continue }
            do {
                let event = try JSONDecoder().decode(MeshNeoCursorRuntimeEvent.self, from: Data(line.dropFirst(14).utf8))
                try event.validate()
                if event.event == "error" { fail("Tracker reported: \(event.reason)"); return }
                if event.event == "exit" {
                    stop(); status = "Stopping tracker · \(event.reason)"; return
                }
                if event.event == "ready" { isStarting = false; isRunning = true; deadline?.cancel(); deadline = nil }
                guard isRunning else { continue }
                let newlyValidated = event.validated && (!validated || calibrationID != event.calibrationID)
                captureActive = event.captureActive; calibrating = event.calibrating; validated = event.validated
                frameObserved = event.frameObserved; selectedCameraID = event.selectedCameraID
                completedTargets = event.completedTargets; totalTargets = event.totalTargets
                observationPath = event.output; cameraID = event.cameraID; displayID = event.displayID; calibrationID = event.calibrationID
                readiness = event.readinessCode ?? .unknown; calibrationIssue = event.calibrationIssue; sampleCount = event.sampleCount ?? 0
                status = event.readinessCode == nil
                    ? (captureActive ? (validated ? "Calibration passed · current tracking readiness unavailable" : "Camera active · tracking readiness unavailable") : "Tracker open · camera off")
                    : readinessSummary
                if newlyValidated { onValidated?() }
            } catch { fail("Tracker event is invalid"); return }
        }
    }
    private func clearObservation() {
        captureActive = false; frameObserved = false; calibrating = false; validated = false; completedTargets = 0
        observationPath = nil; cameraID = nil; selectedCameraID = nil; displayID = nil; calibrationID = nil
        readiness = .unknown; calibrationIssue = nil; sampleCount = 0
    }
    private func eof(_ child: Process) {
        guard process === child else { return }
        output?.readabilityHandler = nil; deadline?.cancel(); deadline = nil
        let wasExpected = expectedExit
        stop()
        if !wasExpected { error = "Tracker connection closed"; status = error! }
    }
    private func terminated(_ child: Process) {
        guard process === child else { return }
        output?.readabilityHandler = nil; try? input?.close(); try? output?.close()
        process = nil; input = nil; output = nil; buffer.removeAll(); deadline?.cancel(); deadline = nil
        stopping?.cancel(); stopping = nil; isStarting = false; isRunning = false; isStopping = false; clearObservation()
        if !expectedExit && error == nil { error = "Tracker exited (\(child.terminationStatus))"; status = error! }
        else if error == nil { status = "Tracker closed" }
    }
    private func fail(_ message: String) {
        stop(); error = String(message.prefix(400)); status = error!
    }
}

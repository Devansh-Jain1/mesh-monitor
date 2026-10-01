import Darwin
import Foundation

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "MeshNeoCursorFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func rejects(_ label: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw NSError(domain: "MeshNeoCursorFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "accepted invalid fixture: \(label)"])
}
private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) }
private func jsonString(_ value: String) throws -> String { String(data: try json(value), encoding: .utf8)! }
private func put(_ data: Data, _ url: URL, mode: mode_t = 0o600) throws {
    try data.write(to: url); try require(chmod(url.path, mode) == 0, "fixture chmod")
}

private final class Fixture {
    let root: URL
    let assets: URL
    let overlay: URL
    let executable: URL
    let config: URL
    var manifest: [String: Any] = [:]
    var configuration: [String: Any] = [:]

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/mesh-neocursor-runtime-\(UUID().uuidString)", isDirectory: true)
        assets = root.appendingPathComponent("assets", isDirectory: true)
        overlay = root.appendingPathComponent("overlay", isDirectory: true)
        executable = root.appendingPathComponent("fake-electron")
        config = root.appendingPathComponent("neocursor-runtime.json")
        for directory in [root, assets, overlay] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var hashes: [String: String] = [:]
        for name in MeshNeoCursorRuntimeFiles.glue {
            let bytes = Data("fixture-original-\(name)\n".utf8)
            try put(bytes, assets.appendingPathComponent(name)); try put(bytes, overlay.appendingPathComponent(name))
            hashes[name] = MeshNeoCursorRuntimeFiles.sha(bytes)
        }
        let package = try json(["name": "mesh-neocursor-observer", "main": "observer-main.cjs", "private": true])
        try put(package, overlay.appendingPathComponent("package.json")); hashes["package.json"] = MeshNeoCursorRuntimeFiles.sha(package)
        manifest = ["schema": 1, "mode": "observation-only", "upstream": ["commit": MeshNeoCursorRuntimeFiles.upstreamPin],
                    "overlay": ["entry": "observer-main.cjs", "files": hashes]]
        configuration = ["schema": "mesh.neocursor-runtime.v1", "electronExecutable": executable.path,
                         "electronVersion": "41.4.0", "overlayDirectory": overlay.path]
        try installChild(mode: "normal", name: "normal")
        try saveManifest()
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func saveConfiguration() throws { try put(json(configuration), config) }
    func saveManifest() throws {
        let data = try json(manifest), hash = MeshNeoCursorRuntimeFiles.sha(data)
        try put(data, overlay.appendingPathComponent("manifest.json"))
        try put(Data((hash + "\n").utf8), overlay.appendingPathComponent("READY"))
        configuration["overlayManifestSHA256"] = hash; try saveConfiguration()
    }
    func validate() throws { _ = try MeshNeoCursorRuntimeFiles.validate(configurationURL: config, expectedAssetsDirectory: assets) }
    func marker(_ name: String) -> URL { root.appendingPathComponent(name) }
    func installChild(mode: String, name: String) throws {
        // This synthetic executable imports only Python's standard library, never Electron,
        // camera, audio, model or networking modules. It does not spawn descendants.
        let script = """
        #!/usr/bin/python3
        import json, os, signal, sys
        root = \(try jsonString(root.path))
        name = \(try jsonString(name))
        mode = \(try jsonString(mode))
        def mark(suffix, value):
            with open(os.path.join(root, name + suffix), 'w') as f:
                json.dump(value, f)
        def finish(reason):
            mark('.stopped', reason)
            sys.exit(0)
        sys.excepthook = lambda kind, value, trace: mark('.failed', str(value))
        signal.signal(signal.SIGTERM, lambda *_: finish('term'))
        if mode == 'term-stall':
            signal.signal(signal.SIGALRM, lambda *_: finish('delayed-term'))
            signal.signal(signal.SIGTERM, lambda *_: (mark('.term-requested', True), signal.alarm(1)))
        mark('.started', {'argv': sys.argv[1:], 'unsafeEnvironment': [k for k in os.environ if k in ['ELECTRON_RUN_AS_NODE','NODE_OPTIONS','NODE_PATH'] or k.startswith('DYLD_')]})
        state = {'schemaVersion':1,'event':'ready','reason':'ui-loaded','captureActive':False,'frameObserved':False,'calibrating':False,'validated':False,'cameraID':None,'selectedCameraID':None,'displayID':None,'calibrationID':None,'output':None,'completedTargets':0,'totalTargets':7}
        def emit():
            print('MESH_OBSERVER ' + json.dumps(state), flush=True)
        if mode == 'hang':
            while True: signal.pause()
        emit()
        if mode == 'oversized':
            print('x' * 70000, flush=True)
        elif mode == 'malformed':
            print('MESH_OBSERVER {bad-json}', flush=True)
        else:
            state.update(event='state',reason='calibration-validated',captureActive=True,frameObserved=True,validated=True,cameraID='fixture-camera',selectedCameraID='fixture-camera',displayID='42',calibrationID='fixture-calibration',output=os.path.join(root,'gaze.json'),completedTargets=7)
            if mode == 'readiness':
                state.update(readinessCode='no-face',sampleCount=0,calibrationIssue=None)
            if mode == 'callback-stop':
                second = dict(state, calibrationID='late-calibration')
                sys.stdout.write('MESH_OBSERVER ' + json.dumps(state) + chr(10) + 'MESH_OBSERVER ' + json.dumps(second) + chr(10))
                sys.stdout.flush()
            else: emit()
        if mode == 'crash':
            sys.exit(23)
        if mode == 'exit-stall':
            state.update(event='exit',reason='ui-exit',captureActive=False,frameObserved=False,validated=False,cameraID=None,calibrationID=None,completedTargets=0)
            emit()
        if mode in ['exit-stall','term-stall']:
            while True: signal.pause()
        if mode == 'reported-error':
            state.update(event='error',reason='capture-failed')
            emit()
        while True:
            line = sys.stdin.readline()
            if not line: finish('eof')
            value = json.loads(line)
            if value == {'command':'quit'}: finish('quit')
        """
        let bytes = Data(script.utf8)
        try put(bytes, executable, mode: 0o700)
        configuration["electronExecutableSHA256"] = MeshNeoCursorRuntimeFiles.sha(bytes)
        if configuration["overlayManifestSHA256"] != nil { try saveConfiguration() }
    }
}

@MainActor private func until(_ label: String, timeout: Double = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    try require(condition(), "timed out: \(label)")
}

@main struct MeshNeoCursorRuntimeFixture {
    @MainActor static func main() async throws {
        let fixture = try Fixture()
        try fileValidation(fixture)
        try eventValidation()
        try await lifecycle(fixture)
        print("PASS: sensor-free NeoCursor runtime validation, explicit start, owned stop, crash, timeout and bounded protocol")
    }

    private static func fileValidation(_ fixture: Fixture) throws {
        try fixture.validate()
        for value in ["41.0.2", "41.3.99", "42.0.0", "41.4.0-beta", "41.4", "41.4.0.0"] {
            fixture.configuration["electronVersion"] = value; try fixture.saveConfiguration()
            try rejects("unsupported Electron \(value)") { try fixture.validate() }
        }
        fixture.configuration["electronVersion"] = "41.4.0"; try fixture.saveConfiguration()
        try require(MeshNeoCursorRuntimeFiles.supportedVersion("41.5.1"), "supported 41.x minor")
        chmod(fixture.config.path, 0o644)
        try rejects("public config") { try fixture.validate() }; chmod(fixture.config.path, 0o600)
        chmod(fixture.root.path, 0o755)
        try rejects("non-private config parent") { try fixture.validate() }; chmod(fixture.root.path, 0o700)
        let symlink = fixture.root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.config)
        try rejects("symlink config") { _ = try MeshNeoCursorRuntimeFiles.validate(configurationURL: symlink, expectedAssetsDirectory: fixture.assets) }
        let hardlink = fixture.root.appendingPathComponent("hardlinked.json")
        try FileManager.default.linkItem(at: fixture.config, to: hardlink)
        try rejects("hardlinked config") { try fixture.validate() }; try FileManager.default.removeItem(at: hardlink)
        let originalConfig = try Data(contentsOf: fixture.config)
        try put(Data(repeating: 32, count: 16_385), fixture.config)
        try rejects("oversized config") { try fixture.validate() }; try put(originalConfig, fixture.config)
        let readyURL = fixture.overlay.appendingPathComponent("READY"), ready = try Data(contentsOf: readyURL)
        try put(Data("wrong\n".utf8), readyURL)
        try rejects("READY mismatch") { try fixture.validate() }; try put(ready, readyURL)
        fixture.manifest["upstream"] = ["commit": String(repeating: "0", count: 40)]; try fixture.saveManifest()
        try rejects("wrong upstream pin") { try fixture.validate() }
        fixture.manifest["upstream"] = ["commit": MeshNeoCursorRuntimeFiles.upstreamPin]; try fixture.saveManifest()
        let glueURL = fixture.overlay.appendingPathComponent("observer-main.cjs"), glue = try Data(contentsOf: glueURL)
        try put(Data("changed".utf8), glueURL)
        try rejects("modified staged glue") { try fixture.validate() }; try put(glue, glueURL)
        let expectedURL = fixture.assets.appendingPathComponent("observer-main.cjs")
        try put(Data("new bundled glue".utf8), expectedURL)
        try rejects("outdated adapter against bundled glue") { try fixture.validate() }; try put(glue, expectedURL)
        let packageURL = fixture.overlay.appendingPathComponent("package.json"), package = try Data(contentsOf: packageURL)
        try put(Data("{}".utf8), packageURL)
        try rejects("changed package") { try fixture.validate() }; try put(package, packageURL)
        let executable = try Data(contentsOf: fixture.executable)
        try put(Data("changed executable".utf8), fixture.executable, mode: 0o700)
        try rejects("Electron digest mismatch") { try fixture.validate() }; try put(executable, fixture.executable, mode: 0o700)
        chmod(fixture.executable.path, 0o600)
        try rejects("nonexecutable") { try fixture.validate() }; chmod(fixture.executable.path, 0o700)
        try fixture.validate()
    }

    static func eventValidation() throws {
        let base: [String: Any] = ["schemaVersion": 1, "event": "state", "reason": "capture-authorized", "captureActive": true,
                                 "frameObserved": false, "calibrating": false, "validated": false, "cameraID": NSNull(), "selectedCameraID": "camera",
                                 "displayID": "42", "calibrationID": NSNull(), "output": NSNull(), "completedTargets": 0, "totalTargets": 7]
        func validate(_ event: [String: Any]) throws { try JSONDecoder().decode(MeshNeoCursorRuntimeEvent.self, from: json(event)).validate() }
        try validate(base)
        let legacy = try JSONDecoder().decode(MeshNeoCursorRuntimeEvent.self, from: json(base))
        try require(legacy.readinessCode == nil && legacy.calibrationIssue == nil && legacy.sampleCount == nil, "legacy schema-1 readiness remains unknown")
        var event = base; event["cameraID"] = "camera"
        try rejects("camera identity before actual frame") { try validate(event) }
        event["frameObserved"] = true; try validate(event)
        event["cameraID"] = "different"; try rejects("frame camera mismatch") { try validate(event) }
        event = base; event["validated"] = true; try rejects("invented validation") { try validate(event) }
        event = base; event["event"] = "exit"; try rejects("exit with active capture") { try validate(event) }
        event = base; event["event"] = "error"; try validate(event) // Error may precede producer stop; native revokes immediately.
        for (key, value) in [("schemaVersion", 2 as Any), ("event", "unknown"), ("reason", "private text\n"), ("completedTargets", 8), ("totalTargets", 9), ("selectedCameraID", String(repeating: "x", count: 2049))] {
            event = base; event[key] = value; try rejects("bad event \(key)") { try validate(event) }
        }
        event = base; event["readinessCode"] = "waiting-frame"; event["sampleCount"] = 0; try validate(event)
        event["readinessCode"] = "camera-off"; try rejects("camera off while capture active") { try validate(event) }
        event["readinessCode"] = "ready-to-calibrate"; try rejects("readiness without a frame") { try validate(event) }
        event["frameObserved"] = true; event["cameraID"] = "camera"; try validate(event)
        for code in ["no-face", "multiple-faces", "eyes-unavailable", "stale-frame"] {
            event["readinessCode"] = code; try validate(event)
        }
        event["readinessCode"] = "collecting"; try rejects("collecting outside calibration") { try validate(event) }
        event["calibrating"] = true; event["calibrationIssue"] = "need-12-fresh-samples"; event["sampleCount"] = 11; try validate(event)
        for (key, value) in [("readinessCode", "private-unknown" as Any), ("calibrationIssue", "unknown"), ("sampleCount", 97), ("sampleCount", -1)] {
            var invalid = event; invalid[key] = value; try rejects("invalid readiness field \(key)") { try validate(invalid) }
        }
        event["readinessCode"] = "validated"; try rejects("readiness cannot invent validated calibration") { try validate(event) }
        event["calibrating"] = false; event["validated"] = true; event["calibrationID"] = "fit"; event["output"] = "/fixture/gaze.json"; try validate(event)
        event["readinessCode"] = "projection-unavailable"; try validate(event)
        event["readinessCode"] = "no-face"; try validate(event) // A fit survives temporary loss of usable landmarks.
        try require(MeshNeoCursorReadiness.noFace.summary.contains("No face"), "friendly readiness text")
        try require(MeshNeoCursorCalibrationIssue.heldOut.summary.contains("Accuracy check failed"), "friendly validation failure")
    }

    @MainActor private static func lifecycle(_ fixture: Fixture) async throws {
        func manager(timeout: UInt64 = 2_000_000_000) -> MeshNeoCursorRuntime {
            MeshNeoCursorRuntime(configurationURL: fixture.config, expectedAssetsDirectory: fixture.assets,
                                 stopGraceNanoseconds: 100_000_000, startupTimeoutNanoseconds: timeout,
                                 terminationTimeoutNanoseconds: 100_000_000)
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: fixture.marker(name).path) }
        let runtime = manager(); var callbacks = 0
        runtime.onValidated = { callbacks += 1 }
        try require(!runtime.isStarting && !runtime.isRunning && !runtime.captureActive && !exists("normal.started"), "init must be inert")
        runtime.refreshConfiguration()
        try await until("inert validation") { !runtime.isStarting }
        try require(runtime.isConfigured && runtime.error == nil && !exists("normal.started"), "refresh validates without launch")
        setenv("ELECTRON_RUN_AS_NODE", "1", 1); setenv("NODE_OPTIONS", "--inspect", 1); setenv("NODE_PATH", "/fake", 1)
        runtime.start()
        try await until("validated synthetic child") { runtime.validated || runtime.error != nil }
        unsetenv("ELECTRON_RUN_AS_NODE"); unsetenv("NODE_OPTIONS"); unsetenv("NODE_PATH")
        let failure = (try? String(contentsOf: fixture.marker("normal.failed"), encoding: .utf8)) ?? "none"
        try require(runtime.error == nil && runtime.isRunning && runtime.captureActive && runtime.frameObserved && runtime.validated, "synthetic receipts update UI: \(runtime.status); fixture error: \(failure)")
        try require(runtime.readiness == .unknown && runtime.status.contains("readiness unavailable"), "old overlay does not imply current gaze readiness")
        try require(runtime.cameraID == "fixture-camera" && runtime.selectedCameraID == "fixture-camera" && runtime.displayID == "42"
                    && runtime.calibrationID == "fixture-calibration" && runtime.completedTargets == 7 && callbacks == 1, "full receipt identity and callback")
        let launch = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.marker("normal.started"))) as! [String: Any]
        try require(launch["argv"] as? [String] == [fixture.overlay.path, "--mesh-managed"], "exact managed argv")
        try require(launch["unsafeEnvironment"] as? [String] == [], "inherited code injection environment removed")
        runtime.stop()
        try require(!runtime.isStarting && runtime.isRunning && runtime.isStopping && runtime.captureActive && !runtime.frameObserved && !runtime.validated && runtime.observationPath == nil && runtime.cameraID == nil, "stop revokes evidence without prematurely claiming capture stopped")
        try await until("quit delivered") { exists("normal.stopped") }
        try await until("normal process exited") { !runtime.isStopping && !runtime.isRunning && !runtime.captureActive }
        try require(String(data: try Data(contentsOf: fixture.marker("normal.stopped")), encoding: .utf8) == "\"quit\"", "owned child receives NDJSON quit")
        try await Task.sleep(nanoseconds: 100_000_000)

        try fixture.installChild(mode: "readiness", name: "readiness")
        let readiness = manager(); readiness.start()
        try await until("bounded readiness receipt") { readiness.readiness == .noFace || readiness.error != nil }
        try require(readiness.error == nil && readiness.validated && readiness.status.contains("No face found"), "current face loss takes precedence over historical validated fit")
        readiness.stop()
        try await until("readiness child exits") { !readiness.isRunning && !readiness.isStopping }
        try require(readiness.readiness == .unknown && readiness.calibrationIssue == nil && readiness.sampleCount == 0, "stop clears readiness and samples")

        for (mode, expectation) in [("crash", "exited or EOF"), ("malformed", "invalid"), ("oversized", "limit"), ("reported-error", "capture-failed"), ("hang", "timed out")] {
            try fixture.installChild(mode: mode, name: mode)
            let tested = manager(timeout: mode == "hang" ? 500_000_000 : 2_000_000_000)
            tested.start()
            try await until("\(mode) clears status") { tested.error != nil && !tested.isRunning && !tested.isStarting && !tested.isStopping }
            try require(!tested.captureActive && !tested.frameObserved && !tested.validated && tested.calibrationID == nil, "\(mode) clears sensor evidence")
            if mode != "crash" {
                try require(tested.error?.contains(expectation) == true, "\(mode) surfaces bounded reason: \(tested.error ?? "none")")
                try await until("\(mode) owned child stopped") { exists(mode + ".stopped") }
            }
            if mode == "hang" {
                try require(String(data: try Data(contentsOf: fixture.marker("hang.stopped")), encoding: .utf8) == "\"term\"", "bounded grace terminates exact unresponsive child")
            }
            tested.stop()
        }

        try fixture.installChild(mode: "exit-stall", name: "exit-stall")
        let exiting = manager(); exiting.start()
        try await until("exit receipt invokes bounded shutdown") { exists("exit-stall.stopped") && !exiting.isStopping && !exiting.isRunning }
        try require(!exiting.captureActive && exiting.error == nil, "exit receipt cannot strand owned process")

        try fixture.installChild(mode: "term-stall", name: "term-stall")
        let stalled = manager(); stalled.start()
        try await until("stalled child running") { stalled.validated }
        stalled.stop()
        stalled.start()
        try require(stalled.isStopping && stalled.status.contains("Stopping"), "start during stop preserves truthful status")
        try await until("explicit non-exit state") { stalled.error?.contains("has not exited") == true }
        try require(stalled.isStopping && stalled.isRunning && stalled.captureActive && !stalled.validated && stalled.observationPath == nil,
                    "termination deadline keeps ownership and last capture state, with evidence revoked")
        try await until("delayed termination clears ownership") { !stalled.isStopping && !stalled.isRunning && !stalled.captureActive }

        try fixture.installChild(mode: "callback-stop", name: "callback-stop")
        let callbackStop = manager(); var callbackCount = 0
        callbackStop.onValidated = { [weak callbackStop] in callbackCount += 1; callbackStop?.stop() }
        callbackStop.start()
        try await until("callback stop revokes remaining receipt batch") { exists("callback-stop.stopped") && !callbackStop.isStopping }
        try require(callbackCount == 1 && !callbackStop.validated && callbackStop.calibrationID == nil, "same-batch late receipts cannot restore stopped evidence")

        try fixture.installChild(mode: "normal", name: "cancelled")
        let cancelled = manager(); cancelled.start(); cancelled.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        try require(!exists("cancelled.started") && !cancelled.isRunning && !cancelled.isStarting, "cancelled validation cannot launch late")

        try fixture.installChild(mode: "normal", name: "deinit")
        var owned: MeshNeoCursorRuntime? = manager()
        owned!.start(); try await until("deinit child ready") { owned?.validated == true }
        weak var released = owned; owned = nil
        try await until("deinit releases and stops child") { released == nil && exists("deinit.stopped") }
    }
}

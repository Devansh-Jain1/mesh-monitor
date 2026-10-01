import Foundation

@MainActor private final class PermissionHarness {
    var current: MeshCameraPermissionStatus
    var reads = 0, requests = 0, changes = 0
    var callbacks: [MeshCameraPermissionSetup.Completion] = []
    lazy var model = MeshCameraPermissionSetup(readStatus: { [self] in reads += 1; return current },
        requestAccess: { [self] callback in requests += 1; callbacks.append(callback) })
    init(_ current: MeshCameraPermissionStatus) { self.current = current }
    func observe() { model.onChange = { [weak self] in self?.changes += 1 } }
}

@main struct MeshCameraPermissionFixture {
    @MainActor static func main() async {
        var checks = 0
        func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func settle() async { for _ in 0..<30 { await Task.yield() } }
        for packaged in [false, true] {
            verify(MeshSnapshotLaunchMode.parse([], packagedApp: packaged) == (packaged ? .setup : .usage), "Only packaged ordinary launch opens setup")
            verify(MeshSnapshotLaunchMode.parse(["--setup"], packagedApp: packaged) == .setup, "Explicit setup is distinct")
            verify(MeshSnapshotLaunchMode.parse(["--managed"], packagedApp: packaged) == .managed, "Managed routing unchanged")
            verify(MeshSnapshotLaunchMode.parse(["--list-devices"], packagedApp: packaged) == .listDevices, "Enumeration is explicit")
            verify(MeshSnapshotLaunchMode.parse(["--help"], packagedApp: packaged) == .usage, "Help is inert")
            for args in [["--setup", "--managed"], ["--setup", "--arm"], ["--setup", "--list-devices"],
                         ["--setup", "--setup"], ["--setup", "--port", "18495"], ["--managed", "--arm"],
                         ["--list-devices", "--arm"], ["--help", "--arm"], ["--unknown"],
                         ["--arm", "--device-id", "DEVICE", "--port", "18495", "--setup"],
                         ["--arm", "--device-id", "", "--port", "18495"],
                         ["--arm", "--device-id", "DEVICE", "--port", "1023"],
                         ["--arm", "--device-id", "DEVICE", "--port", "65536"],
                         ["--arm", "--device-id", "--managed", "--port", "18495"],
                         ["--arm", "--device-id", "DEVICE", "--device-id", "DEVICE"],
                         ["--arm", "--device-id", "DEVICE", "--port"]] {
                verify(MeshSnapshotLaunchMode.parse(args, packagedApp: packaged) == .invalid, "Mixed or malformed mode must fail before dispatch: \(args)")
            }
            for args in [["--arm", "--device-id", "DEVICE", "--port", "18495"],
                         ["--device-id", "DEVICE", "--arm", "--port", "18495"],
                         ["--port", "18495", "--device-id", "DEVICE", "--arm"]] {
                verify(MeshSnapshotLaunchMode.parse(args, packagedApp: packaged) == .arm(deviceID: "DEVICE", port: 18495), "Explicit legacy arm arguments stay supported")
            }
        }
        for state: MeshCameraPermissionStatus in [.notDetermined, .authorized, .denied, .restricted, .unknown] {
            let h = PermissionHarness(state)
            verify(h.model.status == state && h.reads == 1 && h.requests == 0, "Opening setup reads permission only: \(state)")
            h.observe(); h.model.refresh()
            verify(h.requests == 0 && h.model.status == state, "Refresh never requests")
            if state != .notDetermined {
                h.model.requestFromUserAction()
                verify(h.requests == 0 && !h.model.isRequesting, "Existing permission choices never trigger request")
            }
            h.model.close(); let reads = h.reads, changes = h.changes
            h.model.refresh(); h.model.requestFromUserAction(); h.model.close()
            verify(h.reads == reads && h.changes == changes && h.requests == 0 && h.model.isClosed, "Closed setup stays inert")
        }
        do {
            let h = PermissionHarness(.notDetermined); h.observe()
            h.model.requestFromUserAction(); h.model.requestFromUserAction(); h.model.refresh()
            verify(h.requests == 1 && h.model.isRequesting && !h.model.isClosed, "A pending explicit click cannot prompt twice")
            h.current = .authorized
            let callback = h.callbacks[0]
            await Task.detached { callback(false) }.value
            await settle()
            verify(h.model.status == .authorized && !h.model.isRequesting && !h.model.resultUnresolved, "Fresh system status wins over callback false on another executor")
            let reads = h.reads, changes = h.changes
            h.current = .denied; callback(true); await settle()
            verify(h.reads == reads && h.changes == changes && h.model.status == .authorized, "Repeated completion for consumed request cannot overwrite UI")
            h.model.refresh()
            verify(h.model.status == .denied && h.requests == 1, "User can refresh a Settings change without re-prompting")
        }
        do {
            let h = PermissionHarness(.notDetermined); h.observe(); h.model.requestFromUserAction()
            h.current = .denied; h.callbacks[0](true); await settle()
            verify(h.model.status == .denied && !h.model.isRequesting, "Callback true cannot fabricate a grant")
        }
        do {
            let h = PermissionHarness(.notDetermined); h.observe(); h.model.requestFromUserAction()
            h.callbacks[0](true); await settle()
            verify(h.model.status == .notDetermined && h.model.resultUnresolved && !h.model.isRequesting, "Unresolved OS status remains explicit")
            h.model.requestFromUserAction()
            verify(h.requests == 2 && h.model.isRequesting && !h.model.resultUnresolved, "Only another explicit click retries unresolved permission")
            h.current = .restricted; h.callbacks[0](true); await settle()
            verify(h.model.isRequesting && h.model.status == .notDetermined, "Old callback cannot resolve a new request")
            h.callbacks[1](false); await settle()
            verify(h.model.status == .restricted && !h.model.isRequesting, "Restricted result is distinct from denied")
        }
        do {
            let h = PermissionHarness(.notDetermined); h.observe(); _ = h.model
            h.current = .authorized; h.model.requestFromUserAction()
            verify(h.requests == 0 && h.model.status == .authorized, "Click rechecks status before request")
        }
        do {
            let h = PermissionHarness(.notDetermined); h.observe(); h.model.requestFromUserAction()
            h.model.close(); let reads = h.reads, changes = h.changes
            h.current = .authorized; let callback = h.callbacks[0]
            await Task.detached { callback(true) }.value; await settle()
            verify(h.model.isClosed && !h.model.isRequesting && h.model.status == .notDetermined, "Close invalidates pending UI publication")
            verify(h.reads == reads && h.changes == changes, "Late callback does not read state or resurrect closed UI")
            let reopened = PermissionHarness(.authorized)
            verify(reopened.model.status == .authorized && reopened.requests == 0, "New setup uses new OS readback after closure")
        }
        for closeWhenPending in [false, true] {
            let h = PermissionHarness(.notDetermined)
            h.model.onChange = { [weak h] in
                guard let h else { return }
                if h.model.isRequesting == closeWhenPending { h.model.close() }
            }
            h.model.requestFromUserAction()
            verify(h.model.isClosed && h.requests == 0, "Reentrant window closure cannot start a permission request")
        }
        print("\(checks) permission/launch checks passed; injected providers only, no AppKit launch, camera, TCC, audio, or listeners")
    }
}

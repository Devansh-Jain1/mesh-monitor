# M1 camera helper package and attended setup

The helper now has a source-only macOS app packaging path. Building produces a signed bundle, a ZIP, a frozen source snapshot, and a hash/signature receipt. It does not install or execute the helper, query/request Camera permission, enumerate devices, contact M1, create Station configuration, reload Station, or open any sensor. The package does not establish a working M1 integration.

## Fixed package identity

| Field | Value |
| --- | --- |
| App | `Mesh Monitor M1 Camera.app` |
| Bundle identifier | `com.devansh.mesh-monitor.m1-camera` |
| Executable | `Contents/MacOS/MeshMonitorM1Camera` |
| Current version / build | `1.0.1` / `2` |
| Target | Apple silicon, macOS 14.0 or later |
| Permission description | Camera only; no microphone usage description |
| Requested signing options | Hardened runtime, camera entitlement only |
| Default signing | Ad hoc, not notarized or Developer ID distribution |

`CFBundleIdentifier` is fixed. That does **not** establish a stable TCC permission identity across ad hoc rebuilds. The builder preserves the actual designated requirement in `SIGNATURE.txt`; it does not replace it with an identifier-only requirement. A configured signing certificate can be selected explicitly with `--sign-identity` and its 40-digit certificate SHA-1. Certificate signing is still not proof that Station's directly launched child will be the TCC-responsible process.

Apple requires a camera usage description and appropriate entitlement before authorization/capture. Permission must be explicitly requested at an appropriate user action, and authorization checked before capture. See Apple's [capture authorization guide](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media) and [authorizationStatus documentation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)).

## Build without launching anything

From the `mesh-monitor-v1` worktree:

```sh
python3 ops/build_mesh_monitor_m1_camera.py
```

The default output is a fresh `artifacts/mesh-m1-camera-package-<timestamp>-<nonce>/`. `--output` may instead select a fresh directory under `/private/tmp/`. Existing output directories are rejected. Compilation uses only the frozen `source-snapshot/` bytes. A signed staging bundle is retained under `/private/tmp/mesh-m1-camera-sign-*/` so Desktop File Provider metadata cannot invalidate it during creation; the ZIP contains those exact verified bytes.

`BUILD-RECEIPT.json` records source and binary hashes, signed bundle files, archive hash, signature metadata hash, target, commands, signing mode, and explicit false flags for installation, helper launch, TCC, camera and Station acceptance. `codesign --verify --deep --strict` must succeed before a success receipt is issued. A failed build produces no success receipt. No tests execute the packaged helper.

To verify the package later, compare the receipt's source/binary/archive hashes and run `codesign --verify --deep --strict` on its `verified_staging_app`. Successful verification establishes signed byte integrity at that time, not Camera authorization or compatibility on the M1.

## Optional offline Station candidates

The builder creates candidates only when **all three** exact inputs are supplied together:

- `--receiver-source`: an explicit saved receiver matching the camera patcher's known return-patched SHA-256, or its exact already-patched output.
- `--camera-id`: the explicit external device's ID, supplied from prior authorized M1 enumeration. There is no guessed device or automatic enumeration.
- `--m1-app-path`: the intended absolute M1 path ending in `Mesh Monitor M1 Camera.app`. This is metadata only; the builder never writes there.

`--remote-port` defaults to `18495` and must match the M4 configuration. With these exact inputs, `setup-candidates/` contains:

- Original receiver bytes and a separate camera receiver candidate; source is never overwritten.
- The matching frozen Station owner/bridge module.
- A mode-0600 `camera-station.candidate.json` with the intended absolute helper executable, its **post-signing** SHA-256, exact camera ID, port and schema.

There are no capabilities/tokens in the candidate files. A candidate is not live `~/.config/mesh-monitor/camera-station.json`. The builder never writes that directory, starts a socket, or changes mode/AIY behavior. Installing a rebuilt or re-signed helper later requires checking and updating its exact executable hash through the reviewed setup process; otherwise Station correctly refuses it.

Before any later deployment, read back the actual receiver and compare it to the exact candidate source; an old fixture does not prove deployed compatibility. Preserve the original receiver/module/config, review candidate diffs, and establish the owner-private mode-0700 config directory plus mode-0600 configuration without symlink traversal. Station executes the exact configured helper with `--managed` and owns its pipes; the approved fixed bridge remains in `~/AIYStation/mesh_monitor_m1_camera_station.py`. The signed app is a package for that child, not a separate launch-on-login service.

## Explicit permission setup

The helper now implements a native setup window. Opening the packaged app with no arguments, or invoking its executable with `--setup`, shows permission status without capturing, enumerating devices, opening a listener, contacting Station, or requesting access automatically. An unpackaged command-line launch without arguments only prints usage. Invalid mixed modes are rejected before any setup or capture path.

**Allow camera…** is the sole permission-request action. It calls video `requestAccess` and reads macOS authorization again on the main actor when the callback returns. Granted, denied, restricted, undetermined and unknown states are distinct. Denied access offers **Open Camera Settings** on an explicit click. Refreshing/returning from Settings reads status without asking again. There is no microphone request. Closing the setup revokes its callback generation; it cannot cancel an already shown macOS permission dialog, and the UI explains that limit.

This setup path is source-tested with injected authorization providers and compiled as part of the signed package, but has not been launched on M1 or granted Camera permission. Neither the returned callback Boolean nor package signing establishes persistent authorization or Station's TCC responsibility. Managed capture still requires existing Camera authorization and the exact selected external device. Do not use the standalone `--arm` path as a permission workaround or as managed-session acceptance.

An attended setup must verify which process/bundle actually appears in Camera permissions when setup runs and when Station launches `Contents/MacOS/MeshMonitorM1Camera --managed`. If Station/SSH's responsibility chain prevents the intended identity from receiving authorization, correct the ownership/launch design; do not broaden permissions to Terminal/Python/sshd as an assumed workaround. No permission grant, persistence, or responsible-process behavior is inferred from a codesign receipt.

## Attended acceptance after deployment

Only after packaging, permission identity and exact device setup are verified:

1. Confirm ordinary launch and Station restart open no camera. Start explicitly from M4 Inputs while M1 is unlocked in Desktop.
2. Verify the actual selected external device, camera indicator and fresh authenticated preview agree. A `helperStarted` receipt alone is insufficient.
3. Exercise Stop, Pause, Night, Quit, M1 Dark, M1 lock, connection loss, device removal and stalled shutdown. Observe the physical indicator and measured release timing as well as software receipts.
4. Confirm returning to Desktop or reconnecting never automatically reopens capture. Show unconfirmed shutdown honestly when acknowledgement is missing.
5. Confirm room images enter an agent request only through explicit Room/Both evidence selection. Do not equate a room preview with gaze calibration or emotion/attention detection.

The existing [managed protocol](mesh-monitor-managed-camera-protocol.md) and [M1 plan](../ops/mesh-monitor-m1-camera-plan.md) remain the authority for session ownership and validation. Packaging does not replace their gates.

## Fixture checks

```sh
python3 -m unittest discover -s tests -p test_mesh_m1_camera_packaging.py -v
```

`tests/test_mesh_camera_permission.py` separately compiles the actual helper with Swift 6 and exercises its pure mode parser and injected permission controller, without launching its application entry point or asking for access.

The packaging tests use a fake compiler and signer. They verify fixed identity, frozen source custody, file/ZIP hashes, camera-only entitlement requests, no helper execution, exact receiver acceptance, all-or-nothing setup, private candidates, no overwrite, and failure without a success receipt. A separate actual compile/sign, if performed, should be recorded with its receipt and still marked not launched or sensor-tested.

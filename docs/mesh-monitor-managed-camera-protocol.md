# Managed snapshot helper protocol v1

Implemented helper in `ops/mesh_monitor_camera_snapshot.swift`. Build 19 source now includes Station ownership, the M4 transport/client and app controls described below; none of this M1 path is deployed or physically accepted. This document defines the helper boundary for the [optional M1 camera plan](../ops/mesh-monitor-m1-camera-plan.md). Managed mode does not itself verify station mode, console unlock or the truth of a supplied station epoch. The future Station owner must enforce those gates before capture.

## Launch and ownership

The new invocation is **`mesh-monitor-camera --managed`**, with no additional arguments. Its stdin must be an inherited pipe. A terminal or regular file is rejected with exit 2. It initially creates no camera object, performs no AVFoundation authorization/device lookup, and opens no listener. The first valid `prepare` creates only the loopback listener. Only authenticated `start` calls the camera backend.

The existing `--list-devices` and `--device-id EXACT_EXTERNAL_ID --port PORT --arm` modes remain manual/standalone. Standalone HTTP stays compatible with the previous unauthenticated loopback interface and is not claimed to have managed ownership. Do not combine these arguments with `--managed`.

The controller and its injected backend are shared with the sensor-free fixture. Production uses separate serial queues for parent controls/watchdog and the camera/listener. A blocked camera start/stop cannot prevent the independent deadline from exiting the helper process.

## Parent commands

One UTF-8 JSON object per newline; maximum 4,096 bytes per line. Blank, oversized or malformed lines, unknown commands, unknown fields, and invalid typed fields terminate the session through cleanup. No binary frames or human text travel on the parent channel.

Every command contains these fields:

| Field | Requirement |
| --- | --- |
| `schemaVersion` | Integer `1` |
| `command` | `prepare`, `start`, `renew`, `status`, or `stop` |
| `sessionID`, `generation` | UUID strings, retained exactly; subsequent commands match exactly |
| `stationEpoch` | 1–128 visible ASCII bytes; no spaces/control characters |
| `cameraID` | Explicit external device ID; 1–512 visible ASCII bytes |
| `controlToken` | Exactly 64 lowercase hexadecimal characters; generated randomly by the parent, not a reused station/API token |

`prepare` additionally requires `port` (integer 1024–65535) and a distinct `snapshotToken` (64 lowercase hex characters). The initial private parent pipe pins the identity and control token for this one process. This is not authentication of an arbitrary network control caller. Tokens are not command-line arguments, URLs or receipts.

`renew` additionally requires an unsigned integer `sequence`, strictly greater than the last accepted sequence (initially zero). Other commands accept no extra fields. Start requires `listenerReady`; it never queues capture before preparation. Repeated Start cannot start a second session. An exact duplicate Prepare returns state without creating a second backend or extending the lease.

Wrong identity, wrong token, stale renewal and wrong-state Start produce bounded errors without changing ownership or extending the lease. They cannot stop another session. Malformed input fails closed. Once stopping begins, further commands and late backend completions cannot reopen capture. Reopening requires a new explicitly launched helper with a new session.

## Receipts and deadlines

Stdout contains bounded NDJSON receipts, with `schemaVersion: 1`, `event`, `reason`, `state`, `captureActive`, `frameObserved`, and optional nested `identity` and `capturedAt`. `identity` contains only sessionID/generation/stationEpoch/cameraID. Neither token is serialized. Output is nonblocking; an unavailable/full output pipe triggers cleanup rather than blocking the watchdog.

Events are `accepted`, `listenerReady`, `helperStarted`, `firstFrame`, `state`, `error`, `stopping`, and `stopped`. Successful reasons are `ok`; failures use fixed enum codes from the source, never raw error strings. In particular:

- `listenerReady` means only the loopback listener is ready; captureActive is false.
- `helperStarted` follows successful camera-session startup, but does not prove a frame arrived.
- `firstFrame` is emitted once for the first fresh captured frame. `frameObserved` is historical within this session, not ongoing freshness proof.
- `captureActive` is conservative: true once Start is requested, including startup and teardown until confirmed stopped. It can therefore be true before the first frame and during a failed/stalled startup. It is false when only a listener was prepared.
- `stopping` immediately clears frame evidence. `stopped` requires the backend to finish camera teardown, clear its frame cache, cancel connections and observe listener cancellation. It does not assert a physically observed camera indicator.

An idle parent has **10 seconds** to prepare. After preparation, the monotonic lease is **6 seconds**; only a fresh accepted Renew extends it. Prepare, Start, Status, rejected requests and duplicate Renew do not extend it. A 100 ms control-queue timer enforces these deadlines independently of camera work. The intended future parent cadence is one renewal every 2 seconds.

EOF, SIGTERM/SIGINT/SIGHUP, explicit Stop, lease expiry, listener/capture errors or a broken output channel all revoke the session and begin teardown. Teardown has a **2 second** grace period. If the backend has not acknowledged completion, the helper emits `error / shutdownUnconfirmed` if stdout is available and exits 3; it does not emit a false `stopped` receipt. Normal acknowledged Stop/EOF/signal exits 0, and other acknowledged failures exit 2. All exit paths close this process's resources; a later physical test must establish camera-indicator behavior and measured timing.

## Snapshot HTTP

Managed mode binds the explicit port to `127.0.0.1` only. Every GET, including `/health`, requires `Authorization: Bearer <snapshotToken>`. Duplicate headers, request bodies, unsupported methods and malformed headers are rejected; URL tokens are not accepted. Requests remain bounded to 4 KiB, four connections and a three-second per-connection lifetime.

Authenticated responses include:

```text
X-Mesh-Camera-Session: <sessionID>
X-Mesh-Camera-Generation: <generation>
X-Mesh-Camera-ID: <cameraID>
X-Mesh-Station-Epoch: <stationEpoch>
Cache-Control: no-store
```

`/health` returns JSON with `ready`, `captureActive`, and `fresh`. In managed mode, a prepared listener can return HTTP 200 with captureActive/fresh false; this allows the future parent to verify the forwarding endpoint before requesting capture. HTTP success alone is not camera readiness.

`/snapshot.jpg` returns a memory-only JPEG only while capture is active and the actual sample timestamp is between 0.5 seconds future and 3 seconds old. It includes the existing `X-Mesh-Captured-At` header with fractional seconds. Otherwise it returns 503. The helper retains at most one bounded 4 MiB JPEG and does not write frames to disk. Unauthenticated responses contain no camera identity headers.

## Verification and remaining integration

Run `python3 -m unittest discover -s tests -p test_mesh_snapshot_managed.py -v` on macOS. It compiles the real helper and the same controller with a fake backend. Tests cover inert construction, prepare/start separation, duplicate starts, wrong tuples/tokens, renewal expiry, EOF in each state, late completion, stalled teardown, output loss, invalid setup, bounded framing and HTTP authentication. Real helper subprocesses receive only empty EOF or invalid input; they never prepare a listener, initialize a camera, query/request TCC, invoke SSH, or play audio.

Still required before optional M1 acceptance: the Station-owned child/lease integration and Dark/lock gates; private control bridge; owned authenticated SSH forward; typed M4 client headers and source matching; app Stop/Pause/Night/Quit drain; exact helper packaging/signing and attended Camera permission; correct Alloco selection; actual preview/camera-indicator and failure-path testing. None is implied by these component tests.

## Station owner and bridge — source-only integration

`ops/mesh_monitor_m1_camera_station.py` is an inert import attached by the existing receiver. It does not register a daemon, adopt another process, enumerate cameras, or automatically start capture. A configured Station owns one exact managed helper process and serializes Prepare, Start, renewal and privacy revocation through its existing `Station.lock`. The control socket carries lifecycle messages only; images remain on the authenticated loopback HTTP path above.

Setup is explicitly optional. The receiver attaches only when `~/.config/mesh-monitor/camera-station.json` exists. That file must be owner-only mode 0600, regular, single-link, at most 4096 bytes, beneath the same user's private mode-0700 directory without symlink traversal. Missing setup leaves the camera integration disabled and creates no directory or socket. Configuration has exactly these fields:

```json
{"schema":"mesh.m1-camera-station.v1","helperExecutable":"/absolute/path/to/managed-helper","helperSHA256":"<64 lowercase hex characters>","cameraID":"<explicit external camera ID>","port":18495}
```

The helper must be an owner-controlled, non-group/world-writable executable with the exact configured SHA-256; its path is checked again immediately before launch. Only `[helperExecutable, "--managed"]` is launched, through retained `Popen` ownership and private stdin/stdout pipes. Neither token enters argv or logs. No child is launched until an eligible explicit Prepare. Start remains a separate authenticated command after `listenerReady` and the M4's authenticated health check.

The Station binds `~/.config/mesh-monitor/camera-control.sock` at mode 0600 in that private directory. Both peers check the local socket peer's UID. Existing paths are refused rather than adopted or removed; cleanup removes only the socket inode this server bound. At most four control connections and 16 KiB of queued output per connection are retained. `--bridge` is a bounded stdio relay to this socket, accepting an inherited FIFO for stdin. The M4's static remote command is:

```text
/usr/bin/python3 ~/AIYStation/mesh_monitor_m1_camera_station.py --bridge
```

Each new control connection first receives one bounded hello, before any Prepare:

```json
{"schemaVersion":1,"event":"stationHello","stationEpoch":"<fresh UUID>","mode":"desktop","eligible":true,"cameraID":"<configured ID>","port":18495,"reason":"ready"}
```

The fields shown are exact. `stationEpoch` changes on each new Station owner; the M4 must echo it and compare camera ID and port with its own explicit configuration. `eligible` requires Desktop plus a fresh successful console-session probe reporting unlocked. Ineligible hello reasons are `stationDark`, `stationMode`, `consoleLocked`, `sessionProbeUnavailable`, or `stationShutdown`. A unavailable/missing bridge emits `error / configurationUnavailable` without identity; it cannot supply a valid hello or start capture.

After hello, commands are exactly the helper commands documented above. The owner pins the initiating connection, sessionID/generation/epoch/cameraID, control token and separate snapshot token. A different connection cannot operate an existing session. A duplicate Prepare neither creates a second child nor renews the lease; a retired tuple cannot automatically reopen. There is no reconnect adoption or restart. A new explicit attempt requires a new session/generation. The last 128 retired tuples are retained in memory.

Station ownership adds a monotonic six-second lease with strictly increasing renewal sequences, independently of the helper's identical lease. Prepare and each Start/Renew check Desktop and a fresh unlocked session under the same lock used by mode changes. Dark, private cover, lock, failed session probe, receiver shutdown, control EOF/backpressure, and lease expiry revoke capture. Returning to Desktop does not reopen it. Receiver hooks revoke before the already-converged private-cover early return, preventing a managed child from surviving an otherwise dark-looking state. A camera/HUD transition waits for the managed child to leave before starting a legacy camera source.

Revocation sends the authenticated Stop, closes only that child's stdin, and clears frame evidence immediately. The owner waits up to two seconds, then terminates the retained child, then after 250 ms kills that same retained child. After a further 250 ms, a surviving child produces `shutdownUnconfirmed`; ownership remains retained and a new child cannot start. Private-cover convergence also remains false while it survives. The shutdown path never looks up a PID, kills by name, or stops an unrelated camera/service.

Forwarded receipts use the helper fields above. `stopped` is forwarded only from the authenticated owned child after its teardown acknowledgement. Ownership is still retained until the child actually exits. `childExited` is a separate Station event with reason `childExited`, state `stopped`, false capture/frame flags, the exact identity and an integer `exitCode`. Exit alone is **not** a camera teardown acknowledgement. The bridge drains an already-queued final receipt for up to one second if its server closes; a disconnected M4 cannot assume it received that receipt.

Station error/revocation reasons, in addition to helper reasons already listed, are `stationEpochChanged`, `sourceMismatch`, `sessionBusy`, `sessionRetired`, `helperUnavailable`, `helperProtocol`, `childWriteFailed`, `parentBackpressure`, `privateCover` and the hello reasons above. State names remain `idle`, `preparing`, `prepared`, `starting`, `capturing`, `stopping`, `stopped`. Reasons are fixed codes, never raw subprocess diagnostics or tokens.

`ops/mesh_monitor_m1_camera_patch.py` prepares an offline candidate against the exact **return-patched** saved receiver, SHA-256 `7a75c92c5766c8a14d234b6d75563b4c23e63c08ae0c1da3397ebad7c3278683`. It accepts its own exact output idempotently, rejects unrelated source, prints a diff by default, and optionally writes a new exclusive candidate file. It does not modify the original receiver, install anything, restart Station, or contact a remote host.

Sensor-free verification commands:

```text
python3 -m unittest discover -s tests -p test_mesh_m1_camera_station.py -v
python3 -m unittest discover -s tests -p test_mesh_m1_camera_patch.py -v
```

These fixtures substitute fake child processes and sockets; no helper, listener, SSH, TCC or sensor is activated. Patch fixtures compile and execute the actual composed receiver methods against a fake Station, including concurrent Start versus Dark under its real lock, lock/probe-failure reconciliation, private-cover failures, shutdown, stalled child, replay, output loss and explicit setup. This establishes source composition and component lifecycle behavior only. Deployment of the exact receiver/module/helper/config, signing/TCC identity, actual M1 camera selection, authenticated forwarding, and attended camera-indicator/Dark/Pause/Quit acceptance remain separate integration work.

## M4 source candidate and app controls

`MeshM1CameraRuntime.swift` owns one retained `MeshM1CameraSSH` transport. Construction, loading saved setup and ordinary app launch are inert. Explicit Start checks the fixed `mesh-m1` station hello against the selected device and ports, pins its epoch, prepares the helper and verifies an authenticated prepared health response before sending Start. It renews the monotonic lease every two seconds. A bounded MainActor inbox preserves receipt/exit ordering and fails closed on overflow.

`helperStarted` enters an awaiting-frame state. The matching helper `firstFrame` receipt starts HTTP polling so a request cannot race an empty initial cache. Only `MeshCameraPresence.onManagedFrame`, after authenticated identity checks, bounded JPEG decode and repeated freshness checks, marks the runtime running. Both the worker and main-actor publication reject stale, missing, repeated or wrong-session frames. A managed-input failure revokes this optional input; it does not pause the M4 screen trial.

The Inputs page distinguishes managed Start/Stop from the advanced manual image URL. Managed source controls cannot change during connection or shutdown. Explicit setup saves only the fixed host alias, camera ID and two ports to the owner-private `m1-camera-setup.json`; no credentials or image data are saved. Room/Both in Conversation remains the explicit sharing choice.

Stop, Pause, Night, switching the morning trigger away from camera arrival, and Quit revoke frames and request exact-session camera shutdown. Quit drains camera and wake cleanup concurrently under the existing outer deadline, with separate outcomes. A matched stopped acknowledgement is distinct from child exit and from a locally closed importer; unconfirmed remote shutdown is retained in runtime status and readiness.

Source-only Swift verification (fake subprocesses and URLProtocol interception, no real network or sensors):

```text
PYTHONPATH=tests python3 -m unittest test_mesh_m1_camera_runtime test_mesh_m1_camera_ssh test_mesh_managed_camera test_mesh_camera_presence test_mesh_focus_gaze_context test_mesh_termination -v
```

The six Swift fixture groups passed together in 33.219 seconds. They include retained-child cancellation, startup and health races, final acknowledgement ordering, malformed/oversized responses, image identity/freshness/replay, and parallel bounded cleanup. These results do not establish physical camera release or an attended integrated M1 session.

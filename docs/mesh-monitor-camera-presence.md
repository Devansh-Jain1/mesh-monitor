# Mesh Monitor camera and local presence

This document describes the original camera/import component. For current
NeoCursor producer integration and the remaining physical/M1 boundaries, see
[the capability audit](../ops/mesh-monitor-capability-audit.md). Its older
importer-only statements do not describe the managed schema 2 eye tracker.

This module is component implementation, not proof of a live M1 feed, gaze accuracy,
camera permission, or a physically heard greeting. No camera/helper/model/service was
launched to develop or test it. The current overnight baseline is **camera and
microphone off**; an explicit morning Return/Home trigger is owned by the parent app.

## App interface

`ops/work_mac_copilot_app/MeshCameraPresence.swift` contains an inert `@MainActor`
`ObservableObject`. The UI calls `availableDevices()` for exact IDs and explicitly
calls `start(source: .native(deviceID:))` or `.snapshot(url:)`. A missing chosen
device never falls back to another camera. Permission is checked, never requested.
`stop()` drops previews and invalidates callbacks immediately, then closes capture
and network resources on their serial queue. The parent must call it on quit/pause.

Published state: `state`, `detail`, `isRunning`, `preview`, `lastFrameAt`,
`lastReceivedAt`, `freshness`, and `presence`. Native Vision detects face/person
presence locally at up to two analyzed frames per second. This does not identify a
person, detect waking, infer emotion, or constitute NeoCursor tracking.

`arm(sessionID:alreadyGreeted:requiresArrival:)` enables an optional camera-triggered
morning session. The default requires one second of observed absence after arm,
then at least three high-confidence presence samples spanning 1.2 seconds. Unknown,
old, future, duplicate, and reordered capture timestamps do not contribute. A
three-second gap resets dwell. `onGreetingRequested(UUID)` fires once per session.
The parent must persist that receipt **before** audio playback, restore
`alreadyGreeted` after restart, and own target date/armed/pause/plan state. Repeated
arm of an already delivered ID is suppressed within the process. This callback
contains no plan, identity, spoken text, or Codex call.

## M1 image transport

Remote images must be an explicit supplied HTTP(S) JPEG/PNG endpoint. The importer
does no discovery, camera activation, cookies, credential reuse, image upload, or
disk recording. Redirects are rejected. Responses are limited to 4 MiB and decoded
at at most 960 pixels. A single polling request is in flight at once; ordinary
cadence is one second. The endpoint needs:

```
Content-Type: image/jpeg
Cache-Control: no-store
X-Mesh-Captured-At: 2026-09-19T08:00:00.123Z
```

The header is the source's actual capture time, not request time. Missing timestamp
allows a visibly **unverified preview only**, never a morning trigger. Freshness
requires clocks within 0.5 seconds into the future / 3 seconds old. Source/operator
integrity and clock synchronization remain deployment prerequisites.

`ops/mesh_monitor_camera_snapshot.swift` is a new optional transport helper. It is
not installed or launched. It accepts only an explicit external device ID and
`--arm`, requires existing Camera permission, binds **127.0.0.1 only**, and holds a
single latest JPEG in memory. `/snapshot.jpg` returns the capture header and `/health`
returns whether a frame is fresh. No remote/public listener, recording, upload,
automatic startup, or built-in-camera fallback is provided.

Setup, only when the user is present and explicitly choosing camera operation:

1. Build/sign/package the helper on the intended host with Camera usage description
   and verify its camera permission. A command-line compile alone does not establish
   its TCC identity or permission. Source typecheck command:
   `xcrun swiftc -typecheck -parse-as-library -target arm64-apple-macosx14.0 ops/mesh_monitor_camera_snapshot.swift`.
2. Enumerate with `--list-devices`; identify the non-IR **CODi A05023 Alloco Webcam**
   by the actual returned ID. Do not infer it from the first external device.
3. Explicitly run `--device-id EXACT_ID --port CHOSEN_PORT --arm` on the M1.
4. Use an authenticated SSH local tunnel to that **M1 loopback** port, then enter
   the tunnel's actual local `/snapshot.jpg` URL in Monitor. The helper itself does
   not install/open a tunnel, read keys, or launch an M1 sensor remotely.
5. Verify live preview, capture age, and stop behavior while physically present.
   Ctrl-C exits the helper; stopping the M4 importer does not remotely stop an M1
   helper the user separately started. The M1 camera indicator must be checked.

The existing M1 station is a separate owner of `dark`, `camera`, and `hud`. This
helper does not bypass or synchronize that owner's switch. Integrating station
dark/quit with helper termination is required before persistent deployment; do not
run it overnight or represent it as dark-aware today.

## Gaze and NeoCursor

Two explicitly distinct paths exist:

* **Experimental native Vision gaze.** `beginNativeGazeCalibration(displayID:)`
  produces `nativeGazeTarget` (normalized display coordinates, top-left origin).
  The parent draws that point on the named **physical display**, not in a scaled
  preview. After looking at each point for two seconds, the user invokes
  `recordNativeGazeTarget()`. Four fresh visible-pupil samples spanning 1.2 seconds
  are required per target. Five points fit an affine transform; two held-out points
  must each be within 0.15 normalized screen units. Degenerate fits, unstable eyes,
  multiple faces, absent pupils, and stale frames fail closed. `nativeGazePoint` is
  an approximate region, not pixel targeting. `cancelNativeGazeCalibration()` and
  camera stop discard calibration. Changing camera placement/posture/display needs
  recalibration. There are no cursor or click actions.
* **NeoCursor observation import.** `startNeoCursorImport(fileURL:cameraID:displayID:calibrationID:)`
  polls an explicitly selected owner-private regular JSON file at 10 Hz;
  `stopNeoCursorImport()` stops it. Symlinks, FIFOs, wrong owner, group/world-readable
  files, and files over 8 KiB are rejected. The adapter must atomically replace its
  latest-value file. No NeoCursor process is launched or upstream source copied.

Example adapter schema (values are illustrative, not live observations):

```json
{"schemaVersion":1,"source":"neocursor","capturedAt":"2026-09-19T08:00:00.123Z",
 "cameraID":"explicit-camera-id","displayID":"explicit-display-id",
 "calibrationID":"attended-calibration-id","calibrated":true,
 "x":0.5,"y":0.5,"confidence":0.9}
```

IDs must match the explicitly configured setup; confidence >=0.7 and capture age
<=1 second are required. Raw iris/face coordinates must not be relabeled as
calibrated screen coordinates. The existing station tracker emits schema 2 raw
pupil observations into an owner-private FIFO. Monitor must **not** attach a second
reader to that FIFO, which could steal input from its existing consumer. An actual
NeoCursor export producer is still absent; the UI must distinguish imported data,
native experimental tracking, and unavailable states.

Read-only upstream review on 2026-09-19: [NeoCursor package metadata](https://github.com/YehyunLee/NeoCursor/blob/main/package.json)
declares ISC, while the [root file listing](https://github.com/YehyunLee/NeoCursor)
does not show a root license text. No derived NeoCursor source was copied. Its
documented head/cursor movement is not proof of calibrated gaze accuracy.

## Verified readiness and physical gates

Read-only M1 preflight on 2026-09-19 via the existing `mesh-m1` alias found station
schema 2 **dark / inactive**, no Photo Booth/NeoCursor/StationHandTracker/snapshot
process, and no hand-control enable sentinel. `NeoCursor.app` was absent from both
Applications folders. The system VDCAssistant process alone does not identify a
camera-consuming application or prove a user-visible indicator is on/off.

M1 default output and system output were **MacBook Pro Speakers**, output volume
56, unmuted. Existing `~/AIYStation/m1_voice_output.py` was running and offers
authenticated `POST /v1/speak` for text (<=1000 characters), not incoming WAV. It
selects the configured output and volume before playback, but calls its configured
TTS URL for synthesis, so it is not an offline-local synthesis proof. The parent
owns explicit audio route/volume changes and a physically heard test.

## M1 playback of locally generated Kokoro speech

`ops/work_mac_copilot_app/MeshM1AudioOutput.swift` exposes `play(url:) async throws`
and `stop()`. The parent explicitly chooses this output instead of M4 playback.
The builder bundles `ops/mesh_monitor_m1_audio_receiver.py`. That fixed source is
sent over the existing host-key-checked `mesh-m1` SSH alias, with original WAV bytes
on stdin; no script installation, network server, API token, or remote synthesis
is needed. All shell-variable fields are generated UUID, byte count, or fixed
base64 source, never user speech. SSH connect timeout is eight seconds; the whole
job is capped at 150 seconds and each WAV at 120 seconds / 12 MiB.

On an explicit playback request, the receiver invokes the existing M1
`~/AIYStation/station-audio-output` selector for exactly **MacBook Pro Speakers**,
sets the user-requested output volume to 100/unmuted, then reads actual CoreAudio
default and system output identities plus volume to verify both before playback.
It monitors route changes while its `afplay` child runs. Headphones or an unknown
route fail closed. SSH stdin EOF / Stop / timeout terminates only that invocation's
owned player and removes its private temporary WAV. It does not stop other audio
apps. It does not restore the preceding output volume after playback.

A remote **read-only** `probe` of this receiver's real CoreAudio implementation
returned MacBook Pro Speakers for both device roles, volume **56**, muted false.
The `play` path and volume-100 change have not been physically exercised by this
worker. A later live app test stopped before playback because the deployed
`station-audio-output` is a silent shell guard, unlike the older native helper's
printed receipt. The receiver now accepts its exit status and still requires
independent CoreAudio device verification; stdout can never substitute for route
proof. A read-only `check` request transferred and validated a 524-byte, 10 ms PCM16
fixture and read the real device/volume without selecting output or playing audio.
Whitelisted receiver failure codes now reach the UI instead of collapsing to a
generic route error. Successful SSH receipt is process evidence; the user must hear the result
from the intended M1 speaker before audio acceptance.

Physical prerequisites: choose intended date/session; verify named Home-calendar
brief; choose Return/Home or attended-camera trigger; confirm correct Alloco image
and capture freshness if camera chosen; establish calibrated gaze if desired;
verify speech from selected M1 speaker at approved volume; test leave/return,
pause/restart suppression, offline/stale plan and camera failure, and late-result
discard. Manual Start morning is a fallback, not camera-detection evidence.

## Validation

`python3 -m unittest discover -s tests -p test_mesh_camera_presence.py -v`
compiles and executes a small macOS Swift harness. It exercises genuine reducer
behavior (arrival, debounce, duplicate/restart suppression, stale/future/pre-arm
frames), gaze identity/freshness, affine/degenerate calibration, and private-file
input checks. No test instantiates a capture worker, opens a network listener,
asks for a permission, or launches a model/app. Both Swift sources separately
typecheck for macOS 14. Physical accuracy, latency, RAM, and audible behavior remain
unmeasured.

`python3 -m unittest discover -s tests -p test_mesh_m1_audio_receiver.py -v` passed
eleven mocked behavioral tests for WAV validation, route and volume rejection,
pre-play cancellation, own-player interruption, output-route changes, EOF stop,
completion receipts, temporary-file cleanup, silent deployed selector behavior,
and selector diagnostics. `MeshM1AudioOutput.swift`
separately typechecks for macOS 14. These tests do not play or change audio.

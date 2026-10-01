# NeoCursor observation overlay: pinned source seam

This adapter stages original Mesh code into `.mesh-observer` inside an explicitly
supplied clean NeoCursor checkout. The observer reuses that checkout's local
MediaPipe FaceMesh JavaScript, model data, and SIMD WASM. This repository does not
redistribute NeoCursor source or MediaPipe assets. Patching performs no download,
dependency installation, Electron launch, camera capture, microphone capture,
audio playback, or service/listener setup.

The supported upstream revision is
`986db45663cf37b6e47e5e355fa1e9ce0d05de76` from
[YehyunLee/NeoCursor](https://github.com/YehyunLee/NeoCursor/tree/986db45663cf37b6e47e5e355fa1e9ce0d05de76).
The pin's `package.json` declares ISC, but the inspected root tree had no separate
LICENSE file. Keeping the overlay original and referencing a user's own checkout
avoids bundling those upstream files; this is not a license determination for a
future redistributed application.

## Why a separate Electron entry

Simply adding an `onResults` callback to upstream `renderer.js` would leave other
effects running. At this pin:

- `main.js` imports `server`, speech handlers, cursor monitor, and optional
  `robotjs` before window construction. Its `app.whenReady` section starts the
  cursor helper and cursor monitor and creates both legacy windows.
- `main.js` uses `preload.js`, then loads `http://localhost:3000`; its IPC includes
  cursor movement, clicks, scroll, keyboard/text actions, and speech controls.
- `renderer.js`'s `onResults` callback feeds legacy landmark and blink handling.
  Its initialization block also schedules speech startup after 1.2 seconds.
- `index.html` loads `mediapipe/camera_utils.js` and `mediapipe/face_mesh.js`.
  The FaceMesh constructor resolves supporting assets beneath
  `mediapipe/face_mesh/`. The pin contains SIMD assets and no non-SIMD fallback.

The overlay's own `package.json` sets `main` to `observer-main.cjs`. An explicit
Electron invocation targets `.mesh-observer`, so no legacy main, preload,
renderer, server, speech handler, cursor helper, or cursor monitor is executed.
The only reused runtime is the pinned local FaceMesh dependency. Mesh's renderer
owns the explicit camera selection/start, FaceMesh callback, and calibration flow.

## Inputs and integrity

`patcher.py preflight --checkout /absolute/path/to/NeoCursor` is read-only. It
requires the exact Git root and HEAD, a clean worktree outside `.mesh-observer`,
the six pinned source SHA256 values, and all seven asset size/Git-blob identities.
Source paths must not traverse symlinks, and inspected files must be owner-owned,
regular, single-link, and within bounded sizes. Git runs with hooks and fsmonitor
disabled. Missing files, an unavailable runtime, or a different revision are not
silently downloaded or substituted.

`patcher.py apply --checkout /absolute/path/to/NeoCursor` runs the same checks,
then stages exactly these original files from the adapter directory:

- `observer-main.cjs`
- `observer-preload.cjs`
- `observer-renderer.js`
- `observer.html`
- `calibration.cjs`
- `publisher.cjs`

It generates the independent `package.json` and `manifest.json`. The manifest
records the absolute upstream path, revision, source SHA256 values, asset SHA256
and Git-blob identities, absolute FaceMesh script/asset paths, and original glue
SHA256 values. Every staged file is mode 0600 inside a mode 0700 directory.

`READY` is written and synced last and contains SHA256 of the exact manifest
bytes. The observer must refuse startup unless that value matches. Interrupted
staging can leave an unready directory; the patcher never overwrites an existing
overlay, including one left by failure. Upstream tracked files are never edited.

The JSON result provides the explicit later launch argument vector:

```text
/absolute/path/to/NeoCursor/node_modules/.bin/electron
/absolute/path/to/NeoCursor/.mesh-observer
```

This launch must target the overlay directory. Do not use upstream `npm start`,
`npm run dev`, `electron .`, or upstream `main.js`: those are the legacy control
application. No command here installs dependencies or performs this launch.

The overlay is a local display/camera baseline. Presence or iris geometry alone
does not prove attention, emotion, understanding, calibrated gaze, or accuracy.
Only an explicit completed calibration and measured holdout validation can admit
schema-2 gaze observations; the publisher/importer enforce their own freshness,
identity, consent, and validation contract.

## Offline verification boundary

Run the synthetic patcher suite with:

```sh
python3 -m unittest discover -s ops/neocursor_mesh_adapter -p test_patcher.py -v
```

Fixtures build a separate temporary Git history and inject its own pin and
catalog. They contain inert placeholder source and assets, not NeoCursor code.
They cover clean preflight, source/asset mismatch, dirty custody, file modes,
original-only staging, no-overwrite behavior, symlink/hardlink rejection,
interrupted publication, fsync failure, and fsmonitor suppression. These tests
are not real upstream asset preflight, engine initialization, camera/gaze proof,
or attended calibration evidence.

During initial development, six public source files were fetched read-only to
`/private/tmp/mesh-neocursor-upstream-986db456` for seam inspection. That directory
is not a Git checkout and lacks the model/WASM assets, so it cannot pass actual
patcher preflight or serve as a launchable observer runtime. Source and asset
identities are recorded in `patcher.py`; the public pinned Git tree supplied the
asset identities without downloading the model data. A later clean checkout at
`/private/tmp/mesh-neocursor-pinned-checkout` includes the actual pinned assets and
passed the real preflight. No dependency installation or engine launch occurred.

The original UI and engine assets use the same `mesh-observer://ui` origin with
`corsEnabled: false` on the supported patched runtime. This accommodates the pinned loader's script, XHR and
fetch requests. The pinned Emscripten runtime needs `unsafe-eval` for its local
generated functions; the resource handler serves only manifest-verified local
files and rejects external network requests. Offline checks exercise these routes;
they do not prove actual Chromium/FaceMesh initialization.

The maintainer's September 3 correction to the CORS advisory states that
`corsEnabled: true` permits cross-origin reads and is not a mitigation. The prior
overlay used that flag; the managed adapter corrects it and requires Electron
41.4.0 or later within 41.x. It still loads only original UI and pinned local
engine assets and denies external navigation/requests.

## Native ownership

Mesh Monitor's explicit Open eye tracker action launches the reviewed executable
with the overlay path followed by `--mesh-managed`. This mode requires a real
inherited stdin pipe. Its only commands are bounded `stop` and `quit`; no parent
command can open a camera. Parent EOF/error, SIGTERM and app quit stop capture,
clear calibrated output and exit. Native status lines contain bounded lifecycle
metadata, including whether a frame was actually observed, never landmarks.
The native manager verifies its private configuration, the pinned executable
hash and the overlay against the bundled adapter files. This is not a claim of
whole Electron-framework attestation or calibrated gaze accuracy.

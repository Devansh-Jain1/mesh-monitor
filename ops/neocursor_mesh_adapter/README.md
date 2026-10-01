# Mesh Monitor · eyes in context

This is the original Mesh observation adapter, bundled with Mesh Monitor 0.5.3.
It uses the pinned NeoCursor checkout's local FaceMesh assets for eye landmarks.
It publishes calibrated coordinates to Mesh; it does not move the cursor,
record audio, speak, or read your screen.

## Current readiness

The calibration, publisher, native importer and managed lifecycle have sensor-free
tests. A separately prepared runtime supplies Electron and the pinned FaceMesh
assets; the native app checks its setup when you select Open eye tracker.
The runtime is not bundled in the app and nothing starts automatically.
The prepared Electron 41.4.0/FaceMesh engine passed a hidden test using one generated
blank image with all device permissions denied; this verifies engine initialization
and processing, not camera capture or actual gaze accuracy.
Attended camera calibration and actual gaze accuracy still require a live check.

## Use from the app

1. Open **Inputs → Open eye tracker**. It opens the prepared local observation
   mode with its camera off. Setup errors appear in Mesh Monitor.
2. In the tracker, press **Refresh choices**, choose your camera and display,
   then **Start chosen camera**. There is no automatic camera or microphone start.
3. Press **Calibrate eyes** and complete seven targets. Five fit the mapping;
   two independently measure error. Failed validation cannot publish gaze.
4. Return to Mesh Monitor and select **Use calibrated gaze**. You do not need
   to find a file. The room camera may remain off. **Screen** or **Both** adds
   fresh gaze to the evidence you choose for your questions.

**Stop tracker**, **Pause all**, **Night**, and quitting Mesh Monitor close the
tracker started by the app. The parent pipe closing also ends that tracker.
Closing may briefly show Stopping while the app waits for actual process exit.
**Stop import** disconnects observations only. A tracker launched separately
must be stopped in its own window. Moving camera, posture or display requires
calibration again.

## Prepare the tracker

Use a clean, local checkout of
[NeoCursor revision 986db456](https://github.com/YehyunLee/NeoCursor/tree/986db45663cf37b6e47e5e355fa1e9ce0d05de76).
The adapter checks the revision and every required source/model asset. A supported
Electron runtime must be supplied separately; the pinned upstream package declares
`^41.0.2`. Use Electron 41.4.0 or later within 41.x for this baseline, incorporating
the maintainer's [custom-protocol CORS fix](https://github.com/electron/electron/security/advisories/GHSA-v3j7-r9gq-3gjw).
Dependency installation is not performed by the adapter.

Run the bundled `patcher.py` with Python 3.10 or later, supplying the absolute
checkout path:

```sh
python3 patcher.py preflight --checkout /absolute/path/to/NeoCursor
python3 patcher.py apply --checkout /absolute/path/to/NeoCursor
```

`apply` writes a new private `.mesh-observer` folder only. It never changes
tracked upstream files, replaces an existing overlay, installs dependencies or
starts the tracker. Its JSON result includes `electronAvailable` and `launchArgv`.
When the runtime is ready, launch Electron with **the `.mesh-observer` directory**
as its application argument. Do not launch the legacy upstream application:
its speech and cursor startup are outside this observation mode.

## External tracker compatibility

1. In observation mode, press **Refresh choices** to allow camera enumeration.
   Choose a camera and the display you will look at.
2. Press **Start chosen camera**. The preview begins only after that explicit
   action. There is no automatic camera selection or microphone capture.
3. Press **Calibrate eyes**. Look at each target and wait for enough stable
   samples before saving it. Five targets fit the mapping; two measure error
   independently. Failed validation cannot publish calibrated observations.
4. In Mesh Monitor, expand **Inputs → Tracker identifiers → Import external observation** and choose:
   `~/Library/Application Support/MeshMonitor/neocursor/observation.json`.
   Your room camera can remain off. The selected display must match.
5. Choose **Screen** or **Both** when asking about the thing you are looking at.
   Freshness, display geometry and validation travel with your original question.

Use **Stop everything** in a separately launched observer to close its camera and
remove its latest observation. Mesh Monitor cannot close a tracker it did not
start. There is no background autostart or reconnect.

Gaze is an approximate screen region. It does not establish attention, emotion,
understanding, or whether an activity is relevant to your task.

See `upstream-seam.md` for the source boundary and integrity checks.

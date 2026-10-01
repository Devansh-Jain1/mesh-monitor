'use strict';
const api = window.meshObserver;
const byID = id => document.getElementById(id);
const video = byID('preview');
let stream, tracker, epoch = 0, capturedAt = 0, actualCamera = '', running = false, packetPending = false;
let starting = false, choosing = false, choicesEpoch = 0;
let latestState = {}, targetReadyPending = false;
let placementStartedAt = 0, placementIndex = -1, placementFailed = false;
function status(message) {
  for (const id of ['status', 'instruction']) if (byID(id).textContent !== message) byID(id).textContent = message;
}
const readinessMessages = Object.freeze({
  'camera-off': 'Camera off. Choose a camera and display, then start when you are ready.',
  'waiting-frame': 'Camera started. Waiting for a processed camera frame.',
  'no-face': 'No face found. Face the chosen camera and check the preview and lighting.',
  'multiple-faces': 'More than one face found. Keep only your face in the camera view.',
  'eyes-unavailable': 'Eye landmarks are not usable yet. Keep both eyes visible and adjust the camera or lighting.',
  'ready-to-calibrate': 'Eyes are visible. Select Calibrate eyes to set up this display.',
  'placing-target': 'Placing the target on your chosen display. Keep looking at the dot.',
  'collecting': 'Keep looking at the dot and hold still. After two seconds, press Space to save this target.',
  'validated': 'Calibrated coordinates are available. Return to Mesh Monitor and select Use calibrated gaze.',
  'projection-unavailable': 'Calibration passed, but no usable screen coordinate is available. Look at the chosen display; recalibrate if your setup moved.',
  'stale-frame': 'Waiting for a fresh frame from the chosen camera. No current coordinates are shared.',
});
const calibrationMessages = Object.freeze({
  'target-not-active': 'Wait until the target is placed on the chosen display.',
  'need-12-fresh-samples': 'Not enough usable eye samples yet. Keep looking at the dot, then press Space again.',
  'need-1200ms-span': 'Hold your gaze on the dot for at least two seconds, then press Space again.',
  'latest-sample-stale': 'The latest eye sample is too old. Wait for fresh tracking before saving this target.',
  'unstable-eye-features': 'Eye samples moved too much. Keep your head still and retry this target.',
  'degenerate-calibration': 'The eye samples could not reliably distinguish the targets. Adjust your setup, then restart calibration.',
  'missing-calibration': 'The calibration fit is unavailable. Restart calibration.',
  'held-out-error': 'The accuracy check failed. Eye detection worked, but the screen mapping was not accurate enough. See Calibration results below before retrying.',
  'focus-lost': 'Calibration stopped because its window lost focus. Return here and restart calibration.',
});
function readinessMessage(value) {
  if (value.readinessCode === 'eyes-unavailable' && value.featureIssue) {
    const reasons = {
      'iris-missing': 'The tracker returned no refined iris landmarks. This is an engine/setup failure; calibration cannot start.',
      'face-outside-frame': 'Some face landmarks fall outside the camera frame. Center your whole face and move slightly back.',
      'eye-size': 'Eye landmarks are too small or distorted. Adjust camera distance and face it directly.',
      'eye-opening': 'The eye-opening filter rejected this frame. Face the camera with eyes comfortably open; glasses, lighting or a too-strict filter may be involved.',
      'iris-position': 'The iris estimate is outside the usable eye region. Face the camera and check lighting.'
    };
    if (reasons[value.featureIssue]) return reasons[value.featureIssue];
  }
  const message = readinessMessages[value.readinessCode];
  const issue = calibrationMessages[value.calibrationIssue];
  return [message, issue].filter(Boolean).join(' ');
}
function diagnosticText(attempt) {
  const q = attempt.quality || {};
  let text = `Target ${attempt.targetNumber} · ${attempt.kind === 'held-out' ? 'accuracy check' : 'training'} · ${attempt.ok ? 'saved' : calibrationMessages[attempt.reason] || attempt.reason}\n`;
  text += `${q.samples || 0} usable samples; ${((q.spanMs || 0) / 1000).toFixed(1)} seconds collected. `;
  if (typeof q.stdX === 'number') text += `Eye-signal variation: ${q.stdX.toFixed(4)} horizontal, ${q.stdY.toFixed(4)} vertical (limit ${q.maxStd}). `;
  const a = attempt.accuracy;
  if (a) {
    text += a.predicted ? `\nPrediction missed horizontally by ${(Math.abs(a.predicted.x - a.target.x) * 100).toFixed(1)}% of screen width and vertically by ${(Math.abs(a.predicted.y - a.target.y) * 100).toFixed(1)}% of screen height. Combined normalized error ${a.error?.toFixed(3)}; allowed ${a.limit}.`
      : '\nThe fitted mapping produced an invalid position.';
    text += '\nThis does not identify the cause. Face tracking noise, head movement, or the mapping itself may be responsible. Look at the dot while pressing Space (do not look down at Save). Keep the camera and posture unchanged. If it repeats, stop retrying and share these results.';
  }
  return text;
}
function displayState(value) {
  latestState = value;
  const attempts = value.calibrationAttempts || [];
  if (attempts.length) {
    byID('diagnostics').textContent = attempts.slice().reverse().map(diagnosticText).join('\n\n');
    byID('diagnostic-json').value = JSON.stringify({schema: 'mesh.calibration-diagnostics.v1', attempts}, null, 2);
  }
  if (!value.calibrating) { placementStartedAt = 0; placementIndex = -1; placementFailed = false; }

  const busy = running || starting || choosing;
  byID('start').disabled = busy || !byID('camera').value || !byID('display').value; byID('stop').disabled = !busy;
  byID('calibrate').disabled = !running || value.calibrating || (!!value.readinessCode &&
    !['ready-to-calibrate', 'validated', 'projection-unavailable'].includes(value.readinessCode));
  byID('camera').disabled = busy; byID('display').disabled = busy; byID('refresh').disabled = busy;
  byID('output').textContent = value.output || 'Observation file appears after a successful calibration.';
  document.body.classList.toggle('calibrating', !!value.calibrating);
  if (value.target) {
    const rendered = value.renderTarget || value.target;
    byID('target').style.left = `${rendered.x * 100}%`; byID('target').style.top = `${rendered.y * 100}%`;
    byID('progress').textContent = `Target ${value.target.index + 1} of 7 · ${value.target.kind === 'held-out' ? 'accuracy check' : 'calibration'} · ${value.progress?.samples || 0} samples`;
    const q = value.quality;
    byID('collect').disabled = !value.progress?.targetActive || (q && !q.ready);
    byID('collect').textContent = q?.ready ? 'Ready · press Space while looking at the dot' : 'Waiting for steady eye samples';
    byID('quality').textContent = q ? `${q.samples}/${q.minSamples} minimum samples · ${(q.spanMs / 1000).toFixed(1)}/${(q.minSpanMs / 1000).toFixed(1)} seconds · ${q.ready ? 'Ready to save' : calibrationMessages[q.reason] || 'Collecting'}` : '';

    presentTarget();
  }
  const message = readinessMessage(value);
  if (placementFailed) status('The target could not start within 8 seconds. This is a setup failure, not your gaze. Press Escape to leave calibration; no samples were saved.');
  else if (message) status(message);
  else if (value.validated) status('Calibration passed. Current tracking readiness is unavailable from this tracker version.');
}
async function presentTarget() {
  if (targetReadyPending || !latestState.calibrating || !latestState.target || latestState.progress?.targetActive) return;
  if (placementIndex !== latestState.target.index) {
    placementIndex = latestState.target.index; placementStartedAt = Date.now(); placementFailed = false;
  }
  if (Date.now() - placementStartedAt >= 8000) {
    placementFailed = true;
    status('The target could not start within 8 seconds. This is a setup failure, not your gaze. Press Escape to leave calibration; no samples were saved.');
    return;
  }
  targetReadyPending = true;
  const token = epoch, index = latestState.target.index;
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  try {
    if (token === epoch && latestState.calibrating && index === latestState.target?.index) {
      const value = await api.targetReady({index, width: innerWidth, height: innerHeight, focused: document.hasFocus(), viewport: latestState.viewport});
      if (token === epoch) displayState(value);
    }
  } catch (_) {
    // macOS may inset fullscreen content below the camera housing.
    // Refresh verified viewport geometry before painting/acknowledging the target.
    try { const value = await api.bootstrap(); if (token === epoch && value.calibrating) displayState(value); } catch (_) {}
  }
  finally {
    if (token === epoch) {
      targetReadyPending = false;
      // A resize/focus event may have happened while this acknowledgement was
      // pending. Retry after another paint until the chosen full display is ready.
      if (latestState.calibrating && !latestState.progress?.targetActive) {
        requestAnimationFrame(() => { if (token === epoch) presentTarget(); });
      }
    }
  }
}
async function refreshChoices(requestPermission = false) {
  if (running || starting || choosing) return;
  const token = epoch, choiceToken = ++choicesEpoch;
  const current = () => token === epoch && choiceToken === choicesEpoch && !running && !starting;
  if (requestPermission) { choosing = true; displayState(latestState); }
  let failure = null;
  try {
    if (requestPermission) { await api.allowCameraChoices(); if (!current()) return; }
    const bootstrap = await api.bootstrap();
    if (!current()) return;
    const selectedCamera = byID('camera').value, selectedDisplay = byID('display').value;
    byID('display').replaceChildren(new Option('Choose display', ''), ...bootstrap.displays.map(d => new Option(`${d.label} · ${d.id}`, d.id)));
    if (bootstrap.displays.some(d => d.id === selectedDisplay)) byID('display').value = selectedDisplay;
    const devices = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput' && d.deviceId);
    if (!current()) return;
    byID('camera').replaceChildren(new Option('Choose camera', ''), ...devices.map((d, i) => new Option(d.label || `Camera ${i + 1} · ${d.deviceId.slice(0, 10)}`, d.deviceId)));
    if (devices.some(d => d.deviceId === selectedCamera)) byID('camera').value = selectedCamera;
    const needsPermission = bootstrap.cameraPermission && bootstrap.cameraPermission !== 'granted';
    byID('refresh').textContent = needsPermission ? 'Enable camera access' : 'Refresh choices';
    if (needsPermission) failure = 'Camera access is needed to list your cameras. Select Enable camera access.';
    else if (!devices.length) failure = 'No cameras found. Connect a camera, then select Refresh choices.';
    displayState(bootstrap);
  } catch (error) { if (current()) failure = error.message; }
  finally { if (current()) { choosing = false; displayState(latestState); if (failure) status(failure); } }
}
function closeLocal() {
  epoch += 1; running = false; starting = false; choosing = false; packetPending = false; targetReadyPending = false;
  if (stream) for (const track of stream.getTracks()) track.stop();
  stream = undefined; video.srcObject = null;
  const previous = tracker; tracker = undefined;
  try { if (previous) Promise.resolve(previous.close()).catch(() => {}); } catch (_) { /* Tracks are already stopped. */ }
  displayState({captureActive: false, calibrating: false});
}
async function stop(message = 'Camera off. No current coordinates are being shared.') {
  closeLocal();
  const token = epoch;
  try { await api.stop(); } catch (error) { if (token === epoch) status(error.message); return; }
  if (token === epoch) status(message);
}
api.onStop(() => { closeLocal(); status('Tracking stopped. Start explicitly when you are ready.'); });
async function start() {
  if (running || starting || choosing) return;
  const cameraID = byID('camera').value, displayID = byID('display').value;
  if (!cameraID || !displayID) { status('Choose an exact camera and display first.'); return; }
  const token = ++epoch;
  starting = true; displayState(latestState);
  try {
    await api.start({cameraID, displayID});
    if (token !== epoch) return;
    const opened = await navigator.mediaDevices.getUserMedia({audio: false, video: {deviceId: {exact: cameraID}, width: {ideal: 640}, height: {ideal: 480}, frameRate: {ideal: 30, max: 30}}});
    if (token !== epoch) { opened.getTracks().forEach(track => track.stop()); return; }
    stream = opened;
    const track = stream.getVideoTracks()[0]; actualCamera = track?.getSettings().deviceId;
    if (actualCamera !== cameraID) throw Error('The chosen camera could not be verified. No fallback camera is used.');
    track.addEventListener('ended', () => { if (token === epoch) stop().catch(() => {}); });
    video.srcObject = stream; await video.play();
    if (token !== epoch) return;
    const engine = new FaceMesh({locateFile: file => `mesh-observer://ui/engine/assets/${file}`});
    tracker = engine;
    engine.setOptions({maxNumFaces: 2, refineLandmarks: true, minDetectionConfidence: 0.5, minTrackingConfidence: 0.5});
    engine.onResults(async results => {
      if (!running || token !== epoch || packetPending) return;
      packetPending = true;
      try {
        const value = await api.frame({cameraID: actualCamera, capturedAt, faces: results.multiFaceLandmarks || [], focused: document.hasFocus()});
        if (token === epoch) displayState(value);
      } catch (error) { if (token === epoch) await stop(error.message); }
      finally { if (token === epoch) packetPending = false; }
    });
    const bootstrap = await api.bootstrap();
    if (token !== epoch) return;
    starting = false; running = true; displayState(bootstrap);
    if (!bootstrap.readinessCode) status('Camera preview active. Waiting for tracking readiness.');
    async function tick() {
      if (!running || token !== epoch) return;
      try { if (video.readyState >= 2 && !packetPending) { capturedAt = Date.now(); await engine.send({image: video}); } }
      catch (error) { if (token === epoch) await stop(error.message); return; }
      if (running && token === epoch) video.requestVideoFrameCallback(tick);
    }
    video.requestVideoFrameCallback(tick);
  } catch (error) { if (token === epoch) await stop(error.message); }
}
async function finish() {
  const token = epoch;
  try {
    const value = await api.finishTarget();
    if (token !== epoch) return;
    displayState(value); if (!value.ok && !value.calibrationIssue) status(calibrationMessages[value.reason] || 'Try this target again.');
  } catch (error) { if (token === epoch) status(error.message); }
}
byID('camera').onchange = byID('display').onchange = () => displayState(latestState);
byID('refresh').onclick = () => refreshChoices(true);
byID('start').onclick = start; byID('stop').onclick = () => stop();
byID('calibrate').onclick = async () => {
  if (!running) return;
  const token = epoch;
  try {
    const value = await api.beginCalibration();
    if (token !== epoch) return;
    displayState(value); status('Look at the glowing dot. Hold steady, then press Space.');
  } catch (error) { if (token === epoch) status(error.message); }
};
byID('collect').onclick = finish; byID('cancel').onclick = () => stop();
addEventListener('keydown', event => { if (!latestState.calibrating) return; if (event.code === 'Space') { event.preventDefault(); if (!event.repeat && !byID('collect').disabled) finish(); } if (event.code === 'Escape') { event.preventDefault(); stop().catch(() => {}); } });
addEventListener('resize', presentTarget); addEventListener('focus', presentTarget);
addEventListener('beforeunload', closeLocal);
refreshChoices();

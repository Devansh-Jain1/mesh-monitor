'use strict';
// Standalone entry point. NeoCursor main.js, preload.js, renderer.js, speech,
// robotjs, server and cursor monitor are never required or executed here.
const {app, BrowserWindow, ipcMain, protocol, screen, session, systemPreferences} = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const {GazeCalibration, extractFeature} = require('./calibration.cjs');
const {ObservationPublisher} = require('./publisher.cjs');
const PIN = '986db45663cf37b6e47e5e355fa1e9ce0d05de76';
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const pageURL = 'mesh-observer://ui/observer.html';
const stateDirectory = path.join(os.homedir(), 'Library', 'Application Support', 'MeshMonitor', 'neocursor');
let window, publisher, calibration, selectedDisplay, selectedCamera, captureAllowed = false, calibrating = false;
let normalBounds, lastFrameAt = -Infinity, lastPublicationAt = -Infinity;
let generation = 0;
let cameraChoicesAllowed = false;
const calibrationAttempts = [];
const managed = process.argv.includes('--mesh-managed');
let quitting = false, statusWritable = true, frameObserved = false, calibrationID = null;
let featureIssue = null;
let frameReadiness = 'waiting-frame', calibrationIssue = null, lastReadinessSignature = '';
function readinessCode() {
  if (!captureAllowed) return 'camera-off';
  if (frameReadiness !== 'ready-to-calibrate') return frameReadiness;
  if (calibrating) return calibration?.progress.targetActive ? 'collecting' : 'placing-target';
  return 'ready-to-calibrate';
}
function readinessFields() {
  return {readinessCode: readinessCode(), calibrationIssue, featureIssue,
    sampleCount: Math.min(96, calibration?.progress.samples || 0)};
}
// Emit changes and the useful sample-count milestone, never a receipt per frame.
function readinessSignature() {
  return JSON.stringify([readinessCode(), calibrationIssue, featureIssue, (calibration?.progress.samples || 0) >= 12]);
}
function reportReadiness() {
  if (readinessSignature() !== lastReadinessSignature) receipt('state', 'tracking-readiness');
}

// Parent receipts contain lifecycle metadata only. Camera permission is not
// proof that a frame arrived: cameraID stays null until an exact-camera packet.
function receipt(event, reason) {
  lastReadinessSignature = readinessSignature();
  if (!managed || !statusWritable) return;
  const value = {schemaVersion: 1, event, reason, captureActive: captureAllowed,
    frameObserved, calibrating, validated: !!calibration?.validated,
    cameraID: frameObserved ? selectedCamera : null, selectedCameraID: selectedCamera || null,
    displayID: selectedDisplay ? String(selectedDisplay.id) : null, calibrationID,
    output: publisher?.output || null,
    completedTargets: calibration?.progress.completedTargets || 0, totalTargets: 7, ...readinessFields()};
  try {
    if (!process.stdout.write('MESH_OBSERVER ' + JSON.stringify(value) + '\n')) {
      statusWritable = false; quit('status-pipe-backpressure');
    }
  } catch (_) { statusWritable = false; quit('status-pipe-error'); }
}
function quit(reason) {
  if (quitting) return;
  quitting = true;
  stop(true, reason); receipt('exit', reason); app.quit();
}
function managedError(reason) { receipt('error', reason); quit(reason); }
function attachParentPipe() {
  if (!managed) return true;
  process.stdout.once('error', () => { statusWritable = false; quit('status-pipe-error'); });
  // Same-origin custom scheme fetches require the fixed, supported Electron
  // runtime. The native launcher independently verifies this range as well.
  const version = /^41\.(\d+)\.(\d+)$/u.exec(process.versions.electron || '');
  if (!version || Number(version[1]) < 4) { managedError('unsupported-electron-runtime'); return false; }
  // A terminal or a regular file cannot represent the lifetime of this parent.
  try {
    if (process.stdin.isTTY || !fs.fstatSync(0).isFIFO() || process.stdin.destroyed) {
      managedError('parent-pipe-required'); return false;
    }
  } catch (_) { managedError('parent-pipe-required'); return false; }
  let pending = Buffer.alloc(0);
  process.stdin.on('data', chunk => {
    if (quitting) return;
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    let offset = 0;
    while (offset < bytes.length && !quitting) {
      const newline = bytes.indexOf(10, offset);
      const end = newline < 0 ? bytes.length : newline;
      if (pending.length + end - offset > 1024) { pending = Buffer.alloc(0); managedError('parent-command-too-long'); return; }
      pending = Buffer.concat([pending, bytes.subarray(offset, end)]);
      if (newline < 0) return;
      const line = pending.toString('utf8').trim(); pending = Buffer.alloc(0); offset = newline + 1;
      if (!line) continue;
      let command;
      try { command = JSON.parse(line); } catch (_) { managedError('invalid-parent-command'); return; }
      if (!command || Array.isArray(command) || Object.keys(command).length !== 1 ||
          !['stop', 'quit'].includes(command.command)) { managedError('invalid-parent-command'); return; }
      if (command.command === 'quit') quit('parent-quit');
      else stop(true, 'parent-stop');
    }
  });
  process.stdin.once('end', () => { pending = Buffer.alloc(0); quit('parent-eof'); });
  process.stdin.once('error', () => { pending = Buffer.alloc(0); managedError('parent-pipe-error'); });
  process.stdin.once('close', () => quit('parent-pipe-closed'));
  process.stdin.resume();
  return !quitting;
}
process.on('SIGTERM', () => quit('sigterm'));

function regularBytes(file, expectedHash) {
  const st = fs.lstatSync(file);
  if (!st.isFile() || st.isSymbolicLink() || st.size > 128 * 1024 * 1024) throw Error('Invalid tracker asset: ' + path.basename(file));
  const bytes = fs.readFileSync(file);
  if (sha(bytes) !== expectedHash) throw Error('Tracker asset changed: ' + path.basename(file));
  return bytes;
}
function resources() {
  const manifestBytes = fs.readFileSync(path.join(__dirname, 'manifest.json'));
  if (fs.readFileSync(path.join(__dirname, 'READY'), 'utf8').trim() !== sha(manifestBytes)) throw Error('Observation overlay staging is incomplete.');
  const manifest = JSON.parse(manifestBytes);
  if (manifest.schema !== 1 || manifest.mode !== 'observation-only' || manifest.upstream?.commit !== PIN) throw Error('Unexpected NeoCursor source version.');
  const result = new Map();
  for (const name of ['observer.html','observer-renderer.js','observer-preload.cjs','observer-main.cjs','calibration.cjs','publisher.cjs']) {
    const bytes = regularBytes(path.join(__dirname, name), manifest.overlay.files[name]);
    if (name === 'observer.html' || name === 'observer-renderer.js') result.set('ui/' + name, bytes);
  }
  const root = fs.realpathSync(manifest.upstream.checkout);
  for (const [relative, record] of Object.entries(manifest.upstream.assets)) {
    const file = path.resolve(root, relative);
    if (!file.startsWith(root + path.sep) || fs.realpathSync(file) !== file) throw Error('Tracker asset path escaped the pinned checkout.');
    const bytes = regularBytes(file, record.sha256);
    if (relative === 'mediapipe/face_mesh.js') result.set('ui/engine/face_mesh.js', bytes);
    else if (relative.startsWith('mediapipe/face_mesh/')) result.set('ui/engine/assets/' + path.basename(relative), bytes);
  }
  if (!result.has('ui/engine/face_mesh.js')) throw Error('Pinned FaceMesh runtime is missing.');
  return result;
}
let assets;
if (attachParentPipe()) {
  try {
    assets = resources();
    protocol.registerSchemesAsPrivileged([{scheme: 'mesh-observer', privileges: {
      standard: true, secure: true, supportFetchAPI: true, corsEnabled: false, stream: true,
    }}]);
    app.setName('Mesh NeoCursor Observer');
    fs.mkdirSync(stateDirectory, {recursive: true, mode: 0o700});
    app.setPath('userData', path.join(stateDirectory, 'electron'));
    if (!app.requestSingleInstanceLock()) managedError('already-running');
  } catch (error) {
    if (!managed) process.stderr.write(error.message + '\n');
    managedError('startup-validation-failed');
  }
}
if (!quitting) {
  app.whenReady().then(() => {
    if (quitting) return;
    publisher = new ObservationPublisher(stateDirectory);
    protocol.handle('mesh-observer', request => {
      const url = new URL(request.url);
      const bytes = assets.get(url.host + url.pathname);
      if (!bytes || request.method !== 'GET') return new Response('Not found', {status: 404});
      const type = url.pathname.endsWith('.html') ? 'text/html' : url.pathname.endsWith('.js') ? 'application/javascript' : url.pathname.endsWith('.wasm') ? 'application/wasm' : 'application/octet-stream';
      return new Response(bytes, {headers: {'Content-Type': type, 'Cache-Control': 'no-store'}});
    });
    const ownContents = contents => !!window && contents?.id === window.webContents.id;
    session.defaultSession.setPermissionCheckHandler((contents, permission, _origin, details) =>
      ownContents(contents) && (captureAllowed || cameraChoicesAllowed) && permission === 'media' && details?.mediaType === 'video');
    session.defaultSession.setPermissionRequestHandler((contents, permission, callback, details) =>
      callback(ownContents(contents) && captureAllowed && permission === 'media' && details?.mediaTypes?.length === 1 && details.mediaTypes[0] === 'video'));
    session.defaultSession.setDisplayMediaRequestHandler((_request, callback) => callback({}));
    session.defaultSession.webRequest.onBeforeRequest((details, callback) =>
      callback({cancel: !details.url.startsWith('mesh-observer://') && !details.url.startsWith('blob:mesh-observer://')}));
    window = new BrowserWindow({width: 920, height: 760, minWidth: 740, minHeight: 600,
      title: 'Mesh · NeoCursor setup', backgroundColor: '#070b14',
      webPreferences: {preload: path.join(__dirname, 'observer-preload.cjs'), contextIsolation: true,
        sandbox: true, nodeIntegration: false, webSecurity: true, backgroundThrottling: false}});
    window.webContents.setWindowOpenHandler(() => ({action: 'deny'}));
    window.webContents.on('will-navigate', (event, url) => { if (url !== pageURL) event.preventDefault(); });
    window.webContents.on('render-process-gone', () => managedError('renderer-gone'));
    window.on('closed', () => { window = undefined; quit('window-closed'); });
    for (const event of ['display-added','display-removed']) screen.on(event, () => stop(true, event));
    screen.on('display-metrics-changed', (_event, display, changed) => {
      // Full-screen entry changes the menu/Dock workArea, not our calibrated
      // full-display coordinates. Stop only when the selected coordinate space changes.
      if (selectedDisplay && display?.id === selectedDisplay.id &&
          (!Array.isArray(changed) || changed.some(key => ['bounds', 'scaleFactor', 'rotation'].includes(key)))) {
        stop(true, 'display-metrics-changed');
      }
    });
    return Promise.resolve(window.loadURL(pageURL)).then(() => { if (!quitting) receipt('ready', 'ui-loaded'); });
  }).catch(error => {
    if (!managed) process.stderr.write(error.message + '\n');
    managedError('startup-failed');
  });
}

function exitCalibration() {
  calibrating = false;
  if (window && !window.isDestroyed()) {
    window.setAlwaysOnTop(false); window.setResizable(true);
    const restore = normalBounds;
    if (window.isFullScreen()) {
      window.once('leave-full-screen', () => { if (restore && window && !window.isDestroyed()) window.setBounds(restore); });
      window.setFullScreen(false);
    } else if (restore) window.setBounds(restore);
  }
  normalBounds = undefined;
}
function stop(notify = true, reason = 'stopped') {
  generation += 1;
  captureAllowed = false; cameraChoicesAllowed = false; calibration?.reset(); calibration = undefined;
  frameObserved = false; calibrationID = null;
  frameReadiness = 'waiting-frame'; calibrationIssue = null;
  try { publisher?.clear(); } catch (_) { /* Stale samples are also refused by Monitor. */ }
  exitCalibration();
  if (notify && window && !window.isDestroyed()) window.webContents.send('mesh-observer:stop');
  receipt('state', reason);
}
app.on('before-quit', () => {
  if (!quitting) { quitting = true; stop(true, 'app-quit'); receipt('exit', 'app-quit'); }
});
function state() {
  const viewport = calibrating && window ? window.getContentBounds() : null;
  const display = selectedDisplay?.bounds, target = calibrating ? calibration?.currentTarget : null;
  const renderTarget = viewport && display && target ? {
    x: (display.x + target.x * display.width - viewport.x) / viewport.width,
    y: (display.y + target.y * display.height - viewport.y) / viewport.height
  } : null;
  return {viewport, renderTarget, quality: calibration?.quality(), calibrationAttempts, captureActive: captureAllowed, calibrating, target: calibrating ? calibration?.currentTarget : null,
    progress: calibration?.progress, validated: !!calibration?.validated,
    output: publisher?.output, displayID: selectedDisplay ? String(selectedDisplay.id) : null, ...readinessFields()};
}
function handle(name, action) {
  ipcMain.handle('mesh-observer:' + name, async (event, ...args) => {
    if (quitting || !window || window.isDestroyed() || event.sender?.id !== window.webContents.id ||
        event.senderFrame !== window.webContents.mainFrame || event.senderFrame?.url !== pageURL) throw Error('Unknown observer frame.');
    const token = generation + (name === 'start' ? 1 : 0);
    try { return await action(...args); }
    catch (error) {
      // Permission results from an older, stopped session must not overwrite a
      // newer native status. Expected target-placement retries stay silent.
      if (!quitting && token === generation && name !== 'target-ready') receipt('error', 'request-' + name + '-failed');
      throw error;
    }
  });
}
handle('bootstrap', () => {
  // Listing already-authorized devices must work on every launch without
  // opening a stream or asking the user to grant the same permission again.
  const cameraPermission = systemPreferences.getMediaAccessStatus('camera');
  cameraChoicesAllowed = cameraPermission === 'granted';
  return {...state(), cameraPermission, upstreamCommit: PIN,
    displays: screen.getAllDisplays().map(d => ({id: String(d.id), label: d.label || `Display ${d.id}`, bounds: d.bounds}))};
});
// The caller already closed its local tracks. A second stop notification could
// otherwise arrive after it has explicitly started a newer session.
handle('stop', () => { stop(false, 'ui-stop'); return state(); });
handle('allow-camera-choices', async () => {
  const token = generation;
  const allowed = await systemPreferences.askForMediaAccess('camera');
  if (quitting || token !== generation || !window || window.isDestroyed()) throw Error('Camera choices permission was cancelled.');
  if (!allowed) throw Error('Camera permission was not granted.');
  cameraChoicesAllowed = true;
  receipt('state', 'camera-choices-allowed');
  return state();
});
handle('start', async configuration => {
  stop(false, 'starting');
  const token = generation;
  if (typeof configuration?.cameraID !== 'string' || !configuration.cameraID.trim() ||
      configuration.cameraID.length > 256 || /[\u0000-\u001f\u007f]/u.test(configuration.cameraID)) throw Error('Choose an exact camera first.');
  selectedDisplay = screen.getAllDisplays().find(d => String(d.id) === configuration.displayID);
  if (!selectedDisplay) throw Error('Choose a connected display first.');
  const allowed = await systemPreferences.askForMediaAccess('camera');
  if (quitting || token !== generation || !window || window.isDestroyed()) throw Error('Camera startup was cancelled.');
  if (!allowed) throw Error('Camera permission was not granted.');
  selectedCamera = configuration.cameraID;
  calibrationID = crypto.randomUUID();
  calibration = new GazeCalibration({cameraID: selectedCamera, displayID: String(selectedDisplay.id), calibrationID});
  captureAllowed = true; lastFrameAt = -Infinity; lastPublicationAt = -Infinity;
  receipt('state', 'capture-authorized');
  return state();
});
handle('calibrate', () => {
  if (!captureAllowed || !selectedDisplay) throw Error('Start the chosen camera first.');
  if (calibrating) throw Error('Calibration is already active.');
  publisher.clear();
  calibrationID = crypto.randomUUID();
  calibration = new GazeCalibration({cameraID: selectedCamera, displayID: String(selectedDisplay.id), calibrationID});
  calibrationIssue = null;
  frameReadiness = 'waiting-frame';
  normalBounds = window.getBounds();
  window.setResizable(false); window.setAlwaysOnTop(true, 'floating');
  // Use the whole selected display. A frame/title bar would offset target positions.
  window.setContentBounds(selectedDisplay.bounds);
  window.setFullScreen(true);
  calibrating = true;
  receipt('state', 'calibration-started');
  // Target presentation is acknowledged by the renderer before sample collection.
  return state();
});
handle('finish-target', () => {
  if (!calibrating || !calibration) throw Error('Calibration is not active.');
  if (!calibration.progress.targetActive) throw Error('Wait for the target to be placed on the selected display.');
  const result = calibration.finishTarget(Date.now());
  calibrationIssue = result.ok ? null : result.reason;
  calibrationAttempts.push({at: new Date().toISOString(), ...result.diagnostic});
  if (calibrationAttempts.length > 20) calibrationAttempts.shift();
  if (result.validated) frameReadiness = 'projection-unavailable'; // Wait for an actual projected frame.
  if (result.validated || (!result.ok && result.progress?.completedTargets === 0 && !result.progress?.targetActive)) exitCalibration();
  receipt('state', result.validated ? 'calibration-validated' : result.ok ? 'target-finished' : 'target-rejected');
  return {...result, ...state()};
});
handle('target-ready', presentation => {
  if (!calibrating || !calibration || calibration.progress.targetActive) return state();
  const bounds = window.getContentBounds(), expected = selectedDisplay.bounds;
  if (!window.isFullScreen() || presentation?.index !== calibration.currentTarget?.index ||
      !Number.isFinite(presentation.width) || !Number.isFinite(presentation.height) ||
      Math.abs(presentation.width - bounds.width) > 1 ||
      Math.abs(presentation.height - bounds.height) > 1 || presentation.focused !== true ||
      ['x', 'y', 'width', 'height'].some(key => !Number.isFinite(bounds[key])) ||
      Math.abs(bounds.x - expected.x) > 1 || Math.abs(bounds.width - expected.width) > 1 ||
      bounds.y < expected.y - 1 || bounds.y - expected.y > 96 ||
      bounds.height < expected.height - 96 || bounds.y + bounds.height > expected.y + expected.height + 1 ||
      (Math.abs(bounds.y - expected.y) > 1 || Math.abs(bounds.height - expected.height) > 1) &&
        ['x', 'y', 'width', 'height'].some(key => !Number.isFinite(presentation.viewport?.[key]) || Math.abs(presentation.viewport[key] - bounds[key]) > 1)) {
    throw Error('Target is not yet on the chosen full display.');
  }
  calibration.beginTarget(Date.now()); receipt('state', 'target-ready'); return state();
});
handle('frame', packet => {
  if (!captureAllowed || !calibration) return state();
  if (calibrating && !packet?.focused && !calibration.progress.targetActive && calibration.progress.completedTargets === 0) { publisher.clear(); return state(); }
  if (calibrating && !packet?.focused) { calibration.reset(); publisher.clear(); exitCalibration(); frameReadiness = 'waiting-frame'; calibrationIssue = 'focus-lost'; receipt('state', 'calibration-focus-lost'); return state(); }
  const now = Date.now();
  if (packet?.cameraID !== selectedCamera || !Number.isFinite(packet.capturedAt) || packet.capturedAt <= lastFrameAt || packet.capturedAt > now + 250 || now - packet.capturedAt > 1000) { publisher.clear(); frameReadiness = 'stale-frame'; reportReadiness(); return state(); }
  lastFrameAt = packet.capturedAt;
  if (!frameObserved) { frameObserved = true; receipt('state', 'frame-observed'); }
  const faces = packet.faces;
  if (!Array.isArray(faces) || faces.length !== 1 || !Array.isArray(faces[0]) || faces[0].length > 512) {
    publisher.clear(); frameReadiness = !Array.isArray(faces) ? 'eyes-unavailable' : faces.length === 0 ? 'no-face' : faces.length > 1 ? 'multiple-faces' : 'eyes-unavailable';
    reportReadiness(); return state();
  }
  const diagnostic = {};
  const feature = extractFeature({multiFaceLandmarks: faces}, diagnostic);
  featureIssue = diagnostic.reason;
  if (!feature) { publisher.clear(); frameReadiness = 'eyes-unavailable'; reportReadiness(); return state(); }
  if (!calibration.validated) frameReadiness = 'ready-to-calibrate';
  if (calibrating && calibration.progress.targetActive) calibration.sample(feature, packet.capturedAt, now);
  if (calibration.validated && now - lastPublicationAt >= 100) {
    const observation = calibration.project(feature, packet.capturedAt, now);
    if (observation) { publisher.publish(observation); lastPublicationAt = now; frameReadiness = 'validated'; }
    else { publisher.clear(); frameReadiness = 'projection-unavailable'; }
  }
  reportReadiness();
  return state();
});

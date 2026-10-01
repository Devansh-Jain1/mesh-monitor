'use strict';
// OPTIONAL explicit probe. Run with a reviewed Electron 41.4+ binary, followed
// by this file and an exact pinned .mesh-observer directory. Never auto-run.
// This is not the observer app: no upstream/user main, preload or renderer loads.
// It uses only a programmatic blank canvas; no device/media/screen API is called.
const {app, BrowserWindow, protocol, session} = require('electron');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const PIN = '986db45663cf37b6e47e5e355fa1e9ce0d05de76';
const PAGE = 'mesh-observer://ui/probe.html';
const ROOT = 'mesh-observer://ui/engine/assets/';
const DEADLINE_MS = 40000;
const MAX_ASSET = 16 * 1024 * 1024;
const ASSET_BLOBS = {
  'mediapipe/camera_utils.js': [7881, '8a7df290a653e7dc93915eb7b63e75c9f557b585'],
  'mediapipe/face_mesh.js': [64913, '869a3bc3c1e8b3a63025445b6cfd067a74d51f86'],
  'mediapipe/face_mesh/face_mesh.binarypb': [939, '5151beb521b0945d5866d1f9ac7c578082464d43'],
  'mediapipe/face_mesh/face_mesh_solution_packed_assets.data': [3986256, '855522fa60cd7c75654925370f11c144e6a9c5ea'],
  'mediapipe/face_mesh/face_mesh_solution_packed_assets_loader.js': [8928, '6a0a65b212505276f6e27e1af7acef9b3054dda8'],
  'mediapipe/face_mesh/face_mesh_solution_simd_wasm_bin.js': [330166, 'e019722ec201725a765520e225a17877d14ecd9c'],
  'mediapipe/face_mesh/face_mesh_solution_simd_wasm_bin.wasm': [6161697, '41f7701041a01afe2411d47a44dc8b77f8c8601b'],
};
const GLUE = ['observer-main.cjs', 'observer-preload.cjs', 'observer-renderer.js',
  'observer.html', 'calibration.cjs', 'publisher.cjs', 'package.json'];
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const blob = bytes => crypto.createHash('sha1').update('blob ' + bytes.length + '\0').update(bytes).digest('hex');
let window, temporaryDirectory, finished = false, deadline;
let permissionChecks = 0, permissionRequests = 0, sensorPermissionRequests = 0;
let displayMediaAttempts = 0, deniedRequests = 0;
const permissionCheckCounts = new Map(), permissionRequestCounts = new Map();
let omittedCheckEvents = 0, omittedRequestEvents = 0;
const hashes = {};
const runtimeVersion = process.versions.electron || 'unavailable';

// Eligibility queries are not permission requests and do not prove capture.
// Keep only bounded names/types, never requesting origins, URLs, or frame data.
function recordPermission(kind, permission, details) {
  const label = value => typeof value === 'string' && value.length
    ? value.slice(0, 48).replace(/[^A-Za-z0-9._-]/gu, '_') : 'unspecified';
  const name = label(permission);
  const types = Array.isArray(details?.mediaTypes) ? details.mediaTypes.slice(0, 4)
    : typeof details?.mediaType === 'string' ? [details.mediaType] : [];
  const mediaTypes = [...new Set(types.map(label))].sort();
  const sensorRelated = /(^|[-_])(media|camera|microphone|audio|video|screen|display|desktop)([-_]|$)/iu.test(name)
    || mediaTypes.some(value => ['audio', 'video', 'camera', 'microphone', 'screen', 'display'].includes(value.toLowerCase()));
  const counts = kind === 'check' ? permissionCheckCounts : permissionRequestCounts;
  if (kind === 'check') permissionChecks += 1;
  else { permissionRequests += 1; if (sensorRelated) sensorPermissionRequests += 1; }
  const key = JSON.stringify([name, mediaTypes]);
  if (counts.has(key)) counts.get(key).count += 1;
  else if (counts.size < 8) counts.set(key, {permission: name, mediaTypes, sensorRelated, count: 1});
  else if (kind === 'check') omittedCheckEvents += 1;
  else omittedRequestEvents += 1;
}

function checkedDirectory(directory, privateOnly = false) {
  if (!path.isAbsolute(directory) || fs.realpathSync(directory) !== directory) throw Error('An exact absolute nonsymlink directory is required.');
  const st = fs.lstatSync(directory);
  if (!st.isDirectory() || st.isSymbolicLink() || st.uid !== process.getuid() || (st.mode & 0o022) || (privateOnly && (st.mode & 0o777) !== 0o700)) throw Error('Directory ownership or permissions are invalid.');
}

function readChecked(file, maxBytes, privateOnly = false) {
  if (fs.realpathSync(file) !== file) throw Error('Symlinked input is not allowed.');
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.uid !== process.getuid() || before.nlink !== 1 || before.size > maxBytes || (before.mode & 0o022) || (privateOnly && (before.mode & 0o777) !== 0o600)) throw Error('Input ownership, permissions or size are invalid.');
    const bytes = fs.readFileSync(fd);
    const after = fs.fstatSync(fd);
    if (bytes.length !== before.size || bytes.length > maxBytes || after.size !== before.size || after.mtimeMs !== before.mtimeMs || after.ino !== before.ino) throw Error('Input changed during validation.');
    return bytes;
  } finally { fs.closeSync(fd); }
}

function inspectOverlay(overlay) {
  checkedDirectory(overlay, true);
  if (path.basename(overlay) !== '.mesh-observer') throw Error('Expected the exact pinned .mesh-observer directory.');
  const manifestBytes = readChecked(path.join(overlay, 'manifest.json'), 32768, true);
  const ready = readChecked(path.join(overlay, 'READY'), 65, true).toString('ascii');
  if (ready !== sha(manifestBytes) + '\n') throw Error('READY does not match the exact staged manifest.');
  const manifest = JSON.parse(manifestBytes);
  if (manifest.schema !== 1 || manifest.mode !== 'observation-only' || manifest.upstream?.commit !== PIN || manifest.overlay?.entry !== 'observer-main.cjs') throw Error('Unsupported overlay manifest or upstream revision.');
  const upstream = manifest.upstream.checkout;
  if (typeof upstream !== 'string' || overlay !== path.join(upstream, '.mesh-observer')) throw Error('Overlay must remain inside its pinned upstream checkout.');
  checkedDirectory(upstream);
  for (const name of GLUE) {
    const data = readChecked(path.join(overlay, name), 512 * 1024, true);
    if (sha(data) !== manifest.overlay.files?.[name]) throw Error('Original overlay glue hash mismatch.');
  }
  const packageInfo = JSON.parse(readChecked(path.join(overlay, 'package.json'), 4096, true));
  if (packageInfo.main !== 'observer-main.cjs') throw Error('Overlay entry is not observation-only.');
  if (manifest.engine?.faceMeshScript !== path.join(upstream, 'mediapipe/face_mesh.js') ||
      manifest.engine?.assetDirectory !== path.join(upstream, 'mediapipe/face_mesh')) throw Error('Engine paths do not match the pinned checkout.');
  const records = manifest.upstream.assets;
  if (!records || Object.keys(records).sort().join('\n') !== Object.keys(ASSET_BLOBS).sort().join('\n')) throw Error('Pinned asset catalog is incomplete or unexpected.');
  const resources = new Map();
  for (const [relative, [size, identity]] of Object.entries(ASSET_BLOBS)) {
    const data = readChecked(path.join(upstream, relative), MAX_ASSET);
    const digest = sha(data), record = records[relative];
    if (data.length !== size || blob(data) !== identity || record.gitBlob !== identity || record.size !== size || record.sha256 !== digest) throw Error('Pinned FaceMesh asset hash mismatch.');
    hashes[relative] = digest;
    if (relative === 'mediapipe/face_mesh.js') resources.set('/engine/face_mesh.js', data);
    else if (relative.startsWith('mediapipe/face_mesh/')) resources.set('/engine/assets/' + path.basename(relative), data);
  }
  hashes.manifest = sha(manifestBytes);
  return resources;
}

function finish(ok, detail = {}) {
  if (finished) return;
  finished = true;
  clearTimeout(deadline);
  const result = {probe: 'neocursor-synthetic-engine', ok, runtimeVersion, upstreamCommit: PIN,
    engineInitialized: false, frameProcessed: false, faces: null,
    syntheticInput: {width: 213, height: 160, kind: 'blank-programmatic-canvas'},
    noSensors: false, permissionChecks, permissionRequests, sensorPermissionRequests,
    permissionCheckCounts: [...permissionCheckCounts.values()],
    permissionRequestCounts: [...permissionRequestCounts.values()],
    omittedCheckEvents, omittedRequestEvents, allPermissionsDenied: true,
    displayMediaAttempts, deniedRequests, hashes, ...detail};
  if (sensorPermissionRequests || displayMediaAttempts) result.noSensors = false;
  if (permissionRequests || displayMediaAttempts || deniedRequests) {
    result.ok = false;
    result.error = result.error || 'An actual permission request, display-media request, or forbidden resource request was denied.';
  }
  // At most one small JSON result, no frames, paths, landmarks, or debug dumps.
  let output = JSON.stringify(result);
  if (output.length > 8192) output = JSON.stringify({probe: result.probe, ok: false, error: 'Result exceeded its bound.'});
  try { process.stdout.write(output + '\n'); } catch (_) { /* Still terminate. */ }
  try { if (window && !window.isDestroyed()) window.destroy(); } catch (_) { /* Continue owned cleanup. */ }
  const code = result.ok ? 0 : 1;
  process.exitCode = code;
  const cleanup = () => {
    if (temporaryDirectory) {
      try { fs.rmSync(temporaryDirectory, {recursive: true, force: true}); } catch (_) { /* OS may retain an open cache file. */ }
      temporaryDirectory = undefined;
    }
  };
  app.once('will-quit', event => {
    // app.quit() otherwise exits with Electron's default code even on failure.
    event.preventDefault(); cleanup(); app.exit(code);
  });
  setTimeout(() => { cleanup(); app.exit(code); }, 1000).unref();
  app.quit();
}

deadline = setTimeout(() => finish(false, {error: 'Synthetic engine probe exceeded its 40-second deadline.'}), DEADLINE_MS);
process.on('uncaughtException', error => finish(false, {error: String(error.message || error).slice(0, 400)}));
process.on('unhandledRejection', error => finish(false, {error: String(error?.message || error).slice(0, 400)}));

try {
  const version = /^(\d+)\.(\d+)\.(\d+)$/.exec(runtimeVersion);
  if (!version || Number(version[1]) !== 41 || Number(version[2]) < 4) throw Error('This probe requires a stable Electron 41.4.0+ runtime in the 41.x series.');
  if (process.argv.length !== 3) throw Error('Usage: Electron probe.cjs /absolute/pinned-checkout/.mesh-observer');
  const resources = inspectOverlay(process.argv[2]);
  const html = Buffer.from(`<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-eval'; connect-src 'self'; worker-src 'self' blob:; img-src 'self' blob: data:; media-src 'none'"></head><body><canvas id="synthetic" width="213" height="160"></canvas><script src="mesh-observer://ui/engine/face_mesh.js"></script></body></html>`);
  resources.set('/probe.html', html);
  protocol.registerSchemesAsPrivileged([{scheme: 'mesh-observer', privileges: {
    standard: true, secure: true, supportFetchAPI: true, corsEnabled: false,
  }}]);
  temporaryDirectory = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'mesh-engine-probe-'));
  fs.chmodSync(temporaryDirectory, 0o700);
  app.setName('Mesh synthetic engine probe');
  app.setPath('userData', temporaryDirectory);
  app.on('window-all-closed', () => {});
  app.whenReady().then(async () => {
    if (finished) return;
    app.dock?.hide();
    session.defaultSession.setPermissionCheckHandler((_contents, permission, _origin, details) => {
      recordPermission('check', permission, details); return false;
    });
    session.defaultSession.setPermissionRequestHandler((_contents, permission, callback, details) => {
      recordPermission('request', permission, details); callback(false);
    });
    session.defaultSession.setDisplayMediaRequestHandler((_request, callback) => { displayMediaAttempts += 1; callback({}); });
    const allowedURL = raw => {
      try {
        const url = new URL(raw);
        return url.protocol === 'mesh-observer:' && url.host === 'ui' && !url.username && !url.password && !url.search && !url.hash && resources.has(url.pathname);
      } catch (_) { return false; }
    };
    session.defaultSession.webRequest.onBeforeRequest((details, callback) => {
      const permitted = details.method === 'GET' && allowedURL(details.url);
      if (!permitted) deniedRequests += 1;
      callback({cancel: !permitted});
    });
    protocol.handle('mesh-observer', request => {
      if (request.method !== 'GET' || !allowedURL(request.url)) {
        deniedRequests += 1;
        return new Response('Denied', {status: 403});
      }
      const pathname = new URL(request.url).pathname;
      const type = pathname.endsWith('.html') ? 'text/html; charset=utf-8' : pathname.endsWith('.js') ? 'application/javascript' : pathname.endsWith('.wasm') ? 'application/wasm' : 'application/octet-stream';
      return new Response(resources.get(pathname), {headers: {'Content-Type': type, 'Cache-Control': 'no-store'}});
    });
    window = new BrowserWindow({show: false, width: 256, height: 256, skipTaskbar: true,
      webPreferences: {sandbox: true, contextIsolation: true, nodeIntegration: false, webSecurity: true,
        backgroundThrottling: false, devTools: false, autoplayPolicy: 'document-user-activation-required'}});
    window.webContents.setWindowOpenHandler(() => ({action: 'deny'}));
    window.webContents.on('will-navigate', event => event.preventDefault());
    window.webContents.on('render-process-gone', () => finish(false, {error: 'Synthetic renderer terminated.'}));
    await window.loadURL(PAGE);
    if (finished) return;
    // Fixed original fixture script, never renderer/user-provided executable text.
    const result = await window.webContents.executeJavaScript(`(async () => {
      let attempts = 0, engine, initialized = false, callbacks = 0, faces = null;
      const denied = () => { attempts += 1; throw Error('Sensor/audio access is forbidden in this probe.'); };
      Object.defineProperty(navigator, 'mediaDevices', {configurable: false, get: denied});
      for (const name of ['Audio', 'AudioContext', 'webkitAudioContext']) {
        Object.defineProperty(window, name, {configurable: false, get: denied});
      }
      try {
        if (typeof FaceMesh !== 'function') throw Error('Pinned FaceMesh script did not load.');
        const canvas = document.getElementById('synthetic');
        const context = canvas.getContext('2d');
        if (!context) throw Error('Synthetic canvas context is unavailable.');
        context.fillStyle = '#000000'; context.fillRect(0, 0, 213, 160);
        engine = new FaceMesh({locateFile: file => ${JSON.stringify(ROOT)} + file});
        engine.setOptions({maxNumFaces: 2, refineLandmarks: true, minDetectionConfidence: 0.5, minTrackingConfidence: 0.5});
        engine.onResults(value => { callbacks += 1; faces = Array.isArray(value.multiFaceLandmarks) ? value.multiFaceLandmarks.length : 0; });
        await engine.initialize(); initialized = true;
        await engine.send({image: canvas});
        if (callbacks !== 1 || faces !== 0) throw Error('Unexpected result for the single blank synthetic canvas.');
        await engine.close(); engine = undefined;
        return {engineInitialized: initialized, frameProcessed: true, faces, callbacks, sensorAttempts: attempts, noSensors: attempts === 0};
      } catch (error) {
        try { if (engine) await engine.close(); } catch (_) {}
        return {engineInitialized: initialized, frameProcessed: false, faces, callbacks, sensorAttempts: attempts, noSensors: attempts === 0, error: String(error.message || error).slice(0, 400)};
      }
    })()`, false);
    if (finished) return;
    const valid = result && result.engineInitialized === true && result.frameProcessed === true && result.faces === 0 && result.callbacks === 1 && result.sensorAttempts === 0 && result.noSensors === true && !result.error;
    finish(valid, {engineInitialized: result?.engineInitialized === true, frameProcessed: result?.frameProcessed === true,
      faces: Number.isInteger(result?.faces) ? result.faces : null, sensorAttempts: result?.sensorAttempts ?? null,
      noSensors: result?.noSensors === true, ...(result?.error ? {error: String(result.error).slice(0, 400)} : {})});
  }).catch(error => finish(false, {error: String(error.message || error).slice(0, 400)}));
} catch (error) {
  finish(false, {error: String(error.message || error).slice(0, 400)});
}

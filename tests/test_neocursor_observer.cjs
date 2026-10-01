'use strict';
// Executes our observer in isolated VMs with fake Electron, fake devices, and
// in-memory assets. No Electron app, permission UI, camera, audio or network runs.
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {EventEmitter} = require('node:events');
const core = require('../ops/neocursor_mesh_adapter/calibration.cjs');
const directory = path.resolve(__dirname, '../ops/neocursor_mesh_adapter');
const mainSource = fs.readFileSync(path.join(directory, 'observer-main.cjs'), 'utf8');
const rendererSource = fs.readFileSync(path.join(directory, 'observer-renderer.js'), 'utf8');
const preloadSource = fs.readFileSync(path.join(directory, 'observer-preload.cjs'), 'utf8');
const htmlSource = fs.readFileSync(path.join(directory, 'observer.html'), 'utf8');
const pageURL = 'mesh-observer://ui/observer.html';
const flush = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

async function mainHarness(options = {}) {
  const root = '/fixture/observer', upstream = '/fixture/upstream';
  const files = new Map(), hashes = {};
  const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
  for (const name of ['observer.html','observer-renderer.js','observer-preload.cjs','observer-main.cjs','calibration.cjs','publisher.cjs']) {
    const bytes = fs.readFileSync(path.join(directory, name));
    files.set(path.join(root, name), bytes); hashes[name] = digest(bytes);
  }
  const engine = Buffer.from('synthetic asset, never executed');
  files.set(path.join(upstream, 'mediapipe/face_mesh.js'), engine);
  const wasm = Buffer.from([0, 97, 115, 109]); // Header only; never instantiated.
  files.set(path.join(upstream, 'mediapipe/face_mesh/fixture.wasm'), wasm);
  const manifest = Buffer.from(JSON.stringify({schema: 1, mode: 'observation-only',
    upstream: {checkout: upstream, commit: '986db45663cf37b6e47e5e355fa1e9ce0d05de76', assets: {
      'mediapipe/face_mesh.js': {sha256: digest(engine)}, 'mediapipe/face_mesh/fixture.wasm': {sha256: digest(wasm)},
    }}, overlay: {files: hashes}}));
  files.set(path.join(root, 'manifest.json'), manifest); files.set(path.join(root, 'READY'), Buffer.from(digest(manifest)));
  if (options.invalidManifest) files.set(path.join(root, 'READY'), Buffer.from('invalid'));
  const fakeFS = {
    readFileSync(file, encoding) { const bytes = files.get(file); assert.ok(bytes, `Unexpected file: ${file}`); return encoding ? bytes.toString(encoding) : bytes; },
    lstatSync(file) { const bytes = files.get(file); assert.ok(bytes, `Unexpected stat: ${file}`); return {isFile: () => true, isSymbolicLink: () => false, size: bytes.length}; },
    realpathSync: file => file, mkdirSync() {},
    fstatSync(fd) { assert.equal(fd, 0); return {isFIFO: () => options.fifo !== false}; },
  };
  const app = Object.assign(new EventEmitter(), {setName() {}, setPath() {}, requestSingleInstanceLock: () => options.singleInstance !== false,
    whenReady: () => options.ready?.promise || Promise.resolve(),
    quit() { this.quitCount = (this.quitCount || 0) + 1; this.emit('before-quit'); }});
  const display = {id: 7, label: 'Fixture display', bounds: {x: -1440, y: 0, width: 1440, height: 900}};
  const screen = Object.assign(new EventEmitter(), {getAllDisplays: () => [display], getDisplayMatching: bounds => bounds.x < 0 ? display : {id: 8, bounds: {x: 0, y: 0, width: 1440, height: 900}}});
  const calls = {permissionRequests: 0, publications: [], clears: 0, requires: [], receipts: [], stdout: []}, handlers = new Map(), instances = [];
  const permission = {check: null, request: null, display: null, web: null};
  const defaultSession = {
    setPermissionCheckHandler: callback => { permission.check = callback; },
    setPermissionRequestHandler: callback => { permission.request = callback; },
    setDisplayMediaRequestHandler: callback => { permission.display = callback; },
    webRequest: {onBeforeRequest: callback => { permission.web = callback; }},
  };
  class BrowserWindow extends EventEmitter {
    constructor(options) {
      super(); this.options = options; this.fullscreen = false; this.bounds = {x: 100, y: 100, width: 920, height: 760};
      this.webContents = Object.assign(new EventEmitter(), {id: 91, mainFrame: {url: pageURL, routingId: 1, processId: 10}, setWindowOpenHandler() {}, send: (...args) => { calls.lastSend = args; }});
      instances.push(this);
    }
    setAlwaysOnTop() {} setResizable() {} isDestroyed() { return false; }
    setFullScreen(value) { this.requestedFullscreen = value; if (!value) this.fullscreen = false; }
    isFullScreen() { return this.fullscreen; }
    getBounds() { return {...this.bounds}; } getContentBounds() { return {...this.bounds}; }
    setBounds(value) { this.bounds = {...value}; } setContentBounds(value) { this.bounds = {...value}; }
    loadURL(url) { assert.equal(url, pageURL); return options.load?.promise; }
  }
  class Publisher {
    constructor() { this.output = '/fixture/observation.json'; }
    clear() { calls.clears += 1; calls.latest = null; }
    publish(value) { calls.publications.push(value); calls.latest = value; }
  }
  let now = 1_790_000_000_000, permissionAnswer = async () => true;
  const electron = {app, BrowserWindow, ipcMain: {handle: (name, callback) => handlers.set(name, callback)},
    protocol: {registerSchemesAsPrivileged: schemes => { calls.schemes = schemes; }, handle: (scheme, handler) => { assert.equal(scheme, 'mesh-observer'); calls.protocol = handler; }}, screen, session: {defaultSession},
    systemPreferences: {getMediaAccessStatus: () => options.cameraPermission || 'not-determined', askForMediaAccess: async kind => { assert.equal(kind, 'camera'); calls.permissionRequests += 1; return permissionAnswer(); }}};
  const imports = {'electron': electron, 'node:fs': fakeFS, 'node:path': path, 'node:os': {homedir: () => '/fixture/home'}, 'node:crypto': crypto,
    './calibration.cjs': core, './publisher.cjs': {ObservationPublisher: Publisher}};
  const stdin = Object.assign(new EventEmitter(), {isTTY: !!options.tty, destroyed: false, resume() { calls.stdinResumes = (calls.stdinResumes || 0) + 1; }});
  const stdout = Object.assign(new EventEmitter(), {write(value) {
    calls.stdout.push(value); assert.ok(value.startsWith('MESH_OBSERVER '));
    assert.ok(Buffer.byteLength(value) < 16 * 1024);
    calls.receipts.push(JSON.parse(value.slice('MESH_OBSERVER '.length)));
    return options.statusWritable !== false;
  }});
  const fakeProcess = Object.assign(new EventEmitter(), {argv: options.managed ? ['fixture-electron', root, '--mesh-managed'] : ['fixture-electron', root],
    versions: {electron: options.electronVersion || '41.4.0'}, stdin, stdout,
    stderr: {write: value => { calls.stderr = value; }}});
  const context = vm.createContext({__dirname: root, Buffer, URL, Response,
    Date: class extends Date { static now() { return now; } },
    process: fakeProcess,
    require(name) { calls.requires.push(name); assert.ok(Object.hasOwn(imports, name), `Unexpected dependency: ${name}`); return imports[name]; }});
  vm.runInContext(mainSource, context, {filename: 'observer-main.cjs'}); await flush();
  assert.equal(calls.stderr, undefined); assert.equal(instances.length, options.expectWindow === false ? 0 : 1);
  const window = instances[0];
  const ownEvent = () => ({sender: window.webContents, senderFrame: window.webContents.mainFrame});
  return {calls, window, screen, display, permission, app, stdin, stdout, process: fakeProcess,
    setNow: value => { now = value; }, get now() { return now; },
    setPermission: callback => { permissionAnswer = callback; },
    invoke: (name, args, event = ownEvent()) => handlers.get('mesh-observer:' + name)(event, args), ownEvent};
}

async function rendererHarness() {
  const elements = new Map(), classes = new Set(), listeners = {}, raf = [], frames = [], engines = [], streams = [];
  const element = id => {
    if (!elements.has(id)) elements.set(id, {value: '', textContent: '', disabled: false, style: {}, replaceChildren(...options) { this.options = options; this.value = options[0]?.value || ''; }});
    return elements.get(id);
  };
  const video = element('preview');
  Object.assign(video, {srcObject: null, readyState: 2, play: async () => {}, requestVideoFrameCallback: callback => frames.push(callback)});
  let stopCallback, active = false;
  const calls = {start: 0, stop: 0, media: 0, frame: 0, ready: 0, choices: 0};
  const inactive = () => ({captureActive: active, calibrating: false, displays: [{id: '7', label: 'Fixture display'}]});
  const api = {
    bootstrap: async () => inactive(),
    allowCameraChoices: async () => { calls.choices += 1; return inactive(); },
    start: async () => { calls.start += 1; active = true; return inactive(); },
    stop: async () => { calls.stop += 1; active = false; return inactive(); },
    beginCalibration: async () => ({calibrating: true, target: {x: 0.15, y: 0.15, index: 0}, progress: {targetActive: false}}),
    finishTarget: async () => ({ok: true, calibrating: true, target: {x: 0.85, y: 0.15, index: 1}, progress: {targetActive: false}}),
    targetReady: async presentation => { calls.ready += 1; return {calibrating: true, target: {index: presentation.index}, progress: {targetActive: true}}; },
    frame: async () => { calls.frame += 1; return inactive(); }, onStop: callback => { stopCallback = callback; },
  };
  function makeStream(deviceId = 'camera-1') {
    const track = {stops: 0, stop() { this.stops += 1; }, getSettings: () => ({deviceId}), addEventListener() {}};
    const stream = {getTracks: () => [track], getVideoTracks: () => [track], track}; streams.push(stream); return stream;
  }
  const media = {enumerateDevices: async () => [{kind: 'videoinput', deviceId: 'camera-1', label: 'Fixture camera'}],
    getUserMedia: async options => { calls.media += 1; assert.equal(options.audio, false); assert.equal(options.video.deviceId.exact, 'camera-1'); return makeStream(); }};
  class FaceMesh {
    constructor(options) { this.options = options; this.closes = 0; engines.push(this); }
    setOptions(options) { assert.equal(options.refineLandmarks, true); }
    onResults(callback) { this.results = callback; }
    async send() {} async close() { this.closes += 1; }
  }
  const context = vm.createContext({window: {meshObserver: api}, document: {getElementById: element, hasFocus: () => true,
    body: {classList: {toggle: (name, enabled) => { enabled ? classes.add(name) : classes.delete(name); }}}},
    navigator: {mediaDevices: media}, FaceMesh, innerWidth: 1440, innerHeight: 900,
    Option: function(text, value) { return {text, value}; }, requestAnimationFrame: callback => raf.push(callback),
    addEventListener: (name, callback) => { listeners[name] = callback; }});
  vm.runInContext(rendererSource, context, {filename: 'observer-renderer.js'}); await flush();
  element('camera').value = 'camera-1'; element('display').value = '7';
  return {api, media, video, calls, engines, streams, makeStream, elements, classes, listeners, raf, frames, element,
    run: code => vm.runInContext(code, context), onStop: () => stopCallback(),
    paint: async () => { for (let index = 0; index < 2; index += 1) { for (const callback of raf.splice(0)) callback(0); await flush(); } }};
}

test('main startup is inert and Stop cancels a pending permission result', async () => {
  const h = await mainHarness(), pending = deferred();
  assert.equal(h.calls.permissionRequests, 0); assert.equal(h.calls.publications.length, 0);
  h.setPermission(() => pending.promise);
  const startup = h.invoke('start', {cameraID: 'camera-1', displayID: '7'});
  await flush(); await h.invoke('stop'); pending.resolve(true);
  await assert.rejects(startup, /cancelled/);
  assert.equal((await h.invoke('bootstrap')).captureActive, false);
  assert.equal(h.permission.check(h.window.webContents, 'media', '', {mediaType: 'video'}), false);
  assert.ok(h.calls.clears > 0);
});

test('camera choices require an explicit permission request but never grant capture', async () => {
  const h = await mainHarness();
  const choices = await h.invoke('allow-camera-choices');
  assert.equal(choices.captureActive, false); assert.equal(h.calls.permissionRequests, 1);
  assert.equal(h.permission.check(h.window.webContents, 'media', '', {mediaType: 'video'}), true);
  h.permission.request(h.window.webContents, 'media', allowed => assert.equal(allowed, false), {mediaTypes: ['video']});
  assert.equal(h.calls.publications.length, 0);
  const pending = deferred(); h.setPermission(() => pending.promise);
  const permission = h.invoke('allow-camera-choices'); await flush();
  await h.invoke('stop'); pending.resolve(true);
  await assert.rejects(permission, /cancelled/);
  assert.equal(h.permission.check(h.window.webContents, 'media', '', {mediaType: 'video'}), false);
  assert.equal((await h.invoke('bootstrap')).captureActive, false);
  assert.equal(h.calls.lastSend, undefined, 'Caller Stop must not send a delayed duplicate stop notification.');
});

test('main IPC accepts only its exact main frame and denies extra device/network authority', async () => {
  const h = await mainHarness();
  await assert.rejects(h.invoke('bootstrap', undefined, {sender: {id: 888}, senderFrame: {url: pageURL}}), /Unknown/);
  await assert.rejects(h.invoke('bootstrap', undefined, {sender: h.window.webContents, senderFrame: {url: pageURL, routingId: 2, processId: 10}}), /Unknown/);
  await h.invoke('start', {cameraID: 'camera-1', displayID: '7'});
  assert.equal(h.permission.check(h.window.webContents, 'media', '', {mediaType: 'audio'}), false);
  assert.equal(h.permission.check({id: 888}, 'media', '', {mediaType: 'video'}), false);
  h.permission.request(h.window.webContents, 'media', allowed => assert.equal(allowed, false), {mediaTypes: ['video', 'audio']});
  h.permission.display({}, value => assert.equal(Object.keys(value).length, 0));
  h.permission.web({url: 'https://example.test'}, value => assert.equal(value.cancel, true));
  assert.ok(h.calls.requires.every(name => !/robot|speech|server|cursor-monitor/u.test(name)));
});

test('verified engine scripts, fetch and WASM URLs share the UI origin and serve only allowlisted assets', async () => {
  const h = await mainHarness(), renderer = await rendererHarness();
  assert.ok(htmlSource.includes('src="mesh-observer://ui/engine/face_mesh.js"'));
  assert.equal(htmlSource.includes('mesh-observer://engine'), false);
  assert.ok(htmlSource.includes("connect-src 'self'"));
  await renderer.run('start()');
  const url = renderer.engines[0].options.locateFile('fixture.wasm');
  assert.equal(url, 'mesh-observer://ui/engine/assets/fixture.wasm');
  for (const [requestURL, contentType] of [[pageURL, 'text/html'], ['mesh-observer://ui/engine/face_mesh.js', 'application/javascript'], [url, 'application/wasm']]) {
    const result = h.calls.protocol({url: requestURL, method: 'GET'});
    assert.equal(result.status, 200); assert.equal(result.headers.get('content-type'), contentType);
  }
  for (const requestURL of ['mesh-observer://engine/face_mesh.js', 'mesh-observer://ui/engine/assets/not-verified.data', 'mesh-observer://ui/observer-main.cjs']) {
    assert.equal(h.calls.protocol({url: requestURL, method: 'GET'}).status, 404);
  }
  assert.equal(h.calls.protocol({url, method: 'POST'}).status, 404);
  const scheme = h.calls.schemes[0];
  assert.equal(scheme.privileges.standard, true); assert.equal(scheme.privileges.secure, true);
  assert.equal(scheme.privileges.supportFetchAPI, true); assert.equal(scheme.privileges.corsEnabled, false);
  await renderer.run('stop()');
});

test('target collection waits for full-screen placement and finite matching viewport dimensions', async () => {
  const h = await mainHarness(); await h.invoke('start', {cameraID: 'camera-1', displayID: '7'});
  await h.invoke('calibrate');
  const presentation = {index: 0, width: 1440, height: 900, focused: true};
  await assert.rejects(h.invoke('target-ready', presentation), /full display/);
  h.window.fullscreen = true;
  await assert.rejects(h.invoke('target-ready', {index: 0, focused: true}), /full display/);
  await assert.rejects(h.invoke('target-ready', {...presentation, width: NaN}), /full display/);
  await assert.rejects(h.invoke('target-ready', {...presentation, height: 8990}), /full display/);
  await assert.rejects(h.invoke('target-ready', {...presentation, index: 1}), /full display/);
  await assert.rejects(h.invoke('target-ready', {...presentation, focused: 'yes'}), /full display/);
  h.window.bounds.x = 0; // A different display can have identical dimensions.
  await assert.rejects(h.invoke('target-ready', presentation), /full display/);
  h.window.bounds.x = -1440;
  const ready = await h.invoke('target-ready', presentation);
  assert.equal(ready.progress.targetActive, true); assert.equal(ready.target.index, 0);
  await h.invoke('stop');
  assert.equal((await h.invoke('target-ready', presentation)).calibrating, false);
});

// Original synthetic landmarks exercise the main/core seam; no image or device
// is used. The eye-relative features have a known affine display relationship.
function fixtureFace(target) {
  const u = 0.35 + target.x * 0.18 + target.y * 0.035;
  const v = -0.08 + target.x * 0.022 + target.y * 0.13;
  const points = Array.from({length: 478}, () => ({x: 0.5, y: 0.5, z: 0}));
  for (const [a, b, iris, top1, bottom1, top2, bottom2, x] of [
    [33, 133, 468, 160, 144, 158, 153, 0.2], [362, 263, 473, 385, 380, 387, 373, 0.6],
  ]) {
    points[a] = {x, y: 0.4}; points[b] = {x: x + 0.15, y: 0.4};
    points[iris] = {x: x + u * 0.15, y: 0.4 + v * 0.15};
    for (const [index, dx, dy] of [[top1, 0.045, -0.02], [bottom1, 0.045, 0.02], [top2, 0.105, -0.02], [bottom2, 0.105, 0.02]]) {
      points[index] = {x: x + dx, y: 0.4 + dy};
    }
  }
  return points;
}

test('seven acknowledged targets use real capture timestamps and Stop clears validated output', async () => {
  const h = await mainHarness({managed: true}); await h.invoke('start', {cameraID: 'camera-1', displayID: '7'});
  let state = await h.invoke('calibrate'); h.window.fullscreen = true;
  const frame = (target, capturedAt = h.now) => h.invoke('frame', {cameraID: 'camera-1', capturedAt, focused: true, faces: [fixtureFace(target)]});
  for (let index = 0; index < 7; index += 1) {
    const target = state.target;
    assert.equal(target.index, index); assert.equal(state.progress.targetActive, false);
    assert.equal((await frame(target)).progress.samples, 0, 'No collection before target acknowledgement.');
    h.setNow(h.now + 1);
    state = await h.invoke('target-ready', {index, width: 1440, height: 900, focused: true});
    assert.equal(state.progress.targetActive, true);
    for (let sample = 0; sample < 12; sample += 1) {
      h.setNow(h.now + 110); state = await frame(target);
      assert.equal(state.progress.samples, sample + 1);
    }
    state = await h.invoke('finish-target');
    assert.equal(state.ok, true, state.reason); assert.equal(state.progress.completedTargets, index + 1);
    assert.equal(h.calls.publications.length, 0, 'No gaze publication before both held-out targets finish.');
    h.setNow(h.now + 200);
  }
  assert.equal(state.validated, true); assert.equal(state.calibrating, false); assert.equal(state.target, null);
  assert.equal(state.readinessCode, 'projection-unavailable', 'A validated fit is not yet a published coordinate.');
  const validated = h.calls.receipts.find(value => value.reason === 'calibration-validated');
  assert.equal(validated.validated, true); assert.equal(validated.completedTargets, 7);
  assert.equal(validated.cameraID, 'camera-1'); assert.equal(validated.displayID, '7');
  assert.equal(typeof validated.calibrationID, 'string'); assert.equal(validated.output, '/fixture/observation.json');
  assert.equal(h.calls.receipts.filter(value => value.reason === 'target-ready').length, 7);
  assert.equal(h.calls.receipts.filter(value => value.reason === 'target-finished').length, 6);
  const capturedAt = h.now - 45;
  await frame({x: 0.63, y: 0.31}, capturedAt);
  const observation = h.calls.latest;
  assert.equal(observation.capturedAt, new Date(capturedAt).toISOString());
  assert.equal(observation.cameraID, 'camera-1'); assert.equal(observation.displayID, '7');
  assert.ok(Math.abs(observation.x - 0.63) < 0.001 && Math.abs(observation.y - 0.31) < 0.001);
  assert.equal('confidence' in observation, false);
  assert.equal((await h.invoke('bootstrap')).readinessCode, 'validated');
  h.setNow(h.now + 110);
  const lost = await h.invoke('frame', {cameraID: 'camera-1', capturedAt: h.now, focused: true, faces: []});
  assert.equal(lost.validated, true, 'A valid historical fit does not disappear when a face leaves.');
  assert.equal(lost.readinessCode, 'no-face'); assert.equal(h.calls.latest, null, 'Face loss revokes current coordinates.');
  h.setNow(h.now + 110);
  assert.equal((await frame({x: 0.63, y: 0.31})).readinessCode, 'validated'); assert.ok(h.calls.latest);
  h.setNow(h.now + 100);
  await frame({x: 0.63, y: 0.31}, h.now - 1001);
  assert.equal(h.calls.latest, null, 'Stale frame revokes the current observation.');
  await frame({x: 0.63, y: 0.31}); assert.ok(h.calls.latest);
  const publications = h.calls.publications.length;
  h.stdin.emit('data', Buffer.from('{"command":"stop"}\n')); assert.equal(h.calls.latest, null);
  assert.equal(h.calls.receipts.at(-1).captureActive, false); assert.equal(h.calls.receipts.at(-1).validated, false);
  for (const value of h.calls.receipts) {
    assert.equal(value.schemaVersion, 1);
    assert.deepEqual(Object.keys(value).sort(), ['schemaVersion','event','reason','captureActive','frameObserved','calibrating','validated',
      'cameraID','selectedCameraID','displayID','calibrationID','output','completedTargets','totalTargets',
      'readinessCode','calibrationIssue','featureIssue','sampleCount'].sort());
  }
  h.setNow(h.now + 110); await frame({x: 0.63, y: 0.31});
  assert.equal(h.calls.publications.length, publications);
});

test('readiness distinguishes unusable frames, recovers with landmarks and avoids per-frame receipt spam', async () => {
  const h = await mainHarness({managed: true});
  assert.equal((await h.invoke('bootstrap')).readinessCode, 'camera-off');
  assert.equal((await h.invoke('start', {cameraID: 'camera-1', displayID: '7'})).readinessCode, 'waiting-frame');
  const face = fixtureFace({x: 0.5, y: 0.5});
  const send = async faces => { h.setNow(h.now + 110); return h.invoke('frame', {cameraID: 'camera-1', capturedAt: h.now, focused: true, faces}); };
  for (const [faces, code] of [[[], 'no-face'], [[face, face], 'multiple-faces'], [[[]], 'eyes-unavailable'], [[face], 'ready-to-calibrate']]) {
    const state = await send(faces);
    assert.equal(state.readinessCode, code); assert.equal(state.validated, false); assert.equal(h.calls.latest, null);
    const count = h.calls.receipts.length;
    await send(faces); await send(faces);
    assert.equal(h.calls.receipts.length, count, 'unchanged readiness does not stream repeated receipts');
  }
  const stale = await h.invoke('frame', {cameraID: 'wrong-camera', capturedAt: h.now, focused: true, faces: [face]});
  assert.equal(stale.readinessCode, 'stale-frame'); assert.equal(h.calls.latest, null);
  await send([face]);
  await h.invoke('calibrate'); h.window.fullscreen = true;
  assert.equal((await send([face])).readinessCode, 'placing-target');
  assert.equal((await h.invoke('target-ready', {index: 0, width: 1440, height: 900, focused: true})).readinessCode, 'collecting');
  const rejected = await h.invoke('finish-target');
  assert.equal(rejected.calibrationIssue, 'need-12-fresh-samples');
  assert.equal((await send([])).readinessCode, 'no-face');
  assert.equal((await send([face])).calibrationIssue, 'need-12-fresh-samples', 'failure explanation survives later frames');
  for (let i = 0; i < 12; i += 1) await send([face]);
  const saved = await h.invoke('finish-target');
  assert.equal(saved.ok, true); assert.equal(saved.calibrationIssue, null); assert.equal(saved.readinessCode, 'placing-target');
  const stopped = await h.invoke('stop');
  assert.equal(stopped.readinessCode, 'camera-off'); assert.equal(stopped.sampleCount, 0); assert.equal(stopped.calibrationIssue, null);
});

test('renderer explains readiness and failed target collection without exposing machine reason codes', async () => {
  const h = await rendererHarness(); await h.run('start()');
  h.run("displayState({captureActive:true, readinessCode:'no-face'})");
  assert.match(h.element('status').textContent, /No face found/); assert.equal(h.element('calibrate').disabled, true);
  h.run("displayState({captureActive:true, readinessCode:'ready-to-calibrate'})");
  assert.match(h.element('status').textContent, /Eyes are visible/); assert.equal(h.element('calibrate').disabled, false);
  h.run("displayState({captureActive:true, readinessCode:'eyes-unavailable', calibrationIssue:'held-out-error'})");
  assert.match(h.element('status').textContent, /Eye landmarks are not usable/);
  assert.match(h.element('status').textContent, /accuracy check failed/);
  assert.equal(h.element('status').textContent.includes('held-out-error'), false);
  h.api.finishTarget = async () => ({ok:false, reason:'need-12-fresh-samples'});
  await h.run('finish()'); assert.match(h.element('instruction').textContent, /Not enough usable eye samples/);
  await h.run('stop()'); assert.match(h.element('status').textContent, /Camera off/);
});

test('managed ready waits for UI load; standalone installs no parent control pipe or status stream', async () => {
  const load = deferred(), h = await mainHarness({managed: true, load});
  assert.equal(h.calls.receipts.length, 0); assert.equal(h.calls.permissionRequests, 0);
  load.resolve(); await flush();
  assert.equal(h.calls.receipts.length, 1); assert.equal(h.calls.receipts[0].event, 'ready');
  assert.equal(h.calls.receipts[0].captureActive, false); assert.equal(h.calls.receipts[0].cameraID, null);
  const standalone = await mainHarness();
  assert.equal(standalone.calls.stdout.length, 0); assert.equal(standalone.stdin.listenerCount('data'), 0);
  assert.equal(standalone.calls.stdinResumes, undefined);
});

test('managed mode refuses a terminal, regular file, old runtime or invalid staging before creating a window', async () => {
  for (const [options, reason] of [
    [{tty: true}, 'parent-pipe-required'], [{fifo: false}, 'parent-pipe-required'],
    [{electronVersion: '41.3.0'}, 'unsupported-electron-runtime'],
    [{electronVersion: '42.0.0'}, 'unsupported-electron-runtime'],
    [{invalidManifest: true}, 'startup-validation-failed'], [{singleInstance: false}, 'already-running'],
  ]) {
    const h = await mainHarness({...options, managed: true, expectWindow: false});
    assert.ok(h.calls.receipts.some(value => value.event === 'error' && value.reason === reason));
    assert.equal(h.calls.receipts.at(-1).event, 'exit'); assert.equal(h.calls.permissionRequests, 0);
    assert.equal(h.app.quitCount, 1);
  }
});

test('fragmented parent Stop cancels pending camera permission; only explicit UI can restart', async () => {
  const h = await mainHarness({managed: true}), permission = deferred();
  h.setPermission(() => permission.promise);
  const startup = h.invoke('start', {cameraID: 'camera-1', displayID: '7'}); await flush();
  h.stdin.emit('data', Buffer.from('{"comm'));
  h.stdin.emit('data', Buffer.from('and":"stop"}\n')); permission.resolve(true);
  await assert.rejects(startup, /cancelled/);
  assert.equal(h.app.quitCount, undefined); assert.equal((await h.invoke('bootstrap')).captureActive, false);
  assert.equal(h.calls.receipts.at(-1).reason, 'parent-stop');
  h.setPermission(async () => true); await h.invoke('start', {cameraID: 'camera-1', displayID: '7'});
  assert.equal(h.calls.receipts.at(-1).reason, 'capture-authorized');
  assert.equal(h.calls.receipts.at(-1).captureActive, true);
  assert.equal(h.calls.receipts.at(-1).cameraID, null, 'Permission alone is not a verified frame.');
  h.stdin.emit('data', Buffer.from('{"command":"quit"}\n'));
  assert.equal(h.app.quitCount, 1); assert.equal(h.calls.receipts.at(-1).reason, 'parent-quit');
  assert.equal(h.calls.receipts.at(-1).captureActive, false);
});

test('parent EOF before app readiness prevents late window creation and permission work', async () => {
  const ready = deferred(), h = await mainHarness({managed: true, ready, expectWindow: false});
  h.stdin.emit('end'); ready.resolve(); await flush();
  assert.equal(h.app.quitCount, 1); assert.equal(h.calls.receipts.at(-1).reason, 'parent-eof');
  assert.equal(h.calls.permissionRequests, 0); assert.equal(h.calls.receipts.some(value => value.event === 'ready'), false);
});

test('EOF, pipe errors and SIGTERM clear output, cancel permission and quit exactly once', async () => {
  for (const event of ['end', 'error', 'close', 'SIGTERM']) {
    const h = await mainHarness({managed: true}), permission = deferred();
    h.setPermission(() => permission.promise);
    const startup = h.invoke('start', {cameraID: 'camera-1', displayID: '7'}); await flush();
    const clears = h.calls.clears;
    if (event === 'SIGTERM') h.process.emit(event); else h.stdin.emit(event, event === 'error' ? Error('private fixture detail') : undefined);
    permission.resolve(true); await assert.rejects(startup, /cancelled/);
    assert.ok(h.calls.clears > clears); assert.equal(h.calls.latest, null); assert.equal(h.app.quitCount, 1);
    assert.equal(h.calls.receipts.at(-1).event, 'exit'); assert.equal(h.calls.receipts.at(-1).captureActive, false);
    assert.equal(h.calls.stdout.join('').includes('private fixture detail'), false);
    const count = h.calls.receipts.length; h.stdin.emit('end'); h.process.emit('SIGTERM');
    assert.equal(h.app.quitCount, 1); assert.equal(h.calls.receipts.length, count);
  }
});

test('parent loss or status-pipe failure revokes already active capture and blocks subsequent IPC', async () => {
  for (const channel of ['stdin', 'stdout']) {
    const h = await mainHarness({managed: true}); await h.invoke('start', {cameraID: 'camera-1', displayID: '7'});
    assert.equal((await h.invoke('bootstrap')).captureActive, true);
    if (channel === 'stdin') h.stdin.emit('end'); else h.stdout.emit('error', Error('fixture broken pipe'));
    assert.equal(h.app.quitCount, 1); assert.equal(h.calls.latest, null);
    assert.equal(h.permission.check(h.window.webContents, 'media', '', {mediaType: 'video'}), false);
    await assert.rejects(h.invoke('start', {cameraID: 'camera-1', displayID: '7'}), /Unknown observer frame/);
    assert.equal(h.calls.permissionRequests, 1);
  }
});

test('invalid, oversized or capture commands stop and quit without granting camera authority', async () => {
  for (const bytes of ['{bad}\n', '{"command":"start"}\n', '{"command":"stop","other":true}\n', 'x'.repeat(1025)]) {
    const h = await mainHarness({managed: true});
    h.stdin.emit('data', Buffer.from(bytes));
    assert.equal(h.app.quitCount, 1); assert.equal(h.calls.permissionRequests, 0);
    assert.ok(h.calls.receipts.some(value => value.event === 'error'));
    assert.equal(h.calls.receipts.at(-1).captureActive, false);
    assert.equal(h.calls.stdout.join('').includes(bytes.trim()), false);
  }
});

test('managed errors are sanitized and an unavailable status pipe shuts down instead of buffering indefinitely', async () => {
  const h = await mainHarness({managed: true}); h.setPermission(async () => false);
  await assert.rejects(h.invoke('start', {cameraID: 'camera-1', displayID: '7'}), /permission/);
  assert.equal(h.calls.receipts.at(-1).event, 'error'); assert.equal(h.calls.receipts.at(-1).reason, 'request-start-failed');
  const blocked = await mainHarness({managed: true, statusWritable: false});
  assert.equal(blocked.calls.stdout.length, 1); assert.equal(blocked.app.quitCount, 1);
  assert.equal(blocked.calls.permissionRequests, 0);
});

test('renderer Stop during getUserMedia closes a late returned stream without constructing an engine', async () => {
  const h = await rendererHarness(), permission = deferred();
  h.media.getUserMedia = () => permission.promise;
  const startup = h.run('start()'); await flush(); await h.run('stop()');
  const lateStream = h.makeStream(); permission.resolve(lateStream); await startup;
  assert.equal(lateStream.track.stops, 1); assert.equal(h.engines.length, 0);
  assert.equal(h.video.srcObject, null); assert.equal(h.run('running'), false);
});

test('refresh is prompt-free on load and explicit camera choices can be cancelled before enumeration', async () => {
  const h = await rendererHarness(), permission = deferred();
  assert.equal(h.calls.choices, 0); assert.equal(h.calls.media, 0);
  let enumerate = 0;
  h.api.allowCameraChoices = () => { h.calls.choices += 1; return permission.promise; };
  h.media.enumerateDevices = async () => { enumerate += 1; return []; };
  const refresh = h.element('refresh').onclick(); await flush();
  assert.equal(h.calls.choices, 1); assert.equal(h.element('stop').disabled, false);
  await h.run('stop()'); permission.resolve({captureActive: false}); await refresh;
  assert.equal(enumerate, 0); assert.equal(h.calls.media, 0);
  assert.equal(h.element('camera').value, 'camera-1'); assert.equal(h.element('start').disabled, false);
});

test('late device enumeration cannot reset choices or enable Start during a pending startup', async () => {
  const h = await rendererHarness(), devices = deferred(), permission = deferred();
  h.media.enumerateDevices = () => devices.promise;
  const refresh = h.run('refreshChoices()'); await flush();
  h.api.start = () => { h.calls.start += 1; return permission.promise; };
  const startup = h.run('start()'); await flush();
  devices.resolve([]); await refresh;
  assert.equal(h.element('camera').value, 'camera-1'); assert.equal(h.element('start').disabled, true);
  await h.run('start()'); assert.equal(h.calls.start, 1);
  await h.run('stop()'); permission.resolve({captureActive: true}); await startup;
  assert.equal(h.calls.media, 0);
});

test('a late Stop reply cannot replace new-session status, even when engine close throws synchronously', async () => {
  const h = await rendererHarness(), response = deferred(); await h.run('start()');
  h.engines[0].close = () => { throw Error('fixture close error'); };
  h.api.stop = () => response.promise;
  const stopping = h.run('stop()'); await flush();
  assert.equal(h.streams[0].track.stops, 1); assert.equal(h.video.srcObject, null);
  await h.run('start()'); response.resolve({captureActive: false}); await stopping;
  assert.equal(h.run('running'), true); assert.match(h.element('status').textContent, /Camera preview active/);
});

test('renderer drops stale post-start, calibration and finish responses after Stop', async () => {
  for (const pendingOperation of ['bootstrap', 'calibrate', 'finish']) {
    const h = await rendererHarness(), response = deferred(); let operation;
    if (pendingOperation === 'bootstrap') { h.api.bootstrap = () => response.promise; operation = h.run('start()'); await flush(); }
    else {
      await h.run('start()');
      if (pendingOperation === 'calibrate') { h.api.beginCalibration = () => response.promise; operation = h.element('calibrate').onclick(); }
      else { h.api.finishTarget = () => response.promise; operation = h.run('finish()'); }
    }
    await h.run('stop()');
    response.resolve({ok: true, captureActive: true, calibrating: true, target: {index: 1, x: 0.85, y: 0.15}, progress: {targetActive: false}});
    await operation; await flush();
    assert.equal(h.classes.has('calibrating'), false, pendingOperation);
    assert.equal(h.run('running'), false);
    assert.match(h.element('status').textContent, /Camera off/);
  }
});

test('old frame finalizers cannot reopen the newer session packet gate', async () => {
  const h = await rendererHarness(), oldReply = deferred(), newReply = deferred();
  await h.run('start()'); h.api.frame = () => oldReply.promise;
  const oldFrame = h.engines[0].results({multiFaceLandmarks: []}); await flush();
  await h.run('stop()'); await h.run('start()'); h.api.frame = () => newReply.promise;
  const newFrame = h.engines[1].results({multiFaceLandmarks: []}); await flush();
  assert.equal(h.run('packetPending'), true);
  oldReply.resolve({captureActive: false, calibrating: false}); await oldFrame;
  assert.equal(h.run('packetPending'), true);
  newReply.resolve({captureActive: true, calibrating: false}); await newFrame;
  assert.equal(h.run('packetPending'), false);
  await h.run('stop()');
});

test('Stop releases an unfinished target presentation and a new session can acknowledge its own target', async () => {
  const h = await rendererHarness(); await h.run('start()'); await h.element('calibrate').onclick();
  assert.equal(h.run('targetReadyPending'), true);
  await h.run('stop()'); await h.run('start()'); await h.element('calibrate').onclick();
  await h.paint(); await flush();
  assert.equal(h.calls.ready, 1); assert.equal(h.run('latestState.progress.targetActive'), true);
  await h.run('stop()');
});

test('target acknowledgement retries after an incomplete full-screen transition without another resize', async () => {
  const h = await rendererHarness(); await h.run('start()');
  const targetReady = h.api.targetReady; let attempt = 0;
  h.api.targetReady = async presentation => {
    if (++attempt === 1) throw Error('Target is not yet on the chosen full display.');
    return targetReady(presentation);
  };
  await h.element('calibrate').onclick(); await h.paint();
  assert.equal(attempt, 1); assert.equal(h.run('latestState.progress.targetActive'), false);
  await h.paint(); await h.paint();
  assert.equal(attempt, 2); assert.equal(h.run('latestState.progress.targetActive'), true);
  await h.run('stop()');
});

test('preload exports only the observation IPC surface without leaking callbacks or Node', () => {
  const calls = [], listeners = [];
  let exported;
  const context = vm.createContext({require(name) {
    assert.equal(name, 'electron');
    return {contextBridge: {exposeInMainWorld(name, value) { assert.equal(name, 'meshObserver'); exported = value; }},
      ipcRenderer: {invoke: (...args) => { calls.push(args); return Promise.resolve({}); }, on: (...args) => { listeners.push(args); return {secretNodeObject: true}; }}};
  }});
  vm.runInContext(preloadSource, context);
  assert.deepEqual(Object.keys(exported).sort(), ['allowCameraChoices','beginCalibration','bootstrap','finishTarget','frame','onStop','start','stop','targetReady']);
  assert.equal(exported.onStop(() => {}), undefined);
  exported.frame({cameraID: 'fixture'}); assert.equal(calls[0][0], 'mesh-observer:frame');
  assert.equal(listeners[0][0], 'mesh-observer:stop');
});

test('calibration survives full-screen work-area changes but real display geometry changes stop capture', async () => {
  const h = await mainHarness({managed: true});
  await h.invoke('start', {cameraID: 'camera-1', displayID: '7'});
  await h.invoke('calibrate');
  h.screen.emit('display-metrics-changed', {}, h.display, ['workArea']);
  let state = await h.invoke('bootstrap');
  assert.equal(state.captureActive, true, 'Full-screen menu/Dock changes must not stop the camera');
  assert.equal(state.calibrating, true);
  h.screen.emit('display-metrics-changed', {}, {...h.display, id: 99}, ['bounds']);
  assert.equal((await h.invoke('bootstrap')).calibrating, true, 'An unrelated display change does not invalidate the target');
  h.screen.emit('display-metrics-changed', {}, h.display, ['scaleFactor']);
  assert.equal((await h.invoke('bootstrap')).captureActive, false, 'Real geometry changes must revoke calibration');
});

test('transient full-screen focus loss collects nothing and does not cancel before the first target is acknowledged', async () => {
  const h = await mainHarness({managed: true});
  await h.invoke('start', {cameraID: 'camera-1', displayID: '7'}); await h.invoke('calibrate');
  const frame = () => h.invoke('frame', {cameraID:'camera-1', capturedAt:h.now, focused:false, faces:[fixtureFace({x:0.5,y:0.5})]});
  const transitioning = await frame();
  assert.equal(transitioning.calibrating, true); assert.equal(transitioning.progress.samples, 0);
  h.window.fullscreen = true;
  await h.invoke('target-ready', {index:0,width:1440,height:900,focused:true});
  h.setNow(h.now + 110);
  const lost = await frame();
  assert.equal(lost.calibrating, false); assert.equal(lost.calibrationIssue, 'focus-lost');
  assert.equal(h.calls.latest, null);
});

test('camera discovery failure remains visible after controls are re-enabled', async () => {
  const h = await rendererHarness();
  h.api.allowCameraChoices = async () => { throw Error('Camera permission was not granted.'); };
  await h.element('refresh').onclick();
  assert.equal(h.element('status').textContent, 'Camera permission was not granted.');
  assert.equal(h.element('refresh').disabled, false);
  assert.equal(h.element('start').disabled, false);
  assert.equal(h.calls.media, 0);
});


test('notched fullscreen viewport preserves full-display target coordinates', async () => {
 const h = await mainHarness(); await h.invoke('start', {cameraID:'camera-1',displayID:'7'});
 await h.invoke('calibrate'); h.window.fullscreen = true;
 h.window.bounds = {x:-1440,y:33,width:1440,height:867};
 const state = await h.invoke('bootstrap');
 assert.ok(Math.abs(state.renderTarget.y * 867 + 33 - state.target.y * 900) < 0.001);
 const packet = {index:0,width:1440,height:867,focused:true};
 await assert.rejects(h.invoke('target-ready', packet), /full display/);
 const ready = await h.invoke('target-ready', {...packet,viewport:state.viewport});
 assert.equal(ready.progress.targetActive,true);
});


test('startup lists previously authorized cameras without a prompt or capture', async () => {
  const h = await mainHarness({cameraPermission: 'granted'});
  const value = await h.invoke('bootstrap');
  assert.equal(value.cameraPermission, 'granted');
  assert.equal(h.permission.check(h.window.webContents, 'media', '', {mediaType: 'video'}), true);
  assert.equal(h.permission.check(h.window.webContents, 'media', '', {mediaType: 'audio'}), false);
  assert.equal(value.captureActive, false);
  assert.equal(h.calls.permissionRequests, 0);
  let allowed;
  h.permission.request(h.window.webContents, 'media', value => { allowed = value; }, {mediaTypes: ['video']});
  assert.equal(allowed, false);
});

test('unapproved camera discovery explains permission and still lists displays', async () => {
  const h = await rendererHarness();
  h.api.bootstrap = async () => ({cameraPermission: 'not-determined', displays: [{id: '7', label: 'Built in'}]});
  h.media.enumerateDevices = async () => [];
  await h.run('refreshChoices()');
  assert.equal(h.element('refresh').textContent, 'Enable camera access');
  assert.match(h.element('status').textContent, /Camera access is needed/);
  assert.equal(h.element('display').options.length, 2);
  assert.equal(h.element('start').disabled, true);
  assert.equal(h.calls.media, 0);
});

test('calibration UX disables premature saving and explains failed mapping numerically', async () => {
  const h = await rendererHarness();
  h.run("displayState({calibrating:true,target:{index:0,x:.15,y:.15},progress:{targetActive:true},quality:{samples:3,minSamples:12,spanMs:200,minSpanMs:1200,ready:false,reason:'need-12-fresh-samples'}})");
  assert.equal(h.element('collect').disabled, true);
  assert.match(h.element('quality').textContent, /3\/12/);
  h.run("displayState({calibrating:true,target:{index:0,x:.15,y:.15},progress:{targetActive:true},quality:{samples:20,minSamples:12,spanMs:1400,minSpanMs:1200,ready:true}})");
  assert.equal(h.element('collect').disabled, false);
  assert.match(h.element('collect').textContent, /Ready/);
  h.run("displayState({calibrating:false,calibrationAttempts:[{targetNumber:6,kind:'held-out',ok:false,reason:'held-out-error',quality:{samples:24,spanMs:1600},accuracy:{target:{x:.3,y:.6},predicted:{x:.55,y:.6},error:.25,limit:.15}}]})");
  assert.match(h.element('diagnostics').textContent, /25.0% of screen width/);
  assert.match(h.element('diagnostics').textContent, /does not identify the cause/);
  assert.equal(JSON.parse(h.element('diagnostic-json').value).attempts[0].targetNumber, 6);
});

test('target placement stops retrying and explains setup failure after eight seconds', async () => {
  const h = await rendererHarness();
  h.run("latestState={calibrating:true,target:{index:0},progress:{targetActive:false}}; placementIndex=0; placementStartedAt=Date.now()-9000;");
  await h.run('presentTarget()');
  assert.equal(h.calls.ready, 0);
  assert.match(h.element('instruction').textContent, /setup failure, not your gaze/);
});

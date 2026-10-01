'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {extractFeature, GazeCalibration} = require('../ops/neocursor_mesh_adapter/calibration.cjs');

const identity = {cameraID: 'explicit-camera', displayID: '7', calibrationID: 'attended-fixture'};
const baseTime = 1_790_000_000_000;
function makeFace(u = 0.5, v = 0, closed = false) {
  const points = Array.from({length: 478}, () => ({x: 0.5, y: 0.5, z: 0}));
  for (const [a, b, iris, u1, l1, u2, l2, start] of [
    [33, 133, 468, 160, 144, 158, 153, 0.2], [362, 263, 473, 385, 380, 387, 373, 0.6],
  ]) {
    const width = 0.15, gap = closed ? 0.002 : 0.04;
    points[a] = {x: start, y: 0.4}; points[b] = {x: start + width, y: 0.4};
    points[iris] = {x: start + u * width, y: 0.4 + v * width};
    points[u1] = {x: start + width * 0.3, y: 0.4 - gap / 2};
    points[l1] = {x: start + width * 0.3, y: 0.4 + gap / 2};
    points[u2] = {x: start + width * 0.7, y: 0.4 - gap / 2};
    points[l2] = {x: start + width * 0.7, y: 0.4 + gap / 2};
  }
  return {multiFaceLandmarks: [points]};
}
// Synthetic camera features with shear and unequal scales; fitting must learn the
// display relation rather than assuming landmark coordinates are screen points.
function featureFor(target) { return {x: 0.35 + target.x * 0.18 + target.y * 0.035, y: -0.08 + target.x * 0.022 + target.y * 0.13}; }
function collect(calibration, feature, start, options = {}) {
  calibration.beginTarget(start);
  const count = options.count || 13, interval = options.interval || 110;
  for (let index = 0; index < count; index += 1) {
    const jitter = options.jitter ? (index % 2 ? options.jitter : -options.jitter) : 0;
    assert.equal(calibration.sample({x: feature.x + jitter, y: feature.y - jitter}, start + index * interval, start + index * interval), true);
  }
  return calibration.finishTarget(start + (count - 1) * interval);
}
function completed() {
  const calibration = new GazeCalibration(identity);
  let time = baseTime;
  for (const target of calibration.targets) {
    const result = collect(calibration, featureFor(target), time, {jitter: 0.0002});
    assert.equal(result.ok, true, result.reason); time += 2_000;
  }
  return {calibration, time};
}

test('extracts eye-relative features without treating raw landmarks as screen gaze', () => {
  const result = extractFeature(makeFace(0.62, 0.04));
  assert.ok(Math.abs(result.x - 0.62) < 1e-10 && Math.abs(result.y - 0.04) < 1e-10);
  assert.deepEqual(Object.keys(result).sort(), ['x', 'y']);
  assert.equal(extractFeature({multiFaceLandmarks: []}), null);
  const two = makeFace(); two.multiFaceLandmarks.push(two.multiFaceLandmarks[0]);
  assert.equal(extractFeature(two), null);
  assert.equal(extractFeature(makeFace(0.5, 0, true)), null);
  for (const mutate of [
    face => { face.multiFaceLandmarks[0].length = 468; },
    face => { face.multiFaceLandmarks[0][468].x = NaN; },
    face => { face.multiFaceLandmarks[0][386].z = Infinity; },
    face => { face.multiFaceLandmarks[0][33] = undefined; },
    face => { delete face.multiFaceLandmarks[0][33]; },
    face => { delete face.multiFaceLandmarks[0][1]; },
    face => { face.multiFaceLandmarks[0][263] = {...face.multiFaceLandmarks[0][362]}; },
    face => { face.multiFaceLandmarks[0][473].y = 0.95; },
  ]) { const face = makeFace(); mutate(face); assert.equal(extractFeature(face), null); }
});

test('requires explicit identity, target arm, 12 unique samples and real capture span', () => {
  assert.throws(() => new GazeCalibration({}), TypeError);
  assert.throws(() => new GazeCalibration({...identity, displayID: ' 7'}), TypeError);
  const calibration = new GazeCalibration(identity), feature = featureFor(calibration.currentTarget);
  assert.equal(calibration.sample(feature, baseTime, baseTime), false);
  assert.equal(calibration.project(feature, baseTime, baseTime), null);
  calibration.beginTarget(baseTime);
  assert.equal(calibration.sample(feature, baseTime, baseTime), true);
  assert.equal(calibration.sample(feature, baseTime, baseTime), false);
  assert.equal(calibration.sample(feature, baseTime - 1, baseTime), false);
  assert.equal(calibration.sample(feature, baseTime + 300, baseTime), false);
  assert.equal(calibration.sample({x: Infinity, y: 0}, baseTime + 1, baseTime + 1), false);
  assert.equal(calibration.sample({x: 1e308, y: 1e308}, baseTime + 1, baseTime + 1), false);
  assert.equal(calibration.finishTarget(baseTime).reason, 'need-12-fresh-samples');
  calibration.reset();
  assert.equal(collect(calibration, feature, baseTime, {count: 11, interval: 140}).reason, 'need-12-fresh-samples');
  calibration.reset();
  assert.equal(collect(calibration, feature, baseTime, {count: 12, interval: 10}).reason, 'need-1200ms-span');
  calibration.reset();
  const result = collect(calibration, feature, baseTime, {count: 12, interval: 110});
  assert.equal(result.ok, true); assert.equal(result.progress.completedTargets, 1);
  assert.equal(result.progress.targetActive, false);
  assert.equal(calibration.sample(feature, baseTime + 1400, baseTime + 1400), false);
});

test('rejects stale and unstable targets, keeping retained sample memory bounded', () => {
  const calibration = new GazeCalibration(identity), feature = featureFor(calibration.currentTarget);
  assert.equal(collect(calibration, feature, baseTime, {jitter: 0.04}).reason, 'unstable-eye-features');
  calibration.beginTarget(baseTime + 10_000);
  for (let index = 0; index < 13; index += 1) calibration.sample(feature, baseTime + 10_000 + index * 110, baseTime + 10_000 + index * 110);
  assert.equal(calibration.finishTarget(baseTime + 12_500).reason, 'latest-sample-stale');
  calibration.beginTarget(baseTime + 20_000);
  for (let index = 0; index < 250; index += 1) calibration.sample(feature, baseTime + 20_000 + index * 20, baseTime + 20_000 + index * 20);
  assert.ok(calibration.progress.samples <= 96);
  assert.equal(calibration.finishTarget(baseTime + 40_000).reason, 'need-12-fresh-samples');
});

test('rejects constant or collinear fits and disarms until explicitly restarted', () => {
  for (const makeFeature of [() => ({x: 0.4, y: 0.01}), target => ({x: 0.3 + target.x * 0.1, y: 0.01 + target.x * 0.2})]) {
    const calibration = new GazeCalibration(identity);
    let result;
    for (let index = 0; index < 5; index += 1) result = collect(calibration, makeFeature(calibration.currentTarget), baseTime + index * 2000);
    assert.equal(result.reason, 'degenerate-calibration');
    assert.equal(calibration.validated, false); assert.equal(calibration.progress.completedTargets, 0);
    assert.equal(calibration.progress.targetActive, false);
  }
});

test('a failed held-out target clears the fit rather than publishing training success', () => {
  const calibration = new GazeCalibration(identity);
  for (let index = 0; index < 5; index += 1) assert.equal(collect(calibration, featureFor(calibration.currentTarget), baseTime + index * 2000).ok, true);
  assert.equal(calibration.project(featureFor({x: 0.5, y: 0.5}), baseTime + 10_000, baseTime + 10_000), null);
  const wrong = featureFor({x: 0.9, y: 0.1});
  const result = collect(calibration, wrong, baseTime + 10_000);
  assert.equal(result.reason, 'held-out-error'); assert.equal(calibration.validated, false);
  assert.equal(calibration.progress.completedTargets, 0);
  assert.equal(calibration.project(wrong, baseTime + 12_000, baseTime + 12_000), null);
});

test('both held-out targets are required and the error threshold applies independently', () => {
  const calibration = new GazeCalibration(identity);
  for (let index = 0; index < 5; index += 1) assert.equal(collect(calibration, featureFor(calibration.currentTarget), baseTime + index * 2000).ok, true);
  const first = calibration.currentTarget;
  assert.equal(collect(calibration, featureFor({x: first.x + 0.14, y: first.y}), baseTime + 10_000).ok, true);
  assert.equal(calibration.validated, false);
  assert.equal(calibration.project(featureFor(first), baseTime + 12_000, baseTime + 12_000), null);
  const second = calibration.currentTarget;
  const failure = collect(calibration, featureFor({x: second.x - 0.16, y: second.y}), baseTime + 12_000);
  assert.equal(failure.reason, 'held-out-error');
  assert.equal(calibration.progress.completedTargets, 0);
  assert.equal(calibration.progress.targetActive, false);
});

test('validated projection preserves actual capture time and calibration provenance, with no confidence', () => {
  const {calibration, time} = completed();
  const target = {x: 0.63, y: 0.31}, feature = featureFor(target);
  const observation = calibration.project(feature, time, time + 40);
  assert.ok(Math.abs(observation.x - target.x) < 0.001 && Math.abs(observation.y - target.y) < 0.001);
  assert.equal(observation.capturedAt, new Date(time).toISOString());
  assert.equal(observation.schemaVersion, 2); assert.equal(observation.source, 'neocursor');
  assert.equal(observation.cameraID, identity.cameraID); assert.equal(observation.displayID, identity.displayID);
  assert.equal(observation.calibrationID, identity.calibrationID); assert.equal(observation.calibrated, true);
  assert.equal('confidence' in observation, false);
  assert.deepEqual({...observation.validation, maxError: 0}, {
    kind: 'held-out-screen-error', maxError: 0, trainingTargets: 5, heldOutTargets: 2,
    minSamplesPerTarget: 12, coordinateOrigin: 'top-left',
  });
  assert.ok(observation.validation.maxError <= 0.15);
  assert.equal(calibration.project(feature, time, time + 50), null);
  assert.equal(calibration.project(feature, time + 1, time + 2000), null);
  assert.equal(calibration.project(feature, time + 3000, time + 2000), null);
  assert.equal(calibration.project(featureFor({x: 1.4, y: 0.5}), time + 2100, time + 2100), null);
  assert.equal(calibration.project({x: NaN, y: 0}, time + 2200, time + 2200), null);
  calibration.reset();
  assert.equal(calibration.project(feature, time + 2300, time + 2300), null);
  assert.equal(calibration.sample(feature, time + 2300, time + 2300), false);
});

 test('rejected eye frames expose a bounded reason without landmark data', () => {
  const d = {};
  assert.equal(extractFeature(makeFace(0.5, 0, true), d), null);
  assert.deepEqual(d, {reason: 'eye-opening'});
  const missing = makeFace(); missing.multiFaceLandmarks[0].length = 468;
  assert.equal(extractFeature(missing, d), null);
  assert.deepEqual(d, {reason: 'iris-missing'});
  assert.ok(extractFeature(makeFace(), d));
  assert.deepEqual(d, {reason: null});
});

test('quality explains readiness and failed accuracy retains diagnostics after fit reset', () => {
  const c = new GazeCalibration(identity);
  assert.equal(c.quality(baseTime).reason, 'target-not-active');
  c.beginTarget(baseTime);
  assert.equal(c.quality(baseTime).reason, 'need-12-fresh-samples');
  for (let i = 0; i < 13; i++) c.sample(featureFor(c.currentTarget), baseTime + i * 110, baseTime + i * 110);
  assert.equal(c.quality(baseTime + 1320).ready, true);
  assert.equal(c.quality(baseTime + 6000).ready, false);
  c.reset();
  for (let i = 0; i < 5; i++) assert.equal(collect(c, featureFor(c.currentTarget), baseTime + i * 2000).ok, true);
  const target = c.currentTarget;
  const result = collect(c, featureFor({x: target.x + 0.25, y: target.y}), baseTime + 10000);
  assert.equal(result.reason, 'held-out-error');
  assert.equal(result.diagnostic.targetNumber, 6);
  assert.equal(result.diagnostic.quality.ready, true);
  assert.ok(Math.abs(result.diagnostic.accuracy.error - 0.25) < 1e-8);
  assert.equal(result.diagnostic.accuracy.limit, 0.15);
  assert.equal(c.progress.completedTargets, 0);
  assert.equal(c.validated, false);
  assert.equal(c.project(featureFor(target), baseTime + 12000, baseTime + 12000), null);
  assert.equal(JSON.stringify(result.diagnostic).includes('landmarks'), false);
});

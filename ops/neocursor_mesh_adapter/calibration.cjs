'use strict';

// Original observation-only calibration. No Electron, filesystem, camera, cursor,
// audio, network, or emotion inference is part of this module.
const TARGETS = Object.freeze([
  [0.15, 0.15], [0.85, 0.15], [0.50, 0.50], [0.15, 0.85], [0.85, 0.85],
  [0.30, 0.60], [0.70, 0.40],
].map(([x, y], index) => Object.freeze({x, y, index, kind: index < 5 ? 'training' : 'held-out'})));
const MIN_SAMPLES = 12;
const MIN_SPAN_MS = 1200;
const MAX_SAMPLE_AGE_MS = 4000;
const MAX_OUTPUT_AGE_MS = 1000;
const MAX_FUTURE_MS = 250;
const MAX_STD = 0.015;
const MAX_SPREAD = 0.06;

function finitePoint(point) {
  return point !== null && typeof point === 'object'
    && Number.isFinite(point.x) && Number.isFinite(point.y);
}

function validFeature(feature) {
  return finitePoint(feature) && feature.x >= 0.05 && feature.x <= 0.95 && Math.abs(feature.y) <= 0.35;
}

function validTime(value) {
  return Number.isSafeInteger(value) && value >= 0 && value <= 8_640_000_000_000_000;
}

function fresh(capturedAtMs, nowMs, maximumAge) {
  return validTime(capturedAtMs) && validTime(nowMs)
    && nowMs - capturedAtMs >= -MAX_FUTURE_MS && nowMs - capturedAtMs <= maximumAge;
}

function distance(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }

/**
 * MediaPipe FaceMesh refineLandmarks topology: iris centers 468/473, eye corners
 * 33/133 and 362/263. Feature axes are eye-relative and unmirrored; the attended
 * affine calibration learns their relation to top-left display coordinates.
 * Returns only {x,y}, never a confidence or an inferred mental state.
 */
function extractFeature(results, diagnostic = {}) {
  const reject = reason => { diagnostic.reason = reason; return null; };
  diagnostic.reason = null;
  const faces = results && results.multiFaceLandmarks;
  if (!Array.isArray(faces) || faces.length !== 1 || !Array.isArray(faces[0])) return null;
  const points = faces[0];
  if (points.length !== 478) return reject('iris-missing');
  // Visit every index explicitly: Array.every skips holes in malformed arrays.
  for (let index = 0; index < points.length; index += 1) {
    const point = points[index];
    if (!finitePoint(point) || point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1
        || (Object.hasOwn(point, 'z') && !Number.isFinite(point.z))) return reject('face-outside-frame');
  }
  // [left corner, right corner, iris, upper/lower lid pair, upper/lower pair]
  const eyes = [[33, 133, 468, 160, 144, 158, 153], [362, 263, 473, 385, 380, 387, 373]];
  const features = [];
  for (const [aID, bID, irisID, u1, l1, u2, l2] of eyes) {
    const a = points[aID], b = points[bID], iris = points[irisID];
    const dx = b.x - a.x, dy = b.y - a.y, width = Math.hypot(dx, dy);
    if (width < 0.008 || width > 0.4) return reject('eye-size');
    const opening = (distance(points[u1], points[l1]) + distance(points[u2], points[l2])) / (2 * width);
    if (!Number.isFinite(opening) || opening < 0.18 || opening > 0.65) return reject('eye-opening');
    const relativeX = iris.x - a.x, relativeY = iris.y - a.y;
    const x = (relativeX * dx + relativeY * dy) / (width * width);
    const y = (-relativeX * dy + relativeY * dx) / (width * width);
    if (x < 0.05 || x > 0.95 || Math.abs(y) > 0.35) return reject('iris-position');
    features.push({x, y});
  }
  const feature = {x: (features[0].x + features[1].x) / 2, y: (features[0].y + features[1].y) / 2};
  return validFeature(feature) ? feature : null;
}

function mean(values) { return values.reduce((sum, value) => sum + value, 0) / values.length; }
function stats(samples) {
  const xs = samples.map(sample => sample.feature.x), ys = samples.map(sample => sample.feature.y);
  const x = mean(xs), y = mean(ys);
  return {
    center: {x, y},
    stdX: Math.sqrt(mean(xs.map(value => (value - x) ** 2))),
    stdY: Math.sqrt(mean(ys.map(value => (value - y) ** 2))),
    spreadX: Math.max(...xs) - Math.min(...xs),
    spreadY: Math.max(...ys) - Math.min(...ys),
  };
}

// Partial-pivot elimination of an independently constructed 3x3 normal system.
function solve3(matrix, values) {
  const rows = matrix.map((row, index) => [...row, values[index]]);
  for (let column = 0; column < 3; column += 1) {
    let pivot = column;
    for (let row = column + 1; row < 3; row += 1) {
      if (Math.abs(rows[row][column]) > Math.abs(rows[pivot][column])) pivot = row;
    }
    if (!Number.isFinite(rows[pivot][column]) || Math.abs(rows[pivot][column]) < 1e-5) return null;
    [rows[column], rows[pivot]] = [rows[pivot], rows[column]];
    const divisor = rows[column][column];
    for (let item = column; item < 4; item += 1) rows[column][item] /= divisor;
    for (let row = 0; row < 3; row += 1) {
      if (row === column) continue;
      const multiplier = rows[row][column];
      for (let item = column; item < 4; item += 1) rows[row][item] -= multiplier * rows[column][item];
    }
  }
  const solution = rows.map(row => row[3]);
  return solution.every(Number.isFinite) ? solution : null;
}

function fitAffine(training) {
  if (training.length !== 5) return null;
  const origin = {x: mean(training.map(item => item.feature.x)), y: mean(training.map(item => item.feature.y))};
  const scale = {
    x: Math.sqrt(mean(training.map(item => (item.feature.x - origin.x) ** 2))),
    y: Math.sqrt(mean(training.map(item => (item.feature.y - origin.y) ** 2))),
  };
  if (scale.x < 0.001 || scale.y < 0.001) return null;
  const rows = training.map(item => [1, (item.feature.x - origin.x) / scale.x, (item.feature.y - origin.y) / scale.y]);
  const correlation = mean(rows.map(row => row[1] * row[2]));
  if (!Number.isFinite(correlation) || Math.abs(correlation) > 0.995) return null;
  const matrix = Array.from({length: 3}, (_, row) => Array.from({length: 3}, (_, column) => rows.reduce((sum, value) => sum + value[row] * value[column], 0)));
  const right = axis => Array.from({length: 3}, (_, column) => rows.reduce((sum, row, index) => sum + row[column] * training[index].target[axis], 0));
  const x = solve3(matrix, right('x')), y = solve3(matrix, right('y'));
  return x && y ? {origin, scale, x, y} : null;
}

function applyAffine(fit, feature) {
  const row = [1, (feature.x - fit.origin.x) / fit.scale.x, (feature.y - fit.origin.y) / fit.scale.y];
  return {x: row.reduce((sum, value, index) => sum + value * fit.x[index], 0),
    y: row.reduce((sum, value, index) => sum + value * fit.y[index], 0)};
}

class GazeCalibration {
  constructor({cameraID, displayID, calibrationID} = {}) {
    for (const value of [cameraID, displayID, calibrationID]) {
      if (typeof value !== 'string' || value.length < 1 || value.length > 256 || value.trim() !== value || /[\u0000-\u001f\u007f]/u.test(value)) {
        throw new TypeError('Explicit nonempty cameraID, displayID and calibrationID are required.');
      }
    }
    this._identity = Object.freeze({cameraID, displayID, calibrationID});
    this.reset();
  }

  get targets() { return TARGETS; }
  get currentTarget() { return TARGETS[this._completed] || null; }
  get validated() { return this._validated; }
  get progress() {
    return {completedTargets: this._completed, totalTargets: TARGETS.length,
      samples: this._samples.length, targetActive: this._targetStartedAt !== null, validated: this._validated};
  }

  quality(nowMs = Date.now()) {
    const samples = this._samples.filter(sample => fresh(sample.capturedAtMs, nowMs, MAX_SAMPLE_AGE_MS));
    const count = samples.length;
    const spanMs = count ? samples[count - 1].capturedAtMs - samples[0].capturedAtMs : 0;
    const ageMs = count ? nowMs - samples[count - 1].capturedAtMs : null;
    const observed = count ? stats(samples) : null;
    const stable = !!observed && observed.stdX <= MAX_STD && observed.stdY <= MAX_STD
      && observed.spreadX <= MAX_SPREAD && observed.spreadY <= MAX_SPREAD;
    const reason = this._targetStartedAt === null ? 'target-not-active'
      : count < MIN_SAMPLES ? 'need-12-fresh-samples'
      : spanMs < MIN_SPAN_MS ? 'need-1200ms-span'
      : !fresh(samples[count - 1].capturedAtMs, nowMs, MAX_OUTPUT_AGE_MS) ? 'latest-sample-stale'
      : !stable ? 'unstable-eye-features' : null;
    return {samples: count, spanMs, ageMs, stable, ready: !reason, reason,
      minSamples: MIN_SAMPLES, minSpanMs: MIN_SPAN_MS,
      stdX: observed?.stdX ?? null, stdY: observed?.stdY ?? null,
      spreadX: observed?.spreadX ?? null, spreadY: observed?.spreadY ?? null,
      maxStd: MAX_STD, maxSpread: MAX_SPREAD};
  }

  reset() {
    this._completed = 0; this._samples = []; this._training = []; this._errors = [];
    this._targetStartedAt = null; this._lastSampleAt = -1; this._lastProjectionAt = -1;
    this._fit = null; this._validated = false;
  }

  beginTarget(nowMs = Date.now()) {
    if (!validTime(nowMs) || this._validated || !this.currentTarget) return null;
    this._targetStartedAt = nowMs; this._samples = [];
    return this.currentTarget;
  }

  sample(feature, capturedAtMs, nowMs = Date.now()) {
    if (this._targetStartedAt === null || this._validated || !validFeature(feature)
        || !fresh(capturedAtMs, nowMs, MAX_OUTPUT_AGE_MS)
        || capturedAtMs < this._targetStartedAt || capturedAtMs <= this._lastSampleAt) return false;
    this._lastSampleAt = capturedAtMs;
    this._samples.push({feature: {x: feature.x, y: feature.y}, capturedAtMs});
    this._samples = this._samples.filter(sample => nowMs - sample.capturedAtMs <= MAX_SAMPLE_AGE_MS).slice(-96);
    return true;
  }

  finishTarget(nowMs = Date.now()) {
    // Snapshot before a failure resets the fit. No image or raw landmarks retained.
    const diagnostic = {targetNumber: this.currentTarget ? this.currentTarget.index + 1 : null,
      kind: this.currentTarget?.kind, quality: this.quality(nowMs)};
    const result = (ok, reason = null) => ({ok, reason, diagnostic: {...diagnostic, ok, reason}, target: this.currentTarget, progress: this.progress, validated: this._validated});
    if (!validTime(nowMs) || this._targetStartedAt === null || this._validated) return result(false, 'target-not-active');
    this._samples = this._samples.filter(sample => fresh(sample.capturedAtMs, nowMs, MAX_SAMPLE_AGE_MS));
    if (this._samples.length < MIN_SAMPLES) return result(false, 'need-12-fresh-samples');
    const first = this._samples[0], last = this._samples[this._samples.length - 1];
    if (last.capturedAtMs - first.capturedAtMs < MIN_SPAN_MS) return result(false, 'need-1200ms-span');
    if (!fresh(last.capturedAtMs, nowMs, MAX_OUTPUT_AGE_MS)) return result(false, 'latest-sample-stale');
    const observed = stats(this._samples);
    if (observed.stdX > MAX_STD || observed.stdY > MAX_STD || observed.spreadX > MAX_SPREAD || observed.spreadY > MAX_SPREAD) {
      return result(false, 'unstable-eye-features');
    }
    const target = this.currentTarget;
    if (target.kind === 'training') {
      this._training.push({feature: observed.center, target});
      if (this._training.length === 5) {
        this._fit = fitAffine(this._training);
        if (!this._fit) { this.reset(); return result(false, 'degenerate-calibration'); }
      }
    } else {
      if (!this._fit) { this.reset(); return result(false, 'missing-calibration'); }
      const prediction = applyAffine(this._fit, observed.center);
      const error = distance(prediction, target);
      diagnostic.accuracy = {target: {x: target.x, y: target.y},
        predicted: finitePoint(prediction) ? prediction : null,
        error: Number.isFinite(error) ? error : null, limit: 0.15};
      if (!Number.isFinite(error) || error > 0.15) { this.reset(); return result(false, 'held-out-error'); }
      this._errors.push(error);
    }
    this._completed += 1; this._targetStartedAt = null; this._samples = [];
    if (this._completed === TARGETS.length) {
      this._validated = this._errors.length === 2;
      this._lastProjectionAt = this._lastSampleAt;
    }
    return result(true);
  }

  project(feature, capturedAtMs, nowMs = Date.now()) {
    if (!this._validated || !this._fit || !validFeature(feature)
        || !fresh(capturedAtMs, nowMs, MAX_OUTPUT_AGE_MS)
        || capturedAtMs <= this._lastProjectionAt) return null;
    const point = applyAffine(this._fit, feature);
    // Outside the calibrated display is unavailable; never clamp it to an edge.
    if (!finitePoint(point) || point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) return null;
    this._lastProjectionAt = capturedAtMs;
    return {
      schemaVersion: 2, source: 'neocursor', capturedAt: new Date(capturedAtMs).toISOString(),
      ...this._identity, calibrated: true, x: point.x, y: point.y,
      validation: {kind: 'held-out-screen-error', maxError: Math.max(...this._errors),
        trainingTargets: 5, heldOutTargets: 2, minSamplesPerTarget: MIN_SAMPLES, coordinateOrigin: 'top-left'},
    };
  }
}

module.exports = {extractFeature, GazeCalibration};

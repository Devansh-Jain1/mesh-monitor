'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

// Coordinates only. Never accepts images, landmarks, audio, or arbitrary paths.
class ObservationPublisher {
  constructor(directory) {
    this.directory = path.resolve(directory);
    fs.mkdirSync(this.directory, {recursive: true, mode: 0o700});
    const st = fs.lstatSync(this.directory);
    if (!st.isDirectory() || st.isSymbolicLink() || fs.realpathSync(this.directory) !== this.directory || st.uid !== process.getuid() || (st.mode & 0o777) !== 0o700) throw Error('Observation directory must be owner-private.');
    this.output = path.join(this.directory, 'observation.json');
    this.lastBytes = null;
  }
  checkTarget() {
    let st;
    try { st = fs.lstatSync(this.output); } catch (e) { if (e.code === 'ENOENT') return; throw e; }
    if (!st.isFile() || st.isSymbolicLink() || st.uid !== process.getuid() || (st.mode & 0o777) !== 0o600 || st.nlink !== 1 || st.size > 8192) throw Error('Unsafe observation file.');
  }
  publish(observation) {
    const v = observation?.validation;
    if (observation?.schemaVersion !== 2 || observation.source !== 'neocursor' || observation.calibrated !== true ||
        !['cameraID','displayID','calibrationID'].every(k => typeof observation[k] === 'string' && observation[k].length > 0 && observation[k].length <= 512) ||
        ![observation.x, observation.y].every(n => Number.isFinite(n) && n >= 0 && n <= 1) ||
        typeof observation.capturedAt !== 'string' || !Number.isFinite(Date.parse(observation.capturedAt)) ||
        v?.kind !== 'held-out-screen-error' || !Number.isFinite(v.maxError) || v.maxError < 0 || v.maxError > 0.15 ||
        v.trainingTargets !== 5 || v.heldOutTargets !== 2 || v.minSamplesPerTarget !== 12 || v.coordinateOrigin !== 'top-left') throw Error('Expected a calibrated NeoCursor observation.');
    // Copy only the agreed fields. An accidental caller cannot persist raw frames.
    const value = Object.fromEntries(['schemaVersion','source','capturedAt','cameraID','displayID','calibrationID','calibrated','x','y','validation'].map(k => [k, observation[k]]));
    value.validation = Object.fromEntries(['kind','maxError','trainingTargets','heldOutTargets','minSamplesPerTarget','coordinateOrigin'].map(k => [k, v[k]]));
    const bytes = Buffer.from(JSON.stringify(value));
    if (bytes.length > 8192) throw Error('Observation exceeds its bound.');
    this.checkTarget();
    const temp = path.join(this.directory, '.' + crypto.randomUUID() + '.tmp');
    let fd;
    try {
      fd = fs.openSync(temp, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
      fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); fs.closeSync(fd); fd = undefined;
      fs.renameSync(temp, this.output); this.lastBytes = bytes;
    } finally { if (fd !== undefined) fs.closeSync(fd); try { fs.unlinkSync(temp); } catch (e) { if (e.code !== 'ENOENT') throw e; } }
  }
  clear() {
    if (!this.lastBytes) return;
    this.checkTarget();
    try { if (fs.readFileSync(this.output).equals(this.lastBytes)) fs.unlinkSync(this.output); }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
    this.lastBytes = null;
  }
}
module.exports = {ObservationPublisher};

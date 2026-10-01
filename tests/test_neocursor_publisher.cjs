'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {ObservationPublisher} = require('../ops/neocursor_mesh_adapter/publisher.cjs');
const observation = () => ({schemaVersion:2,source:'neocursor',capturedAt:new Date().toISOString(),cameraID:'camera',displayID:'display',calibrationID:'calibration',calibrated:true,x:0.2,y:0.4,
  validation:{kind:'held-out-screen-error',maxError:0.08,trainingTargets:5,heldOutTargets:2,minSamplesPerTarget:12,coordinateOrigin:'top-left'}});
function fixture(run) {
  const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()),'mesh-observer-publish-'));
  try { return run(root); } finally { fs.rmSync(root,{recursive:true,force:true}); }
}
test('private atomic coordinates only; stop clears own last observation',()=>fixture(root=>{
  const publisher = new ObservationPublisher(path.join(root,'state'));
  const input=observation(); input.landmarks=[{x:99}]; input.audio='never persist'; input.validation.image='never persist';
  publisher.publish(input);
  const value=JSON.parse(fs.readFileSync(publisher.output));
  assert.equal(value.x,0.2); assert.equal(value.landmarks,undefined); assert.equal(value.audio,undefined); assert.equal(value.validation.image,undefined);
  assert.equal(fs.statSync(publisher.output).mode&0o777,0o600);
  assert.deepEqual(fs.readdirSync(publisher.directory),['observation.json']);
  publisher.publish({...observation(),x:0.7}); assert.equal(JSON.parse(fs.readFileSync(publisher.output)).x,0.7);
  publisher.clear(); assert.equal(fs.existsSync(publisher.output),false); publisher.clear();
}));
test('unknown/newer publisher output is not removed by an old owner',()=>fixture(root=>{
  const publisher=new ObservationPublisher(path.join(root,'state')); publisher.publish(observation());
  fs.writeFileSync(publisher.output,JSON.stringify({...observation(),calibrationID:'newer'}));
  publisher.clear(); assert.equal(fs.existsSync(publisher.output),true);
}));
test('unsafe target links and permissions are rejected without changing target',()=>fixture(root=>{
  const publisher=new ObservationPublisher(path.join(root,'state'));
  const victim=path.join(root,'victim'); fs.writeFileSync(victim,'keep'); fs.symlinkSync(victim,publisher.output);
  assert.throws(()=>publisher.publish(observation())); assert.equal(fs.readFileSync(victim,'utf8'),'keep'); fs.unlinkSync(publisher.output);
  fs.writeFileSync(publisher.output,'keep',{mode:0o644}); assert.throws(()=>publisher.publish(observation()));
  fs.chmodSync(publisher.output,0o600); fs.linkSync(publisher.output,path.join(root,'hard-link')); assert.throws(()=>publisher.publish(observation()));
}));
test('malformed calibration and nonfinite coordinates never publish',()=>fixture(root=>{
  const publisher=new ObservationPublisher(path.join(root,'state'));
  for(const patch of [{schemaVersion:1},{x:NaN},{y:2},{cameraID:''},{capturedAt:'bad'},{calibrated:false},{validation:{...observation().validation,maxError:0.16}}]) assert.throws(()=>publisher.publish({...observation(),...patch}));
  assert.deepEqual(fs.readdirSync(publisher.directory),[]);
}));

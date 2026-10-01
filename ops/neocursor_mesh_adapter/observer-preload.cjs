'use strict';
const {contextBridge, ipcRenderer} = require('electron');
const invoke = (name, ...args) => ipcRenderer.invoke('mesh-observer:' + name, ...args);
contextBridge.exposeInMainWorld('meshObserver', {
  bootstrap: () => invoke('bootstrap'),
  allowCameraChoices: () => invoke('allow-camera-choices'),
  start: configuration => invoke('start', configuration),
  stop: () => invoke('stop'),
  beginCalibration: () => invoke('calibrate'),
  finishTarget: () => invoke('finish-target'),
  targetReady: presentation => invoke('target-ready', presentation),
  frame: packet => invoke('frame', packet),
  onStop: callback => { ipcRenderer.on('mesh-observer:stop', () => callback()); },
});

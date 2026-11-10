import fs from 'node:fs';
import assert from 'node:assert/strict';

// Exercise the actual distributed worker protocol and its decoded-image cache.
const directory = process.argv[2];
const originalFetch = globalThis.fetch;
globalThis.fetch = async (url, options) => String(url).startsWith('file:')
  ? new Response(fs.readFileSync(new URL(url)), {headers:{'Content-Type':'application/wasm'}})
  : originalFetch(url,options);
const pending = new Map();
let ready;
const started = new Promise(resolve => {ready=resolve;});
globalThis.self = {
  postMessage(message) {
    if (message.type === 'ready' || message.type === 'startupError') ready(message);
    else {const resolve=pending.get(message.id);pending.delete(message.id);resolve(message);}
  },
  close() {},
};
const bytes = name => Uint8Array.from(fs.readFileSync(`${directory}/${name}`)).buffer;
await import('../assets/web/rawkit_web_worker.js');
self.onmessage({data:{operation:'open',bytes:bytes('source.dng')}});
assert.equal((await started).type,'ready');
let sequence=0;
const request = data => new Promise(resolve => {const id=++sequence;pending.set(id,resolve);self.onmessage({data:{id,...data}});});
const settings = {whiteBalance:0,temperature:6500,tint:0,exposure:0,contrast:0,highlights:0,shadows:0,whites:0,blacks:0,saturation:0,vibrance:0,demosaicQuality:1,highlightRecovery:1};
const render = profile => request({operation:'render',preview:false,maximumWidth:64,maximumHeight:48,colorSpace:0,bitDepth:1,settings:{...settings,...(profile==null?{}:{cameraProfile:bytes(`profile${profile}.dcp`),cameraProfileId:`profile-${profile}`})}});
const standard = await render(null), first = await render(0), bright = await render(1), restored = await render(null);
for (const result of [standard,first,bright,restored]) assert.equal(result.ok,true,JSON.stringify(result.error));
assert.notDeepEqual(new Uint8Array(first.pixels),new Uint8Array(bright.pixels));
assert.deepEqual(new Uint8Array(standard.pixels),new Uint8Array(restored.pixels));
const invalid = await request({operation:'render',preview:false,maximumWidth:64,maximumHeight:48,colorSpace:0,bitDepth:1,settings:{...settings,cameraProfile:new Uint8Array([1,2,3]).buffer,cameraProfileId:'invalid'}});
assert.equal(invalid.ok,false);
assert.equal((await render(0)).ok,true);
await request({operation:'close'});
console.log('Worker import, profile cache invalidation, clearing and invalid-profile recovery passed.');

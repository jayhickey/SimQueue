// SPDX-License-Identifier: MIT
// Verify the network-only worker without browser or daemon access.
const {readFileSync}=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const worker=readFileSync('Web/dashboard/src/sw.js','utf8');
const app=readFileSync('Web/dashboard/src/app.tsx','utf8');
assert.equal(app.includes('dangerouslySetInnerHTML'),false,'application data must be rendered as text');
const events={};let fetches=0,online=true;
const context=vm.createContext({
  self:{addEventListener:(name,fn)=>events[name]=fn,skipWaiting:async()=>{},clients:{claim:async()=>{}}},
  fetch:async(_request,options)=>{fetches++;assert.equal(options.cache,'no-store');if(!online)throw new Error('offline');return new Response('online');},Response
});
vm.runInContext(worker,context);
(async()=>{
  for(const request of [{method:'POST',mode:'cors'},{method:'GET',mode:'cors'}])events.fetch({request,respondWith:()=>assert.fail('API/actions must bypass the worker')});
  assert.equal(fetches,0);
  let response;const navigate=async()=>{events.fetch({request:{method:'GET',mode:'navigate'},respondWith:p=>response=p});return await response;};
  assert.equal(await(await navigate()).text(),'online');online=false;const offline=await navigate();assert.equal(offline.status,503);assert.equal(offline.headers.get('Cache-Control'),'no-store');assert.match(await offline.text(),/Can’t reach the Mac/);assert.equal(fetches,2);assert.equal(typeof context.caches,'undefined');
  console.log('Dashboard safe-text source and network-only PWA checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});

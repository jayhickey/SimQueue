// SPDX-License-Identifier: MIT
// No browser or npm dependencies: exercise the shipped JavaScript with an injected DOM and clock.
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync('Sources/SimQueueDashboard/DashboardAssets.swift','utf8');
const script = source.match(/"app\.js":\s*\(\s*"text\/javascript",\s*#"""\n([\s\S]*?)"""#/)[1];
class Element {
  constructor(tag) { this.tag=tag; this.children=[]; this.value=''; this.style={}; this.textContent=''; this.listeners={}; this.scrollLeft=0; this.scrollTop=0; this.scrollHeight=500; this.clientHeight=200; }
  get firstElementChild() { return this.children[0] || null; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children=children; }
  addEventListener(name,fn) { this.listeners[name]=fn; }
  setAttribute(name,value) { this[name]=value; }
}
const elements = new Map();
const context = vm.createContext({
  document: {hidden:true, getElementById:id=>{ if (!elements.has(id)) elements.set(id,new Element(id)); return elements.get(id); }, createElement:tag=>new Element(tag)},
  setTimeout() {}, clearTimeout() {}, Date, AbortController,
});
vm.runInContext(script,context);
const run = expression => vm.runInContext(expression,context);
run("snapshot={generatedAt:'2026-01-01T00:01:00Z'}");
const phases = job => JSON.parse(run(`JSON.stringify(timings(${JSON.stringify(job)}))`));
assert.deepEqual(phases({queue_time:'2026-01-01T00:00:00Z'}),['1m 0s','—','—']);
assert.deepEqual(phases({queue_time:0, admitted_at:10, started_at:20, finished_at:50}),['10s','10s','30s']);
assert.deepEqual(phases({queue_time:0, finished_at:5}),['5s','—','—']);
assert.deepEqual(phases({queue_time:10, started_at:20, finished_at:25}),['10s','—','5s']);
assert.equal(run('duration(-10)'), '0s');
assert.equal(run('duration(NaN)'), '—');
const hostile = '<img src=x onerror=alert(1)>';
const node = run(`el('pre', ${JSON.stringify(hostile)})`);
assert.equal(node.textContent,hostile);
assert.equal(node.children.length,0);
elements.get('search').value='TESTER';
assert.equal(run("matches({id:'J-1', project:'generic', submitter:'tester', command:['echo','hi']})"),true);
elements.get('project').value='other';
assert.equal(run("matches({id:'J-1', project:'generic', submitter:'tester'})"),false);
// Start and queue times: "Oct 22, 12:43 PM" in the given zone, a dash when missing.
assert.equal(run("stamp('2026-10-22T19:43:00Z','America/Los_Angeles')"),'Oct 22, 12:43 PM');
assert.equal(run("stamp('2026-10-22T19:43:00Z','Asia/Tokyo')"),'Oct 23, 4:43 AM');
assert.equal(run("stamp(1767600330,'America/Los_Angeles')"),'Jan 5, 12:05 AM');
assert.equal(run("stamp(null)"),'—');
// Readable names with spaces and punctuation are shown as-is, searchable, and get their own Queued and Started cells.
const names=['Quotify PR #134 · Unit tests','Quotify main · Unit + UI tests (full)'];
for (const name of names) assert.equal(run(`label(${JSON.stringify({project:'quotify',kind:name})})`),`quotify · ${name}`);
elements.get('project').value='';
elements.get('search').value='unit + ui tests (FULL)';
assert.equal(run(`matches(${JSON.stringify({id:'J-2',project:'quotify',kind:names[1],submitter:'ci'})})`),true);
run(`table(${JSON.stringify([{id:'J-1',project:'quotify',kind:names[0],state:'queued',priority:50,queue_time:'2026-10-22T19:43:00Z',granted_sims:0}])},'recent')`);
const rendered=elements.get('recent').children[0].children[0];
const header=rendered.children[0].children[0].children.map(th=>th.textContent);
assert.deepEqual(header.slice(0,5),['Job / command','State','Priority','Queued','Started']);
const cells=rendered.children[1].children[0].children;
assert.equal(cells[0].children[0].textContent,`quotify · ${names[0]}`);
assert.match(cells[3].textContent,/^Oct 2[23], \d{1,2}:43 [AP]M$/);
assert.equal(cells[3].title,'2026-10-22T19:43:00Z');
assert.equal(cells[4].textContent,'—','not started yet');
elements.get('search').value='';
console.log('Dashboard JavaScript timing, filtering and safe-text checks passed');

const previousSnapshot=run('snapshot');
run("snapshot={status:{host:{sampledAt:100,totalMemoryBytes:34359738368,availableMemoryBytes:8589934592,swapUsedBytes:0,memoryPressure:'normal',cpuUsagePercent:40,load1:6.2,load5:8,cpuCount:10,freeDiskBytes:100,thermalState:'nominal'},storage:{system_free_bytes:21474836480,free_bytes:42949672960,minimum_free_bytes:21474836480,available:true},global_wait_reasons:[],storageReviewRunning:false},active:[],recent:[],generatedAt:101};renderMachine();renderStorage()");
assert.equal(elements.get('machine').children[0].children[1].textContent,'8.0 GiB');
assert.equal(elements.get('machine').children[1].children[1].textContent,'40%');
assert.match(elements.get('machine').children[1].children[2].textContent,/Load 6.2 \/ 8.0/);
assert.equal(elements.get('cleanup-storage').disabled,true,'cleanup requires a reviewed eligible inventory');
run("snapshot.status={global_wait_reasons:[{summary:'disk is low'}]};renderMachine();renderStorage()");
assert.equal(elements.get('machine').children[0].children[1].textContent,'Unavailable');
assert.match(elements.get('admission-health').textContent,/disk is low/);
assert.equal(elements.get('review-storage').disabled,true,'old daemons never receive background cleanup requests');
context.savedHealthSnapshot=previousSnapshot;
run('snapshot=savedHealthSnapshot');
console.log('Dashboard machine health, unavailable readings and storage capability checks passed');


// Independent table offsets survive refreshed rows and updated durations.
run("table([{id:'J-scroll',project:'test',state:'running',priority:50,queue_time:1,started_at:2}], 'active'); table([{id:'J-done',project:'test',state:'succeeded',priority:50,queue_time:1,started_at:2,finished_at:3}], 'recent')");
const activeScroller=elements.get('active').firstElementChild;
const recentScroller=elements.get('recent').firstElementChild;
activeScroller.scrollLeft=340; activeScroller.scrollTop=12;
recentScroller.scrollLeft=620;
const oldTable=activeScroller.firstElementChild;
run("snapshot={generatedAt:120}; table([{id:'J-scroll',project:'test',state:'running',priority:50,queue_time:1,started_at:2}], 'active'); table([{id:'J-done',project:'test',state:'succeeded',priority:50,queue_time:1,started_at:2,finished_at:4}], 'recent')");
assert.equal(elements.get('active').firstElementChild,activeScroller,'polling retains the live scroll container');
assert.equal(elements.get('recent').firstElementChild,recentScroller);
assert.equal(activeScroller.scrollLeft,340);
assert.equal(activeScroller.scrollTop,12);
assert.equal(recentScroller.scrollLeft,620,'each table retains its own horizontal position');
assert.notEqual(activeScroller.firstElementChild,oldTable,'row data still refreshes');
assert.equal(activeScroller.firstElementChild.children[1].children[0].children[7].textContent,'1m 58s');
run("table([], 'active')");
assert.equal(elements.get('active').firstElementChild.textContent,'No jobs in this view.');
run("table([{id:'J-new',project:'test',state:'running',priority:50,queue_time:1,started_at:2}], 'active')");
assert.equal(elements.get('active').firstElementChild.scrollLeft,0,'new table after empty state starts normally');
console.log('Dashboard refresh scroll preservation checks passed');

// Rows are not rebuilt under an in-progress touch or momentum scroll (iOS drops the gesture).
const job=id=>JSON.stringify([{id,project:'test',state:'running',priority:50,queue_time:1,started_at:2}]);
run(`clock=()=>10000; table(${job('J-t1')},'active')`);
const touchWrap=elements.get('active').firstElementChild, touchTable=touchWrap.firstElementChild;
touchWrap.listeners.touchstart();
run(`table(${job('J-t2')},'active')`); assert.equal(touchWrap.firstElementChild,touchTable,'no rebuild under a finger');
touchWrap.listeners.touchend();
run(`clock=()=>10500; table(${job('J-t2')},'active')`); assert.equal(touchWrap.firstElementChild,touchTable,'no rebuild during momentum');
run(`clock=()=>11200; table(${job('J-t2')},'active')`); assert.notEqual(touchWrap.firstElementChild,touchTable,'redraws once settled');
const settled=touchWrap.firstElementChild; touchWrap.listeners.scroll();
run(`clock=()=>11300; table(${job('J-t3')},'active')`); assert.equal(touchWrap.firstElementChild,settled,'trackpad/wheel scroll also defers');
touchWrap.listeners.click();
run(`table(${job('J-t3')},'active')`); assert.notEqual(touchWrap.firstElementChild,settled,'a tap redraws immediately');
run('clock=()=>Date.now()');
console.log('Dashboard gesture-deferred refresh checks passed');


assert.equal(run("controls({id:'J-1',state:'queued',priority:100}).children[0].disabled"),true);
assert.equal(run("controls({id:'J-1',state:'running',priority:50}).children.length"),1);
assert.equal(run("controls({id:'J-1',state:'succeeded'}).children.length"),0);
(async () => {
  run('snapshot=null');
  let posts=0;
  context.confirm=()=>false;
  run('askAction=async()=>confirm()');
  context.fetch=async (path,options) => {
    if (options?.method === 'POST') { posts++; assert.equal(options.headers['X-SimQueue-Action'],'1'); return {ok:true,json:async()=>({priority:80})}; }
    return {ok:true,json:async()=>({status:{},active:[],recent:[],generatedAt:0})};
  };
  await run("changeJob({id:'J-1',project:'test'},'cancel')");
  assert.equal(posts,0,'declining cancellation must not send a request');
  await run("changeJob({id:'J-1'},'priority',101)");
  assert.equal(posts,0,'invalid priorities must not send a request');
  await run("changeJob({id:'J-1'},'priority',80)");
  assert.equal(posts,1);
  assert.match(elements.get('action-status').textContent,/priority set to 80/);
  context.confirm=()=>true;
  context.fetch=async()=>{ posts++; throw new Error('disconnect'); };
  await run("changeJob({id:'J-1'},'cancel')");
  assert.equal(posts,2,'ambiguous mutations are never automatically retried');
  assert.match(elements.get('action-status').textContent,/No confirmed response/);
  // Exercise the real log polling functions with deferred responses and a fake clock.
  let reads=0, resolveRead;
  context.fetch=async () => { reads++; return {ok:true,json:async()=>({data:'first\n',offset:50,at_end:true,job_finished:false})}; };
  context.document.hidden=false;
  run("logView=createTail('J-live')");
  await run('pollTail(logView)');
  assert.equal(run('logView.output.textContent'),'first\n');
  assert.equal(run('logView.output.scrollTop'),500,'live output follows the bottom');
  run('pauseTail(logView)');
  await run('pollTail(logView)');
  assert.equal(reads,1,'paused output does not request more logs');
  context.fetch=async()=>({ok:false,status:503});
  run('logView.paused=false');
  await run('pollTail(logView)');
  assert.equal(run('logView.output.textContent'),'first\n','disconnect preserves displayed output');
  assert.match(run('logView.status.textContent'),/stale/);
  context.fetch=()=>{reads++; return new Promise(resolve=>{resolveRead=resolve;});};
  const pending=run('pollTail(logView)');
  const inFlightReads=reads;
  await run('pollTail(logView)');
  assert.equal(reads,inFlightReads,'tail requests cannot overlap');
  run("stopTail(); logView=createTail('J-other')");
  resolveRead({ok:true,json:async()=>({data:'stale job',job_finished:false,at_end:true})});
  await pending;
  assert.equal(run('logView.output.textContent'),'Loading output…','late responses cannot overwrite another job');
  context.fetch=async()=>{ reads++; return {ok:true,json:async()=>({data:'done\n',offset:0,job_finished:true,at_end:true})}; };
  await run('pollTail(logView)');
  const finishedReads=reads;
  await run('pollTail(logView)');
  assert.equal(reads,finishedReads);
  assert.equal(run('logView.finished'),true);
  assert.equal(run('logView.pause.disabled'),true);
  context.fetch=async()=>({ok:false,status:409,text:async()=>'Upgrade the daemon for live tail'});
  run("stopTail(); logView=createTail('J-old')");
  await run('pollTail(logView)');
  assert.match(run('logView.status.textContent'),/Upgrade the daemon/);
  assert.equal(run('logView.finished'),true,'unsupported daemons do not get polled forever');
  run("stopTail(); logView=createTail('J-scroll')");
  run('logView.output.listeners.scroll()');
  assert.equal(run('logView.paused'),true,'scrolling up pauses the live view');
  run('logView.paused=false');
  context.document.hidden=true;
  const hiddenReads=reads;
  await run('pollTail(logView)');
  assert.equal(reads,hiddenReads,'hidden tabs do not fetch log data');
  context.document.hidden=false;
  run("snapshot={status:{},active:[{id:'J-label',project:'example',kind:'a very long untruncated activity label',state:'running',started_at:1}],recent:[],generatedAt:2}");
  elements.get('search').value=''; elements.get('project').value=''; elements.get('state').value='';
  run('render()');
  assert.equal(elements.get('timeline').children[0].children[0].title,'example · a very long untruncated activity label');
  run('stopTail()');
  console.log('Dashboard live-tail polling, pause, completion, stale-response and error checks passed');
  console.log('Dashboard job control checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});

// The installed app must never replay actions or serve old job data offline.
const worker = source.match(/"sw\.js":\s*\(\s*"text\/javascript",\s*#"""\n([\s\S]*?)"""#/)[1];
const workerEvents = {};
let workerFetches = 0;
let workerOnline = true;
const workerContext = vm.createContext({
  self: {addEventListener:(name, fn)=>workerEvents[name]=fn, skipWaiting:async()=>{}, clients:{claim:async()=>{}}},
  fetch:async(_request, options)=>{workerFetches++; assert.equal(options.cache,'no-store'); if (!workerOnline) throw new Error('offline'); return new Response('online');},
  Response,
});
vm.runInContext(worker, workerContext);
(async()=>{
  for (const request of [{method:'POST',mode:'cors'}, {method:'GET',mode:'cors'}]) {
    workerEvents.fetch({request, respondWith:()=>assert.fail('API/actions must bypass the worker')});
  }
  assert.equal(workerFetches,0);
  let response;
  const navigate=async()=>{workerEvents.fetch({request:{method:'GET',mode:'navigate'},respondWith:p=>response=p}); return await response;};
  assert.equal(await (await navigate()).text(),'online');
  workerOnline=false;
  const offline=await navigate();
  assert.equal(offline.status,503);
  assert.equal(offline.headers.get('Cache-Control'),'no-store');
  assert.match(await offline.text(),/SimQueue is offline/);
  assert.equal(workerFetches,2);
  assert.equal(typeof workerContext.caches,'undefined');
  console.log('PWA network-only navigation and action bypass checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});

// SPDX-License-Identifier: MIT
// No browser or npm dependencies: exercise the shipped JavaScript with an injected DOM and clock.
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync('Sources/SimQueueDashboard/DashboardAssets.swift','utf8');
const script = source.match(/"app\.js":\s*\(\s*"text\/javascript",\s*#"""\n([\s\S]*?)"""#/)[1];
class Element {
  constructor(tag) { this.tag=tag; this.children=[]; this.value=''; this.style={}; this.textContent=''; this.listeners={}; this.scrollTop=0; this.scrollHeight=500; this.clientHeight=200; }
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
console.log('Dashboard JavaScript timing, filtering and safe-text checks passed');

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

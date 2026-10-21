// SPDX-License-Identifier: MIT
// No browser or npm dependencies: exercise the shipped JavaScript with an injected DOM and clock.
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync('Sources/SimQueueDashboard/DashboardAssets.swift','utf8');
const script = source.match(/"app\.js":\s*\(\s*"text\/javascript",\s*#"""\n([\s\S]*?)"""#/)[1];
class Element {
  constructor(tag) { this.tag=tag; this.children=[]; this.value=''; this.style={}; this.textContent=''; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children=children; }
  addEventListener() {}
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
  console.log('Dashboard job control checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});

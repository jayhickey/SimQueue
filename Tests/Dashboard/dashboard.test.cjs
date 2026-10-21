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

// SPDX-License-Identifier: MIT
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { mkdir } from 'node:fs/promises';
import { fixture, now } from './fixtures.mjs';
const out = new URL('../../../.build/dashboard/model-test.mjs', import.meta.url);
await mkdir(new URL('.', out), { recursive: true });
await build({
  entryPoints: [new URL('../src/model.ts', import.meta.url).pathname],
  outfile: out.pathname,
  bundle: true,
  format: 'esm',
  platform: 'node',
});
const m = await import(out.href);
test('timings separate queue, preparation and execution, including older daemons', () => {
  assert.deepEqual(
    m.timings({ queue_time: 0, admitted_at: 10, started_at: 20, finished_at: 50 }, 100000),
    [10000, 10000, 30000],
  );
  assert.deepEqual(m.timings({ queue_time: 0, started_at: 20, finished_at: 50 }, 100000), [
    20000,
    null,
    30000,
  ]);
  assert.deepEqual(m.timings({ queue_time: 0 }, 100000), [100000, null, null]);
  assert.equal(m.duration(-100), '0s');
  assert.equal(m.duration(NaN), '—');
  assert.equal(m.bytes(null), 'Unavailable');
  assert.equal(m.numeric(undefined), '—');
});
test('summaries distinguish cancellation from failure and use known durations', () => {
  const summary = m.recentSummary(fixture.recent);
  assert.equal(summary.passed, 9);
  assert.equal(summary.failed, 1);
  assert.equal(summary.other, 1);
  assert.equal(summary.rate, 90);
  assert.equal(m.recentSummary([]).rate, null);
  assert.equal(m.recentSummary([]).median, null);
  assert.equal(
    m.recentSummary([{ state: 'succeeded', started_at: 10, finished_at: 5 }]).median,
    null,
  );
});
test('averages use completed known phases, skip ambiguous waits and count samples', () => {
  const job = {
    state: 'succeeded',
    attempt: 0,
    queue_time: 0,
    admitted_at: 10,
    started_at: 15,
    finished_at: 35,
  };
  const jobs = [
    job,
    { ...job, admitted_at: 30, started_at: 35, finished_at: 75 },
    { ...job, attempt: 1 },
    { ...job, admitted_at: undefined },
    { ...job, state: 'canceled', started_at: undefined },
    { ...job, state: 'running' },
    { ...job, admitted_at: -1 },
    { ...job, started_at: 40 },
    { ...job, finished_at: 'invalid' },
  ];
  const stats = m.recentSummary(jobs);
  assert.equal(stats.averageWait, 20000);
  assert.equal(stats.waitCount, 2);
  assert.equal(stats.averageRun, 24000);
  assert.equal(stats.runCount, 5);
  const zero = m.recentSummary([{ ...job, admitted_at: 0, started_at: 0, finished_at: 0 }]);
  assert.equal(zero.averageWait, 0);
  assert.equal(zero.averageRun, 0);
  for (const empty of [[], [{ state: 'failed', finished_at: 10 }]]) {
    const result = m.recentSummary(empty);
    assert.equal(result.averageWait, null);
    assert.equal(result.averageRun, null);
    assert.equal(result.waitCount, 0);
    assert.equal(result.runCount, 0);
  }
});
test('filters include caller labels, commands, IDs and submitters', () => {
  const j = fixture.active[0];
  assert.equal(m.matches(j, 'TEST FILTER', '', ''), true);
  assert.equal(m.matches(j, '--parallel', '', ''), true);
  assert.equal(m.matches(j, 'developer', '', ''), true);
  assert.equal(m.matches(j, '', 'other', ''), false);
});
test('bounded tab trends deduplicate samples and preserve gaps', () => {
  let samples = [];
  for (let i = 0; i < 200; i++) {
    const s = structuredClone(fixture);
    s.status.host.sampledAt += i;
    s.generatedAt = new Date(now + i * 1000).toISOString();
    samples = m.addSample(samples, s);
  }
  assert.equal(samples.length, 120);
  const missing = structuredClone(fixture);
  delete missing.status.host.cpuUsagePercent;
  missing.status.host.sampledAt += 210;
  missing.generatedAt = new Date(now + 210000).toISOString();
  samples = m.addSample(samples, missing);
  assert.equal(samples.at(-1).cpu, null);
  assert.equal(m.addSample(samples, missing), samples);
  const fresh = structuredClone(fixture);
  fresh.status.host.sampledAt += 230;
  fresh.generatedAt = new Date(now + 230000).toISOString();
  samples = m.addSample(samples, fresh);
  assert.equal(m.trendSegments(samples, 'cpu').length, 2);
  assert.equal(
    m.addSample(samples, { ...fixture, generatedAt: new Date(now + 300000).toISOString() }),
    samples,
    'stale readings do not become fresh trend points',
  );
});
test('poller has one lane, pauses hidden work and backs off failures', async () => {
  const scheduled = [];
  let reads = 0,
    resolve,
    visible = true;
  const p = m.createPoller(
    () => {
      reads++;
      return new Promise((r) => (resolve = r));
    },
    () => visible,
    (fn, ms) => {
      scheduled.push({ fn, ms });
      return scheduled.length;
    },
    () => {},
  );
  const first = p.run();
  await p.run();
  assert.equal(reads, 1);
  resolve(false);
  await first;
  assert.equal(scheduled.at(-1).ms, 0, 'coalesced refresh');
  const second = p.run();
  resolve(false);
  await second;
  assert.equal(scheduled.at(-1).ms, 12000);
  visible = false;
  await p.run();
  assert.equal(reads, 2);
  p.stop();
  await p.run();
  assert.equal(reads, 2);
});
test('requests bound responses, supply action header and never retry ambiguous mutations', async () => {
  const old = globalThis.fetch;
  let count = 0;
  try {
    globalThis.fetch = async (_path, opts) => {
      count++;
      assert.equal(opts.method, 'POST');
      assert.equal(opts.headers['X-SimQueue-Action'], '1');
      throw new Error('disconnected');
    };
    await assert.rejects(() => m.request('cancel/J-1', { method: 'POST' }));
    assert.equal(count, 1);
  } finally {
    globalThis.fetch = old;
  }
});

test('timestamp formatting keeps viewer timezone and missing-value semantics', () => {
  assert.equal(m.stamp('2026-10-22T19:43:00Z', 'America/Los_Angeles'), 'Oct 22, 12:43 PM');
  assert.equal(m.stamp('2026-10-22T19:43:00Z', 'Asia/Tokyo'), 'Oct 23, 4:43 AM');
  assert.equal(m.stamp(null), '—');
  assert.equal(m.clockStamp(null), '—');
});

test('activity phase ranges distinguish queue, preparation, execution and missing history', () => {
  const job = {
    state: 'succeeded',
    attempt: 0,
    queue_time: 0,
    admitted_at: 10,
    started_at: 20,
    finished_at: 50,
  };
  assert.deepEqual(m.activitySegments(job, 100000), [
    { phase: 'queue', start: 0, end: 10000 },
    { phase: 'preparation', start: 10000, end: 20000 },
    { phase: 'run', start: 20000, end: 50000 },
  ]);
  assert.deepEqual(m.activitySegments({ state: 'queued', queue_time: 10 }, 50000), [
    { phase: 'queue', start: 10000, end: 50000 },
  ]);
  assert.deepEqual(
    m.activitySegments({ state: 'admitted', queue_time: 0, admitted_at: 10 }, 50000),
    [
      { phase: 'queue', start: 0, end: 10000 },
      { phase: 'preparation', start: 10000, end: 50000 },
    ],
  );
  assert.deepEqual(m.activitySegments({ state: 'failed', started_at: 20 }, 100000), []);
  assert.deepEqual(m.timings({ state: 'failed', started_at: 20 }, 100000), [null, null, null]);
  assert.equal(m.timings({ state: 'succeeded', started_at: 20, finished_at: 10 }, 100000)[2], null);
  assert.deepEqual(m.phaseTimings({ ...job, attempt: 1 }, 100000), [null, 10000, 30000]);
  assert.equal(
    m.activitySegments({ ...job, attempt: 1 }, 100000).some((s) => s.phase === 'queue'),
    false,
  );
  assert.match(m.activityDescription({ ...job, attempt: 1 }, 100000), /unavailable across retries/);
  assert.equal(m.waitLabel({ started_at: 20 }), 'Before start');
});

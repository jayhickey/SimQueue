// SPDX-License-Identifier: MIT
// Opt-in browser profile against synthetic data. It never connects to a daemon.
import { chromium } from '@playwright/test';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { once } from 'node:events';
const root = new URL('../../../.build/dashboard/', import.meta.url);
const baseline = process.argv[process.argv.indexOf('--baseline-ref') + 1];
const runs = [{ name: 'runner-vitals', directory: root.pathname }];
if (process.argv.includes('--baseline-ref')) {
  const directory = new URL('baseline/', root);
  await mkdir(directory, { recursive: true });
  const source = execFileSync(
    'git',
    ['show', `${baseline}:Sources/SimQueueDashboard/DashboardAssets.swift`],
    { encoding: 'utf8' },
  );
  for (const [key, name] of [
    ['', 'index.html'],
    ['app.js', 'app.js'],
    ['style.css', 'style.css'],
    ['sw.js', 'sw.js'],
    ['manifest.webmanifest', 'manifest.webmanifest'],
  ]) {
    const escaped = key.replaceAll('.', '\\.');
    const match = source.match(
      new RegExp(`"${escaped}":\\s*\\(\\s*"[^"]+",\\s*#"""\\n([\\s\\S]*?)"""#`),
    );
    if (!match) throw new Error(`Missing baseline asset ${name}`);
    await writeFile(new URL(name, directory), match[1].replace(/^            /gm, ''));
  }
  runs.unshift({ name: 'baseline', directory: directory.pathname });
}
const results = [];
for (const run of runs) {
  const server = spawn(process.execPath, [new URL('server.mjs', import.meta.url).pathname], {
    env: { ...process.env, SIMQ_DASHBOARD_ASSETS: run.directory, SIMQ_DASHBOARD_PORT: '43872' },
    stdio: 'ignore',
  });
  let browser;
  try {
    for (let i = 0; i < 100; i++) {
      try {
        await fetch('http://127.0.0.1:43872');
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 100));
      }
    }
    browser = await chromium.launch();
    const page = await browser.newPage({ serviceWorkers: 'block' });
    let snapshots = 0;
    page.on('request', (r) => {
      if (r.url().endsWith('/api/snapshot')) snapshots++;
    });
    await page.goto('http://127.0.0.1:43872/fixture/');
    await page.waitForTimeout(1000);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Performance.enable');
    await cdp.send('HeapProfiler.collectGarbage');
    const before = await cdp.send('Runtime.getHeapUsage'),
      initial = await cdp.send('Performance.getMetrics');
    for (let i = 0; i < 6; i++) await page.waitForTimeout(10000);
    await cdp.send('HeapProfiler.collectGarbage');
    const after = await cdp.send('Runtime.getHeapUsage'),
      final = await cdp.send('Performance.getMetrics');
    const metric = (r, key) => r.metrics.find((m) => m.name === key)?.value ?? 0;
    const result = {
      name: run.name,
      seconds: 60,
      snapshotRequests: snapshots,
      heapBeforeBytes: before.usedSize,
      heapAfterBytes: after.usedSize,
      heapGrowthBytes: after.usedSize - before.usedSize,
      taskSeconds: metric(final, 'TaskDuration') - metric(initial, 'TaskDuration'),
      domNodes: await page.locator('*').count(),
    };
    results.push(result);
    console.log(JSON.stringify(result));
  } finally {
    if (browser) await browser.close();
    if (server.exitCode === null && server.signalCode === null) {
      server.kill('SIGTERM');
      await once(server, 'exit');
    }
  }
}
await writeFile(new URL('performance.json', root), JSON.stringify(results, null, 2) + '\n');

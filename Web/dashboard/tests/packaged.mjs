// SPDX-License-Identifier: MIT
// Standalone executable proof against a disposable fake daemon. No installed service changes.
import { chromium, expect } from '@playwright/test';
import http from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, copyFile, chmod, mkdir, readFile, rm } from 'node:fs/promises';
import { once } from 'node:events';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const assets = new URL('../../../.build/dashboard/', import.meta.url);
const index = process.argv.indexOf('--bin-dir');
const binaryDirectory =
  index >= 0
    ? resolve(process.argv[index + 1])
    : fileURLToPath(new URL('../../../.build/debug/', import.meta.url));
const root = await mkdtemp(process.platform === 'darwin' ? '/private/tmp/sq-ui-' : '/tmp/sq-ui-');
const state = root + '/state';
await mkdir(state);
const env = {
  ...process.env,
  SIMQ_NO_AUTOSTART: '1',
  SIMQ_STATE_DIR: state,
  SIMQ_HOST_LOCK: root + '/fake-host.lock',
};
const children = [];
let browser, proxy;
let connected = true;
async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  child.kill('SIGTERM');
  const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
  try {
    await exited;
  } finally {
    clearTimeout(timer);
  }
}
try {
  const copy = root + '/simq';
  await copyFile(binaryDirectory + '/simq', copy);
  await chmod(copy, 0o755);
  const daemon = spawn(
    binaryDirectory + '/simqd',
    [
      'run',
      '--foreground',
      '--state-dir',
      state,
      '--backend',
      'fake',
      '--probe',
      'fake',
      '--executor',
      'fake',
    ],
    { env, stdio: 'ignore' },
  );
  children.push(daemon);
  const dashboard = spawn(copy, ['dashboard', '--state-dir', state, '--no-open'], {
    cwd: root,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.push(dashboard);
  const url = await new Promise((yes, no) => {
    let output = '';
    const timer = setTimeout(() => no(new Error('Copied dashboard failed to start')), 15000);
    dashboard.stdout.on('data', (data) => {
      output += data;
      const match = output.match(/SimQueue dashboard: (http[^\s]+)/);
      if (match) {
        clearTimeout(timer);
        yes(match[1]);
      }
    });
    dashboard.once('exit', () => {
      clearTimeout(timer);
      no(new Error('Copied dashboard exited before startup'));
    });
  });
  for (let i = 0; i < 100; i++) {
    const r = await fetch(new URL('api/snapshot', url));
    if (r.ok) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.equal(
    await (await fetch(new URL('app.js', url))).text(),
    await readFile(new URL('app.js', assets), 'utf8'),
    'copied executable embeds current assets without a resource bundle',
  );
  // A disposable proxy models the Mac becoming unreachable at the transport layer.
  // Browser offline emulation does not consistently affect service-worker fetches.
  proxy = http.createServer((req, res) => {
    if (!connected) {
      res.destroy();
      return;
    }
    const upstream = http.request(new URL(req.url, url), { headers: req.headers }, (reply) => {
      res.writeHead(reply.statusCode, reply.headers);
      reply.pipe(res);
    });
    upstream.on('error', () => res.destroy());
    upstream.end();
  });
  proxy.listen(0, '127.0.0.1');
  await once(proxy, 'listening');
  const proxied = new URL(url);
  proxied.port = String(proxy.address().port);
  browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto(proxied.href);
  await expect(
    page.getByRole('heading', { name: 'Ready · 0 running, 0 preparing, 0 waiting' }),
  ).toBeVisible();
  await page.waitForFunction(() => navigator.serviceWorker.controller !== null);
  for (let i = 0; i < 2; i++) await page.waitForTimeout(10000);
  const [cpu, rss] = execFileSync('ps', ['-p', String(dashboard.pid), '-o', '%cpu=,rss='], {
    encoding: 'utf8',
  })
    .trim()
    .split(/\s+/)
    .map(Number);
  await page.screenshot({ path: new URL('packaged-smoke.png', assets).pathname, fullPage: true });
  connected = false;
  await page.reload({ waitUntil: 'domcontentloaded' });
  await expect(page.getByRole('heading', { name: 'Can’t reach the Mac' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Retry connection' })).toBeVisible();
  connected = true;
  await page.getByRole('link', { name: 'Retry connection' }).click();
  await expect(
    page.getByRole('heading', { name: 'Ready · 0 running, 0 preparing, 0 waiting' }),
  ).toBeVisible();
  const result = {
    copiedExecutable: true,
    fakeBackend: true,
    assetsMatch: true,
    offlineLaunchAndRecovery: true,
    dashboardCPUPercent: cpu,
    dashboardRSSBytes: rss * 1024,
  };
  await writeResult(result);
  console.log(JSON.stringify(result));
} finally {
  if (browser) await browser.close();
  if (proxy) {
    proxy.closeAllConnections();
    await new Promise((resolve) => proxy.close(resolve));
  }
  for (const child of children.reverse()) await stop(child);
  await rm(root, { recursive: true, force: true });
}
async function writeResult(result) {
  const { writeFile } = await import('node:fs/promises');
  await writeFile(new URL('packaged-smoke.json', assets), JSON.stringify(result, null, 2) + '\n');
}

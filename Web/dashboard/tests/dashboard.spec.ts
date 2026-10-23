// SPDX-License-Identifier: MIT
import { test, expect, type Page } from '@playwright/test';
import { fixture } from './fixtures.mjs';
async function snapshot(page: Page, modify: (s: any) => void = () => {}) {
  const data = structuredClone(fixture);
  modify(data);
  await page.route('**/api/snapshot', (r) => r.fulfill({ json: data }));
}
async function ready(page: Page) {
  await page.goto('/fixture/');
  await expect(
    page.getByRole('heading', { name: 'Busy · 2 running, 1 preparing, 3 waiting' }),
  ).toBeVisible();
}
async function noOverflow(page: Page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
}
for (const colorScheme of ['light', 'dark'] as const) {
  test(`complete ${colorScheme} dashboard, missing-data safety and responsive layouts`, async ({
    page,
  }, testInfo) => {
    await page.emulateMedia({ colorScheme });
    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await ready(page);
    for (const name of [
      'CPU',
      'Memory',
      'Disk free',
      'Thermal',
      'Now running',
      'Up next',
      'Recent',
      'Activity',
      'Managed storage',
      'Runner',
    ])
      await expect(page.getByRole('heading', { name, exact: false })).toBeVisible();
    await expect(page.getByText('78%', { exact: true })).toBeVisible();
    await expect(page.getByText('12.5 GiB eligible', { exact: true })).toBeVisible();
    for (const width of [320, 390, 768, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      await noOverflow(page);
    }
    await page.setViewportSize({
      width: testInfo.project.name === 'webkit' ? 390 : 1280,
      height: 900,
    });
    await page.screenshot({
      path: `../../.build/dashboard/${testInfo.project.name}-${colorScheme}-busy.png`,
      fullPage: true,
    });
    expect(errors).toEqual([]);
  });
}
test('missing load averages and absent metrics do not blank the page', async ({ page }) => {
  await snapshot(page, (s) => {
    delete s.status.host.load1;
    delete s.status.host.load5;
    delete s.status.host.cpuUsagePercent;
    delete s.status.storage.minimum_free_bytes;
  });
  await ready(page);
  await expect(page.getByText('Load — / — · 1m / 5m')).toBeVisible();
  await expect(page.getByText('Admission floor unavailable')).toBeVisible();
  await noOverflow(page);
});
test('older daemon without host or storage support renders useful jobs', async ({ page }) => {
  await snapshot(page, (s) => {
    delete s.status.host;
    delete s.status.artifactStorage;
    delete s.status.storage;
    delete s.status.storageReviewRunning;
  });
  await ready(page);
  await page.getByRole('button', { name: 'Review storage', exact: true }).click();
  await expect(page.getByText('Storage review requires an updated daemon.')).toBeVisible();
  await expect(page.locator('.vital .mini-badge.muted')).toHaveCount(4);
});
test('polling retains card identity, scroll, filters and focus', async ({ page }) => {
  await ready(page);
  await page
    .locator('[data-job-id="J-2207"]')
    .evaluate((el) => ((window as any).originalCard = el));
  await page.getByRole('button', { name: 'Search and filter', exact: true }).first().click();
  const input = page.getByRole('searchbox');
  await input.fill('mobile');
  await input.focus();
  await page.evaluate(() => window.scrollTo(0, 350));
  const scroll = await page.evaluate(() => scrollY);
  await page.waitForTimeout(3400);
  expect(
    await page
      .locator('[data-job-id="J-2207"]')
      .evaluate((el) => el === (window as any).originalCard),
  ).toBe(true);
  await expect(input).toBeFocused();
  await expect(input).toHaveValue('mobile');
  expect(await page.evaluate(() => scrollY)).toBe(scroll);
});
test('disconnect preserves stale snapshot, disables actions and reconnects without navigation', async ({
  page,
}, testInfo) => {
  await ready(page);
  let offline = true;
  await page.route('**/api/snapshot', (route) =>
    offline ? route.abort() : route.fulfill({ json: fixture }),
  );
  await expect(page.getByRole('heading', { name: 'Can’t reach the Mac' })).toBeVisible({
    timeout: 8000,
  });
  await expect(page.getByText('78%', { exact: true })).toBeVisible();
  await expect(
    page.locator('[data-job-id="J-2207"]').getByRole('button', { name: 'Cancel', exact: true }),
  ).toBeDisabled();
  await page.screenshot({
    path: `../../.build/dashboard/${testInfo.project.name}-offline.png`,
    fullPage: true,
  });
  offline = false;
  await page.getByRole('button', { name: 'Retry now' }).click();
  await expect(
    page.getByRole('heading', { name: 'Busy · 2 running, 1 preparing, 3 waiting' }),
  ).toBeVisible();
});
test('first load offline and empty queue have explicit states', async ({ page }, testInfo) => {
  await page.route('**/api/snapshot', (r) => r.abort());
  await page.goto('/fixture/');
  await expect(page.getByRole('heading', { name: 'Can’t reach the Mac' })).toBeVisible();
  await snapshot(page, (s) => {
    s.active = [];
    s.recent = [];
    s.status.running = 0;
    s.status.admitted = 0;
    s.status.queued = 0;
    s.status.global_wait_reasons = [];
  });
  await page.getByRole('button', { name: 'Retry now' }).click();
  await expect(page.getByText('Nothing running', { exact: true })).toBeVisible();
  await expect(page.getByText('Queue is empty', { exact: true })).toBeVisible();
  await expect(page.getByText('No finished jobs in this view.')).toBeVisible();
  await page.screenshot({
    path: `../../.build/dashboard/${testInfo.project.name}-empty.png`,
    fullPage: true,
  });
});
test('cancellation is confirmed, sent once and never automatically replayed', async ({ page }) => {
  await ready(page);
  let posts = 0;
  await page.route('**/api/cancel/*', (r) => {
    posts++;
    return r.abort();
  });
  const cancel = page
    .locator('[data-job-id="J-2207"]')
    .getByRole('button', { name: 'Cancel', exact: true });
  await cancel.click();
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  expect(posts).toBe(0);
  await cancel.click();
  await page.getByRole('button', { name: 'Cancel job', exact: true }).click();
  await expect(page.getByText(/No confirmed response/)).toBeVisible();
  await page.waitForTimeout(3200);
  expect(posts).toBe(1);
});
test('priority constraints and admission races are handled', async ({ page }) => {
  await ready(page);
  await page.route('**/api/priority/**', (r) =>
    r.fulfill({ status: 409, body: 'Job already admitted' }),
  );
  await page.getByRole('button', { name: 'Raise priority for J-2210 by 10' }).click();
  await expect(page.getByText('J-2210: Job already admitted')).toBeVisible();
  await page.getByRole('button', { name: 'Set exact priority for J-2210' }).click();
  await page.getByRole('spinbutton').fill('101');
  await page.getByRole('button', { name: 'Set priority', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Change priority' })).toBeVisible();
});
test('job details preserve exact safe text, log pause, and focus restoration', async ({ page }) => {
  await ready(page);
  const opener = page
    .locator('[data-job-id="J-2207"]')
    .getByRole('button', { name: 'Log', exact: true });
  await opener.click();
  const dialog = page.getByRole('dialog', { name: 'Job details' });
  await dialog.getByText('Technical details and artifacts', { exact: true }).click();
  await expect(dialog.getByRole('heading', { name: 'Command · exact argv' })).toBeVisible();
  await expect(dialog.getByLabel('Job output')).toContainText('Running tests…');
  await dialog.getByRole('button', { name: 'Pause live output', exact: true }).click();
  await page.waitForTimeout(3300);
  await expect(dialog.getByRole('button', { name: 'Resume live output' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();
  await expect(opener).toBeFocused();
});
test('long hostile labels are text, wrap, and stay accessible', async ({ page }) => {
  const hostile = '<img src=x onerror=alert(1)> verylonglabel'.repeat(8);
  await snapshot(page, (s) => {
    s.active[0].kind = hostile;
    s.active[0].command = ['echo', hostile];
  });
  await ready(page);
  await page.setViewportSize({ width: 320, height: 900 });
  await noOverflow(page);
  await expect(page.locator('[data-job-id="J-2207"] img')).toHaveCount(0);
  await expect(
    page
      .locator('[data-job-id="J-2207"]')
      .getByRole('button', { name: `mobile · ${hostile}`, exact: true }),
  ).toBeVisible();
});
test('storage review stays explicit, read-only, and reports partial inventory', async ({
  page,
}) => {
  let reviews = 0,
    cleanups = 0;
  await page.route('**/api/storage/*', (r) => {
    if (r.request().url().endsWith('/cleanup')) cleanups++;
    else reviews++;
    return r.fulfill({ json: { scheduled: true } });
  });
  await snapshot(page, (s) => {
    s.status.artifactStorage.categories[0].unknownSizes = 1;
  });
  await ready(page);
  expect(reviews).toBe(0);
  await page.getByRole('button', { name: 'Review storage', exact: true }).first().click();
  await expect(
    page.getByText('No files are deleted from this page.', { exact: false }),
  ).toBeVisible();
  await page.getByRole('button', { name: 'Refresh storage review' }).click();
  await expect(page.getByText('Review accepted.', { exact: false })).toBeVisible();
  expect(reviews).toBe(1);
  expect(cleanups).toBe(0);
});

test('hidden tabs suspend snapshot and log fetching until visible', async ({ page }) => {
  let snapshots = 0,
    logs = 0;
  await page.route('**/api/snapshot', (r) => {
    snapshots++;
    return r.fulfill({ json: fixture });
  });
  await page.route('**/api/logs/**', (r) => {
    logs++;
    return r.fulfill({ json: { data: 'output', offset: 0, at_end: true, job_finished: false } });
  });
  await ready(page);
  await page
    .locator('[data-job-id="J-2207"]')
    .getByRole('button', { name: 'Log', exact: true })
    .click();
  await expect(page.getByLabel('Job output')).toContainText('output');
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  const before = [snapshots, logs];
  await page.waitForTimeout(3400);
  expect([snapshots, logs]).toEqual(before);
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await expect.poll(() => snapshots).toBeGreaterThan(before[0]);
  await expect.poll(() => logs).toBeGreaterThan(before[1]);
});

test('large queues render in bounded batches and enlarged text still fits', async ({ page }) => {
  await snapshot(page, (s) => {
    s.active = [
      ...s.active.slice(0, 3),
      ...Array.from({ length: 1000 }, (_, i) => ({
        ...s.active[3],
        id: `J-large-${i}`,
        position: i + 1,
      })),
    ];
    s.status.queued = 1000;
  });
  await page.goto('/fixture/');
  await expect(page.getByRole('heading', { name: 'Up next 1000', exact: true })).toBeVisible();
  await expect(page.locator('[data-job-id]')).toHaveCount(33);
  await page.getByRole('button', { name: 'Show next 30 waiting jobs' }).click();
  await expect(page.locator('[data-job-id]')).toHaveCount(63);
  await page.evaluate(() => (document.documentElement.style.fontSize = '26px'));
  await page.setViewportSize({ width: 320, height: 900 });
  await noOverflow(page);
});

test('late log responses cannot replace a newly selected job and completed tails stop', async ({
  page,
}) => {
  await ready(page);
  let lateResolve: () => void = () => {},
    newReads = 0;
  const held = new Promise<void>((resolve) => (lateResolve = resolve));
  await page.route('**/api/logs/J-2207/tail', async (r) => {
    await held;
    try {
      await r.fulfill({
        json: { data: 'old output', offset: 0, at_end: true, job_finished: false },
      });
    } catch {
      /* closing aborts the old request */
    }
  });
  await page.route('**/api/logs/J-2208/tail', (r) => {
    newReads++;
    return r.fulfill({
      json: { data: 'finished output', offset: 0, at_end: true, job_finished: true },
    });
  });
  await page
    .locator('[data-job-id="J-2207"]')
    .getByRole('button', { name: 'Log', exact: true })
    .click();
  await page.getByRole('button', { name: 'Close Job details' }).click();
  await page
    .locator('[data-job-id="J-2208"]')
    .getByRole('button', { name: 'Log', exact: true })
    .click();
  await expect(page.getByLabel('Job output')).toHaveText('finished output');
  lateResolve();
  await page.waitForTimeout(1400);
  await expect(page.getByLabel('Job output')).toHaveText('finished output');
  expect(newReads).toBe(1);
});

test('cleanup accountability shows confirmed bytes, protected data and actionable failures', async ({
  page,
}) => {
  await snapshot(page, (s) => {
    s.status.lastCleanup = {
      finishedAt: 1792782000,
      automatic: true,
      inventoryIncomplete: true,
      removedCount: 2,
      removedBytes: 1048576,
      unknownRemovedSizes: 1,
      deferredCount: 3,
      failureCount: 1,
      failures: ['Could not remove <unsafe> output'],
      unavailableRoots: ['Original output drive is disconnected'],
    };
    s.status.artifactStorage.protected = [
      { name: 'Pinned', bytes: 2097152, count: 2, unknownSizes: 1 },
      { name: 'Active / cleanup pending', bytes: 4194304, count: 1, unknownSizes: 0 },
    ];
  });
  await ready(page);
  await expect(
    page.getByText('Inventory incomplete; remaining targets unknown', { exact: false }),
  ).toBeVisible();
  await expect(page.getByText('2 targets removed', { exact: false })).toBeVisible();
  await page.getByText('Needs attention', { exact: true }).click();
  await expect(page.getByText('Could not remove <unsafe> output', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Review storage', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: 'Protected and retained' })).toBeVisible();
  await expect(page.getByText('Pinned · 2 runs', { exact: true })).toBeVisible();
  await page.setViewportSize({ width: 320, height: 740 });
  await noOverflow(page);
});

test('activity separates phases, reveals timing on hover and opens a concise job summary', async ({
  page,
}, testInfo) => {
  let detailReads = 0;
  await page.route('**/api/job/**', (route) => {
    detailReads++;
    return route.continue();
  });
  await ready(page);
  const row = page.locator('[data-activity-job="J-2207"]');
  await expect(row.locator('rect.phase-queue')).toHaveCount(1);
  await expect(row.locator('rect.phase-preparation')).toHaveCount(1);
  await expect(row.locator('rect.phase-run')).toHaveCount(1);
  const colors = await row
    .locator('rect')
    .evaluateAll((nodes) => nodes.map((n) => getComputedStyle(n).fill));
  expect(new Set(colors).size).toBe(3);
  expect(detailReads).toBe(0);
  if (testInfo.project.name === 'chromium') {
    await row.focus();
    await page.keyboard.press('Tab');
    await page.keyboard.press('Shift+Tab');
    await expect(row).toBeFocused();
    await expect(row.getByRole('tooltip')).toBeVisible();
    await row.hover();
    await expect(row.getByRole('tooltip')).toBeVisible();
    await expect(row.getByRole('tooltip')).toContainText('Queue wait: 50s');
    await expect(row.getByRole('tooltip')).toContainText('Runtime: 6m 12s');
    await page.screenshot({
      path: `../../.build/dashboard/activity-hover-${testInfo.project.name}.png`,
      fullPage: false,
    });
  }
  await row.click();
  const dialog = page.getByRole('dialog', { name: 'Job details' });
  await expect(
    dialog.getByRole('heading', { name: 'mobile · Smoke · Test filter', exact: true }),
  ).toBeVisible();
  await expect(dialog.locator('.job-timing.phase-queue')).toContainText('50s');
  await expect(dialog.locator('.job-timing.phase-preparation')).toContainText('10s');
  await expect(dialog.locator('.job-timing.phase-run')).toContainText('6m 12s');
  await expect(dialog.getByRole('heading', { name: 'Command · exact argv' })).not.toBeVisible();
  await expect(dialog.getByRole('heading', { name: 'Live output' })).toBeVisible();
  await page.screenshot({
    path: `../../.build/dashboard/job-summary-${testInfo.project.name}.png`,
    fullPage: false,
  });
  await page.setViewportSize({ width: 320, height: 740 });
  await noOverflow(page);
  expect(await dialog.evaluate((d) => d.scrollWidth <= d.clientWidth)).toBe(true);
  await page.screenshot({
    path: `../../.build/dashboard/job-summary-compact-${testInfo.project.name}.png`,
    fullPage: false,
  });
});

test('activity includes queued-only jobs and runtime stays a phase color after failure', async ({
  page,
}) => {
  await snapshot(page, (s) => {
    s.active[0].state = 'failed';
    s.active[0].finished_at = s.generatedAt;
  });
  await ready(page);
  const queued = page.locator('[data-activity-job="J-2210"]');
  await expect(queued).toBeVisible();
  await expect(queued.locator('rect.phase-queue')).toHaveCount(1);
  await expect(queued.locator('rect.phase-run')).toHaveCount(0);
  const failed = page.locator('[data-activity-job="J-2207"]');
  await expect(failed.locator('rect.phase-run')).toHaveCount(1);
  await expect(failed).toHaveAttribute('aria-label', /failed/);
});

test('retry details do not mislabel earlier execution as queue wait', async ({ page }) => {
  const retried = { ...fixture.active[0], attempt: 1 };
  await snapshot(page, (s) => {
    s.active[0] = retried;
  });
  await page.route('**/api/job/J-2207', (route) => route.fulfill({ json: retried }));
  await ready(page);
  const row = page.locator('[data-activity-job="J-2207"]');
  await expect(row.locator('rect.phase-queue')).toHaveCount(0);
  await row.click();
  const dialog = page.getByRole('dialog', { name: 'Job details' });
  await expect(dialog.locator('.job-timing.phase-queue strong')).toHaveText('—');
  await expect(dialog.locator('.job-timing.phase-queue')).toContainText(
    'Unavailable across retries',
  );
  await expect(dialog.locator('.job-timing.phase-run')).toContainText('6m 12s');
});

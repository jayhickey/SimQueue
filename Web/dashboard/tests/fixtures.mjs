// SPDX-License-Identifier: MIT
export const now = 1792779300000;
const iso = (seconds) => new Date(now - seconds * 1000).toISOString();
const job = (id, kind, state, seconds, extra = {}) => ({
  id,
  project: 'mobile',
  kind,
  state,
  priority: 50,
  run_timeout_seconds: 1800,
  submitter: 'developer',
  attempt: 0,
  queue_time: iso(seconds + 60),
  admitted_at: state === 'queued' ? null : iso(seconds + 10),
  started_at: ['queued', 'admitted'].includes(state) ? null : iso(seconds),
  finished_at: ['queued', 'admitted', 'running'].includes(state) ? null : iso(20),
  granted_sims: state === 'queued' ? 0 : 1,
  wait_reasons: [],
  command: ['swift', 'test', '--parallel'],
  ...extra,
});
export const fixture = {
  generatedAt: new Date(now).toISOString(),
  status: {
    running: 2,
    admitted: 1,
    queued: 3,
    paused: false,
    draining: false,
    load_throttled: false,
    global_wait_reasons: [{ code: 'memory', summary: 'Next up is waiting for memory' }],
    daemon: { version: '0.1.21', backend: 'simctl', probe: 'system', started_at: iso(7200) },
    health: { health: 'ok', reasons: [] },
    host: {
      sampledAt: now / 1000,
      cpuUsagePercent: 78,
      cpuCount: 10,
      load1: 9.4,
      load5: 8.1,
      availableMemoryBytes: 3.4 * 1024 ** 3,
      totalMemoryBytes: 24 * 1024 ** 3,
      memoryPressure: 'warn',
      swapUsedBytes: 2.1 * 1024 ** 3,
      freeDiskBytes: 23.1 * 1024 ** 3,
      thermalState: 'fair',
    },
    storage: {
      system_free_bytes: 23.1 * 1024 ** 3,
      minimum_free_bytes: 20 * 1024 ** 3,
      free_bytes: 183 * 1024 ** 3,
      available: true,
      job_output_root: '/managed/jobs',
      state_directory: '/managed/state',
    },
    storageReviewRunning: false,
    artifactStorage: {
      sampledAt: now / 1000 - 60,
      categories: [
        { name: 'DerivedData', bytes: 38 * 1024 ** 3, count: 14, unknownSizes: 0 },
        { name: 'Result bundles', bytes: 6.2 * 1024 ** 3, count: 9, unknownSizes: 0 },
        { name: 'Other run output', bytes: 2.4 * 1024 ** 3, count: 14, unknownSizes: 0 },
        { name: 'Managed simulator data', bytes: 21 * 1024 ** 3, count: 4, unknownSizes: 0 },
      ],
      reclaimableBytes: 12.5 * 1024 ** 3,
      candidateCount: 2,
      unknownCandidateSizes: 0,
      candidates: [
        { path: '/managed/jobs/old-run', bytes: 12.5 * 1024 ** 3, reason: 'Past retention' },
      ],
      retention: {
        succeededSeconds: 604800,
        otherSeconds: 1209600,
        unknownSeconds: 2592000,
        keptSeconds: 7776000,
        derivedDataSeconds: 86400,
        maxRemovalsPerPass: 20,
      },
      cleanupMode: 'enforce',
      removedCount: 0,
      failureCount: 0,
    },
  },
  active: [
    job('J-2207', 'Smoke · Test filter', 'running', 372, { priority: 70 }),
    job('J-2208', 'Proof video · Header conditions', 'running', 168),
    job('J-2209', 'Screenshots · Lean widget states', 'admitted', 22),
    job(
      'J-2210',
      'Screenshots · Rotation picker side-by-side vs mock, light + dark',
      'queued',
      38,
      {
        position: 1,
        priority: 90,
        wait_reasons: [
          { code: 'memory', summary: 'Waiting for memory: needs 6.8 GiB, 3.4 GiB available' },
        ],
      },
    ),
    job('J-2211', 'UI tests · Tall widget long-quote fits', 'queued', 47, {
      position: 2,
      wait_reasons: [{ code: 'simulators', summary: 'Waiting for a free simulator' }],
    }),
    job('J-2212', 'Unit tests · Share image export', 'queued', 200, {
      position: 3,
      priority: 40,
      wait_reasons: [{ code: 'load', summary: 'Waiting for host load' }],
    }),
  ],
  recent: [
    job('J-2206', 'Smoke · 7-test filter', 'failed', 340, {
      result_class: 'test_failure',
      command_exit_code: 65,
      message: '1 of 7 tests failed: testWidgetGallery',
    }),
    ...Array.from({ length: 9 }, (_, i) =>
      job(
        `J-${2205 - i}`,
        ['Screenshots · Settings layout', 'Unit tests · Gradient store', 'Archive · TestFlight'][
          i % 3
        ],
        'succeeded',
        400 + i * 60,
        { finished_at: iso(50 + i * 60), result_class: 'success', command_exit_code: 0 },
      ),
    ),
    job('J-2196', 'UI tests · Abandoned run', 'canceled', 1000, {
      finished_at: iso(900),
      result_class: 'canceled',
    }),
  ],
};

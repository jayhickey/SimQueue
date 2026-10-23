// SPDX-License-Identifier: MIT
export type At = string | number | null | undefined;
export interface Reason {
  code: string;
  summary: string;
}
export interface Job {
  id: string;
  project: string;
  kind?: string;
  state: string;
  priority: number;
  attempt?: number;
  submitter?: string;
  position?: number;
  effective_score?: number;
  granted_sims?: number;
  queue_time?: At;
  admitted_at?: At;
  started_at?: At;
  finished_at?: At;
  command?: string[];
  result_class?: string;
  command_exit_code?: number;
  message?: string;
  wait_reasons?: Reason[];
  peak_memory_mib?: number;
  git_sha?: string;
  worktree?: string;
  cwd?: string;
  run_dir?: string;
  run_deadline_at?: At;
  queue_deadline_at?: At;
  run_timeout_seconds?: number;
  queue_timeout_seconds?: number;
  exclusive?: boolean;
  retryable?: boolean;
  cleanup_pending?: boolean;
  cleanup_blocked?: boolean;
  sims?: { name: string; udid: string }[];
  artifacts?: { path: string; bytes: number }[];
  artifacts_truncated?: boolean;
}
export interface Host {
  sampledAt?: number;
  cpuUsagePercent?: number;
  cpuCount?: number;
  load1?: number;
  load5?: number;
  availableMemoryBytes?: number;
  totalMemoryBytes?: number;
  memoryPressure?: string;
  swapUsedBytes?: number;
  freeDiskBytes?: number;
  thermalState?: string;
}
export interface StorageReport {
  sampledAt: number;
  categories: { name: string; bytes: number; count: number; unknownSizes: number }[];
  reclaimableBytes: number;
  candidateCount: number;
  unknownCandidateSizes: number;
  candidates: { path: string; bytes?: number; reason: string }[];
  retention: {
    succeededSeconds?: number;
    otherSeconds?: number;
    unknownSeconds?: number;
    keptSeconds?: number;
    derivedDataSeconds?: number;
    budgetBytes?: number;
    maxRemovalsPerPass?: number;
  };
  notes?: string[];
  cleanupMode: string;
  error?: string;
  removedCount: number;
  failureCount: number;
}
export interface Status {
  running: number;
  admitted: number;
  queued: number;
  draining: boolean;
  paused: boolean;
  load_throttled: boolean;
  global_wait_reasons?: Reason[];
  template_hint?: string;
  host?: Host;
  daemon: { version: string; backend: string; started_at: At; probe?: string };
  health?: { health: string; reasons?: string[] };
  storage?: {
    system_free_bytes?: number;
    minimum_free_bytes?: number;
    free_bytes?: number;
    available: boolean;
    failure?: string;
    job_output_root: string;
    state_directory: string;
  };
  artifactStorage?: StorageReport;
  storageReviewRunning?: boolean;
}
export interface Snapshot {
  generatedAt: At;
  status: Status;
  active: Job[];
  recent: Job[];
}
export const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n);
export const epoch = (at: At): number | null => {
  const value = at == null ? NaN : typeof at === 'number' ? at * 1000 : Date.parse(at);
  return Number.isFinite(value) ? value : null;
};
export const duration = (ms: number | null | undefined): string => {
  if (!finite(ms)) return '—';
  const s = Math.max(0, Math.floor(ms / 1000));
  return s < 60
    ? `${s}s`
    : s < 3600
      ? `${Math.floor(s / 60)}m ${s % 60}s`
      : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
};
export const bytes = (n: number | undefined | null, digits = 1): string => {
  if (!finite(n) || n < 0) return 'Unavailable';
  if (n === 0) return '0 B';
  const i = Math.min(4, Math.max(0, Math.floor(Math.log(n) / Math.log(1024))));
  return `${(n / 1024 ** i).toFixed(i ? digits : 0)} ${['B', 'KiB', 'MiB', 'GiB', 'TiB'][i]}`;
};
export const numeric = (n: number | undefined, digits = 1) => (finite(n) ? n.toFixed(digits) : '—');
// Formatting is on every card's update path. Reuse formatters rather than creating
// dozens of expensive Intl objects on each three-second snapshot.
const dateOptions: Intl.DateTimeFormatOptions = {
  month: 'short',
  day: 'numeric',
  hour: 'numeric',
  minute: '2-digit',
};
const defaultDateFormatter = new Intl.DateTimeFormat('en-US', dateOptions);
const timeFormatter = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
const zoneFormatters = new Map<string, Intl.DateTimeFormat>();
export const stamp = (at: At, timeZone?: string): string => {
  const value = epoch(at);
  if (value === null) return '—';
  if (!timeZone) return defaultDateFormatter.format(value);
  let formatter = zoneFormatters.get(timeZone);
  if (!formatter) {
    if (zoneFormatters.size >= 8) zoneFormatters.clear();
    formatter = new Intl.DateTimeFormat('en-US', { ...dateOptions, timeZone });
    zoneFormatters.set(timeZone, formatter);
  }
  return formatter.format(value);
};
export const clockStamp = (at: At): string => {
  const value = epoch(at);
  return value === null ? '—' : timeFormatter.format(value);
};
export const label = (j: Job) =>
  j.kind
    ? `${j.project} · ${j.kind}`
    : `${j.project} · ${j.command?.[0]?.split('/').pop() || j.id}`;
export const human = (text: string | undefined) => text?.replaceAll('_', ' ') || 'Unavailable';
export const isActive = (j: Job) => ['queued', 'admitted', 'running'].includes(j.state);
export const tone = (j: Job): string =>
  j.state === 'succeeded'
    ? 'success'
    : j.state === 'running'
      ? 'running'
      : ['queued', 'admitted'].includes(j.state)
        ? 'warning'
        : ['canceled', 'expired'].includes(j.state)
          ? 'muted'
          : 'danger';
export const stateLabel = (j: Job) =>
  j.state === 'admitted' ? 'Preparing' : j.state === 'queued' ? 'Waiting' : human(j.state);
export function timings(j: Job, now: number): [number | null, number | null, number | null] {
  const q = epoch(j.queue_time),
    a = epoch(j.admitted_at),
    s = epoch(j.started_at),
    f = epoch(j.finished_at),
    end = f ?? now;
  return [
    q === null ? null : (a ?? s ?? end) - q,
    a === null ? null : (s ?? end) - a,
    s === null ? null : end - s,
  ];
}
export function matches(j: Job, query: string, project: string, state: string): boolean {
  return (
    (!project || j.project === project) &&
    (!state || j.state === state) &&
    [j.id, j.project, j.kind, j.submitter, ...(j.command || [])]
      .join(' ')
      .toLowerCase()
      .includes(query.toLowerCase())
  );
}
export function recentSummary(jobs: Job[]) {
  const passed = jobs.filter((j) => j.state === 'succeeded').length;
  const failed = jobs.filter((j) =>
    ['failed', 'infra_failed', 'timed_out', 'interrupted'].includes(j.state),
  ).length;
  const durations = jobs
    .map((j) => {
      const s = epoch(j.started_at),
        f = epoch(j.finished_at);
      return s === null || f === null || f < s ? null : f - s;
    })
    .filter(finite)
    .sort((a, b) => a - b);
  const mid = Math.floor(durations.length / 2);
  return {
    passed,
    failed,
    other: jobs.length - passed - failed,
    rate: passed + failed ? Math.round((passed * 100) / (passed + failed)) : null,
    median: durations.length ? (durations[mid] + durations[durations.length - 1 - mid]) / 2 : null,
  };
}
export const thermalValue = (state: string | undefined) =>
  ({ nominal: 0, fair: 1, serious: 2, critical: 3 })[state || ''];
export type Sample = {
  at: number;
  cpu: number | null;
  memory: number | null;
  disk: number | null;
  thermal: number | null;
};
export function addSample(samples: Sample[], s: Snapshot): Sample[] {
  const h = s.status.host,
    at = finite(h?.sampledAt) ? h.sampledAt * 1000 : null,
    generated = epoch(s.generatedAt);
  if (at === null || generated === null || generated - at > 15000 || samples.at(-1)?.at === at)
    return samples;
  const value = (n: unknown) => (finite(n) ? n : null);
  return [
    ...samples,
    {
      at,
      cpu: value(h?.cpuUsagePercent),
      memory: value(h?.availableMemoryBytes),
      disk: value(h?.freeDiskBytes),
      thermal: value(thermalValue(h?.thermalState)),
    },
  ].slice(-120);
}
export type Metric = 'cpu' | 'memory' | 'disk' | 'thermal';
export function trendSegments(samples: Sample[], metric: Metric): Sample[][] {
  const groups: Sample[][] = [];
  for (const s of samples) {
    if (s[metric] === null) {
      groups.push([]);
      continue;
    }
    let group = groups.at(-1);
    if (!group || (group.length && s.at - group.at(-1)!.at > 15000)) {
      group = [];
      groups.push(group);
    }
    group.push(s);
  }
  return groups.filter((g) => g.length);
}
export class APIError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
  }
}
export async function request<T>(
  path: string,
  options: { method?: 'POST'; signal?: AbortSignal } = {},
): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  options.signal?.addEventListener('abort', abort, { once: true });
  if (options.signal?.aborted) controller.abort();
  const timer = setTimeout(abort, 12000);
  try {
    const r = await fetch(`api/${path}`, {
      cache: 'no-store',
      method: options.method,
      headers: options.method ? { 'X-SimQueue-Action': '1' } : undefined,
      signal: controller.signal,
    });
    if (!r.ok) throw new APIError((await r.text()).slice(0, 1000) || 'Unavailable', r.status);
    return await r.json();
  } finally {
    clearTimeout(timer);
    options.signal?.removeEventListener('abort', abort);
  }
}
// A single scheduling lane: refresh requests (including manual retry) never overlap.
export function createPoller(
  task: () => Promise<boolean>,
  visible: () => boolean,
  schedule = (fn: () => void, ms: number) => setTimeout(fn, ms),
  cancel = (id: ReturnType<typeof setTimeout>) => clearTimeout(id),
) {
  let timer: ReturnType<typeof setTimeout> | undefined,
    stopped = false,
    busy = false,
    failures = 0,
    rerun = false;
  async function run() {
    if (stopped) return;
    if (busy) {
      rerun = true;
      return;
    }
    if (timer !== undefined) cancel(timer);
    busy = true;
    try {
      if (visible()) failures = (await task()) ? 0 : failures + 1;
    } finally {
      busy = false;
      if (!stopped) {
        const delay = rerun ? 0 : Math.min(30000, 3000 * 2 ** Math.min(failures, 4));
        rerun = false;
        timer = schedule(run, delay);
      }
    }
  }
  return {
    run,
    stop: () => {
      stopped = true;
      if (timer !== undefined) cancel(timer);
    },
  };
}

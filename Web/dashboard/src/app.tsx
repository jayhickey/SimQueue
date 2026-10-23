// SPDX-License-Identifier: MIT
import { Component, render, type ComponentChildren } from 'preact';
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import {
  APIError,
  addSample,
  bytes,
  clockStamp,
  createPoller,
  duration,
  epoch,
  finite,
  human,
  isActive,
  label,
  matches,
  numeric,
  recentSummary,
  request,
  stamp,
  stateLabel,
  thermalValue,
  timings,
  tone,
  trendSegments,
  type Job,
  type Metric,
  type Sample,
  type Snapshot,
  type StorageReport,
} from './model';

// Safari does not focus buttons on pointer activation. Remember the initiating control
// explicitly so dismissing either a detail dialog or a nested confirmation restores focus.
let pointerTrigger: HTMLElement | null = null;
let pointerAt = 0;
document.addEventListener(
  'pointerdown',
  (event) => {
    pointerTrigger =
      event.target instanceof Element
        ? event.target.closest<HTMLElement>('button, a, input, select, summary')
        : null;
    pointerAt = performance.now();
  },
  { capture: true, passive: true },
);

function useDashboard() {
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [connection, setConnection] = useState<'connecting' | 'live' | 'offline'>('connecting');
  const [samples, setSamples] = useState<Sample[]>([]);
  const poller = useRef<ReturnType<typeof createPoller>>();
  useEffect(() => {
    const controller = new AbortController();
    const p = createPoller(
      async () => {
        try {
          const next = await request<Snapshot>('snapshot', { signal: controller.signal });
          if (!next.status || !Array.isArray(next.active) || !Array.isArray(next.recent))
            throw new Error('Invalid snapshot');
          if (!controller.signal.aborted) {
            setSnapshot(next);
            setSamples((prev) => addSample(prev, next));
            setConnection('live');
          }
          return true;
        } catch {
          if (!controller.signal.aborted) setConnection('offline');
          return false;
        }
      },
      () => !document.hidden,
    );
    poller.current = p;
    const visible = () => {
      if (!document.hidden) void p.run();
    };
    document.addEventListener('visibilitychange', visible);
    window.addEventListener('online', visible);
    void p.run();
    return () => {
      p.stop();
      controller.abort();
      document.removeEventListener('visibilitychange', visible);
      window.removeEventListener('online', visible);
    };
  }, []);
  return { snapshot, connection, samples, refresh: () => void poller.current?.run() };
}
function Dot({ kind = 'success' }: { kind?: string }) {
  return <span class={`dot ${kind}`} aria-hidden="true" />;
}
function Empty({ children }: { children: ComponentChildren }) {
  return <div class="empty">{children}</div>;
}
function Heading({
  title,
  count,
  aside,
  id,
}: {
  title: string;
  count?: number;
  aside?: ComponentChildren;
  id?: string;
}) {
  return (
    <div class="section-heading">
      <h2 id={id}>
        {title}
        {count !== undefined && <span class="count">{count}</span>}
      </h2>
      {aside && <span class="section-aside">{aside}</span>}
    </div>
  );
}
function Sparkline({ samples, metric }: { samples: Sample[]; metric: Metric }) {
  const groups = trendSegments(samples, metric);
  const values = groups
    .flat()
    .map((s) => s[metric]!)
    .filter(finite);
  const first = samples[0]?.at ?? 0,
    last = samples.at(-1)?.at ?? first,
    span = Math.max(1, last - first);
  const low = metric === 'cpu' || metric === 'thermal' ? 0 : Math.min(...values),
    high = metric === 'cpu' ? 100 : metric === 'thermal' ? 3 : Math.max(...values);
  const point = (s: Sample) =>
    `${2 + ((s.at - first) / span) * 196},${27 - ((s[metric]! - low) / Math.max(1, high - low)) * 22}`;
  return (
    <svg
      class="sparkline"
      viewBox="0 0 200 32"
      preserveAspectRatio="none"
      role="img"
      aria-label={`${metric} trend this tab, ${values.length} readings${!values.length ? ', unavailable' : ''}`}
    >
      <path class="spark-base" d="M0 29 H200" />
      {groups.map((g, i) =>
        g.length === 1 ? (
          <circle key={i} cx={point(g[0]).split(',')[0]} cy={point(g[0]).split(',')[1]} r="1.8" />
        ) : (
          <polyline key={i} points={g.map(point).join(' ')} />
        ),
      )}
    </svg>
  );
}
function Vitals({
  snapshot,
  samples,
  stale,
}: {
  snapshot?: Snapshot;
  samples: Sample[];
  stale: boolean;
}) {
  const s = snapshot?.status,
    h = s?.host,
    storage = s?.storage;
  const disk = storage?.system_free_bytes ?? h?.freeDiskBytes,
    floor = storage?.minimum_free_bytes;
  const margin = finite(disk) && finite(floor) ? disk - floor : null;
  const thermal = thermalValue(h?.thermalState),
    pressure = h?.memoryPressure;
  const memoryWarning = pressure !== undefined && pressure !== 'normal';
  const cards: [string, Metric, string, string, string, string][] = [
    [
      'CPU',
      'cpu',
      finite(h?.cpuUsagePercent) ? `${numeric(h.cpuUsagePercent, 0)}%` : '—',
      finite(h?.cpuCount) ? `${h.cpuCount} cores` : 'Unavailable',
      `Load ${numeric(h?.load1)} / ${numeric(h?.load5)} · 1m / 5m`,
      !finite(h?.cpuCount) && !finite(h?.cpuUsagePercent)
        ? 'muted'
        : s?.load_throttled
          ? 'warning'
          : 'running',
    ],
    [
      'Memory',
      'memory',
      bytes(h?.availableMemoryBytes),
      pressure ? human(pressure) : 'Unavailable',
      `of ${bytes(h?.totalMemoryBytes)} · Swap ${bytes(h?.swapUsedBytes)}`,
      !pressure ? 'muted' : memoryWarning ? 'warning' : 'success',
    ],
    [
      'Disk free',
      'disk',
      bytes(disk),
      margin === null
        ? 'Unavailable'
        : margin < 0
          ? 'Below floor'
          : margin < 5 * 1024 ** 3
            ? 'Low'
            : 'Healthy',
      finite(floor)
        ? floor === 0
          ? 'Admission disk floor disabled'
          : `${margin === null ? '—' : bytes(Math.abs(margin))} ${margin !== null && margin < 0 ? 'below' : 'above'} ${bytes(floor, 0)} floor`
        : 'Admission floor unavailable',
      margin === null ? 'muted' : margin < 5 * 1024 ** 3 ? 'warning' : 'success',
    ],
    [
      'Thermal',
      'thermal',
      h?.thermalState ? human(h.thermalState) : '—',
      thermal === undefined
        ? 'Unavailable'
        : thermal >= 2
          ? 'Hot'
          : thermal === 1
            ? 'Warm'
            : 'Healthy',
      h?.sampledAt ? `Sample ${clockStamp(h.sampledAt)}` : 'No resource sample',
      thermal === undefined ? 'muted' : thermal > 0 ? 'warning' : 'success',
    ],
  ];
  return (
    <section class={`vitals ${stale ? 'stale' : ''}`} aria-label="Runner vitals">
      {cards.map(([title, metric, value, badge, detail, color]) => (
        <article class={`vital ${color}`} key={metric}>
          <div class="vital-label">
            <h2>{title}</h2>
            <span class={`mini-badge ${color}`}>{badge}</span>
          </div>
          <div class="vital-value">
            {value}
            {metric === 'memory' && finite(h?.availableMemoryBytes) && <small> free</small>}
          </div>
          <p>{detail}</p>
          <Sparkline samples={samples} metric={metric} />
          <span class="trend-label">this tab{stale ? ' · stale' : ''}</span>
        </article>
      ))}
    </section>
  );
}
function StatusSummary({
  snapshot,
  connection,
  openJob,
  openStorage,
  refresh,
}: {
  snapshot?: Snapshot;
  connection: string;
  openJob: (id: string) => void;
  openStorage: () => void;
  refresh: () => void;
}) {
  const s = snapshot?.status,
    h = s?.host,
    offline = connection === 'offline';
  const reasons = s?.global_wait_reasons || [];
  const failed = snapshot?.recent
    .filter((j) => ['failed', 'infra_failed', 'timed_out', 'interrupted'].includes(j.state))
    .sort((a, b) => (epoch(b.finished_at) ?? 0) - (epoch(a.finished_at) ?? 0))[0];
  const now = epoch(snapshot?.generatedAt) ?? 0;
  const recentFailure =
    failed && epoch(failed.finished_at) !== null && now - epoch(failed.finished_at)! < 15 * 60000
      ? failed
      : null;
  const disk = s?.storage?.system_free_bytes ?? h?.freeDiskBytes,
    floor = s?.storage?.minimum_free_bytes;
  const margin = finite(disk) && finite(floor) ? disk - floor : null;
  const admission = s?.draining
    ? 'Draining · new jobs wait'
    : s?.paused
      ? 'Paused · new jobs wait'
      : reasons.length
        ? reasons.map((r) => r.summary).join(' · ')
        : s?.load_throttled
          ? 'Admission held by host load'
          : 'Admission open';
  const headline = offline
    ? 'Can’t reach the Mac'
    : !s
      ? 'Connecting to runner…'
      : `${s.running || s.admitted ? 'Busy' : 'Ready'} · ${s.running} running, ${s.admitted} preparing, ${s.queued} waiting`;
  return (
    <section class={`status-summary ${offline ? 'disconnected' : ''}`} aria-label="Runner status">
      <div class="status-title">
        <Dot kind={offline ? 'danger' : connection === 'connecting' ? 'muted' : 'running'} />
        <h1>{headline}</h1>
      </div>
      <p class="status-description">
        {offline
          ? `Last snapshot ${snapshot ? stamp(snapshot.generatedAt) : 'unavailable'}. Check the Mac and your private network. Displayed readings are stale.`
          : s
            ? `${admission}.${finite(h?.availableMemoryBytes) ? ` ${bytes(h.availableMemoryBytes)} available memory.` : ''}`
            : 'Waiting for the first snapshot.'}
      </p>
      {offline && <button onClick={refresh}>Retry now</button>}
      {!offline && (
        <div class="warnings">
          {margin !== null && finite(floor) && floor > 0 && margin < 5 * 1024 ** 3 && (
            <div class="warning-chip warning">
              <span>
                <b>{margin < 0 ? 'Disk below admission floor' : 'Disk getting low'}</b> ·{' '}
                {bytes(Math.abs(margin))} {margin < 0 ? 'below' : 'above'} the {bytes(floor, 0)}{' '}
                floor
              </span>
              <button onClick={openStorage}>Review storage</button>
            </div>
          )}
          {h?.memoryPressure && h.memoryPressure !== 'normal' && (
            <div class="warning-chip warning">
              <span>
                <b>Memory pressure</b> · {human(h.memoryPressure)} · {bytes(h.availableMemoryBytes)}{' '}
                available
              </span>
            </div>
          )}
          {s?.health && s.health.health !== 'ok' && (
            <div class="warning-chip danger">
              <span>
                <b>Runner needs attention</b> ·{' '}
                {(s.health.reasons || []).join(' · ') || human(s.health.health)}
              </span>
            </div>
          )}
          {s?.storage?.available === false && (
            <div class="warning-chip danger">
              <span>
                <b>Output storage unavailable</b> ·{' '}
                {s.storage.failure || 'Check mount and permissions'}
              </span>
              <button onClick={openStorage}>Review storage</button>
            </div>
          )}
          {h?.sampledAt && now - h.sampledAt * 1000 > 15000 && (
            <div class="warning-chip warning">
              <span>
                <b>Resource sample is stale</b> · Last measured {stamp(h.sampledAt)}
              </span>
            </div>
          )}
          {recentFailure && (
            <div class="warning-chip danger">
              <span>
                <b>{recentFailure.id} failed</b> ·{' '}
                {duration(now - (epoch(recentFailure.finished_at) ?? now))} ago
              </span>
              <button onClick={() => openJob(recentFailure.id)}>View log</button>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
type Action = (j: Job, kind: 'cancel' | 'priority', priority?: number) => void;
function JobControls({
  job,
  disabled,
  pending,
  act,
}: {
  job: Job;
  disabled: boolean;
  pending: boolean;
  act: Action;
}) {
  if (!isActive(job)) return null;
  return (
    <div class="job-controls">
      {job.state === 'queued' && (
        <>
          <button
            title={`Set exact priority for ${job.id}`}
            aria-label={`Set exact priority for ${job.id}`}
            disabled={disabled || pending}
            onClick={() => act(job, 'priority')}
          >
            P{job.priority}
          </button>
          <div class="stepper">
            <button
              aria-label={`Raise priority for ${job.id} by 10`}
              disabled={disabled || pending || job.priority >= 100}
              onClick={() => act(job, 'priority', Math.min(100, job.priority + 10))}
            >
              ↑
            </button>
            <button
              aria-label={`Lower priority for ${job.id} by 10`}
              disabled={disabled || pending || job.priority <= 0}
              onClick={() => act(job, 'priority', Math.max(0, job.priority - 10))}
            >
              ↓
            </button>
          </div>
        </>
      )}
      <button class="cancel" disabled={disabled || pending} onClick={() => act(job, 'cancel')}>
        {pending ? 'Updating…' : 'Cancel'}
      </button>
    </div>
  );
}
function JobCard({
  job,
  now,
  open,
  disabled,
  pending,
  act,
}: {
  job: Job;
  now: number;
  open: (id: string) => void;
  disabled: boolean;
  pending: boolean;
  act: Action;
}) {
  const phase = timings(job, now),
    queued = job.state === 'queued';
  return (
    <article class={`job-card ${tone(job)}`} data-job-id={job.id}>
      <div class="job-top">
        <div class="job-name">
          {queued && <span class="position">#{job.position ?? '—'}</span>}
          <button class="text-button" title={label(job)} onClick={() => open(job.id)}>
            {label(job)}
          </button>
        </div>
        {!queued && (
          <div class="elapsed">
            <strong>{duration(phase[job.state === 'admitted' ? 1 : 2])}</strong>
            <span>
              {job.state === 'admitted'
                ? 'preparing'
                : finite(job.run_timeout_seconds)
                  ? `of ${duration(job.run_timeout_seconds * 1000)} limit`
                  : 'running'}
            </span>
          </div>
        )}
      </div>
      <div class="job-meta">
        <span class={`state ${tone(job)}`}>
          <Dot kind={tone(job)} />
          {stateLabel(job)}
        </span>
        <span>{job.id}</span>
        <span>P{job.priority}</span>
        {!queued && <span>{job.granted_sims ?? '—'} sims</span>}
      </div>
      {queued && (
        <p class="wait-reason">
          {job.wait_reasons?.map((r) => r.summary).join(' · ') ||
            'Waiting for the next scheduling pass'}
        </p>
      )}
      {!queued && <div class={`activity-accent ${tone(job)}`} aria-hidden="true" />}
      <div class="job-bottom">
        <span class="job-time">
          {queued
            ? `waiting ${duration(phase[0])}`
            : `${duration(phase[0])} wait · ${duration(phase[1])} prep`}
        </span>
        <time
          dateTime={new Date(
            epoch(queued ? job.queue_time : (job.started_at ?? job.admitted_at)) ?? 0,
          ).toISOString()}
          title={stamp(queued ? job.queue_time : (job.started_at ?? job.admitted_at))}
        >
          {clockStamp(queued ? job.queue_time : (job.started_at ?? job.admitted_at))}
        </time>
        <div class="job-actions">
          {!queued && <button onClick={() => open(job.id)}>Log</button>}
          <JobControls job={job} disabled={disabled} pending={pending} act={act} />
        </div>
      </div>
    </article>
  );
}
function Recent({
  jobs,
  now,
  open,
  showFilters,
}: {
  jobs: Job[];
  now: number;
  open: (id: string) => void;
  showFilters: () => void;
}) {
  const stats = useMemo(() => recentSummary(jobs), [jobs]);
  const [all, setAll] = useState(false);
  return (
    <section aria-labelledby="recent-title">
      <Heading id="recent-title" title="Recent" count={jobs.length} aside="last 100 kept" />
      <div class="results-summary">
        <span class="success">{stats.passed} passed</span>
        <span class="danger">{stats.failed} failed</span>
        {stats.other > 0 && <span>{stats.other} other</span>}
        <span>{stats.rate === null ? '—' : `${stats.rate}%`} pass rate</span>
        <span>{duration(stats.median)} median run</span>
      </div>
      <p class="summary-caption">
        Displayed results · pass rate excludes canceled/expired · median uses known runs
      </p>
      <div class="recent-list">
        {jobs.length ? (
          jobs.slice(0, all ? 100 : 12).map((j) => (
            <button
              class={`recent-row ${tone(j)}`}
              key={j.id}
              onClick={() => open(j.id)}
              title={label(j)}
            >
              <span class="result-icon" aria-label={human(j.result_class || j.state)}>
                {j.state === 'succeeded' ? '✓' : tone(j) === 'danger' ? '×' : '−'}
              </span>
              <span class="recent-content">
                <span class="recent-name">{label(j)}</span>
                <span class="recent-meta">
                  {j.id} · {duration(timings(j, now)[2])} · {clockStamp(j.finished_at)}
                  {j.command_exit_code != null ? ` · exit ${j.command_exit_code}` : ''}
                </span>
                {j.state !== 'succeeded' && (
                  <span class="result-message">
                    {human(j.result_class || j.state)}
                    {j.message ? ` · ${j.message}` : ''}
                  </span>
                )}
              </span>
            </button>
          ))
        ) : (
          <Empty>No finished jobs in this view.</Empty>
        )}
      </div>
      <div class="section-links">
        {jobs.length > 12 && (
          <button class="text-button" onClick={() => setAll(!all)}>
            {all ? 'Show fewer' : `Show all ${jobs.length}`}
          </button>
        )}
        <button class="text-button" onClick={showFilters}>
          Search and filter
        </button>
      </div>
    </section>
  );
}
function Timeline({ jobs, now, open }: { jobs: Job[]; now: number; open: (id: string) => void }) {
  const started = jobs
    .filter((j) => epoch(j.started_at) !== null)
    .sort((a, b) => (epoch(b.started_at) ?? 0) - (epoch(a.started_at) ?? 0))
    .slice(0, 20);
  const start = started.length ? Math.min(...started.map((j) => epoch(j.started_at)!)) : now;
  const end = started.length ? Math.max(...started.map((j) => epoch(j.finished_at) ?? now)) : now;
  const span = Math.max(1000, end - start),
    active = started.some((j) => !j.finished_at);
  return (
    <section class="side-section" aria-labelledby="activity-title">
      <Heading id="activity-title" title="Activity" aside={`last ${duration(span)}`} />
      <div class="timeline card">
        {started.length ? (
          <>
            <div class="timeline-axis">
              <span>{clockStamp(start / 1000)}</span>
              <span>{active ? 'now' : clockStamp(end / 1000)}</span>
            </div>
            {started.map((j) => (
              <button
                class="timeline-row"
                key={j.id}
                onClick={() => open(j.id)}
                title={`${label(j)} · ${stamp(j.started_at)} → ${stamp(j.finished_at)} · ${duration(timings(j, now)[2])}`}
              >
                <span>{label(j)}</span>
                <svg
                  viewBox="0 0 100 8"
                  preserveAspectRatio="none"
                  role="img"
                  aria-label={`${human(j.state)}, ${duration(timings(j, now)[2])}`}
                >
                  <path class="timeline-track" d="M0 4 H100" />
                  <rect
                    class={tone(j)}
                    x={Math.max(0, ((epoch(j.started_at)! - start) * 100) / span)}
                    y="1"
                    width={Math.max(
                      1,
                      (((epoch(j.finished_at) ?? now) - epoch(j.started_at)!) * 100) / span,
                    )}
                    height="6"
                    rx="1"
                  />
                  {active && <path class="now-marker" d="M99 0 V8" />}
                </svg>
              </button>
            ))}
          </>
        ) : (
          <Empty>No execution history yet.</Empty>
        )}
      </div>
    </section>
  );
}
function agePolicy(n: number | undefined) {
  return finite(n)
    ? n === 0
      ? 'disabled'
      : n < 86400
        ? `${numeric(n / 3600)} hours`
        : `${numeric(n / 86400, 0)} days`
    : 'not configured';
}
function CleanupOutcome({ snapshot }: { snapshot?: Snapshot }) {
  const summary = snapshot?.status.lastCleanup;
  if (!summary) return <p class="muted">No completed cleanup report yet.</p>;
  return (
    <div class="cleanup-outcome">
      <p>
        <strong>Last cleanup · {stamp(summary.finishedAt)}</strong>
      </p>
      <p>
        {summary.removedCount} targets removed · {bytes(summary.removedBytes)} logical data
        {summary.unknownRemovedSizes > 0 ? ` + ${summary.unknownRemovedSizes} unknown sizes` : ''}
      </p>
      <p class="muted">
        {summary.automatic ? 'Automatic retention' : 'Requested cleanup'} ·{' '}
        {summary.inventoryIncomplete
          ? 'Inventory incomplete; remaining targets unknown'
          : `${summary.deferredCount} deferred or protected`}{' '}
        · {summary.failureCount} failures
      </p>
      <p class="muted">Logical bytes removed; actual disk space recovered may differ.</p>
      {(summary.failureCount > 0 || summary.unavailableRoots.length > 0) && (
        <details>
          <summary class="danger">Needs attention</summary>
          {[...summary.failures, ...summary.unavailableRoots].map((message) => (
            <p class="danger" key={message}>
              {message}
            </p>
          ))}
          {summary.failureCount > summary.failures.length && (
            <p class="muted">
              Showing {summary.failures.length} of {summary.failureCount} failures. Full details are
              in the daemon audit log.
            </p>
          )}
          {summary.unavailableRoots.length > 0 && (
            <p class="muted">
              Reconnect the original drive at its configured mount path. Queued work resumes
              automatically; interrupted commands are not replayed automatically.
            </p>
          )}
        </details>
      )}
    </div>
  );
}

function Storage({
  snapshot,
  online,
  open,
}: {
  snapshot?: Snapshot;
  online: boolean;
  open: () => void;
}) {
  const report = snapshot?.status.artifactStorage,
    categories = report?.categories || [],
    total = categories.reduce((n, c) => n + c.bytes, 0),
    unknown = categories.some((c) => c.unknownSizes > 0);
  const busy = snapshot?.status.storageReviewRunning;
  let offset = 0;
  return (
    <section class="side-section" aria-labelledby="storage-title">
      <Heading
        id="storage-title"
        title="Managed storage"
        aside={report ? `reviewed ${clockStamp(report.sampledAt)}` : 'not measured'}
      />
      <div class="storage card">
        <div class="storage-numbers">
          <strong>{report ? bytes(total) : '—'}</strong>
          <span>
            {report
              ? `${bytes(report.reclaimableBytes)} eligible${report.unknownCandidateSizes ? ' + unknown' : ''}`
              : 'Review to measure'}
          </span>
        </div>
        {report && (
          <>
            <svg
              class="storage-bar"
              viewBox="0 0 100 6"
              preserveAspectRatio="none"
              role="img"
              aria-label="Managed storage by category"
            >
              {categories.map((c, i) => {
                const x = offset,
                  width = total ? (c.bytes * 100) / total : 0;
                offset += width;
                return (
                  <rect
                    key={c.name}
                    class={`category-${i % 6}`}
                    x={x}
                    y="0"
                    width={width}
                    height="6"
                  />
                );
              })}
            </svg>
            <ul class="storage-categories">
              {categories.map((c, i) => (
                <li key={c.name}>
                  <span>
                    <i class={`category-${i % 6}`} />
                    {c.name}
                  </span>
                  <span>
                    {bytes(c.bytes)}
                    {c.unknownSizes ? ` + ${c.unknownSizes} unknown` : ''}
                  </span>
                </li>
              ))}
            </ul>
            {unknown && (
              <p class="muted">Partial inventory: unknown sizes are not counted as zero.</p>
            )}
            <p class="muted storage-note">
              Logical sizes; shared blocks may reduce actual reclaimed space.
            </p>
          </>
        )}
        {!report && (
          <p class="muted">
            Measure managed artifacts on demand. No storage scan runs on page refresh.
          </p>
        )}
        <CleanupOutcome snapshot={snapshot} />
        <div class="storage-buttons">
          <button onClick={open}>Review storage</button>
          <button
            disabled={!online || !report || report.candidateCount === 0 || !!report.error}
            onClick={open}
          >
            Review cleanup{report ? ` · ${bytes(report.reclaimableBytes)}` : ''}
          </button>
        </div>
        <p class="muted storage-note">
          {busy
            ? 'Storage review running…'
            : report
              ? `Retention: passed ${agePolicy(report.retention.succeededSeconds)} · other ${agePolicy(report.retention.otherSeconds)}`
              : 'Uses the runner’s configured retention policy.'}
        </p>
        {report?.error && <p class="danger">{report.error}</p>}
      </div>
    </section>
  );
}
function Runner({ snapshot }: { snapshot?: Snapshot }) {
  const s = snapshot?.status,
    now = epoch(snapshot?.generatedAt),
    admission = s?.draining
      ? 'Draining'
      : s?.paused
        ? 'Paused'
        : s?.load_throttled || s?.global_wait_reasons?.length
          ? 'Held'
          : 'Open';
  return (
    <section class="side-section" aria-labelledby="runner-title">
      <Heading id="runner-title" title="Runner" />
      <div class="card runner">
        <dl>
          <dt>Health</dt>
          <dd>
            <span class={`mini-badge ${s?.health?.health === 'ok' ? 'success' : 'warning'}`}>
              {s?.health?.health ? human(s.health.health) : 'Unavailable'}
            </span>
          </dd>
          <dt>Admission</dt>
          <dd>{s ? admission : '—'}</dd>
          <dt>Daemon</dt>
          <dd>{s ? `${s.daemon.version} · ${s.daemon.backend}` : '—'}</dd>
          <dt>Up since</dt>
          <dd>{stamp(s?.daemon.started_at)}</dd>
          <dt>Uptime</dt>
          <dd>
            {now !== null && epoch(s?.daemon.started_at) !== null
              ? duration(now - epoch(s?.daemon.started_at)!)
              : '—'}
          </dd>
          <dt>Probe</dt>
          <dd>{s?.daemon.probe || 'Unavailable'}</dd>
          <dt>Swap used</dt>
          <dd>{bytes(s?.host?.swapUsedBytes)}</dd>
          <dt>Output volume free</dt>
          <dd>{bytes(s?.storage?.free_bytes)}</dd>
        </dl>
        {s?.template_hint && (
          <details>
            <summary>Runner configuration</summary>
            <p class="muted">{s.template_hint}</p>
          </details>
        )}
      </div>
    </section>
  );
}
function Modal({
  title,
  close,
  children,
  wide = false,
}: {
  title: string;
  close: () => void;
  children: ComponentChildren;
  wide?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current!;
    const trigger =
      performance.now() - pointerAt < 1000 && pointerTrigger?.isConnected
        ? pointerTrigger
        : document.activeElement;
    d.showModal();
    return () => {
      d.close();
      if (trigger instanceof HTMLElement && trigger.isConnected)
        trigger.focus({ preventScroll: true });
    };
  }, []);
  return (
    <dialog
      ref={ref}
      class={wide ? 'wide-dialog' : ''}
      aria-label={title}
      onCancel={(e) => {
        e.preventDefault();
        close();
      }}
    >
      <div class="dialog-heading">
        <h2>{title}</h2>
        <button onClick={close} aria-label={`Close ${title}`}>
          Close
        </button>
      </div>
      {children}
    </dialog>
  );
}
function LiveLog({ id, online }: { id: string; online: boolean }) {
  const [data, setData] = useState('Loading output…'),
    [paused, setPaused] = useState(false),
    [finished, setFinished] = useState(false),
    [message, setMessage] = useState('Connecting…');
  const output = useRef<HTMLPreElement>(null),
    generation = useRef(0),
    inFlight = useRef(false);
  useEffect(() => {
    if (paused || finished) return;
    let stopped = false,
      timer: ReturnType<typeof setTimeout>;
    const controller = new AbortController(),
      runGeneration = ++generation.current;
    async function poll() {
      if (stopped) return;
      if (!document.hidden && online && !inFlight.current) {
        inFlight.current = true;
        try {
          const tail = await request<{
            data: string;
            offset: number;
            job_finished: boolean;
            at_end: boolean;
          }>(`logs/${encodeURIComponent(id)}/tail`, { signal: controller.signal });
          if (stopped || runGeneration !== generation.current) return;
          setData(tail.data || 'No output yet.');
          const done = !!(tail.job_finished && tail.at_end);
          setFinished(done);
          setMessage(
            `${done ? 'Complete · final output.' : 'Live · refreshes every second.'}${tail.offset > 0 ? ' Showing the last 32 KiB; use simq logs ' + id + ' for earlier output.' : ''}`,
          );
        } catch (error) {
          if (stopped) return;
          if (error instanceof APIError && error.status === 409) {
            setMessage(error.message);
            setFinished(true);
          } else setMessage('Log connection lost · displayed output is stale · retrying…');
        } finally {
          inFlight.current = false;
        }
      }
      if (!stopped) timer = setTimeout(poll, 1000);
    }
    void poll();
    return () => {
      stopped = true;
      ++generation.current;
      controller.abort();
      clearTimeout(timer);
    };
  }, [id, paused, finished, online]);
  useEffect(() => {
    if (!paused && output.current) output.current.scrollTop = output.current.scrollHeight;
  }, [data, paused]);
  const resume = () => {
    setPaused(false);
    if (output.current) output.current.scrollTop = output.current.scrollHeight;
  };
  return (
    <section class="log-panel">
      <Heading title="Live output" aside="last 32 KiB" />
      <div class="log-toolbar">
        <button disabled={finished} onClick={() => setPaused(!paused)}>
          {paused ? 'Resume live output' : 'Pause live output'}
        </button>
        <button disabled={finished} onClick={resume}>
          Jump to latest
        </button>
      </div>
      <p class="muted" role="status">
        {!online
          ? 'Disconnected · displayed output is stale.'
          : paused
            ? 'Paused · resume to jump to the latest output.'
            : message}
      </p>
      <pre
        ref={output}
        class="live-log"
        tabIndex={0}
        aria-label="Job output"
        onScroll={() => {
          const n = output.current;
          if (n && !finished && n.scrollHeight - n.clientHeight - n.scrollTop > 24) setPaused(true);
        }}
      >
        {data}
      </pre>
      <p class="muted">Scroll up to pause. Resume to follow new output.</p>
    </section>
  );
}
function JobDetail({
  id,
  snapshot,
  online,
  pending,
  act,
  actionStatus,
  close,
}: {
  id: string;
  snapshot?: Snapshot;
  online: boolean;
  pending: boolean;
  act: Action;
  actionStatus: string;
  close: () => void;
}) {
  const [detail, setDetail] = useState<Job>(),
    [error, setError] = useState('');
  const generation = useRef(0);
  useEffect(() => {
    const controller = new AbortController(),
      g = ++generation.current;
    if (online)
      void request<Job>(`job/${encodeURIComponent(id)}`, { signal: controller.signal })
        .then((j) => {
          if (g === generation.current) {
            setDetail(j);
            setError('');
          }
        })
        .catch(() => {
          if (!controller.signal.aborted)
            setError('Job details unavailable. Retrying on the next snapshot.');
        });
    return () => {
      ++generation.current;
      controller.abort();
    };
  }, [id, snapshot?.generatedAt, online]);
  const job = detail || snapshot?.active.concat(snapshot.recent).find((j) => j.id === id);
  const now = epoch(snapshot?.generatedAt) ?? Date.now();
  const fields: Record<string, unknown> = job
    ? {
        Job: job.id,
        Label: label(job),
        State: stateLabel(job),
        Result: human(job.result_class),
        'Command exit': job.command_exit_code,
        Project: job.project,
        Submitter: job.submitter,
        Priority: job.priority,
        'Dispatch position': job.position,
        'Effective score': job.effective_score,
        Attempt: job.attempt,
        'Wait / prep / run': timings(job, now).map(duration).join(' / '),
        Queued: stamp(job.queue_time),
        Admitted: stamp(job.admitted_at),
        Started: stamp(job.started_at),
        Finished: stamp(job.finished_at),
        Commit: job.git_sha,
        Worktree: job.worktree,
        Directory: job.cwd,
        'Run directory': job.run_dir,
        'Peak memory': finite(job.peak_memory_mib)
          ? `${job.peak_memory_mib} MiB (process group only)`
          : undefined,
        'Run deadline': stamp(job.run_deadline_at),
        'Queue deadline': stamp(job.queue_deadline_at),
        Exclusive: job.exclusive,
        Retryable: job.retryable,
        'Cleanup pending': job.cleanup_pending,
        'Cleanup blocked': job.cleanup_blocked,
        Message: job.message,
        Waiting: job.wait_reasons?.map((r) => r.summary).join('; '),
        Simulators: job.sims?.map((s) => `${s.name} (${s.udid})`).join(', '),
      }
    : {};
  return (
    <Modal title="Job details" close={close} wide>
      <p class="action-status" role="status">
        {actionStatus}
      </p>
      <p class="danger" role="status">
        {error}
      </p>
      {job ? (
        <>
          <JobControls job={job} disabled={!online} pending={pending} act={act} />
          <details class="job-metadata" open>
            <summary>{label(job)}</summary>
            <dl>
              {Object.entries(fields)
                .filter(([, v]) => v !== undefined && v !== null && v !== '')
                .map(([k, v]) => (
                  <FragmentPair key={k} name={k} value={String(v)} />
                ))}
            </dl>
            <h3>Command · exact argv</h3>
            <pre>{JSON.stringify(job.command || [], null, 2)}</pre>
            {job.artifacts?.length ? (
              <>
                <h3>Artifacts</h3>
                <ul class="artifacts">
                  {job.artifacts.map((a) => (
                    <li key={a.path}>
                      {a.path} · {bytes(a.bytes)}
                    </li>
                  ))}
                </ul>
              </>
            ) : null}
            {job.artifacts_truncated && <p class="muted">Artifact listing is truncated.</p>}
          </details>
        </>
      ) : (
        <p>Loading job details…</p>
      )}
      <LiveLog key={id} id={id} online={online} />
    </Modal>
  );
}
function FragmentPair({ name, value }: { name: string; value: string }) {
  return (
    <>
      <dt>{name}</dt>
      <dd>{value}</dd>
    </>
  );
}
function StorageDetail({
  snapshot,
  online,
  refresh,
  close,
}: {
  snapshot?: Snapshot;
  online: boolean;
  refresh: () => void;
  close: () => void;
}) {
  const [pending, setPending] = useState(false),
    [message, setMessage] = useState('');
  const report = snapshot?.status.artifactStorage,
    s = snapshot?.status;
  const busy = pending || s?.storageReviewRunning === true;
  async function review() {
    if (busy || !online) return;
    setPending(true);
    setMessage('Requesting a background storage review…');
    try {
      await request('storage/review', { method: 'POST' });
      setMessage('Review accepted. Results appear when the background pass completes.');
      refresh();
    } catch (e) {
      setMessage(
        `No confirmed result. ${e instanceof Error ? e.message : 'Refresh before retrying.'}`,
      );
    } finally {
      setPending(false);
    }
  }
  return (
    <Modal title="Review storage" close={close} wide>
      <p class="muted">
        Read-only review of SimQueue-managed storage. Inventory runs on demand, outside the
        scheduler’s critical path.
      </p>
      <dl>
        <FragmentPair
          name="Admission volume free"
          value={bytes(s?.storage?.system_free_bytes ?? s?.host?.freeDiskBytes)}
        />
        <FragmentPair name="Admission floor" value={bytes(s?.storage?.minimum_free_bytes)} />
        <FragmentPair name="Output volume free" value={bytes(s?.storage?.free_bytes)} />
        <FragmentPair
          name="Output directory"
          value={s?.storage?.job_output_root || 'Unavailable'}
        />
      </dl>
      <button disabled={!online || busy || s?.storageReviewRunning === undefined} onClick={review}>
        {busy ? 'Reviewing storage…' : 'Refresh storage review'}
      </button>
      <p role="status">{message}</p>
      {s?.storageReviewRunning === undefined && (
        <p class="muted">Storage review requires an updated daemon.</p>
      )}
      {report && (
        <>
          <h3>
            {bytes(report.reclaimableBytes)} eligible · {report.candidateCount} targets
          </h3>
          <p class="muted">
            Reviewed {stamp(report.sampledAt)}. Sizes are estimates; shared blocks and unknown sizes
            affect actual space recovered.
          </p>
          <ul class="storage-candidates">
            {report.candidates.map((c, i) => (
              <li key={c.path + i}>
                <code>{c.path}</code>
                <span>
                  {bytes(c.bytes)} · {c.reason}
                </span>
              </li>
            ))}
          </ul>
          {report.candidates.length < report.candidateCount && (
            <p class="muted">
              Showing {report.candidates.length} of {report.candidateCount} candidates.
            </p>
          )}
          <h3>Protected and retained</h3>
          {report.protected ? (
            <ul class="storage-categories">
              {report.protected.map((item) => (
                <li key={item.name}>
                  <span>
                    {item.name} · {item.count} runs
                  </span>
                  <span>
                    {bytes(item.bytes)}
                    {item.unknownSizes ? ` + ${item.unknownSizes} unknown sizes` : ''}
                  </span>
                </li>
              ))}
            </ul>
          ) : (
            <p class="muted">Per-reason protection accounting requires an updated daemon.</p>
          )}
          <p class="muted">
            Pinned data is exempt from budget cleanup and the shorter DerivedData lifetime. Active
            work and pending process cleanup are protected. Other data stays until its retention
            policy allows removal.
          </p>
          <h3>Cleanup outcome</h3>
          <CleanupOutcome snapshot={snapshot} />
          <h3>Retention policy</h3>
          <dl>
            {Object.entries({
              'Passed jobs': agePolicy(report.retention.succeededSeconds),
              'Other results': agePolicy(report.retention.otherSeconds),
              'Unknown outputs': agePolicy(report.retention.unknownSeconds),
              'Kept base retention': agePolicy(report.retention.keptSeconds ?? 90 * 86400),
              DerivedData: agePolicy(report.retention.derivedDataSeconds),
              Budget: bytes(report.retention.budgetBytes),
              'Cleanup mode': human(report.cleanupMode),
              'Last pass': `${report.removedCount} removed · ${report.failureCount} failures`,
            }).map(([k, v]) => (
              <FragmentPair key={k} name={k} value={v} />
            ))}
          </dl>
          {report.notes?.map((n) => (
            <p class="muted" key={n}>
              {n}
            </p>
          ))}
          {report.error && <p class="danger">{report.error}</p>}
        </>
      )}
      <p class="muted">
        Active runs are protected. Kept runs are exempt from budget cleanup and retain at least
        their normal result retention. Simulator and template sizes are visibility only; they are
        not artifact cleanup targets.
      </p>
      <h3>Clean from the command line</h3>
      <p>
        Review current candidates with <code>simq gc</code>. After reviewing,{' '}
        <code>simq gc --apply</code> applies the runner’s retention policy. No files are deleted
        from this page.
      </p>
    </Modal>
  );
}
function App() {
  const { snapshot, connection, samples, refresh } = useDashboard();
  const [selected, setSelected] = useState<string | null>(null),
    [storage, setStorage] = useState(false),
    [filters, setFilters] = useState(false);
  const [query, setQuery] = useState(''),
    [project, setProject] = useState(''),
    [state, setState] = useState('');
  const [pending, setPending] = useState<Set<string>>(() => new Set()),
    [actionStatus, setActionStatus] = useState('');
  const inFlightActions = useRef(new Set<string>());
  const [confirmation, setConfirmation] = useState<{
      job: Job;
      kind: 'cancel' | 'priority';
    } | null>(null),
    [priority, setPriority] = useState('');
  const online = connection === 'live';
  const all = snapshot?.active.concat(snapshot.recent) || [];
  const projects = [...new Set(all.map((j) => j.project).concat(project ? [project] : []))].sort();
  const active = (snapshot?.active || []).filter((j) => matches(j, query, project, state));
  const running = active
    .filter((j) => j.state !== 'queued')
    .sort(
      (a, b) =>
        (epoch(a.admitted_at) ?? epoch(a.started_at) ?? 0) -
        (epoch(b.admitted_at) ?? epoch(b.started_at) ?? 0),
    );
  const queued = active
    .filter((j) => j.state === 'queued')
    .sort(
      (a, b) =>
        (a.position ?? Infinity) - (b.position ?? Infinity) ||
        (epoch(a.queue_time) ?? 0) - (epoch(b.queue_time) ?? 0),
    );
  const recent = (snapshot?.recent || [])
    .filter((j) => matches(j, query, project, state))
    .sort((a, b) => (epoch(b.finished_at) ?? 0) - (epoch(a.finished_at) ?? 0));
  const now = epoch(snapshot?.generatedAt) ?? Date.now();
  const [queueLimit, setQueueLimit] = useState(30);
  async function mutate(j: Job, kind: 'cancel' | 'priority', value?: number) {
    if (!online || inFlightActions.current.has(j.id)) return;
    if (
      kind === 'priority' &&
      (!finite(value) || !Number.isInteger(value) || value < 0 || value > 100)
    ) {
      setActionStatus('Priority must be a whole number from 0 to 100.');
      return;
    }
    inFlightActions.current.add(j.id);
    setPending((prev) => new Set(prev).add(j.id));
    setActionStatus(`Updating ${j.id}…`);
    try {
      await request(
        kind === 'cancel'
          ? `cancel/${encodeURIComponent(j.id)}`
          : `priority/${encodeURIComponent(j.id)}/${value}`,
        { method: 'POST' },
      );
      setActionStatus(
        kind === 'cancel'
          ? `${j.id}: cancellation accepted; cleanup may still be pending.`
          : `${j.id}: priority set to ${value}. Queue order updates on the next scheduling pass.`,
      );
      refresh();
    } catch (error) {
      setActionStatus(
        `${j.id}: ${error instanceof APIError ? error.message : 'No confirmed response. Refresh the job state before retrying.'}`,
      );
    } finally {
      inFlightActions.current.delete(j.id);
      setPending((prev) => {
        const next = new Set(prev);
        next.delete(j.id);
        return next;
      });
    }
  }
  const act: Action = (j, kind, value) => {
    if (kind === 'cancel' || value === undefined) {
      setConfirmation({ job: j, kind });
      setPriority(String(j.priority));
    } else void mutate(j, kind, value);
  };
  const openJob = (id: string) => {
    setStorage(false);
    setSelected(id);
  };
  return (
    <>
      <header class="app-header">
        <a class="brand" href="./" aria-label="SimQueue dashboard">
          <span class="brand-mark">SQ</span>
          <span>SimQueue</span>
        </a>
        <span class="runner-label">
          {snapshot?.status.daemon.probe === 'fake' ? 'FAKE RUNNER' : 'RUNNER'}
        </span>
        <span class={`connection ${connection}`} role="status">
          <Dot kind={online ? 'success' : connection === 'offline' ? 'danger' : 'muted'} />
          {online ? 'Live' : connection === 'offline' ? 'Disconnected' : 'Connecting'}
        </span>
      </header>
      <main>
        <StatusSummary
          snapshot={snapshot}
          connection={connection}
          openJob={openJob}
          openStorage={() => setStorage(true)}
          refresh={refresh}
        />
        <Vitals snapshot={snapshot} samples={samples} stale={!online} />
        <div class="dashboard-toolbar">
          <span class="muted">
            {snapshot ? `Updated ${clockStamp(snapshot.generatedAt)}` : 'Waiting for runner'}
            {!online && snapshot ? ' · stale snapshot' : ''}
          </span>
          <button class="text-button" aria-expanded={filters} onClick={() => setFilters(!filters)}>
            {filters ? 'Hide filters' : 'Search and filter'}
          </button>
        </div>
        {filters && (
          <section class="filters card" aria-label="Filter jobs">
            <input
              autoFocus
              type="search"
              value={query}
              placeholder="Search jobs, commands, submitters or IDs"
              aria-label="Search jobs"
              onInput={(e) => setQuery(e.currentTarget.value)}
            />
            <select
              aria-label="Filter project"
              value={project}
              onChange={(e) => setProject(e.currentTarget.value)}
            >
              <option value="">All projects</option>
              {projects.map((p) => (
                <option key={p}>{p}</option>
              ))}
            </select>
            <select
              aria-label="Filter state"
              value={state}
              onChange={(e) => setState(e.currentTarget.value)}
            >
              <option value="">All states</option>
              {[
                'queued',
                'admitted',
                'running',
                'succeeded',
                'failed',
                'canceled',
                'interrupted',
                'infra_failed',
                'timed_out',
                'expired',
              ].map((s) => (
                <option key={s} value={s}>
                  {human(s)}
                </option>
              ))}
            </select>
            <button
              onClick={() => {
                setQuery('');
                setProject('');
                setState('');
              }}
            >
              Clear
            </button>
          </section>
        )}
        {(query || project || state) && (
          <p class="muted">
            Job lists are filtered. Runner status and vitals describe the whole machine.
          </p>
        )}
        <p class="action-status" role="status">
          {actionStatus}
        </p>
        <div class="dashboard-columns">
          <div class="jobs-column">
            <section aria-labelledby="running-title">
              <Heading id="running-title" title="Now running" count={running.length} />
              <div class="job-stack">
                {running.length ? (
                  running.map((j) => (
                    <JobCard
                      key={j.id}
                      job={j}
                      now={now}
                      open={openJob}
                      disabled={!online}
                      pending={pending.has(j.id)}
                      act={act}
                    />
                  ))
                ) : (
                  <Empty>{snapshot ? 'Nothing running' : 'Waiting for the runner snapshot'}</Empty>
                )}
              </div>
            </section>
            <section aria-labelledby="queue-title">
              <Heading
                id="queue-title"
                title="Up next"
                count={queued.length}
                aside="higher priority runs first"
              />
              <div class="job-stack queue-stack">
                {queued.length ? (
                  queued
                    .slice(0, queueLimit)
                    .map((j) => (
                      <JobCard
                        key={j.id}
                        job={j}
                        now={now}
                        open={openJob}
                        disabled={!online}
                        pending={pending.has(j.id)}
                        act={act}
                      />
                    ))
                ) : (
                  <Empty>{snapshot ? 'Queue is empty' : 'No queue snapshot yet'}</Empty>
                )}
              </div>
              {queued.length > queueLimit && (
                <button
                  class="text-button show-more"
                  onClick={() => setQueueLimit(queueLimit + 30)}
                >
                  Show next {Math.min(30, queued.length - queueLimit)} waiting jobs
                </button>
              )}
            </section>
            <Recent jobs={recent} now={now} open={openJob} showFilters={() => setFilters(true)} />
          </div>
          <aside>
            <Timeline jobs={[...active, ...recent]} now={now} open={openJob} />
            <Storage snapshot={snapshot} online={online} open={() => setStorage(true)} />
            <Runner snapshot={snapshot} />
          </aside>
        </div>
        <footer>
          Machine readings are the latest sample. Trend lines are kept by this tab only. Commands
          and logs may contain sensitive information.
          <br />
          Wait includes time since submission; preparation, execution, memory and simulator details
          describe the latest attempt. History is limited to the last 100 retained submissions;
          recent rows are ordered by completion within that window.
        </footer>
      </main>
      {selected && (
        <JobDetail
          key={selected}
          id={selected}
          snapshot={snapshot}
          online={online}
          pending={pending.has(selected)}
          actionStatus={actionStatus}
          act={act}
          close={() => setSelected(null)}
        />
      )}
      {storage && (
        <StorageDetail
          snapshot={snapshot}
          online={online}
          refresh={refresh}
          close={() => setStorage(false)}
        />
      )}
      {confirmation && (
        <Modal
          title={confirmation.kind === 'cancel' ? 'Cancel job' : 'Change priority'}
          close={() => setConfirmation(null)}
        >
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void mutate(
                confirmation.job,
                confirmation.kind,
                confirmation.kind === 'priority' ? Number(priority) : undefined,
              );
              setConfirmation(null);
            }}
          >
            <p>
              {confirmation.kind === 'cancel'
                ? `Cancel ${confirmation.job.id} (${label(confirmation.job)})? Running commands will be stopped and resources cleaned up.`
                : `Set the base priority for ${confirmation.job.id}. Higher runs first; admission holds still apply.`}
            </p>
            {confirmation.kind === 'priority' && (
              <label>
                Priority (0–100)
                <input
                  autoFocus
                  type="number"
                  min="0"
                  max="100"
                  step="1"
                  required
                  value={priority}
                  onInput={(e) => setPriority(e.currentTarget.value)}
                />
              </label>
            )}
            <div class="confirm-actions">
              <button type="button" onClick={() => setConfirmation(null)}>
                Back
              </button>
              <button disabled={!online} class={confirmation.kind === 'cancel' ? 'cancel' : ''}>
                {confirmation.kind === 'cancel' ? 'Cancel job' : 'Set priority'}
              </button>
            </div>
          </form>
        </Modal>
      )}
    </>
  );
}
class Boundary extends Component<{ children: ComponentChildren }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  render() {
    return this.state.failed ? (
      <main>
        <h1>Dashboard could not render</h1>
        <p>The runner may still be working. Reload to reconnect.</p>
        <button onClick={() => location.reload()}>Reload dashboard</button>
      </main>
    ) : (
      this.props.children
    );
  }
}
if ('serviceWorker' in navigator && globalThis.isSecureContext)
  void navigator.serviceWorker
    .register('sw.js', { scope: './', updateViaCache: 'none' })
    .catch(() => {});
render(
  <Boundary>
    <App />
  </Boundary>,
  document.getElementById('app')!,
);

// SPDX-License-Identifier: MIT

// Embedded so a copied simq executable needs no resource bundle or web runtime.
enum DashboardAssets {
    static let files: [String: (type: String, text: String)] = [
        "": (
            "text/html",
            #"""
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#101516"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="SimQueue"><link rel="manifest" href="manifest.webmanifest"><link rel="apple-touch-icon" href="icon-180.png"><title>SimQueue · Queue dashboard</title><link rel="stylesheet" href="style.css"><script defer src="app.js"></script></head>
            <body>
            <header><div class="brand">SQ <span>SimQueue</span></div><span class="badge">QUEUE</span></header>
            <main><div class="heading"><div><h1>Queue status</h1></div><p id="connection" role="status">Connecting…</p></div>
            <section aria-labelledby="machine-title"><h2 id="machine-title">Machine health</h2><div id="machine" class="overview"></div><p id="admission-health" class="notice" role="status"></p><details><summary>Resource details</summary><dl id="resource-details"></dl></details></section>
            <section id="overview" class="overview" aria-label="Host overview"></section>
            <p id="health" class="notice"></p>
            <p id="action-status" role="status"></p>
            <div class="filters"><input id="search" type="search" placeholder="Search project, command, submitter or ID" aria-label="Search jobs"><select id="project" aria-label="Filter project"><option value="">All projects</option></select><select id="state" aria-label="Filter state"><option value="">All states</option></select></div>
            <section aria-labelledby="storage-title"><h2 id="storage-title">Managed storage</h2><p class="muted">Review SimQueue job artifacts and the configured retention policy. No global Xcode caches or unmanaged simulators are removed.</p><div class="log-toolbar"><button id="review-storage">Review storage</button><button id="cleanup-storage" disabled>Clean eligible artifacts…</button></div><p id="storage-action-status" role="status"></p><div id="storage-summary"></div><details><summary>Cleanup preview</summary><div id="storage-candidates"></div></details></section>
            <section><h2>In flight <span id="active-count"></span></h2><p class="muted">Waiting jobs show dispatch position. Priority is higher-first; aging can affect order.</p><div id="active"></div></section>
            <section><h2>Recent activity</h2><p class="muted">Execution overlap across the displayed jobs · latest attempt</p><div id="timeline" aria-label="Execution timeline"></div></section>
            <section><h2>Recently finished <span id="recent-count"></span></h2><p class="muted">Up to 100 retained jobs, newest submitted first. Filters apply to this window.</p><div id="recent"></div></section>
            <footer>Refreshes every 3 seconds while visible. Timings and memory describe the latest attempt. Commands and logs may contain sensitive information.</footer>
            </main>
            <dialog id="detail"><div class="dialog-heading"><h2>Job details</h2><button id="close">Close</button></div><p id="detail-action-status" role="status"></p><div id="detail-body"></div></dialog>
            <dialog id="action-dialog"><form method="dialog"><h2 id="action-title"></h2><p id="action-question"></p><label id="priority-label">Priority (0–100)<input id="new-priority" type="number" min="0" max="100" step="1"></label><div class="dialog-heading"><button value="cancel" formnovalidate>Back</button><button id="confirm-action" value="confirm">Confirm</button></div></form></dialog>
            </body></html>
            """#
        ),
        "app.js": (
            "text/javascript",
            #"""
            'use strict';
            if (typeof navigator !== 'undefined' && 'serviceWorker' in navigator && globalThis.isSecureContext) {
              navigator.serviceWorker.register('sw.js', {scope:'./', updateViaCache:'none'}).catch(() => {});
            }
            const $ = id => document.getElementById(id);
            const el = (tag, text, className) => { const n = document.createElement(tag); if (text != null) n.textContent = text; if (className) n.className = className; return n; };
            let snapshot, selected = null, detailGeneration = 0, logView = null;
            const pendingActions = new Set();
            const states = ['queued','admitted','running','succeeded','failed','canceled','interrupted','infra_failed','timed_out','expired'];
            for (const state of states) { const o = el('option', state.replaceAll('_',' ')); o.value = state; $('state').append(o); }
            const epoch = value => value == null ? null : (typeof value === 'number' ? value * 1000 : Date.parse(value));
            const duration = ms => { if (ms == null || !Number.isFinite(ms)) return '—'; const s = Math.max(0, Math.floor(ms/1000)); return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s/60)}m ${s%60}s` : `${Math.floor(s/3600)}h ${Math.floor(s%3600/60)}m`; };
            const now = () => epoch(snapshot?.generatedAt) || Date.now();
            // "Oct 22, 12:43 PM" in the viewer's time zone (or the one given); a dash when unset.
            const stamp = (value, timeZone) => { const ms=epoch(value); if (ms == null || !Number.isFinite(ms)) return '—'; const p=Object.fromEntries(new Intl.DateTimeFormat('en-US',{month:'short',day:'numeric',hour:'numeric',minute:'2-digit',hour12:true,timeZone}).formatToParts(new Date(ms)).map(x=>[x.type,x.value])); return `${p.month} ${p.day}, ${p.hour}:${p.minute} ${p.dayPeriod}`; };
            const label = j => j.kind ? `${j.project} · ${j.kind}` : `${j.project} · ${j.command?.[0]?.split('/').pop() || j.id.slice(0,8)}`;
            function timings(j) {
              const q=epoch(j.queue_time), a=epoch(j.admitted_at), s=epoch(j.started_at), f=epoch(j.finished_at), end=f ?? now();
              // Admission is the start of preparation, execution begins at started_at.
              // Older daemon versions may omit admission; don't invent a prep duration.
              return [duration((a ?? s ?? end)-q), a == null ? '—' : duration((s ?? end)-a), s == null ? '—' : duration(end-s)];
            }
            async function get(path) {
              const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 12000);
              try { const r = await fetch(`api/${path}`, {cache:'no-store', signal:controller.signal}); if (!r.ok) { const error=new Error(r.status===409 ? await r.text() : 'Unavailable'); error.status=r.status; throw error; } return await r.json(); }
              finally { clearTimeout(timeout); }
            }
            function matches(j) {
              const query=$('search').value.toLowerCase();
              return (!$('project').value || j.project === $('project').value) && (!$('state').value || j.state === $('state').value) &&
                [j.project,j.kind,j.id,j.submitter,...(j.command || [])].join(' ').toLowerCase().includes(query);
            }
            function askAction(j, action) {
              const dialog=$('action-dialog');
              if (dialog.open) return Promise.resolve(null);
              const priority=action==='priority';
              $('action-title').textContent=priority ? 'Change priority' : 'Cancel job';
              $('action-question').textContent=priority ? `Set the base priority for ${j.id} (${label(j)}). Higher runs first.` : `Cancel ${j.id} (${label(j)})? Running commands will be stopped and their resources cleaned up.`;
              $('priority-label').hidden=!priority; $('new-priority').required=priority; $('new-priority').value=String(j.priority);
              $('confirm-action').textContent=priority ? 'Set priority' : 'Cancel job';
              dialog.returnValue=''; dialog.showModal();
              return new Promise(resolve=>dialog.addEventListener('close',()=>resolve(dialog.returnValue==='confirm' ? (priority ? Number($('new-priority').value) : true) : null),{once:true}));
            }
            function setActionStatus(text) { $('action-status').textContent=text; $('detail-action-status').textContent=text; }
            async function changeJob(j, action, priority) {
              if (pendingActions.has(j.id)) return;
              if (action === 'cancel' && !(await askAction(j,'cancel'))) return;
              if (action === 'priority' && (!Number.isInteger(priority) || priority < 0 || priority > 100)) {
                setActionStatus('Priority must be a whole number from 0 to 100.'); return;
              }
              pendingActions.add(j.id); render();
              setActionStatus(`Updating ${j.id}…`);
              try {
                const path=action === 'cancel' ? `cancel/${j.id}` : `priority/${j.id}/${priority}`;
                const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 12000);
                let response;
                try { response=await fetch(`api/${path}`,{method:'POST',headers:{'X-SimQueue-Action':'1'},signal:controller.signal}); }
                catch { throw new Error('No confirmed response. Refresh the job state before retrying.'); }
                finally { clearTimeout(timeout); }
                if (!response.ok) throw new Error(await response.text());
                const updated=await response.json();
                setActionStatus(action === 'cancel' ? `${j.id}: cancellation accepted; cleanup may still be pending.` : `${j.id}: priority set to ${updated.priority}. Queue order updates on the next scheduling pass.`);
                try { snapshot=await get('snapshot'); } catch { $('connection').textContent='Action accepted; snapshot refresh failed. Retrying…'; $('connection').className='error'; }
              } catch (error) { setActionStatus(`${j.id}: ${error.message}`); }
              finally { pendingActions.delete(j.id); render(); }
            }
            function controls(j) {
              const cell=el('td');
              if (!['queued','admitted','running'].includes(j.state)) return cell;
              function button(text, title, handler) {
                const b=el('button',text); b.title=title; b.setAttribute('aria-label',title); b.disabled=pendingActions.has(j.id); b.addEventListener('click',handler); cell.append(b); return b;
              }
              if (j.state === 'queued') {
                button('↑',`Raise priority for ${j.id} by 10`,()=>changeJob(j,'priority',Math.min(100,j.priority+10))).disabled ||= j.priority >= 100;
                button('↓',`Lower priority for ${j.id} by 10`,()=>changeJob(j,'priority',Math.max(0,j.priority-10))).disabled ||= j.priority <= 0;
                button('Priority…',`Set priority for ${j.id}`,async()=>{const value=await askAction(j,'priority'); if (value !== null) changeJob(j,'priority',value);});
              }
              button('Cancel',`Cancel ${j.id}`,()=>changeJob(j,'cancel'));
              return cell;
            }
            let clock = () => Date.now();
            // Rebuilding rows under a finger or during momentum makes iOS drop the scroll; wait until it settles.
            const scrollBusy = wrap => wrap.touching || clock() - (wrap.scrolledAt || 0) < 1000;
            function scroller() {
              const wrap = el('div', null, 'table-wrap'), release = () => { wrap.touching = false; wrap.scrolledAt = clock(); };
              wrap.addEventListener('touchstart', () => { wrap.touching = true; }, {passive:true});
              wrap.addEventListener('touchend', release, {passive:true}); wrap.addEventListener('touchcancel', release, {passive:true});
              wrap.addEventListener('scroll', () => { wrap.scrolledAt = clock(); }, {passive:true});
              wrap.addEventListener('click', () => { wrap.scrolledAt = 0; });
              return wrap;
            }
            function table(jobs, target) {
              const root=$(target);
              if (!jobs.length) { root.replaceChildren(el('div', 'No jobs in this view.', 'empty')); return; }
              // Keep the scrolling element attached across polling refreshes.
              const existing=root.firstElementChild, kept=existing?.className==='table-wrap';
              if (kept && scrollBusy(existing)) return; // the next poll redraws once the gesture ends
              const wrap=kept ? existing : scroller();
              const left=wrap.scrollLeft, top=wrap.scrollTop, t=el('table'), head=el('tr');
              for (const name of ['Job / command','State','Priority','Queued','Started','Wait','Prep','Run','Sims','Outcome / hold','Actions']) head.append(el('th',name));
              const thead=el('thead'); thead.append(head); t.append(thead); const body=el('tbody');
              for (const j of jobs) {
                const row=el('tr'), name=el('td'), button=el('button',label(j),'job-button');
                button.addEventListener('click',()=>openDetail(j.id)); const summary=el('small',`${j.id} · ${(j.command || []).join(' ')}`); summary.title=(j.command || []).join(' '); name.append(button,summary); row.append(name);
                const state=el('td'); state.append(el('span',j.state.replaceAll('_',' '),'pill '+j.state)); row.append(state);
                row.append(el('td',`P${j.priority}${j.position ? ' · #'+j.position : ''}`));
                for (const at of [j.queue_time,j.started_at]) { const cell=el('td',stamp(at)); if (at) cell.title=String(at); row.append(cell); }
                for (const time of timings(j)) row.append(el('td',time));
                row.append(el('td',j.granted_sims),el('td',j.wait_reasons?.map(r=>r.summary).join('; ') || j.result_class || j.message || '—'),controls(j)); body.append(row);
              }
              t.append(body); wrap.replaceChildren(t);
              if (wrap!==existing) root.replaceChildren(wrap);
              // Restore only what layout clamped: writing scroll offsets cancels iOS momentum.
              if (wrap.scrollLeft!==left) wrap.scrollLeft=left; if (wrap.scrollTop!==top) wrap.scrollTop=top;
            }
            const bytes = value => value == null || !Number.isFinite(value) ? 'Unavailable' : value >= 1073741824 ? `${(value/1073741824).toFixed(1)} GiB` : `${(value/1048576).toFixed(1)} MiB`;
            const percent = value => value == null || !Number.isFinite(value) ? 'Unavailable' : `${value.toFixed(0)}%`;
            const days = value => value == null ? 'Not configured' : value < 86400 ? `${(value/3600).toFixed(1)} hours` : `${(value/86400).toFixed(1)} days`;
            let storagePending=false, lastStorageRender=null;
            function renderMachine() {
              const s=snapshot.status, h=s.host, storage=s.storage;
              const metric=(title,value,detail)=>{const n=el('div',null,'metric');n.append(el('span',title),el('strong',value),el('small',detail));return n;};
              $('machine').replaceChildren(
                metric('Available memory',bytes(h?.availableMemoryBytes),h ? `of ${bytes(h.totalMemoryBytes)} · pressure ${h.memoryPressure}` : 'Requires an updated daemon'),
                metric('CPU utilization',percent(h?.cpuUsagePercent),h ? `Load ${h.load1.toFixed(1)} / ${h.load5.toFixed(1)} · ${h.cpuCount} cores` : 'No resource sample'),
                metric('System volume',bytes(storage?.system_free_bytes),'Free space'),
                metric('Job output volume',bytes(storage?.free_bytes),storage?.available===false ? 'Unavailable · check mount or permissions' : 'Free space'));
              const reasons=(s.global_wait_reasons || []).map(r=>r.summary);
              const admission=s.draining ? 'Draining · new jobs wait' : s.paused ? 'Paused · new jobs wait' : reasons.length ? 'Jobs waiting: '+reasons.join(' · ') : 'Queue admission: Open';
              const stale=h && now()-h.sampledAt*1000>15000;
              $('admission-health').textContent=admission+(stale ? ' · Resource sample is stale' : '');
              $('admission-health').className=reasons.length || s.draining || s.paused ? 'notice error' : 'notice';
              const details=[['Sample time',h ? new Date(h.sampledAt*1000).toLocaleString() : 'Unavailable'],['Total RAM',bytes(h?.totalMemoryBytes)],['Swap used',bytes(h?.swapUsedBytes)],['Thermal state',h?.thermalState || 'Unavailable'],['State volume free',bytes(h?.freeDiskBytes)],['Minimum free space',bytes(storage?.minimum_free_bytes)],['Output directory',storage?.job_output_root || 'Unavailable']];
              $('resource-details').replaceChildren(...details.flatMap(([key,value])=>[el('dt',key),el('dd',value)]));
            }
            function renderStorage() {
              const s=snapshot.status, report=s.artifactStorage, busy=storagePending || s.storageReviewRunning===true;
              $('review-storage').disabled=busy || s.storageReviewRunning==null;
              $('cleanup-storage').disabled=busy || !report || report.cleanupMode!=='enforce' || report.candidateCount===0 || report.retention.maxRemovalsPerPass<=0 || report.removedCount>0 || Boolean(report.error);
              const renderKey=JSON.stringify([report,busy,s.storageReviewRunning==null]);
              if(renderKey===lastStorageRender) return;
              lastStorageRender=renderKey;
              if (!report) { $('storage-summary').replaceChildren(el('p',busy ? 'Reviewing storage in the background…' : 'Choose Review storage to measure managed artifacts. Sizes are not scanned on each refresh.','muted')); return; }
              const summary=el('div'), table=el('table'), header=el('tr');
              for(const title of ['Storage category','Estimated bytes','Directories']) header.append(el('th',title)); table.append(header);
              for(const category of report.categories) {const row=el('tr');row.append(el('td',category.name),el('td',bytes(category.bytes)+(category.unknownSizes ? ` + ${category.unknownSizes} unknown` : '')),el('td',category.count));table.append(row);}
              const r=report.retention, measured=report.categories.reduce((sum,c)=>sum+c.bytes,0);
              summary.append(el('p',`${bytes(measured)} measured managed artifacts (unknown sizes excluded).`),el('p',`Inventory ${new Date(report.sampledAt*1000).toLocaleString()} · ${report.candidateCount} eligible targets · ${bytes(report.reclaimableBytes)} estimated reclaimable${report.unknownCandidateSizes ? ' + unknown sizes' : ''}.`),table,
                el('p',`Retention: DerivedData ${days(r.derivedDataSeconds)} · successful runs ${days(r.succeededSeconds)} · other runs ${days(r.otherSeconds)} · pinned ${days(r.keptSeconds ?? 7776000)}. Budget: ${r.budgetBytes == null ? 'Not configured' : bytes(r.budgetBytes)}. Cleanup mode: ${report.cleanupMode}.`, 'muted'),
                el('p','Sizes are logical file bytes, not guaranteed reclaimed disk space (APFS clones and compression differ). Accounting samples at most 200 run directories; unknown sizes remain marked. Active jobs and pending cleanup are protected.','muted'));
              if(report.cleanupAt) summary.append(el('p',`Last cleanup pass ${new Date(report.cleanupAt*1000).toLocaleString()}: ${report.removedCount} removed, ${report.failureCount} failed. Inventory is from before cleanup; review again for updated sizes.`));
              if(report.error) summary.append(el('p',report.error,'error'));
              if(busy) summary.append(el('p','Storage work is running in the background…','muted'));
              $('storage-summary').replaceChildren(summary);
              const preview=el('div');
              for(const candidate of report.candidates) preview.append(el('p',`${candidate.path} · ${candidate.reason} · ${bytes(candidate.bytes)}`));
              if(report.candidateCount>report.candidates.length) preview.append(el('p',`Showing ${report.candidates.length} of ${report.candidateCount} eligible targets.`));
              $('storage-candidates').replaceChildren(preview);
            }
            async function storageAction(action) {
              if(!snapshot || storagePending) return;
              if(action==='cleanup' && !confirm('Remove currently eligible SimQueue artifacts? Eligibility is rechecked before each deletion. Active work stays protected; pinned artifacts follow their longer retention. At most 20 targets are removed per pass, subject to the configured limit. This cannot be undone.')) return;
              storagePending=true; renderStorage();
              const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),12000);
              try {
                const response=await fetch(`api/storage/${action}`,{method:'POST',headers:{'X-SimQueue-Action':'1'},signal:controller.signal});
                if(!response.ok) throw new Error(await response.text());
                $('storage-action-status').textContent='Storage work requested. Results appear automatically when the background pass completes.';
              } catch(error) { $('storage-action-status').textContent='No confirmed result. '+(error.message || 'Refresh before retrying.'); }
              finally {clearTimeout(timeout);storagePending=false;renderStorage();}
            }
            $('review-storage').addEventListener('click',()=>storageAction('review'));
            $('cleanup-storage').addEventListener('click',()=>storageAction('cleanup'));
            function render() {
              if (!snapshot) return;
              const s=snapshot.status;
              renderMachine(); renderStorage();
              $('overview').replaceChildren(...[[s.running,'Running'],[s.queued,'Queued'],[s.admitted,'Preparing'],[s.draining ? 'Draining' : s.paused ? 'Paused' : s.load_throttled ? 'Throttled' : 'Open','Admission']].map(([v,k])=>{const n=el('div',null,'metric'); n.append(el('strong',v),el('span',k)); return n;}));
              $('health').textContent=[`Health: ${s.health?.health || 'unreported'}`, ...(s.health?.reasons || []), ...(s.global_wait_reasons || []).map(r=>r.summary),s.template_hint].filter(Boolean).join(' · ');
              const active=snapshot.active.filter(matches).sort((a,b)=>(a.state==='queued')-(b.state==='queued') || (a.position ?? Infinity)-(b.position ?? Infinity) || epoch(a.queue_time)-epoch(b.queue_time));
              const recent=snapshot.recent.filter(matches);
              table(active,'active'); table(recent,'recent'); $('active-count').textContent=`${active.length}`; $('recent-count').textContent=`${recent.length}`;
              const root=$('timeline'); root.replaceChildren();
              const jobs=[...active,...recent].filter(j=>j.started_at).sort((a,b)=>epoch(b.started_at)-epoch(a.started_at)).slice(0,20);
              if (!jobs.length) { root.append(el('p','No execution history in this view.','muted')); return; }
              const start=Math.min(...jobs.map(j=>epoch(j.started_at))), end=Math.max(...jobs.map(j=>epoch(j.finished_at) ?? now())), span=Math.max(1000,end-start);
              for (const j of jobs) { const row=el('div',null,'timeline-row'), name=el('button',label(j),'job-button timeline-label'), track=el('div',null,'track'), bar=el('div',null,'bar');
                name.title=label(j); name.addEventListener('click',()=>openDetail(j.id)); bar.style.left=`${100*(epoch(j.started_at)-start)/span}%`; bar.style.width=`${100*((epoch(j.finished_at) ?? now())-epoch(j.started_at))/span}%`;
                track.title=`${j.started_at} → ${j.finished_at || 'running'} (${timings(j)[2]})`; track.append(bar); row.append(name,track); root.append(row); }
            }
            function stopTail() {
              if (logView) clearTimeout(logView.timer);
              logView=null;
            }
            function pauseTail(view) {
              if (view!==logView || view.finished) return;
              view.paused=true; clearTimeout(view.timer);
              view.pause.textContent='Resume live output'; view.status.textContent='Paused · resume to jump to the latest output.';
            }
            function resumeTail(view) {
              if (view!==logView || view.finished) return;
              view.paused=false; view.pause.textContent='Pause live output';
              view.output.scrollTop=view.output.scrollHeight; clearTimeout(view.timer);
              pollTail(view);
            }
            async function pollTail(view) {
              if (view!==logView || view.paused || view.finished || view.busy) return;
              view.busy=true;
              try {
                if (document.hidden) return;
                const data=await get(`logs/${encodeURIComponent(view.id)}/tail`);
                if (view!==logView || view.paused) return;
                const text=data.data || 'No output yet.';
                if (view.output.textContent!==text) view.output.textContent=text;
                view.output.scrollTop=view.output.scrollHeight;
                view.finished=Boolean(data.job_finished && data.at_end);
                let status=view.finished ? 'Complete · final output.' : 'Live · refreshes every second.';
                if (data.offset>0) status+=' Showing the last 32 KiB; earlier output is available with simq logs '+view.id+'.';
                if (view.status.textContent!==status) view.status.textContent=status;
                view.pause.disabled=view.finished; view.latest.disabled=view.finished;
              } catch (error) {
                if (view===logView && !view.paused) {
                  if (error.status===409) { view.finished=true; view.pause.disabled=true; view.latest.disabled=true; view.status.textContent=error.message; }
                  else view.status.textContent='Log connection lost · displayed output is stale · retrying…';
                }
              } finally {
                view.busy=false;
                if (view===logView && !view.paused && !view.finished) view.timer=setTimeout(()=>pollTail(view),1000);
              }
            }
            function createTail(id) {
              const panel=el('section'), heading=el('h3','Live output · last 32 KiB'), toolbar=el('div',null,'log-toolbar');
              const pause=el('button','Pause live output'), latest=el('button','Jump to latest'), status=el('p','Connecting…','muted');
              status.setAttribute('role','status');
              const output=el('pre','Loading output…','live-log'); output.tabIndex=0; output.setAttribute('aria-label','Job output');
              const view={id,panel,pause,latest,status,output,paused:false,finished:false,busy:false,timer:null};
              pause.addEventListener('click',()=>view.paused ? resumeTail(view) : pauseTail(view));
              latest.addEventListener('click',()=>resumeTail(view));
              output.addEventListener('scroll',()=>{
                if (output.scrollHeight-output.clientHeight-output.scrollTop>24) pauseTail(view);
              });
              toolbar.append(pause,latest); panel.append(heading,toolbar,status,output,el('p','Scroll up to pause. Resume or jump to latest to follow new output.','muted'));
              return view;
            }
            async function openDetail(id) {
              stopTail(); selected=id; const generation=++detailGeneration;
              logView=createTail(id); const metadata=el('div','Loading…'); metadata.id='job-metadata';
              $('detail-body').replaceChildren(metadata,logView.panel);
              if (!$('detail').open) $('detail').showModal();
              pollTail(logView);
              try { await updateDetail(id,generation); } catch { if (generation===detailGeneration) metadata.textContent='Job details unavailable. Close and reopen to retry.'; }
            }
            async function updateDetail(id,generation) {
              const j=await get(`job/${encodeURIComponent(id)}`);
              if (generation!==detailGeneration || selected!==id) return;
              const root=$('detail-body'), dl=el('dl'), times=timings(j);
              for (const [key,value] of Object.entries({'Job':j.id,'Label':label(j),'State':j.state,'Project':j.project,'Submitter':j.submitter,'Priority':j.priority,'Dispatch position':j.position,'Effective score':j.effective_score,'Attempt':j.attempt,'Wait / prep / run':times.join(' / '),'Queued':j.queue_time,'Admitted':j.admitted_at,'Started':j.started_at,'Finished':j.finished_at,'Result':j.result_class,'Command exit':j.command_exit_code,'Commit':j.git_sha,'Worktree':j.worktree,'Directory':j.cwd,'Run directory':j.run_dir,'Peak memory':j.peak_memory_mib == null ? null : `${j.peak_memory_mib} MiB`,'Run deadline':j.run_deadline_at,'Queue deadline':j.queue_deadline_at,'Exclusive':j.exclusive,'Retryable':j.retryable,'Cleanup pending':j.cleanup_pending,'Cleanup blocked':j.cleanup_blocked,'Message':j.message,'Waiting':j.wait_reasons?.map(r=>r.summary).join('; '),'Simulators':j.sims?.map(s=>`${s.name} (${s.udid})`).join(', '),'Artifacts':j.artifacts?.map(a=>`${a.path} (${a.bytes} bytes)`).join('\n')})) {
                if (value != null && value !== '') dl.append(el('dt',key),el('dd',String(value)));
              }
              const command=el('pre',JSON.stringify(j.command || [],null,2));
              const actions=el('table'), actionRow=el('tr'); actionRow.append(controls(j)); actions.append(actionRow);
              const metadata=$('job-metadata'); metadata.replaceChildren(actions,dl,el('h3','Command · exact argv'),command);
              if (j.artifacts_truncated) metadata.append(el('p','Artifact listing is truncated.','muted'));
            }
            $('close').addEventListener('click',()=>$('detail').close());
            $('detail').addEventListener('close',()=>{selected=null; ++detailGeneration; stopTail();});
            for (const id of ['search','project','state']) $(id).addEventListener('input',render);
            async function refresh() {
              if (!document.hidden) {
                try { snapshot=await get('snapshot');
                  const projects=[...new Set([...snapshot.active,...snapshot.recent].map(j=>j.project))].sort();
                  const current=$('project').value; $('project').replaceChildren();
                  for (const p of ['',...new Set([...projects,...(current ? [current] : [])])]) {const o=el('option',p || 'All projects');o.value=p;$('project').append(o);} $('project').value=current;
                  $('connection').textContent=`Updated ${new Date(epoch(snapshot.generatedAt)).toLocaleTimeString()}`; $('connection').className=''; render();
                  if (selected) await updateDetail(selected,detailGeneration);
                } catch { $('connection').textContent='Disconnected · displayed data is stale · retrying…'; $('connection').className='error'; }
              }
              setTimeout(refresh,3000);
            }
            refresh();
            """#
        ),
        "manifest.webmanifest": (
            "application/manifest+json",
            #"""
            {"id":"./","name":"SimQueue","short_name":"SimQueue","description":"Queue status, job controls and live logs","start_url":"./","scope":"./","display":"standalone","theme_color":"#101516","background_color":"#101516","icons":[{"src":"icon-192.png","sizes":"192x192","type":"image/png","purpose":"any"},{"src":"icon-512.png","sizes":"512x512","type":"image/png","purpose":"any"}]}
            """#
        ),
        "sw.js": (
            "text/javascript",
            #"""
            'use strict';
            // Network only: never cache queue data, logs, capabilities or actions.
            self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
            self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
            self.addEventListener('fetch', event => {
              if (event.request.mode !== 'navigate' || event.request.method !== 'GET') return;
              event.respondWith(fetch(event.request, {cache:'no-store'}).catch(() => new Response(
                '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>SimQueue · Offline</title><h1>SimQueue is offline</h1><p>Connect to Tailscale and check that the dashboard is running, then reload.</p><p>Reload this page to retry.</p></html>',
                {status:503, headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Referrer-Policy':'no-referrer'}}
              )));
            });
            """#
        ),
        "style.css": (
            "text/css",
            #"""
            :root{color-scheme:dark;--bg:#101516;--panel:#192123;--line:#2b393b;--text:#e5efed;--muted:#9cadaa;--accent:#a7e2ba}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,sans-serif}header{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid var(--line);padding:20px 4vw}.brand{font-weight:800;color:var(--accent)}.brand span{margin-left:16px;color:var(--text);font-size:17px}.badge,.eyebrow{font-size:11px;letter-spacing:.14em;color:var(--accent)}main{max-width:1500px;margin:auto;padding:32px 4vw}.heading{display:flex;justify-content:space-between;align-items:center;gap:20px}h1{font-size:clamp(26px,3vw,42px);font-weight:550;letter-spacing:-.04em;margin:5px 0}h2{font-size:19px;font-weight:550;margin-bottom:4px}h2 span{color:var(--muted);margin-left:8px}.muted,footer{color:var(--muted)}.overview{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:28px 0 16px}.metric{padding:18px 22px;border:1px solid var(--line);border-radius:10px;background:var(--panel)}.metric strong{display:block;font-size:30px;font-weight:500}.metric span{color:var(--muted)}.error{color:#f0a59c}.metric small{display:block;color:var(--muted)}#storage-summary table{white-space:normal}#storage-candidates{overflow-wrap:anywhere}.notice{color:var(--accent);white-space:pre-wrap}.filters{display:flex;gap:10px;margin:28px 0}input,select,button{font:inherit;color:var(--text);background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:10px}input{flex:1;min-width:120px}button{cursor:pointer}button:disabled{opacity:.4;cursor:default}td button+button{margin-left:5px}#action-status{white-space:pre-wrap;color:var(--accent)}button:hover,button:focus-visible{border-color:var(--accent)}section{margin:28px 0}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:9px}table{width:100%;border-collapse:collapse;text-align:left;white-space:nowrap}th{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.06em;background:var(--panel)}td,th{padding:13px 16px;border-bottom:1px solid var(--line)}tr:last-child td{border-bottom:0}td:first-child{max-width:330px;white-space:normal}td small{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;color:var(--muted);overflow-wrap:anywhere}.job-button{border:0;padding:0;background:none;text-align:left;color:var(--accent);font-weight:600}.pill{font-size:12px;color:#d6c9a3}.pill.succeeded,.pill.running{color:var(--accent)}.pill.failed,.pill.infra_failed,.pill.timed_out{color:#f0a59c}.empty{padding:25px;border:1px dashed var(--line);border-radius:8px;color:var(--muted)}#timeline{display:grid;gap:8px;max-height:300px;overflow:auto}.timeline-row{display:grid;grid-template-columns:minmax(160px,28%) minmax(0,1fr);gap:16px;align-items:center}.timeline-label{white-space:normal;overflow-wrap:anywhere;line-height:1.35}.track{height:15px;background:var(--panel);border-radius:3px;position:relative;overflow:hidden}.bar{height:100%;position:absolute;background:#629e78;min-width:2px;border-radius:3px}.log-toolbar{display:flex;gap:8px;flex-wrap:wrap}.live-log{min-height:140px;max-height:350px;overscroll-behavior:contain}footer{font-size:12px;border-top:1px solid var(--line);padding:22px 0}dialog{color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:12px;width:min(850px,94vw);max-height:88vh;padding:24px}dialog::backdrop{background:#0009}.dialog-heading{display:flex;justify-content:space-between;align-items:center}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:var(--panel);padding:15px;border-radius:6px;max-height:350px;overflow:auto;font-size:12px}dl{display:grid;grid-template-columns:150px 1fr;gap:8px}dt{color:var(--muted)}dd{margin:0;overflow-wrap:anywhere}#connection{color:var(--muted);font-size:12px}#connection.error{color:#f0a59c}@media(max-width:650px){.overview{grid-template-columns:repeat(2,1fr)}.filters,.heading{flex-wrap:wrap}.filters input{flex-basis:100%}.timeline-row{grid-template-columns:140px minmax(0,1fr)}dl{grid-template-columns:140px minmax(0,1fr)}}
            """#
        ),
    ]
}

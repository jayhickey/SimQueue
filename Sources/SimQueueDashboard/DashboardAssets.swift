// SPDX-License-Identifier: MIT

// Embedded so a copied simq executable needs no resource bundle or web runtime.
enum DashboardAssets {
    static let files: [String: (type: String, text: String)] = [
        "": (
            "text/html",
            #"""
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>SimQueue · Queue dashboard</title><link rel="stylesheet" href="style.css"><script defer src="app.js"></script></head>
            <body>
            <header><div class="brand">SQ <span>SimQueue</span></div><span class="badge">LOCAL</span></header>
            <main><div class="heading"><div><h1>Queue status</h1></div><p id="connection" role="status">Connecting…</p></div>
            <section id="overview" class="overview" aria-label="Host overview"></section>
            <p id="health" class="notice"></p>
            <p id="action-status" role="status"></p>
            <div class="filters"><input id="search" type="search" placeholder="Search project, command, submitter or ID" aria-label="Search jobs"><select id="project" aria-label="Filter project"><option value="">All projects</option></select><select id="state" aria-label="Filter state"><option value="">All states</option></select></div>
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
            const $ = id => document.getElementById(id);
            const el = (tag, text, className) => { const n = document.createElement(tag); if (text != null) n.textContent = text; if (className) n.className = className; return n; };
            let snapshot, selected = null, detailGeneration = 0;
            const pendingActions = new Set();
            const states = ['queued','admitted','running','succeeded','failed','canceled','interrupted','infra_failed','timed_out','expired'];
            for (const state of states) { const o = el('option', state.replaceAll('_',' ')); o.value = state; $('state').append(o); }
            const epoch = value => value == null ? null : (typeof value === 'number' ? value * 1000 : Date.parse(value));
            const duration = ms => { if (ms == null || !Number.isFinite(ms)) return '—'; const s = Math.max(0, Math.floor(ms/1000)); return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s/60)}m ${s%60}s` : `${Math.floor(s/3600)}h ${Math.floor(s%3600/60)}m`; };
            const now = () => epoch(snapshot?.generatedAt) || Date.now();
            const label = j => j.kind ? `${j.project} · ${j.kind}` : `${j.project} · ${j.command?.[0]?.split('/').pop() || j.id.slice(0,8)}`;
            function timings(j) {
              const q=epoch(j.queue_time), a=epoch(j.admitted_at), s=epoch(j.started_at), f=epoch(j.finished_at), end=f ?? now();
              // Admission is the start of preparation, execution begins at started_at.
              // Older daemon versions may omit admission; don't invent a prep duration.
              return [duration((a ?? s ?? end)-q), a == null ? '—' : duration((s ?? end)-a), s == null ? '—' : duration(end-s)];
            }
            async function get(path) {
              const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 12000);
              try { const r = await fetch(`api/${path}`, {cache:'no-store', signal:controller.signal}); if (!r.ok) throw new Error('Unavailable'); return await r.json(); }
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
            function table(jobs, target) {
              const root=$(target); root.replaceChildren();
              if (!jobs.length) { root.append(el('div', 'No jobs in this view.', 'empty')); return; }
              const wrap=el('div',null,'table-wrap'), t=el('table'), head=el('tr');
              for (const name of ['Job / command','State','Priority','Wait','Prep','Run','Sims','Outcome / hold','Actions']) head.append(el('th',name));
              const thead=el('thead'); thead.append(head); t.append(thead); const body=el('tbody');
              for (const j of jobs) {
                const row=el('tr'), name=el('td'), button=el('button',label(j),'job-button');
                button.addEventListener('click',()=>openDetail(j.id)); const summary=el('small',`${j.id} · ${(j.command || []).join(' ')}`); summary.title=(j.command || []).join(' '); name.append(button,summary); row.append(name);
                const state=el('td'); state.append(el('span',j.state.replaceAll('_',' '),'pill '+j.state)); row.append(state);
                row.append(el('td',`P${j.priority}${j.position ? ' · #'+j.position : ''}`));
                for (const time of timings(j)) row.append(el('td',time));
                row.append(el('td',j.granted_sims),el('td',j.wait_reasons?.map(r=>r.summary).join('; ') || j.result_class || j.message || '—'),controls(j)); body.append(row);
              }
              t.append(body); wrap.append(t); root.append(wrap);
            }
            function render() {
              if (!snapshot) return;
              const s=snapshot.status;
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
                name.addEventListener('click',()=>openDetail(j.id)); bar.style.left=`${100*(epoch(j.started_at)-start)/span}%`; bar.style.width=`${100*((epoch(j.finished_at) ?? now())-epoch(j.started_at))/span}%`;
                track.title=`${j.started_at} → ${j.finished_at || 'running'} (${timings(j)[2]})`; track.append(bar); row.append(name,track); root.append(row); }
            }
            async function openDetail(id) {
              selected=id; const generation=++detailGeneration; $('detail-body').replaceChildren(el('p','Loading…'));
              if (!$('detail').open) $('detail').showModal();
              try { await updateDetail(id,generation); } catch { if (generation===detailGeneration) $('detail-body').replaceChildren(el('p','Job details unavailable. Close and reopen to retry.')); }
            }
            async function updateDetail(id,generation) {
              const j=await get(`job/${encodeURIComponent(id)}`);
              if (generation!==detailGeneration || selected!==id) return;
              const root=$('detail-body'), dl=el('dl'), times=timings(j);
              for (const [key,value] of Object.entries({'Job':j.id,'Label':label(j),'State':j.state,'Project':j.project,'Submitter':j.submitter,'Priority':j.priority,'Dispatch position':j.position,'Effective score':j.effective_score,'Attempt':j.attempt,'Wait / prep / run':times.join(' / '),'Queued':j.queue_time,'Admitted':j.admitted_at,'Started':j.started_at,'Finished':j.finished_at,'Result':j.result_class,'Command exit':j.command_exit_code,'Commit':j.git_sha,'Worktree':j.worktree,'Directory':j.cwd,'Run directory':j.run_dir,'Peak memory':j.peak_memory_mib == null ? null : `${j.peak_memory_mib} MiB`,'Run deadline':j.run_deadline_at,'Queue deadline':j.queue_deadline_at,'Exclusive':j.exclusive,'Retryable':j.retryable,'Cleanup pending':j.cleanup_pending,'Cleanup blocked':j.cleanup_blocked,'Message':j.message,'Waiting':j.wait_reasons?.map(r=>r.summary).join('; '),'Simulators':j.sims?.map(s=>`${s.name} (${s.udid})`).join(', '),'Artifacts':j.artifacts?.map(a=>`${a.path} (${a.bytes} bytes)`).join('\n')})) {
                if (value != null && value !== '') dl.append(el('dt',key),el('dd',String(value)));
              }
              const command=el('pre',JSON.stringify(j.command || [],null,2));
              const logs=el('pre','Loading output…'); const actions=el('table'), actionRow=el('tr'); actionRow.append(controls(j)); actions.append(actionRow); root.replaceChildren(actions,dl,el('h3','Command · exact argv'),command,el('h3','Output · first 32 KiB'),logs);
              if (j.artifacts_truncated) root.append(el('p','Artifact listing is truncated.','muted'));
              try { const data=await get(`logs/${encodeURIComponent(id)}`); if (generation!==detailGeneration) return;
                logs.textContent=data.data || 'No output yet.'; if (!data.at_end) logs.append(document.createTextNode('\n… More output available with simq logs '+id));
              } catch { logs.textContent='Log unavailable for this job.'; }
            }
            $('close').addEventListener('click',()=>$('detail').close());
            $('detail').addEventListener('close',()=>{selected=null; ++detailGeneration;});
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
        "style.css": (
            "text/css",
            #"""
            :root{color-scheme:dark;--bg:#101516;--panel:#192123;--line:#2b393b;--text:#e5efed;--muted:#9cadaa;--accent:#a7e2ba}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,sans-serif}header{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid var(--line);padding:20px 4vw}.brand{font-weight:800;color:var(--accent)}.brand span{margin-left:16px;color:var(--text);font-size:17px}.badge,.eyebrow{font-size:11px;letter-spacing:.14em;color:var(--accent)}main{max-width:1500px;margin:auto;padding:32px 4vw}.heading{display:flex;justify-content:space-between;align-items:center;gap:20px}h1{font-size:clamp(26px,3vw,42px);font-weight:550;letter-spacing:-.04em;margin:5px 0}h2{font-size:19px;font-weight:550;margin-bottom:4px}h2 span{color:var(--muted);margin-left:8px}.muted,footer{color:var(--muted)}.overview{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:28px 0 16px}.metric{padding:18px 22px;border:1px solid var(--line);border-radius:10px;background:var(--panel)}.metric strong{display:block;font-size:30px;font-weight:500}.metric span{color:var(--muted)}.notice{color:var(--accent);white-space:pre-wrap}.filters{display:flex;gap:10px;margin:28px 0}input,select,button{font:inherit;color:var(--text);background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:10px}input{flex:1;min-width:120px}button{cursor:pointer}button:disabled{opacity:.4;cursor:default}td button+button{margin-left:5px}#action-status{white-space:pre-wrap;color:var(--accent)}button:hover,button:focus-visible{border-color:var(--accent)}section{margin:28px 0}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:9px}table{width:100%;border-collapse:collapse;text-align:left;white-space:nowrap}th{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.06em;background:var(--panel)}td,th{padding:13px 16px;border-bottom:1px solid var(--line)}tr:last-child td{border-bottom:0}td:first-child{max-width:330px;white-space:normal}td small{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;color:var(--muted);overflow-wrap:anywhere}.job-button{border:0;padding:0;background:none;text-align:left;color:var(--accent);font-weight:600}.pill{font-size:12px;color:#d6c9a3}.pill.succeeded,.pill.running{color:var(--accent)}.pill.failed,.pill.infra_failed,.pill.timed_out{color:#f0a59c}.empty{padding:25px;border:1px dashed var(--line);border-radius:8px;color:var(--muted)}#timeline{display:grid;gap:8px;max-height:300px;overflow:auto}.timeline-row{display:grid;grid-template-columns:160px 1fr;gap:16px;align-items:center}.timeline-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.track{height:15px;background:var(--panel);border-radius:3px;position:relative;overflow:hidden}.bar{height:100%;position:absolute;background:#629e78;min-width:2px;border-radius:3px}footer{font-size:12px;border-top:1px solid var(--line);padding:22px 0}dialog{color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:12px;width:min(850px,94vw);max-height:88vh;padding:24px}dialog::backdrop{background:#0009}.dialog-heading{display:flex;justify-content:space-between;align-items:center}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:var(--panel);padding:15px;border-radius:6px;max-height:350px;overflow:auto;font-size:12px}dl{display:grid;grid-template-columns:150px 1fr;gap:8px}dt{color:var(--muted)}dd{margin:0;overflow-wrap:anywhere}#connection{color:var(--muted);font-size:12px}#connection.error{color:#f0a59c}@media(max-width:650px){.overview{grid-template-columns:repeat(2,1fr)}.filters,.heading{flex-wrap:wrap}.filters input{flex-basis:100%}.timeline-row{grid-template-columns:100px 1fr}dl{grid-template-columns:100px 1fr}}
            """#
        ),
    ]
}

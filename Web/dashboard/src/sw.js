// SPDX-License-Identifier: MIT
// No offline cache: capabilities, queue data, logs and actions stay network-only.
self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (event) => {
  if (event.request.mode !== 'navigate' || event.request.method !== 'GET') return;
  event.respondWith(
    fetch(event.request, { cache: 'no-store' }).catch(
      () =>
        new Response(
          `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="color-scheme" content="light dark"><title>SimQueue · Offline</title><style>body{margin:0;background:light-dark(#edf1ee,#101817);color:light-dark(#24332d,#e4ece7);font:15px/1.6 system-ui,sans-serif}main{max-width:32rem;margin:12vh auto;padding:24px}b{color:#329765}section{margin-top:24px;border:1px solid #a56565;border-radius:12px;padding:24px}h1{font-size:24px;line-height:1.2}a{display:inline-block;padding:10px 18px;border:1px solid #6b8977;border-radius:6px;color:inherit;text-decoration:none;font:inherit;cursor:pointer}small{opacity:.7}</style><main><b>SQ · SimQueue</b><section><h1>Can’t reach the Mac</h1><p>SimQueue is offline. Connect to your private network and check that the dashboard is running.</p><a href="./">Retry connection</a></section><p><small>No live readings or job controls are available while disconnected.</small></p></main></html>`,
          {
            status: 503,
            headers: {
              'Content-Type': 'text/html; charset=utf-8',
              'Cache-Control': 'no-store',
              'Referrer-Policy': 'no-referrer',
            },
          },
        ),
    ),
  );
});

// SPDX-License-Identifier: MIT
// Disposable fixture server. It has no daemon, simulator or filesystem mutation routes.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fixture } from './fixtures.mjs';
const root = process.env.SIMQ_DASHBOARD_ASSETS
  ? new URL('file://' + process.env.SIMQ_DASHBOARD_ASSETS + '/')
  : new URL('../../../.build/dashboard/', import.meta.url);
const csp =
  "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; frame-ancestors 'none'; base-uri 'none'";
http
  .createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    const path = req.url;
    if (path === '/') {
      res.end('ready');
      return;
    }
    if (!path.startsWith('/fixture/')) {
      res.writeHead(404).end();
      return;
    }
    const route = path.slice('/fixture/'.length);
    if (route === 'api/snapshot') {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify(fixture));
      return;
    }
    if (route.startsWith('api/job/')) {
      const id = route.split('/').at(-1);
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify(fixture.active.concat(fixture.recent).find((j) => j.id === id)));
      return;
    }
    if (route.startsWith('api/logs/')) {
      res.setHeader('Content-Type', 'application/json');
      res.end(
        JSON.stringify({
          data: 'Preparing workload…\nRunning tests…\n',
          offset: 0,
          at_end: true,
          job_finished: false,
        }),
      );
      return;
    }
    if (req.method === 'POST') {
      res.setHeader('Content-Type', 'application/json');
      res.end('{}');
      return;
    }
    const files = {
      '': 'index.html',
      'app.js': 'app.js',
      'style.css': 'style.css',
      'sw.js': 'sw.js',
      'manifest.webmanifest': 'manifest.webmanifest',
    };
    if (!(route in files)) {
      res.writeHead(404).end();
      return;
    }
    res.setHeader('Content-Security-Policy', csp);
    res.setHeader(
      'Content-Type',
      route.endsWith('.js')
        ? 'text/javascript'
        : route.endsWith('.css')
          ? 'text/css'
          : route.endsWith('.webmanifest')
            ? 'application/manifest+json'
            : 'text/html',
    );
    res.end(await readFile(new URL(files[route], root)));
  })
  .listen(Number(process.env.SIMQ_DASHBOARD_PORT || 43871), '127.0.0.1');

// SPDX-License-Identifier: MIT
import { build, transform } from 'esbuild';
import { mkdir, copyFile, readFile, writeFile } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
const out = new URL('../../.build/dashboard/', import.meta.url);
await mkdir(out, { recursive: true });
await build({
  entryPoints: [new URL('src/app.tsx', import.meta.url).pathname],
  outfile: new URL('app.js', out).pathname,
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari16'],
  legalComments: 'eof',
  banner: {
    js:
      '/*! Preact\n' +
      (await readFile(new URL('node_modules/preact/LICENSE', import.meta.url), 'utf8')) +
      '*/',
  },
});
const css = await transform(await readFile(new URL('src/style.css', import.meta.url), 'utf8'), {
  loader: 'css',
  minify: true,
  target: ['safari16'],
  legalComments: 'eof',
});
await writeFile(new URL('style.css', out), css.code);
for (const file of ['index.html', 'sw.js', 'manifest.webmanifest'])
  await copyFile(new URL(`src/${file}`, import.meta.url), new URL(file, out));
for (const [file, budget] of [
  ['app.js', 24576],
  ['style.css', 6144],
]) {
  const data = await readFile(new URL(file, out)),
    gz = gzipSync(data).length;
  if (gz > budget) throw new Error(`${file}: ${gz} gzip bytes exceeds ${budget} byte budget`);
  console.log(`${file}: ${data.length} bytes, ${gz} bytes gzip (budget ${budget})`);
}

// A throwaway static server for the browser smoke test. No dependencies.
//   node linux/web-tests/player-smoke/serve.mjs --fixtures OUTDIR [--port 18123] [--host 127.0.0.1] [--gap-ms 6000]
// /            linux/web (the page's own modules, read-only)
// /smoke/      this folder
// /smoke/fixtures/   OUTDIR from make-fixtures.sh
// /api/v1/nvr/ the archive routes of T00 C.5 over those clips (mini-archive.mjs), for pipeline.html
// It listens on the loopback address unless told otherwise. `--host 0.0.0.0` is for the manual check from another device (an iPad, an iPhone)
// over plain HTTP on the LAN name, which is the condition the real page runs in; never leave it running.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { answer, createMiniArchive, layout } from './mini-archive.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => { const at = args.indexOf(`--${name}`); return at >= 0 ? args[at + 1] : fallback; };
const here = fileURLToPath(new URL('.', import.meta.url));
const fixtures = option('fixtures');
if (!fixtures) { console.error('usage: node serve.mjs --fixtures OUTDIR [--port 18123] [--host 127.0.0.1] [--gap-ms 6000]'); process.exit(2); }
const port = Number(option('port', '18123'));
const host = option('host', '127.0.0.1');
const roots = [['/smoke/fixtures/', resolve(fixtures)], ['/smoke/', here], ['/', resolve(here, '../../web')]];
const mini = createMiniArchive(resolve(fixtures), { gapMs: Number(option('gap-ms', '6000')) });
const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.json': 'application/json', '.mp4': 'video/mp4', '.m4s': 'video/mp4' };

createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost');
  if (url.pathname.startsWith('/api/v1/')) {
    const result = answer(mini.archive, `${url.pathname.slice('/api/v1/'.length)}${url.search}`);
    response.writeHead(result.status, { 'Cache-Control': 'no-store', ...result.headers });
    response.end(result.body);
    return;
  }
  if (url.pathname === '/smoke/layout.json') {
    response.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify(layout(mini)));
    return;
  }
  const [prefix, root] = roots.find(([p]) => url.pathname.startsWith(p));
  const relative = normalize(decodeURIComponent(url.pathname.slice(prefix.length))).replace(/^(\.\.[/\\])+/, '');
  try {
    const body = await readFile(join(root, relative || 'index.html'));
    response.writeHead(200, { 'Content-Type': types[extname(relative)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    response.end(body);
  } catch {
    response.writeHead(404);
    response.end('not found');
  }
}).listen(port, host, () => console.log(`http://${host === '0.0.0.0' ? '<this machine\'s LAN name>' : host}:${port}/smoke/smoke.html`));

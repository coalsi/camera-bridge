// The smoke server: serves linux/web as it is, except the player modules of T08 and T09's Record switch, which come from ./fakes, plus
// a few fake API routes (listed below). Sends the daemon's security headers (so an inline style or script is refused here too). Loopback only.
//   node linux/web-dev/t10-smoke/server.mjs [port]      (default 8143)
// Fake routes: GET /api/v1/nvr/cameras, GET .../snapshot, POST .../optimize and .../optimize/undo. Everything else under /api/ is a 404.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '../../web');
const port = Number(process.argv[2] || 8143);
const FAKED = new Set(['fetcher', 'catalog', 'cell', 'clock', 'session', 'surface', 'lite', 'record']);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };
const csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";
// An api.js from before T08 has no getBytes or notifyAuth; the player modules import them, so add them to what is served.
const SHIM = '\nexport function notifyAuth(kind) { listeners.forEach((fn) => fn(kind)); }\nexport async function getBytes() { throw new Error("getBytes is not available in the smoke server"); }\n';

function resolveFile(pathname) {
  if (pathname === '/') return path.join(here, 'harness.html');
  if (pathname === '/harness.js') return path.join(here, 'harness.js');
  if (pathname === '/t10-drive.js' || pathname === '/t10-checks.js') return path.join(here, '..', pathname.slice(1));
  const fake = pathname.match(/^\/js\/nvr\/([a-z]+)\.js$/);
  if (fake && FAKED.has(fake[1])) return path.join(here, 'fakes', `${fake[1]}.js`);
  const file = path.join(webRoot, pathname);
  return file.startsWith(webRoot + path.sep) ? file : null;
}

http.createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');
  response.setHeader('Content-Security-Policy', csp);
  response.setHeader('Cache-Control', 'no-store');
  if (url.pathname === '/favicon.ico') { response.statusCode = 204; return response.end(); }
  if (url.pathname === '/api/v1/nvr/cameras') {
    response.setHeader('Content-Type', 'application/json');
    return response.end(JSON.stringify({ serverTime: Date.now(), catalogVersion: 1, cameras: [] }));
  }
  if (url.pathname.endsWith('/snapshot')) {
    response.setHeader('Content-Type', 'image/svg+xml');
    return response.end(`<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720"><rect width="1280" height="720" fill="#2b5d8a"/><circle cx="${300 + (Date.now() / 50) % 600}" cy="360" r="90" fill="#e8a33d"/><text x="40" y="80" font-size="48" fill="#fff">snapshot ${new Date().toISOString().slice(11, 19)}</text></svg>`);
  }
  if (url.pathname.endsWith('/optimize') && request.method === 'POST') {
    response.setHeader('Content-Type', 'application/json');
    return setTimeout(() => response.end(JSON.stringify({
      applied: [{ id: 'bitrate', title: 'Lowered the bit rate to 6 Mbit/s' }, { id: 'gop', title: 'Set the key frame interval to 2 s' }],
      failed: [{ id: 'sub', reason: 'The sub stream could not be changed.' }], canUndo: true, mayNeedRecordingReEnabled: true, scoreBefore: 40, scoreAfter: 90,
    })), 600);
  }
  if (url.pathname.endsWith('/optimize/undo') && request.method === 'POST') { response.statusCode = 204; return response.end(); }
  const file = resolveFile(url.pathname);
  if (!file) { response.statusCode = 403; return response.end(); }
  fs.readFile(file, 'utf8', (error, text) => {
    if (error) { response.statusCode = 404; response.setHeader('Content-Type', 'application/json'); return response.end('{"error":"not_found","message":"No such file."}'); }
    response.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
    const needsShim = url.pathname === '/js/api.js' && !/export (async )?function getBytes/.test(text);
    response.end(needsShim ? text + SHIM : text);
  });
}).listen(port, '127.0.0.1', () => console.log(`T10 smoke server on http://127.0.0.1:${port}/`));

// Runs JavaScript files inside a page of a throwaway headless Chrome (its own temporary profile, loopback debugging port) and prints what they return.
//   node linux/web-dev/t10-run.mjs <url> <file.js> [<file.js> ...]
// Each file is evaluated in the page in order, as one expression (an async arrow function called at once is fine: its result is awaited).
// Set CHROME to another browser binary. Needs Node 22 or newer (WebSocket and fetch are built in). No cookie, storage or response body is printed.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const [url, ...files] = process.argv.slice(2);
if (!url || files.length === 0) { console.error('usage: node t10-run.mjs <url> <file.js> [...]'); process.exit(2); }
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const port = 9300 + Math.floor(Math.random() * 600);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'cb-t10-'));
const chrome = spawn(chromePath, ['--headless=new', '--disable-gpu', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const finish = async (code) => { try { chrome.kill('SIGTERM'); } catch { /* gone */ } await sleep(300); fs.rmSync(profile, { recursive: true, force: true }); process.exit(code); };

let page;
for (let i = 0; i < 50 && !page; i += 1) {
  try { page = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((target) => target.type === 'page'); } catch { /* not up yet */ }
  if (!page) await sleep(200);
}
if (!page) { console.error('the browser did not start'); await finish(1); }
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve) => socket.addEventListener('open', resolve));
let nextId = 0;
const waiting = new Map();
const problems = [];
socket.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  if (message.id && waiting.has(message.id)) { waiting.get(message.id)(message); waiting.delete(message.id); return; }
  if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') problems.push(`log: ${message.params.entry.text}`);
  if (message.method === 'Runtime.exceptionThrown') problems.push(`exception: ${message.params.exceptionDetails.exception?.description ?? message.params.exceptionDetails.text}`);
});
const send = (method, params = {}) => new Promise((resolve) => { const id = ++nextId; waiting.set(id, resolve); socket.send(JSON.stringify({ id, method, params })); });
await send('Runtime.enable');
await send('Log.enable');
await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1100, height: 1000, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url });
await sleep(1500);
const results = [];
for (const file of files) {
  const reply = await send('Runtime.evaluate', { expression: fs.readFileSync(file, 'utf8'), awaitPromise: true, returnByValue: true, timeout: 180000 });
  if (!reply.result) { results.push({ cdpError: reply.error?.message ?? 'no result' }); continue; }   // the page navigated or closed while the file ran
  const { exceptionDetails, result } = reply.result;
  results.push(exceptionDetails ? { error: exceptionDetails.exception?.description ?? exceptionDetails.text } : result.value);
}
console.log(JSON.stringify({ results, pageProblems: problems }, null, 1));
await finish(0);

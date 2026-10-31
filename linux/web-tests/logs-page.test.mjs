// The Log page (screens/logs.js): the stream sends its newest 500 lines again on every (re)connection, so the view starts over on each `open`
// instead of showing them twice; the count follows the lines; lines held back while paused are capped.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let renderLogs;
const sources = [];
before(async () => {
  browser = installFakeBrowser();
  globalThis.EventSource = class {
    constructor(url) { this.url = url; this.listeners = new Map(); this.closed = false; sources.push(this); }
    addEventListener(type, fn) { this.listeners.set(type, fn); }
    close() { this.closed = true; }
    fire(type, data) { this.listeners.get(type)?.(data === undefined ? {} : { data: JSON.stringify(data) }); }
  };
  ({ renderLogs } = await import('../web/js/screens/logs.js'));
});
after(() => browser?.restore());

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const line = (n, extra = {}) => ({ date: new Date(Date.UTC(2026, 9, 31, 12, 0, n)).toISOString(), level: 'info', category: 'engine', message: `line ${n}`, ...extra });
const shownLines = (page) => all(page.el, (node) => node.className.startsWith('log-line')).map((node) => all(node, (n) => n.className === 'm')[0].textContent);
const status = (page) => all(page.el, (node) => node.getAttribute('role') === 'status')[0].textContent;

test('a reconnection starts the view over: the newest lines are not shown twice', () => {
  const page = renderLogs();
  const source = sources.at(-1);
  source.fire('open');
  for (let n = 1; n <= 3; n += 1) source.fire('log', line(n));
  assert.deepEqual(shownLines(page), ['line 1', 'line 2', 'line 3']);
  assert.equal(status(page), '3 lines');
  // The box restarted: the browser reconnects by itself and the stream sends the newest lines again.
  source.fire('open');
  for (let n = 1; n <= 4; n += 1) source.fire('log', line(n));
  assert.deepEqual(shownLines(page), ['line 1', 'line 2', 'line 3', 'line 4']);
  assert.equal(status(page), '4 lines');
  page.destroy();
});

test('lines held back while paused are capped at what the view keeps', () => {
  const page = renderLogs();
  const source = sources.at(-1);
  source.fire('open');
  const pause = all(page.el, (node) => node.localName === 'button' && /Pause/.test(node.textContent))[0];
  pause.dispatchEvent({ type: 'click', target: pause });
  assert.match(status(page), /Paused/);
  for (let n = 0; n < 2500; n += 1) source.fire('log', line(n % 60, { message: `held ${n}` }));
  assert.equal(shownLines(page).length, 0, 'nothing shows while paused');
  pause.dispatchEvent({ type: 'click', target: pause });
  const shown = shownLines(page);
  assert.equal(shown.length, 2000, 'at most 2,000');
  assert.equal(shown[0], 'held 500', 'the newest ones');
  assert.equal(shown.at(-1), 'held 2499');
  assert.equal(status(page), '2000 lines');
  page.destroy();
});

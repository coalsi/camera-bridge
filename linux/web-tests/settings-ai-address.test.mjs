// The address #/settings/ai (the camera page's AI descriptions card links to it): Settings opens at its AI descriptions card, with the
// keyboard there. A file of its own: the recording screens (nvr/ui.js) load for the first time here, as on a fresh page, so the Recording
// card above the AI card comes after the settings and the scroll has to wait for it.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
before(() => { browser = installFakeBrowser(); });
after(() => browser?.restore());

const SETTINGS = {
  bridgeName: 'Bridge', timeZone: 'UTC', logLevel: 'info', basePort: 21100, sensorsBridgePort: 21190, webhookEnabled: false, webhookPort: 21180,
  ai: { provider: 'anthropic', model: 'claude-haiku-5-5', keySaved: true, keyHint: '0000', today: 0, last7Days: 0, paused: false, needsRecordingsFolder: false },
};

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const tick = () => new Promise((resolve) => setImmediate(resolve));

test('#/settings/ai opens Settings at the AI descriptions card once the Recording card above it is there, with the keyboard on its heading', async () => {
  const { renderSettings } = await import('../web/js/screens/settings.js');
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url).endsWith('/api/v1/settings')) return new Response(JSON.stringify(SETTINGS), { status: 200, headers: { 'Content-Type': 'application/json' } });
    throw new TypeError('fetch failed (no bridge in this test)');
  };
  const proto = Object.getPrototypeOf(browser.document.createElement('div'));
  const saved = { focus: proto.focus, querySelector: proto.querySelector };
  let screen = null;
  const recordingHost = () => all(screen.el, (node) => node.getAttribute('id') === 'recording')[0];
  const scrolled = [];
  const focused = [];
  proto.scrollIntoView = function scrollIntoView() { scrolled.push({ el: this, recordingThere: Boolean(recordingHost()?.firstChild) }); };
  proto.focus = function focus() { focused.push(this); };
  proto.querySelector = function querySelector(selector) { return selector === 'h2' ? all(this, (node) => node.localName === 'h2')[0] ?? null : null; };
  try {
    screen = renderSettings({ params: ['ai'], setTitle: () => {} });
    browser.document.append(screen.el);
    for (let i = 0; i < 400 && !recordingHost()?.firstChild; i += 1) await tick();   // the recording screens load
    for (let i = 0; i < 20; i += 1) await tick();
    assert.ok(recordingHost()?.firstChild, 'the Recording card came');
    assert.equal(scrolled.length, 1, 'once');
    assert.ok(scrolled[0].el.classList.contains('ai-card'), `scrolled to ${scrolled[0].el.className}`);
    assert.equal(scrolled[0].recordingThere, true, 'not before the Recording card above it, which would push it down');
    const heading = all(scrolled[0].el, (node) => node.localName === 'h2')[0];
    assert.equal(heading.getAttribute('tabindex'), '-1', 'a heading takes focus only with a tabindex');
    assert.ok(focused.includes(heading), 'the keyboard starts at the card');
  } finally {
    screen?.el.remove();
    screen?.destroy();
    delete proto.scrollIntoView;
    Object.assign(proto, saved);
    globalThis.fetch = realFetch;
  }
});

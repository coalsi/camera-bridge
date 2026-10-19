// The camera page's Security card says where the camera's event pictures go while its AI switch is on and the AI service is not on the home
// network (final review M6): "Its event pictures go to Claude for AI descriptions." The guard's badge and level are not touched; this is only
// the line. In the fake browser with Settings' answer given to the card.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let sec;
before(async () => {
  browser = installFakeBrowser();
  sec = await import('../web/js/screens/security.js');
});
after(() => browser?.restore());

const ID = '0A1B2C3D-0000-4000-8000-000000000031';
const LINE = (service) => `Its event pictures go to ${service} for AI descriptions.`;
const camera = (extra = {}) => ({ id: ID, name: 'Front door', isEnabled: true, vendor: 'hikvision', aiDescriptions: true, status: { connection: 'online' }, ...extra });
const CLAUDE = { provider: 'anthropic', model: 'claude-haiku-5-5', baseURL: null, keySaved: true };
const home = (baseURL) => ({ provider: 'openAICompatible', model: 'llava', baseURL, keySaved: false });
const settingsWith = (ai) => ({ bridgeName: 'Bridge', ai });

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const lines = (card) => all(card.el, (node) => node.classList?.contains('sec-ai-note') && visible(node)).map((node) => node.textContent);
const settle = async () => { for (let i = 0; i < 5; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
const cardFor = async (cam, ai) => {
  const card = sec.createSecurityCard(cam, { canSetUp: false, aiSettings: ai instanceof Error ? Promise.reject(ai) : Promise.resolve(settingsWith(ai)) });
  await settle();
  return card;
};

test('the switch on with Claude: the card says the event pictures go to Claude, once', async () => {
  const card = await cardFor(camera(), CLAUDE);
  assert.deepEqual(lines(card), [LINE('Claude')]);
  assert.equal(card.el.textContent.split(LINE('Claude')).length, 2, 'said once');
});

test('the switch on with a service at 192.168.77.10: no line, the pictures stay at home', async () => {
  const card = await cardFor(camera(), home('http://192.168.77.10:11434/v1'));
  assert.deepEqual(lines(card), []);
});

test('the switch off: no line, whatever the service', async () => {
  for (const ai of [CLAUDE, home('https://api.openai.com/v1'), home('http://192.168.77.10:11434/v1')]) {
    const card = await cardFor(camera({ aiDescriptions: false }), ai);
    assert.deepEqual(lines(card), [], JSON.stringify(ai));
  }
});

test('an OpenAI-compatible service away from home is named by its host', async () => {
  assert.deepEqual(lines(await cardFor(camera(), home('https://api.openai.com/v1'))), [LINE('api.openai.com')]);
  assert.deepEqual(lines(await cardFor(camera(), home('https://openrouter.ai/api/v1/'))), [LINE('openrouter.ai')]);
  assert.deepEqual(lines(await cardFor(camera(), home('https://llm.example.test:8443/v1'))), [LINE('llm.example.test')], 'the host, not the port');
});

test('what counts as the home network: private, loopback and link-local IPv4, and .local and .lan names', () => {
  const homeHosts = ['10.0.0.5', '10.255.255.255', '172.16.0.1', '172.31.255.254', '192.168.1.1', '192.168.77.10', '127.0.0.1', '127.8.9.10', '169.254.3.4',
    'ollama.local', 'NAS.LAN', 'studio.example.local', 'localhost', '[::1]', '[fe80::1]'];
  const awayHosts = ['172.15.0.1', '172.32.0.1', '11.0.0.1', '8.8.8.8', '192.0.2.1', '100.64.0.1', 'api.openai.com', '10.example.com', '192.168.1.1.example.com',
    'local.example.com', 'notlocal', '[2001:db8::1]'];
  for (const host of homeHosts) assert.equal(sec.isHomeNetworkHost(host), true, host);
  for (const host of awayHosts) assert.equal(sec.isHomeNetworkHost(host), false, host);
  // Written another way, an address is still the same address.
  assert.equal(sec.picturesGoTo({ provider: 'openAICompatible', baseURL: 'http://0x7f.1/v1' }), null);
  assert.equal(sec.picturesGoTo({ provider: 'openAICompatible', baseURL: 'http://3232235786/v1' }), null, '192.168.0.10 as one number');
});

test('no service, no address, or settings that could not be read: no line', async () => {
  assert.deepEqual(lines(await cardFor(camera(), { provider: null, keySaved: false })), []);
  assert.deepEqual(lines(await cardFor(camera(), { provider: 'openAICompatible', baseURL: null })), []);
  assert.deepEqual(lines(await cardFor(camera(), { provider: 'openAICompatible', baseURL: 'not an address' })), []);
  assert.deepEqual(lines(await cardFor(camera(), new Error('offline'))), []);
  assert.deepEqual(lines(sec.createSecurityCard(camera(), { canSetUp: false })), [], 'a card given no settings');
});

test('the line follows the camera’s switch in place, and waits for Settings', async () => {
  let answer;
  const card = sec.createSecurityCard(camera({ aiDescriptions: false }), { canSetUp: false, aiSettings: new Promise((resolve) => { answer = resolve; }) });
  assert.deepEqual(lines(card), [], 'nothing before Settings answers');
  answer(settingsWith(CLAUDE));
  await settle();
  assert.deepEqual(lines(card), [], 'the switch is off');
  card.update(camera({ aiDescriptions: true }));
  assert.deepEqual(lines(card), [LINE('Claude')]);
  card.update(camera({ aiDescriptions: false }));
  assert.deepEqual(lines(card), []);
});

test('the line changes no badge or level', async () => {
  const security = { level: 'gold', title: 'Local only', summary: 'Camera Bridge found no way in from outside.', checkedAt: '2026-10-17T14:00:00Z', findings: [], guard: { watched: true, today: 0, last24h: 0, names: [] } };
  const withLine = await cardFor(camera({ status: { connection: 'online', security } }), CLAUDE);
  const without = await cardFor(camera({ aiDescriptions: false, status: { connection: 'online', security } }), CLAUDE);
  const badge = (card) => all(card.el, (node) => node.classList?.contains('sec-badge')).map((node) => [node.dataset.level, node.textContent]);
  assert.deepEqual(badge(withLine), [['gold', 'Local only']]);
  assert.deepEqual(badge(withLine), badge(without));
});

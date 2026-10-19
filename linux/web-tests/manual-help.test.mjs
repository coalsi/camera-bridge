// "Change it by hand" on the page (screens/manual-help.js): the bridge's help for a step of Set up for Camera Bridge the camera refused or does
// not support (camera-setup.js) and for the Security card's findings, the Internet guard's "Not watched" among them (security.js). A menu path
// the bridge does not call confirmed always shows "Menu names differ between models", in the fake browser. The helps drawn here are the
// bridge's own (support/manual-help-fixtures.json, written and checked by BridgeEngine's CameraManualHelpTests), so they can't drift from it.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let help;
let setup;
let sec;
before(async () => {
  browser = installFakeBrowser();
  help = await import('../web/js/screens/manual-help.js');
  setup = await import('../web/js/screens/camera-setup.js');
  sec = await import('../web/js/screens/security.js');
});
after(() => browser?.restore());

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList.contains(name));
const tag = (root, name) => all(root, (node) => node.localName === name);

const FIXTURES = JSON.parse(readFileSync(new URL('./support/manual-help-fixtures.json', import.meta.url), 'utf8')).helps;
const BRIDGE = '192.168.77.28';
/** The Reolink doorbell's guard (CameraManualHelpText): unconfirmed places, its web page, the router's way, what it asks now, Check again. */
const WATCH = FIXTURES.reolinkGuard;
/** A Hikvision's Watch: its menu confirmed, its web page, what it asks now, and its address to keep and reserve. */
const HIKVISION = FIXTURES.hikvisionWatch;
/** A Tapo's Watch: the Tapo app's path, no web page. */
const TAPO = FIXTURES.tapoWatch;
/** A confirmed path (the IPCamera Web family's own page). */
const CLOUD = FIXTURES.ipcamWebCloud;

test('the fixtures are the bridge’s own helps', () => {
  assert.match(WATCH.why, /^The Internet guard sees a camera’s lookups only while its DNS asks Camera Bridge \(192\.168\.77\.28\)/);
  assert.equal(WATCH.places[0].app, 'The Reolink app');
  assert.equal(HIKVISION.places[0].confirmed, true);
  assert.equal(CLOUD.places[0].action, 'Turn off Enable Mobile Monitoring.');
});

test('the bridge’s help reads as why, where (each menu joined by ›), what to set, the router’s way and what to do next', () => {
  const view = help.manualHelpView(WATCH);
  assert.equal(view.why, WATCH.why);
  assert.deepEqual(view.places.map((place) => place.path.join(' › ')),
    ['Settings › (your camera) › Network Information', 'Device Settings › Network › Network Information › Network Settings', 'Settings (the gear) › Network Settings › Set Up']);
  const block = help.manualHelpBlock(view);
  assert.equal(block.localName, 'details');
  assert.ok(!block.open, 'closed until opened');
  assert.equal(tag(block, 'summary')[0].textContent, 'Change it by hand');
  assert.match(block.textContent, /The Reolink app: Settings › \(your camera\) › Network Information\. Set the DNS by hand/);
  const values = tag(block, 'dd').map((node) => byClass(node, 'manual-value')[0].textContent);
  assert.deepEqual(values, ['set by hand, not automatic', BRIDGE, BRIDGE], 'the bridge’s own address to type in');
  assert.match(block.textContent, /On your router: Or have your router hand this camera 192\.168\.77\.28 as its DNS server/);
  assert.equal(tag(tag(block, 'ol')[0], 'li').length, 3, 'the camera’s places are the steps; the router is another way, not a step');
  const order = block.childNodes.map((node) => node.className || node.localName);
  assert.ok(order.indexOf('manual-values') < order.indexOf('manual-router'), 'what to type on the camera comes right after where');
  assert.match(block.textContent, /Then press Check again/);
  assert.match(block.textContent, /Menu names differ between models/);
});

test('a path the bridge does not call confirmed always shows the caveat, even when the bridge left it out; a confirmed one needs none', () => {
  const { caveat, ...bare } = WATCH;
  const view = help.manualHelpView(bare);
  assert.match(view.caveat, /^Menu names differ between models/);
  assert.match(help.manualHelpBlock(view).textContent, /Menu names differ between models/);
  const generic = help.manualHelpView({ why: 'x.', places: [{ app: 'The camera’s web page', path: [], action: 'Open its network settings.' }] });
  assert.match(generic.caveat, /Menu names differ between models/, 'a generic instruction (no path, not confirmed) carries it too');
  const confirmed = help.manualHelpView(CLOUD);
  assert.equal(confirmed.caveat, null);
  assert.ok(!/Menu names differ/.test(help.manualHelpBlock(confirmed).textContent));
});

test('nothing usable is no help; odd entries are left out, and nothing is drawn from markup', () => {
  for (const raw of [null, undefined, 'x', 3, {}, { places: 'no' }, { why: '  ' }]) assert.equal(help.manualHelpView(raw), null, JSON.stringify(raw));
  const view = help.manualHelpView({ why: 'Why.', places: [null, { app: 'A' }, { app: 'B', action: 'Do it.', path: ['x', 3, ' '] }], values: [{ label: 'L' }, { label: 'L', value: 'V' }] });
  assert.deepEqual(view.places, [{ app: 'B', path: ['x'], action: 'Do it.', confirmed: false }]);
  assert.deepEqual(view.values, [{ label: 'L', value: 'V', copy: false }]);
  const block = help.manualHelpBlock(help.manualHelpView({ why: '<b>bold</b>.', places: [] , router: 'r.' }));
  assert.equal(tag(block, 'b').length, 0, 'text stays text');
  assert.equal(help.manualHelpBlock(null), null);
});

// MARK: Pointing the DNS at Camera Bridge by hand

test('the camera’s own page opens from a button, in a new tab that can’t reach back; a camera without one has the app’s path instead', () => {
  const view = help.manualHelpView(HIKVISION);
  assert.deepEqual(view.link, { label: 'Open the camera’s web page', url: 'http://192.168.77.120/' });
  const block = help.manualHelpBlock(view);
  const links = byClass(block, 'manual-link');
  assert.equal(links.length, 1);
  assert.equal(links[0].localName, 'a');
  assert.equal(links[0].textContent, 'Open the camera’s web page');
  assert.equal(links[0].getAttribute('href'), 'http://192.168.77.120/');
  assert.equal(links[0].getAttribute('target'), '_blank');
  assert.equal(links[0].getAttribute('rel'), 'noopener noreferrer');
  const tapo = help.manualHelpBlock(help.manualHelpView(TAPO));
  assert.equal(byClass(tapo, 'manual-link').length, 0, 'a Tapo has no web page');
  assert.match(tapo.textContent, /The Tapo app: \(your camera\) › Device Settings › Advanced Settings › Network Settings › Static IP\./);
});

test('only an http or https address with no one’s name or password in it is a link', () => {
  for (const url of ['javascript:alert(1)', 'data:text/html,x', 'ftp://192.168.77.120/', 'http://admin:pw@192.168.77.120/', '//192.168.77.120/', 'not a url', 3, null]) {
    assert.equal(help.manualHelpView({ ...HIKVISION, link: { label: 'Open the camera’s web page', url } }).link, null, String(url));
  }
  assert.equal(help.manualHelpView({ ...HIKVISION, link: 'http://192.168.77.120/' }).link, null);
  assert.equal(help.manualHelpView({ ...HIKVISION, link: { url: 'https://192.168.77.120:8443/' } }).link.label, 'Open the camera’s web page', 'the page’s own words');
});

test('what it asks now and what to change: “Right now it asks A and B. Change both to C.”', () => {
  const block = help.manualHelpBlock(help.manualHelpView(HIKVISION));
  const line = byClass(block, 'manual-current')[0];
  assert.equal(line.textContent, 'Right now it asks 192.168.77.1 and 192.0.2.53. Change both to 192.168.77.28.');
  assert.equal(help.MANUAL_TEXT.current(['192.168.77.1'], BRIDGE), 'Right now it asks 192.168.77.1. Change both to 192.168.77.28.');
  assert.equal(help.MANUAL_TEXT.current(['192.168.77.1', '192.0.2.53', '192.0.2.54'], BRIDGE),
    'Right now it asks 192.168.77.1, 192.0.2.53 and 192.0.2.54. Change both to 192.168.77.28.');
  const unread = help.manualHelpBlock(help.manualHelpView({ ...HIKVISION, current: [] }));
  assert.equal(byClass(unread, 'manual-current').length, 0, 'not read: nothing said');
});

test('the addresses to type have Copy buttons: the clipboard where the browser has it', async () => {
  const written = [];
  const saved = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  Object.defineProperty(globalThis, 'navigator', { value: { clipboard: { writeText: async (text) => { written.push(text); } } }, configurable: true });
  try {
    const block = help.manualHelpBlock(help.manualHelpView(HIKVISION));
    const buttons = byClass(block, 'manual-copy');
    assert.equal(buttons.length, 2, 'the two DNS servers, not the mode');
    assert.ok(buttons.every((button) => button.localName === 'button' && button.getAttribute('type') === 'button' && button.textContent === 'Copy'));
    assert.equal(buttons[0].getAttribute('aria-label'), 'Copy Preferred DNS server');
    buttons[0].click();
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.deepEqual(written, [BRIDGE]);
    assert.equal(buttons[0].textContent, 'Copied');
  } finally {
    Object.defineProperty(globalThis, 'navigator', saved);
  }
});

test('without the clipboard (the box’s page is plain HTTP), Copy selects the value, and copies it where the browser still can', async () => {
  const value = help.manualHelpBlock(help.manualHelpView(HIKVISION));
  const target = byClass(value, 'manual-value')[1];
  const selected = [];
  const selection = { removeAllRanges() { selected.length = 0; }, addRange(range) { selected.push(range.node); } };
  const range = () => ({ node: null, selectNodeContents(node) { this.node = node; } });
  assert.equal(await help.copyText(BRIDGE, target, { clipboard: undefined, selection, range, exec: () => false }), 'selected');
  assert.deepEqual(selected, [target], 'the value alone, ready to copy');
  assert.equal(await help.copyText(BRIDGE, target, { clipboard: undefined, selection, range, exec: (command) => command === 'copy' }), 'copied');
  const refused = { writeText: async () => { throw new Error('NotAllowedError'); } };
  assert.equal(await help.copyText(BRIDGE, target, { clipboard: refused, selection, range, exec: () => false }), 'selected', 'a refused clipboard too');
  assert.equal(await help.copyText(BRIDGE, target, { clipboard: undefined, selection: null, range, exec: () => false }), 'failed');
  assert.equal(help.MANUAL_TEXT.copied, 'Copied');
  assert.match(help.MANUAL_TEXT.selected, /^Selected/);
});

test('a camera whose DNS stays only with a fixed address: keep its address as it is, and reserve it in the router', () => {
  const block = help.manualHelpBlock(help.manualHelpView(HIKVISION));
  assert.equal(byClass(block, 'manual-keep')[0].textContent, 'Keep its address as it is: 192.168.77.120, mask 255.255.255.0, gateway 192.168.77.1.');
  assert.equal(byClass(block, 'manual-reserve')[0].textContent,
    'Reserve 192.168.77.120 for this camera in your router (its hardware address is 02:00:00:00:00:21).');
  const bare = help.manualHelpView({ ...HIKVISION, keep: { address: '192.168.77.120' }, reserve: { address: '192.168.77.120' } });
  assert.equal(byClass(help.manualHelpBlock(bare), 'manual-keep')[0].textContent, 'Keep its address as it is: 192.168.77.120.');
  assert.equal(byClass(help.manualHelpBlock(bare), 'manual-reserve')[0].textContent, 'Reserve 192.168.77.120 for this camera in your router.');
  const odd = help.manualHelpView({ ...HIKVISION, keep: { address: 'x', mask: '255.255.255.0' }, reserve: { address: '192.168.77.120', mac: 'nope' } });
  assert.equal(odd.keep, null, 'not an address: no line');
  assert.deepEqual(odd.reserve, { address: '192.168.77.120', mac: null });
  assert.equal(byClass(help.manualHelpBlock(help.manualHelpView(WATCH)), 'manual-keep').length, 0, 'a Reolink keeps its DNS on DHCP');
});

test('the warnings that apply are listed', () => {
  const block = help.manualHelpBlock(help.manualHelpView(TAPO));
  const items = tag(byClass(block, 'manual-warnings')[0], 'li').map((node) => node.textContent);
  assert.deepEqual(items, TAPO.warnings);
  assert.ok(items.some((text) => /factory reset/.test(text)));
});

test('nothing the bridge sends for the DNS help becomes markup', () => {
  const evil = '<img src=x onerror=alert(1)>';
  const block = help.manualHelpBlock(help.manualHelpView({ ...HIKVISION, current: [evil], warnings: [evil], link: { label: evil, url: 'http://192.168.77.120/' },
    reserve: { address: '192.168.77.120', mac: evil }, values: [{ label: evil, value: evil, copy: true }] }));
  assert.equal(tag(block, 'img').length, 0);
  assert.ok(block.textContent.includes(evil), 'shown as text');
  assert.equal(byClass(block, 'manual-link')[0].textContent, evil);
});

// MARK: Set up for Camera Bridge

test('a step the camera refused or does not support shows the bridge’s help under it in the dialog', () => {
  const report = { steps: [
    { id: 'timeSource', title: 'Time from the bridge', status: 'refused', detail: 'the camera refused the login', manualHelp: { ...WATCH, values: [{ label: 'NTP server', value: BRIDGE }] } },
    { id: 'cloud', title: 'Cloud off', status: 'notSupported', manualHelp: CLOUD },
    { id: 'timeZone', title: 'Time zone', status: 'alreadyRight' },
  ] };
  assert.equal(setup.describeStep(report.steps[2]).manual, null);
  assert.equal(setup.describeStep(report.steps[1]).manual.places[0].confirmed, true);
  const list = setup.stepList(report);
  const items = tag(list, 'li').filter((node) => node.parentNode === list);
  assert.equal(items.length, 3);
  assert.equal(byClass(items[0], 'manual-help').length, 1, 'the refused step');
  assert.match(items[0].textContent, /NTP server/);
  assert.match(items[0].textContent, /The camera refused the login\./, 'the step’s own words stay');
  assert.equal(byClass(items[1], 'manual-help').length, 1, 'the step not supported');
  assert.match(items[1].textContent, /Configuration › Services Security › P2P/);
  assert.equal(byClass(items[2], 'manual-help').length, 0, 'a step already right has none');
});

// MARK: The Security card

const ID = '0A1B2C3D-0000-4000-8000-000000000009';
const finding = (feature, state, level, sentence, extra = {}) => ({ feature, state, level, sentence, canChange: false, linked: null, service: null, manualHelp: null, ...extra });
const NOT_WATCHED = finding('internetGuard', 'off', 'green', 'The Internet guard doesn’t watch this camera, so Camera Bridge can’t confirm that nothing gets out.',
  { manualHelp: WATCH });
const security = (findings, watched = false) => ({ level: 'red', title: 'Outside access possible', summary: 'Something on this camera can let it be reached from outside your home.',
  checkedAt: '2026-10-18T16:00:00Z', findings, guard: { watched, today: 0, last24h: 0, names: [] } });
const camera = (sec, overrides = {}) => ({ id: ID, name: 'Doorbell', vendor: 'reolink', isEnabled: true, endpoint: { host: '192.168.77.120' },
  status: { connection: 'online', security: sec }, ...overrides });
function securityCard(value, { canSetUp = true } = {}) {
  return sec.createSecurityCard(camera(value), { canSetUp, openSetup: () => Promise.resolve('cancelled'), now: () => Date.parse('2026-10-18T16:05:00Z'),
    checks: sec.createSecurityChecks({ send: () => new Promise(() => {}), apply: () => {} }) });
}

test('not watched: the guard’s section says how to point the camera’s DNS at Camera Bridge by hand, with the bridge’s address', () => {
  const { el } = securityCard(security([finding('upnp', 'off', 'gold', 'UPnP is off.'), NOT_WATCHED]));
  const guard = byClass(el, 'sec-guard')[0];
  const blocks = byClass(guard, 'manual-help');
  assert.equal(blocks.length, 1);
  assert.equal(tag(blocks[0], 'summary')[0].textContent, 'Point its DNS at Camera Bridge yourself');
  assert.match(blocks[0].textContent, new RegExp(BRIDGE.replaceAll('.', '\\.')));
  assert.match(blocks[0].textContent, /Menu names differ between models/);
  assert.match(blocks[0].textContent, /Then press Check again/);
  assert.equal(byClass(blocks[0], 'manual-link')[0].getAttribute('href'), 'http://192.168.77.31/', 'the doorbell’s own page');
  assert.match(blocks[0].textContent, /Right now it asks 192\.168\.77\.1 and 192\.0\.2\.53\. Change both to 192\.168\.77\.28\./);
  assert.equal(byClass(blocks[0], 'manual-copy').length, 2);
  const cant = securityCard(security([NOT_WATCHED]), { canSetUp: false });
  assert.equal(byClass(byClass(cant.el, 'sec-guard')[0], 'manual-help').length, 1, 'also where the setup does not work with the camera');
});

test('a watched camera’s guard shows no DNS help, and the view keeps the help for each finding', () => {
  const watched = securityCard(security([{ ...NOT_WATCHED, state: 'on', level: 'gold', sentence: 'The Internet guard has watched it for the last 24 hours and saw it make no internet lookups.', manualHelp: null }], true));
  assert.equal(byClass(watched.el, 'manual-help').length, 0);
  const view = sec.securityView(camera(security([finding('upnp', 'on', 'red', 'UPnP is on, so the camera can open ports on your router to the internet.', { manualHelp: CLOUD }), NOT_WATCHED])));
  assert.equal(view.findings[0].manual.places[0].action, 'Turn off Enable Mobile Monitoring.');
  assert.equal(view.guard.manual.values[1].value, BRIDGE);
});

test('a finding the setup can’t change shows its help under its sentence', () => {
  const { el } = securityCard(security([finding('upnp', 'on', 'red', 'UPnP is on, so the camera can open ports on your router to the internet.', { manualHelp: CLOUD }),
    finding('cloud', 'on', 'red', 'The maker’s cloud is on.', { canChange: true })]));
  const items = byClass(el, 'sec-finding');
  assert.equal(byClass(items[0], 'manual-help').length, 1);
  assert.match(items[0].textContent, /Configuration › Services Security › P2P/);
  assert.equal(byClass(items[1], 'manual-help').length, 0, 'what the setup can change has “Fix with Set up for Camera Bridge” instead');
});

test('a help someone opened stays open when the card draws again (a new check, the next minute)', () => {
  const findings = [finding('upnp', 'on', 'red', 'UPnP is on, so the camera can open ports on your router to the internet.', { manualHelp: CLOUD }), NOT_WATCHED];
  const handle = securityCard(security(findings));
  const toggle = (block, open) => { block.open = open; block.dispatchEvent({ type: 'toggle', target: block }); };
  const guardHelp = () => byClass(byClass(handle.el, 'sec-guard')[0], 'manual-help')[0];
  const findingHelp = () => byClass(byClass(handle.el, 'sec-finding')[0], 'manual-help')[0];
  toggle(guardHelp(), true);
  toggle(findingHelp(), true);
  handle.update(camera({ ...security(findings), checkedAt: '2026-10-18T16:04:00Z' }));
  assert.equal(guardHelp().open, true, 'the guard’s help');
  assert.equal(findingHelp().open, true, 'the finding’s help');
  toggle(findingHelp(), false);
  handle.update(camera({ ...security(findings), checkedAt: '2026-10-18T16:05:00Z' }));
  assert.ok(!findingHelp().open, 'and closed once closed');
  assert.equal(guardHelp().open, true);
});

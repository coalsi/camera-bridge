// "Change it by hand" on the page (screens/manual-help.js): the bridge's help for a step of Set up for Camera Bridge the camera refused or does
// not support (camera-setup.js) and for the Security card's findings, the Internet guard's "Not watched" among them (security.js). A menu path
// the bridge does not call confirmed always shows "Menu names differ between models", in the fake browser.
import assert from 'node:assert/strict';
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

const BRIDGE = '192.168.77.28';
/** What the bridge sends for the Reolink doorbell's Watch (CameraManualHelpText): unconfirmed places, the router's way, Check again. */
const WATCH = {
  why: `The Internet guard sees a camera’s lookups only while its DNS asks Camera Bridge (${BRIDGE}) and nothing else.`,
  places: [
    { app: 'The Reolink app', path: ['Settings', '(your camera)', 'Network Information'], action: 'Set the DNS by hand (not automatic) to the servers below.', confirmed: false },
    { app: 'The Reolink Client (on a computer)', path: ['Device Settings', 'Network', 'Network Information'], action: 'Set the DNS by hand (not automatic) to the servers below.', confirmed: false },
  ],
  values: [{ label: 'DNS', value: 'set by hand, not automatic' }, { label: 'Preferred DNS server', value: BRIDGE }, { label: 'Alternate DNS server', value: BRIDGE }],
  router: `Or give the camera a fixed address (a DHCP reservation) and have your router hand that camera ${BRIDGE} as its DNS server.`,
  then: 'Then press Check again on the camera’s Security card.',
  caveat: 'Menu names differ between models and firmware versions, so look for the closest match.',
};
/** A confirmed path (the IPCamera Web family's own page). */
const CLOUD = {
  why: 'The camera didn’t take the change.',
  places: [{ app: 'The camera’s web page', path: ['Configuration', 'Services Security', 'P2P'], action: 'Turn off Enable Mobile Monitoring.', confirmed: true }],
  values: [{ label: 'Enable Mobile Monitoring', value: 'off' }],
};

test('the bridge’s help reads as why, where (each menu joined by ›), what to set, the router’s way and what to do next', () => {
  const view = help.manualHelpView(WATCH);
  assert.equal(view.why, WATCH.why);
  assert.deepEqual(view.places.map((place) => place.path.join(' › ')), ['Settings › (your camera) › Network Information', 'Device Settings › Network › Network Information']);
  const block = help.manualHelpBlock(view);
  assert.equal(block.localName, 'details');
  assert.ok(!block.open, 'closed until opened');
  assert.equal(tag(block, 'summary')[0].textContent, 'Change it by hand');
  assert.match(block.textContent, /The Reolink app: Settings › \(your camera\) › Network Information\. Set the DNS by hand/);
  const values = tag(block, 'dd').map((node) => node.textContent);
  assert.deepEqual(values, ['set by hand, not automatic', BRIDGE, BRIDGE], 'the bridge’s own address to type in');
  assert.match(block.textContent, /On your router: Or give the camera a fixed address/);
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
  assert.deepEqual(view.values, [{ label: 'L', value: 'V' }]);
  const block = help.manualHelpBlock(help.manualHelpView({ why: '<b>bold</b>.', places: [] , router: 'r.' }));
  assert.equal(tag(block, 'b').length, 0, 'text stays text');
  assert.equal(help.manualHelpBlock(null), null);
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

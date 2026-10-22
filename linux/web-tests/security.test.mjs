// The security levels on the page (screens/security.js): what status.security reads as, the badge and its one-line summary on the Cameras
// page with the legend under the table, the camera page's Security card (its findings, "Check again", "Fix with Set up for Camera Bridge",
// the Internet guard), the Monitor's dot beside each name, and the colours in both themes, in the fake browser with fake requests.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';
import { ApiError } from '../web/js/api.js';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let sec;
let store;
before(async () => {
  browser = installFakeBrowser();
  sec = await import('../web/js/screens/security.js');
  store = await import('../web/js/store.js');
});
after(() => browser?.restore());

const ID = '0A1B2C3D-0000-4000-8000-000000000004';
const NOW = Date.parse('2026-10-17T15:00:00Z');
const ago = (minutes) => new Date(NOW - minutes * 60_000).toISOString();

const finding = (feature, state, level, sentence, { canChange = false, linked = null, service = null } = {}) =>
  ({ feature, state, level, sentence, canChange, linked, service });
const QUIET = finding('internetGuard', 'on', 'gold', 'The Internet guard has watched it for the last 24 hours and saw it make no internet lookups.');
const NOT_WATCHED = finding('internetGuard', 'off', 'green', 'The Internet guard doesn’t watch this camera, so Camera Bridge can’t confirm that nothing gets out.');
const NO_GUARD = finding('internetGuard', 'absent', 'green', 'This bridge can’t watch the camera’s internet traffic, so Camera Bridge can’t confirm that nothing gets out.');
const TRYING = finding('internetGuard', 'on', 'gold',
  'The Internet guard blocked 112 attempts to reach the internet in the last 24 hours (*.p2p.example.com, cloud.example.net). Nothing got out.');

const SECURITY = {
  red: { level: 'red', title: 'Outside access possible', summary: 'Something on this camera can let it be reached from outside your home.', checkedAt: ago(180),
    findings: [
      finding('cloud', 'on', 'red', 'Hik-Connect is on and linked to an account, so the camera can be reached from outside your home.', { canChange: true, linked: true, service: 'Hik-Connect' }),
      finding('upnp', 'on', 'red', 'UPnP is on, so the camera can open ports on your router to the internet.', { canChange: true }),
      finding('unauthenticatedVideo', 'off', 'gold', 'Its video needs a password.'),
      QUIET,
    ],
    guard: { watched: true, today: 0, last24h: 0, names: [] } },
  yellow: { level: 'yellow', title: 'Needs work', summary: 'Nothing Camera Bridge read opens this camera to the outside, but something needs work.', checkedAt: ago(30),
    findings: [
      finding('cloud', 'unknown', 'yellow', 'Camera Bridge can’t read whether the maker’s cloud is on.'),
      finding('unauthenticatedVideo', 'on', 'yellow', 'Its video plays without a password on your home network.', { canChange: true }),
      TRYING,
    ],
    guard: { watched: true, today: 47, last24h: 112, last7d: 340, names: [
      { name: 'cloud.example.net', count: 75, last: ago(120) },
      { name: '*.p2p.example.com', count: 290, last: ago(4) },
      { name: 'update.example.org', count: 3, last: null },
      { name: 'time.example.org', count: 21, last: ago(1200) },
    ] } },
  green: { level: 'green', title: 'Good', summary: 'Camera Bridge found no cloud turned on, but it can’t confirm everything, so a way out is still possible.', checkedAt: ago(5),
    findings: [
      finding('ddns', 'unknown', 'green', 'Camera Bridge can’t read whether dynamic DNS is on.'),
      NOT_WATCHED,
      finding('cloud', 'off', 'gold', 'Hik-Connect is off.', { canChange: true, linked: false, service: 'Hik-Connect' }),
    ],
    guard: { watched: false, today: 0, last24h: 0, names: [] } },
  gold: { level: 'gold', title: 'Local only',
    summary: 'Every outside feature Camera Bridge knows for this camera is off, its video needs a password, and the Internet guard saw nothing get out in the last 24 hours.',
    checkedAt: ago(60),
    findings: [finding('cloud', 'off', 'gold', 'VisionEye cloud is off.', { canChange: true, service: 'VisionEye cloud' }), finding('unauthenticatedVideo', 'off', 'gold', 'Its video needs a password.'), QUIET],
    guard: { watched: true, today: 0, last24h: 0, names: [] } },
};

const camera = (security, overrides = {}) => ({
  id: ID, name: 'Back Yard', vendor: 'onvif', isEnabled: true, endpoint: { host: '192.0.2.14' },
  status: { connection: 'online', ...(security === undefined ? {} : { security }) }, ...overrides,
});

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList.contains(name));
const one = (root, name) => byClass(root, name)[0];
const buttons = (root) => all(root, (node) => node.localName === 'button');
const button = (root, text) => buttons(root).find((node) => node.textContent.includes(text));
const visible = (node, root) => { for (let n = node; n && n !== root?.parentNode; n = n.parentNode) if (n.hidden) return false; return true; };
const settle = () => new Promise((resolve) => setImmediate(resolve));
const nodesText = (nodes) => nodes.filter(Boolean).map((node) => node.textContent).join(' | ');

/** Fake requests: each check waits until the test answers it (`answer(value)` or `fail(error)`). */
function fakeBridge() {
  const sent = [];
  const applied = [];
  const waiting = [];
  const deps = {
    send: (path) => new Promise((resolve, reject) => { sent.push(path); waiting.push({ resolve, reject }); }),
    apply: (value) => applied.push(value),
  };
  return {
    deps, sent, applied,
    answer: async (value) => { waiting.shift().resolve(value); await settle(); },
    fail: async (error) => { waiting.shift().reject(error); await settle(); },
  };
}

// MARK: What status.security reads as

test('a camera reads as no level until its first check (the bridge leaves the key out), and as its level once checked', () => {
  assert.equal(sec.securityView(null), null);
  assert.equal(sec.securityView(camera(undefined)), null);
  assert.equal(sec.securityView(camera(null)), null);
  assert.equal(sec.securityView(camera({ ...SECURITY.gold, level: 'sealed' })), null, 'a level the page does not know is not guessed');
  for (const level of sec.SECURITY_LEVELS) {
    const view = sec.securityView(camera(SECURITY[level]));
    assert.equal(view.level, level);
    assert.equal(view.word, SECURITY[level].title, 'the page uses the bridge’s words for the level');
    assert.equal(view.summary, SECURITY[level].summary);
    assert.equal(view.checkedAt, Date.parse(SECURITY[level].checkedAt));
  }
  assert.deepEqual(sec.SECURITY_LEVELS, ['red', 'yellow', 'green', 'gold'], 'worst first');
});

test('the findings keep the bridge’s order without the guard’s; what the setup can change and is not yet right is fixable', () => {
  const red = sec.securityView(camera(SECURITY.red));
  assert.deepEqual(red.findings.map((entry) => entry.feature), ['cloud', 'upnp', 'unauthenticatedVideo']);
  assert.deepEqual(red.fixable.map((entry) => entry.feature), ['cloud', 'upnp']);
  const green = sec.securityView(camera(SECURITY.green));
  assert.deepEqual(green.fixable, [], 'a cloud already off is not something to fix, though the setup could change it');
  assert.equal(green.findings.find((entry) => entry.feature === 'cloud').fixable, false);
  const odd = sec.securityView(camera({ ...SECURITY.red, findings: [{ feature: 'cloud' }, null, 'x', ...SECURITY.red.findings] }));
  assert.equal(odd.findings.length, 3, 'a finding without a sentence is left out');
});

test('the guard: watched or not, today and 24 h, the names newest first (a name never seen last goes last); none on a bridge without it', () => {
  const trying = sec.securityView(camera(SECURITY.yellow)).guard;
  assert.deepEqual([trying.onBridge, trying.watched, trying.today, trying.last24h, trying.last7d], [true, true, 47, 112, 340]);
  assert.deepEqual(trying.names.map((entry) => entry.name), ['*.p2p.example.com', 'cloud.example.net', 'time.example.org', 'update.example.org']);
  assert.equal(trying.sentence, TRYING.sentence);
  const notWatched = sec.securityView(camera(SECURITY.green)).guard;
  assert.deepEqual([notWatched.onBridge, notWatched.watched], [true, false]);
  const mac = sec.securityView(camera({ ...SECURITY.green, guard: null, findings: [NO_GUARD] })).guard;
  assert.deepEqual([mac.onBridge, mac.watched, mac.names], [false, false, []]);
  assert.equal(mac.sentence, NO_GUARD.sentence);
  const bad = sec.securityView(camera({ ...SECURITY.yellow, guard: { watched: true, today: -3, last24h: 'x', names: 'no' } })).guard;
  assert.deepEqual([bad.today, bad.last24h, bad.last7d, bad.names], [0, 0, 0, []]);
});

test('the levels and the guard use the bridge’s words (BridgeEngine CameraSecurityLevel.title and InternetGuardText)', (t) => {
  const engine = new URL('../../Packages/CameraBridgeKit/Sources/BridgeEngine/Security/', import.meta.url);
  if (!existsSync(new URL('CameraSecurity.swift', engine))) { t.skip('the Swift sources are not here'); return; }
  const levels = readFileSync(new URL('CameraSecurity.swift', engine), 'utf8');
  const titles = levels.slice(levels.indexOf('public var title: String'));
  for (const level of sec.SECURITY_LEVELS) {
    assert.match(titles, new RegExp(`case \\.${level}: "${sec.SECURITY_TEXT.levels[level]}"`), `${level} is “${sec.SECURITY_TEXT.levels[level]}” in the engine`);
  }
  const guard = readFileSync(new URL('InternetGuard.swift', engine), 'utf8');
  for (const key of ['name', 'watch', 'seal', 'watchStep', 'sealStep', 'notOnThisBridge', 'notOnItsNetwork']) {
    assert.ok(guard.includes(`static let ${key} = "${sec.GUARD_TEXT[key]}"`), `InternetGuardText.${key} is “${sec.GUARD_TEXT[key]}”`);
  }
});

// MARK: The badge, the Cameras page and the legend

test('each level’s badge is a shield in its colour with the level’s word, never the colour alone', () => {
  for (const level of sec.SECURITY_LEVELS) {
    const badge = sec.securityBadge(level);
    assert.equal(badge.dataset.level, level);
    assert.ok(badge.textContent.includes(sec.SECURITY_TEXT.levels[level]), 'the word is shown');
    assert.equal(badge.getAttribute('title'), `Security: ${sec.SECURITY_TEXT.levels[level]}`);
    const shield = all(badge, (node) => node.localName === 'svg')[0];
    assert.equal(shield.getAttribute('aria-hidden'), 'true', 'the shield is decoration: the word says it');
    assert.ok(all(shield, (node) => node.getAttribute('class') === 'sec-shield-mark').length > 0, 'each level has its own mark in the shield');
  }
  assert.equal(sec.securityBadge('purple'), null);
  const named = sec.securityBadge('gold', { prefix: true });
  assert.equal(one(named, 'sr-only').textContent, 'Security: ', 'beside a name, a screen reader hears what the badge is about');
});

test('the Cameras page’s cell: the badge and the bridge’s one-line summary; “Checking…” or nothing before the first check', () => {
  const red = sec.securityCell(camera(SECURITY.red));
  assert.equal(red[0].dataset.level, 'red');
  assert.equal(red[1].textContent, SECURITY.red.summary);
  assert.ok(red[1].classList.contains('sec-summary'));
  assert.equal(red[1].getAttribute('title'), SECURITY.red.summary, 'the whole summary is there when it is cut to two lines');
  assert.equal(nodesText(sec.securityCell(camera(undefined))), 'Checking…', 'an online camera is checked soon');
  assert.equal(nodesText(sec.securityCell(camera(undefined, { status: { connection: 'connecting' } }))), 'Checking…');
  assert.deepEqual(sec.securityCell(camera(undefined, { isEnabled: false, status: { connection: 'disabled' } })), [], 'a camera that is off shows nothing');
  assert.deepEqual(sec.securityCell(camera(undefined, { status: { connection: 'offline' } })), []);
  assert.deepEqual(sec.securityCell(camera(undefined, { vendor: 'demo' })), [], 'the demo camera is never checked');
});

test('the legend says what each colour means in the owner’s words, best first, and what “Checking…” is', () => {
  const legend = sec.securityLegend();
  assert.equal(legend.localName, 'details');
  assert.equal(all(legend, (node) => node.localName === 'summary')[0].textContent, 'What do the colours mean?');
  const terms = all(legend, (node) => node.localName === 'dt');
  const meanings = all(legend, (node) => node.localName === 'dd').map((node) => node.textContent);
  assert.deepEqual(terms.slice(0, 4).map((node) => node.firstChild.dataset.level), ['gold', 'green', 'yellow', 'red']);
  assert.deepEqual(meanings.slice(0, 4), [
    'Gold. Camera Bridge found no way in from outside, and its Internet guard saw nothing get out for a full day and has seen at least one lookup from it.',
    'Green. Its cloud is off; something Camera Bridge can’t confirm remains.',
    'Yellow. Camera Bridge found nothing that lets it in from outside, but something needs work: its cloud is on but not linked, its video plays '
      + 'without a password on your network, or Camera Bridge can’t read its cloud.',
    'Red. Its cloud, UPnP, dynamic DNS or RTMP push is on, or it only works through its maker’s cloud.',
  ]);
  assert.ok(!/Nobody is watching/.test(legend.textContent), 'nothing Camera Bridge could not confirm is promised');
  assert.equal(terms[4].textContent, 'Checking…');
  assert.match(meanings[4], /^Not checked yet\./);
  assert.match(meanings[4], /a minute after it starts/, 'when a check really happens');
  assert.match(meanings[4], /turned off isn’t checked: it keeps the level of its last check/, 'a camera turned off keeps its last level; it does not show nothing');
  assert.match(legend.textContent, /without it, Good is the best/, 'gold needs the guard: a bridge without it says so');
});

test('the Cameras page has a Security column after Status, each row’s badge, and the legend under the table', async () => {
  const observed = [];
  globalThis.IntersectionObserver = class { constructor() {} observe(el) { observed.push(el); } disconnect() {} };
  const { renderCameras } = await import('../web/js/screens/cameras.js');
  store.store.cameras = new Map([
    ['a', { ...camera(SECURITY.red), id: 'a', name: 'Front Door', kind: 'doorbell' }],
    ['b', { ...camera(undefined), id: 'b', name: 'Garage', kind: 'camera' }],
  ]);
  const screen = renderCameras();
  try {
    const heads = all(screen.el, (node) => node.localName === 'th').map((node) => node.textContent);
    assert.deepEqual(heads.slice(0, 4), ['Camera', 'Status', 'Security', 'Video']);
    const cells = all(screen.el, (node) => node.localName === 'td' && node.dataset.label === 'Security');
    assert.equal(cells.length, 2);
    assert.equal(one(cells[0], 'sec-badge').dataset.level, 'red');
    assert.equal(cells[1].textContent, 'Checking…');
    assert.equal(byClass(screen.el, 'sec-legend').length, 1);
    store.putCamera({ ...camera(SECURITY.gold), id: 'b', name: 'Garage', kind: 'camera' });
    const updated = all(screen.el, (node) => node.localName === 'td' && node.dataset.label === 'Security')[1];
    assert.equal(one(updated, 'sec-badge').dataset.level, 'gold', 'the row follows the camera in place');
  } finally {
    screen.destroy();
    store.store.cameras = new Map();
    delete globalThis.IntersectionObserver;
  }
});

// MARK: The camera page's card

const card = (security, options = {}) => {
  const bridge = fakeBridge();
  const opened = [];
  const handle = sec.createSecurityCard(camera(security, options.camera), {
    canSetUp: options.canSetUp ?? true,
    openSetup: options.openSetup === null ? null : () => { opened.push('setup'); return Promise.resolve('cancelled'); },
    routerHelp: options.routerHelp,
    restart: options.restart,
    checks: sec.createSecurityChecks(bridge.deps),
    now: () => NOW,
    setTimer: options.setTimer,
  });
  return { ...handle, bridge, opened };
};

test('the card shows the level, the summary, when it was checked, and each finding in plain words with its level said', () => {
  const { el } = card(SECURITY.red);
  assert.equal(one(el, 'sec-badge').dataset.level, 'red');
  assert.ok(el.textContent.includes(SECURITY.red.summary));
  assert.match(one(el, 'sec-checked').textContent, /Checked 3 hours ago\./);
  const items = byClass(el, 'sec-finding');
  assert.deepEqual(items.map((item) => one(item, 'sec-mark').dataset.level), ['red', 'red', 'gold']);
  assert.equal(one(items[0], 'sr-only').textContent, 'Outside access possible: ', 'the mark’s colour is said in words');
  assert.ok(items[0].textContent.includes('Hik-Connect is on and linked to an account'));
  assert.ok(items[0].textContent.includes('Set up for Camera Bridge can change this.'));
  assert.ok(!items[2].textContent.includes('can change this'), 'what is already right needs no change');
  assert.ok(!items.some((item) => item.textContent.includes(QUIET.sentence)), 'the guard’s finding is in the guard’s section, not the list');
  assert.ok(one(el, 'sec-guard').textContent.includes(QUIET.sentence));
  assert.equal(button(el, 'Check again').hidden, false);
});

test('a camera not checked yet says so and offers “Check now”; one turned off offers nothing; the demo camera has no card', () => {
  const fresh = card(undefined).el;
  assert.match(fresh.textContent, /Not checked yet/);
  assert.equal(byClass(fresh, 'sec-badge').length, 0);
  assert.equal(button(fresh, 'Check now').hidden, false);
  assert.equal(byClass(fresh, 'sec-finding').length, 0);
  const off = card(undefined, { camera: { isEnabled: false, status: { connection: 'disabled' } } }).el;
  assert.equal(button(off, 'Check now').hidden, true);
  assert.match(off.textContent, /Turn the camera on to check it/);
  assert.equal(card(undefined, { camera: { vendor: 'demo' } }).el.hidden, true);
});

test('“Check again” asks the bridge once, says it is checking, and shows the new level from the answer', async () => {
  const handle = card(SECURITY.yellow);
  const again = button(handle.el, 'Check again');
  again.click();
  assert.deepEqual(handle.bridge.sent, [`cameras/${ID}/security/check`]);
  assert.equal(again.getAttribute('aria-disabled'), 'true', 'the button keeps its place and the keyboard while the camera answers');
  assert.equal(one(handle.el, 'save-state').textContent, 'Checking…');
  again.click();
  assert.equal(handle.bridge.sent.length, 1, 'a second press while checking sends nothing');
  await handle.bridge.answer({ ...SECURITY.gold, checkedAt: new Date(NOW).toISOString() });
  assert.equal(again.getAttribute('aria-disabled'), null);
  assert.equal(one(handle.el, 'save-state').textContent, 'Checked: Local only.');
  assert.equal(one(handle.el, 'sec-badge').dataset.level, 'gold');
  assert.match(one(handle.el, 'sec-checked').textContent, /Checked just now\./);
  assert.equal(handle.bridge.applied.length, 1, 'the camera with its new level goes to the store');
  assert.equal(handle.bridge.applied[0].status.security.level, 'gold');
  assert.equal(handle.bridge.applied[0].status.connection, 'online', 'nothing else of the camera changes');
});

test('a finished check goes into the store’s camera as it is then, not the one from when the button was pressed', async () => {
  const stored = new Map();
  const bridge = fakeBridge();
  const checks = sec.createSecurityChecks({ ...bridge.deps, current: (id) => stored.get(id) });
  stored.set(ID, camera(SECURITY.yellow, { status: { connection: 'connecting', security: SECURITY.yellow } }));
  const pending = checks.check(stored.get(ID));
  // Meanwhile the camera came online and was renamed (the event stream delivered it).
  stored.set(ID, camera(SECURITY.yellow, { name: 'Back Garden', status: { connection: 'online', security: SECURITY.yellow } }));
  await bridge.answer({ ...SECURITY.gold, checkedAt: new Date(NOW).toISOString() });
  const result = await pending;
  assert.equal(bridge.applied.length, 1);
  assert.deepEqual([bridge.applied[0].name, bridge.applied[0].status.connection, bridge.applied[0].status.security.level], ['Back Garden', 'online', 'gold']);
  assert.equal(result.camera, bridge.applied[0]);
});

test('a finished check says the new level out loud; an error goes once a newer result arrives or the wait it named is over', async () => {
  const handle = card(SECURITY.green);
  button(handle.el, 'Check again').click();
  await handle.bridge.answer({ ...SECURITY.gold, checkedAt: new Date(NOW).toISOString() });
  assert.equal(one(handle.el, 'save-state').textContent, 'Checked: Local only.', 'a screen reader hears the result, not only “Checking…”');

  const timers = [];
  const late = card(SECURITY.green, { setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length; } });
  button(late.el, 'Check again').click();
  await late.bridge.fail(new ApiError(429, 'security_check_too_soon', 'This camera was checked less than a minute ago. Try again in 42 s.', null, { retryAfter: 42 }));
  assert.match(one(late.el, 'sec-problem').textContent, /checked less than a minute ago/);
  assert.deepEqual(timers.map((timer) => timer.ms), [42_000], 'the wait the bridge named');
  timers[0].fn();
  assert.equal(one(late.el, 'sec-problem').textContent, '', 'gone once it is over');

  const slow = card(SECURITY.green);
  button(slow.el, 'Check again').click();
  await slow.bridge.fail(new ApiError(504, 'timeout', 'The bridge took too long to answer.'));
  assert.match(one(slow.el, 'sec-problem').textContent, /took too long/);
  slow.update(camera({ ...SECURITY.green, checkedAt: ago(10) }));
  assert.match(one(slow.el, 'sec-problem').textContent, /took too long/, 'an older result does not clear it');
  slow.update(camera({ ...SECURITY.red, checkedAt: new Date(NOW + 1000).toISOString() }));
  assert.equal(one(slow.el, 'sec-problem').textContent, '', 'the engine’s result came through the event stream');
  assert.equal(one(slow.el, 'sec-badge').dataset.level, 'red');
});

test('a check the bridge refuses shows its sentence (too soon, offline); an answer that isn’t a level changes nothing', async () => {
  const handle = card(SECURITY.green);
  button(handle.el, 'Check again').click();
  await handle.bridge.fail(new ApiError(429, 'security_check_too_soon', 'This camera was checked less than a minute ago. Try again in a minute.', null, { retryAfter: 42 }));
  assert.match(one(handle.el, 'sec-problem').textContent, /checked less than a minute ago/);
  assert.equal(one(handle.el, 'sec-badge').dataset.level, 'green', 'the last level stays');
  button(handle.el, 'Check again').click();
  await handle.bridge.answer({ level: 'unknown' });
  assert.match(one(handle.el, 'sec-problem').textContent, /The check didn’t finish/);
  assert.equal(handle.bridge.applied.length, 0);
  button(handle.el, 'Check again').click();
  await handle.bridge.fail(new TypeError('x is undefined'));
  assert.equal(one(handle.el, 'sec-problem').textContent, sec.SECURITY_TEXT.failed, 'a script’s own error text is never shown');
  assert.equal(sec.securityErrorText(new ApiError(409, 'camera_offline', 'The camera isn’t answering, so it can’t be checked now.')),
    'The camera isn’t answering, so it can’t be checked now.');
});

test('“Fix with Set up for Camera Bridge” is there for what the setup can change, and opens the setup', () => {
  const red = card(SECURITY.red);
  const fix = button(red.el, 'Fix with Set up for Camera Bridge');
  assert.ok(fix && visible(fix, red.el));
  fix.click();
  assert.deepEqual(red.opened, ['setup']);
  const green = card(SECURITY.green);
  assert.ok(!visible(button(green.el, 'Fix with Set up for Camera Bridge'), green.el), 'nothing to fix');
  const rtsp = card(SECURITY.red, { canSetUp: false });
  assert.ok(!visible(button(rtsp.el, 'Fix with Set up for Camera Bridge'), rtsp.el), 'a camera the setup does not work with is not offered it');
  assert.ok(!rtsp.el.textContent.includes('Set up for Camera Bridge can change this.'));
});

test('the card follows the camera in place; a camera from elsewhere is ignored', () => {
  const handle = card(SECURITY.green);
  const again = button(handle.el, 'Check again');
  handle.update(camera(SECURITY.red));
  assert.equal(one(handle.el, 'sec-badge').dataset.level, 'red');
  assert.equal(button(handle.el, 'Check again'), again, 'the button is not rebuilt (it keeps the keyboard)');
  handle.update({ ...camera(SECURITY.gold), id: 'other' });
  assert.equal(one(handle.el, 'sec-badge').dataset.level, 'red');
});

// MARK: The Internet guard on the card

const guardOf = (el) => one(el, 'sec-guard');

test('watched and still trying: what it blocked today and in 24 hours, the names newest first with their counts and last time', () => {
  const { el } = card(SECURITY.yellow);
  const guard = guardOf(el);
  assert.equal(one(guard, 'pill').textContent, 'Watching');
  const ok = one(guard, 'sec-guard-ok');
  assert.equal(ok.textContent, 'Blocked 47 attempts today, 340 in the last 7 days. Nothing got out.', 'it reads as a success');
  assert.ok(!guard.textContent.includes('another way out'), 'no warning for blocked attempts');
  const names = byClass(guard, 'sec-name');
  assert.deepEqual(names.map((node) => all(node, (child) => child.localName === 'code')[0].textContent),
    ['*.p2p.example.com', 'cloud.example.net', 'time.example.org', 'update.example.org']);
  assert.match(names[0].textContent, /290 times · last 4 minutes ago/);
  assert.ok(names.every((node) => one(node, 'sec-name-ok').textContent === 'Blocked'), 'each name says it was blocked');
  assert.equal(one(names[3], 'sec-name-when').textContent, '3 times', 'a name never seen last has no time');
  assert.match(guard.textContent, /sees lookups by name only/, 'what Watch can’t see is said');
  assert.ok(!visible(button(el, 'Set up for Camera Bridge (includes Watch)'), el), 'a watched camera is not offered Watch again');
});

test('each name says how often, first and last, and what it likely is; “was it you?” follows the list', () => {
  const security = { ...SECURITY.yellow, guard: { ...SECURITY.yellow.guard, names: [
    { name: '*.p2p.example.com', count: 290, first: ago(3 * 24 * 60), last: ago(4) },
    { name: 'cloud.example.net', count: 1, first: ago(120), last: ago(120) },
    { name: 'time.example.org', count: 21, first: ago(1300), last: ago(1200) },
    { name: 'update.example.org', count: 3, first: null, last: null },
    { name: 'a.example.com', count: 2, first: ago(29.3), last: ago(29) },
  ] } };
  const view = sec.securityView(camera(security)).guard;
  assert.deepEqual(view.names.map((entry) => [entry.name, entry.first]),
    [['*.p2p.example.com', NOW - 3 * 86_400_000], ['a.example.com', NOW - 29.3 * 60_000], ['cloud.example.net', NOW - 120 * 60_000],
      ['time.example.org', NOW - 1300 * 60_000], ['update.example.org', null]], 'first is read like last (ms, null when the bridge does not say)');
  const { el } = card(security, { camera: { vendor: 'reolink', manufacturer: 'Reolink' } });
  const items = byClass(guardOf(el), 'sec-name');
  const whenOf = (item) => one(item, 'sec-name-when').textContent;
  const whatOf = (item) => one(item, 'sec-name-what').textContent;
  assert.equal(whenOf(items[0]), '290 times · first 3 days ago · last 4 minutes ago');
  assert.equal(whatOf(items[0]), 'Likely Reolink’s cloud or phone-app connection.', 'a cloud name without a maker in it is the camera maker’s');
  assert.equal(whenOf(items[1]), '2 times · last 29 minutes ago', 'a first that reads the same as the last is said once');
  assert.equal(whenOf(items[2]), '1 time · last 2 hours ago');
  assert.equal(whenOf(items[3]), '21 times · first 22 hours ago · last 20 hours ago');
  assert.equal(whatOf(items[3]), 'Likely a time server: the camera asks it for the time. Set up for Camera Bridge can point its clock at the bridge instead.');
  assert.equal(whenOf(items[4]), '3 times', 'no times when the bridge does not say');
  assert.equal(whatOf(items[4]), 'Likely a firmware or app update check.', 'an update name that names no maker is nobody’s in particular');
  assert.equal(whatOf(items[1]), 'Not one Camera Bridge recognizes.');
  const times = all(items[0], (node) => node.localName === 'time');
  assert.deepEqual(times.map((node) => node.getAttribute('datetime')), [ago(3 * 24 * 60), ago(4)], 'each time has its full date for the tooltip');
  const was = one(guardOf(el), 'sec-was-it-you');
  assert.equal(was.textContent, 'Cameras look these up on their own, and also when you use the maker’s phone app or website with them. '
    + 'If you used this camera’s app around one of these times, that may have been you.');
  assert.equal(was.parentNode, items[0].parentNode.parentNode, 'under the list');

  const rtsp = card(security, { canSetUp: false });
  const timeItem = byClass(guardOf(rtsp.el), 'sec-name').find((item) => item.textContent.includes('time.example.org'));
  assert.equal(one(timeItem, 'sec-name-what').textContent, 'Likely a time server: the camera asks it for the time.', 'no setup, no hint');
  const clockSet = card(security, { camera: { setupState: { applied: ago(60), steps: [{ id: 'timeSource', status: 'done' }] } } });
  const setItem = byClass(guardOf(clockSet.el), 'sec-name').find((item) => item.textContent.includes('time.example.org'));
  assert.ok(!one(setItem, 'sec-name-what').textContent.includes('Set up for Camera Bridge'), 'its clock already comes from the bridge');
  assert.equal(byClass(guardOf(card(SECURITY.gold).el), 'sec-was-it-you').length, 0, 'nothing blocked, nothing to ask');
  const noCloud = { ...security, guard: { ...security.guard, names: security.guard.names.filter((entry) => !/p2p|cloud/.test(entry.name))
    .concat({ name: 'push.apple.com', count: 4, first: ago(90), last: ago(80) }) } };
  const quietCard = card(noCloud, { camera: { vendor: 'reolink', manufacturer: 'Reolink' } });
  assert.equal(byClass(guardOf(quietCard.el), 'sec-name').length, 4);
  assert.equal(byClass(guardOf(quietCard.el), 'sec-was-it-you').length, 0, 'only when a name is likely the maker’s cloud (a general service is not)');
});

test('watched and quiet says so, without names', () => {
  const guard = guardOf(card(SECURITY.gold).el);
  assert.equal(one(guard, 'pill').textContent, 'Watching');
  assert.match(guard.textContent, /no internet lookups/);
  assert.equal(byClass(guard, 'sec-name').length, 0);
  const fallback = guardOf(card({ ...SECURITY.gold, findings: SECURITY.gold.findings.filter((entry) => entry.feature !== 'internetGuard') }).el);
  assert.match(fallback.textContent, /It made no internet lookups in the last 24 hours\./, 'the page’s own words say what was seen, not “tries to reach the internet”');
});

test('not watched: why it matters, and “Watch its internet” opens the setup where the bridge has the guard and the setup works', () => {
  const handle = card(SECURITY.green);
  const guard = guardOf(handle.el);
  assert.equal(one(guard, 'pill').textContent, 'Not watched');
  assert.ok(guard.textContent.includes(NOT_WATCHED.sentence));
  assert.match(guard.textContent, /blocks every one/);
  assert.match(guard.textContent, /stops working away from home/, 'what Watch costs is said before it is chosen');
  const watch = button(handle.el, 'Set up for Camera Bridge (includes Watch)');
  assert.ok(watch && visible(watch, handle.el), 'the button says it runs the whole setup');
  assert.match(guard.textContent, /The whole setup runs, and it shows every change first\./);
  watch.click();
  assert.deepEqual(handle.opened, ['setup']);
  const rtsp = card(SECURITY.green, { canSetUp: false });
  assert.ok(!visible(button(rtsp.el, 'Set up for Camera Bridge (includes Watch)'), rtsp.el));
  assert.match(guardOf(rtsp.el).textContent, /can’t change this camera’s settings, so it can’t watch it/);
});

test('a bridge without the guard says so, offers no Watch, and points at the router', () => {
  const handle = card({ ...SECURITY.green, guard: null, findings: [SECURITY.green.findings[0], NO_GUARD] });
  const guard = guardOf(handle.el);
  assert.equal(one(guard, 'pill').textContent, 'Not on this bridge');
  assert.ok(guard.textContent.includes(NO_GUARD.sentence));
  assert.match(guard.textContent, /your router/i);
  assert.ok(!visible(button(handle.el, 'Set up for Camera Bridge (includes Watch)'), handle.el));
});

test('a camera that works only through its maker’s cloud is not told to block its internet: it would stop working here too', () => {
  const wyze = { vendor: 'go2rtc', integration: { service: 'wyze' } };
  assert.equal(sec.needsMakersCloud(wyze), true);
  // A Tuya / Smart Life camera's video comes through go2rtc's tuya:// source, which signs in to the Tuya cloud.
  for (const service of ['eufy', 'ring', 'nest', 'tuya']) assert.equal(sec.needsMakersCloud({ vendor: 'go2rtc', integration: { service } }), true, service);
  for (const service of ['unifiProtect', 'other']) assert.equal(sec.needsMakersCloud({ vendor: 'go2rtc', integration: { service } }), false, service);
  assert.equal(sec.needsMakersCloud({ vendor: 'onvif', manufacturer: 'TP-Link', model: 'Tapo C200' }), false, 'a Tapo camera on its own RTSP works without the internet');
  let built = 0;
  const notWatched = card(SECURITY.green, { canSetUp: false, camera: wyze, routerHelp: () => { built += 1; return browser.document.createElement('details'); } });
  assert.equal(built, 0, 'no router help');
  const guard = guardOf(notWatched.el);
  assert.match(guard.textContent, /needs its maker’s cloud to work with Camera Bridge/);
  assert.ok(!/router/i.test(guard.textContent));
  const mac = card({ ...SECURITY.red, guard: null, findings: [NO_GUARD] }, { canSetUp: false, camera: wyze });
  assert.ok(!/router/i.test(guardOf(mac.el).textContent));
});

test('the router help goes at the end of the guard’s section', () => {
  const help = browser.document.createElement('details');
  help.className = 'local-only';
  const handle = card(SECURITY.green, { routerHelp: (c) => { help.dataset.for = c.id; return help; } });
  assert.equal(one(handle.el, 'local-only'), help);
  assert.equal(help.dataset.for, ID);
});

test('“Restart the camera now” is on the card while the bridge says the camera waits for a restart, and goes once nothing waits', () => {
  const made = [];
  const restart = (c) => { made.push(c.id); const el = browser.document.createElement('div'); el.className = 'restart-camera'; return el; };
  const waiting = card(SECURITY.green, { restart, camera: { restartOffered: true } });
  assert.ok(one(waiting.el, 'restart-camera'));
  waiting.update(camera(SECURITY.green, { restartOffered: true, name: 'Back Garden' }));
  assert.deepEqual(made, [ID], 'kept in place as the card draws again (a confirmation under way stays)');
  waiting.update(camera(SECURITY.green, { restartOffered: false }));
  assert.equal(one(waiting.el, 'restart-camera'), undefined, 'gone once nothing waits for a restart');
  assert.equal(one(card(SECURITY.green, { restart }).el, 'restart-camera'), undefined, 'not offered: none');
});

// MARK: The Monitor's dot

test('the Monitor’s dot beside a name: its level’s colour and word (title and label), drawn in place, gone without a level', () => {
  const slot = browser.document.createElement('span');
  sec.drawSecurityDot(slot, camera(undefined));
  assert.equal(slot.childNodes.length, 0, 'nothing before the first check');
  sec.drawSecurityDot(slot, camera(SECURITY.red));
  const dot = slot.firstChild;
  assert.ok(dot.classList.contains('sec-dot'));
  assert.deepEqual([dot.dataset.level, dot.getAttribute('role'), dot.getAttribute('aria-label'), dot.getAttribute('title')],
    ['red', 'img', 'Security: Outside access possible', 'Security: Outside access possible']);
  const marks = (node) => all(node, (child) => child.getAttribute?.('class') === 'sec-shield-mark').map((child) => child.getAttribute('d'));
  const redMarks = marks(dot);
  assert.ok(redMarks.length > 0, 'the level’s own mark (a cross, a lock …), so the levels differ by shape, not colour alone');
  sec.drawSecurityDot(slot, camera(SECURITY.gold));
  assert.equal(slot.firstChild, dot, 'the same dot changes');
  assert.deepEqual([dot.dataset.level, dot.getAttribute('aria-label')], ['gold', 'Security: Local only']);
  assert.notDeepEqual(marks(dot), redMarks, 'and its mark with it');
  const other = browser.document.createElement('i');
  slot.append(other);
  sec.drawSecurityDot(slot, null);
  assert.deepEqual(slot.childNodes, [other], 'only its own dot leaves; other marks stay');
});

test('the Monitor draws the dot through its name hook, and the dot sits in the name’s bar without covering the picture', () => {
  const nvr = readFileSync(new URL('../web/js/screens/nvr.js', import.meta.url), 'utf8');
  const hook = nvr.slice(nvr.indexOf('function drawNameMarks'), nvr.indexOf('function updateTile'));
  assert.match(hook, /drawSecurityDot\(parts\.nameSlot, camera\)/);
  assert.ok(hook.indexOf('drawSecurityDot') < hook.indexOf('.hidden ='), 'the slot shows once the dot is in it');
  const css = readFileSync(new URL('../web/monitor.css', import.meta.url), 'utf8');
  const rule = css.slice(css.indexOf('.sec-dot {'), css.indexOf('}', css.indexOf('.sec-dot {')));
  assert.ok(rule.length > 10, 'monitor.css styles the dot');
  assert.ok(!/position\s*:\s*absolute/.test(rule), 'the dot stays in the bar’s flow');
  assert.match(rule, /flex\s*:\s*none/);
  for (const level of sec.SECURITY_LEVELS) assert.match(css, new RegExp(`--sec-${level}:`), `the Monitor (always dark) has its own ${level}`);
});

// MARK: The colours

test('the four colours are tokens in the dark and both light blocks, each with an ink for its mark', () => {
  const css = readFileSync(new URL('../web/style.css', import.meta.url), 'utf8');
  const block = (selector, from = 0) => { const start = css.indexOf(selector, from); return css.slice(start, css.indexOf('}', start)); };
  const dark = block(':root {');
  const chosen = block(':root[data-theme="light"] {');
  const followed = block(':root:not([data-theme="dark"]) {', css.indexOf('@media (prefers-color-scheme: light)'));
  for (const level of sec.SECURITY_LEVELS) {
    for (const name of [`--sec-${level}`, `--sec-${level}-ink`]) {
      for (const [where, text] of [['dark', dark], ['light', chosen], ['light (Auto)', followed]]) assert.match(text, new RegExp(`${name}:`), `${name} in ${where}`);
    }
    assert.match(css, new RegExp(`\\.sec-badge\\[data-level="${level}"\\]`), `the badge has ${level}`);
  }
});

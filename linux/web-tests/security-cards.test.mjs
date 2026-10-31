// Settings › Security and the monitoring card (screens/sessions-card.js, screens/monitor-card.js), and the "Wrong Passwords Entered" notice
// (kind signInAttempts, category security), which renders like any other notice. In the fake browser; the bridge's zone is Phoenix.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let createSessionsCard;
let sessionLine;
let monitorCardFor;
before(async () => {
  browser = installFakeBrowser();
  ({ createSessionsCard, sessionLine } = await import('../web/js/screens/sessions-card.js'));
  ({ monitorCardFor } = await import('../web/js/screens/monitor-card.js'));
  (await import('../web/js/store.js')).setBridgeZone('America/Phoenix');
});
after(() => browser?.restore());

const NOW = Date.UTC(2026, 9, 31, 21, 0, 0);
const settle = async () => { for (let i = 0; i < 12; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const named = (root, text) => all(root, (node) => node.localName === 'button' && node.textContent.trim() === text);
const visibleText = (node) => (node.hidden ? '' : node.data !== undefined ? node.data : (node.childNodes ?? []).map(visibleText).join(''));

// MARK: Signed-in browsers

const SESSIONS = [
  { id: 's1', browser: 'Chrome on Mac', address: '192.0.2.20', created: new Date(NOW - 86_400_000).toISOString(), lastSeen: new Date(NOW - 10_000).toISOString(), current: true },
  { id: 's2', browser: 'Safari on iPhone', address: '192.0.2.31', created: new Date(NOW - 3 * 86_400_000).toISOString(), lastSeen: new Date(NOW - 120_000).toISOString(), current: false },
  { id: 's3', browser: 'A browser', address: null, created: new Date(NOW - 9 * 86_400_000).toISOString(), lastSeen: new Date(NOW - 5 * 86_400_000).toISOString(), current: false },
];

test('each browser is one line: what it is, where from, when it was last seen; the one in use says so', async () => {
  assert.equal(sessionLine(SESSIONS[1], NOW), 'Safari on iPhone · 192.0.2.31 · last seen 2 min ago');
  assert.equal(sessionLine(SESSIONS[0], NOW), 'Chrome on Mac · 192.0.2.20 · last seen just now');
  assert.equal(sessionLine(SESSIONS[2], NOW), 'A browser · last seen 5 days ago', 'no address for one from before');
  const card = createSessionsCard({ load: async () => ({ sessions: SESSIONS }), now: () => NOW });
  await settle();
  const rows = byClass(card.el, 'session-item');
  assert.equal(rows.length, 3);
  assert.match(visibleText(rows[0]), /This browser/);
  assert.doesNotMatch(visibleText(rows[1]), /This browser/);
  assert.match(all(rows[1], (node) => node.classList?.contains('session-text'))[0].getAttribute('title'), /^Signed in Oct 28, 2026, 2:00\s?PM, last seen Oct 31, 2026, 1:58\s?PM$/, 'in the bridge’s time');
  card.destroy();
});

test('Sign out asks first; another browser leaves the list, this one goes back to the sign-in page', async () => {
  const ended = [];
  let answer = false;
  const questions = [];
  let list = SESSIONS;
  let signedOut = 0;
  const card = createSessionsCard({
    load: async () => ({ sessions: list }),
    signOut: async (id) => { ended.push(id); list = list.filter((s) => s.id !== id); },
    confirm: async (question) => { questions.push(question); return answer; },
    signedOut: () => { signedOut += 1; },
    now: () => NOW,
  });
  await settle();
  const button = (id) => named(byClass(card.el, 'session-item').find((row) => row.dataset.id === id), 'Sign out')[0];
  button('s2').click();
  await settle();
  assert.equal(questions[0].title, 'Sign out Safari on iPhone?');
  assert.deepEqual(ended, [], 'No: nothing is sent');
  answer = true;
  button('s2').click();
  await settle();
  assert.deepEqual(ended, ['s2']);
  assert.deepEqual(byClass(card.el, 'session-item').map((row) => row.dataset.id), ['s1', 's3']);
  assert.equal(signedOut, 0);
  button('s1').click();
  await settle();
  assert.equal(questions.at(-1).title, 'Sign out of this browser?');
  assert.deepEqual(ended, ['s2', 's1']);
  assert.equal(signedOut, 1, 'this browser: back to the sign-in page');
  card.destroy();
});

test('a refusal is said on the card', async () => {
  const card = createSessionsCard({
    load: async () => ({ sessions: SESSIONS }), confirm: async () => true, now: () => NOW,
    signOut: async () => { throw Object.assign(new Error('Something went wrong (500).'), { status: 500 }); },
  });
  await settle();
  named(byClass(card.el, 'session-item')[1], 'Sign out')[0].click();
  await settle();
  assert.equal(visibleText(byClass(card.el, 'session-problem')[0]), 'Something went wrong (500).');
  assert.equal(byClass(card.el, 'session-item').length, 3);
  card.destroy();
});

// MARK: Monitoring

test('monitoring off: a switch and nothing else; on: the address, the token hidden until Show, Copy and a new token', async () => {
  const changes = [];
  const change = (partial) => changes.push(partial);
  const off = monitorCardFor({ monitorEnabled: false, monitorToken: null }, { change, origin: 'http://camera-bridge.local' });
  assert.doesNotMatch(visibleText(off), /Bearer|api\/v1\/monitor/);
  const toggle = all(off, (node) => node.localName === 'input')[0];
  toggle.checked = true;
  toggle.dispatchEvent({ type: 'change', target: toggle });
  assert.deepEqual(changes, [{ monitorEnabled: true }]);

  const TOKEN = 'mon_8c1f2e9d0a7b4c3e';
  let shown = false;
  const copied = [];
  const make = () => monitorCardFor({ monitorEnabled: true, monitorToken: TOKEN }, {
    change, shown, setShown: (on) => { shown = on; }, origin: 'http://camera-bridge.local',
    copy: async (value) => { copied.push(value); return 'copied'; }, confirm: async () => true, say: () => {},
  });
  let card = make();
  assert.match(visibleText(card), /http:\/\/camera-bridge\.local\/api\/v1\/monitor/);
  assert.match(visibleText(card), /Send it as “Authorization: Bearer <token>”\./);
  assert.ok(!visibleText(card).includes(TOKEN), 'hidden until Show');
  named(card, 'Show')[0].click();
  assert.equal(shown, true);
  card = make();
  assert.ok(visibleText(card).includes(TOKEN));
  named(card, 'Copy')[1].click();
  await settle();
  assert.deepEqual(copied, [TOKEN]);
  named(card, 'New token')[0].click();
  await settle();
  assert.deepEqual(changes.at(-1), { regenerateMonitorToken: true });
});

// MARK: The notice

test('"Wrong Passwords Entered" (signInAttempts) is a security warning like the others: a toast, and a row on the Notifications page', async () => {
  const notifications = await import('../web/js/notifications.js');
  const entry = {
    id: 'e-sign-in', key: 'sign-in-1761944400', noticeID: 'sign-in-1761944400', kind: 'signInAttempts', category: 'security', severity: 'warning',
    title: 'Wrong Passwords Entered', detail: '12 wrong passwords were entered from 192.0.2.77. Sign-ins from there wait a while after each one.',
    cameraID: null, cameraName: null, action: null, date: new Date(NOW).toISOString(), read: false, toasted: false,
  };
  assert.equal(notifications.notificationIcon(entry), 'alert');
  assert.deepEqual(notifications.notificationActions(entry), [], 'no button');
  const shown = notifications.showToast(entry);
  assert.match(visibleText(shown.el), /Wrong Passwords Entered/);
  assert.match(visibleText(shown.el), /12 wrong passwords were entered/);
  shown.close?.();
  notifications.clearToasts();
});

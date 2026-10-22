// The Secure address card on the System page: what it says in each state, the router help, the switch.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
before(() => { browser = installFakeBrowser(); });
after(() => browser?.restore());

const HOST = 'k7f2q9.box.camera-bridge.app';
const READY = { available: true, state: 'ready', host: HOST, url: `https://${HOST}`, address: '192.168.77.5', expiresOn: '2026-12-20T08:00:00Z',
  renewsOn: '2026-11-20T08:00:00Z', redirect: true, redirectActive: true, problem: null, rebind: null };

const text = (node) => (node.childNodes ?? []).map((child) => (child.tagName ? text(child) : child.data ?? child.textContent ?? '')).join('');
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const buttons = (card) => all(card, (n) => n.localName === 'button');

test('no card where the box has no TLS front, or has not said yet', async () => {
  const { secureAddressCard } = await import('../web/js/screens/secure-address.js');
  assert.equal(secureAddressCard(null), null);
  assert.equal(secureAddressCard({ ...READY, available: false }), null);
});

test('a ready address shows the link, the install hint, the renewal date and the switch', async () => {
  const { secureAddressCard } = await import('../web/js/screens/secure-address.js');
  const card = secureAddressCard(READY, {});
  const words = text(card);
  assert.match(words, /Secure address/);
  assert.match(words, new RegExp(`https://${HOST}`));
  assert.match(words, /Open it once, then install the app from there\./);
  assert.match(words, /renews by itself around November 20, 2026|renews by itself around 20 November 2026|renews by itself around/);
  assert.equal(all(card, (n) => n.localName === 'a')[0].getAttribute('href'), `https://${HOST}`);
  const toggle = all(card, (n) => n.localName === 'input')[0];
  assert.ok(toggle.checked);
  assert.match(words, /Send camera-bridge\.local to the secure address/);
});

test('the redirect switch reports the new value', async () => {
  const { secureAddressCard } = await import('../web/js/screens/secure-address.js');
  const seen = [];
  const card = secureAddressCard({ ...READY, redirect: false, redirectActive: false }, { setRedirect: (value) => seen.push(value) });
  const toggle = all(card, (n) => n.localName === 'input')[0];
  assert.ok(!toggle.checked);
  toggle.checked = true;
  toggle.dispatchEvent({ type: 'change', target: toggle });
  assert.deepEqual(seen, [true]);
});

test('a waiting address says it takes minutes and that the plain address works', async () => {
  const { secureAddressCard } = await import('../web/js/screens/secure-address.js');
  const words = text(secureAddressCard({ ...READY, state: 'waiting', expiresOn: null, renewsOn: null, redirectActive: false }, {}));
  assert.match(words, /getting its certificate/);
  assert.match(words, /plain address works meanwhile/);
  assert.match(words, /Takes effect once the secure address works/);
});

test('an error is said in plain words with a way to try again', async () => {
  const { secureAddressCard } = await import('../web/js/screens/secure-address.js');
  let tried = 0;
  const card = secureAddressCard({ ...READY, state: 'error', redirectActive: false,
    problem: { code: 'service_not_ready', message: 'The secure address service isn’t ready yet. The box will try again later.' } }, { retry: () => { tried += 1; } });
  const words = text(card);
  assert.match(words, /isn’t ready yet/);
  assert.match(words, /http:\/\/camera-bridge\.local, keeps working/);
  const retry = buttons(card).find((b) => /Try again now/.test(text(b)));
  assert.ok(retry);
  retry.click();
  assert.equal(tried, 1);
});

test('a router that hides the name gets its menu path; a router that does not gets a tick', async () => {
  const { secureAddressCard, ROUTER_HELP } = await import('../web/js/screens/secure-address.js');
  const blocked = text(secureAddressCard({ ...READY, rebind: { state: 'blocked', message: 'Your router doesn’t give out names that point inside your home (DNS rebind protection).', checkedAt: '2026-10-22T08:00:00Z' } }, {}));
  assert.match(blocked, /DNS rebind protection/);
  assert.match(blocked, /allow the name box\.camera-bridge\.app/);
  for (const [maker] of ROUTER_HELP) assert.ok(blocked.includes(maker), maker);
  assert.match(blocked, /FRITZ!Box: Home Network/);
  const ok = text(secureAddressCard({ ...READY, rebind: { state: 'ok', message: 'Your router gives out the secure address.', checkedAt: '2026-10-22T08:00:00Z' } }, {}));
  assert.match(ok, /Your router gives out the secure address\./);
  assert.doesNotMatch(ok, /FRITZ/);
  const noNet = text(secureAddressCard({ ...READY, rebind: { state: 'no_internet', message: 'The box can’t look up names on the internet right now, so this can’t be tested.', checkedAt: '2026-10-22T08:00:00Z' } }, {}));
  assert.doesNotMatch(noNet, /FRITZ/);
});

test('the test button is there once the box has a name, and busy disables the controls', async () => {
  const { secureAddressCard } = await import('../web/js/screens/secure-address.js');
  const card = secureAddressCard(READY, { busy: 'check' });
  assert.ok(buttons(card).some((b) => /Test this address/.test(text(b))));
  assert.ok(buttons(card).every((b) => b.disabled));
  assert.equal(buttons(secureAddressCard({ ...READY, host: null, state: 'off' }, {})).length, 0);
});

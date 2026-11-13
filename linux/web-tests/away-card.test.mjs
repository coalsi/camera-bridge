// Settings › Away from home (screens/away-card.js): each state of the box's card (GET away) in plain words, the switch, the router step
// (an eero's own steps, or one sentence for any other router), the devices with Remove, a WireGuard device's QR code shown once, and the
// card reading itself again every 15 s while on. In the fake browser, with the functions the card calls injected, as for the Apple TV and
// iPhone card.
import assert from 'node:assert/strict';
import { after, afterEach, before, mock, test } from 'node:test';
import { FakeElement, installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let addressTail;
let createAwayCard;
let deviceLine;
let routerStep;
let showConfigQR;
before(async () => {
  browser = installFakeBrowser();
  ({ addressTail, createAwayCard, deviceLine, routerStep, showConfigQR } = await import('../web/js/screens/away-card.js'));
});
after(() => browser?.restore());

const NOW = Date.UTC(2026, 10, 12, 18, 0, 0);
const MINUTE = 60_000;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');   // whole seconds, as the box says its dates
const ADDRESS = '2001:db8:4:7000:1a2b:3c4d:5e6f:7a8b';
const AWAY_NAME = 'abcdefghij0123456789.away.camera-bridge.app';
const tick = () => new Promise((resolve) => setImmediate(resolve));
const settle = async () => { for (let i = 0; i < 12; i += 1) await tick(); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const named = (root, text) => all(root, (node) => node.localName === 'button' && node.textContent.trim() === text);
const visibleText = (node) => (node.hidden ? '' : node.data !== undefined ? node.data : (node.childNodes ?? []).map(visibleText).join(''));
const switchOf = (root) => all(root, (node) => node.localName === 'input' && node.getAttribute('role') === 'switch')[0];
const isOn = (root) => switchOf(root).checked === true;   // h() leaves `checked` unset for false, as a new input has it
const flip = (input, checked) => { input.checked = checked; input.dispatchEvent({ type: 'change', target: input }); };
const rowIDs = (card) => byClass(card.el, 'away-device').map((row) => row.dataset.id);
const refusal = (status, code, message) => Object.assign(new Error(message), { status, code });
const toasts = () => visibleText(browser.document.getElementById('toasts'));

const OFF = { on: false, state: 'off', problem: null, port: 51820, address: null, name: null, router: null, addressChangedAt: null, devices: [] };
const on = (more = {}) => ({ on: true, state: 'setup', problem: null, port: 51820, address: ADDRESS, name: AWAY_NAME, router: null, addressChangedAt: null, devices: [], ...more });
const PHONE = { id: 'd1', kind: 'app', name: 'iPhone', lastHandshake: iso(NOW - 5 * MINUTE), lastAwayAt: iso(NOW - 5 * MINUTE) };
const TABLET = { id: 'd3', kind: 'app', name: 'iPad', lastHandshake: iso(NOW - 120 * MINUTE), lastAwayAt: iso(NOW - 120 * MINUTE) };
const LAPTOP = { id: 'd2', kind: 'wireguard', name: 'Laptop', lastHandshake: null, lastAwayAt: null };
// A configuration as the box writes one. Its keys are counting patterns (the base64 of bytes 0 to 31, then 32 to 63), nobody's keys.
const CONFIG ='[Interface]\nPrivateKey = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\nAddress = 10.123.45.3/32\nMTU = 1280\n\n[Peer]\n'
  + 'PublicKey = ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=\nAllowedIPs = 10.123.45.1/32, 192.0.2.10/32\nEndpoint = [2001:db8:4:7000:1a2b:3c4d:5e6f:7a8b]:51820\n';

const DESCRIPTION = 'Your iPhone, or any device with the WireGuard app, can watch your cameras from anywhere, straight from your home, with nothing in between. Turn it on here; your router may need one setting too.';
const WEBSITE = 'The camera-bridge.app website, an outside service, keeps the box’s away name pointed at your home and sees nothing else. While it is down, phones use the last address they know.';
const PHONE_STEP = 'Turn on Away from home in the Camera Bridge app on your iPhone, or add a device for the WireGuard app below.';
const CHECK_IPHONE = 'On your iPhone, turn off Wi-Fi and open the Camera Bridge app. When it reaches the box from away, this card names the phone.';
const CHECK_WIREGUARD = 'On a device with the WireGuard app, turn the tunnel on while the device is off your home network (on a phone, turn off Wi-Fi). When it reaches the box from away, this card names the device.';
const NEW_CODES = 'Devices with the WireGuard app need a new code too: remove each one, then add it again.';
const EERO_STEPS = [
  'In the eero app: Settings › Network settings › Reservations & port forwarding › IPv6 firewall rules › Add.',
  'Choose the device that is the box. The eero app lists devices by name and may show it under a name you gave it; the address in the next step tells you which one it is.',
  'Choose the address ending in 1a2b:3c4d:5e6f:7a8b (exactly that one).',
  'Enter port 51820, UDP.',
];
const OTHER_STEPS = [
  `Allow incoming IPv6 traffic to ${ADDRESS}, UDP port 51820.`,
  'Routers usually keep that setting with their firewall or port forwarding settings, often under IPv6.',
];

/** Every card a test made, destroyed after each test: a test that fails half-way leaves no card reading itself again every 15 s. */
const cards = new Set();
const made = (card) => { cards.add(card); return card; };
afterEach(() => {
  for (const card of cards) card.destroy();
  cards.clear();
});

/** A card over `answer` (a card document, or a function giving one), with the rest of `options` injected. */
async function cardFor(answer, options = {}) {
  const card = made(createAwayCard({ load: async () => (typeof answer === 'function' ? answer() : answer), now: () => NOW, ...options }));
  await settle();
  return card;
}

// MARK: The words

test('the address the router step names is the last four groups, written out', () => {
  assert.equal(addressTail(ADDRESS), '1a2b:3c4d:5e6f:7a8b');
  assert.equal(addressTail('2001:db8:4:7000::1'), '0:0:0:1');
  assert.equal(addressTail('2001:db8::1a2b:0:0:7a8b'), '1a2b:0:0:7a8b');
  assert.equal(addressTail('2001:0DB8:0004:7000:0A2B:3C4D:5E6F:7A8B'), 'a2b:3c4d:5e6f:7a8b', 'as eero writes it: lower case, no leading zeros');
  assert.equal(addressTail('[2001:db8:4:7000::1]'), '0:0:0:1');
  for (const nothing of [null, undefined, '', '192.0.2.10', 'not an address', '2001:db8::1::2', '2001:db8:4:7000:1:2:3:4:5']) {
    assert.equal(addressTail(nothing), '', String(nothing));
  }
});

test('the eero step against the other router’s', () => {
  assert.deepEqual(routerStep(on({ router: 'eero' })), { brand: 'eero', steps: EERO_STEPS });
  assert.ok(!/camera-bridge/.test(routerStep(on({ router: 'eero' })).steps[1]), 'the box is told apart by its address, never by a name');
  assert.deepEqual(routerStep(on({ router: null })), { brand: null, steps: OTHER_STEPS });
  assert.deepEqual(routerStep(on({ router: 'something else' })), { brand: null, steps: OTHER_STEPS }, 'only eero has steps of its own');
  assert.equal(routerStep(on({ address: null })).steps[0], 'Allow incoming IPv6 traffic to the box, UDP port 51820.', 'no address yet');
});

test('a device’s line says when it last reached the box from away, or that it hasn’t yet', () => {
  assert.equal(deviceLine(PHONE, NOW), 'Reached from away: iPhone, 5 minutes ago.');
  assert.equal(deviceLine(TABLET, NOW), 'Reached from away: iPad, 2 hours ago.');
  assert.equal(deviceLine({ ...PHONE, lastAwayAt: iso(NOW - 3_000) }, NOW), 'Reached from away: iPhone, just now.');
  assert.equal(deviceLine({ ...PHONE, lastAwayAt: iso(NOW + 90_000) }, NOW), 'Reached from away: iPhone, just now.', 'the box’s clock a little ahead of this one');
  assert.equal(deviceLine(LAPTOP, NOW), 'Laptop hasn’t reached the box from away yet.');
  assert.equal(deviceLine({ ...LAPTOP, lastHandshake: iso(NOW - MINUTE) }, NOW), 'Laptop hasn’t reached the box from away yet.', 'a handshake at home is not from away');
});

// MARK: One state at a time

test('off: what it does, in two sentences, and the switch', async () => {
  const card = await cardFor(OFF);
  // The Settings section above it is "Away from home": the card's heading and its switch say it in other words.
  assert.equal(all(card.el, (node) => node.localName === 'h2')[0].textContent, 'Watch from anywhere');
  const text = visibleText(card.el);
  assert.ok(text.includes(DESCRIPTION), text);
  assert.ok(!/It takes this switch/.test(text));
  assert.ok(switchOf(card.el), 'the switch');
  assert.equal(isOn(card.el), false);
  assert.equal(visibleText(all(card.el, (node) => node.classList?.contains('switch-row'))[0]), 'Use Away from home');
  assert.ok(!text.includes(WEBSITE), 'nothing goes to the website while it is off');
  assert.deepEqual(named(card.el, 'Add a device with the WireGuard app'), []);
  card.destroy();
});

test('checking: it says it is looking', async () => {
  const card = await cardFor(on({ state: 'checking', address: null }));
  const text = visibleText(card.el);
  assert.ok(text.includes('Looking at how your home reaches the internet…'), text);
  assert.equal(isOn(card.el), true);
  assert.ok(text.includes(WEBSITE));
  card.destroy();
});

test('no IPv6 at home: what that means, and whom to ask', async () => {
  const card = await cardFor(on({ state: 'no_ipv6', address: null }));
  const text = visibleText(card.el);
  assert.ok(text.includes('Phones can’t reach this home from outside yet, because the internet connection has no IPv6. Ask your provider whether they offer it.'), text);
  assert.ok(!text.includes('On your router'), 'no router step without an address');
  assert.deepEqual(named(card.el, 'Add a device with the WireGuard app'), [], 'a device would have nowhere to go');
  card.destroy();
});

test('setup: the router step, Check for either kind of device, and the next step until a device has it', async () => {
  const card = await cardFor(on({ router: 'eero' }));
  const text = visibleText(card.el);
  const steps = all(byClass(card.el, 'away-router')[0], (node) => node.localName === 'li').map((item) => item.textContent);
  assert.deepEqual(steps, EERO_STEPS, 'the eero app’s four steps, in order');
  const check = all(card.el, (node) => node.localName === 'details')[0];
  assert.ok(check, 'Check, folded');
  assert.equal(all(check, (node) => node.localName === 'summary')[0].textContent, 'Check');
  assert.deepEqual(all(check, (node) => node.localName === 'p').map((line) => line.textContent), [CHECK_IPHONE, CHECK_WIREGUARD],
    'how to check from the iPhone app, and from the WireGuard app');
  assert.ok(text.includes(PHONE_STEP), text);
  assert.ok(text.includes(WEBSITE));
  assert.equal(named(card.el, 'Add a device with the WireGuard app').length, 1, 'the device the phone step points at, below it');
  card.destroy();

  const other = await cardFor(on({ router: null, devices: [{ ...PHONE, lastAwayAt: null }] }));
  const said = all(byClass(other.el, 'away-router')[0], (node) => node.localName === 'p').map((line) => line.textContent);
  assert.deepEqual(said, OTHER_STEPS, 'any other router: the address and the port, and where routers keep that');
  assert.ok(!visibleText(other.el).includes(PHONE_STEP), 'an iPhone has turned it on already');
  assert.ok(visibleText(other.el).includes('iPhone hasn’t reached the box from away yet.'));
  other.destroy();

  const laptopOnly = await cardFor(on({ devices: [LAPTOP] }));
  assert.ok(!visibleText(laptopOnly.el).includes(PHONE_STEP), 'a device with the WireGuard app has it too');
  laptopOnly.destroy();
});

test('working: one line per device, in the box’s order (newest first); Remove asks first', async () => {
  const removed = [];
  const questions = [];
  let answer = false;
  let devices = [PHONE, TABLET, LAPTOP];
  const card = await cardFor(() => on({ state: 'working', devices }), {
    removeDevice: async (id) => { removed.push(id); devices = devices.filter((device) => device.id !== id); },
    confirm: async (question) => { questions.push(question); return answer; },
  });
  assert.deepEqual(rowIDs(card), ['d1', 'd3', 'd2'], 'as the box gave them');
  assert.deepEqual(byClass(card.el, 'away-device').map((row) => visibleText(row).replace(/Remove$/, '')), [
    'Reached from away: iPhone, 5 minutes ago.', 'Reached from away: iPad, 2 hours ago.', 'Laptop hasn’t reached the box from away yet.',
  ]);
  assert.ok(visibleText(card.el).includes(`The box’s address on the internet: ${ADDRESS}`));
  assert.ok(!visibleText(card.el).includes('On your router'), 'working: no router step');
  const button = (id) => named(byClass(card.el, 'away-device').find((row) => row.dataset.id === id), 'Remove')[0];
  assert.equal(button('d1').getAttribute('aria-label'), 'Remove iPhone');

  button('d1').click();
  await settle();
  assert.deepEqual(questions, [{
    title: 'Remove iPhone from Away from home?',
    body: 'iPhone stays paired and keeps working at home. To reach the box from away again, turn on Away from home in its Camera Bridge app.',
    confirm: 'Remove',
    danger: true,
  }]);
  assert.deepEqual(removed, [], 'No: nothing is sent');

  answer = true;
  button('d1').click();
  await settle();
  assert.deepEqual(removed, ['d1']);
  assert.deepEqual(rowIDs(card), ['d3', 'd2'], 'read again from the box');

  button('d2').click();
  await settle();
  assert.deepEqual(questions.at(-1), {
    title: 'Remove Laptop?',
    body: 'Laptop can’t reach the box from away any more. To use it again, add it again and scan the new code.',
    confirm: 'Remove',
    danger: true,
  });
  assert.deepEqual(removed, ['d1', 'd2']);
  card.destroy();
});

test('a device the box no longer has counts as removed; a refusal is said once, on the card', async () => {
  let failure = refusal(404, 'not_found', 'That device isn’t there any more.');
  let devices = [PHONE, LAPTOP];
  let problem = null;
  const card = await cardFor(() => on({ state: problem ? 'problem' : 'working', problem, devices }), {
    removeDevice: async (id) => { devices = devices.filter((device) => device.id !== id); throw failure; },
    confirm: async () => true,
  });
  named(byClass(card.el, 'away-device')[0], 'Remove')[0].click();
  await settle();
  assert.deepEqual(rowIDs(card), ['d2']);
  assert.ok(!visibleText(card.el).includes('That device isn’t there any more.'), '404: it was gone already');

  // From the owner's browser a removal is applied at once; a 503 `system` is the system's sentence. The box keeps the removal and tries
  // again, and its card's problem then says so, so the sentence is not said twice.
  failure = refusal(503, 'system', 'The VPN interface isn’t up.');
  problem = 'The VPN interface isn’t up. A removed device can still connect until the box’s retry goes through.';
  named(byClass(card.el, 'away-device')[0], 'Remove')[0].click();
  await settle();
  const text = visibleText(card.el);
  assert.ok(text.includes(problem), text);
  assert.equal(text.split('The VPN interface isn’t up.').length - 1, 1, 'once');
  assert.deepEqual(rowIDs(card), []);
  card.destroy();

  // A refusal the card doesn't otherwise say stays on it.
  const refused = await cardFor(on({ state: 'working', devices: [PHONE] }), {
    removeDevice: async () => { throw refusal(500, 'error', 'Something went wrong (500).'); },
    confirm: async () => true,
  });
  named(byClass(refused.el, 'away-device')[0], 'Remove')[0].click();
  await settle();
  assert.ok(visibleText(refused.el).includes('Something went wrong (500).'));
  refused.destroy();
});

test('address changed: the new address, the router step again, and a new code for WireGuard devices', async () => {
  const changed = on({ state: 'address_changed', router: 'eero', addressChangedAt: iso(NOW - 10 * MINUTE), devices: [{ ...PHONE, lastAwayAt: iso(NOW - 60 * MINUTE) }, LAPTOP] });
  const card = await cardFor(changed);
  const text = visibleText(card.el);
  assert.ok(text.includes('Your home’s address changed. The router rule needs the new one:'), text);
  assert.equal(all(card.el, (node) => node.localName === 'code' && node.textContent === ADDRESS).length, 1, 'the new address');
  assert.deepEqual(all(byClass(card.el, 'away-router')[0], (node) => node.localName === 'li').map((item) => item.textContent), EERO_STEPS);
  assert.ok(text.includes(NEW_CODES), 'their configuration holds the old address');
  assert.ok(!text.includes(PHONE_STEP));
  card.destroy();

  // Without a device that uses the WireGuard app there is no code to renew.
  const phonesOnly = await cardFor({ ...changed, devices: [{ ...PHONE, lastAwayAt: iso(NOW - 60 * MINUTE) }] });
  assert.ok(visibleText(phonesOnly.el).includes('Your home’s address changed.'));
  assert.ok(!visibleText(phonesOnly.el).includes(NEW_CODES), 'no WireGuard device: nothing to say about their codes');
  phonesOnly.destroy();
});

test('a problem: the box’s sentence and Try again, which sends the same choice', async () => {
  const sent = [];
  let answer = on({ state: 'problem', problem: 'The VPN interface isn’t up.' });
  const card = await cardFor(() => answer, { setOn: async (value) => { sent.push(value); answer = on({ state: 'setup' }); return answer; } });
  assert.ok(visibleText(card.el).includes('The VPN interface isn’t up.'));
  assert.equal(isOn(card.el), true);
  named(card.el, 'Try again')[0].click();
  await settle();
  assert.deepEqual(sent, [true]);
  assert.ok(!visibleText(card.el).includes('The VPN interface isn’t up.'), 'the answer is drawn');
  assert.deepEqual(named(card.el, 'Try again'), []);
  card.destroy();

  // A failed Off is a problem too, while the switch shows off; Try again turns it off again.
  const offSent = [];
  const failedOff = await cardFor({ ...OFF, state: 'problem', problem: 'The system didn’t take the change.' }, { setOn: async (value) => { offSent.push(value); return OFF; } });
  assert.equal(isOn(failedOff.el), false);
  assert.ok(visibleText(failedOff.el).includes('The system didn’t take the change.'));
  assert.ok(!visibleText(failedOff.el).includes(WEBSITE));
  named(failedOff.el, 'Try again')[0].click();
  await settle();
  assert.deepEqual(offSent, [false]);
  failedOff.destroy();
});

test('whenever it is on, the card says what the website does', async () => {
  for (const state of ['checking', 'no_ipv6', 'setup', 'working', 'address_changed', 'problem']) {
    const card = await cardFor(on({ state, problem: state === 'problem' ? 'The VPN interface isn’t up.' : null }));
    assert.ok(visibleText(card.el).includes(WEBSITE), state);
    card.destroy();
  }
});

// MARK: The switch

test('the switch posts { on: true } and says the secure address came on too', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });   // the toast's own timer
  try {
    const sent = [];
    let secure = { enabled: false };
    let answer = OFF;
    const card = await cardFor(() => answer, {
      setOn: async (value) => { sent.push(value); answer = value ? on() : OFF; return answer; },
      secureAddress: async () => secure,
    });
    flip(switchOf(card.el), true);
    await settle();
    assert.deepEqual(sent, [true]);
    assert.equal(isOn(card.el), true);
    assert.ok(visibleText(card.el).includes(WEBSITE), 'the box’s answer is drawn');
    assert.ok(toasts().includes('The secure address is on too: Away from home needs it.'), toasts());

    // Off and on again with the secure address already on: nothing to say about it.
    const before = toasts();
    flip(switchOf(card.el), false);
    await settle();
    secure = { enabled: true };
    flip(switchOf(card.el), true);
    await settle();
    assert.deepEqual(sent, [true, false, true]);
    assert.equal(toasts(), before, 'no second toast');
    card.destroy();
  } finally {
    mock.timers.reset();
  }
});

test('turning it off with devices asks first, since every device loses its way in', async () => {
  const sent = [];
  const questions = [];
  let answer = false;
  const card = await cardFor(on({ state: 'working', devices: [PHONE] }), {
    setOn: async (value) => { sent.push(value); return OFF; },
    confirm: async (question) => { questions.push(question); return answer; },
  });
  flip(switchOf(card.el), false);
  await settle();
  assert.deepEqual(questions, [{
    title: 'Turn off Away from home?',
    body: 'The box closes its VPN and forgets every device’s key at once. Each device has to be set up again to reach the box from away.',
    confirm: 'Turn off',
    danger: true,
  }]);
  assert.deepEqual(sent, [], 'No: nothing is sent');
  assert.equal(isOn(card.el), true, 'and the switch is back on');
  answer = true;
  flip(switchOf(card.el), false);
  await settle();
  assert.deepEqual(sent, [false]);
  assert.equal(isOn(card.el), false);
  card.destroy();

  const empty = await cardFor(on(), { setOn: async (value) => { sent.push(value); return OFF; }, confirm: async () => { throw new Error('not asked'); } });
  flip(switchOf(empty.el), false);
  await settle();
  assert.deepEqual(sent, [false, false], 'no device: nothing to lose, nothing asked');
  empty.destroy();
});

test('a refused switch says why and stays as it was', async () => {
  const card = await cardFor(OFF, { setOn: async () => { throw refusal(503, 'unavailable', 'Away from home is part of Camera Bridge OS.'); }, secureAddress: async () => ({ enabled: true }) });
  flip(switchOf(card.el), true);
  await settle();
  assert.ok(visibleText(card.el).includes('Away from home is part of Camera Bridge OS.'));
  assert.equal(isOn(card.el), false);
  card.destroy();

  // Unreadable secure address: the switch still works, and nothing is said about the secure address.
  const sent = [];
  const unread = await cardFor(OFF, { setOn: async (value) => { sent.push(value); return on(); }, secureAddress: async () => { throw refusal(0, 'network', 'The bridge didn’t answer.'); } });
  flip(switchOf(unread.el), true);
  await settle();
  assert.deepEqual(sent, [true]);
  assert.equal(isOn(unread.el), true);
  unread.destroy();
});

// MARK: A device with the WireGuard app

test('Add a device with the WireGuard app: a name, the box’s configuration shown once as a QR code, and nothing of it kept', async () => {
  const added = [];
  const shown = [];
  let devices = [];
  const card = await cardFor(() => on({ devices }), {
    askName: async () => 'Laptop',
    addDevice: async (name) => { added.push(name); devices = [...devices, LAPTOP]; return { device: LAPTOP, config: CONFIG }; },
    showQR: async (config, device) => { shown.push([config, device]); },
  });
  named(card.el, 'Add a device with the WireGuard app')[0].click();
  await settle();
  assert.deepEqual(added, ['Laptop']);
  assert.deepEqual(shown, [[CONFIG, LAPTOP]], 'the configuration goes to the dialog');
  assert.deepEqual(rowIDs(card), ['d2'], 'the new device is listed');
  assert.ok(!serialize(card.el).includes('PrivateKey'), 'no part of the configuration is left on the card');
  assert.equal(localStorage.length, 0, 'nor kept in the browser');
  assert.equal(sessionStorage.length, 0);
  card.destroy();
});

test('a name left out sends nothing; a refusal is said on the card', async () => {
  const added = [];
  const shown = [];
  let name;
  let failure = null;
  const card = await cardFor(on(), {
    askName: async () => name,
    addDevice: async (value) => { added.push(value); if (failure) throw failure; return { device: LAPTOP, config: CONFIG }; },
    showQR: async (config) => { shown.push(config); },
  });
  named(card.el, 'Add a device with the WireGuard app')[0].click();
  await settle();
  assert.deepEqual(added, [], 'cancelled');
  for (const [error, said] of [
    [refusal(409, 'too_many_devices', '20 devices use the WireGuard app already. Remove one first.'), '20 devices use the WireGuard app already. Remove one first.'],
    [refusal(400, 'invalid', 'Give the device a name.'), 'Give the device a name.'],
    [new Error(''), 'That device couldn’t be added.'],
  ]) {
    name = 'Laptop';
    failure = error;
    named(card.el, 'Add a device with the WireGuard app')[0].click();
    await settle();
    assert.ok(visibleText(card.el).includes(said), said);
  }
  assert.deepEqual(shown, [], 'no configuration, no dialog');
  card.destroy();
});

/** Everything a tree holds as text: its text and every attribute (an SVG path is an attribute). */
function serialize(node) {
  if (node.data !== undefined) return node.data;
  return [...(node.attributes ?? new Map())].map(([name, value]) => `${name}=${value}`).join(' ') + (node.childNodes ?? []).map(serialize).join('');
}

test('the dialog shows the QR code, the text folded under it, and that it is shown once; closed, nothing of it is left', async () => {
  const closed = showConfigQR(CONFIG, LAPTOP);
  const dialog = all(browser.document.body, (node) => node.localName === 'dialog')[0];
  assert.ok(dialog?.open, 'a modal dialog');
  const text = visibleText(dialog);
  assert.ok(text.includes('Scan this with the WireGuard app'), text);
  assert.ok(text.includes('In the WireGuard app on Laptop, add a tunnel from a QR code and scan this one. On a computer, use the text below instead.'), text);
  assert.ok(text.includes('Shown once: the box keeps only the device’s public key.'), text);
  const picture = all(dialog, (node) => node.localName === 'svg')[0];
  assert.ok(picture, 'the QR code');
  const { encodeQR, qrPath } = await import('../web/js/qr.js');
  const code = encodeQR(CONFIG);
  assert.equal(picture.getAttribute('viewBox'), `0 0 ${code.size + 8} ${code.size + 8}`, 'with its quiet zone');
  assert.equal(all(picture, (node) => node.localName === 'path')[0].getAttribute('d'), qrPath(code), 'the configuration’s code');
  const details = all(dialog, (node) => node.localName === 'details')[0];
  assert.equal(all(details, (node) => node.localName === 'summary')[0].textContent, 'The configuration as text');
  assert.equal(all(details, (node) => node.localName === 'pre')[0].textContent, CONFIG);
  named(dialog, 'Done')[0].click();
  assert.equal(await closed, undefined, 'the dialog hands nothing back');
  assert.equal(all(browser.document.body, (node) => node.localName === 'dialog').length, 0, 'the dialog is gone');
  assert.ok(!serialize(browser.document.body).includes('PrivateKey'), 'and with it the configuration');
  assert.equal(localStorage.length, 0);
});

// MARK: What the box can't do, and the refresh

test('a box without Away from home says it is part of Camera Bridge OS, with no switch', async () => {
  let loads = 0;
  const card = await cardFor(() => { loads += 1; throw refusal(503, 'unavailable', 'Away from home is part of Camera Bridge OS.'); });
  const text = visibleText(card.el);
  assert.ok(text.includes('Away from home is part of Camera Bridge OS.'), text);
  assert.equal(switchOf(card.el), undefined, 'no switch');
  assert.deepEqual(all(card.el, (node) => node.localName === 'button'), []);
  assert.ok(!text.includes(DESCRIPTION));
  assert.equal(loads, 1);
  card.destroy();
});

test('a first read that fails is tried again every 15 s until it works', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    let loads = 0;
    let fails = true;
    const card = await cardFor(() => { loads += 1; if (fails) throw refusal(0, 'network', 'The bridge didn’t answer.'); return OFF; });
    assert.ok(visibleText(card.el).includes('The bridge didn’t answer.'));
    mock.timers.tick(15_000);
    await settle();
    assert.equal(loads, 2, 'tried again');
    fails = false;
    mock.timers.tick(15_000);
    await settle();
    assert.equal(loads, 3);
    assert.ok(switchOf(card.el) && !visibleText(card.el).includes('The bridge didn’t answer.'), 'read: the switch, and no error');
    mock.timers.tick(60_000);
    await settle();
    assert.equal(loads, 3, 'off once read: no more reads');

    // A box without Away from home is not asked again.
    let unavailable = 0;
    const older = await cardFor(() => { unavailable += 1; throw refusal(503, 'unavailable', 'Away from home is part of Camera Bridge OS.'); });
    mock.timers.tick(60_000);
    await settle();
    assert.equal(unavailable, 1);
    older.destroy();
    card.destroy();
  } finally {
    mock.timers.reset();
  }
});

test('a read that changes only the times updates the lines in place: the keyboard, an open Check and the alert stay', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  const focused = [];
  const savedFocus = FakeElement.prototype.focus;
  FakeElement.prototype.focus = function focus() { focused.push(this); };
  try {
    let clock = NOW;
    let answer = on({ state: 'working', devices: [PHONE, LAPTOP] });
    const card = await cardFor(() => answer, { now: () => clock });
    const lines = () => byClass(card.el, 'away-device-line');
    const [phoneLine] = lines();
    const [removeButton] = named(byClass(card.el, 'away-device')[0], 'Remove');
    // A minute later, with a new handshake: only the phone's line changes, in the same node.
    clock = NOW + MINUTE;
    answer = on({ state: 'working', devices: [{ ...PHONE, lastHandshake: iso(NOW + 30_000) }, LAPTOP] });
    mock.timers.tick(15_000);
    await settle();
    assert.equal(lines()[0], phoneLine, 'the same line');
    assert.equal(phoneLine.textContent, 'Reached from away: iPhone, 6 minutes ago.');
    assert.equal(named(byClass(card.el, 'away-device')[0], 'Remove')[0], removeButton, 'the same button, so the keyboard stays on it');

    // A problem's alert is not drawn again by a read that changes nothing on it.
    answer = on({ state: 'problem', problem: 'The VPN interface isn’t up.', devices: [PHONE] });
    mock.timers.tick(15_000);
    await settle();
    const [alert] = byClass(card.el, 'away-problem');
    clock += MINUTE;
    mock.timers.tick(15_000);
    await settle();
    assert.equal(byClass(card.el, 'away-problem')[0], alert, 'the same alert, so it isn’t said again');

    // An open Check stays open across a change that does draw the card again.
    answer = on({ state: 'setup', devices: [] });
    mock.timers.tick(15_000);
    await settle();
    const check = () => all(card.el, (node) => node.localName === 'details')[0];
    check().open = true;
    check().dispatchEvent({ type: 'toggle', target: check() });
    answer = on({ state: 'setup', router: 'eero', devices: [] });
    mock.timers.tick(15_000);
    await settle();
    assert.ok(byClass(card.el, 'away-router')[0].textContent.includes('eero app'), 'drawn again');
    assert.equal(check().open, true, 'and Check is still open');

    // The keyboard goes back to the same control when the card is drawn again.
    const [add] = named(card.el, 'Add a device with the WireGuard app');
    browser.document.activeElement = add;
    answer = on({ state: 'setup', router: null, devices: [] });
    mock.timers.tick(15_000);
    await settle();
    const [again] = named(card.el, 'Add a device with the WireGuard app');
    assert.notEqual(again, add, 'drawn again');
    assert.equal(focused.at(-1), again, 'the keyboard is on the new button');
    card.destroy();
  } finally {
    FakeElement.prototype.focus = savedFocus;
    delete browser.document.activeElement;
    mock.timers.reset();
  }
});

test('the keyboard comes back to Try again once its action ends', async () => {
  const focused = [];
  const savedFocus = FakeElement.prototype.focus;
  FakeElement.prototype.focus = function focus() { focused.push(this); };
  try {
    let release;
    const card = await cardFor(on({ state: 'problem', problem: 'The VPN interface isn’t up.' }), {
      setOn: () => new Promise((resolve) => { release = resolve; }),
    });
    const [button] = named(card.el, 'Try again');
    browser.document.activeElement = button;
    button.click();
    await settle();
    assert.equal(named(card.el, 'Try again')[0].disabled, true, 'waiting for the box');
    browser.document.activeElement = browser.document.body;   // a disabled control loses the keyboard
    release(on({ state: 'problem', problem: 'The firewall isn’t loaded, so Away from home can’t open its port.' }));
    await settle();
    const [again] = named(card.el, 'Try again');
    assert.ok(!again.disabled, 'no longer waiting');
    assert.equal(focused.at(-1), again, 'the keyboard is back on Try again');
    card.destroy();
  } finally {
    FakeElement.prototype.focus = savedFocus;
    delete browser.document.activeElement;
  }
});

test('a card that can’t be read says why', async () => {
  const card = await cardFor(() => { throw refusal(0, 'network', 'The bridge didn’t answer. Check that it is on and that this device is on the same network.'); });
  assert.ok(visibleText(card.el).includes('The bridge didn’t answer. Check that it is on and that this device is on the same network.'));
  assert.equal(switchOf(card.el), undefined, 'on or off is not known');
  card.destroy();

  const silent = await cardFor(() => { throw new Error(''); });
  assert.ok(visibleText(silent.el).includes('Away from home can’t be read right now.'));
  silent.destroy();
});

test('while on, the card reads itself again every 15 s; off, it doesn’t', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    let loads = 0;
    let answer = on({ state: 'working', devices: [PHONE] });
    const card = await cardFor(() => { loads += 1; return answer; });
    assert.equal(loads, 1);
    mock.timers.tick(14_999);
    await settle();
    assert.equal(loads, 1);
    mock.timers.tick(1);
    await settle();
    assert.equal(loads, 2);
    answer = OFF;
    mock.timers.tick(15_000);
    await settle();
    assert.equal(loads, 3, 'the read that finds it off');
    assert.equal(isOn(card.el), false);
    mock.timers.tick(60_000);
    await settle();
    assert.equal(loads, 3, 'off: no more reads');
    card.destroy();

    let quick = 0;
    const often = await cardFor(() => { quick += 1; return on(); }, { every: 1000 });
    mock.timers.tick(3000);
    await settle();
    assert.ok(quick >= 2, `every: ${quick}`);
    often.destroy();
  } finally {
    mock.timers.reset();
  }
});

test('destroy() stops the refresh, and a late answer is not drawn', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    let loads = 0;
    const card = await cardFor(() => { loads += 1; return on(); });
    card.destroy();
    mock.timers.tick(60_000);
    await settle();
    assert.equal(loads, 1);
  } finally {
    mock.timers.reset();
  }
  let release;
  const late = made(createAwayCard({ load: () => new Promise((resolve) => { release = resolve; }), now: () => NOW }));
  await settle();
  late.destroy();
  release(on());
  await settle();
  assert.equal(switchOf(late.el), undefined, 'the late answer is not drawn');
});

test('an answer to an older read never replaces a newer one', async () => {
  const pending = [];
  const card = made(createAwayCard({ load: () => new Promise((resolve) => pending.push(resolve)), now: () => NOW }));
  await settle();
  card.refresh();
  await settle();
  pending[1](on({ state: 'working', devices: [PHONE] }));
  await settle();
  pending[0](OFF);
  await settle();
  assert.equal(isOn(card.el), true, 'the newer answer stands');
  assert.deepEqual(rowIDs(card), ['d1']);
  card.destroy();
});

// MARK: The bridge's routes

test('without injected functions the card calls GET away, GET system/secure-address, POST away {on}, POST away/devices {name} and DELETE away/devices/:id', async () => {
  const realFetch = globalThis.fetch;
  const calls = [];
  let current = OFF;
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    const method = init.method ?? 'GET';
    calls.push([method, path, init.body ? JSON.parse(init.body) : undefined]);
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
    if (method === 'GET' && path === 'away') return json(200, current);
    if (method === 'GET' && path === 'system/secure-address') return json(200, { available: true, enabled: true });
    if (method === 'POST' && path === 'away') { current = JSON.parse(init.body).on ? on() : OFF; return json(200, current); }
    if (method === 'POST' && path === 'away/devices') { current = on({ devices: [LAPTOP] }); return json(201, { device: LAPTOP, config: CONFIG }); }
    if (method === 'DELETE') { current = on(); return new Response(null, { status: 204 }); }
    return json(404, { error: 'not_found', message: 'That doesn’t exist.' });
  };
  const card = made(createAwayCard({ askName: async () => 'Laptop', showQR: async () => {}, confirm: async () => true, now: () => NOW }));
  try {
    await settle();
    flip(switchOf(card.el), true);
    await settle();
    named(card.el, 'Add a device with the WireGuard app')[0].click();
    await settle();
    named(byClass(card.el, 'away-device')[0], 'Remove')[0].click();
    await settle();
    assert.deepEqual(calls, [
      ['GET', 'away', undefined],
      ['GET', 'system/secure-address', undefined],
      ['POST', 'away', { on: true }],
      ['POST', 'away/devices', { name: 'Laptop' }],
      ['GET', 'away', undefined],
      ['DELETE', 'away/devices/d2', undefined],
      ['GET', 'away', undefined],
    ]);
    assert.deepEqual(rowIDs(card), []);
  } finally {
    card.destroy();
    globalThis.fetch = realFetch;
  }
});

// MARK: Settings

const SETTINGS = {
  bridgeName: 'Bridge', timeZone: 'UTC', logLevel: 'info', basePort: 21100, sensorsBridgePort: 21190, webhookEnabled: false, webhookPort: 21180,
  ai: { provider: 'anthropic', model: 'claude-haiku-5-5', keySaved: true, keyHint: '0000', today: 0, last7Days: 0, paused: false, needsRecordingsFolder: false },
};

/**
 * Settings drawn over a bridge that answers the settings and GET away (`away`); `run` gets the page, the requests made, what was scrolled to
 * and focused, and `leave()`, which takes the page away as the router does (the bridge stays until the test ends).
 */
async function withSettings({ params, away }, run) {
  const { renderSettings } = await import('../web/js/screens/settings.js');
  const realFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url, init = {}) => {
    const key = `${init.method ?? 'GET'} ${String(url).replace('/api/v1/', '')}`;
    requests.push(key);
    const answer = { 'GET settings': SETTINGS, 'GET away': away }[key];
    if (!answer) throw new TypeError('fetch failed (no bridge in this test)');
    return new Response(JSON.stringify(answer), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  const scrolled = [];
  const focused = [];
  const saved = FakeElement.prototype.focus;
  FakeElement.prototype.focus = function focus() { focused.push(this); };
  FakeElement.prototype.scrollIntoView = function scrollIntoView() { scrolled.push(this); };
  const proto = FakeElement.prototype;
  const savedQuery = proto.querySelector;
  proto.querySelector = function querySelector(selector) { return selector === 'h2' ? all(this, (node) => node.localName === 'h2')[0] ?? null : null; };
  let screen = null;
  let left = false;
  const leave = () => {
    if (left || !screen) return;
    left = true;
    screen.el.remove();
    screen.destroy();
  };
  try {
    screen = renderSettings({ params, setTitle: () => {} });
    browser.document.append(screen.el);
    const recordingHost = () => all(screen.el, (node) => node.getAttribute('id') === 'recording')[0];
    for (let i = 0; i < 400 && !recordingHost()?.firstChild; i += 1) await tick();   // the recording screens load
    for (let i = 0; i < 20; i += 1) await tick();
    await run({ screen, requests, scrolled, focused, leave, card: byClass(screen.el, 'away-card')[0] });
  } finally {
    leave();
    FakeElement.prototype.focus = saved;
    delete FakeElement.prototype.scrollIntoView;
    proto.querySelector = savedQuery;
    globalThis.fetch = realFetch;
  }
}

test('Settings has an Away from home section after Security, holding the card', async () => {
  await withSettings({ params: [], away: on({ state: 'working', devices: [PHONE] }) }, ({ screen, requests, scrolled, card }) => {
    const titles = all(screen.el, (node) => node.classList?.contains('section-title')).map((node) => node.textContent);
    assert.equal(titles.indexOf('Away from home'), titles.indexOf('Security') + 1, `sections: ${titles.join(', ')}`);
    const section = all(screen.el, (node) => node.classList?.contains('settings-section')).find((node) => node.childNodes[0].textContent === 'Away from home');
    assert.ok(section && card && section.contains(card), 'the card is in it');
    assert.ok(visibleText(card).includes('Reached from away: iPhone'), 'and has read the box’s card');
    assert.ok(requests.includes('GET away'));
    assert.deepEqual(scrolled, [], '#/settings scrolls nowhere');
  });
});

test('#/settings/away opens Settings at the card, with the keyboard on its heading; leaving the page stops the card', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    await withSettings({ params: ['away'], away: on({ state: 'working', devices: [PHONE] }) }, async ({ scrolled, focused, card, requests, leave }) => {
      assert.equal(scrolled.length, 1, 'once');
      assert.equal(scrolled[0], card, 'to the Away from home card');
      const heading = all(card, (node) => node.localName === 'h2')[0];
      assert.equal(heading.getAttribute('tabindex'), '-1', 'a heading takes the focus only with a tabindex');
      assert.ok(focused.includes(heading));

      const reads = () => requests.filter((request) => request === 'GET away').length;
      const first = reads();
      mock.timers.tick(15_000);
      await settle();
      assert.equal(reads(), first + 1, 'on the page, the card reads itself again after 15 s');
      leave();
      mock.timers.tick(60_000);
      await settle();
      assert.equal(reads(), first + 1, 'the page is gone: the card reads nothing more');
    });
  } finally {
    mock.timers.reset();
  }
});

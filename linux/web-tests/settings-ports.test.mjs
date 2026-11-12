// The Apple Home ports and Webhook cards of Settings (screens/settings.js): on Camera Bridge OS the ports a person can choose are the ones the
// bridge's firewall opens to the local network (TCP 21090 to 21199, linux/os/mkosi.extra/etc/nftables.conf; the first camera port anywhere from
// 21100 to 21199, as the bridge rules). A new port outside them is refused on the page; a port saved before is kept as it is, and the card says
// plainly that the network can't reach it. A development daemon (GET system's mode "development") has
// no firewall: no such limits or warnings. The pure rules, then the cards in the fake browser with a made-up bridge.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let settingsModule;
let storeModule;
let current;           // what GET settings answers
let mode = 'installed';   // what GET system says the bridge runs as
const patches = [];    // the bodies of PATCH settings, in order

const DEFAULTS = {
  bridgeName: 'Bridge', timeZone: 'UTC', logLevel: 'info', basePort: 21100, sensorsBridgePort: 21099, webhookEnabled: true, webhookPort: 21090,
  webhookToken: '00000000000000000000000000000000', motionShadowTest: false, cameraOrder: [],
  ai: { provider: null, keySaved: false, today: 0, last7Days: 0, paused: false, needsRecordingsFolder: false },
};
const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

before(async () => {
  browser = installFakeBrowser();
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    if (path === 'settings' && (init.method ?? 'GET') === 'GET') return reply(200, current);
    if (path === 'system') return reply(200, { product: 'Camera Bridge OS', version: '0.1.135', mode });
    if (path === 'settings' && init.method === 'PATCH') {
      const body = JSON.parse(init.body);
      patches.push(body);
      current = { ...current, ...body };
      return reply(200, current);
    }
    return reply(404, { error: 'not_found', message: 'There is nothing here.' });
  };
  settingsModule = await import('../web/js/screens/settings.js');
  storeModule = await import('../web/js/store.js');
});
after(() => browser?.restore());

const settle = async () => { for (let i = 0; i < 20; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const visibleText = (node) => (node.hidden ? '' : node.data !== undefined ? node.data : (node.childNodes ?? []).map(visibleText).join(''));
const card = (page, title) => all(page.el, (node) => node.classList?.contains('card') && all(node, (n) => n.localName === 'h2')[0]?.textContent === title)[0];
const inputs = (node) => all(node, (n) => n.localName === 'input' && n.getAttribute('type') === 'number');
const warnings = (node) => all(node, (n) => n.classList?.contains('banner') && n.classList.contains('warning')).map(visibleText);
const submit = async (form) => { form.dispatchEvent({ type: 'submit', target: form, preventDefault() {} }); await settle(); };

/** The store holds `count` cameras (the page does not count them; the first camera port's limit is the same whatever the number). */
function withCameras(count) {
  storeModule.store.cameras = new Map(Array.from({ length: count }, (_, i) => [`cam-${i}`, { id: `cam-${i}`, name: `Camera ${String(i).padStart(2, '0')}` }]));
}

async function open(saved, { bridgeMode = 'installed', cameras = 0 } = {}) {
  current = { ...DEFAULTS, ...saved };
  mode = bridgeMode;
  withCameras(cameras);
  patches.length = 0;
  const page = settingsModule.renderSettings({ params: [], setTitle: () => {} });
  browser.document.body.append(page.el);
  await settle();
  return page;
}
function close(page) {
  page.el.remove();
  page.destroy();
}

// --- the rules ---------------------------------------------------------------------------------------------------------------------

test('the page’s ranges are the firewall’s: 21090 to 21199 for the webhook and the sensors bridge, 21100 to 21199 for the cameras', () => {
  assert.deepEqual({ ...settingsModule.OPEN_PORTS }, { low: 21090, high: 21199 });
  assert.deepEqual({ ...settingsModule.CAMERA_PORTS }, { low: 21100, high: 21199 });
});

test('on the box the first camera port may be anywhere from 21100 to 21199, whatever the number of cameras; off the box any port from 1024', () => {
  const { portRanges } = settingsModule;
  const plain = (r) => ({ base: { ...r.base }, open: { ...r.open } });
  assert.deepEqual(plain(portRanges()), { base: { low: 21100, high: 21199 }, open: { low: 21090, high: 21199 } });
  assert.deepEqual(plain(portRanges({ onTheBox: false })), { base: { low: 1024, high: 65535 }, open: { low: 1024, high: 65535 } });
});

test('a ports form sends only the ports that changed, each inside its range', () => {
  const { portChanges, OPEN_PORTS, CAMERA_PORTS } = settingsModule;
  const fields = (base, sensors) => [{ key: 'basePort', value: base, range: CAMERA_PORTS, name: 'first camera port' },
    { key: 'sensorsBridgePort', value: sensors, range: OPEN_PORTS, name: 'sensors bridge port' }];
  assert.deepEqual(portChanges(fields('21150', '21099'), DEFAULTS), { changes: { basePort: 21150 } });
  assert.deepEqual(portChanges(fields(' 21100 ', '21199'), DEFAULTS), { changes: { sensorsBridgePort: 21199 } });
  assert.deepEqual(portChanges(fields('21100', '21099'), DEFAULTS), { changes: {} }, 'nothing changed: nothing is sent');
  for (const base of ['21099', '21200', '1024', '0', '', 'abc', '21150.5', '-21150', '121150']) {
    assert.deepEqual(portChanges(fields(base, '21099'), DEFAULTS), { error: 'Choose a first camera port from 21100 to 21199.' }, JSON.stringify(base));
  }
  assert.deepEqual(portChanges(fields('21100', '21089'), DEFAULTS), { error: 'Choose a sensors bridge port from 21090 to 21199.' });
  assert.deepEqual(portChanges(fields('21100', '21200'), DEFAULTS), { error: 'Choose a sensors bridge port from 21090 to 21199.' });
});

test('a port saved outside the range is kept as it is: it is not sent, and the other port can still change', () => {
  const { portChanges, OPEN_PORTS, CAMERA_PORTS } = settingsModule;
  const saved = { ...DEFAULTS, basePort: 30000, sensorsBridgePort: 51826 };
  const fields = (base, sensors) => [{ key: 'basePort', value: base, range: CAMERA_PORTS, name: 'first camera port' },
    { key: 'sensorsBridgePort', value: sensors, range: OPEN_PORTS, name: 'sensors bridge port' }];
  assert.deepEqual(portChanges(fields('30000', '21099'), saved), { changes: { sensorsBridgePort: 21099 } });
  assert.deepEqual(portChanges(fields('21100', '51826'), saved), { changes: { basePort: 21100 } });
  assert.deepEqual(portChanges(fields('30001', '51826'), saved), { error: 'Choose a first camera port from 21100 to 21199.' }, 'another port outside is still new');
});

test('the saved ports the network can’t reach are named, each in a plain sentence; port 0 and an idle webhook are not judged', () => {
  const { unreachablePorts } = settingsModule;
  assert.deepEqual(unreachablePorts(DEFAULTS), {});
  assert.deepEqual(unreachablePorts({ ...DEFAULTS, basePort: 21199, sensorsBridgePort: 21090, webhookPort: 21199 }), {});
  const all3 = unreachablePorts({ ...DEFAULTS, basePort: 21090, sensorsBridgePort: 51826, webhookPort: 8123 });
  assert.deepEqual(Object.keys(all3).sort(), ['basePort', 'sensorsBridgePort', 'webhookPort']);
  assert.equal(all3.basePort, 'New cameras would get ports from 21090 upward, which your network can’t reach: the bridge’s firewall keeps them closed, so Apple Home could not add those cameras. Choose a first camera port from 21100 to 21199.');
  assert.equal(all3.sensorsBridgePort, 'Your network can’t reach the sensors bridge on port 51826: the bridge’s firewall keeps that port closed, so Apple Home can’t add it or use it. Choose a port from 21090 to 21199.');
  assert.equal(all3.webhookPort, 'Your network can’t reach the webhook on port 8123: the bridge’s firewall keeps that port closed, so requests from other systems don’t arrive. Choose a port from 21090 to 21199.');
  assert.deepEqual(unreachablePorts({ ...DEFAULTS, sensorsBridgePort: 0, webhookEnabled: false, webhookPort: 8123 }), {});
  assert.deepEqual(unreachablePorts({ ...DEFAULTS, basePort: 38100, webhookPort: 8123 }, { onTheBox: false }), {}, 'a development daemon has no firewall');
});

// --- the cards -----------------------------------------------------------------------------------------------------------------------

test('the ports card says which ports the firewall lets in, its fields are limited to them, and nothing is wrong at the defaults', async () => {
  const page = await open({});
  try {
    const ports = card(page, 'Apple Home ports');
    const text = visibleText(ports);
    assert.match(text, /Each camera is its own accessory with its own port, from 21100 to 21199\. The sensors bridge and the webhook use ports from 21090 to 21199\. These are the ports the bridge’s firewall lets in from your network\./);
    assert.doesNotMatch(text, /allows them through its firewall/, 'the old sentence (the cameras’ range only) is gone');
    const [base, sensors] = inputs(ports);
    assert.deepEqual([base.getAttribute('min'), base.getAttribute('max'), base.value], ['21100', '21199', 21100]);
    assert.deepEqual([sensors.getAttribute('min'), sensors.getAttribute('max'), sensors.value], ['21090', '21199', 21099]);
    const [port] = inputs(card(page, 'Webhook'));
    assert.deepEqual([port.getAttribute('min'), port.getAttribute('max'), port.value], ['21090', '21199', 21090]);
    assert.deepEqual([...warnings(ports), ...warnings(card(page, 'Webhook'))], []);
  } finally {
    close(page);
  }
});

test('ports saved outside the range: each card says the network can’t reach them', async () => {
  const page = await open({ basePort: 30000, sensorsBridgePort: 51826, webhookPort: 8123 });
  try {
    const shown = warnings(card(page, 'Apple Home ports'));
    assert.equal(shown.length, 2, shown.join(' | '));
    assert.match(shown[0], /^New cameras would get ports from 30000 upward, which your network can’t reach/);
    assert.match(shown[1], /^Your network can’t reach the sensors bridge on port 51826/);
    const hook = warnings(card(page, 'Webhook'));
    assert.equal(hook.length, 1, hook.join(' | '));
    assert.match(hook[0], /^Your network can’t reach the webhook on port 8123: the bridge’s firewall keeps that port closed/);
  } finally {
    close(page);
  }
});

test('saving the ports sends only what changed, so a port saved outside the range stays as it is', async () => {
  const page = await open({ basePort: 21100, sensorsBridgePort: 51826 });
  try {
    const ports = card(page, 'Apple Home ports');
    const [base] = inputs(ports);
    base.value = '21120';
    await submit(ports);
    assert.deepEqual(patches, [{ basePort: 21120 }]);
    assert.equal(current.sensorsBridgePort, 51826, 'kept');
  } finally {
    close(page);
  }
});

test('a new port outside the range is refused on the page: nothing is sent and the card says which ports to choose', async () => {
  const page = await open({});
  try {
    let ports = card(page, 'Apple Home ports');
    let [base, sensors] = inputs(ports);
    base.value = '21200';
    await submit(ports);
    ports = card(page, 'Apple Home ports');
    assert.deepEqual(patches, []);
    assert.match(visibleText(ports), /Choose a first camera port from 21100 to 21199\./);
    [base, sensors] = inputs(ports);
    base.value = '21100';
    sensors.value = '51826';
    await submit(ports);
    assert.deepEqual(patches, []);
    assert.match(visibleText(card(page, 'Apple Home ports')), /Choose a sensors bridge port from 21090 to 21199\./);
    sensors.value = '21189';
    await submit(card(page, 'Apple Home ports'));
    assert.deepEqual(patches, [{ sensorsBridgePort: 21189 }]);
  } finally {
    close(page);
  }
});

test('the webhook’s port follows the same rule', async () => {
  const page = await open({ webhookPort: 8123 });
  try {
    const form = () => all(card(page, 'Webhook'), (n) => n.localName === 'form')[0];
    const [port] = inputs(form());
    port.value = '8124';
    await submit(form());
    assert.deepEqual(patches, []);
    assert.match(visibleText(card(page, 'Webhook')), /Choose a webhook port from 21090 to 21199\./);
    port.value = '8123';
    await submit(form());
    assert.deepEqual(patches, [], 'the saved port, unchanged: nothing to send');
    port.value = '21095';
    await submit(form());
    assert.deepEqual(patches, [{ webhookPort: 21095 }]);
    assert.deepEqual(warnings(card(page, 'Webhook')), [], 'in range now: no warning');
  } finally {
    close(page);
  }
});

test('with 10 cameras the first camera port may still be 21195: cameras keep their ports, and a new one gets the lowest free port from there', async () => {
  const page = await open({}, { cameras: 10 });
  try {
    const ports = card(page, 'Apple Home ports');
    const [base] = inputs(ports);
    assert.equal(base.getAttribute('max'), '21199');
    assert.match(visibleText(ports), /From 21100 to 21199\. New cameras get ports from here upward\. Cameras you already added keep theirs\./);
    base.value = '21195';
    await submit(ports);
    assert.deepEqual(patches, [{ basePort: 21195 }]);
  } finally {
    close(page);
    withCameras(0);
  }
});

test('a development daemon (no firewall): no firewall sentence, no warnings, and any port from 1024 is sent', async () => {
  const page = await open({ basePort: 38100, sensorsBridgePort: 0, webhookPort: 8123 }, { bridgeMode: 'development' });
  try {
    const ports = card(page, 'Apple Home ports');
    const text = visibleText(ports) + visibleText(card(page, 'Webhook'));
    assert.doesNotMatch(text, /firewall|can’t reach|21199/, text);
    assert.deepEqual([...warnings(ports), ...warnings(card(page, 'Webhook'))], []);
    const [base, sensors] = inputs(ports);
    assert.deepEqual([base.getAttribute('min'), base.getAttribute('max')], ['1024', '65535']);
    sensors.value = '30000';
    await submit(ports);
    assert.deepEqual(patches, [{ sensorsBridgePort: 30000 }], 'the saved first camera port (38100) is kept, the new sensors port sent');
  } finally {
    close(page);
  }
});

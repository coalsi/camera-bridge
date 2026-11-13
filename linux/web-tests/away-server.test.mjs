// Away from home on the dev server (web-dev/lib/server.mjs; the bridge's: WebApp+Away.swift): the page's four routes, answered as the bridge
// answers them, over a scenario `POST /__dev/away` sets. The phone's `viewer/away` routes are left out: the dev server has no device keys.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { startDevServer } from './support/dev-server.mjs';
import { ensureFixtures } from './support/fixtures.mjs';

const fixtures = ensureFixtures();

const CARD_KEYS = ['on', 'state', 'problem', 'port', 'address', 'name', 'router', 'addressChangedAt', 'devices'];
const DEVICE_KEYS = ['id', 'kind', 'name', 'lastHandshake', 'lastAwayAt'];
const ADDRESS = '2001:db8:4:7000:1a2b:3c4d:5e6f:7a8b';
const AWAY_NAME = 'devserver0123456789a.away.camera-bridge.app';

test('the dev server answers the Away from home routes like the bridge', { skip: fixtures.skip }, async () => {
  const server = await startDevServer();
  const { api } = server;
  const remove = (id, options) => api.send('DELETE', `away/devices/${id}`, options);
  try {
    // A session is needed for every one of them.
    assert.equal((await api.get('away', { auth: false })).status, 401);
    assert.equal((await api.post('away', { on: true }, { auth: false })).status, 401);
    assert.equal((await api.post('away/devices', { name: 'Laptop' }, { auth: false })).status, 401);
    assert.equal((await remove('0123456789abcdef0123456789abcdef', { auth: false })).status, 401);

    // Off: every key of the card, null where there is nothing.
    const off = (await api.get('away')).json;
    assert.deepEqual(Object.keys(off), CARD_KEYS);
    assert.deepEqual(off, { on: false, state: 'off', problem: null, port: 51820, address: null, name: null, router: null, addressChangedAt: null, devices: [] });
    assert.equal((await api.post('away/devices', { name: 'Laptop' })).json.error, 'away_off', 'no device while it is off');

    // The switch: a boolean, nothing else.
    const odd = await api.post('away', { on: 'yes' });
    assert.deepEqual([odd.status, odd.json.error, odd.json.field], [400, 'invalid', 'on']);
    assert.deepEqual([(await api.post('away', {})).status, (await api.post('away', {})).json.field], [400, 'on']);
    await api.post('system/secure-address/enabled', { enabled: false });
    assert.equal((await api.get('system/secure-address')).json.enabled, false);
    const turnedOn = await api.post('away', { on: true });
    assert.equal(turnedOn.status, 200);
    assert.deepEqual(Object.keys(turnedOn.json), CARD_KEYS);
    assert.deepEqual([turnedOn.json.on, turnedOn.json.state, turnedOn.json.address, turnedOn.json.name, turnedOn.json.port], [true, 'setup', ADDRESS, AWAY_NAME, 51820]);
    assert.equal((await api.get('system/secure-address')).json.enabled, true, 'turning it on turns the secure address on, as the bridge does');
    const kept = await api.post('system/secure-address/enabled', { enabled: false });
    assert.deepEqual([kept.status, kept.json.error, kept.json.message], [409, 'away_on', 'Away from home needs the secure address. Turn Away from home off first.']);

    // A device with the WireGuard app: its configuration once, then only the device.
    const unnamed = await api.post('away/devices', { name: '  ' });
    assert.deepEqual([unnamed.status, unnamed.json.error, unnamed.json.field, unnamed.json.message], [400, 'invalid', 'name', 'Give the device a name.']);
    assert.deepEqual([(await api.post('away/devices', {})).status, (await api.post('away/devices', { name: 7 })).status], [400, 400]);
    const added = await api.post('away/devices', { name: ' Laptop ' });
    assert.equal(added.status, 201);
    assert.deepEqual(Object.keys(added.json), ['device', 'config']);
    const { device, config } = added.json;
    assert.deepEqual(Object.keys(device), DEVICE_KEYS);
    assert.deepEqual([device.kind, device.name, device.lastHandshake, device.lastAwayAt], ['wireguard', 'Laptop', null, null]);
    assert.match(device.id, /^[0-9a-f]{32}$/, 'a path segment of the page’s Remove');
    assert.match(config, /^\[Interface\]\nPrivateKey = \S{44}\nAddress = 10\.123\.45\.\d+\/32\nMTU = 1280\n\n\[Peer\]\nPublicKey = \S{44}\nAllowedIPs = 10\.123\.45\.1\/32, \S+\/32\nEndpoint = \[2001:db8:4:7000:1a2b:3c4d:5e6f:7a8b\]:51820\n$/);
    assert.doesNotMatch(config, /PrivateKey = [A-Za-z0-9+/]{43}=/, 'placeholders, which no WireGuard app takes for a key');
    const listed = await api.get('away');
    assert.deepEqual(listed.json.devices, [device]);
    assert.ok(!listed.text.includes('PrivateKey') && !listed.text.includes('config'), 'the configuration is never answered again');

    // Remove: 204, then the device isn't there any more.
    const removed = await remove(device.id);
    assert.deepEqual([removed.status, removed.text], [204, '']);
    const again = await remove(device.id);
    assert.deepEqual([again.status, again.json.error, again.json.message], [404, 'not_found', 'That device isn’t there any more.']);
    assert.deepEqual((await api.get('away')).json.devices, []);

    // The scenario: what the card says.
    await api.dev('away', { state: 'working' });
    const working = (await api.get('away')).json;
    assert.equal(working.state, 'working');
    assert.ok(working.devices.some((one) => one.lastAwayAt !== null), 'a device has reached the box from away');
    await api.dev('away', { state: 'no_ipv6' });
    assert.deepEqual([(await api.get('away')).json.address, (await api.post('away/devices', { name: 'Laptop' })).json.error], [null, 'no_address']);
    await api.dev('away', { state: 'problem', problem: 'The VPN interface isn’t up.' });
    assert.deepEqual([(await api.get('away')).json.state, (await api.get('away')).json.problem], ['problem', 'The VPN interface isn’t up.']);
    await api.dev('away', { router: 'eero', state: 'address_changed' });
    const changed = (await api.get('away')).json;
    assert.deepEqual([changed.router, changed.state], ['eero', 'address_changed']);
    const lastAway = Math.max(0, ...changed.devices.filter((one) => one.lastAwayAt).map((one) => Date.parse(one.lastAwayAt)));
    assert.ok(lastAway > 0 && Date.parse(changed.addressChangedAt) > lastAway, 'after the last time a device reached it');

    // Off empties the devices and lets the secure address go.
    const turnedOff = (await api.post('away', { on: false })).json;
    assert.deepEqual([turnedOff.on, turnedOff.state, turnedOff.devices], [false, 'off', []]);
    assert.equal((await api.post('system/secure-address/enabled', { enabled: false })).status, 200);
    assert.equal((await api.post('system/secure-address/enabled', { enabled: true })).json.enabled, true);

    // A box without Away from home: 503 for every route.
    await api.dev('away', { available: false });
    for (const answer of [await api.get('away'), await api.post('away', { on: true }), await api.post('away/devices', { name: 'Laptop' }), await remove(device.id)]) {
      assert.deepEqual([answer.status, answer.json.error, answer.json.message], [503, 'unavailable', 'Away from home is part of Camera Bridge OS.']);
    }
  } finally {
    await server.close();
  }
});

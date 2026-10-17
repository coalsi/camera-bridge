// "Keep this camera local" (screens/camera-setup.js localOnlyCard): what the setup turned off or watches, the router steps that survive a
// factory reset, with step-by-step help for common routers, and the setup's words for "Watch its internet", in the fake browser.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let setup;
before(async () => {
  browser = installFakeBrowser();
  setup = await import('../web/js/screens/camera-setup.js');
});
after(() => browser?.restore());

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const tag = (root, name) => all(root, (node) => node.localName === name);

const camera = (steps = [], overrides = {}) => ({
  id: 'x', name: 'Patio', vendor: 'onvif', manufacturer: 'Hikvision', endpoint: { host: '192.168.77.21' },
  setupState: steps.length ? { version: 1, applied: '2026-10-17T10:00:00Z', steps: steps.map(([id, status]) => ({ id, status })) } : null, ...overrides,
});

test('the help is one closed disclosure with the router steps, the camera’s address in them', () => {
  const card = setup.localOnlyCard(camera());
  assert.equal(card.localName, 'details');
  assert.ok(!card.open, 'closed until opened');
  assert.equal(tag(card, 'summary')[0].textContent, 'Keep this camera local');
  assert.match(card.textContent, /Camera Bridge needs no internet to show or record this camera/);
  assert.match(card.textContent, /192\.168\.77\.21/);
  assert.match(card.textContent, /DHCP reservation/);
  assert.match(card.textContent, /takes it off your network/, 'the wrong kind of block is warned against');
  assert.match(card.textContent, /A guest network usually does the opposite/, 'a guest network is not offered as a camera network');
  assert.match(card.textContent, /What stops working: the maker’s phone app away from home/);
});

test('the address in the steps is the camera’s own only: none for a camera behind go2rtc or a UniFi console, or at a loopback address', () => {
  for (const overrides of [{ vendor: 'go2rtc', endpoint: { host: '127.0.0.1' }, integration: { service: 'tuya' } },
    { vendor: 'unifi', endpoint: { host: '192.168.77.1' }, integration: { service: 'unifiProtect' } },
    { vendor: 'rtsp', endpoint: { host: '127.0.0.1' } }, { vendor: 'onvif', endpoint: { host: 'localhost' } }, { vendor: 'onvif', endpoint: { host: '::1' } }]) {
    const card = setup.localOnlyCard(camera([], overrides));
    assert.ok(!card.textContent.includes(overrides.endpoint.host), `${overrides.vendor} at ${overrides.endpoint.host}: not named as the camera’s address`);
    assert.match(card.textContent, /DHCP reservation/, 'the steps stay');
  }
  const behind = setup.localOnlyCard(camera([], { vendor: 'unifi', endpoint: { host: '192.168.77.1' }, integration: { service: 'unifiProtect' } }));
  assert.match(behind.textContent, /use the camera’s own address/, 'the steps are for the camera itself, not the console or the helper');
  assert.match(setup.localOnlyCard(camera()).textContent, /\(192\.168\.77\.21\)/, 'a camera Camera Bridge reaches directly is named by its address');
});

test('removing a watched camera says Camera Bridge gives it its DNS back first, and what to do when the camera doesn’t answer', () => {
  const watched = camera([['internetWatch', 'done']], { setupBackup: { version: 1, internetWatch: { method: 'onvifMinimal', fromDHCP: true, servers: [] } } });
  assert.match(setup.removalNote(watched), /gives the camera its own DNS servers back first/);
  assert.match(setup.removalNote(watched), /change its DNS on the camera/);
  assert.equal(setup.removalNote(camera([['internetWatch', 'restored']])), '', 'nothing to give back');
  assert.equal(setup.removalNote(camera()), '');
});

test('each common router has its own steps to reserve the address and block the internet, and the words say menus differ', () => {
  const card = setup.localOnlyCard(camera());
  const routers = tag(card, 'details').filter((node) => node !== card);
  const names = routers.map((node) => tag(node, 'summary')[0].textContent);
  assert.deepEqual(names, ['eero', 'Google Nest Wifi or Google Wifi', 'UniFi', 'ASUS', 'TP-Link Deco', 'Netgear Orbi', 'Another router']);
  assert.deepEqual(setup.ROUTER_HELP.map((entry) => entry.name), names);
  for (const router of routers) {
    const steps = tag(router, 'li');
    assert.ok(steps.length >= 2, `${tag(router, 'summary')[0].textContent} has a step to reserve and one to block`);
    assert.match(steps[0].textContent, /reserv|Fixed IP/i);
    assert.match(router.textContent, /internet/i);
  }
  assert.match(card.textContent, /Menu names differ between routers and versions/);
  assert.match(card.textContent, /check that this camera’s picture still shows/, 'the person checks the camera still works');
  for (const entry of setup.ROUTER_HELP) {
    for (const line of [...entry.reserve, ...entry.block]) assert.ok(!/\b\d{1,3}(\.\d{1,3}){3}\b/.test(line('')), `${entry.name}: no address of its own in the words`);
  }
});

test('what the setup turned off and the Internet guard’s Watch are named, and that a factory reset undoes them', () => {
  const cloud = setup.localOnlyCard(camera([['cloud', 'done'], ['upnp', 'alreadyRight']]));
  assert.match(cloud.textContent, /The setup turned off its cloud \(Hik-Connect\) and UPnP on this camera\./);
  assert.match(cloud.textContent, /A factory reset undoes this/);
  const watched = setup.localOnlyCard(camera([['internetWatch', 'done'], ['cloud', 'refused']]));
  assert.match(watched.textContent, /The Internet guard watches its internet lookups\./);
  assert.ok(!/turned off/.test(tag(watched, 'p')[0].textContent), 'a refused step is not called done');
  const restored = setup.localOnlyCard(camera([['internetWatch', 'restored']]));
  assert.match(restored.textContent, /Camera Bridge needs no internet/);
});

test('the setup says what “Watch its internet” does before it is applied, and that Restore puts the camera’s DNS back', () => {
  const info = setup.summarize({ steps: [{ id: 'internetWatch', title: 'Watch its internet', status: 'willChange', changes: [{ label: 'DNS', now: 'from the router (DHCP)', after: 'the bridge (192.168.77.2)' }] }] });
  assert.equal(info.watchWillChange, true);
  assert.equal(setup.summarize({ steps: [{ id: 'internetWatch', status: 'alreadyRight' }] }).watchWillChange, false);
  assert.match(setup.SETUP_TEXT.watchNote, /^“Watch its internet” points the camera’s internet lookups at Camera Bridge, which blocks every one/);
  assert.match(setup.SETUP_TEXT.watchNote, /maker’s app stops working away from home/);
  assert.match(setup.SETUP_TEXT.restoreWhat, /its internet lookups \(Watch\)/);
  const card = setup.cameraSetupCard(camera(), { onDone() {} });
  assert.match(card.textContent, /its internet watched by the Internet guard/);
  assert.equal(all(card, (node) => node.classList.contains('local-only')).length, 1, 'the setup card keeps the help by default');
  assert.equal(all(setup.cameraSetupCard(camera(), { localHelp: false }), (node) => node.classList.contains('local-only')).length, 0,
    'the camera page shows the help in its Security card instead');
});

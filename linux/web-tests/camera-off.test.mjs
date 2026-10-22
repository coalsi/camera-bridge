// A camera that is turned off (isEnabled false): the line under its switch, the Cameras list (kept, greyed, "Turned off", no picture request),
// the Events page (no filter chip, its recordings' events still listed under its name) and the events of the Monitor's card.
// The Monitor wall itself is in monitor-wall.test.mjs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { settle } from './nvr-grid-helpers.mjs';
import { gatherEvents } from '../web/js/screens/wall-events-model.js';

const id = (n) => `00000000-0000-4000-8000-00000000000${n}`;
const T0 = new Date(2026, 9, 22, 14, 0).getTime();
const all = (root, match, out = []) => { for (const child of root.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); all(child, match, out); } return out; };
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));

test('the switch on the camera page says the camera stays in Apple Home with a "Camera off" picture', () => {
  const source = readFileSync(new URL('../web/js/screens/camera.js', import.meta.url), 'utf8');
  const line = /title: 'Turned on', desc: '([^']*)'/.exec(source)?.[1] ?? '';
  assert.match(line, /stays in Apple Home/);
  assert.match(line, /“Camera off” picture/);
  assert.match(source, /switchRow\(\{ title: 'Turned on'[^\n]*save\(\{ isEnabled: v \}/, 'the existing switch still saves isEnabled');
});

test('the Cameras list keeps a camera that is turned off, greyed, labelled "Turned off", and asks it for no picture', async () => {
  const browser = installFakeBrowser();
  globalThis.IntersectionObserver = class { constructor() {} observe(el) { el.visible = true; } disconnect() {} };
  const asked = [];
  const { store, putCamera } = await import('../web/js/store.js');
  const { renderCameras } = await import('../web/js/screens/cameras.js');
  const base = { kind: 'camera', vendorName: 'ONVIF', address: '', nvrEnabled: false, status: { paired: true } };
  store.cameras = new Map([
    [id(1), { ...base, id: id(1), name: 'Front door', isEnabled: true, status: { connection: 'online', paired: true } }],
    [id(2), { ...base, id: id(2), name: 'Garage', isEnabled: false, status: { connection: 'disabled', paired: true } }],
  ]);
  globalThis.Image = class { set src(url) { asked.push(url); } };
  const screen = renderCameras();
  try {
    const rows = all(screen.el, (node) => node.localName === 'tr' && node.dataset.id);
    assert.equal(rows.length, 2, 'both cameras are listed');
    const garage = rows.find((row) => row.dataset.id === id(2));
    assert.equal(garage.dataset.state, 'off', 'the stylesheet greys a row in this state');
    assert.match(garage.textContent, /Turned off/);
    garage.refreshPicture();
    assert.ok(!asked.some((url) => url.includes(id(2))), 'nothing is asked of a camera that is off');
    putCamera({ ...store.cameras.get(id(2)), isEnabled: true, status: { connection: 'online', paired: true } });
    assert.notEqual(all(screen.el, (node) => node.localName === 'tr' && node.dataset.id === id(2))[0].dataset.state, 'off', 'turned back on, the row follows');
  } finally {
    screen.destroy();
    store.cameras = new Map();
    delete globalThis.IntersectionObserver;
    delete globalThis.Image;
    browser.restore();
  }
  const css = readFileSync(new URL('../web/style.css', import.meta.url), 'utf8');
  assert.match(css, /\.cam-table tr\[data-state="off"\] \.cam-main \{ opacity: 0\.6; \}/);
});

test('the Events page has no filter for a camera that is turned off, and still lists the events of its recordings under its name', async () => {
  const browser = installFakeBrowser();
  const { store } = await import('../web/js/store.js');
  store.cameras.clear();
  store.cameras.set(id(1), { id: id(1), name: 'Front Door', isEnabled: true, status: {} });
  store.cameras.set(id(2), { id: id(2), name: 'Garage', isEnabled: false, status: { recentEvents: [{ name: 'Motion', date: new Date(T0 - 60_000).toISOString() }] } });
  const { createEventsPage } = await import('../web/js/screens/events.js');
  const requests = [];
  const events = [
    { id: 'a', cameraID: id(1), kind: 'Person', start: T0 - 5 * 60_000, end: null, recorded: true, description: null },
    { id: 'b', cameraID: id(2), kind: 'Person', start: T0 - 3 * 3_600_000, end: null, recorded: true, description: null },
  ];
  const thumbs = { tile() { const el = document.createElement('div'); el.dataset.state = 'idle'; return el; }, release() {}, destroy() {} };
  const page = createEventsPage({
    now: () => T0, thumbs, cameras: () => [...store.cameras.values()], onCameras: () => () => {}, scrolledDown: () => false,
    load: async (request) => { requests.push(request); return { events: events.filter((e) => e.start >= request.fromMs && e.start < request.toMs), more: false }; },
  });
  browser.document.append(page.el);
  try {
    await settle();
    const chips = all(page.el, (node) => node.localName === 'button' && node.dataset.id).map((node) => node.textContent);
    assert.deepEqual(chips, ['Front Door'], 'only the camera that is on is a filter');
    const rows = byClass(page.el, 'ev-item');
    assert.deepEqual(rows.map((row) => byClass(row, 'ev-camera')[0].textContent), ['Front Door', 'Garage'], 'the recording of the camera that is off is listed under its name');
    assert.ok(!rows.some((row) => /Motion/.test(row.textContent)), 'its last status events are not new events');
    assert.ok(requests[0].cameras.includes(id(2)), 'its recordings are still asked for');
  } finally {
    page.destroy();
    store.cameras.clear();
    browser.restore();
  }
});

test('the events of the Monitor leave out what a camera that is off last reported, and keep its archived events', () => {
  const cameras = [
    { id: id(1), name: 'Front Door', isEnabled: true, status: { recentEvents: [{ name: 'Motion', date: new Date(T0).toISOString() }] } },
    { id: id(2), name: 'Garage', isEnabled: false, status: { recentEvents: [{ name: 'Motion', date: new Date(T0).toISOString() }] } },
  ];
  const archived = [{ id: 'x', cameraID: id(2), kind: 'Person', start: T0 - 1000, end: null, recorded: true }];
  const events = gatherEvents({ cameras, archived });
  assert.deepEqual(events.map((e) => [e.cameraName, e.label]).sort(), [['Front Door', 'Motion'], ['Garage', 'Person']]);
});

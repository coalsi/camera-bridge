// What the Events page, its rows and the Monitor's events card draw (screens/events.js, events-row.js, wall-events.js), on the fake browser.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { settle } from './nvr-grid-helpers.mjs';

const T0 = new Date(2026, 9, 19, 14, 0).getTime();
const id = (n) => `00000000-0000-4000-8000-00000000000${n}`;

const all = (root, match, out = []) => { for (const child of root.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); all(child, match, out); } return out; };
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const byTag = (root, tag) => all(root, (node) => node.tagName.toLowerCase() === tag);

function fakeThumbs() {
  const made = [];
  return {
    made,
    released: [],
    tile(cameraId, atMs) { const el = document.createElement('div'); el.className = 'ev-thumb'; el.dataset.state = 'idle'; el.dataset.camera = cameraId; el.dataset.at = String(atMs); made.push(el); return el; },
    release(el) { this.released.push(el); },
    destroy() { this.destroyed = true; },
  };
}

function archived(n, minutesAgo, extra = {}) {
  return { id: `e${n}`, cameraID: id(1), kind: 'Person', start: T0 - minutesAgo * 60_000, end: null, recorded: true, description: null, ...extra };
}
const said = (summary, kind, concern) => ({ summary, kind, concern });

async function setup() {
  const browser = installFakeBrowser();
  const { store } = await import('../web/js/store.js');
  store.cameras.clear();
  store.cameras.set(id(1), { id: id(1), name: 'Front Door', aiDescriptions: true, status: {} });
  store.cameras.set(id(2), { id: id(2), name: 'Garage', aiDescriptions: false, status: {} });
  return { browser, store, done() { store.cameras.clear(); browser.restore(); } };
}

// MARK: The row

test('a row shows the picture, camera, time, type, what the AI saw and its words; the words stay text', async () => {
  const env = await setup();
  try {
    const { eventRow } = await import('../web/js/screens/events-row.js');
    const thumb = fakeThumbs().tile(id(1), T0);
    const base = { at: T0, endAt: T0 + 8000, cameraId: id(1), cameraName: 'Front Door', label: 'Person', level: 'detection', recorded: true };
    const described = eventRow({ ...base, description: { text: '<img src=x onerror=alert(1)> at the door', concern: 'alarm', kind: 'person' } },
      { thumb, href: `/nvr/${T0 - 3000}?camera=${id(1)}&play=1` });
    assert.equal(described.dataset.concern, 'alarm');
    const link = byTag(described, 'a')[0];
    assert.equal(link.getAttribute('href'), `#/nvr/${T0 - 3000}?camera=${id(1)}&play=1`, 'a row is a link into the Monitor');
    assert.ok(link.contains(thumb));
    assert.equal(byClass(described, 'ev-camera')[0].textContent, 'Front Door');
    assert.equal(byClass(described, 'ev-duration')[0].textContent, '8 s');
    assert.equal(byClass(described, 'ev-type')[0].textContent, 'Person');
    assert.equal(byClass(described, 'ev-chip')[0].textContent, 'Person');
    assert.equal(byClass(described, 'ev-chip')[0].dataset.kind, 'person');
    const sentence = byClass(described, 'ev-ai')[0];
    assert.equal(sentence.textContent, '<img src=x onerror=alert(1)> at the door');
    assert.equal(sentence.dataset.concern, 'alarm');
    assert.ok(sentence.childNodes.every((node) => !node.tagName), 'no element is made of the words');
    assert.match(link.getAttribute('aria-label'), /, person, alarm: <img/);
    assert.equal(all(described, (node) => node.getAttribute('style') !== null).length, 0, 'no inline style');
    assert.equal(all(described, (node) => /^(video|audio|canvas)$/i.test(node.tagName)).length, 0, 'no video on the page');

    const plain = eventRow({ ...base, endAt: null, description: null }, { thumb: fakeThumbs().tile(id(1), T0), href: '/nvr/1', describing: false });
    assert.equal(byClass(plain, 'ev-chip').length + byClass(plain, 'ev-ai').length + byClass(plain, 'ev-describing').length, 0, 'nothing of the AI without a description');
    assert.equal(plain.dataset.concern, '');

    const waiting = eventRow({ ...base, endAt: null, description: null }, { thumb: fakeThumbs().tile(id(1), T0), href: '/nvr/1', describing: true });
    assert.equal(byClass(waiting, 'ev-describing')[0].textContent, 'Describing…');

    const nothing = eventRow({ ...base, label: 'Motion', level: 'motion', description: { text: 'Nothing notable', concern: 'nothing', kind: 'nothing' } }, { thumb: fakeThumbs().tile(id(1), T0), href: '/nvr/1' });
    assert.equal(byClass(nothing, 'ev-ai')[0].dataset.concern, 'nothing');

    const unrecorded = eventRow({ ...base, recorded: false, description: null }, { thumb: fakeThumbs().tile(id(1), T0), href: null });
    assert.equal(byTag(unrecorded, 'a').length, 0, 'nothing to open');
    assert.equal(byClass(unrecorded, 'ev-note')[0].textContent, 'Not recorded');
    assert.equal(unrecorded.dataset.recorded, 'false');
  } finally { env.done(); }
});

// MARK: The Monitor's card

test('the Monitor’s events card shows the picture, what the AI saw, its dot and words, “Describing…” and a link to every event', async () => {
  const env = await setup();
  try {
    const { createWallEvents } = await import('../web/js/screens/wall-events.js');
    const now = T0 + 20_000;
    const stored = [
      archived(1, 5, { description: said('A person tries the door handle', 'person', 'alarm') }),
      archived(2, 0, { start: T0 + 5000 }),                                  // 15 s old, camera 1 is described: its words are on their way
      archived(3, 30, { kind: 'Motion', description: said('Leaves blow across the porch', 'nothing', 'routine') }),
    ];
    const thumbs = fakeThumbs();
    const picked = [];
    const context = { cameraIds: [id(1)], range: { fromMs: T0 - 3_600_000, toMs: Infinity }, extentOf: () => ({ oldest: T0 - 86_400_000, newest: T0 + 20_000 }) };
    const wall = createWallEvents({
      now: () => now, thumbs, onPick: (event) => picked.push(event), onChange: () => wall.update(context),
      loadEvents: async () => ({ events: stored, more: false }),
    });
    browser(env).document.append(wall.list);
    wall.update(context);
    await settle();
    const rows = byClass(wall.list, 'mon-event');
    assert.equal(rows.length, 3);
    assert.equal(thumbs.made.length, 3, 'a picture tile for each row');
    assert.deepEqual(thumbs.made.map((t) => Number(t.dataset.at)).sort(), [T0 - 1_800_000, T0 - 300_000, T0 + 5000].sort(), 'taken at each event’s start');
    assert.ok(rows.every((row, i) => byClass(row, 'ev-thumb').length === 1), 'one tile in each row');
    // newest first: the waiting one, the alarm, the quiet one
    assert.equal(byClass(rows[0], 'ev-describing')[0].textContent, 'Describing…');
    assert.equal(byClass(rows[1], 'ev-chip')[0].textContent, 'Person');
    assert.deepEqual([byClass(rows[1], 'mon-event-ai')[0].textContent, byClass(rows[1], 'mon-event-ai')[0].dataset.concern], ['A person tries the door handle', 'alarm']);
    assert.equal(byClass(rows[2], 'ev-chip')[0].textContent, 'Nothing');
    assert.equal(byClass(rows[2], 'mon-event-ai')[0].dataset.concern, 'nothing');
    assert.match(rows[1].getAttribute('aria-label'), /, person, alarm: A person tries the door handle$/);
    assert.equal(byClass(wall.head, 'mon-all-events')[0].getAttribute('href'), `#/events?cameras=${id(1)}`, 'All events, for the camera on its own');
    rows[1].closest = () => rows[1];                      // the fake DOM has no closest(); the list's click handler asks for it
    wall.list.dispatchEvent({ type: 'click', target: rows[1] });
    assert.equal(picked.length, 1, 'a click still plays from the event');
    assert.equal(picked[0].description.kind, 'person');
    wall.update({ ...context, cameraIds: [id(1), id(2)] });
    assert.equal(byClass(wall.head, 'mon-all-events')[0].getAttribute('href'), '#/events', 'and for the whole wall');
    wall.destroy();
    assert.equal(thumbs.destroyed, true);
  } finally { env.done(); }
});
const browser = (env) => env.browser;

// MARK: The page

function pageWith(env, { events = [], query = '', more = false, fail = null, requests = [] } = {}) {
  return import('../web/js/screens/events.js').then(({ createEventsPage }) => {
    const addresses = [];
    const thumbs = fakeThumbs();
    const page = createEventsPage({
      query, now: () => T0 + 60_000, thumbs, writeAddress: (text) => addresses.push(text), cameras: () => [...env.store.cameras.values()],
      onCameras: () => () => {}, scrolledDown: () => false,
      load: async (request) => {
        requests.push(request);
        if (fail) throw fail;
        return { events: events.filter((e) => e.start >= request.fromMs && e.start < request.toMs), more };
      },
    });
    env.browser.document.append(page.el);
    return { page, addresses, thumbs, requests, rows: () => byClass(page.el, 'ev-item') };
  });
}

test('the page lists events newest first in groups by day, each a link into the Monitor, with no video', async () => {
  const env = await setup();
  try {
    const events = [
      archived(1, 5, { description: said('A person tries the door handle', 'person', 'alarm') }),
      archived(2, 20, { kind: 'Motion' }),
      archived(3, 24 * 60 + 30, { kind: 'Vehicle', cameraID: id(2), description: said('A van parks across the driveway', 'vehicle', 'unusual') }),
    ];
    const view = await pageWith(env, { events });
    await settle();
    const days = byClass(view.page.el, 'ev-day');
    assert.deepEqual(days.map((day) => byTag(day, 'h2')[0].textContent), ['Today', 'Yesterday']);
    assert.deepEqual(view.rows().map((row) => byClass(row, 'ev-type')[0].textContent), ['Person', 'Motion', 'Vehicle']);
    assert.equal(byTag(view.rows()[0], 'a')[0].getAttribute('href'), `#/nvr/${T0 - 5 * 60_000 - 3000}?camera=${id(1)}&play=1`);
    assert.equal(all(view.page.el, (node) => /^(video|audio|canvas)$/i.test(node.tagName)).length, 0);
    assert.equal(view.thumbs.made.length, 3);
    const requestedCameras = view.requests[0].cameras;
    assert.deepEqual([...requestedCameras].sort(), [id(1), id(2)], 'the archive is asked for every camera');
    view.page.destroy();
  } finally { env.done(); }
});

test('filters narrow the list, are written to the address and are read back from it', async () => {
  const env = await setup();
  try {
    const events = [
      archived(1, 5, { description: said('A person tries the door handle', 'person', 'alarm') }),
      archived(2, 20, { kind: 'Motion' }),
      archived(3, 40, { kind: 'Vehicle', description: said('A van parks across the driveway', 'vehicle', 'unusual') }),
      archived(4, 60, { description: said('A man walks to the door', 'person', 'routine') }),
    ];
    const view = await pageWith(env, { events });
    await settle();
    const chip = (group, data) => all(view.page.el, (node) => node.classList?.contains('ev-filter') && node.dataset[group] === data)[0];
    assert.equal(view.rows().length, 4);

    chip('kind', 'person').click();
    assert.equal(view.rows().length, 2, 'what the AI saw: person');
    assert.equal(view.addresses.at(-1), 'saw=person');
    assert.equal(chip('kind', 'person').getAttribute('aria-pressed'), 'true');

    const concern = all(view.page.el, (node) => node.tagName === 'SELECT' && node.getAttribute('aria-label') === 'How much it matters')[0];
    concern.value = 'notable';
    concern.dispatchEvent({ type: 'change', target: concern });
    assert.deepEqual(view.rows().map((row) => row.dataset.concern), ['alarm'], 'alarm and unusual only, and a person');
    assert.equal(view.addresses.at(-1), 'saw=person&concern=notable');

    chip('type', 'Vehicle').click();
    assert.equal(view.rows().length, 0, 'a vehicle that the AI did not call a person');
    assert.match(view.page.el.textContent, /No events match/);
    all(view.page.el, (node) => node.textContent === 'Clear filters')[0].click();
    assert.equal(view.rows().length, 4);
    assert.equal(view.addresses.at(-1), '');
    view.page.destroy();

    // The same filters, from an address.
    const again = await pageWith(env, { events, query: 'saw=vehicle&concern=notable&range=24h' });
    await settle();
    assert.deepEqual(again.page.filters(), { cameras: [], types: [], saw: ['vehicle'], concern: 'notable', described: false, q: '', range: '24h' });
    assert.equal(again.rows().length, 1);
    again.page.destroy();
  } finally { env.done(); }
});

test('Load more asks the archive for the older part, and an empty place says why', async () => {
  const env = await setup();
  try {
    const events = Array.from({ length: 5 }, (_, i) => archived(i, i + 1));
    const view = await pageWith(env, { events, more: true });
    await settle();
    const button = all(view.page.el, (node) => node.tagName === 'BUTTON' && node.textContent === 'Load more')[0];
    assert.equal(button.hidden, false, 'the archive has older events');
    const before = view.requests.length;
    button.click();
    await settle();
    assert.ok(view.requests.length > before, 'the older page was asked for');
    view.page.destroy();

    const none = await pageWith(env, { events: [] });
    await settle();
    assert.match(none.page.el.textContent, /Nothing has happened yet/);
    none.page.destroy();

    const noPlace = await pageWith(env, { events: [], fail: Object.assign(new Error('archive_unavailable'), { status: 503 }) });
    await settle();
    assert.match(noPlace.page.el.textContent, /No place for recordings yet/);
    noPlace.page.destroy();
  } finally { env.done(); }
});

test('a new event waits behind a button while the person has scrolled down, and joins when asked', async () => {
  const env = await setup();
  try {
    const stored = [archived(1, 5), archived(2, 10)];
    const { createEventsPage } = await import('../web/js/screens/events.js');
    let clock = T0 + 60_000;
    let poke = () => {};
    const page = createEventsPage({
      now: () => clock, thumbs: fakeThumbs(), cameras: () => [...env.store.cameras.values()], onCameras: (fn) => { poke = fn; return () => {}; }, scrolledDown: () => true,
      load: async (request) => ({ events: stored.filter((e) => e.start >= request.fromMs && e.start < request.toMs), more: false }),
    });
    env.browser.document.append(page.el);
    await settle();
    const rows = () => byClass(page.el, 'ev-item');
    const held = byClass(page.el, 'ev-held')[0];
    assert.equal(rows().length, 2);
    assert.equal(held.hidden, true);
    stored.unshift(archived(3, 0, { start: T0 + 50_000 }));
    clock += 40_000;
    poke();
    await settle();
    await settle();
    assert.equal(rows().length, 2, 'the rows being read do not move');
    assert.equal(held.hidden, false);
    assert.equal(held.textContent, '1 new event');
    held.click();
    assert.equal(rows().length, 3, 'asked for, it joins at the top');
    assert.equal(held.hidden, true);
    page.destroy();
  } finally { env.done(); }
});

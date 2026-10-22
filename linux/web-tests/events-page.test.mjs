// The Events page: its model (screens/events-model.js), the thumbnails (nvr/thumbs.js), the row (screens/events-row.js) and the page (screens/events.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  EVENT_RANGES, concernRank, emptyFilters, eventKey, eventPath, filterEvents, filtersFromQuery, filtersToQuery, groupByDay, holdNewEvents,
  isDescribing, queryRange, typeChoices,
} from '../web/js/screens/events-model.js';
import { gatherEvents } from '../web/js/screens/wall-events-model.js';
import { createThumbnails } from '../web/js/nvr/thumbs.js';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { settle } from './nvr-grid-helpers.mjs';

const id = (n) => `00000000-0000-4000-8000-00000000000${n}`;
const NOW = new Date(2026, 9, 19, 15, 30).getTime();          // Monday 19 October 2026, 15:30 local
const local = (day, hour, minute = 0) => new Date(2026, 9, day, hour, minute).getTime();
const said = (text, kind, concern) => ({ text, kind, concern });

function event(n, at, extra = {}) {
  return { at, endAt: null, cameraId: id(1), cameraName: 'Front Door', label: 'Person', level: 'detection', recorded: true, description: null, ...extra, n };
}

// MARK: Model

test('filters round-trip through the address, and the defaults stay out of it', () => {
  assert.equal(filtersToQuery(emptyFilters()), '');
  const filters = {
    cameras: [id(1), id(2)], types: ['Person', 'Doorbell'], saw: ['person', 'vehicle'], concern: 'notable', described: true, q: 'red jacket & hat', range: '24h',
  };
  const query = filtersToQuery(filters);
  assert.ok(!query.includes(' '), 'a space is encoded');
  assert.deepEqual(filtersFromQuery(query), filters);
  assert.deepEqual(filtersFromQuery(`?${query}`), filters, 'a leading ? is fine');
  assert.equal(filtersToQuery({ ...emptyFilters(), range: '7d' }), '', 'the default range is left out');
  assert.equal(filtersToQuery({ ...emptyFilters(), range: 'today' }), 'range=today');
});

test('an address with nonsense falls back to the defaults, piece by piece', () => {
  const f = filtersFromQuery('cameras=not-an-id,' + id(3) + '&saw=person,dragon&concern=loud&range=forever&described=maybe&type=');
  assert.deepEqual(f.cameras, [id(3)]);
  assert.deepEqual(f.saw, ['person']);
  assert.equal(f.concern, 'any');
  assert.equal(f.range, '7d');
  assert.equal(f.described, false);
  assert.deepEqual(f.types, []);
  assert.deepEqual(filtersFromQuery(undefined), emptyFilters());
  assert.deepEqual(filtersFromQuery('%E0%A4%A'), emptyFilters(), 'a broken escape never throws');
});

test('ranges start where they say', () => {
  assert.deepEqual(Object.keys(EVENT_RANGES), ['today', '24h', '7d', '30d']);
  assert.equal(queryRange({ ...emptyFilters(), range: 'today' }, NOW).fromMs, local(19, 0));
  assert.equal(queryRange({ ...emptyFilters(), range: '24h' }, NOW).fromMs, NOW - 86_400_000);
  assert.equal(queryRange({ ...emptyFilters(), range: '7d' }, NOW).fromMs, NOW - 7 * 86_400_000);
  assert.equal(queryRange({ ...emptyFilters(), range: '30d' }, NOW).fromMs, NOW - 30 * 86_400_000);
  assert.equal(queryRange(emptyFilters(), NOW).toMs, Infinity, 'it follows live');
});

test('filterEvents narrows by camera, type, what the AI saw, concern, description and words', () => {
  const events = [
    event(1, NOW - 1000, { description: said('A person tries the door handle', 'person', 'alarm') }),
    event(2, NOW - 2000, { cameraId: id(2), cameraName: 'Garage', label: 'Vehicle', description: said('A van parks across the driveway', 'vehicle', 'unusual') }),
    event(3, NOW - 3000, { label: 'Motion', description: said('Nothing notable', 'nothing', 'nothing') }),
    event(4, NOW - 4000, { label: 'Motion' }),
    event(5, NOW - 5000, { label: 'Package', description: said('A courier leaves a parcel', 'delivery', 'routine') }),
    event(6, NOW - 9 * 86_400_000, { label: 'Motion' }),
  ];
  const ns = (f) => filterEvents(events, { ...emptyFilters(), ...f }, { now: NOW }).map((e) => e.n);
  assert.deepEqual(ns({}), [1, 2, 3, 4, 5], 'the default range is 7 days: the ninth-day-old one is out');
  assert.deepEqual(ns({ range: '30d' }), [1, 2, 3, 4, 5, 6]);
  assert.deepEqual(ns({ cameras: [id(2)] }), [2]);
  assert.deepEqual(ns({ types: ['motion'] }), [3, 4], 'types compare without case');
  assert.deepEqual(ns({ types: ['Person', 'Package'] }), [1, 5]);
  assert.deepEqual(ns({ saw: ['person', 'delivery'] }), [1, 5], 'an event with no description has not been seen as anything');
  assert.deepEqual(ns({ concern: 'notable' }), [1, 2]);
  assert.deepEqual(ns({ concern: 'alarm' }), [1]);
  assert.deepEqual(ns({ described: true }), [1, 2, 3, 5]);
  assert.deepEqual(ns({ q: 'PARCEL' }), [5], 'words are found in the sentences, without case');
  assert.deepEqual(ns({ q: '  ' }), [1, 2, 3, 4, 5], 'blank words are no filter');
  assert.deepEqual(ns({ types: ['Person'], concern: 'notable', described: true }), [1], 'filters add up');
  assert.equal(concernRank('alarm') > concernRank('unusual') && concernRank('unusual') > concernRank('routine') && concernRank('routine') > concernRank('nothing'), true);
});

test('the type choices are the usual ones and every other kind seen, once', () => {
  const choices = typeChoices([event(1, NOW, { label: 'Line crossing' }), event(2, NOW, { label: 'person' }), event(3, NOW, { label: 'Line crossing' })]);
  assert.deepEqual(choices.slice(0, 7), ['Motion', 'Person', 'Vehicle', 'Animal', 'Package', 'Face', 'Doorbell']);
  assert.deepEqual(choices.slice(7), ['Line crossing']);
});

test('events are grouped by day, newest first: Today, Yesterday, then the date', () => {
  const events = [
    event(1, local(19, 15)), event(2, local(19, 0, 5)),
    event(3, local(18, 23, 50)), event(4, local(18, 8)),
    event(5, local(14, 12)), event(6, local(14, 11)),
    event(7, new Date(2025, 11, 31, 9).getTime()),
  ];
  const groups = groupByDay(events, NOW);
  assert.deepEqual(groups.map((g) => [g.label, g.events.map((e) => e.n)]), [
    ['Today', [1, 2]], ['Yesterday', [3, 4]], [groups[2].label, [5, 6]], [groups[3].label, [7]],
  ]);
  assert.match(groups[2].label, /14/, 'a date');
  assert.match(groups[2].label, /Oct/);
  assert.match(groups[3].label, /2025/, 'another year says so');
  assert.equal(new Set(groups.map((g) => g.key)).size, 4);
  assert.deepEqual(groupByDay([], NOW), []);
});

test('a click goes to the Monitor at that moment, a few seconds before, with that camera playing', () => {
  const e = event(1, 1_760_099_000_000, { cameraId: id(3) });
  assert.equal(eventPath(e), `/nvr/1760098997000?camera=${id(3)}&play=1`);
  assert.equal(eventPath(event(2, 5000)), null, 'a time the Monitor could not take is no link');
  assert.equal(eventPath({ ...e, recorded: false }), null, 'nothing was recorded then');
});

test('a describing mark only for a camera that is described, an event under two minutes old with no words yet', () => {
  const camera = { id: id(1), aiDescriptions: true };
  assert.equal(isDescribing(event(1, NOW - 30_000), camera, NOW), true);
  assert.equal(isDescribing(event(1, NOW - 121_000), camera, NOW), false, 'too old: none is coming');
  assert.equal(isDescribing(event(1, NOW - 30_000, { description: said('x', 'other', 'routine') }), camera, NOW), false);
  assert.equal(isDescribing(event(1, NOW - 30_000), { id: id(1), aiDescriptions: false }, NOW), false);
  assert.equal(isDescribing(event(1, NOW - 30_000), undefined, NOW), false);
  assert.equal(isDescribing(event(1, NOW - 30_000, { recorded: false }), camera, NOW), true, 'it is described from the picture, not the recording');
});

test('new events are held back while the person reads further down, and join at once at the top', () => {
  const first = [event(1, NOW - 10_000), event(2, NOW - 20_000)];
  const known = new Set(first.map(eventKey));
  const next = [event(3, NOW - 1000), ...first];
  assert.deepEqual(holdNewEvents(next, known, { hold: true }), { shown: first, held: [next[0]] });
  assert.deepEqual(holdNewEvents(next, known, { hold: false }), { shown: next, held: [] });
  const older = [...first, event(4, NOW - 90_000)];
  assert.deepEqual(holdNewEvents(older, known, { hold: true }).shown, older, 'an older page is never held: it is what was asked for');
  assert.deepEqual(holdNewEvents(next, new Set(), { hold: true }).shown, next, 'the first draw shows everything');
});

test('gathered events keep what the AI saw (kind) for the filters', () => {
  const cameras = [{ id: id(1), name: 'Front Door' }];
  const events = gatherEvents({ cameras, archived: [{ id: 'a', cameraID: id(1), kind: 'Person', start: NOW, end: null, recorded: true, description: { summary: 'x', kind: 'animal', concern: 'routine' } }] });
  assert.equal(events[0].description.kind, 'animal');
});

// MARK: Thumbnails

/** An IntersectionObserver the test drives by hand. */
function fakeObserver() {
  const state = { targets: new Set(), callback: null };
  state.create = (callback) => {
    state.callback = callback;
    return { observe: (el) => state.targets.add(el), unobserve: (el) => state.targets.delete(el), disconnect: () => state.targets.clear() };
  };
  state.show = (...els) => state.callback(els.map((target) => ({ target, isIntersecting: true })));
  state.hide = (...els) => state.callback(els.map((target) => ({ target, isIntersecting: false })));
  return state;
}

function fakeLoader() {
  const calls = [];
  return {
    calls,
    load: (cameraId, atMs) => new Promise((resolve, reject) => { calls.push({ cameraId, atMs, resolve, reject }); }),
  };
}

const walk = (node, out = []) => { for (const child of node.childNodes ?? []) { if (child.tagName) out.push(child); walk(child, out); } return out; };

test('thumbnails load only when seen, two at a time, and a picture that scrolled away before its turn is not fetched', async () => {
  const browser = installFakeBrowser();
  try {
    const observer = fakeObserver();
    const loader = fakeLoader();
    const thumbs = createThumbnails({ load: loader.load, createObserver: observer.create, concurrency: 2 });
    const tiles = [1, 2, 3, 4].map((n) => thumbs.tile(id(1), NOW - n * 60_000));
    assert.equal(loader.calls.length, 0, 'nothing is asked for until a tile is on screen');
    assert.deepEqual(tiles.map((t) => t.dataset.state), ['idle', 'idle', 'idle', 'idle']);
    observer.show(...tiles);
    await settle();
    assert.equal(loader.calls.length, 2, 'two in flight, the rest wait');
    observer.hide(tiles[2]);                    // scrolled past before its turn
    loader.calls[0].resolve('data:image/jpeg;base64,AAAA');
    await settle();
    assert.equal(tiles[0].dataset.state, 'loaded');
    const img = walk(tiles[0]).find((n) => n.tagName.toLowerCase() === 'img');
    assert.equal(img.getAttribute('src'), 'data:image/jpeg;base64,AAAA');
    assert.equal(loader.calls.length, 3);
    assert.equal(loader.calls[2].atMs, NOW - 4 * 60_000, 'the hidden one was skipped');
    loader.calls[1].reject(Object.assign(new Error('gap'), { code: 'gap' }));
    loader.calls[2].resolve(null);
    await settle();
    assert.deepEqual([tiles[1].dataset.state, tiles[3].dataset.state], ['none', 'none'], 'no footage or no picture: a plain placeholder');
    assert.equal(tiles[2].dataset.state, 'idle');
    observer.show(tiles[2]);
    await settle();
    assert.equal(loader.calls.length, 4, 'a tile that comes back is loaded then');
    thumbs.destroy();
  } finally { browser.restore(); }
});

test('a picture already loaded is not asked for twice, and no video element is ever made', async () => {
  const browser = installFakeBrowser();
  try {
    const observer = fakeObserver();
    const loader = fakeLoader();
    const thumbs = createThumbnails({ load: loader.load, createObserver: observer.create });
    const a = thumbs.tile(id(1), NOW);
    observer.show(a);
    await settle();
    loader.calls[0].resolve('data:image/jpeg;base64,BBBB');
    await settle();
    const b = thumbs.tile(id(1), NOW);
    observer.show(b);
    await settle();
    assert.equal(loader.calls.length, 1);
    assert.equal(b.dataset.state, 'loaded');
    assert.deepEqual([...walk(a), ...walk(b)].filter((n) => /^(video|audio|canvas)$/i.test(n.tagName)), []);
    thumbs.destroy();
  } finally { browser.restore(); }
});

test('a page without IntersectionObserver still gets its pictures (a few at a time)', async () => {
  const browser = installFakeBrowser();
  try {
    const loader = fakeLoader();
    const thumbs = createThumbnails({ load: loader.load, createObserver: null, concurrency: 1 });
    const t = thumbs.tile(id(1), NOW);
    await settle();
    assert.equal(loader.calls.length, 1);
    loader.calls[0].resolve('data:image/jpeg;base64,CC');
    await settle();
    assert.equal(t.dataset.state, 'loaded');
    thumbs.destroy();
  } finally { browser.restore(); }
});

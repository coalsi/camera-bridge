// The Events page: its model (screens/events-model.js), the thumbnails (nvr/thumbs.js), the row (screens/events-row.js) and the page (screens/events.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  EVENT_RANGES, concernRank, emptyFilters, eventKey, eventPath, filterEvents, filtersFromQuery, filtersToQuery, groupByDay, holdNewEvents,
  isDescribing, queryRange, typeChoices,
} from '../web/js/screens/events-model.js';
import { gatherEvents } from '../web/js/screens/wall-events-model.js';
import { createThumbnails, decodeFirstFrame, loadKeyframePicture } from '../web/js/nvr/thumbs.js';
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

test('a picture that failed for a passing reason is not kept as "no picture": it is asked for again while on screen, and is a placeholder after three tries', async () => {
  const browser = installFakeBrowser();
  const timers = [];
  try {
    const observer = fakeObserver();
    const loader = fakeLoader();
    const thumbs = createThumbnails({ load: loader.load, createObserver: observer.create, setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length; }, clearTimer() {} });
    const tile = thumbs.tile(id(1), NOW);
    observer.show(tile);
    await settle();
    const busy = Object.assign(new Error('The bridge is busy.'), { status: 429 });
    loader.calls[0].reject(busy);
    await settle();
    assert.equal(tile.dataset.state, 'idle', 'not "none": a busy box is no answer');
    assert.equal(timers.at(-1).ms, 30_000);
    timers.at(-1).fn();
    await settle();
    assert.equal(loader.calls.length, 2, 'asked for again after 30 s while it is on screen');
    loader.calls[1].reject(Object.assign(new Error('The recordings drive isn’t connected.'), { status: 503 }));
    await settle();
    observer.hide(tile);
    timers.at(-1).fn();
    await settle();
    assert.equal(loader.calls.length, 2, 'not while it is off screen');
    observer.show(tile);
    await settle();
    assert.equal(loader.calls.length, 3, 'but as soon as it comes back');
    loader.calls[2].reject(new Error('network'));
    await settle();
    assert.equal(tile.dataset.state, 'none', 'three failures: a placeholder');
    const again = thumbs.tile(id(1), NOW);
    assert.equal(again.dataset.state, 'none', 'and kept');
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

// What the page does with a MediaSource, a <video> and a canvas, noted in `events`, on globalThis until `restore()`. `held` says what the source buffer holds
// once a media segment of that many bytes is appended: [start, end] in seconds, or null for nothing (the init segment is 3 bytes and holds no picture).
function fakeMedia(held) {
  const events = [];
  const saved = { source: globalThis.MediaSource, document: globalThis.document, create: URL.createObjectURL, revoke: URL.revokeObjectURL };
  const later = (fn) => setTimeout(fn, 0);
  let range = null;
  class FakeBuffer extends EventTarget {
    updating = false;
    appendBuffer(bytes) {
      events.push(`append ${bytes.length}`);
      if (bytes.length in held) range = held[bytes.length];
      later(() => this.dispatchEvent(new Event('updateend')));
    }
    get buffered() { return { length: range ? 1 : 0, start: () => range[0], end: () => range[1] }; }
  }
  const buffer = new FakeBuffer();
  let source;
  class FakeSource extends EventTarget {
    static isTypeSupported() { return true; }
    constructor() { super(); source = this; this.readyState = 'closed'; range = null; }
    addSourceBuffer() { return buffer; }
    endOfStream() { events.push('endOfStream'); this.readyState = 'ended'; }
  }
  class FakeVideo extends EventTarget {
    videoWidth = 320;
    videoHeight = 180;
    removeAttribute() {}
    load() {}
    set src(url) { later(() => { source.readyState = 'open'; source.dispatchEvent(new Event('sourceopen')); }); }
    set currentTime(seconds) { events.push(`seek ${seconds.toFixed(4)}`); later(() => this.dispatchEvent(new Event('seeked'))); }
  }
  const canvas = { getContext: () => ({ drawImage() { events.push('draw'); } }), toDataURL: () => 'data:image/jpeg;base64,AAAA' };
  globalThis.MediaSource = FakeSource;
  globalThis.document = { createElement: (tag) => (tag === 'video' ? new FakeVideo() : canvas) };
  URL.createObjectURL = () => 'blob:picture';
  URL.revokeObjectURL = () => {};
  return {
    events,
    restore() {
      globalThis.MediaSource = saved.source;
      if (saved.document === undefined) delete globalThis.document; else globalThis.document = saved.document;
      URL.createObjectURL = saved.create;
      URL.revokeObjectURL = saved.revoke;
    },
  };
}

// A copy of nvr/thumbs.js of its own, so what it learns about a browser (that the picture alone does not decode) starts over, as it does with a page load.
let pages = 0;
const freshThumbs = () => import(`../web/js/nvr/thumbs.js?page=${++pages}`);

const PART = JSON.stringify({ id: 'abcdef012345.7', mime: 'video/mp4; codecs="avc1.64001e"', initId: 'abcdef012345.7' });
const keyPath = (cameraId, atMs, alone) => `nvr/cameras/${cameraId}/keyframe?at=${atMs}${alone ? '&picture=1' : ''}`;
const initPath = (cameraId) => `nvr/cameras/${cameraId}/fragments/abcdef012345.7/init`;

/** The bridge for the thumbnail requests: `asked` is every path in order; the init segment is 3 bytes, the picture alone 5, the whole key fragment 50. */
function fakeBridge() {
  const asked = [];
  const bytes = async (path) => {
    asked.push(path);
    const size = path.includes('/fragments/') ? 3 : path.includes('picture=1') ? 5 : 50;
    return { headers: new Headers(path.includes('/keyframe?') ? { 'X-CB-Part': PART } : {}), data: new Uint8Array(size) };
  };
  return { asked, bytes };
}

/** A decoder for loadKeyframePicture: `alone(media)` and `whole(media)` give the picture (or throw, or give null) for what is asked; `calls` says which and how big. */
function fakeDecoder({ alone, whole = () => 'data:image/jpeg;base64,WHOLE' }) {
  const calls = [];
  const decode = async ({ media, alone: isAlone }) => {
    calls.push(`${isAlone ? 'alone' : 'whole'} ${media.length}`);
    return isAlone ? alone(media) : whole(media);
  };
  return { calls, decode };
}

const LONE = 'data:image/jpeg;base64,LONE';
const WHOLE = 'data:image/jpeg;base64,WHOLE';
const cannotDecode = () => { throw new Error('no seeked'); };           // as decodeFirstFrame fails when the decoder says nothing in DECODE_MS

test('a thumbnail asks the bridge for the key picture alone, then for the init segment its answer names', async () => {
  const asked = [];
  const part = JSON.stringify({ id: 'abcdef012345.7', mime: 'video/mp4; codecs="avc1.64001e"', initId: 'abcdef012345.7' });
  const bytes = async (path) => {
    asked.push(path);
    return { headers: new Headers(path.includes('/keyframe?') ? { 'X-CB-Part': part } : {}), data: new Uint8Array(8).buffer };
  };
  assert.equal(await loadKeyframePicture(id(1), NOW + 0.9, { bytes }), null, 'no MediaSource in this page: no picture, and no failure');
  assert.deepEqual(asked, [
    `nvr/cameras/${id(1)}/keyframe?at=${NOW}&picture=1`,
    `nvr/cameras/${id(1)}/fragments/abcdef012345.7/init`,
  ], 'the whole key fragment is not asked for: the first picture is all a thumbnail draws');
});

test('a fragment of one picture is decoded once the stream is ended, and the seek lands inside that picture', async () => {
  // One picture of a camera at 200 frames a second: the buffer holds 5 ms, from 80 ms (the picture's composition offset).
  const media = fakeMedia({ 5: [0.08, 0.085] });
  try {
    const picture = await decodeFirstFrame({ mime: 'video/mp4; codecs="avc1.64001e"', init: new Uint8Array(3), media: new Uint8Array(5), alone: true });
    assert.equal(picture, 'data:image/jpeg;base64,AAAA');
    assert.deepEqual(media.events, ['append 3', 'append 5', 'endOfStream', 'seek 0.0825', 'draw'],
      'ended before the seek (a decoder with B-frames holds the first picture back otherwise), and half way into a picture shorter than 20 ms');
  } finally { media.restore(); }
});

test('a whole key fragment is decoded as it was before the picture alone: the stream is not ended, and the seek is 10 ms in', async () => {
  const media = fakeMedia({ 50: [0.08, 2.58] });
  try {
    const picture = await decodeFirstFrame({ mime: 'video/mp4; codecs="avc1.64001e"', init: new Uint8Array(3), media: new Uint8Array(50) });
    assert.equal(picture, 'data:image/jpeg;base64,AAAA');
    assert.deepEqual(media.events, ['append 3', 'append 50', 'seek 0.0900', 'draw']);
  } finally { media.restore(); }
});

test('a moment with no footage is no picture, and a passing failure is not', async () => {
  const gap = async () => { throw Object.assign(new Error('Nothing was recorded at that time.'), { status: 404, code: 'gap' }); };
  assert.equal(await loadKeyframePicture(id(1), NOW, { bytes: gap }), null);
  const busy = async () => { throw Object.assign(new Error('The bridge is busy.'), { status: 429, code: 'busy' }); };
  await assert.rejects(loadKeyframePicture(id(1), NOW, { bytes: busy }), { status: 429 });
  const noPart = async () => ({ headers: new Headers(), data: new ArrayBuffer(0) });
  assert.equal(await loadKeyframePicture(id(1), NOW, { bytes: noPart }), null, 'an answer without its description is no picture');
});

test('when the picture alone decodes it is the thumbnail, and the whole key fragment is never asked for', async () => {
  const { loadKeyframePicture: load } = await freshThumbs();
  const bridge = fakeBridge();
  const decoder = fakeDecoder({ alone: () => LONE });
  assert.equal(await load(id(1), NOW, { bytes: bridge.bytes, decode: decoder.decode }), LONE);
  assert.equal(await load(id(1), NOW - 60_000, { bytes: bridge.bytes, decode: decoder.decode }), LONE);
  assert.deepEqual(bridge.asked, [keyPath(id(1), NOW, true), initPath(id(1)), keyPath(id(1), NOW - 60_000, true), initPath(id(1))]);
  assert.deepEqual(decoder.calls, ['alone 5', 'alone 5']);
});

test('a browser that cannot decode the picture alone is asked for the whole key fragment, once, and that picture is the thumbnail', async () => {
  const { loadKeyframePicture: load } = await freshThumbs();
  const bridge = fakeBridge();
  const decoder = fakeDecoder({ alone: cannotDecode });
  assert.equal(await load(id(1), NOW, { bytes: bridge.bytes, decode: decoder.decode }), WHOLE);
  assert.deepEqual(bridge.asked, [keyPath(id(1), NOW, true), initPath(id(1)), keyPath(id(1), NOW, false), initPath(id(1))],
    'the picture alone first, then the key fragment as the page always asked for it');
  assert.deepEqual(decoder.calls, ['alone 5', 'whole 50']);
});

test('a browser that takes the picture alone and draws nothing from it is asked for the whole key fragment too', async () => {
  const media = fakeMedia({});                      // a MediaSource that supports the codec
  try {
    const { loadKeyframePicture: load } = await freshThumbs();
    const bridge = fakeBridge();
    const decoder = fakeDecoder({ alone: () => null });
    assert.equal(await load(id(1), NOW, { bytes: bridge.bytes, decode: decoder.decode }), WHOLE);
    assert.deepEqual(bridge.asked, [keyPath(id(1), NOW, true), initPath(id(1)), keyPath(id(1), NOW, false), initPath(id(1))]);
    assert.deepEqual(decoder.calls, ['alone 5', 'whole 50']);
  } finally { media.restore(); }
});

test('a browser that cannot play the codec at all gets no picture, and the whole key fragment is not downloaded for nothing', async () => {
  const { loadKeyframePicture: load } = await freshThumbs();       // no MediaSource in this page
  const bridge = fakeBridge();
  const decoder = fakeDecoder({ alone: () => null });
  assert.equal(await load(id(1), NOW, { bytes: bridge.bytes, decode: decoder.decode }), null);
  assert.equal(await load(id(1), NOW - 1000, { bytes: bridge.bytes, decode: decoder.decode }), null);
  assert.deepEqual(bridge.asked, [keyPath(id(1), NOW, true), initPath(id(1)), keyPath(id(1), NOW - 1000, true), initPath(id(1))],
    'and it is still the picture alone that is asked for: nothing was learned about the lone picture');
  assert.deepEqual(decoder.calls, ['alone 5', 'alone 5']);
});

test('after one picture the browser could not decode alone, every picture goes straight to the whole key fragment, as before', async () => {
  const { loadKeyframePicture: load } = await freshThumbs();
  const bridge = fakeBridge();
  const decoder = fakeDecoder({ alone: cannotDecode });
  assert.equal(await load(id(1), NOW, { bytes: bridge.bytes, decode: decoder.decode }), WHOLE);
  const before = bridge.asked.length;
  assert.equal(await load(id(2), NOW - 60_000, { bytes: bridge.bytes, decode: decoder.decode }), WHOLE);
  assert.equal(await load(id(1), NOW - 120_000, { bytes: bridge.bytes, decode: decoder.decode }), WHOLE);
  assert.deepEqual(bridge.asked.slice(before), [
    keyPath(id(2), NOW - 60_000, false), initPath(id(2)), keyPath(id(1), NOW - 120_000, false), initPath(id(1)),
  ], 'no more tries of the picture alone, and no second request for any picture');
  assert.deepEqual(decoder.calls, ['alone 5', 'whole 50', 'whole 50', 'whole 50']);
  // The page that learned it is that page's: another one (a reload) tries the picture alone again.
  const reloaded = await freshThumbs();
  const again = fakeBridge();
  await reloaded.loadKeyframePicture(id(1), NOW, { bytes: again.bytes, decode: fakeDecoder({ alone: () => LONE }).decode });
  assert.equal(again.asked[0], keyPath(id(1), NOW, true));
});

test('a busy bridge or a lost connection says nothing about the browser: no second request, and the next picture is asked for alone again', async () => {
  const { loadKeyframePicture: load } = await freshThumbs();
  const asked = [];
  const failing = (error) => async (path) => { asked.push(path); throw error; };
  const decoder = fakeDecoder({ alone: cannotDecode });
  await assert.rejects(load(id(1), NOW, { bytes: failing(Object.assign(new Error('The bridge is busy.'), { status: 429, code: 'busy' })), decode: decoder.decode }), { status: 429 });
  await assert.rejects(load(id(1), NOW - 1000, { bytes: failing(new Error('network')), decode: decoder.decode }), { message: 'network' });
  assert.deepEqual(asked, [keyPath(id(1), NOW, true), keyPath(id(1), NOW - 1000, true)]);
  const gap = failing(Object.assign(new Error('Nothing was recorded at that time.'), { status: 404, code: 'gap' }));
  assert.equal(await load(id(1), NOW - 2000, { bytes: gap, decode: decoder.decode }), null, 'no footage is no picture, in this browser as in any');
  assert.deepEqual(asked.slice(2), [keyPath(id(1), NOW - 2000, true)]);
  assert.deepEqual(decoder.calls, [], 'nothing was decoded, so nothing was learned');
});

test('the real decoder: a picture alone that leaves the buffer empty is taken again as the whole key fragment, decoded as before', async () => {
  const media = fakeMedia({ 5: null, 50: [0.08, 2.58] });          // this browser buffers nothing of a fragment of one sample
  try {
    const { loadKeyframePicture: load } = await freshThumbs();
    const bridge = fakeBridge();
    assert.equal(await load(id(1), NOW, { bytes: bridge.bytes }), 'data:image/jpeg;base64,AAAA');
    assert.deepEqual(bridge.asked, [keyPath(id(1), NOW, true), initPath(id(1)), keyPath(id(1), NOW, false), initPath(id(1))]);
    assert.deepEqual(media.events, ['append 3', 'append 5', 'append 3', 'append 50', 'seek 0.0900', 'draw'],
      'the key fragment is not ended and is entered 10 ms in, as it was before the picture alone was asked for');
  } finally { media.restore(); }
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

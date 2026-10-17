import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGridController } from '../web/js/screens/nvr-controller.js';
import { fakeTime, settle } from './nvr-grid-helpers.mjs';

const T0 = 1760099000000;
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

function makeCamera(n, overrides = {}) {
  return {
    id: id(n), name: `Camera ${n}`, isEnabled: true, nvrEnabled: true,
    status: { connection: 'online', connectionReason: null, nvr: { state: 'recording', detail: null, pause: null, notes: [] } },
    ...overrides,
  };
}

function fakeCell(cameraId) {
  return {
    cameraId, kind: 'idle', next: null, message: null, listeners: new Set(),
    get coverage() { return { kind: this.kind, next: this.next, message: this.message }; },
    onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); },
    set(kind, extra = {}) { this.kind = kind; Object.assign(this, extra); for (const fn of [...this.listeners]) fn(); },
  };
}

// A session that records what it is asked and answers like T00's Session: scrub pauses at the time, goLive goes live, seek moves the playhead.
function fakeSession() {
  return {
    calls: [], mode: 'live', position: T0 - 6000, cells: new Map(), onRequest: () => {},
    setCameras(ids) { this.calls.push(['setCameras', [...ids]]); this.cells = new Map(ids.map((cid) => [cid, fakeCell(cid)])); },
    cell(cid) { return this.cells.get(cid); },
    focus(cid) { this.calls.push(['focus', cid]); },
    scrub(ms) { this.calls.push(['scrub', ms]); this.mode = 'paused'; this.position = ms; this.onRequest(); },
    goLive() { this.calls.push(['goLive']); this.mode = 'live'; this.onRequest(); },
    togglePlay() { this.calls.push(['togglePlay']); this.mode = this.mode === 'playing' ? 'paused' : 'playing'; this.onRequest(); },
    seek(deltaMs) {
      this.calls.push(['seek', deltaMs]);
      if (deltaMs !== 0) { this.position += deltaMs; if (this.mode === 'live') this.mode = 'paused'; }
      this.onRequest();
    },
    suspend() { this.calls.push(['suspend']); },
    resume() { this.calls.push(['resume']); },
    names() { return this.calls.map((call) => call[0]); },
  };
}

function fakeCatalog() {
  const listeners = new Set();
  return {
    baseMs: Number.NaN, extents: new Map(), started: 0,
    extent(cid) { return this.extents.get(cid) ?? null; },
    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    answer(extents = {}) {
      this.baseMs = T0 - 400 * 86_400_000;
      for (const [cid, extent] of Object.entries(extents)) this.extents.set(cid, extent);
      for (const fn of [...listeners]) fn({ kind: 'extents' });
    },
    listenerCount: () => listeners.size,
  };
}

function setup({ count = 9, perPage = 4, initialMs = null, initialPage = 0, initialFocus = null, playable = true, catalogTimeoutMs = 10_000, paginate } = {}) {
  const time = fakeTime(0);
  const cameras = Array.from({ length: count }, (_, i) => makeCamera(i + 1));
  const session = fakeSession();
  const catalog = fakeCatalog();
  const log = { hashes: [], navigations: [], remembered: [], waveform: [], snapshotIds: [], pokes: 0 };
  const cameraListeners = new Set();
  const controller = createGridController({
    session, catalog, listCameras: () => cameras,
    subscribeCameras: (fn) => { cameraListeners.add(fn); return () => cameraListeners.delete(fn); },
    perPage, initialMs, initialPage, initialFocus, playable, catalogTimeoutMs, paginate,
    navigate: (path) => log.navigations.push(path), replaceHash: (path) => log.hashes.push(path), remember: (state) => log.remembered.push(state),
    formatTime: (ms) => `t${ms - T0}`, now: time.now,
    setWaveformCameras: (ids) => log.waveform.push([...ids]), setSnapshotIds: (ids) => log.snapshotIds.push([...ids]), pokeSnapshots: () => { log.pokes += 1; },
    setTimer: time.setTimer, clearTimer: time.clearTimer,
    setTick: (fn, ms) => {
      const handle = { stopped: false, timer: null };
      const loop = () => { if (handle.stopped) return; fn(); handle.timer = time.setTimer(loop, ms); };
      handle.timer = time.setTimer(loop, ms);
      return handle;
    },
    clearTick: (handle) => { handle.stopped = true; time.clearTimer(handle.timer); },
  });
  session.onRequest = () => controller.noteRequest();
  const emits = { count: 0 };
  controller.subscribe(() => { emits.count += 1; });
  return { time, cameras, session, catalog, log, controller, cameraListeners, emits };
}

const ids = (...numbers) => numbers.map(id);

test('opening the page shows the first page of tiles at once and asks the session for nothing', async () => {
  const t = setup();
  const started = t.controller.start();
  assert.deepEqual(t.session.calls, [['setCameras', ids(1, 2, 3, 4)], ['focus', id(1)]]);
  assert.deepEqual(t.log.snapshotIds, [ids(1, 2, 3, 4)]);
  assert.equal(t.controller.view().phase, 'connecting');
  t.catalog.answer({ [id(1)]: { oldest: T0 - 1000, newest: T0 } });
  await started;
  const view = t.controller.view();
  assert.equal(view.phase, 'ready');
  assert.deepEqual(t.session.names(), ['setCameras', 'focus'], 'no scrub, no play, no seek, no live: nothing may decode yet');
  assert.equal(view.transport.mode, 'snapshots');
  assert.deepEqual(view.tiles.map((tile) => tile.look.state), ['snapshot', 'snapshot', 'snapshot', 'snapshot']);
  assert.deepEqual([view.page, view.pages, view.first, view.last, view.total], [0, 3, 1, 4, 9]);
  assert.equal(view.tiles[0].focused, true);
  assert.equal(view.tiles[0].href, `#/camera/${id(1)}/watch`, 'live pictures open the watch screen live');
  assert.equal(view.noRecordings, false);
  assert.deepEqual(t.log.waveform, [ids(1)]);
  t.controller.destroy();
});

test('a time in the address is applied once the catalog has answered, as a paused jump', async () => {
  const t = setup({ initialMs: T0 - 600_000 });
  const started = t.controller.start();
  await settle();
  assert.equal(t.session.names().includes('scrub'), false, 'the catalog has not answered: no time base yet');
  t.catalog.answer({ [id(1)]: { oldest: T0 - 86_400_000, newest: T0 } });
  await started;
  assert.deepEqual(t.session.calls.filter((call) => call[0] === 'scrub'), [['scrub', T0 - 600_000]]);
  const view = t.controller.view();
  assert.equal(view.transport.mode, 'paused');
  assert.equal(view.transport.positionMs, T0 - 600_000);
  assert.deepEqual(view.tiles.map((tile) => tile.look.state), ['loading', 'nothingRecorded', 'nothingRecorded', 'nothingRecorded']);
  assert.equal(view.tiles[0].href, `#/camera/${id(1)}/watch/${T0 - 600_000}`);
  t.controller.destroy();
});

test('a catalog that never answers ends in "unreachable" after the timeout, and Try again waits again', async () => {
  const t = setup({ catalogTimeoutMs: 3000 });
  const started = t.controller.start();
  t.time.advance(3000);
  await started;
  assert.equal(t.controller.view().phase, 'unreachable');
  assert.equal(t.controller.view().transport.canPlay, false);
  t.controller.togglePlay();
  assert.equal(t.session.names().includes('goLive'), false, 'no transport action before the catalog is known');
  const again = t.controller.retryCatalog();
  assert.equal(t.controller.view().phase, 'connecting');
  t.catalog.answer();
  await again;
  assert.equal(t.controller.view().phase, 'ready');
  assert.equal(t.controller.view().transport.canPlay, true);
  assert.equal(t.time.pendingTimers() > 0, true, 'only the tick is left');
  t.controller.destroy();
});

test('a catalog whose time base is still 0 or NaN has not answered yet', async () => {
  const t = setup({ catalogTimeoutMs: 2000 });
  t.catalog.baseMs = 0;
  const started = t.controller.start();
  t.time.advance(2000);
  await started;
  assert.equal(t.controller.view().phase, 'unreachable');
  t.controller.destroy();
});

test('the first request of any cell ends "nothing started": tiles load, snapshots are poked once', async () => {
  const t = setup();
  const started = t.controller.start();
  t.catalog.answer({ [id(1)]: { oldest: T0 - 86_400_000, newest: T0 }, [id(2)]: { oldest: T0 - 86_400_000, newest: T0 } });
  await started;
  t.controller.noteRequest();
  t.controller.noteRequest();
  assert.equal(t.log.pokes, 1);
  const view = t.controller.view();
  assert.equal(view.transport.mode, 'live');
  assert.deepEqual(view.tiles.map((tile) => tile.look.state), ['loading', 'loading', 'nothingRecorded', 'nothingRecorded']);
  t.session.cell(id(1)).set('recorded');
  t.session.cell(id(2)).set('gap', { next: T0 });
  await settle();
  // Live: a recorded tile shows its refreshing snapshot (caption: live), not the player.
  assert.deepEqual(t.controller.view().tiles.slice(0, 2).map((tile) => tile.look.state), ['snapshot', 'gap']);
  t.controller.destroy();
});

test('a cell that changes makes the page redraw once, however many changes arrive together', async () => {
  const t = setup();
  const started = t.controller.start();
  t.catalog.answer({ [id(1)]: { oldest: 1, newest: 2 } });
  await started;
  await settle();
  t.controller.noteRequest();
  await settle();
  const before = t.emits.count;
  t.session.cell(id(1)).set('loading');
  t.session.cell(id(2)).set('loading');
  t.session.cell(id(3)).set('loading');
  assert.equal(t.emits.count, before, 'redraws are deferred');
  await settle();
  assert.equal(t.emits.count, before + 1);
  t.controller.destroy();
});

test('paging moves the session to the next cameras, keeps the hovered tile when it is still there, and restarts the position when something is playing', async () => {
  const t = setup({ count: 9, perPage: 4 });
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  t.session.calls.length = 0;
  t.controller.nextPage();
  assert.deepEqual(t.session.calls, [['setCameras', ids(5, 6, 7, 8)], ['focus', id(5)]], 'nothing started: no seek');
  assert.deepEqual(t.log.snapshotIds.at(-1), ids(5, 6, 7, 8));
  assert.deepEqual(t.log.remembered.at(-1), { page: 1, focusId: id(5) });
  t.controller.nextPage();
  assert.deepEqual(t.controller.view().tiles.map((tile) => tile.id), ids(9));
  assert.deepEqual([t.controller.view().first, t.controller.view().last], [9, 9]);
  t.controller.nextPage();
  assert.equal(t.controller.view().page, 2, 'the last page stays');
  t.controller.noteRequest();
  t.session.calls.length = 0;
  t.controller.previousPage();
  assert.deepEqual(t.session.calls, [['setCameras', ids(5, 6, 7, 8)], ['focus', id(5)], ['seek', 0]], 'started: the new cells take the playhead where it is');
  t.controller.destroy();
});

test('the first page can be restored with the tile that was open', async () => {
  const t = setup({ count: 9, perPage: 4, initialPage: 1, initialFocus: id(7) });
  const started = t.controller.start();
  assert.deepEqual(t.session.calls, [['setCameras', ids(5, 6, 7, 8)], ['focus', id(7)]]);
  t.catalog.answer();
  await started;
  assert.equal(t.controller.view().tiles.find((tile) => tile.focused).id, id(7));
  const outOfRange = setup({ count: 3, perPage: 4, initialPage: 5 });
  const done = outOfRange.controller.start();
  assert.equal(outOfRange.controller.view().page, 0);
  outOfRange.catalog.answer();
  await done;
  t.controller.destroy();
  outOfRange.controller.destroy();
});

test('the focused tile stays until another tile on the page is chosen', async () => {
  const t = setup();
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  t.session.calls.length = 0;
  t.controller.focus(id(3));
  t.controller.focus(id(3));
  t.controller.focus(id(8));       // not on this page
  assert.deepEqual(t.session.calls, [['focus', id(3)]]);
  assert.equal(t.controller.view().tiles.find((tile) => tile.focused).id, id(3));
  t.controller.destroy();
});

test('Play on the first screen goes live from the recordings; afterwards it toggles; Go Live and the keys act on the session', async () => {
  const t = setup();
  const started = t.controller.start();
  t.catalog.answer({ [id(1)]: { oldest: 1, newest: 2 } });
  await started;
  assert.equal(t.controller.view().transport.canGoLive, false);
  t.controller.togglePlay();
  assert.deepEqual(t.session.calls.at(-1), ['goLive']);
  assert.equal(t.controller.view().transport.mode, 'live');
  assert.equal(t.controller.view().transport.playing, true);
  t.controller.togglePlay();
  assert.deepEqual(t.session.calls.at(-1), ['togglePlay']);
  assert.equal(t.controller.view().transport.mode, 'playing');
  assert.equal(t.controller.view().transport.canGoLive, true);
  t.controller.key({ action: 'seek', deltaMs: -10_000 });
  assert.deepEqual(t.session.calls.at(-1), ['seek', -10_000]);
  t.controller.key({ action: 'goLive' });
  assert.deepEqual(t.session.calls.at(-1), ['goLive']);
  t.controller.key({ action: 'togglePlay' });
  assert.deepEqual(t.session.calls.at(-1), ['togglePlay']);
  t.controller.key(null);
  t.controller.retryTile();
  assert.deepEqual(t.session.calls.at(-1), ['seek', 0]);
  t.controller.destroy();
});

test('a browser that cannot play recordings keeps the transport off and the tiles on snapshots', async () => {
  const t = setup({ playable: false });
  const started = t.controller.start();
  t.catalog.answer({ [id(1)]: { oldest: 1, newest: 2 } });
  await started;
  t.controller.togglePlay();
  t.controller.seek(1000);
  assert.deepEqual(t.session.names(), ['setCameras', 'focus']);
  assert.equal(t.controller.view().transport.canPlay, false);
  t.controller.destroy();
});

test('opening a tile hands over the shared moment and puts it in the grid address first', async () => {
  const t = setup();
  const started = t.controller.start();
  t.catalog.answer({ [id(1)]: { oldest: 1, newest: 2 } });
  await started;

  t.controller.openTile(id(2));        // nothing started: live
  assert.deepEqual(t.log.hashes.at(-1), '/nvr');
  assert.deepEqual(t.log.navigations.at(-1), `/camera/${id(2)}/watch`);
  assert.deepEqual(t.log.remembered.at(-1), { page: 0, focusId: id(2), opened: id(2) });

  t.session.scrub(T0 - 90_000);        // paused at a moment
  t.controller.openTile(id(3));
  assert.equal(t.log.hashes.at(-1), `/nvr/${T0 - 90_000}`);
  assert.equal(t.log.navigations.at(-1), `/camera/${id(3)}/watch/${T0 - 90_000}`);

  t.session.mode = 'playing';
  t.session.position = T0 - 30_000.4;
  t.controller.openTile(id(4));
  assert.equal(t.log.navigations.at(-1), `/camera/${id(4)}/watch/${T0 - 30_000}`);

  t.session.mode = 'live';
  t.controller.openTile(id(4));
  assert.equal(t.log.navigations.at(-1), `/camera/${id(4)}/watch`);
  assert.equal(t.log.hashes.at(-1), '/nvr');

  const before = t.log.navigations.length;
  t.controller.openTile(id(9));        // not on this page
  assert.equal(t.log.navigations.length, before);
  t.controller.destroy();
});

test('the address follows the playhead: at most once a second when paused, every 5 s when playing, bare when live', async () => {
  const t = setup();
  const started = t.controller.start();
  t.catalog.answer({ [id(1)]: { oldest: 1, newest: 2 } });
  await started;
  t.time.advance(2000);
  assert.deepEqual(t.log.hashes, [], 'nothing started: the address is left alone');

  t.session.scrub(T0 - 600_000);
  t.time.advance(250);
  assert.deepEqual(t.log.hashes, [`/nvr/${T0 - 600_000}`]);
  t.time.advance(2000);
  assert.equal(t.log.hashes.length, 1, 'unchanged: not written again');

  t.session.scrub(T0 - 300_000);
  t.time.advance(250);
  assert.equal(t.log.hashes.at(-1), `/nvr/${T0 - 300_000}`);

  const before = t.log.hashes.length;          // a drag moves the playhead all the time: the address is written once a second, and ends exact
  for (let i = 1; i <= 8; i += 1) { t.session.scrub(T0 - 300_000 + i * 1000); t.time.advance(250); }
  assert.equal(t.log.hashes.length - before, 2, 'two seconds of dragging, two writes');
  t.time.advance(1000);
  assert.equal(t.log.hashes.at(-1), `/nvr/${T0 - 300_000 + 8000}`);
  t.session.scrub(T0 - 300_000);
  t.time.advance(1000);

  t.session.mode = 'playing';
  t.session.position = T0 - 299_000;
  const writes = t.log.hashes.length;
  t.time.advance(4000);
  assert.equal(t.log.hashes.length, writes, 'playing: at most every 5 s');
  t.session.position = T0 - 295_000;
  t.time.advance(1500);
  assert.equal(t.log.hashes.length, writes + 1);
  assert.equal(t.log.hashes.at(-1), `/nvr/${T0 - 295_000}`);

  t.session.goLive();
  t.time.advance(250);
  assert.equal(t.log.hashes.at(-1), '/nvr');
  t.controller.destroy();
});

test('the combined waveform follows the cameras that have recordings', async () => {
  const t = setup();
  const started = t.controller.start();
  t.catalog.answer({ [id(2)]: { oldest: 1, newest: 2 } });
  await started;
  assert.deepEqual(t.log.waveform, [ids(2)]);
  t.catalog.answer({ [id(2)]: { oldest: 1, newest: 3 } });
  assert.equal(t.log.waveform.length, 1, 'same cameras: the timeline is not told again');
  t.catalog.answer({ [id(5)]: { oldest: 1, newest: 2 } });
  assert.deepEqual(t.log.waveform.at(-1), ids(2, 5), 'cameras on other pages count too');
  assert.deepEqual(t.controller.view().waveform, { ids: ids(2, 5), truncated: false });
  t.controller.destroy();
});

test('a page with no recordings and no camera recording says so', async () => {
  const t = setup({ count: 2 });
  for (const camera of t.cameras) camera.nvrEnabled = false;
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  assert.equal(t.controller.view().noRecordings, true);
  t.cameras[0].nvrEnabled = true;
  assert.equal(t.controller.view().noRecordings, false);
  t.controller.destroy();
});

test('a camera that is added or removed changes the page; a status change alone does not touch the session', async () => {
  const t = setup({ count: 5, perPage: 4 });
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  t.session.calls.length = 0;
  t.cameras[0].status = { ...t.cameras[0].status, connection: 'offline' };
  for (const fn of [...t.cameraListeners]) fn();
  assert.deepEqual(t.session.calls, []);
  assert.equal(t.controller.view().tiles[0].look.state, 'cameraOffline');
  t.cameras.splice(0, 1);                  // the first camera was removed: the page now starts at camera 2
  for (const fn of [...t.cameraListeners]) fn();
  assert.deepEqual(t.session.calls[0], ['setCameras', ids(2, 3, 4, 5)]);
  assert.deepEqual(t.session.calls[1], ['focus', id(2)], 'the focused camera is gone');
  t.controller.destroy();
});

test('the mosaic gives the pages their lengths; a new layout keeps the page that holds the focused camera, else the first one on screen', async () => {
  let lengths = [3, 4, 2];
  const asked = [];
  const t = setup({ count: 9, perPage: 16, paginate: (cameras) => { asked.push(cameras.length); return lengths; } });
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  assert.deepEqual(t.session.calls[0], ['setCameras', ids(1, 2, 3)]);
  assert.ok(asked.length > 0 && asked.every((n) => n === 9), 'paginate is asked with the whole camera list');
  let view = t.controller.view();
  assert.deepEqual([view.page, view.pages, view.first, view.last, view.total], [0, 3, 1, 3, 9]);
  t.controller.nextPage();
  view = t.controller.view();
  assert.deepEqual(view.tiles.map((tile) => tile.id), ids(4, 5, 6, 7));
  assert.deepEqual([view.page, view.first, view.last], [1, 4, 7]);
  // The wall got smaller: two cameras a page. Camera 4 led the page; it is on the third page now, and that page shows.
  lengths = [2, 2, 2, 2, 1];
  t.session.calls.length = 0;
  const before = t.emits.count;
  t.controller.relayout();
  view = t.controller.view();
  assert.deepEqual([view.page, view.pages, view.first, view.last], [1, 5, 3, 4]);
  assert.deepEqual(t.session.calls[0], ['setCameras', ids(3, 4)]);
  await settle();
  assert.equal(t.emits.count, before + 1, 'one redraw');
  // Nothing changed: the session is not asked again.
  t.session.calls.length = 0;
  t.controller.relayout();
  assert.deepEqual(t.session.calls, []);
  // The focused (hovered) camera leads when there is one: cameras 5 and 6 are on screen, 6 is hovered, and the new pages split them.
  t.controller.nextPage();
  t.controller.focus(id(6));
  lengths = [5, 4];
  t.controller.relayout();
  assert.deepEqual(t.controller.view().tiles.map((tile) => tile.id), ids(6, 7, 8, 9), 'the page that holds the focused camera');
  assert.equal(t.controller.focusedId, id(6));
  // The mosaic cannot say yet (no size): fixed pages of perPage.
  lengths = null;
  t.controller.relayout();
  view = t.controller.view();
  assert.deepEqual([view.page, view.pages, view.first, view.last], [0, 1, 1, 9]);
  t.controller.destroy();
});

test('coming back with more than 16 cameras finds the remembered page and camera once the mosaic first gives its pages', async () => {
  let lengths = null;   // the wall is not measured yet: pages of 16 stand in
  const t = setup({ count: 20, perPage: 16, initialPage: 3, initialFocus: id(14), paginate: () => lengths });
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  lengths = [4, 4, 4, 4, 4];   // the person was on the fourth page of four, hovering camera 14
  t.controller.relayout();
  const view = t.controller.view();
  assert.deepEqual(view.tiles.map((tile) => tile.id), ids(13, 14, 15, 16));
  assert.equal(view.page, 3);
  assert.equal(t.controller.focusedId, id(14));
  t.controller.destroy();
});

test('a camera added, removed or with a new shape re-packs the mosaic around the camera that led the page', async () => {
  let lengths = [3, 4, 2];
  const t = setup({ count: 9, perPage: 16, paginate: () => lengths });
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  t.controller.nextPage();         // cameras 4 to 7
  t.controller.focus(id(6));
  lengths = [2, 2, 2, 2, 1];       // camera 1 reported a 4:3 stream: two cameras a page now
  for (const fn of [...t.cameraListeners]) fn();
  assert.deepEqual(t.controller.view().tiles.map((tile) => tile.id), ids(5, 6), 'the page that holds the hovered camera');
  assert.equal(t.controller.focusedId, id(6));
  t.controller.focus(id(5));
  t.controller.nextPage();         // cameras 7 and 8; the person chose this page
  assert.deepEqual(t.controller.view().tiles.map((tile) => tile.id), ids(7, 8), 'a page chosen by hand is not overruled');
  t.controller.destroy();
});

test('without paginate the pages are perPage cameras each, and relayout changes nothing', async () => {
  const t = setup({ count: 9, perPage: 4 });
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  t.session.calls.length = 0;
  t.controller.relayout();
  assert.deepEqual(t.session.calls, []);
  assert.deepEqual([t.controller.view().pages, t.controller.view().last], [3, 4]);
  t.controller.destroy();
  t.controller.relayout();
});

test('an empty bridge has no tiles and no page', async () => {
  const t = setup({ count: 0 });
  const started = t.controller.start();
  t.catalog.answer();
  await started;
  const view = t.controller.view();
  assert.equal(view.noCameras, true);
  assert.deepEqual([view.tiles.length, view.pages, view.first, view.last], [0, 1, 0, 0]);
  assert.deepEqual(t.session.names(), [], 'no cameras: nothing to set');
  t.controller.destroy();
});

test('suspend and resume pass to the session; destroy releases every subscription and stops the tick and the waiting', async () => {
  const t = setup();
  const started = t.controller.start();
  t.catalog.answer({ [id(1)]: { oldest: 1, newest: 2 } });
  await started;
  t.controller.noteRequest();
  t.controller.suspend();
  t.controller.resume();
  assert.deepEqual(t.session.calls.slice(-2), [['suspend'], ['resume']]);
  assert.equal(t.cameraListeners.size, 1);
  assert.equal(t.catalog.listenerCount(), 1);
  assert.equal([...t.session.cells.values()].every((cell) => cell.listeners.size === 1), true);

  t.controller.destroy();
  assert.equal(t.cameraListeners.size, 0);
  assert.equal(t.catalog.listenerCount(), 0);
  assert.equal([...t.session.cells.values()].every((cell) => cell.listeners.size === 0), true);
  assert.equal(t.time.pendingTimers(), 0, 'the tick is cancelled');
  const calls = t.session.calls.length;
  t.controller.togglePlay();
  t.controller.nextPage();
  t.controller.openTile(id(1));
  t.controller.suspend();
  assert.equal(t.session.calls.length, calls);
  assert.deepEqual(t.log.navigations, []);
});

test('destroying while the catalog is still being waited for ends quietly', async () => {
  const t = setup({ initialMs: T0 - 1000 });
  const started = t.controller.start();
  t.controller.destroy();
  t.catalog.answer();
  await started;
  assert.equal(t.session.names().includes('scrub'), false);
  assert.equal(t.time.pendingTimers(), 0);
});

// The fakes the NVR tests stand on must themselves keep the server's contract (T00 C.5), or every test above them proves nothing.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../web/js/api.js';
import { FILE_A, FILE_B, MEDIA_START_TICKS, MIME, ORIGIN, createArchive, createFakeApi, decodeBytes, isBytesPath, routeBytes, routeJson } from './player-fakes/fake-archive.mjs';
import { createFakeTimers } from './player-fakes/fake-timers.mjs';

function fixture() {
  const timers = createFakeTimers();
  // File A: 30 parts of 2 s, a keyframe every 4th part. File B starts 20 s after A ends (a gap), 10 parts, a keyframe in every part.
  const archive = createArchive({
    timers,
    files: [
      { key: FILE_A, startMs: ORIGIN, parts: 30, gop: 4 },
      { key: FILE_B, startMs: ORIGIN + 80_000, parts: 10, gop: 1 },
    ],
  });
  return { timers, archive, api: createFakeApi({ archives: [archive], timers }) };
}

describe('fake timers', () => {
  it('fire in time order, only when advanced, and settle promise chains in between', async () => {
    const timers = createFakeTimers();
    const seen = [];
    timers.setTimeout(() => seen.push('b'), 20);
    timers.setTimeout(() => seen.push('a'), 10);
    const later = timers.sleep(30).then(() => seen.push('c'));
    await timers.advance(9);
    assert.deepEqual(seen, []);
    await timers.advance(1);
    assert.deepEqual(seen, ['a']);
    await timers.advance(100);
    await later;
    assert.deepEqual(seen, ['a', 'b', 'c']);
    assert.equal(timers.now(), 110);
    const id = timers.setTimeout(() => seen.push('never'), 5);
    timers.clearTimeout(id);
    await timers.idle();
    assert.equal(seen.includes('never'), false);
    assert.equal(timers.pending(), 0);
  });
});

describe('fake archive', () => {
  it('finds the part containing a time, start inclusive and end exclusive', () => {
    const { archive } = fixture();
    assert.equal(archive.idOf(archive.containing(ORIGIN)), `${FILE_A}.0`);
    assert.equal(archive.idOf(archive.containing(ORIGIN + 1999)), `${FILE_A}.0`);
    assert.equal(archive.idOf(archive.containing(ORIGIN + 2000)), `${FILE_A}.1`);
    assert.equal(archive.containing(ORIGIN + 60_000), undefined);           // the gap between the files
    assert.equal(archive.idOf(archive.containing(ORIGIN + 80_000)), `${FILE_B}.0`);
    assert.equal(archive.idOf(archive.startingAfter(ORIGIN + 60_000)), `${FILE_B}.0`);
    assert.equal(archive.startingAfter(ORIGIN + 98_000), undefined);
  });

  it('plans from the key part to the target and then looks ahead across files', () => {
    const { archive } = fixture();
    const plan = archive.plan(ORIGIN + 13_000, 2);                           // part 6 of A; its GOP starts at part 4
    assert.equal(plan.found, true);
    assert.deepEqual(plan.parts.map((p) => p.id), [`${FILE_A}.4`, `${FILE_A}.5`, `${FILE_A}.6`, `${FILE_A}.7`, `${FILE_A}.8`]);
    assert.equal(plan.targetIndex, 2);
    assert.equal(plan.exact, true);
    assert.deepEqual(plan.parts.map((p) => p.key), [true, false, false, false, true]);
    assert.equal(plan.parts[0].bytes, 700_000);
    assert.equal(plan.parts[1].bytes, 100_000);
    assert.equal(plan.files[FILE_A].mime, MIME);
    assert.equal(plan.files[FILE_A].initId, `${FILE_A}.4`);
    assert.equal(plan.files[FILE_A].anchor, ORIGIN - MEDIA_START_TICKS / 90);
    const crossing = archive.plan(ORIGIN + 57_000, 2);                       // part 28 of A: the last-but-one part; look-ahead leaves the file
    assert.deepEqual(crossing.parts.map((p) => p.id), [`${FILE_A}.28`, `${FILE_A}.29`, `${FILE_B}.0`]);
    assert.deepEqual(Object.keys(crossing.files).sort(), [FILE_A, FILE_B]);
  });

  it('classifies a time with no recording', () => {
    const { archive } = fixture();
    const gap = archive.plan(ORIGIN + 70_000);
    assert.deepEqual([gap.found, gap.reason, gap.next], [false, 'gap', ORIGIN + 80_000]);
    assert.deepEqual([archive.plan(ORIGIN - 5000).reason, archive.plan(ORIGIN - 5000).next], ['beforeStart', ORIGIN]);
    assert.equal(archive.plan(ORIGIN + 100_000).reason, 'afterEnd');
  });

  it('lists the parts after an id, across the gap', () => {
    const { archive } = fixture();
    const result = archive.after(`${FILE_A}.28`, 3);
    assert.deepEqual(result.parts.map((p) => p.id), [`${FILE_A}.29`, `${FILE_B}.0`, `${FILE_B}.1`]);
    assert.throws(() => archive.after(`${FILE_A}.99`), (error) => error instanceof ApiError && error.status === 410);
  });

  it('stands bytes for parts, and the tfdt and anchor put them on the shared time line', () => {
    const { archive } = fixture();
    const part = archive.containing(ORIGIN + 13_000);
    const media = decodeBytes(archive.mediaBytes(part));
    assert.deepEqual([media.kind, media.id, media.key], ['media', `${FILE_A}.6`, false]);
    const epochMs = archive.fileInfo(FILE_A, 'x').anchor + (media.tfdtTicks / 90_000) * 1000;
    assert.ok(Math.abs(epochMs - part.start) < 1e-6);
    assert.deepEqual(decodeBytes(archive.initBytes(FILE_B)), { kind: 'init', file: FILE_B });
  });

  it('retention removes parts: their ids are gone and the version moves', () => {
    const { archive } = fixture();
    const before = archive.catalogVersion;
    archive.removeBefore(ORIGIN + 10_000);
    assert.equal(archive.byId(`${FILE_A}.0`), undefined);
    assert.ok(archive.byId(`${FILE_A}.5`));
    assert.equal(archive.catalogVersion, before + 1);
    assert.equal(archive.extent().oldest, ORIGIN + 10_000);
  });
});

describe('routes without a clock', () => {
  it('route the JSON and the media paths of the contract, and tell them apart', () => {
    const { archive } = fixture();
    assert.equal(isBytesPath('nvr/cameras'), false);
    assert.equal(isBytesPath('nvr/cameras/CAM-1/fragments?at=1'), false);
    assert.equal(isBytesPath(`nvr/cameras/CAM-1/fragments/${FILE_A}.1`), true);
    assert.equal(isBytesPath(`nvr/cameras/CAM-1/fragments/${FILE_A}.1/init`), true);
    assert.equal(isBytesPath('nvr/cameras/CAM-1/keyframe?at=1'), true);
    assert.equal(routeJson([archive], 'nvr/cameras').cameras[0].id, 'CAM-1');
    assert.equal(decodeBytes(routeBytes([archive], `nvr/cameras/CAM-1/fragments/${FILE_A}.2`).data).id, `${FILE_A}.2`);
    assert.throws(() => routeBytes([archive], `nvr/cameras/CAM-9/fragments/${FILE_A}.2`), (error) => error.status === 404);
  });

  it('a clip that starts at tfdt 0 (ffmpeg) has its anchor at the file start', () => {
    const timers = createFakeTimers();
    const archive = createArchive({ timers, files: [{ key: FILE_A, startMs: ORIGIN, parts: 3, mediaStartTicks: 0 }] });
    assert.equal(archive.fileInfo(FILE_A, 'x').anchor, ORIGIN);
    assert.equal(decodeBytes(archive.mediaBytes(archive.byId(`${FILE_A}.2`))).tfdtTicks, 2 * 2000 * 90);
  });
});

describe('fake api', () => {
  it('serves the routes with the contract shapes', async () => {
    const { api, timers } = fixture();
    const pending = Promise.all([
      api.get('nvr/cameras'),
      api.get(`nvr/cameras/CAM-1/fragments?at=${ORIGIN + 13_000}&ahead=1`),
      api.getBytes(`nvr/cameras/CAM-1/keyframe?at=${ORIGIN + 13_000}`),
      api.getBytes(`nvr/cameras/CAM-1/fragments/${FILE_A}.6`),
      api.getBytes(`nvr/cameras/CAM-1/fragments/${FILE_A}.6/init`),
    ]);
    await timers.advance(100);
    const [catalog, plan, key, fragment, init] = await pending;
    assert.deepEqual(Object.keys(catalog), ['serverTime', 'catalogVersion', 'cameras']);
    assert.deepEqual(catalog.cameras[0], { id: 'CAM-1', oldest: ORIGIN, newest: ORIGIN + 100_000, typicalGOP: 8 });
    assert.equal(plan.parts.length, 4);
    const header = JSON.parse(key.headers.get('X-CB-Part'));
    assert.deepEqual([header.id, header.start, header.end, header.mime, header.initId], [`${FILE_A}.4`, ORIGIN + 8000, ORIGIN + 10_000, MIME, `${FILE_A}.4`]);
    assert.equal(decodeBytes(key.data).id, `${FILE_A}.4`);
    assert.equal(decodeBytes(fragment.data).id, `${FILE_A}.6`);
    assert.equal(decodeBytes(init.data).kind, 'init');
  });

  it('answers 404 gap with X-CB-Next, 410 gone and 404 for an unknown camera', async () => {
    const { api, archive, timers } = fixture();
    const gap = api.getBytes(`nvr/cameras/CAM-1/keyframe?at=${ORIGIN + 70_000}`).catch((error) => error);
    archive.removeBefore(ORIGIN + 20_000);
    const gone = api.getBytes(`nvr/cameras/CAM-1/fragments/${FILE_A}.0`).catch((error) => error);
    const unknown = api.getBytes(`nvr/cameras/NOPE/fragments/${FILE_A}.0`).catch((error) => error);
    await timers.advance(100);
    const [g, o, u] = [await gap, await gone, await unknown];
    assert.deepEqual([g.status, g.code, g.next], [404, 'gap', ORIGIN + 80_000]);
    assert.deepEqual([o.status, o.code], [410, 'gone']);
    assert.deepEqual([u.status, u.code], [404, 'not_found']);
  });

  it('counts requests in flight, aborts on a signal and injects failures', async () => {
    const { api, timers } = fixture();
    const first = api.getBytes(`nvr/cameras/CAM-1/fragments/${FILE_A}.1`);
    const second = api.getBytes(`nvr/cameras/CAM-1/fragments/${FILE_A}.2`);
    await timers.advance(100);
    await Promise.all([first, second]);
    assert.equal(api.stats().worst.bytes, 2);
    assert.equal(api.stats().perCamera.get('CAM-1'), 2);
    assert.equal(api.stats().now.bytes, 0);

    const controller = new AbortController();
    const aborted = api.getBytes(`nvr/cameras/CAM-1/fragments/${FILE_A}.3`, { signal: controller.signal }).catch((error) => error);
    await timers.advance(5);
    controller.abort();
    assert.equal((await aborted).name, 'AbortError');
    assert.equal(api.log.at(-1).aborted, true);

    api.failWhen('keyframe', () => new ApiError(429, 'busy', 'Busy.', null, { retryAfter: 1 }), { times: 1 });
    const failing = api.getBytes(`nvr/cameras/CAM-1/keyframe?at=${ORIGIN + 13_000}`).catch((error) => error);
    await timers.advance(100);
    assert.equal((await failing).code, 'busy');
    const fine = api.getBytes(`nvr/cameras/CAM-1/keyframe?at=${ORIGIN + 13_000}`);
    await timers.advance(100);
    assert.equal(decodeBytes((await fine).data).id, `${FILE_A}.4`);
  });
});

// The real fetcher, catalog, clock and cell over a fake archive, fake routes and a fake surface: the rig the cell, session and storm tests share.
import { PlaybackClock } from '../../web/js/nvr/clock.js';
import { createCatalog } from '../../web/js/nvr/catalog.js';
import { createCell } from '../../web/js/nvr/cell.js';
import { createFetcher } from '../../web/js/nvr/fetcher.js';
import { FILE_A, FILE_B, ORIGIN, createArchive, createFakeApi } from './fake-archive.mjs';
import { FakeSurface } from './fake-surface.mjs';
import { createFakeTimers } from './fake-timers.mjs';

export const SERVER_AT_ZERO = ORIGIN + 3_600_000;

/** Just enough of an element for the cell to build its media elements in a stage. */
export function fakeElement(tag, parent = null) {
  const element = {
    tag, attributes: {}, style: { display: '' }, parent, width: 0, height: 0, removed: false,
    setAttribute(name, value) { element.attributes[name] = value; },
    remove() { element.removed = true; if (element.parent) element.parent.children = element.parent.children.filter((child) => child !== element); },
    addEventListener() {}, removeEventListener() {},
  };
  return element;
}

export function fakeStage() {
  const stage = { children: [], ownerDocument: { createElement: (tag) => fakeElement(tag) }, append(...nodes) { for (const node of nodes) { node.parent = stage; stage.children.push(node); } } };
  return stage;
}

/** File A: 120 s in 60 parts with a keyframe every 4th part (an 8 s GOP). Then a 20 s gap. File B: 40 s, a keyframe in every part. */
export const defaultFiles = () => [
  { key: FILE_A, startMs: ORIGIN, parts: 60, gop: 4 },
  { key: FILE_B, startMs: ORIGIN + 140_000, parts: 20, gop: 1 },
];

export function createRig({ cameras = [{ id: 'CAM-1', files: defaultFiles() }], latency, leadLimitBytes, surfaceOptions, policy } = {}) {
  const timers = createFakeTimers();
  const archives = cameras.map((camera) => createArchive({ timers, cameraId: camera.id, files: camera.files, serverEpochAtZero: SERVER_AT_ZERO }));
  const api = createFakeApi({ archives, timers, latency });
  const fetcher = createFetcher({ get: api.get, getBytes: api.getBytes, sleep: timers.sleep });
  const catalog = createCatalog({ fetcher, now: () => SERVER_AT_ZERO + timers.now(), perf: timers.now, timers });
  const clock = new PlaybackClock({ serverNow: catalog.serverNow, perf: timers.now });
  const surfaces = new Map();

  const rig = {
    timers, archives, archive: archives[0], api, fetcher, catalog, clock, surfaces,
    base: () => catalog.baseMs,
    surface: (id = archives[0].cameraId) => surfaces.get(id),
    stages: new Map(),
    makeSurface(id, elements = {}) {
      const surface = new FakeSurface({ timers, ...surfaceOptions });
      surface.elements = elements;
      surfaces.set(id, surface);
      return surface;
    },
    makeCell(id = archives[0].cameraId, options = {}) {
      const stage = fakeStage();
      rig.stages.set(id, stage);
      return createCell({ cameraId: id, stage, catalog, fetcher, clock, createSurface: (elements) => rig.makeSurface(id, elements), timers, policy, leadLimitBytes, ...options });
    },
    /** Starts the catalog and lets its first answer arrive, so the time base is known. */
    async start() {
      catalog.start();
      await timers.advance(100);
    },
    paths: (pattern) => api.log.filter((entry) => entry.path.includes(pattern)).map((entry) => entry.path),
    /** Every request except the catalog's own once-a-second poll. */
    requests: () => api.log.filter((entry) => entry.path !== 'nvr/cameras'),
  };
  return rig;
}

/** desire(targetMs, precision, playing) with a rising epoch. */
export function desirer(cell, firstEpoch = 1) {
  let epoch = firstEpoch - 1;
  return (targetMs, precision = 'exact', playing = false, extra = {}) => {
    epoch += 1;
    cell.request({ targetMs, precision, playing, epoch, ...extra });
    return epoch;
  };
}

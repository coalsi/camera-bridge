// The watch screen's player holds what the person sees while it builds its buffer again (js/nvr/surface.js `holdFrom`): the straightened
// picture, not the camera's own frame. The whole screen in the fake browser, with a stand-in for the player's cell and surface.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { drawnFrom, givePicture, planCalls, recordingCanvases, siblingAfter } from './support/fake-picture.mjs';

const BACKYARD = { straighten: 0.4, level: 0.15 };
const FLATTER = { straighten: -0.2, level: 0.05 };
const OFF = { straighten: 0, level: 0 };

let browser;
let store;
let putCamera;
let renderWatch;
let CAMERA_DEFINITIONS;
let cameraConfiguration;

before(async () => {
  browser = installFakeBrowser();
  recordingCanvases(browser.document);          // 2D canvases that record what they draw, and no WebGL: a straightened picture is read from its strip plan
  globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  globalThis.fetch = async () => ({ status: 404, ok: false, json: async () => ({}), text: async () => '{}', headers: { get: () => null } });
  ({ store, putCamera } = await import('../web/js/store.js'));
  ({ renderWatch } = await import('../web/js/screens/watch.js'));
  ({ CAMERA_DEFINITIONS, cameraConfiguration } = await import('../web-dev/lib/cameras.mjs'));
});
after(() => {
  delete globalThis.Image;
  delete globalThis.ResizeObserver;
  delete globalThis.fetch;
  browser?.restore();
});

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}

/**
 * The watch screen of a camera whose saved correction is `pictureCorrection`, with a cell that does nothing (it hands the screen's surface
 * factory to the test) and a surface that remembers the options it was built with. -> { page, video, surface() } where surface() builds one
 * the way the cell does.
 */
function openWatch(pictureCorrection) {
  const camera = { ...cameraConfiguration(CAMERA_DEFINITIONS[1]), pictureCorrection,
    status: { connection: 'online', summary: 'Live', recentEvents: [], nvr: { state: 'off', detail: null, pause: null, notes: [] } } };
  store.cameras.set(camera.id, camera);
  const cells = [];
  class FakeSurface { constructor(options) { this.options = options; } }
  const player = {
    Surface: FakeSurface,
    createCell: (options) => {
      cells.push(options);
      return { coverage: { kind: 'idle', next: null, message: null }, onChange: () => () => {}, request() {}, destroy() {}, suspend() {}, resume() {} };
    },
  };
  const page = renderWatch({ params: [camera.id], navigate() {}, setTitle() {}, player });
  let video;
  try {
    assert.equal(cells.length, 1, 'the screen made its cell');
    video = all(page.el, (node) => node.localName === 'video')[0];
    assert.ok(video, 'the screen has its video');
  } catch (error) {
    page.destroy();     // its timers would keep the test running
    store.cameras.clear();
    throw error;
  }
  givePicture(video, { width: 640, height: 284 });
  return {
    camera, page, video,
    /** The surface as the cell builds it: it gives the factory its two elements and a `holdFrom` of its own. */
    surface() {
      const holdCanvas = all(page.el, (node) => node.localName === 'canvas' && node.className.includes('watch-hold'))[0];
      assert.ok(holdCanvas, 'the screen has its hold canvas');
      return cells[0].createSurface({ video, holdCanvas, holdFrom: () => null }).options;
    },
    close() { page.destroy(); store.cameras.clear(); },
  };
}

describe('the watch screen holds the picture the person sees', () => {
  test('a straightened camera: the player is given the straightened canvas, drawn now with the camera’s correction', () => {
    const w = openWatch(BACKYARD);
    try {
      const options = w.surface();
      assert.equal(options.video, w.video);
      assert.equal(typeof options.holdFrom, 'function', 'a hold of its own, not the video’s frame');
      const canvas = options.holdFrom();
      assert.ok(canvas, 'the straightened canvas');
      assert.equal(canvas, siblingAfter(w.video), 'the one right after the video, under the hold');
      assert.notEqual(canvas, w.video);
      const from = canvas.getContext('2d').draws.length;
      assert.ok(options.holdFrom() === canvas);
      assert.deepEqual(drawnFrom(canvas, w.video, from), planCalls(BACKYARD, 640, 284), 'drawn again at once with the camera’s correction, to be copied');
    } finally {
      w.close();
    }
  });

  test('a correction saved meanwhile is the one drawn; off, the hold is the video’s own frame', () => {
    const w = openWatch(BACKYARD);
    try {
      const { holdFrom } = w.surface();
      const canvas = holdFrom();
      putCamera({ ...w.camera, pictureCorrection: FLATTER });
      const from = canvas.getContext('2d').draws.length;
      assert.equal(holdFrom(), canvas, 'still straightened, on the same canvas');
      assert.deepEqual(drawnFrom(canvas, w.video, from).slice(-planCalls(FLATTER, 640, 284).length), planCalls(FLATTER, 640, 284));
      putCamera({ ...w.camera, pictureCorrection: OFF });
      assert.equal(holdFrom(), null, 'off: the surface holds the video’s own frame');
    } finally {
      w.close();
    }
  });

  test('a camera that is not straightened: nothing to hold but the video’s own frame', () => {
    const w = openWatch(OFF);
    try {
      const { holdFrom } = w.surface();
      assert.equal(holdFrom(), null);
      putCamera({ ...w.camera, pictureCorrection: BACKYARD });         // turned on while the screen is open
      assert.ok(holdFrom(), 'and straightened from then on');
    } finally {
      w.close();
    }
  });
});

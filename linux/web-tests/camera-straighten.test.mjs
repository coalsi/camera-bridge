// The camera page's "Straighten the picture" card (screens/camera.js) and the preview it straightens while its sliders move: the whole page
// in the fake browser, with fake requests (a PATCH answered the way the bridge answers it) and canvases that record what they draw.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { landing, stripPlan } from '../web/js/live/straighten.js';

const BACKYARD = { straighten: 0.4, level: 0.15 };
const OFF = { straighten: 0, level: 0 };
const LINE = 'Applies everywhere this camera is seen: live view, the Monitor, recordings, saved clips and Apple Home. Recordings keep the camera’s original picture.';
const ENCODER = ' Straighten the picture is on, so Apple Home’s live view and recordings always use the video encoder.';

let browser;
let store;
let putCamera;
let renderCamera;
let CAMERA_DEFINITIONS;
let cameraConfiguration;
const images = [];   // every new Image() the page made: the preview's snapshots load through one

before(async () => {
  browser = installFakeBrowser();
  // A canvas gives a recording 2D context and no WebGL, so a straightened picture is drawn through the strip plan, where it can be read.
  const create = browser.document.createElement;
  browser.document.createElement = (tag) => {
    const el = create(tag);
    if (tag !== 'canvas') return el;
    Object.assign(el, { width: 300, height: 150 });
    const context = { draws: [], drawImage(...args) { this.draws.push(args); } };
    el.getContext = (kind) => (kind === '2d' ? context : null);
    return el;
  };
  globalThis.Image = class { constructor() { images.push(this); } set src(value) { this.value = value; } get src() { return this.value; } };
  ({ store, putCamera } = await import('../web/js/store.js'));
  ({ renderCamera } = await import('../web/js/screens/camera.js'));
  ({ CAMERA_DEFINITIONS, cameraConfiguration } = await import('../web-dev/lib/cameras.mjs'));
});
after(() => {
  delete globalThis.Image;
  browser?.restore();
});

// MARK: Helpers

const settle = () => new Promise((resolve) => setImmediate(resolve));

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList.contains(name));
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const siblingAfter = (el) => el.parentNode.childNodes[el.parentNode.childNodes.indexOf(el) + 1];
const cardTitled = (root, title) => byClass(root, 'card').find((card) => card.childNodes.some((child) => child.localName === 'h2' && child.textContent === title));
/** The visible paragraphs of `root`, as text. */
const lines = (root) => all(root, (node) => node.localName === 'p' && visible(node)).map((node) => node.textContent);

/** The input that the card's label `name` is for. */
function slider(card, name) {
  const label = all(card, (node) => node.localName === 'label' && node.textContent === name)[0];
  assert.ok(label, `a label “${name}”`);
  return all(card, (node) => node.localName === 'input' && node.getAttribute('id') === label.getAttribute('for'))[0];
}
const number = (card, input) => all(card, (node) => node.localName === 'output' && node.getAttribute('for') === input.getAttribute('id'))[0]?.textContent;
const button = (card, text) => all(card, (node) => node.localName === 'button' && node.textContent === text)[0];

/** Moves a slider to `value`: 'input' while it is dragged, 'change' when it is let go. */
function move(input, value, type = 'input') {
  input.value = String(value);
  input.dispatchEvent({ type, target: input });
}
/** A pointer drags the slider through `values` and lets go (pointerup, then change, as a browser sends them). */
function drag(input, ...values) {
  input.dispatchEvent({ type: 'pointerdown', target: input });
  for (const value of values) move(input, value);
  input.dispatchEvent({ type: 'pointerup', target: input });
  move(input, values.at(-1), 'change');
}
/** One arrow key on the slider: a range input sends input and change for each step. */
function press(input, value) {
  input.dispatchEvent({ type: 'keydown', key: 'ArrowRight', target: input });
  move(input, value);
  move(input, value, 'change');
}

/**
 * The drawImage calls that draw the picture straightened by `c` on a canvas of its own size `width` × `height` (the strip plan), the
 * picture written 'picture' (a fake element holds the whole page: a failed comparison would print all of it).
 */
const planCalls = (c, width, height) => stripPlan(c, width, height).map((r) => ['picture', r.sx, r.sy, r.sw, r.sh, r.dx, r.dy, r.dw, r.dh]);
/** What the canvas after `source` drew, in planCalls' terms. */
const drawn = (source) => siblingAfter(source).getContext('2d').draws.map(([from, ...rest]) => [from === source ? 'picture' : 'something else', ...rest]);

const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

/**
 * The bridge behind fetch: PATCH cameras/:id answers the camera with the change in it (as the bridge does); nothing else is there. `late`:
 * each PATCH waits in `waiting` until the test calls its answer().
 */
function fakeBridge(camera, { late = false } = {}) {
  const patches = [];
  const waiting = [];
  let current = camera;
  globalThis.fetch = async (url, init = {}) => {
    if (init.method === 'PATCH' && url === `/api/v1/cameras/${camera.id}`) {
      const body = JSON.parse(init.body);
      patches.push(body);
      const answer = () => { current = { ...current, ...body }; return reply(200, current); };
      return late ? new Promise((resolve) => { waiting.push({ answer: () => resolve(answer()) }); }) : answer();
    }
    return reply(404, { error: 'not_found', message: 'There is nothing here.' });
  };
  return { patches, waiting };
}

/** Waits until `find()` gives something (the page builds its right column after its first requests). */
async function until(find) {
  for (let tries = 0; tries < 400; tries += 1) {
    const found = find();
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error('it never appeared');
}

/** The camera page of a camera (online unless `connection` says) whose saved correction is `pictureCorrection`, built and settled. */
async function openPage(pictureCorrection, { late = false, connection = 'online' } = {}) {
  const camera = { ...cameraConfiguration(CAMERA_DEFINITIONS[1]), vendorName: 'ONVIF', pictureCorrection,
    status: { connection, summary: 'Live', recentEvents: [], nvr: { state: 'off', detail: null, pause: null, notes: [] } } };
  store.cameras.set(camera.id, camera);
  const bridge = fakeBridge(camera, { late });
  images.length = 0;
  const page = renderCamera({ params: [camera.id], navigate() {}, setTitle() {} });
  let card;
  try {
    card = await until(() => cardTitled(page.el, 'Straighten the picture'));
  } catch (error) {
    page.destroy();   // its timers would keep the test running
    store.cameras.clear();
    throw error;
  }
  const preview = byClass(page.el, 'preview')[0];
  const img = all(preview, (node) => node.localName === 'img')[0];
  const video = all(preview, (node) => node.localName === 'video')[0];
  return {
    camera, bridge, page, card, preview, img, video,
    /** The picture arrived: `width` × `height`, shown at its own size. */
    picture(width = 640, height = 284) {
      Object.assign(img, { naturalWidth: width, naturalHeight: height, complete: true, clientWidth: width, clientHeight: height });
    },
    close() { page.destroy(); store.cameras.clear(); },
  };
}

// MARK: The card

describe('Straighten the picture on the camera page', () => {
  test('the card shows two sliders at the saved values and Reset', async () => {
    const p = await openPage(BACKYARD);
    try {
      const straighten = slider(p.card, 'Straighten');
      const level = slider(p.card, 'Level');
      assert.deepEqual([straighten.getAttribute('type'), straighten.getAttribute('min'), straighten.getAttribute('max'), String(straighten.value)], ['range', '-60', '60', '40']);
      assert.deepEqual([level.getAttribute('type'), level.getAttribute('min'), level.getAttribute('max'), String(level.value)], ['range', '-40', '40', '15']);
      assert.deepEqual([number(p.card, straighten), number(p.card, level)], ['40', '15'], 'their numbers');
      assert.ok(button(p.card, 'Reset'), 'a Reset button');
      assert.ok(lines(p.card).includes(LINE), 'the line about where it applies');
      const cards = byClass(p.page.el, 'card');
      assert.equal(cards.indexOf(p.card), cards.indexOf(cardTitled(p.page.el, 'Labels on video')) + 1, 'right after Labels on video');
    } finally {
      p.close();
    }
  });

  test('moving a slider previews without saving; releasing saves once', async () => {
    const p = await openPage(BACKYARD);
    try {
      p.picture();
      const straighten = slider(p.card, 'Straighten');
      straighten.dispatchEvent({ type: 'pointerdown', target: straighten });
      move(straighten, 41);
      const canvas = siblingAfter(p.img);
      assert.equal(canvas.localName, 'canvas', 'the preview’s picture is straightened');
      canvas.getContext('2d').draws.length = 0;
      move(straighten, 42);
      assert.deepEqual(drawn(p.img), planCalls({ straighten: 0.42, level: 0.15 }, 640, 284), 'drawn at once with the slider’s value');
      assert.equal(number(p.card, straighten), '42');
      putCamera({ ...p.camera, status: { ...p.camera.status, summary: 'Still live' } });   // news from the camera meanwhile
      assert.equal(String(straighten.value), '42', 'a slider being moved stays where it is');
      await settle();
      assert.equal(p.bridge.patches.length, 0, 'moving saves nothing');

      straighten.dispatchEvent({ type: 'pointerup', target: straighten });
      move(straighten, 42, 'change');
      await settle();
      assert.deepEqual(p.bridge.patches, [{ pictureCorrection: { straighten: 0.42, level: 0.15 } }], 'one save, at once, when it is let go');
      assert.equal(cardTitled(p.page.el, 'Straighten the picture'), p.card, 'the page is not built again');
      assert.equal(byClass(p.page.el, 'preview')[0], p.preview, 'the preview keeps running');
      assert.equal(siblingAfter(p.img), canvas, 'still straightened, on the same canvas');
      assert.equal(String(straighten.value), '42');
    } finally {
      p.close();
    }
    assert.notEqual(siblingAfter(p.img)?.localName, 'canvas', 'the page gone: its straightened views are too');
    assert.notEqual(siblingAfter(p.video)?.localName, 'canvas', 'the video’s as well');
  });

  test('Reset saves off', async () => {
    const p = await openPage(BACKYARD);
    try {
      p.picture();
      assert.equal(siblingAfter(p.img).localName, 'canvas');
      assert.equal(siblingAfter(p.video).localName, 'canvas', 'the live video has its view too');
      button(p.card, 'Reset').click();
      await settle();
      assert.deepEqual(p.bridge.patches, [{ pictureCorrection: { straighten: 0, level: 0 } }]);
      assert.deepEqual([String(slider(p.card, 'Straighten').value), String(slider(p.card, 'Level').value)], ['0', '0']);
      assert.deepEqual([number(p.card, slider(p.card, 'Straighten')), number(p.card, slider(p.card, 'Level'))], ['0', '0']);
      assert.notEqual(siblingAfter(p.img)?.localName, 'canvas', 'off: the camera’s own picture, no canvas');
      assert.notEqual(siblingAfter(p.video)?.localName, 'canvas', 'for the video too');
      assert.equal(p.img.classList.contains('straighten-source'), false);
      assert.equal(p.video.classList.contains('straighten-source'), false);
      assert.equal(byClass(p.preview, 'straighten-guide')[0].hidden, true, 'and no guide');
    } finally {
      p.close();
    }
  });

  test('the preview asks for the original picture', async () => {
    const p = await openPage(BACKYARD);
    try {
      const snapshots = images.map((image) => image.src).filter(Boolean);
      assert.ok(snapshots.length >= 1, 'a snapshot was asked for');
      for (const url of snapshots) assert.match(url, new RegExp(`^/api/v1/cameras/${p.camera.id}/snapshot\\?original=1&t=\\d+$`));
      assert.match(p.img.src, new RegExp(`^/api/v1/cameras/${p.camera.id}/live\\?original=1&t=\\d+$`), 'and so does the picture stream');
    } finally {
      p.close();
    }
  });

  test('the picture stream is drawn again every second (a browser tells of its first picture only)', async (t) => {
    t.mock.timers.enable({ apis: ['setInterval'] });
    const p = await openPage(BACKYARD);
    try {
      p.picture();
      p.img.dispatchEvent({ type: 'load' });   // the stream's first picture: its only load event
      siblingAfter(p.img).getContext('2d').draws.length = 0;
      t.mock.timers.tick(1000);
      assert.deepEqual(drawn(p.img), planCalls(BACKYARD, 640, 284), 'its newest picture, straightened');
    } finally {
      p.close();
    }
  });

  test('a strong setting says how much it stretches', async () => {
    const stretched = 'At this setting parts of the picture are stretched up to 2.7×.';
    const strong = await openPage(BACKYARD);
    try {
      assert.ok(lines(strong.card).includes(stretched));
      move(slider(strong.card, 'Level'), 0);
      move(slider(strong.card, 'Straighten'), 10);
      assert.equal(lines(strong.card).some((line) => line.includes('stretched')), false, 'gone as the sliders move below 2×');
    } finally {
      strong.close();
    }
    const gentle = await openPage({ straighten: 0.1, level: 0 });
    try {
      assert.equal(lines(gentle.card).some((line) => line.includes('stretched')), false, 'below 2×: no such line');
    } finally {
      gentle.close();
    }
  });

  test('the guide line lies where the straightened horizon lands, across the picture and not the bars beside it', async () => {
    const p = await openPage(BACKYARD);
    try {
      const guide = byClass(p.preview, 'straighten-guide')[0];
      assert.ok(guide, 'a guide on the preview');
      Object.assign(p.preview, { clientWidth: 960, clientHeight: 540 });
      Object.assign(p.img, { naturalWidth: 1920, naturalHeight: 852 });
      p.img.dispatchEvent({ type: 'load' });
      const place = () => ['left', 'width', 'top'].map((key) => Number.parseFloat(guide.style[key]));
      const close = (got, want, message) => got.forEach((value, index) => assert.ok(Math.abs(value - want[index]) < 1e-9, `${message}: ${got} want ${want}`));
      assert.equal(guide.hidden, false);
      // 1920 × 852 in 960 × 540: 960 × 426 with bars of 57 above and below.
      close(place(), [0, 100, (57 + landing(BACKYARD) * 426) / 540 * 100], 'a wide picture');
      move(slider(p.card, 'Straighten'), -30);
      close(place(), [0, 100, (57 + landing({ straighten: -0.3, level: 0.15 }) * 426) / 540 * 100], 'it follows the slider');
      Object.assign(p.img, { naturalWidth: 640, naturalHeight: 480 });   // a 4:3 picture: bars at the sides
      p.img.dispatchEvent({ type: 'load' });
      close(place(), [12.5, 75, landing({ straighten: -0.3, level: 0.15 }) * 100], 'a narrow picture');
      globalThis.getComputedStyle = () => ({ objectFit: 'cover', objectPosition: '50% 50%' });   // the picture's own fit is read
      p.img.dispatchEvent({ type: 'load' });
      // 640 × 480 covering 960 × 540: 960 × 720, 90 cut off above and below.
      close(place(), [0, 100, (-90 + landing({ straighten: -0.3, level: 0.15 }) * 720) / 540 * 100], 'a picture that covers its box');
      delete globalThis.getComputedStyle;

      move(slider(p.card, 'Straighten'), 0);
      move(slider(p.card, 'Level'), 0);
      assert.equal(guide.hidden, true, 'both sliders at 0: no guide');
      assert.notEqual(siblingAfter(p.img)?.localName, 'canvas', 'and no straightened view');
      move(slider(p.card, 'Level'), -5);
      assert.equal(guide.hidden, false, 'one slider off 0: the guide again');
      assert.equal(siblingAfter(p.img).localName, 'canvas');
    } finally {
      delete globalThis.getComputedStyle;
      p.close();
    }
  });

  test('no guide over the placeholder: a camera that shows no picture has none', async () => {
    const p = await openPage(BACKYARD, { connection: 'offline' });
    try {
      assert.equal(byClass(p.preview, 'placeholder')[0].hidden, false, 'the placeholder shows');
      assert.equal(byClass(p.preview, 'straighten-guide')[0].hidden, true);
      move(slider(p.card, 'Straighten'), 30);
      assert.equal(byClass(p.preview, 'straighten-guide')[0].hidden, true, 'not while the sliders move either');
    } finally {
      p.close();
    }
  });

  test('keys save once they pause, one save on its way at a time, and the slider never jumps back', async (t) => {
    const p = await openPage(OFF, { late: true });
    t.mock.timers.enable({ apis: ['setTimeout'] });
    try {
      const straighten = slider(p.card, 'Straighten');
      for (const value of [1, 2, 3, 4, 5]) press(straighten, value);
      await settle();
      assert.equal(p.bridge.patches.length, 0, 'nothing while the keys go on');
      t.mock.timers.tick(400);
      await settle();
      assert.deepEqual(p.bridge.patches, [{ pictureCorrection: { straighten: 0.05, level: 0 } }], 'one save once they pause');
      for (const value of [6, 7, 8]) press(straighten, value);
      t.mock.timers.tick(400);
      await settle();
      assert.equal(p.bridge.patches.length, 1, 'the next waits for the answer to the one on its way');
      // The answers come late, the newest first; the slider stays where the keys left it all along.
      while (p.bridge.waiting.length) {
        for (const request of p.bridge.waiting.splice(0).reverse()) request.answer();
        await settle();
        assert.equal(String(straighten.value), '8', 'the slider never jumps back');
        assert.equal(number(p.card, straighten), '8');
      }
      assert.ok(p.bridge.patches.length <= 2, `at most two saves, not ${p.bridge.patches.length}`);
      assert.deepEqual(p.bridge.patches.at(-1), { pictureCorrection: { straighten: 0.08, level: 0 } }, 'the newest value is the one saved');
      assert.deepEqual(store.cameras.get(p.camera.id).pictureCorrection, { straighten: 0.08, level: 0 });
    } finally {
      p.close();
    }
  });

  test('an arrow-key edit made less than 400 ms before leaving the page is saved, not lost', async (t) => {
    const p = await openPage(OFF);
    t.mock.timers.enable({ apis: ['setTimeout'] });
    let left = false;
    try {
      press(slider(p.card, 'Straighten'), 12);
      await settle();
      assert.equal(p.bridge.patches.length, 0, 'the keys have not paused yet');
      p.page.destroy();      // the person goes to another page
      left = true;
      await settle();
      t.mock.timers.tick(1000);
      await settle();
      assert.deepEqual(p.bridge.patches, [{ pictureCorrection: { straighten: 0.12, level: 0 } }], 'the edit was sent as the page went, once');
    } finally {
      if (left) store.cameras.clear(); else p.close();
    }
  });

  test('an arrow-key edit still waiting for its pause is saved when the page is built again', async (t) => {
    const p = await openPage(OFF);
    t.mock.timers.enable({ apis: ['setTimeout'] });
    try {
      press(slider(p.card, 'Level'), -7);
      await settle();
      assert.equal(p.bridge.patches.length, 0, 'the keys have not paused yet');
      // Another browser edited something else about the camera: the page is built again, with a new Straighten card.
      putCamera({ ...p.camera, name: 'Backyard, renamed' });
      for (let rounds = 0; rounds < 40 && cardTitled(p.page.el, 'Straighten the picture') === p.card; rounds += 1) await settle();
      assert.notEqual(cardTitled(p.page.el, 'Straighten the picture'), p.card, 'the page was built again');
      t.mock.timers.tick(1000);
      await settle();
      assert.deepEqual(p.bridge.patches, [{ pictureCorrection: { straighten: 0, level: -0.07 } }], 'the edit was sent once, by the card that was replaced');
    } finally {
      p.close();
    }
  });

  test('news from elsewhere waits while a slider is held; a drag that ends where it began holds nothing', async () => {
    const p = await openPage(BACKYARD);
    try {
      p.picture();
      const straighten = slider(p.card, 'Straighten');
      straighten.dispatchEvent({ type: 'pointerdown', target: straighten });
      move(straighten, 30);
      putCamera({ ...p.camera, pictureCorrection: { straighten: -0.2, level: 0.1 } });   // another browser saved meanwhile
      assert.deepEqual([String(straighten.value), String(slider(p.card, 'Level').value)], ['30', '15'], 'the hand on the slider wins');
      const held = { straighten: 0.3, level: 0.15 };
      assert.deepEqual(drawn(p.img).slice(-stripPlan(held, 640, 284).length), planCalls(held, 640, 284), 'the preview shows what the hand chose');
      move(straighten, 40);   // back where it began: let go, the browser sends no change
      straighten.dispatchEvent({ type: 'pointerup', target: straighten });
      putCamera({ ...p.camera, pictureCorrection: { straighten: 0.1, level: -0.05 } });
      assert.deepEqual([String(straighten.value), String(slider(p.card, 'Level').value)], ['10', '-5'], 'let go: news moves it again');
      await settle();
      assert.equal(p.bridge.patches.length, 0);
    } finally {
      p.close();
    }
  });

  test('the page follows the saved correction in place: Apple Home’s encoder sentence, another browser’s change', async () => {
    const p = await openPage(OFF);
    try {
      p.picture();
      const quality = cardTitled(p.page.el, 'Live view and Home recording');
      assert.equal(quality.textContent.includes(ENCODER.trim()), false, 'off: not a word about it');
      const straighten = slider(p.card, 'Straighten');
      drag(straighten, 40);
      await settle();
      assert.equal(cardTitled(p.page.el, 'Live view and Home recording'), quality, 'the page is not built again');
      assert.ok(quality.textContent.includes(`ones that use B-frames.${ENCODER}`), 'saved on: the encoder sentence, next to the timestamp’s place');

      const other = { straighten: -0.2, level: 0.1 };
      putCamera({ ...p.camera, pictureCorrection: other });   // changed in another browser
      assert.deepEqual([String(straighten.value), String(slider(p.card, 'Level').value)], ['-20', '10']);
      assert.deepEqual(drawn(p.img).slice(-stripPlan(other, 640, 284).length), planCalls(other, 640, 284), 'the preview follows');
      assert.equal(cardTitled(p.page.el, 'Straighten the picture'), p.card);
      putCamera({ ...p.camera, pictureCorrection: OFF });
      assert.equal(quality.textContent.includes(ENCODER.trim()), false, 'off again: the sentence goes');
      assert.notEqual(siblingAfter(p.img)?.localName, 'canvas');
    } finally {
      p.close();
    }
  });
});

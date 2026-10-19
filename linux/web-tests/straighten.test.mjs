// Straighten the picture in the browser (js/live/straighten.js): the formula against the vectors the Swift copy is pinned to, the 2D strip
// plan, and the view that draws a camera's picture straightened over it (WebGL, else the strip plan, also after a lost WebGL context).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { createStraightenedView, GLSL_STRAIGHTEN, horizon, isOn, landing, largestStretch, sourceFraction, stripPlan } from '../web/js/live/straighten.js';

const here = dirname(fileURLToPath(import.meta.url));
const { vectors } = JSON.parse(readFileSync(join(here, '../../Packages/CameraBridgeKit/Tests/MediaCoreTests/Fixtures/picture-correction-vectors.json'), 'utf8'));
const BACKYARD = { straighten: 0.4, level: 0.15 };
const OFF = { straighten: 0, level: 0 };

// MARK: The formula

test('every shared vector matches', () => {
  assert.equal(vectors.length, 676);
  for (const v of vectors) {
    const got = sourceFraction(v, v.across, v.down);
    assert.ok(Math.abs(got - v.source) < 1e-9, `(${v.straighten}, ${v.level}) at (${v.across}, ${v.down}): ${got}, Swift says ${v.source}`);
  }
});

test('off is off', () => {
  assert.equal(isOn(undefined), false);
  assert.equal(isOn(null), false);
  assert.equal(isOn({ straighten: 0, level: 0 }), false);
  assert.equal(isOn({ straighten: 0.01, level: 0 }), true);
  assert.equal(isOn({ straighten: 0, level: -0.01 }), true);
  assert.equal(horizon(undefined, 0.3), 0.5);
  assert.equal(landing(undefined), 0.5);
  assert.equal(sourceFraction(undefined, 0.3, 0.42), 0.42);
});

test('the edges are exact and the horizon lands on the landing row', () => {
  for (const across of [0, 0.25, 0.5, 1]) {
    assert.equal(sourceFraction(BACKYARD, across, 0), 0);
    assert.equal(sourceFraction(BACKYARD, across, -0.1), 0);
    assert.equal(sourceFraction(BACKYARD, across, 1), 1);
    assert.equal(sourceFraction(BACKYARD, across, 1.2), 1);
    assert.ok(Math.abs(sourceFraction(BACKYARD, across, landing(BACKYARD)) - horizon(BACKYARD, across)) < 1e-12);
  }
  // Here the lower piece's arithmetic alone lands one step short of 1 (0.9999999999999999): the bottom row is still the bottom row.
  assert.equal(sourceFraction({ straighten: -0.59, level: -0.25 }, 1, 1), 1);
  assert.ok(Math.abs(landing(BACKYARD) - (0.5 + 0.4 * 2 / 3)) < 1e-15);
  assert.ok(Math.abs(horizon(BACKYARD, 0.5) - 0.9) < 1e-15, 'the middle sags by Straighten');
  assert.ok(Math.abs(horizon(BACKYARD, 1) - 0.65) < 1e-15, 'the right edge is lower by Level');
});

test('largestStretch matches Swift', () => {
  assert.ok(Math.abs(largestStretch(BACKYARD) - 2.71496) < 1e-5);
  assert.ok(Math.abs(largestStretch({ straighten: 0.1, level: 0 }) - 1.13157) < 1e-5);
  assert.ok(Math.abs(largestStretch(BACKYARD) - 2.714958691380824) < 1e-12);
  assert.ok(Math.abs(largestStretch({ straighten: 0.1, level: 0 }) - 1.1315687104968346) < 1e-12);
  assert.equal(largestStretch(OFF), 1);
  assert.equal(largestStretch(undefined), 1);
});

test('the shader snippet declares the uniform and the function another fragment shader includes', () => {
  assert.match(GLSL_STRAIGHTEN, /uniform vec2 straighten;/);
  assert.match(GLSL_STRAIGHTEN, /float sourceDown\(float across, float down\)/);
  assert.doesNotMatch(GLSL_STRAIGHTEN, /#version|precision|void main/, 'GLSL ES 1.0, and the shader that includes it sets the precision and has the main');
  // The same steps as sourceFraction, in the same order: the edges first, then h, T and the two pieces.
  for (const step of ['down <= 0.0', 'down >= 1.0', '2.0 * across - 1.0', 'clamp(0.5 + straighten.x * (1.0 - u * u) + straighten.y * u, 0.03, 0.97)',
    'clamp(0.5 + 2.0 / 3.0 * straighten.x, 0.03, 0.97)', 'down * h / t', 'h + (down - t) * (1.0 - h) / (1.0 - t)', 'clamp(fs, 0.0, 1.0)']) {
    assert.ok(GLSL_STRAIGHTEN.includes(step), `the snippet has ${step}`);
  }
});

// MARK: The 2D strip plan

test('stripPlanCoversEveryColumnOnce', () => {
  const plan = stripPlan(BACKYARD, 640, 284);
  assert.equal(plan.length, 640);
  const top = landing(BACKYARD) * 284;
  for (let strip = 0; strip < 320; strip += 1) {
    const [above, below] = [plan[2 * strip], plan[2 * strip + 1]];
    const dx = 2 * strip;
    const h = horizon(BACKYARD, (dx + 1) / 640) * 284;   // the strip's middle
    assert.deepEqual(above, { sx: dx, sy: 0, sw: 2, sh: h, dx, dy: 0, dw: 2, dh: top });
    assert.deepEqual(below, { sx: dx, sy: h, sw: 2, sh: 284 - h, dx, dy: top, dw: 2, dh: 284 - top });
  }
  for (const r of plan) {
    assert.ok(r.sx >= 0 && r.sy >= 0 && r.sw > 0 && r.sh > 0, 'a source rectangle with a size');
    assert.ok(r.sx + r.sw <= 640 && r.sy + r.sh <= 284 + 1e-9, 'every source rectangle stays inside the picture');
  }
  // Each piece is the formula: a row's centre in the strip's middle column takes its colour from where sourceFraction says.
  for (const r of plan.slice(300, 304)) {
    for (const y of [r.dy + 0.25 * r.dh, r.dy + 0.75 * r.dh]) {
      const sampled = r.sy + (y - r.dy) * (r.sh / r.dh);
      assert.ok(Math.abs(sampled / 284 - sourceFraction(BACKYARD, (r.dx + 1) / 640, y / 284)) < 1e-12);
    }
  }
  // A width the step does not divide: the last strip is the one column left.
  const odd = stripPlan({ straighten: -0.2, level: 0.3 }, 640, 360, 3);
  const columns = [];
  for (const r of odd.filter((_, index) => index % 2 === 0)) for (let x = r.dx; x < r.dx + r.dw; x += 1) columns.push(x);
  assert.deepEqual(columns, Array.from({ length: 640 }, (_, x) => x));
  assert.equal(odd.at(-1).dx, 639);
  assert.equal(odd.at(-1).dw, 1);
  assert.ok(Math.abs(odd.at(-1).sh - (360 - horizon({ straighten: -0.2, level: 0.3 }, 639.5 / 640) * 360)) < 1e-9, 'its horizon in its own middle');
});

test('stripPlan of off is one rectangle', () => {
  assert.deepEqual(stripPlan(OFF, 640, 284), [{ sx: 0, sy: 0, sw: 640, sh: 284, dx: 0, dy: 0, dw: 640, dh: 284 }]);
  assert.deepEqual(stripPlan(undefined, 320, 180, 4), [{ sx: 0, sy: 0, sw: 320, sh: 180, dx: 0, dy: 0, dw: 320, dh: 180 }]);
});

// MARK: The view

/** The drawImage calls that draw `source` (its intrinsic size `width` × `height`) through the strip plan of a `cw` × `ch` canvas. */
function planCalls(source, c, cw, ch, width = cw, height = ch) {
  const kx = width / cw, ky = height / ch;
  return stripPlan(c, cw, ch).map((r) => [source, r.sx * kx, r.sy * ky, r.sw * kx, r.sh * ky, r.dx, r.dy, r.dw, r.dh]);
}

/**
 * A recording WebGL context: every call is kept in `calls`; shaders compile, programs link; its largest texture is `maxTextureSize`;
 * loseContext() fires `webglcontextlost`.
 */
function fakeGL(canvas, maxTextureSize) {
  const calls = [];
  let lost = false;
  const known = {
    calls,
    getShaderParameter: () => true,
    getProgramParameter: () => true,
    getAttribLocation: () => 0,
    getUniformLocation: (program, name) => ({ name }),
    getParameter: (name) => (name === 'MAX_TEXTURE_SIZE' ? maxTextureSize : null),
    isContextLost: () => lost,
    getExtension: (name) => (name === 'WEBGL_lose_context'
      ? { loseContext: () => { lost = true; canvas.dispatchEvent({ type: 'webglcontextlost', preventDefault() {} }); } }
      : null),
  };
  return new Proxy(known, {
    get(target, key) {
      if (key in target) return target[key];
      if (typeof key !== 'string') return undefined;
      if (/^[A-Z0-9_]+$/.test(key)) return key;              // the constants
      return (...args) => { calls.push([key, ...args]); return { made: key }; };
    },
  });
}

function fake2D(canvas) {
  return { canvas, draws: [], drawImage(...args) { this.draws.push(args); } };
}

/**
 * A fake browser whose canvases have a WebGL context (`webgl`: a recording stand-in) or refuse it, and a recording 2D context. A canvas
 * keeps the kind of context it was first given, as a browser's does.
 */
function browser({ webgl = false, maxTextureSize = 4096, ratio = 1, fit = { objectFit: 'contain', objectPosition: '50% 50%' } } = {}) {
  const fake = installFakeBrowser();
  const canvases = [];
  const create = fake.document.createElement;
  fake.document.createElement = (tag) => {
    const el = create(tag);
    if (tag !== 'canvas') return el;
    Object.assign(el, { width: 300, height: 150 });
    let kind = null, context = null;
    el.getContext = (wanted) => {
      if (kind) return kind === wanted ? context : null;
      if (wanted === 'webgl' && webgl) context = fakeGL(el, maxTextureSize);
      else if (wanted === '2d') context = fake2D(el);
      else return null;
      kind = wanted;
      return context;
    };
    canvases.push(el);
    return el;
  };
  window.devicePixelRatio = ratio;
  globalThis.getComputedStyle = () => fit;
  return { canvases, restore() { delete globalThis.getComputedStyle; delete globalThis.MutationObserver; fake.restore(); } };
}

/** A playing <video> (one in a tile's box, unless `inBox` is false) whose frame callbacks run when the test calls `frame()`. */
function fakeVideo({ width = 640, height = 284, shownWidth = width, shownHeight = height, inBox = true } = {}) {
  const video = document.createElement('video');
  Object.assign(video, { className: 'nvr-live', videoWidth: width, videoHeight: height, readyState: 4, clientWidth: shownWidth, clientHeight: shownHeight });
  const pending = new Map();
  let next = 1;
  video.pending = pending;
  video.requestVideoFrameCallback = (fn) => { pending.set(next, fn); return next++; };
  video.cancelVideoFrameCallback = (id) => { pending.delete(id); };
  video.frame = () => { const due = [...pending.values()]; pending.clear(); for (const fn of due) fn(0, {}); };
  if (inBox) document.createElement('div').append(document.createElement('img'), video, document.createElement('span'));
  return video;
}

const siblingAfter = (el) => el.parentNode.childNodes[el.parentNode.childNodes.indexOf(el) + 1];

test('aViewFallsBackTo2DWhenWebGLIsRefused', () => {
  const fake = browser({ webgl: false });
  try {
    const video = fakeVideo();
    const view = createStraightenedView({ source: video, correction: BACKYARD });
    const canvas = view.canvas;
    assert.equal(fake.canvases.at(-1), canvas);
    assert.equal(siblingAfter(video), canvas, 'the canvas is right after the video');
    assert.equal(canvas.className, 'nvr-live straightened', 'the source’s classes, and straightened');
    assert.ok(video.classList.contains('straighten-source'));
    assert.equal(canvas.getContext('webgl'), null, 'a 2D canvas');
    assert.deepEqual([canvas.width, canvas.height], [640, 284]);
    const context = canvas.getContext('2d');
    assert.deepEqual(context.draws, planCalls(video, BACKYARD, 640, 284), 'drawn at once, through the strip plan');
    video.frame();
    assert.equal(context.draws.length, 2 * stripPlan(BACKYARD, 640, 284).length, 'and again at the next frame');
    assert.equal(video.pending.size, 1, 'waiting for the frame after');

    view.set(OFF);
    assert.equal(canvas.parentNode, null, 'off: no canvas');
    assert.equal(view.canvas, null);
    assert.equal(video.classList.contains('straighten-source'), false);
    assert.equal(video.pending.size, 0, 'off: nothing waits for a frame');

    view.set({ straighten: -0.2, level: 0 });
    assert.equal(siblingAfter(video), view.canvas, 'on again: a canvas again');
    assert.deepEqual(view.canvas.getContext('2d').draws, planCalls(video, { straighten: -0.2, level: 0 }, 640, 284));
    view.destroy();
    assert.equal(siblingAfter(video).localName, 'span', 'destroyed: the canvas is gone');
    assert.equal(video.classList.contains('straighten-source'), false);
    assert.equal(video.pending.size, 0);
    view.set(BACKYARD);
    assert.equal(view.canvas, null, 'a destroyed view stays off');
  } finally {
    fake.restore();
  }
});

test('a view draws with WebGL, and through the strip plan once its context is lost', () => {
  const fake = browser({ webgl: true });
  try {
    const video = fakeVideo();
    const view = createStraightenedView({ source: video, correction: BACKYARD });
    const glCanvas = view.canvas;
    const gl = glCanvas.getContext('webgl');
    assert.ok(gl, 'a WebGL canvas');
    const fragment = gl.calls.filter(([name]) => name === 'shaderSource').map(([, , text]) => text).find((text) => text.includes('gl_FragColor'));
    assert.ok(fragment.includes(GLSL_STRAIGHTEN), 'the fragment shader includes the formula');
    assert.match(fragment, /texture2D\([^;]*sourceDown\(/, 'and samples the picture where it says');
    const drawn = () => gl.calls.filter(([name]) => name === 'drawArrays').length;
    assert.equal(drawn(), 1, 'drawn at once');
    assert.ok(gl.calls.some(([name, , , , , , source]) => name === 'texImage2D' && source === video), 'from the video');
    assert.ok(gl.calls.some(([name, at, a, b]) => name === 'uniform2f' && at.name === 'straighten' && a === 0.4 && b === 0.15));
    assert.deepEqual([glCanvas.width, glCanvas.height], [640, 284]);
    video.frame();
    assert.equal(drawn(), 2, 'and at the next frame');

    gl.getExtension('WEBGL_lose_context').loseContext();   // as the browser does when a page has too many contexts
    const canvas = view.canvas;
    assert.notEqual(canvas, glCanvas);
    assert.equal(glCanvas.parentNode, null);
    assert.equal(siblingAfter(video), canvas, 'a 2D canvas takes its place');
    assert.equal(canvas.className, 'nvr-live straightened');
    assert.deepEqual(canvas.getContext('2d').draws, planCalls(video, BACKYARD, 640, 284));
    video.frame();
    assert.equal(drawn(), 2, 'the lost context draws no more');
    assert.equal(canvas.getContext('2d').draws.length, 2 * stripPlan(BACKYARD, 640, 284).length);
    view.destroy();

    const other = createStraightenedView({ source: video, correction: BACKYARD });
    const count = fake.canvases.length;
    const otherGL = other.canvas.getContext('webgl');
    other.destroy();
    assert.equal(otherGL.isContextLost(), true, 'destroyed: its context is given back at once');
    assert.equal(fake.canvases.length, count, 'and nothing falls back to 2D');
    assert.equal(siblingAfter(video).localName, 'span');
  } finally {
    fake.restore();
  }
});

test('the canvas is the picture’s size capped at its displayed size × devicePixelRatio, fitted as the source is', () => {
  const fake = browser({ ratio: 2, fit: { objectFit: 'cover', objectPosition: '0% 30%' } });
  try {
    const video = fakeVideo({ width: 1280, height: 568, shownWidth: 320, shownHeight: 142 });
    const view = createStraightenedView({ source: video, correction: BACKYARD });
    assert.deepEqual([view.canvas.width, view.canvas.height], [640, 284], '320 × 142 shown, at 2 device pixels a pixel');
    assert.deepEqual(view.canvas.getContext('2d').draws, planCalls(video, BACKYARD, 640, 284, 1280, 568), 'the source rectangles in the video’s pixels');
    assert.equal(view.canvas.style.objectFit, 'cover');
    assert.equal(view.canvas.style.objectPosition, '0% 30%');
    view.destroy();

    const small = fakeVideo({ width: 640, height: 284, shownWidth: 1200, shownHeight: 533 });
    const sharp = createStraightenedView({ source: small, correction: BACKYARD });
    assert.deepEqual([sharp.canvas.width, sharp.canvas.height], [640, 284], 'never more pixels than the picture has');
    sharp.destroy();
  } finally {
    fake.restore();
  }
});

test('an image is drawn when it loads and when the correction changes; off it costs nothing', () => {
  const fake = browser();
  try {
    const box = document.createElement('div');
    const img = document.createElement('img');
    Object.assign(img, { naturalWidth: 640, naturalHeight: 284, complete: true, clientWidth: 640, clientHeight: 284 });
    box.append(img);
    const view = createStraightenedView({ source: img, correction: BACKYARD });
    const context = view.canvas.getContext('2d');
    assert.deepEqual(context.draws, planCalls(img, BACKYARD, 640, 284));
    context.draws.length = 0;
    img.dispatchEvent({ type: 'load' });
    assert.deepEqual(context.draws, planCalls(img, BACKYARD, 640, 284), 'a new picture: drawn');
    context.draws.length = 0;
    const next = { straighten: 0.2, level: -0.1 };
    view.set(next);
    assert.deepEqual(context.draws, planCalls(img, next, 640, 284), 'a new correction: drawn at once');
    context.draws.length = 0;
    view.set(OFF);
    assert.equal(box.childNodes.length, 1, 'only the image');
    assert.equal(img.className, '');
    assert.equal(img.listeners.get('load')?.size ?? 0, 0, 'nothing listens');
    img.dispatchEvent({ type: 'load' });
    assert.equal(context.draws.length, 0);

    const waiting = document.createElement('img');
    box.append(waiting);
    const unloaded = createStraightenedView({ source: waiting, correction: BACKYARD });
    assert.equal(unloaded.canvas.getContext('2d').draws.length, 0, 'no picture yet: nothing drawn');
    Object.assign(waiting, { naturalWidth: 640, naturalHeight: 284, complete: true, clientWidth: 640, clientHeight: 284 });
    waiting.dispatchEvent({ type: 'load' });
    assert.equal(unloaded.canvas.getContext('2d').draws.length, stripPlan(BACKYARD, 640, 284).length);
    unloaded.destroy();
  } finally {
    fake.restore();
  }
});

test('the canvas follows the source’s classes and hidden', () => {
  const fake = browser();
  const observers = [];
  globalThis.MutationObserver = class {
    constructor(callback) { this.callback = callback; this.target = null; observers.push(this); }
    observe(target, options) { this.target = target; this.options = options; }
    disconnect() { this.target = null; }
  };
  try {
    const video = fakeVideo();
    video.hidden = true;
    const view = createStraightenedView({ source: video, correction: BACKYARD });
    assert.equal(view.canvas.hidden, true, 'a hidden source: a hidden canvas');
    const watching = observers.find((observer) => observer.target === video);
    assert.deepEqual(watching.options.attributeFilter.sort(), ['class', 'hidden']);
    video.hidden = false;
    video.classList.add('playing');
    watching.callback([]);
    assert.equal(view.canvas.hidden, false);
    assert.equal(view.canvas.className, 'nvr-live playing straightened');
    view.set(OFF);
    assert.equal(watching.target, null, 'off: nothing watches the source');
  } finally {
    fake.restore();
  }
});

test('a source with no parent stays as it is: no class, no canvas, nothing drawn', () => {
  const fake = browser({ webgl: true });
  try {
    const video = fakeVideo({ inBox: false });
    const view = createStraightenedView({ source: video, correction: BACKYARD });
    assert.equal(view.canvas, null);
    assert.equal(video.className, 'nvr-live', 'the camera’s own picture stays visible');
    assert.equal(fake.canvases.length, 0, 'no canvas made, no WebGL context taken');
    assert.equal(video.pending.size, 0, 'nothing waits for a frame');
    document.createElement('div').append(video);
    view.set(BACKYARD);
    assert.equal(siblingAfter(video), view.canvas, 'once it has a parent, set() puts the canvas in place');
    assert.ok(video.classList.contains('straighten-source'));

    // Taken out of the page (without destroy) before its WebGL context is lost: no 2D canvas has anywhere to go, so the source is left as it is.
    video.remove();
    view.canvas.getContext('webgl').getExtension('WEBGL_lose_context').loseContext();
    assert.equal(view.canvas, null);
    assert.equal(video.className, 'nvr-live');
    assert.equal(video.pending.size, 0);
  } finally {
    fake.restore();
  }
});

test('a picture larger than WebGL’s largest texture is drawn through the strip plan', () => {
  const fake = browser({ webgl: true, maxTextureSize: 64 });
  try {
    const video = fakeVideo({ width: 100, height: 50 });
    const view = createStraightenedView({ source: video, correction: BACKYARD });
    const gl = fake.canvases[0].getContext('webgl');
    assert.ok(gl, 'WebGL was tried first');
    assert.equal(gl.calls.some(([name]) => name === 'texImage2D' || name === 'drawArrays'), false, 'it never drew (it would have drawn black)');
    assert.equal(gl.isContextLost(), true, 'its context is given back');
    assert.equal(fake.canvases[0].parentNode, null);
    assert.equal(view.canvas.getContext('webgl'), null, 'a 2D view');
    assert.equal(siblingAfter(video), view.canvas);
    assert.deepEqual(view.canvas.getContext('2d').draws, planCalls(video, BACKYARD, 100, 50));
    view.destroy();

    const fits = fakeVideo({ width: 64, height: 32 });
    const glView = createStraightenedView({ source: fits, correction: BACKYARD });
    assert.ok(glView.canvas.getContext('webgl'), 'a picture that fits stays on WebGL');
    glView.destroy();
  } finally {
    fake.restore();
  }
});

test('the 2D path plans once for the same correction and canvas size', () => {
  const fake = browser();
  try {
    const plans = [];
    const planner = (...args) => { plans.push(args.slice(1)); return stripPlan(...args); };
    const video = fakeVideo();
    const view = createStraightenedView({ source: video, correction: BACKYARD, planner });
    const context = view.canvas.getContext('2d');
    video.frame();
    video.frame();
    assert.deepEqual(plans, [[640, 284]], 'three drawings, one plan');
    assert.equal(context.draws.length, 3 * stripPlan(BACKYARD, 640, 284).length);
    assert.deepEqual(context.draws.slice(-640), planCalls(video, BACKYARD, 640, 284), 'the kept plan draws the same rectangles');
    view.set({ ...BACKYARD });
    assert.equal(plans.length, 1, 'the same values: still the same plan');
    view.set({ straighten: 0.3, level: 0.15 });
    video.frame();
    assert.equal(plans.length, 2, 'a new correction: a new plan');
    assert.deepEqual(context.draws.slice(-640), planCalls(video, { straighten: 0.3, level: 0.15 }, 640, 284));
    Object.assign(video, { clientWidth: 320, clientHeight: 142 });
    video.frame();
    video.frame();
    assert.deepEqual(plans.at(-1), [320, 142], 'a new canvas size: a new plan, once');
    assert.equal(plans.length, 3);
    view.destroy();
  } finally {
    fake.restore();
  }
});

test('a canvas shows nothing until it has drawn a picture: before that an opaque canvas would be black over what lies under it', () => {
  for (const webgl of [false, true]) {
    const fake = browser({ webgl });
    try {
      const kind = webgl ? 'WebGL' : '2D';
      const video = fakeVideo();
      Object.assign(video, { videoWidth: 0, videoHeight: 0, readyState: 0 });      // no picture yet
      const view = createStraightenedView({ source: video, correction: BACKYARD });
      assert.equal(view.canvas.style.opacity, '0', `${kind}: see-through before its first picture (the snapshot under it shows)`);
      Object.assign(video, { videoWidth: 640, videoHeight: 284, readyState: 4 });
      if (!webgl) {
        const context = view.canvas.getContext('2d');
        const drawImage = context.drawImage;
        context.drawImage = () => { throw new DOMException('The image argument is not ready.', 'InvalidStateError'); };
        video.frame();
        assert.equal(view.canvas.style.opacity, '0', '2D: a picture the browser could not draw yet shows nothing');
        context.drawImage = drawImage;
      }
      video.frame();
      assert.equal(view.canvas.style.opacity, '', `${kind}: shown once it has drawn`);
      view.set(OFF);
      view.set(BACKYARD);
      assert.equal(view.canvas.style.opacity, '', 'a new canvas over a video that has a picture is drawn, and shown, at once');
      view.destroy();
    } finally {
      fake.restore();
    }
  }
});

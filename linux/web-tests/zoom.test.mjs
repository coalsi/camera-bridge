// The digital zoom of one camera (js/live/zoom.js), the one zoom of the page (the Monitor's one-camera wall and Sky Watcher's clip player):
// its gestures (a box, the wheel, moving the zoomed picture inside the picture's edges, a pinch, a double-click, Esc and 0, zooming to a point)
// and the marks a page draws over it; and on a straightened picture, the zoomed area and the overview are parts of the picture as the camera's
// page straightens it, drawn from the camera's own video through the formula (js/live/straighten.js), with WebGL or in 2D.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { fakeGL, fragmentSource, givePicture, planCalls, recordingCanvases, drawnFrom, uniform2 } from './support/fake-picture.mjs';
import { GLSL_STRAIGHTEN, sourceFraction } from '../web/js/live/straighten.js';
import { createZoom } from '../web/js/live/zoom.js';

const BACKYARD = { straighten: 0.4, level: 0.15 };
const OFF = { straighten: 0, level: 0 };

/**
 * A zoom over a box (640 × 284 unless `box` says otherwise) showing a video of `picture` (640 × 284 unless it says otherwise: the whole picture
 * then fills the box), the zoom's canvases given WebGL when `webgl` (true, or the options of `fakeGL`: its largest texture, shaders that fail),
 * and the correction `correction.now` as the page's store would have it; `state.source`, when set, is the picture on screen instead of the
 * video (a still). `options()` gives what else goes to createZoom (onView, marks, onActive), made once the fake browser is there.
 */
function zoomRig({ webgl = false, correction = BACKYARD, picture = {}, box = { clientWidth: 640, clientHeight: 284 }, options = () => ({}) } = {}) {
  const browser = installFakeBrowser();
  const gls = [];       // every WebGL context the canvases were given
  const { canvases } = recordingCanvases(browser.document, {
    webgl: webgl ? (canvas) => { const gl = fakeGL(canvas, webgl === true ? {} : webgl); gls.push(gl); return gl; } : null,
  });
  globalThis.ResizeObserver = class { observe() {} disconnect() {} };
  const host = Object.assign(document.createElement('div'), box);
  const video = givePicture(document.createElement('video'), picture);
  host.append(video);
  const state = { now: correction, source: null };
  const extra = options();
  const zoom = createZoom({ host, getVideo: () => state.source ?? video, getCorrection: () => state.now, ...extra });
  const find = (match) => {
    const out = [];
    const walk = (node) => { for (const child of node.childNodes) { if (child.tagName && match(child)) out.push(child); walk(child); } };
    walk(zoom.el);
    return out;
  };
  const [canvas] = find((el) => el.localName === 'canvas' && el.className === 'zoom-canvas');
  const [map] = find((el) => el.localName === 'canvas' && el.className === 'zoom-map');
  const [surface] = find((el) => el.className === 'zoom-surface');
  const zoomIn = () => find((el) => el.getAttribute('aria-label') === 'Zoom in')[0].dispatchEvent({ type: 'click', stopPropagation() {} });
  return {
    zoom, host, video, canvas, map, surface, canvases, gls, state, zoomIn, find, marks: extra.marks ?? null,
    close() { zoom.destroy(); delete globalThis.ResizeObserver; browser.restore(); },
  };
}

/** An event of `type` on `el` at the host point (x, y) (the host is at the page's top left), as the browser gives it; it keeps what was done to it. */
function fire(el, type, x, y, extra = {}) {
  const event = {
    type, pointerId: 1, pointerType: 'mouse', button: 0, clientX: x, clientY: y, target: el, defaultPrevented: false, stopped: false,
    preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this.stopped = true; }, ...extra,
  };
  el.dispatchEvent(event);
  return event;
}

/** A drag of the mouse on `el` from `from` to `to` (host points), through the middle; -> the release. */
function dragOn(el, from, to, extra = {}) {
  fire(el, 'pointerdown', ...from, extra);
  fire(el, 'pointermove', (from[0] + to[0]) / 2, (from[1] + to[1]) / 2, extra);
  fire(el, 'pointermove', ...to, extra);
  return fire(el, 'pointerup', ...to, extra);
}

const near = (got, want, what = '') => assert.ok(Math.abs(got - want) < 1e-9, `${what} ${got} ≈ ${want}`);
function nearView(got, want, what = 'the view') {
  for (const side of ['x', 'y', 'w', 'h']) near(got[side], want[side], `${what}: ${side}`);
}
/** The point of the picture (0..1) under the host point (x, y) with `view` on a host the picture's own shape. */
const under = (view, x, y, width = 640, height = 284) => ({ x: view.x + (x / width) * view.w, y: view.y + (y / height) * view.h });

// MARK: The gestures

test('a box dragged over the whole picture zooms to it: all of the box, in the host’s shape; a short drag is a click', () => {
  const views = [];
  const active = [];
  const rig = zoomRig({ correction: OFF, options: () => ({ onView: (view) => views.push(view), onActive: (on) => active.push(on) }) });
  try {
    fire(rig.surface, 'pointerdown', 160, 71);
    fire(rig.surface, 'pointermove', 164, 74);
    const click = fire(rig.surface, 'pointerup', 164, 74);
    assert.equal(rig.zoom.zoomed(), false, 'under 8 px: a click, not a box');
    assert.equal(click.stopped, false, 'and the page’s own click goes on (the Monitor: back to all cameras)');

    // A box a quarter of the picture across and down, its top left a quarter in: the view is that box.
    const release = dragOn(rig.surface, [160, 71], [320, 142]);
    nearView(rig.zoom.view(), { x: 0.25, y: 0.25, w: 0.25, h: 0.25 });
    near(rig.zoom.level(), 4, 'four times the whole picture');
    assert.equal(release.stopped, true, 'a drag is not a click');
    assert.equal(rig.zoom.el.dataset.zoomed, 'true');
    assert.deepEqual(active, [true]);
    nearView(views.at(-1), rig.zoom.view(), 'the page is told');
    assert.equal(rig.find((el) => el.className === 'zoom-level')[0].textContent, '4.0×', 'the level, at the top left');
    assert.equal(rig.find((el) => el.className === 'zoom-controls')[0].hidden, false, 'with Reset');

    // A tall narrow box, dragged from its bottom right: its height decides, so all of it is in the zoomed area.
    rig.zoom.reset();
    dragOn(rig.surface, [140, 150], [100, 50]);
    const view = rig.zoom.view();
    near(view.h, 100 / 284, 'as tall as the box');
    near(view.w, view.h, 'in the host’s shape (here the picture’s)');
    near(view.y, 50 / 284, 'the box’s top');
    near(view.x + view.w / 2, 120 / 640, 'around the box’s middle');
  } finally {
    rig.close();
  }
});

test('the wheel zooms in and out around the pointer: the point under it stays where it is, and the page never scrolls', () => {
  const rig = zoomRig({ correction: OFF });
  try {
    const at = [480, 71];
    const before = under(rig.zoom.view(), ...at);
    const wheel = fire(rig.surface, 'wheel', ...at, { deltaY: -100, deltaMode: 0 });
    assert.equal(wheel.defaultPrevented, true, 'the page does not scroll');
    const once = rig.zoom.view();
    near(1 / once.w, 1.0018 ** 100, 'a notch of 100 px: about 1.2 times');
    const after = under(once, ...at);
    near(after.x, before.x, 'the point under the pointer stays across');
    near(after.y, before.y, 'and down');

    fire(rig.surface, 'wheel', ...at, { deltaY: -3, deltaMode: 1 });          // lines: a mouse with notches
    const twice = rig.zoom.view();
    assert.ok(twice.w < once.w, 'in further');
    near(under(twice, ...at).x, before.x);
    near(under(twice, ...at).y, before.y);

    fire(rig.surface, 'wheel', 100, 200, { deltaY: -10, ctrlKey: true });    // a trackpad's pinch: the wheel with ctrl, four times as fast
    const pinched = rig.zoom.view();
    near(twice.w / pinched.w, 1.0018 ** 40);
    const still = under(twice, 100, 200);
    near(under(pinched, 100, 200).x, still.x);
    near(under(pinched, 100, 200).y, still.y);

    // Out past the whole picture is the whole picture, and the page still does not scroll.
    const out = fire(rig.surface, 'wheel', ...at, { deltaY: 5000 });
    assert.equal(out.defaultPrevented, true);
    assert.deepEqual(rig.zoom.view(), { x: 0, y: 0, w: 1, h: 1 });
    assert.equal(rig.zoom.zoomed(), false);
    assert.equal(rig.zoom.level(), 1);
  } finally {
    rig.close();
  }
});

test('zoomed, a drag moves the picture with the pointer, never past its edges; Shift and a drag draw a box to zoom further', () => {
  const rig = zoomRig({ correction: OFF });
  try {
    assert.equal(rig.zoom.zoomTo(0.5, 0.5, 4), true);
    nearView(rig.zoom.view(), { x: 0.375, y: 0.375, w: 0.25, h: 0.25 });
    fire(rig.surface, 'pointerdown', 320, 142);
    fire(rig.surface, 'pointermove', 400, 142);            // 80 px right: the picture goes with the pointer
    near(rig.zoom.view().x, 0.375 - (80 / 640) * 0.25, 'an eighth of the host is an eighth of the view');
    assert.equal(rig.zoom.el.dataset.panning, 'true', 'a closed hand while it moves');
    fire(rig.surface, 'pointermove', 400, 182);            // and 40 px down
    near(rig.zoom.view().y, 0.375 - (40 / 284) * 0.25);
    fire(rig.surface, 'pointermove', 5000, 5000);          // dragged far down and right: the picture's top left corner, no further
    nearView(rig.zoom.view(), { x: 0, y: 0, w: 0.25, h: 0.25 });
    fire(rig.surface, 'pointermove', -5000, -5000);        // far up and left: its bottom right corner
    nearView(rig.zoom.view(), { x: 0.75, y: 0.75, w: 0.25, h: 0.25 });
    const release = fire(rig.surface, 'pointerup', -5000, -5000);
    assert.equal(release.stopped, true, 'not a click');
    assert.equal(rig.zoom.el.dataset.panning, 'false');
    near(rig.zoom.level(), 4, 'moving never zooms');

    // A click on the zoomed picture moves nothing, and is the zoom's (the Monitor stays on this camera).
    fire(rig.surface, 'pointerdown', 300, 100);
    fire(rig.surface, 'pointermove', 303, 102);
    assert.equal(fire(rig.surface, 'pointerup', 303, 102).stopped, true);
    assert.equal(fire(rig.surface, 'click', 303, 102).stopped, true);
    nearView(rig.zoom.view(), { x: 0.75, y: 0.75, w: 0.25, h: 0.25 });

    // Shift: a box, in the zoomed area's own coordinates (the left half of the host is an eighth of the picture).
    dragOn(rig.surface, [0, 0], [320, 142], { shiftKey: true });
    nearView(rig.zoom.view(), { x: 0.75, y: 0.75, w: 0.125, h: 0.125 });
  } finally {
    rig.close();
  }
});

test('a pinch zooms around the fingers and moves with them; the finger left on the picture moves it on', () => {
  const rig = zoomRig({ correction: OFF });
  try {
    const touch = (type, id, x, y) => fire(rig.surface, type, x, y, { pointerId: id, pointerType: 'touch' });
    touch('pointerdown', 1, 200, 142);
    touch('pointerdown', 2, 440, 142);                    // the midpoint is the picture's middle
    touch('pointermove', 2, 560, 142);                    // 240 px apart, then 360: half as large again; the midpoint goes 60 px right
    const view = rig.zoom.view();
    near(view.w, 1 / 1.5, 'the spread zooms');
    near(under(view, 380, 142).x, 0.5, 'the point that was between the fingers is between them still');
    near(under(view, 380, 142).y, 0.5);
    assert.equal(rig.zoom.el.dataset.panning, 'false', 'a pinch is not a drag');
    touch('pointerup', 2, 560, 142);
    touch('pointermove', 1, 260, 142);                    // the finger left: 60 px right
    near(rig.zoom.view().x, view.x - (60 / 640) * view.w, 'moves the picture');
    touch('pointerup', 1, 260, 142);
  } finally {
    rig.close();
  }
});

test('Safari’s trackpad pinch zooms the picture around the pointer, never the page', () => {
  const rig = zoomRig({ correction: OFF });
  try {
    const before = under(rig.zoom.view(), 160, 71);
    const start = fire(rig.surface, 'gesturestart', 160, 71, { scale: 1 });
    const change = fire(rig.surface, 'gesturechange', 160, 71, { scale: 2 });
    assert.equal(start.defaultPrevented, true, 'the page does not zoom');
    assert.equal(change.defaultPrevented, true);
    near(rig.zoom.view().w, 0.5, 'twice as large');
    near(under(rig.zoom.view(), 160, 71).x, before.x, 'around the pointer');
    near(under(rig.zoom.view(), 160, 71).y, before.y);
    fire(rig.surface, 'gesturechange', 160, 71, { scale: 3 });         // its scale is the whole gesture's: half as large again
    near(rig.zoom.view().w, 1 / 3);
    assert.equal(fire(rig.surface, 'gestureend', 160, 71, { scale: 3 }).defaultPrevented, true);
  } finally {
    rig.close();
  }
});

test('double-click, Esc and 0 show the whole picture again; whole, or with ctrl, cmd or alt, the keys are the page’s', () => {
  const active = [];
  const rig = zoomRig({ correction: OFF, options: () => ({ onActive: (on) => active.push(on) }) });
  const key = (init) => ({ key: '0', ctrlKey: false, metaKey: false, altKey: false, ...init });
  try {
    rig.zoom.zoomTo(0.3, 0.6, 3);
    const dbl = fire(rig.surface, 'dblclick', 10, 10);
    assert.equal(rig.zoom.zoomed(), false, 'a double-click');
    assert.equal(dbl.stopped, true);
    assert.deepEqual(rig.zoom.view(), { x: 0, y: 0, w: 1, h: 1 });

    for (const name of ['0', 'Escape']) {
      rig.zoom.zoomTo(0.3, 0.6, 3);
      assert.equal(rig.zoom.key(key({ key: name })), true, `${name} is the zoom’s while zoomed`);
      assert.equal(rig.zoom.zoomed(), false, name);
      assert.equal(rig.zoom.key(key({ key: name })), false, `whole, ${name} is the page’s (Esc then closes or leaves)`);
    }
    rig.zoom.zoomTo(0.3, 0.6, 3);
    for (const modifier of ['ctrlKey', 'metaKey', 'altKey']) assert.equal(rig.zoom.key(key({ [modifier]: true })), false, `not with ${modifier} (the browser’s own zoom)`);
    assert.equal(rig.zoom.key(key({ key: '1' })), false);
    assert.equal(rig.zoom.zoomed(), true);
    rig.find((el) => el.classList.contains('zoom-reset'))[0].dispatchEvent({ type: 'click', stopPropagation() {} });
    assert.equal(rig.zoom.zoomed(), false, 'and Reset');
    assert.deepEqual(active, [true, false, true, false, true, false, true, false]);
  } finally {
    rig.close();
  }
});

test('zoom to a point: the area around it at the level asked, kept inside the picture, whatever the host’s shape', () => {
  const rig = zoomRig({ correction: OFF });
  try {
    rig.zoom.zoomTo(0.5, 0.4, 4);
    nearView(rig.zoom.view(), { x: 0.375, y: 0.275, w: 0.25, h: 0.25 }, 'centred on the point');
    near(rig.zoom.level(), 4);
    rig.zoom.zoomTo(0.95, 0.02, 4);
    nearView(rig.zoom.view(), { x: 0.75, y: 0, w: 0.25, h: 0.25 }, 'near a corner: the corner, the point still in it');
    rig.zoom.zoomTo(0.5, 0.5, 40);
    near(rig.zoom.level(), 12, 'at most twelve times');
  } finally {
    rig.close();
  }
  // A host wider than the picture shows it whole by its height: four times is still four times as the controls read it.
  const wide = zoomRig({ correction: OFF, box: { clientWidth: 900, clientHeight: 284 } });
  try {
    wide.zoom.zoomTo(0.5, 0.5, 4);
    near(wide.zoom.level(), 4);
    near(wide.zoom.view().w * 640 / (wide.zoom.view().h * 284), 900 / 284, 'in the host’s shape');
  } finally {
    wide.close();
  }
  // Nothing to zoom yet: nothing happens.
  const empty = zoomRig({ correction: OFF, picture: { width: 0, height: 0 } });
  try {
    assert.equal(empty.zoom.zoomTo(0.5, 0.5, 4), false);
    fire(empty.surface, 'wheel', 100, 100, { deltaY: -100 });
    assert.equal(empty.zoom.zoomed(), false);
    assert.equal(empty.zoom.level(), 1);
  } finally {
    empty.close();
  }
});

test('a page’s marks lie over the zoomed picture and under the controls, and the page is told each new view', () => {
  const views = [];
  const rig = zoomRig({
    correction: OFF,
    options: () => ({ marks: Object.assign(document.createElement('svg'), { className: 'page-marks' }), onView: (view) => views.push(view) }),
  });
  try {
    const layer = rig.zoom.el.childNodes.map((node) => node.className);
    assert.deepEqual(layer, ['zoom-canvas', 'page-marks', 'zoom-surface', 'zoom-box', 'zoom-controls', 'zoom-hint'],
      'over the zoomed picture, under the gestures and the controls');
    assert.equal(rig.marks.parentNode, rig.zoom.el);
    rig.zoom.zoomTo(0.5, 0.5, 2);
    dragOn(rig.surface, [320, 142], [160, 142]);           // half the host to the left: a quarter of the picture
    rig.zoom.reset();
    assert.equal(views.length, 4, 'zoomed, moved twice, whole');
    nearView(views[0], { x: 0.25, y: 0.25, w: 0.5, h: 0.5 });
    nearView(views[1], { x: 0.3125, y: 0.25, w: 0.5, h: 0.5 });
    nearView(views[2], { x: 0.375, y: 0.25, w: 0.5, h: 0.5 });
    assert.deepEqual(views[3], { x: 0, y: 0, w: 1, h: 1 });
    views[3].x = 9;
    assert.equal(rig.zoom.view().x, 0, 'a copy: the page cannot move the zoom by mistake');
  } finally {
    rig.close();
  }
});

test('a still zooms as a video does, by its own size, and is not drawn again while nothing changes', async () => {
  const rig = zoomRig({ correction: OFF });
  try {
    const still = Object.assign(document.createElement('img'), { naturalWidth: 640, naturalHeight: 284, src: '/still.jpg' });
    rig.state.source = still;
    rig.zoom.zoomTo(0.5, 0.5, 2);
    const draws = drawnFrom(rig.canvas, still);
    assert.equal(draws.length, 1, 'drawn at once');
    assert.deepEqual(draws[0], ['picture', 160, 71, 320, 142, 0, 0, 640, 284], 'the middle quarter, filling the box');
    await new Promise((resolve) => setTimeout(resolve, 80));                 // a few display frames
    assert.equal(drawnFrom(rig.canvas, still).length, 1, 'a picture that does not move is not drawn again each frame');
    rig.zoomIn();
    assert.equal(drawnFrom(rig.canvas, still).length, 2, 'but at once when the view changes');
  } finally {
    rig.close();
  }
});

test('the zoomed picture shows a hand to move it, the whole picture a crosshair for a box', () => {
  const css = readFileSync(new URL('../web/monitor.css', import.meta.url), 'utf8');
  assert.match(css, /\.zoom-surface \{[^}]*cursor: crosshair;[^}]*touch-action: none;/);
  assert.match(css, /\.zoom-layer\[data-zoomed="true"\] \.zoom-surface \{ cursor: grab; \}/);
  assert.match(css, /\.zoom-layer\[data-panning="true"\] \.zoom-surface \{ cursor: grabbing; \}/);
});

test('zoom samples through the correction', () => {
  const rig = zoomRig({ webgl: true });
  try {
    const gl = rig.canvas.getContext('webgl');
    assert.ok(gl, 'the zoom draws with WebGL');
    const fragment = fragmentSource(gl);
    assert.ok(fragment.includes(GLSL_STRAIGHTEN), 'the fragment shader has the formula');
    assert.match(fragment, /#ifdef GL_FRAGMENT_PRECISION_HIGH\s+precision highp float;\s+#else\s+precision mediump float;\s+#endif/,
      'highp where the graphics have it: mediump cannot address every row of a tall picture');
    // Every sample, the sharpening's neighbours included, is a point of the straightened picture: one texture2D, through sourceDown.
    assert.equal(fragment.match(/texture2D\(/g).length, 1);
    assert.match(fragment, /texture2D\(tex, vec2\(at\.x, sourceDown\(at\.x, at\.y\)\)\)/);
    assert.equal(fragment.match(/pick\(/g).length, 6, 'the centre and its four neighbours, and the function itself');

    rig.zoomIn();
    assert.deepEqual(uniform2(gl, 'straighten').at(-1), [0.4, 0.15], 'the camera’s correction');
    const draws = gl.calls.filter(([name]) => name === 'drawArrays').length;
    assert.ok(draws > 0, 'drawn');
    assert.ok(gl.calls.some(([name, , , , , , source]) => name === 'texImage2D' && source === rig.video), 'from the camera’s own video');

    rig.state.now = { straighten: -0.2, level: 0.1 };      // saved on the camera's page meanwhile
    rig.zoomIn();
    assert.deepEqual(uniform2(gl, 'straighten').at(-1), [-0.2, 0.1], 'the next picture follows it');
    rig.state.now = OFF;
    rig.zoomIn();
    assert.deepEqual(uniform2(gl, 'straighten').at(-1), [0, 0], 'off is (0, 0): the formula is then the identity');
    rig.state.now = undefined;
    rig.zoomIn();
    assert.deepEqual(uniform2(gl, 'straighten').at(-1), [0, 0], 'and so is a camera with no correction');
  } finally {
    rig.close();
  }
});

/**
 * Checks the 2D path's pieces: each draws a part of the straightened picture's area `view` (normalized) of a 640 × 284 video into the whole
 * 640 × 284 canvas, the pieces cover the canvas once, every column of the picture is where it was, and every row comes from where the
 * formula says (the horizon taken in the middle of the piece's 2-column strip, as stripPlan does).
 */
function checkPieces(draws, c, view) {
  const W = 640, H = 284;
  const toPicture = (x, y) => ({ x: (view.x + (x / W) * view.w) * W, y: (view.y + (y / H) * view.h) * H });
  let area = 0;
  for (const [, sx, sy, sw, sh, dx, dy, dw, dh] of draws) {
    assert.ok(dx >= -1e-9 && dy >= -1e-9 && dx + dw <= W + 1e-9 && dy + dh <= H + 1e-9, `inside the canvas: ${[dx, dy, dw, dh]}`);
    assert.ok(sx >= -1e-9 && sy >= -1e-9 && sx + sw <= W + 1e-9 && sy + sh <= H + 1e-9, `inside the picture: ${[sx, sy, sw, sh]}`);
    area += dw * dh;
    const top = toPicture(dx, dy);
    const bottom = toPicture(dx + dw, dy + dh);
    assert.ok(Math.abs(sx - top.x) < 1e-9 && Math.abs(sx + sw - bottom.x) < 1e-9, 'columns stay where they are');
    const middle = (Math.floor((top.x + bottom.x) / 2 / 2) * 2 + 1) / W;      // the middle of the strip this piece is from
    assert.ok(Math.abs(sy - sourceFraction(c, middle, top.y / H) * H) < 1e-9, `the piece's top row comes from where the formula says (${sy})`);
    assert.ok(Math.abs(sy + sh - sourceFraction(c, middle, bottom.y / H) * H) < 1e-9, 'and its bottom row');
  }
  assert.ok(Math.abs(area - W * H) < 1e-6, `the pieces cover the canvas once (${area} of ${W * H})`);
}

test('without WebGL the zoomed area is drawn through the strip plan, every piece where the formula says', () => {
  const rig = zoomRig();
  try {
    assert.equal(rig.canvas.getContext('webgl'), null, 'a 2D zoom');
    rig.zoomIn();                                                      // 1.5×, around the middle: a third of the picture each way is cut
    const view = { x: 1 / 6, y: 1 / 6, w: 2 / 3, h: 2 / 3 };
    const draws = drawnFrom(rig.canvas, rig.video);
    assert.ok(draws.length > 100, `in pieces (${draws.length})`);
    assert.ok(draws.every(([picture]) => picture === 'picture'), 'from the camera’s own video');
    checkPieces(draws, BACKYARD, view);

    rig.state.now = OFF;
    const from = rig.canvas.getContext('2d').draws.length;
    rig.zoomIn();                                                      // 2.25×
    const off = drawnFrom(rig.canvas, rig.video, from);
    assert.equal(off.length, 1, 'off: the area in one piece, as before the correction existed');
    const [, sx, sy, sw, sh, dx, dy, dw, dh] = off[0];
    const w = 1 / 2.25;
    for (const [got, want] of [[sx, (1 - w) / 2 * 640], [sy, (1 - w) / 2 * 284], [sw, w * 640], [sh, w * 284], [dx, 0], [dy, 0], [dw, 640], [dh, 284]]) {
      assert.ok(Math.abs(got - want) < 1e-9, `${got} ≈ ${want}`);
    }
  } finally {
    rig.close();
  }
});

test('the overview shows the whole picture straightened, and plainly while off', () => {
  const rig = zoomRig();
  try {
    rig.zoomIn();
    assert.deepEqual([rig.map.width, rig.map.height], [160, 71], 'the overview has the picture’s shape');
    const plan = planCalls(BACKYARD, 160, 71, 640, 284);
    assert.deepEqual(drawnFrom(rig.map, rig.video).slice(-plan.length), plan, 'the strip plan at the overview’s size, from the video');
    rig.state.now = OFF;
    rig.zoomIn();
    assert.deepEqual(drawnFrom(rig.map, rig.video).at(-1), ['picture', 0, 0, 640, 284, 0, 0, 160, 71]);
  } finally {
    rig.close();
  }
});

test('a zoom whose WebGL context the browser takes back goes on in 2D, through the strip plan', () => {
  const rig = zoomRig({ webgl: true });
  try {
    rig.zoomIn();                                                      // 1.5×
    const gl = rig.canvas.getContext('webgl');
    gl.getExtension('WEBGL_lose_context').loseContext();             // as the browser does when a page has too many contexts
    const [flat] = rig.find((el) => el.localName === 'canvas' && el.className === 'zoom-canvas');
    assert.notEqual(flat, rig.canvas, 'a new canvas: one that had a WebGL context can have no other');
    assert.equal(rig.canvas.parentNode, null);
    assert.equal(flat.hidden, false, 'still zoomed');
    const drawsBefore = gl.calls.filter(([name]) => name === 'drawArrays').length;
    rig.zoomIn();                                                      // 2.25×
    assert.equal(gl.calls.filter(([name]) => name === 'drawArrays').length, drawsBefore, 'the lost context draws no more');
    const w = 1 / 2.25;
    checkPieces(drawnFrom(flat, rig.video), BACKYARD, { x: (1 - w) / 2, y: (1 - w) / 2, w, h: w });
  } finally {
    rig.close();
  }
});

test('a zoom gives its WebGL context back when it closes (a page gets only so many)', () => {
  const rig = zoomRig({ webgl: true });
  const gl = rig.canvas.getContext('webgl');
  rig.close();
  assert.equal(gl.isContextLost(), true);
});

// MARK: A GPU that cannot draw it

/** The calls of `gl` that upload a picture or draw. */
const uploads = (gl) => gl.calls.filter(([name]) => name === 'texImage2D').length;
const drawings = (gl) => gl.calls.filter(([name]) => name === 'drawArrays').length;
/** The zoom's canvases that are still in its layer. */
const current = (rig) => rig.find((el) => el.localName === 'canvas' && el.className === 'zoom-canvas');

test('a picture larger than the GPU’s largest texture is zoomed in 2D, not drawn black by WebGL', () => {
  // The owner's panorama is 4256 wide; a GPU limited to 4096 would upload it as an incomplete texture and the zoom would draw black.
  const rig = zoomRig({ webgl: { maxTextureSize: 4096 }, picture: { width: 4256, height: 1888, shownWidth: 640, shownHeight: 284 } });
  try {
    const [gl] = rig.gls;
    assert.ok(gl, 'WebGL was tried first');
    rig.zoomIn();
    assert.equal(uploads(gl), 0, 'the picture is never uploaded as a texture');
    assert.equal(drawings(gl), 0, 'and WebGL draws nothing');
    assert.equal(gl.isContextLost(), true, 'its context is given back');
    const [flat] = current(rig);
    assert.notEqual(flat, rig.canvas, 'a new canvas: the one WebGL had can have no 2D context');
    assert.equal(flat.hidden, false, 'zoomed');
    const draws = drawnFrom(flat, rig.video);
    assert.ok(draws.length > 100, `drawn through the strip plan, from the camera’s own video (${draws.length} pieces)`);
    assert.ok(draws.every(([picture]) => picture === 'picture'));
    rig.zoomIn();
    assert.ok(drawnFrom(flat, rig.video).length > draws.length, 'and goes on in 2D');
  } finally {
    rig.close();
  }
});

test('a picture the GPU can hold is still drawn by WebGL, up to the largest texture', () => {
  for (const [maxTextureSize, width, height] of [[8192, 4256, 1888], [4256, 4256, 1888], [4096, 640, 284]]) {
    const rig = zoomRig({ webgl: { maxTextureSize }, picture: { width, height, shownWidth: 640, shownHeight: 284 } });
    try {
      const [gl] = rig.gls;
      rig.zoomIn();
      assert.ok(uploads(gl) > 0 && drawings(gl) > 0, `${width} × ${height} on a GPU of ${maxTextureSize}: WebGL draws it`);
      assert.equal(gl.isContextLost(), false);
      assert.equal(current(rig)[0], rig.canvas, 'the same canvas');
    } finally {
      rig.close();
    }
  }
});

test('either side past the largest texture is enough to zoom in 2D', () => {
  const tall = zoomRig({ webgl: { maxTextureSize: 4096 }, picture: { width: 640, height: 4200, shownWidth: 640, shownHeight: 284 } });
  try {
    tall.zoomIn();
    assert.equal(uploads(tall.gls[0]), 0);
    assert.ok(drawnFrom(current(tall)[0], tall.video).length > 0, 'drawn in 2D');
  } finally {
    tall.close();
  }
});

for (const [failure, options] of [['compile', { compiles: false }], ['link', { links: false }]]) {
  test(`a zoom whose shader fails to ${failure} draws in 2D on a fresh canvas`, () => {
    const rig = zoomRig({ webgl: options });
    try {
      const [gl] = rig.gls;
      assert.ok(gl, 'WebGL was tried first');
      assert.equal(gl.isContextLost(), true, 'its context is given back');
      const zoomCanvases = rig.canvases.filter((el) => el.className === 'zoom-canvas');
      assert.equal(zoomCanvases.length, 2, 'a second canvas was made: the first already held a WebGL context');
      assert.equal(zoomCanvases[0].parentNode, null, 'the first is gone');
      assert.equal(current(rig)[0], zoomCanvases[1], 'the second is in the layer');
      rig.zoomIn();                                                    // 1.5×, around the middle
      const view = { x: 1 / 6, y: 1 / 6, w: 2 / 3, h: 2 / 3 };
      const draws = drawnFrom(zoomCanvases[1], rig.video);
      assert.ok(draws.length > 100, `drawn through the strip plan (${draws.length} pieces)`);
      checkPieces(draws, BACKYARD, view);
      assert.equal(drawings(gl), 0);
    } finally {
      rig.close();
    }
  });
}

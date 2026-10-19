// The digital zoom of one camera (js/live/zoom.js) on a straightened picture: the zoomed area and the overview are parts of the picture as
// the camera's page straightens it, drawn from the camera's own video through the formula (js/live/straighten.js), with WebGL or in 2D.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { fakeGL, fragmentSource, givePicture, planCalls, recordingCanvases, drawnFrom, uniform2 } from './support/fake-picture.mjs';
import { GLSL_STRAIGHTEN, sourceFraction } from '../web/js/live/straighten.js';
import { createZoom } from '../web/js/live/zoom.js';

const BACKYARD = { straighten: 0.4, level: 0.15 };
const OFF = { straighten: 0, level: 0 };

/**
 * A zoom over a 640 × 284 box showing a video of `picture` (640 × 284 unless it says otherwise: the whole picture then fills the box), the
 * zoom's canvases given WebGL when `webgl` (true, or the options of `fakeGL`: its largest texture, shaders that fail), and the correction
 * `correction.now` as the page's store would have it.
 */
function zoomRig({ webgl = false, correction = BACKYARD, picture = {} } = {}) {
  const browser = installFakeBrowser();
  const gls = [];       // every WebGL context the canvases were given
  const { canvases } = recordingCanvases(browser.document, {
    webgl: webgl ? (canvas) => { const gl = fakeGL(canvas, webgl === true ? {} : webgl); gls.push(gl); return gl; } : null,
  });
  globalThis.ResizeObserver = class { observe() {} disconnect() {} };
  const host = Object.assign(document.createElement('div'), { clientWidth: 640, clientHeight: 284 });
  const video = givePicture(document.createElement('video'), picture);
  host.append(video);
  const state = { now: correction };
  const zoom = createZoom({ host, getVideo: () => video, getCorrection: () => state.now });
  const find = (match) => {
    const out = [];
    const walk = (node) => { for (const child of node.childNodes) { if (child.tagName && match(child)) out.push(child); walk(child); } };
    walk(zoom.el);
    return out;
  };
  const [canvas] = find((el) => el.localName === 'canvas' && el.className === 'zoom-canvas');
  const [map] = find((el) => el.localName === 'canvas' && el.className === 'zoom-map');
  const zoomIn = () => find((el) => el.getAttribute('aria-label') === 'Zoom in')[0].dispatchEvent({ type: 'click', stopPropagation() {} });
  return {
    zoom, host, video, canvas, map, canvases, gls, state, zoomIn, find,
    close() { zoom.destroy(); delete globalThis.ResizeObserver; browser.restore(); },
  };
}

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

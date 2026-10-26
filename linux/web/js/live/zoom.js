// Digital zoom on one camera's picture, the one zoom of the page (the Monitor's one-camera wall, Sky Watcher's clip player): drag a box to zoom
// into it; the wheel, a trackpad's pinch or a pinch on a touch screen zoom around the pointer; zoomed, drag the picture (or the rectangle on the
// overview) to move it, or Shift and drag a box to zoom further; double-click, Esc, 0 or Reset go back to the whole picture. While zoomed, the
// area is drawn on a canvas over the video: with WebGL, upscaled and sharpened on the computer's graphics (contrast-adaptive sharpening, after
// AMD FidelityFX CAS: edges and small text come back without halos), else drawn plainly with the browser's best smoothing.
//
// The view is a rectangle of the picture in its own normalized coordinates (0..1 across and down). It always keeps the shape of the tile, so
// the zoomed area fills it. A camera whose picture is straightened (its page's Straighten the picture, js/live/straighten.js) is zoomed in the
// straightened picture: the view is a rectangle of that picture (the same size as the video's), and every point of it is sampled from the
// video where the formula says, so a straight horizon stays straight however far in. A page that draws over the picture (the light's path in
// Sky Watcher's player) gives the zoom its marks: they are put over the zoomed picture, under the zoom's own controls, and the page draws them
// in the view's coordinates (onView), so they stay on what they mark.
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { GLSL_STRAIGHTEN, stripPlan } from './straighten.js';

const MAX_ZOOM = 12;
const DRAG_MIN_PX = 8;          // a drag shorter than this is a click
const WHEEL_STEP = 1.0018;      // zoom per wheel pixel (a notch of 100 px: about 1.2x)
const STORE_KEY = 'cb.zoom.enhance';
const HINT_WHOLE = 'Drag over an area to zoom';
const HINT_ZOOMED = 'Drag to move · Shift-drag to zoom further';

const clamp = (value, low, high) => Math.min(Math.max(value, low), high);

const VERTEX = `attribute vec2 p; varying vec2 uv; uniform vec4 view; void main() {
  uv = view.xy + (p * 0.5 + 0.5) * view.zw; gl_Position = vec4(p.x, -p.y, 0.0, 1.0); }`;

// Contrast-adaptive sharpening on the source's own pixel grid: the 3x3 neighbourhood (cross) decides how much the centre is pushed away from
// its neighbours, less where the area is already contrasty, so flat areas and edges are sharpened without ringing. `uv` is a point of the
// straightened picture; pick() samples the video where it comes from (`straighten` is (0, 0) for a picture that is not straightened: the
// identity). highp where the graphics have it: mediump (16-bit on phones) cannot address every row of a tall picture.
const FRAGMENT = `#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 uv; uniform sampler2D tex; uniform vec2 texel; uniform float amount;
${GLSL_STRAIGHTEN}
vec3 pick(vec2 at) { return texture2D(tex, vec2(at.x, sourceDown(at.x, at.y))).rgb; }
void main() {
  vec3 e = pick(uv);
  if (amount <= 0.0) { gl_FragColor = vec4(e, 1.0); return; }
  vec3 b = pick(uv + vec2(0.0, -texel.y));
  vec3 d = pick(uv + vec2(-texel.x, 0.0));
  vec3 f = pick(uv + vec2(texel.x, 0.0));
  vec3 hh = pick(uv + vec2(0.0, texel.y));
  vec3 mn = min(min(min(d, e), min(f, b)), hh);
  vec3 mx = max(max(max(d, e), max(f, b)), hh);
  vec3 amp = sqrt(clamp(min(mn, 2.0 - mx) / max(mx, vec3(0.0001)), 0.0, 1.0));
  vec3 w = amp * (-1.0 / mix(8.0, 5.0, amount));
  vec3 outc = (b * w + d * w + f * w + hh * w + e) / (1.0 + 4.0 * w);
  gl_FragColor = vec4(clamp(outc, 0.0, 1.0), 1.0);
}`;

function readEnhance() {
  try { return localStorage.getItem(STORE_KEY) !== '0'; } catch { return true; }
}

/**
 * A WebGL drawer of a video area with sharpening; null when the browser has no WebGL, or its shaders do not compile or link (the context is
 * then given back; the canvas has had it, so it can have no 2D context: the zoom draws on a new one).
 */
function createGLDrawer(canvas) {
  const gl = canvas.getContext('webgl', { alpha: false, antialias: false, preserveDrawingBuffer: false });
  if (!gl) return null;
  const giveBack = () => gl.getExtension('WEBGL_lose_context')?.loseContext();
  function shader(type, text) {
    const s = gl.createShader(type);
    gl.shaderSource(s, text);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) || 'shader');
    return s;
  }
  let program;
  try {
    program = gl.createProgram();
    gl.attachShader(program, shader(gl.VERTEX_SHADER, VERTEX));
    gl.attachShader(program, shader(gl.FRAGMENT_SHADER, FRAGMENT));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program) || 'link');
  } catch {
    giveBack();
    return null;
  }
  gl.useProgram(program);
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const p = gl.getAttribLocation(program, 'p');
  gl.enableVertexAttribArray(p);
  gl.vertexAttribPointer(p, 2, gl.FLOAT, false, 0, 0);
  const texture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  const uView = gl.getUniformLocation(program, 'view');
  const uTexel = gl.getUniformLocation(program, 'texel');
  const uAmount = gl.getUniformLocation(program, 'amount');
  const uStraighten = gl.getUniformLocation(program, 'straighten');
  const largest = gl.getParameter(gl.MAX_TEXTURE_SIZE);
  return {
    /**
     * Draws `view` of `size.video` (a video or an image, `size.vw` × `size.vh`) straightened by `correction` into `rect` (canvas pixels: x, y,
     * w, h), the rest black; false when WebGL cannot (a lost context, a picture larger than its largest texture, which it would draw black, or
     * a picture it refuses).
     */
    draw(size, view, rect, amount, correction) {
      if (gl.isContextLost() || !(size.vw <= largest && size.vh <= largest)) return false;
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.clearColor(0, 0, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
      try { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, size.video); } catch { return false; }
      gl.viewport(Math.round(rect.x), Math.round(canvas.height - rect.y - rect.h), Math.round(rect.w), Math.round(rect.h));
      gl.uniform4f(uView, view.x, view.y, view.w, view.h);
      gl.uniform2f(uTexel, 1 / size.vw, 1 / size.vh);
      gl.uniform1f(uAmount, amount);
      gl.uniform2f(uStraighten, Number(correction?.straighten) || 0, Number(correction?.level) || 0);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      return true;
    },
    /** Frees the context at once (a page gets only so many: the Monitor's straightened pictures have theirs too). */
    destroy() {
      if (!gl.isContextLost()) {
        gl.deleteTexture(texture);
        gl.deleteBuffer(buffer);
        gl.deleteProgram(program);
      }
      giveBack();
    },
  };
}

/** stripPlan, kept while the correction and the size stay the same: the zoom draws every display frame. */
function keptPlan() {
  let key = null;
  let plan = null;
  return (correction, width, height) => {
    const next = `${Number(correction?.straighten) || 0},${Number(correction?.level) || 0},${width},${height}`;
    if (next !== key) { key = next; plan = stripPlan(correction, width, height); }
    return plan;
  };
}

/**
 * The 2D path's pieces of the area `view` (normalized) of the straightened picture: `plan` is the strip plan of the picture at `pw` × `ph`
 * (the video is `vw` × `vh`), and each of its pieces that shows is cut to the view, with its rectangle in the video's pixels and in `rect`
 * (canvas pixels). Off, the plan is one piece: the area, as it always was. -> [[sx, sy, sw, sh, dx, dy, dw, dh]]
 */
function viewPieces(plan, pw, ph, vw, vh, view, rect) {
  const kx = vw / pw, ky = vh / ph;
  const left = view.x * pw, top = view.y * ph, width = view.w * pw, height = view.h * ph;
  const fx = rect.w / width, fy = rect.h / height;
  const pieces = [];
  for (const r of plan) {
    const x0 = Math.max(r.dx, left), x1 = Math.min(r.dx + r.dw, left + width);
    const y0 = Math.max(r.dy, top), y1 = Math.min(r.dy + r.dh, top + height);
    if (x1 <= x0 || y1 <= y0) continue;
    // A piece is one straight stretch, so the part of it that shows comes from the same part of its source rectangle.
    const sx = r.sw / r.dw, sy = r.sh / r.dh;
    pieces.push([(r.sx + (x0 - r.dx) * sx) * kx, (r.sy + (y0 - r.dy) * sy) * ky, (x1 - x0) * sx * kx, (y1 - y0) * sy * ky,
      rect.x + (x0 - left) * fx, rect.y + (y0 - top) * fy, (x1 - x0) * fx, (y1 - y0) * fy]);
  }
  return pieces;
}

/**
 * Zoom over `host` (the picture's box). `getVideo()` gives the picture on screen now: a <video> (live or a recording) or an <img> (a still),
 * null while there is none; `getCorrection()` the camera's picture correction now (null or off: the picture as the camera sends it), read at
 * every picture, so a correction saved meanwhile shows at once. `onActive(zoomed)` runs when the picture goes from whole to zoomed and back,
 * `onView(view)` after every change of the view. `marks`, an element of the page's the size of the host, is put over the zoomed picture and
 * under the zoom's controls: the page draws in it what marks a place in the picture, in the view's coordinates (view(), level()).
 * -> { el, reset(), zoomed(), view(), level(), zoomTo(x, y, level), key(event), destroy() }
 */
export function createZoom({ host, getVideo, getCorrection = () => null, onActive = () => {}, onView = () => {}, marks = null }) {
  let view = { x: 0, y: 0, w: 1, h: 1 };
  let enhance = readEnhance();
  let destroyed = false;
  let frame = null;
  let drag = null;              // { kind: 'box' | 'pan', x0, y0, x1, y1, moved, view0 }
  const pointers = new Map();   // pointer id -> {x, y}, for a pinch
  let pinch = null;             // { distance, x, y }: the two fingers' distance and midpoint at the last move
  let gesture = null;           // Safari's trackpad pinch: { scale } at the last change
  let stillDrawn = null;        // the still last drawn (a picture that does not move is drawn again only when something changes)

  let canvas = h('canvas', { class: 'zoom-canvas', hidden: true, 'aria-hidden': 'true' });
  const box = h('div', { class: 'zoom-box', hidden: true });
  const surface = h('div', { class: 'zoom-surface' });
  const level = h('span', { class: 'zoom-level', 'aria-live': 'polite' });
  const minimap = h('canvas', { class: 'zoom-map', width: 160, height: 90, title: 'Drag the rectangle to move' });
  const enhanceButton = h('button', { class: 'zoom-btn zoom-enhance', type: 'button', onclick: (e) => { e.stopPropagation(); setEnhance(!enhance); } });
  const controls = h('div', { class: 'zoom-controls', hidden: true },
    h('div', { class: 'zoom-row' },
      h('button', { class: 'zoom-btn', type: 'button', 'aria-label': 'Zoom out', onclick: (e) => { e.stopPropagation(); zoomBy(1 / 1.5); } }, '−'),
      level,
      h('button', { class: 'zoom-btn', type: 'button', 'aria-label': 'Zoom in', onclick: (e) => { e.stopPropagation(); zoomBy(1.5); } }, '+'),
      h('button', { class: 'zoom-btn zoom-reset', type: 'button', title: 'The whole picture (double-click, Esc or 0)', onclick: (e) => { e.stopPropagation(); reset(); } },
        icon('refresh'), 'Reset'),
      enhanceButton),
    minimap);
  const hint = h('div', { class: 'zoom-hint' }, HINT_WHOLE);
  const el = h('div', { class: 'zoom-layer' }, canvas, marks, surface, box, controls, hint);
  // The hint shows for 3 s: each time the pointer comes onto the whole picture, and once as it is zoomed (how to move it). Never on a touch
  // screen (monitor.css).
  let hintTimer = null;
  function flashHint(text) {
    if (hint.textContent !== text) hint.textContent = text;
    hint.dataset.show = 'true';
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => { hint.dataset.show = 'false'; }, 3000);
  }
  surface.addEventListener('pointerenter', (event) => {
    if (event.pointerType === 'mouse' && !isZoomed()) flashHint(HINT_WHOLE);
  });
  host.append(el);

  /** A new canvas takes this one's place: one that had a WebGL context can have no other kind. -> its 2D context */
  function replaceCanvas() {
    const fresh = h('canvas', { class: 'zoom-canvas', hidden: canvas.hidden, 'aria-hidden': 'true' });
    canvas.after(fresh);
    canvas.remove();
    canvas = fresh;
    return canvas.getContext('2d');
  }

  let gl = createGLDrawer(canvas);
  let ctx2d = gl ? null : canvas.getContext('2d');
  if (!gl && !ctx2d) ctx2d = replaceCanvas();     // WebGL took the canvas and then failed (its shaders): draw on a new one
  if (gl) canvas.addEventListener('webglcontextlost', flatten);
  const enhanceTitle = () => (gl ? 'Sharpens the zoomed picture on this computer’s graphics' : 'This browser has no WebGL: the picture is only smoothed');

  /**
   * WebGL draws no more (the browser took its context back, as it does when a page has too many, or it refused a picture, or the picture is
   * larger than its largest texture): a new canvas takes the WebGL one's place and the zoom goes on in 2D (a canvas that had a WebGL context
   * can have no other).
   */
  function flatten() {
    if (!gl) return;
    const old = gl;
    gl = null;
    stillDrawn = null;
    canvas.removeEventListener('webglcontextlost', flatten);
    old.destroy();
    if (destroyed) return;
    ctx2d = replaceCanvas();
    enhanceButton.title = enhanceTitle();
  }
  const areaPlan = keptPlan();      // the 2D path's
  const mapPlan = keptPlan();       // the overview's

  const isZoomed = () => view.w < 0.999 || view.h < 0.999;
  const sameView = (a, b) => a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;

  /** The picture on screen and its own size (a video's, or an image's once it has loaded): { video, vw, vh, still }, or null while there is none. */
  function videoSize() {
    const video = getVideo();
    const vw = video?.videoWidth || video?.naturalWidth || 0;
    const vh = video?.videoHeight || video?.naturalHeight || 0;
    if (!(vw > 0 && vh > 0)) return null;
    return { video, vw, vh, still: !(video.videoWidth > 0) };
  }

  /** Where `view` lands in the host (CSS pixels): fitted, letterboxed. */
  function fitted(v, vw, vh) {
    const bw = host.clientWidth, bh = host.clientHeight;
    const rw = v.w * vw, rh = v.h * vh;
    const scale = Math.min(bw / rw, bh / rh);
    const w = rw * scale, hgt = rh * scale;
    return { x: (bw - w) / 2, y: (bh - hgt) / 2, w, h: hgt, scale };
  }

  /** The view the size of the tile's shape around a centre (normalized), `wNorm` wide, kept inside the picture. */
  function shaped(cx, cy, wNorm, vw, vh) {
    const tileAspect = host.clientWidth / Math.max(1, host.clientHeight);
    const videoAspect = vw / vh;
    let w = Math.min(1, Math.max(1 / MAX_ZOOM, wNorm));
    let hgt = w * videoAspect / tileAspect;
    if (hgt > 1) { hgt = 1; w = Math.min(1, tileAspect / videoAspect); }
    if (w >= 0.999 && hgt >= 0.999) return { x: 0, y: 0, w: 1, h: 1 };
    // A tile wider than the picture: the whole height shows and a narrower width zooms nothing; treat full height as the floor.
    const x = Math.min(Math.max(cx - w / 2, 0), 1 - w);
    const y = Math.min(Math.max(cy - hgt / 2, 0), 1 - hgt);
    return { x, y, w, h: hgt };
  }

  /** A host point (CSS pixels) in normalized video coordinates under the current view; null outside the picture. */
  function toVideo(px, py, size) {
    const f = fitted(view, size.vw, size.vh);
    return { x: view.x + ((px - f.x) / f.w) * view.w, y: view.y + ((py - f.y) / f.h) * view.h };
  }

  function zoomFactor(size) {
    const whole = fitted({ x: 0, y: 0, w: 1, h: 1 }, size.vw, size.vh).scale;
    return fitted(view, size.vw, size.vh).scale / whole;
  }

  function setView(next) {
    if (sameView(view, next)) return;
    const was = isZoomed();
    view = next;
    const now = isZoomed();
    canvas.hidden = !now;
    controls.hidden = !now;
    el.dataset.zoomed = String(now);
    if (now !== was) {
      onActive(now);
      if (now) flashHint(HINT_ZOOMED);
      else { clearTimeout(hintTimer); hint.dataset.show = 'false'; }
    }
    draw();
    showLevel();
    onView({ ...view });
  }

  function showLevel() {
    const size = videoSize();
    level.textContent = size ? `${zoomFactor(size).toFixed(1)}×` : '';
  }

  /**
   * Zooms by `factor` around the host point (px, py) (CSS pixels): the point of the picture under it stays there, or with (toX, toY) goes
   * there (a pinch's fingers move as they spread). Out past the whole picture is the whole picture.
   */
  function zoomBy(factor, px = host.clientWidth / 2, py = host.clientHeight / 2, toX = px, toY = py) {
    const size = videoSize();
    if (!size) return;
    const at = toVideo(px, py, size);
    const w = view.w / factor;
    if (w >= 1 && factor < 1) { reset(); return; }
    const next = shaped(0, 0, w, size.vw, size.vh);
    const f = fitted(next, size.vw, size.vh);
    const fx = (toX - f.x) / f.w, fy = (toY - f.y) / f.h;
    next.x = clamp(at.x - fx * next.w, 0, 1 - next.w);
    next.y = clamp(at.y - fy * next.h, 0, 1 - next.h);
    setView(next);
  }

  /** `from` (a view) moved as the pointer moved by (dx, dy) CSS pixels: the picture follows the pointer, never past its edges. */
  function pan(from, dx, dy) {
    const size = videoSize();
    if (!size) return;
    const f = fitted(from, size.vw, size.vh);
    setView({ ...from, x: clamp(from.x - (dx / f.w) * from.w, 0, 1 - from.w), y: clamp(from.y - (dy / f.h) * from.h, 0, 1 - from.h) });
  }

  /**
   * The area around (x, y) (0..1 of the picture) at `times` the whole picture's size (the level the controls read), kept inside the picture.
   * -> false while there is no picture to zoom
   */
  function zoomTo(x, y, times) {
    const size = videoSize();
    if (!size || !(times > 0)) return false;
    const tileAspect = host.clientWidth / Math.max(1, host.clientHeight);
    // The whole picture fits the host by its height when the host is wider than the picture: a view as wide as the host shows more across.
    setView(shaped(x, y, Math.max(1, tileAspect / (size.vw / size.vh)) / times, size.vw, size.vh));
    return true;
  }

  function reset() { setView({ x: 0, y: 0, w: 1, h: 1 }); }

  /** Esc or 0 while zoomed (not with ctrl, cmd or alt): the whole picture again. -> whether the key was the zoom's */
  function key(event) {
    if (!isZoomed() || event.ctrlKey || event.metaKey || event.altKey || (event.key !== 'Escape' && event.key !== '0')) return false;
    reset();
    return true;
  }

  function setEnhance(on) {
    enhance = on;
    try { localStorage.setItem(STORE_KEY, on ? '1' : '0'); } catch { /* not kept */ }
    replace(enhanceButton, icon('bolt'), on ? 'Enhance on' : 'Enhance off');
    enhanceButton.setAttribute('aria-pressed', String(on));
    enhanceButton.title = enhanceTitle();
    draw();
  }

  // MARK: Drawing

  /** Draws the zoomed area and the overview; `again` (each display frame) leaves a still that is already drawn as it is. */
  function draw({ again = false } = {}) {
    if (destroyed || !isZoomed()) return;
    const size = videoSize();
    if (!size) return;
    const ratio = window.devicePixelRatio || 1;
    const cw = Math.max(1, Math.round(host.clientWidth * ratio)), ch = Math.max(1, Math.round(host.clientHeight * ratio));
    const correction = getCorrection();
    // A still does not move: drawn again only when its picture, the canvas's size or the correction changes (the view and Enhance draw at once).
    const still = size.still ? `${size.video.currentSrc || size.video.src}|${cw}x${ch}|${Number(correction?.straighten) || 0},${Number(correction?.level) || 0}` : null;
    if (again && still !== null && still === stillDrawn) return;
    stillDrawn = still;
    if (canvas.width !== cw || canvas.height !== ch) { canvas.width = cw; canvas.height = ch; }
    const f = fitted(view, size.vw, size.vh);
    const rect = { x: f.x * ratio, y: f.y * ratio, w: f.w * ratio, h: f.h * ratio };
    let drawn = false;
    if (gl) drawn = gl.draw(size, view, rect, enhance ? 0.6 : 0, correction);
    if (!drawn) {
      // Without WebGL (or a frame WebGL refused): the browser's own scaling, through the strip plan of the picture at about the size the canvas
      // shows it (a strip of two columns is then two canvas pixels, or two of the video's when zoomed in further).
      flatten();
      if (canvas.width !== cw || canvas.height !== ch) { canvas.width = cw; canvas.height = ch; }
      const c = ctx2d;
      if (c) {
        c.fillStyle = '#000';
        c.fillRect(0, 0, cw, ch);
        c.imageSmoothingEnabled = true;
        c.imageSmoothingQuality = 'high';
        const scale = Math.min(1, rect.w / (view.w * size.vw));
        const pw = Math.max(1, Math.round(size.vw * scale)), ph = Math.max(1, Math.round(size.vh * scale));
        try {
          for (const piece of viewPieces(areaPlan(correction, pw, ph), pw, ph, size.vw, size.vh, view, rect)) c.drawImage(size.video, ...piece);
        } catch { /* not ready */ }
      }
    }
    drawMap(size, correction);
  }

  function drawMap(size, correction) {
    const c = minimap.getContext('2d');
    if (!c) return;
    const mh = Math.round(minimap.width * size.vh / size.vw);
    if (minimap.height !== mh) minimap.height = mh;
    const kx = size.vw / minimap.width, ky = size.vh / minimap.height;
    try {
      for (const r of mapPlan(correction, minimap.width, minimap.height)) c.drawImage(size.video, r.sx * kx, r.sy * ky, r.sw * kx, r.sh * ky, r.dx, r.dy, r.dw, r.dh);
    } catch { return; }
    c.fillStyle = 'rgb(0 0 0 / 0.45)';
    const r = { x: view.x * minimap.width, y: view.y * minimap.height, w: view.w * minimap.width, h: view.h * minimap.height };
    c.fillRect(0, 0, minimap.width, r.y);
    c.fillRect(0, r.y + r.h, minimap.width, minimap.height - r.y - r.h);
    c.fillRect(0, r.y, r.x, r.h);
    c.fillRect(r.x + r.w, r.y, minimap.width - r.x - r.w, r.h);
    c.strokeStyle = '#e06a5a';   // light brand red, as the zoom box (monitor.css)
    c.lineWidth = 2;
    c.strokeRect(r.x + 1, r.y + 1, Math.max(2, r.w - 2), Math.max(2, r.h - 2));
  }

  // Every display frame while zoomed (the picture under it may switch between live video and a recording).
  function loop() {
    if (destroyed) return;
    if (isZoomed()) draw({ again: true });
    frame = requestAnimationFrame(loop);
  }

  // MARK: Pointer

  const local = (event) => { const r = host.getBoundingClientRect(); return { x: event.clientX - r.left, y: event.clientY - r.top }; };
  const panFrom = (p) => ({ kind: 'pan', x0: p.x, y0: p.y, x1: p.x, y1: p.y, moved: false, view0: view });
  const setPanning = (on) => { if (el.dataset.panning !== String(on)) el.dataset.panning = String(on); };

  surface.addEventListener('pointerdown', (event) => {
    if (event.button !== 0 && event.pointerType === 'mouse') return;
    const p = local(event);
    pointers.set(event.pointerId, p);
    try { surface.setPointerCapture(event.pointerId); } catch { /* a synthetic pointer has nothing to capture */ }
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      pinch = { distance: Math.hypot(a.x - b.x, a.y - b.y), x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      drag = null;
      box.hidden = true;
      setPanning(false);
      return;
    }
    if (pointers.size > 2) return;
    // Zoomed, a drag moves the picture (with Shift, a box zooms further); whole, a drag is a box.
    drag = isZoomed() && !event.shiftKey ? panFrom(p) : { kind: 'box', x0: p.x, y0: p.y, x1: p.x, y1: p.y, moved: false };
  });

  surface.addEventListener('pointermove', (event) => {
    if (!pointers.has(event.pointerId)) return;
    const p = local(event);
    pointers.set(event.pointerId, p);
    if (pinch) {
      if (pointers.size !== 2) return;
      // The fingers' spread zooms; the point of the picture under their midpoint goes along with it.
      const [a, b] = [...pointers.values()];
      const distance = Math.hypot(a.x - b.x, a.y - b.y);
      const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      zoomBy(pinch.distance > 0 && distance > 0 ? distance / pinch.distance : 1, pinch.x, pinch.y, mid.x, mid.y);
      pinch = { distance, ...mid };
      return;
    }
    if (!drag) return;
    drag.x1 = p.x; drag.y1 = p.y;
    if (Math.hypot(drag.x1 - drag.x0, drag.y1 - drag.y0) >= DRAG_MIN_PX) drag.moved = true;
    if (!drag.moved) return;
    if (drag.kind === 'pan') {
      setPanning(true);
      pan(drag.view0, drag.x1 - drag.x0, drag.y1 - drag.y0);
      return;
    }
    box.hidden = false;
    box.style.setProperty('--x', `${Math.min(drag.x0, drag.x1)}px`);
    box.style.setProperty('--y', `${Math.min(drag.y0, drag.y1)}px`);
    box.style.setProperty('--w', `${Math.abs(drag.x1 - drag.x0)}px`);
    box.style.setProperty('--h', `${Math.abs(drag.y1 - drag.y0)}px`);
  });

  /** The view a box dragged from (x0, y0) to (x1, y1) (host CSS pixels) zooms to: all of the box, in the host's shape, inside the picture. */
  function boxView(x0, y0, x1, y1, size) {
    const a = toVideo(Math.min(x0, x1), Math.min(y0, y1), size);
    const b = toVideo(Math.max(x0, x1), Math.max(y0, y1), size);
    const cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
    // The box's larger side decides, so all of it is in the zoomed area.
    const tileAspect = host.clientWidth / Math.max(1, host.clientHeight);
    const boxW = Math.max(b.x - a.x, (b.y - a.y) * tileAspect * size.vh / size.vw);
    return shaped(cx, cy, boxW, size.vw, size.vh);
  }

  function endPointer(event) {
    pointers.delete(event.pointerId);
    setPanning(false);
    if (pinch) {
      if (pointers.size >= 2) return;
      pinch = null;
      // The finger left on a zoomed picture moves it on.
      const [rest] = pointers.values();
      if (rest && isZoomed()) drag = panFrom(rest);
      return;
    }
    const d = drag;
    drag = null;
    box.hidden = true;
    if (!d) return;
    if (!d.moved) {
      // A plain click: zoomed, it does nothing (the wall stays on this camera); whole, the tile's own click goes back to all cameras.
      if (isZoomed()) event.stopPropagation();
      return;
    }
    event.stopPropagation();
    if (d.kind === 'pan') return;           // it moved the picture as it went
    const size = videoSize();
    if (size) setView(boxView(d.x0, d.y0, d.x1, d.y1, size));
  }
  surface.addEventListener('pointerup', endPointer);
  surface.addEventListener('pointercancel', (event) => { pointers.delete(event.pointerId); drag = null; pinch = null; box.hidden = true; setPanning(false); });
  // The tile's click (go back to all cameras) only for a plain click on the whole picture.
  surface.addEventListener('click', (event) => { if (isZoomed()) event.stopPropagation(); });
  surface.addEventListener('dblclick', (event) => { event.stopPropagation(); reset(); });
  // The wheel (and a trackpad: a pinch comes as the wheel with ctrl) zooms the picture, never the page.
  surface.addEventListener('wheel', (event) => {
    event.preventDefault();
    const p = local(event);
    const delta = event.deltaMode === 1 ? event.deltaY * 33 : event.deltaY;
    zoomBy(Math.pow(WHEEL_STEP, -delta * (event.ctrlKey ? 4 : 1)), p.x, p.y);
  }, { passive: false });
  // Safari's trackpad pinch comes as its gesture events, and would zoom the whole page. A pinch on a touch screen is the pointers' (above).
  surface.addEventListener('gesturestart', (event) => { event.preventDefault(); gesture = { scale: 1 }; });
  surface.addEventListener('gesturechange', (event) => {
    event.preventDefault();
    if (!gesture || pointers.size > 0 || !(event.scale > 0)) return;
    const p = local(event);
    zoomBy(event.scale / gesture.scale, p.x, p.y);
    gesture.scale = event.scale;
  });
  surface.addEventListener('gestureend', (event) => { event.preventDefault(); gesture = null; });

  // The overview: drag the rectangle (or click anywhere on it) to move.
  function mapMove(event) {
    const r = minimap.getBoundingClientRect();
    const cx = (event.clientX - r.left) / r.width, cy = (event.clientY - r.top) / r.height;
    setView({ ...view, x: Math.min(Math.max(cx - view.w / 2, 0), 1 - view.w), y: Math.min(Math.max(cy - view.h / 2, 0), 1 - view.h) });
  }
  minimap.addEventListener('pointerdown', (event) => { event.stopPropagation(); minimap.setPointerCapture(event.pointerId); mapMove(event); });
  minimap.addEventListener('pointermove', (event) => { if (minimap.hasPointerCapture(event.pointerId)) mapMove(event); });
  for (const type of ['click', 'dblclick', 'pointerup']) {
    minimap.addEventListener(type, (event) => event.stopPropagation());
    controls.addEventListener(type, (event) => event.stopPropagation());
  }

  // A host of a new size: the zoomed area keeps its centre and width and takes the host's new shape, drawn at the new size.
  const resize = new ResizeObserver(() => {
    const size = isZoomed() ? videoSize() : null;
    if (!size) return;
    setView(shaped(view.x + view.w / 2, view.y + view.h / 2, view.w, size.vw, size.vh));
    draw();
    showLevel();
  });
  resize.observe(host);

  setEnhance(enhance);
  el.dataset.zoomed = 'false';
  el.dataset.panning = 'false';
  loop();

  return {
    el,
    reset,
    zoomed: isZoomed,
    /** The part of the picture on screen: { x, y, w, h }, 0..1 of the picture (the whole picture: 0, 0, 1, 1). */
    view: () => ({ ...view }),
    /** How many times the whole picture's size it is shown (the level the controls read): 1 for the whole picture. */
    level: () => { const size = videoSize(); return size && isZoomed() ? zoomFactor(size) : 1; },
    zoomTo,
    key,
    destroy() {
      clearTimeout(hintTimer);
      destroyed = true;
      resize.disconnect();
      if (frame !== null) cancelAnimationFrame(frame);
      canvas.removeEventListener('webglcontextlost', flatten);
      gl?.destroy();
      el.remove();
    },
  };
}

// Digital zoom on one camera's picture (the Monitor's one-camera wall): drag a box to zoom into it, wheel or pinch to zoom around the pointer,
// drag the rectangle on the overview to move, double-click or Esc to go back to the whole picture. While zoomed, the area is drawn on a canvas
// over the video: with WebGL, upscaled and sharpened on the computer's graphics (contrast-adaptive sharpening, after AMD FidelityFX CAS: edges
// and small text come back without halos), else drawn plainly with the browser's best smoothing.
//
// The view is a rectangle of the video in its own normalized coordinates (0..1 across and down). It always keeps the shape of the tile, so the
// zoomed area fills it.
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';

const MAX_ZOOM = 12;
const DRAG_MIN_PX = 8;          // a drag shorter than this is a click
const WHEEL_STEP = 1.0018;      // zoom per wheel pixel (a notch of 100 px: about 1.2x)
const STORE_KEY = 'cb.zoom.enhance';

const VERTEX = `attribute vec2 p; varying vec2 uv; uniform vec4 view; void main() {
  uv = view.xy + (p * 0.5 + 0.5) * view.zw; gl_Position = vec4(p.x, -p.y, 0.0, 1.0); }`;

// Contrast-adaptive sharpening on the source's own pixel grid: the 3x3 neighbourhood (cross) decides how much the centre is pushed away from
// its neighbours, less where the area is already contrasty, so flat areas and edges are sharpened without ringing.
const FRAGMENT = `precision mediump float; varying vec2 uv; uniform sampler2D tex; uniform vec2 texel; uniform float amount;
void main() {
  vec3 e = texture2D(tex, uv).rgb;
  if (amount <= 0.0) { gl_FragColor = vec4(e, 1.0); return; }
  vec3 b = texture2D(tex, uv + vec2(0.0, -texel.y)).rgb;
  vec3 d = texture2D(tex, uv + vec2(-texel.x, 0.0)).rgb;
  vec3 f = texture2D(tex, uv + vec2(texel.x, 0.0)).rgb;
  vec3 hh = texture2D(tex, uv + vec2(0.0, texel.y)).rgb;
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

/** A WebGL drawer of a video area with sharpening; null when the browser has no WebGL. */
function createGLDrawer(canvas) {
  const gl = canvas.getContext('webgl', { alpha: false, antialias: false, preserveDrawingBuffer: false });
  if (!gl) return null;
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
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
  } catch { return null; }
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
  return {
    /** Draws `view` of `video` into `rect` (canvas pixels: x, y, w, h), the rest black. */
    draw(video, view, rect, amount) {
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.clearColor(0, 0, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
      try { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, video); } catch { return false; }
      gl.viewport(Math.round(rect.x), Math.round(canvas.height - rect.y - rect.h), Math.round(rect.w), Math.round(rect.h));
      gl.uniform4f(uView, view.x, view.y, view.w, view.h);
      gl.uniform2f(uTexel, 1 / video.videoWidth, 1 / video.videoHeight);
      gl.uniform1f(uAmount, amount);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      return true;
    },
    destroy() {
      gl.deleteTexture(texture);
      gl.deleteBuffer(buffer);
      gl.deleteProgram(program);
    },
  };
}

/**
 * Zoom over `host` (the tile's picture box). `getVideo()` gives the <video> on screen now (live or a recording). `onActive(zoomed)` runs when the
 * picture goes from whole to zoomed and back. -> { el, reset(), zoomed(), destroy() }
 */
export function createZoom({ host, getVideo, onActive = () => {} }) {
  let view = { x: 0, y: 0, w: 1, h: 1 };
  let enhance = readEnhance();
  let destroyed = false;
  let frame = null;
  let drag = null;              // { kind: 'box' | 'pan', x0, y0, x1, y1, view0 }
  const pointers = new Map();   // pointer id -> {x, y}, for a pinch
  let pinch = null;

  const canvas = h('canvas', { class: 'zoom-canvas', hidden: true, 'aria-hidden': 'true' });
  const box = h('div', { class: 'zoom-box', hidden: true });
  const surface = h('div', { class: 'zoom-surface', title: 'Drag over an area to zoom into it' });
  const level = h('span', { class: 'zoom-level', 'aria-live': 'polite' });
  const minimap = h('canvas', { class: 'zoom-map', width: 160, height: 90, title: 'Drag the rectangle to move' });
  const enhanceButton = h('button', { class: 'zoom-btn zoom-enhance', type: 'button', onclick: (e) => { e.stopPropagation(); setEnhance(!enhance); } });
  const controls = h('div', { class: 'zoom-controls', hidden: true },
    h('div', { class: 'zoom-row' },
      h('button', { class: 'zoom-btn', type: 'button', 'aria-label': 'Zoom out', onclick: (e) => { e.stopPropagation(); zoomBy(1 / 1.5); } }, '−'),
      level,
      h('button', { class: 'zoom-btn', type: 'button', 'aria-label': 'Zoom in', onclick: (e) => { e.stopPropagation(); zoomBy(1.5); } }, '+'),
      h('button', { class: 'zoom-btn', type: 'button', onclick: (e) => { e.stopPropagation(); reset(); } }, icon('refresh'), 'Reset'),
      enhanceButton),
    minimap);
  const hint = h('div', { class: 'zoom-hint' }, 'Drag over an area to zoom');
  const el = h('div', { class: 'zoom-layer' }, canvas, surface, box, controls, hint);
  host.append(el);

  let gl = createGLDrawer(canvas);
  const ctx2d = gl ? null : canvas.getContext('2d');

  const isZoomed = () => view.w < 0.999 || view.h < 0.999;

  function videoSize() {
    const video = getVideo();
    if (!video || !video.videoWidth || !video.videoHeight) return null;
    return { video, vw: video.videoWidth, vh: video.videoHeight };
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
    const was = isZoomed();
    view = next;
    const now = isZoomed();
    canvas.hidden = !now;
    controls.hidden = !now;
    el.dataset.zoomed = String(now);
    if (now !== was) onActive(now);
    draw();
    showLevel();
  }

  function showLevel() {
    const size = videoSize();
    level.textContent = size ? `${zoomFactor(size).toFixed(1)}×` : '';
  }

  function zoomBy(factor, px = host.clientWidth / 2, py = host.clientHeight / 2) {
    const size = videoSize();
    if (!size) return;
    const at = toVideo(px, py, size);
    const w = view.w / factor;
    if (w >= 1 && factor < 1) { reset(); return; }
    // Keep the point under the pointer where it is.
    const next = shaped(0, 0, w, size.vw, size.vh);
    const f = fitted(next, size.vw, size.vh);
    const fx = (px - f.x) / f.w, fy = (py - f.y) / f.h;
    next.x = Math.min(Math.max(at.x - fx * next.w, 0), 1 - next.w);
    next.y = Math.min(Math.max(at.y - fy * next.h, 0), 1 - next.h);
    setView(next);
  }

  function reset() { setView({ x: 0, y: 0, w: 1, h: 1 }); }

  function setEnhance(on) {
    enhance = on;
    try { localStorage.setItem(STORE_KEY, on ? '1' : '0'); } catch { /* not kept */ }
    replace(enhanceButton, icon('bolt'), on ? 'Enhance on' : 'Enhance off');
    enhanceButton.setAttribute('aria-pressed', String(on));
    enhanceButton.title = gl ? 'Sharpens the zoomed picture on this computer’s graphics' : 'This browser has no WebGL: the picture is only smoothed';
    draw();
  }

  // MARK: Drawing

  function draw() {
    if (destroyed || !isZoomed()) return;
    const size = videoSize();
    if (!size) return;
    const ratio = window.devicePixelRatio || 1;
    const cw = Math.max(1, Math.round(host.clientWidth * ratio)), ch = Math.max(1, Math.round(host.clientHeight * ratio));
    if (canvas.width !== cw || canvas.height !== ch) { canvas.width = cw; canvas.height = ch; }
    const f = fitted(view, size.vw, size.vh);
    const rect = { x: f.x * ratio, y: f.y * ratio, w: f.w * ratio, h: f.h * ratio };
    let drawn = false;
    if (gl) drawn = gl.draw(size.video, view, rect, enhance ? 0.6 : 0);
    if (!drawn) {
      // Without WebGL (or a frame WebGL refused): the browser's own scaling.
      if (gl) { gl.destroy(); gl = null; }
      const c = ctx2d ?? canvas.getContext('2d');
      if (c) {
        c.fillStyle = '#000';
        c.fillRect(0, 0, cw, ch);
        c.imageSmoothingEnabled = true;
        c.imageSmoothingQuality = 'high';
        try { c.drawImage(size.video, view.x * size.vw, view.y * size.vh, view.w * size.vw, view.h * size.vh, rect.x, rect.y, rect.w, rect.h); } catch { /* not ready */ }
      }
    }
    drawMap(size);
  }

  function drawMap(size) {
    const c = minimap.getContext('2d');
    if (!c) return;
    const mh = Math.round(minimap.width * size.vh / size.vw);
    if (minimap.height !== mh) minimap.height = mh;
    try { c.drawImage(size.video, 0, 0, minimap.width, minimap.height); } catch { return; }
    c.fillStyle = 'rgb(0 0 0 / 0.45)';
    const r = { x: view.x * minimap.width, y: view.y * minimap.height, w: view.w * minimap.width, h: view.h * minimap.height };
    c.fillRect(0, 0, minimap.width, r.y);
    c.fillRect(0, r.y + r.h, minimap.width, minimap.height - r.y - r.h);
    c.fillRect(0, r.y, r.x, r.h);
    c.fillRect(r.x + r.w, r.y, minimap.width - r.x - r.w, r.h);
    c.strokeStyle = '#f0b254';
    c.lineWidth = 2;
    c.strokeRect(r.x + 1, r.y + 1, Math.max(2, r.w - 2), Math.max(2, r.h - 2));
  }

  // Every display frame while zoomed (the picture under it may switch between live video and a recording).
  function loop() {
    if (destroyed) return;
    if (isZoomed()) draw();
    frame = requestAnimationFrame(loop);
  }

  // MARK: Pointer

  const local = (event) => { const r = host.getBoundingClientRect(); return { x: event.clientX - r.left, y: event.clientY - r.top }; };

  surface.addEventListener('pointerdown', (event) => {
    if (event.button !== 0 && event.pointerType === 'mouse') return;
    const p = local(event);
    pointers.set(event.pointerId, p);
    surface.setPointerCapture(event.pointerId);
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      pinch = { distance: Math.hypot(a.x - b.x, a.y - b.y), view0: view };
      drag = null;
      box.hidden = true;
      return;
    }
    drag = { kind: 'box', x0: p.x, y0: p.y, x1: p.x, y1: p.y, moved: false };
  });

  surface.addEventListener('pointermove', (event) => {
    if (!pointers.has(event.pointerId)) return;
    const p = local(event);
    pointers.set(event.pointerId, p);
    if (pinch && pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      const distance = Math.hypot(a.x - b.x, a.y - b.y);
      if (pinch.distance > 0) {
        const factor = distance / pinch.distance;
        pinch.distance = distance;
        zoomBy(factor, (a.x + b.x) / 2, (a.y + b.y) / 2);
      }
      return;
    }
    if (!drag) return;
    drag.x1 = p.x; drag.y1 = p.y;
    if (Math.hypot(drag.x1 - drag.x0, drag.y1 - drag.y0) >= DRAG_MIN_PX) drag.moved = true;
    if (!drag.moved) return;
    box.hidden = false;
    box.style.setProperty('--x', `${Math.min(drag.x0, drag.x1)}px`);
    box.style.setProperty('--y', `${Math.min(drag.y0, drag.y1)}px`);
    box.style.setProperty('--w', `${Math.abs(drag.x1 - drag.x0)}px`);
    box.style.setProperty('--h', `${Math.abs(drag.y1 - drag.y0)}px`);
  });

  function endPointer(event) {
    pointers.delete(event.pointerId);
    if (pinch) { if (pointers.size < 2) pinch = null; return; }
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
    const size = videoSize();
    if (!size) return;
    const a = toVideo(Math.min(d.x0, d.x1), Math.min(d.y0, d.y1), size);
    const b = toVideo(Math.max(d.x0, d.x1), Math.max(d.y0, d.y1), size);
    const cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
    // The box's larger side decides, so all of it is in the zoomed area.
    const tileAspect = host.clientWidth / Math.max(1, host.clientHeight);
    const boxW = Math.max(b.x - a.x, (b.y - a.y) * tileAspect * size.vh / size.vw);
    setView(shaped(cx, cy, boxW, size.vw, size.vh));
  }
  surface.addEventListener('pointerup', endPointer);
  surface.addEventListener('pointercancel', (event) => { pointers.delete(event.pointerId); drag = null; pinch = null; box.hidden = true; });
  // The tile's click (go back to all cameras) only for a plain click on the whole picture.
  surface.addEventListener('click', (event) => { if (isZoomed()) event.stopPropagation(); });
  surface.addEventListener('dblclick', (event) => { event.stopPropagation(); reset(); });
  surface.addEventListener('wheel', (event) => {
    event.preventDefault();
    const p = local(event);
    const delta = event.deltaMode === 1 ? event.deltaY * 33 : event.deltaY;
    zoomBy(Math.pow(WHEEL_STEP, -delta * (event.ctrlKey ? 4 : 1)), p.x, p.y);
  }, { passive: false });

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

  const resize = new ResizeObserver(() => { if (isZoomed()) setView(view); });
  resize.observe(host);

  setEnhance(enhance);
  el.dataset.zoomed = 'false';
  loop();

  return {
    el,
    reset,
    zoomed: isZoomed,
    destroy() {
      destroyed = true;
      resize.disconnect();
      if (frame !== null) cancelAnimationFrame(frame);
      gl?.destroy();
      el.remove();
    },
  };
}

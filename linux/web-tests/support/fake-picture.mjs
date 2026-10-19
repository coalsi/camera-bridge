// Canvases that record what is drawn on them, and pictures to draw: for the tests of the pages that straighten a camera's picture
// (js/live/straighten.js draws a <video> on a canvas over it, js/live/zoom.js draws the zoomed area). Use with installFakeBrowser.
import { stripPlan } from '../../web/js/live/straighten.js';

/** A 2D context that keeps every drawImage call in `draws` and does nothing for the rest (fills, strokes, its state). */
export function recording2D(canvas) {
  const target = { canvas, draws: [], drawImage(...args) { this.draws.push(args); } };
  return new Proxy(target, {
    get(context, key) {
      if (key in context) return context[key];
      return typeof key === 'string' ? () => {} : undefined;
    },
  });
}

/**
 * A recording WebGL context on `canvas`: every call is kept in `calls` (the shaders' source among them); shaders compile and programs link
 * (unless `compiles` / `links` say otherwise); its largest texture is `maxTextureSize`; a uniform's location is { name }; the constants are
 * their own names; WEBGL_lose_context's loseContext() fires `webglcontextlost` on the canvas.
 */
export function fakeGL(canvas = null, { maxTextureSize = 16384, compiles = true, links = true } = {}) {
  const calls = [];
  let lost = false;
  const known = {
    calls,
    getShaderParameter: () => compiles,
    getProgramParameter: () => links,
    getShaderInfoLog: () => 'ERROR: 0:1: fake compile error',
    getProgramInfoLog: () => 'fake link error',
    getAttribLocation: () => 0,
    getUniformLocation: (program, name) => ({ name }),
    getParameter: (name) => (name === 'MAX_TEXTURE_SIZE' ? maxTextureSize : null),
    isContextLost: () => lost,
    getExtension: (name) => (name === 'WEBGL_lose_context'
      ? { loseContext: () => { if (lost) return; lost = true; canvas?.dispatchEvent({ type: 'webglcontextlost', preventDefault() {} }); } }
      : null),
  };
  return new Proxy(known, {
    get(target, key) {
      if (key in target) return target[key];
      if (typeof key !== 'string') return undefined;
      if (/^[A-Z0-9_]+$/.test(key)) return key;
      return (...args) => { calls.push([key, ...args]); return { made: key }; };
    },
  });
}

/** The source of the fragment shader `gl` (fakeGL) was given. */
export const fragmentSource = (gl) => gl.calls.filter(([name]) => name === 'shaderSource').map(([, , text]) => text).find((text) => text.includes('gl_FragColor'));

/** The (x, y) each uniform2f call gave the uniform `name`, in order. */
export const uniform2 = (gl, name) => gl.calls.filter(([call, at]) => call === 'uniform2f' && at?.name === name).map(([, , x, y]) => [x, y]);

/**
 * Gives the fake browser's canvases a recording 2D context and, with `webgl(canvas)`, the WebGL context it makes (else none: a straightened
 * view then draws through the strip plan, where a test can read it). A canvas keeps the kind of context it was first given, as a browser's
 * does, and its width and height attributes are its size, as in a browser. -> { canvases (every canvas made, in order) }
 */
export function recordingCanvases(document, { webgl = null } = {}) {
  const canvases = [];
  const create = document.createElement;
  document.createElement = (tag) => {
    const el = create(tag);
    if (tag !== 'canvas') return el;
    Object.assign(el, { width: 300, height: 150 });
    const setAttribute = el.setAttribute.bind(el);
    el.setAttribute = (name, value) => { setAttribute(name, value); if (name === 'width' || name === 'height') el[name] = Number(value); };
    let kind = null;
    let context = null;
    el.getContext = (wanted) => {
      if (kind) return kind === wanted ? context : null;
      if (wanted === 'webgl' && webgl) context = webgl(el);
      else if (wanted === '2d') context = recording2D(el);
      if (!context) return null;
      kind = wanted;
      return context;
    };
    canvases.push(el);
    return el;
  };
  return { canvases };
}

/** `video` has a picture `width` × `height`, shown in a box `shownWidth` × `shownHeight`: what straighten.js reads before it draws. */
export function givePicture(video, { width = 640, height = 284, shownWidth = width, shownHeight = height } = {}) {
  return Object.assign(video, { videoWidth: width, videoHeight: height, readyState: 4, clientWidth: shownWidth, clientHeight: shownHeight });
}

/**
 * The drawImage calls that draw a picture straightened by `c` on a canvas `cw` × `ch` (the strip plan), the picture's own size being
 * `width` × `height`, the picture written 'picture'.
 */
export function planCalls(c, cw, ch, width = cw, height = ch) {
  const kx = width / cw, ky = height / ch;
  return stripPlan(c, cw, ch).map((r) => ['picture', r.sx * kx, r.sy * ky, r.sw * kx, r.sh * ky, r.dx, r.dy, r.dw, r.dh]);
}

/**
 * What `canvas` drew from its `from`th drawImage call on, in planCalls' terms: `source` written 'picture', anything else 'something else'
 * (a fake element holds the whole page, so a failed comparison that printed one would print all of it).
 */
export function drawnFrom(canvas, source, from = 0) {
  return canvas.getContext('2d').draws.slice(from).map(([picture, ...rest]) => [picture === source ? 'picture' : 'something else', ...rest]);
}

/** The element right after `el` among its parent's children. */
export const siblingAfter = (el) => el.parentNode?.childNodes[el.parentNode.childNodes.indexOf(el) + 1] ?? null;

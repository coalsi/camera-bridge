// Straighten the picture in the browser. A panorama stitched from two lenses bends its horizon; this draws the camera's picture with that
// curve moved onto a straight line, column by column, the top and bottom edges kept where they are (no crop, no black, same shape).
//
// The formula is PictureCorrection in Packages/CameraBridgeKit/Sources/MediaCore/PictureCorrection.swift, copied step for step, and both
// are pinned to Packages/CameraBridgeKit/Tests/MediaCoreTests/Fixtures/picture-correction-vectors.json (linux/web-tests/straighten.test.mjs).
// A correction is { straighten, level } (the spec's a and b); both 0, or none at all, is off. Resolution-free: `across` is x / W and `down`
// is y / H (pixel i's centre is (i + 0.5) / size), and sourceFraction is the row, as a fraction of the height, the colour comes from.
//
// createStraightenedView draws a <video> or <img> straightened on a canvas over it: with WebGL (the formula in the fragment shader), else,
// or once the browser takes the WebGL context back, through the 2D strip plan. Nothing here touches the page until it is called.

const SOURCE_CLASS = 'straighten-source';
const VIEW_CLASS = 'straightened';

const values = (c) => ({ a: Number(c?.straighten) || 0, b: Number(c?.level) || 0 });

/** Whether `c` changes the picture at all (both 0, or no correction, is off). */
export function isOn(c) {
  const { a, b } = values(c);
  return a !== 0 || b !== 0;
}

/** `h`: where the camera's horizon is in the column `across` (0 at the left edge, 1 at the right), as a fraction of the height. */
export function horizon(c, across) {
  const { a, b } = values(c);
  const u = 2 * across - 1;
  return Math.min(0.97, Math.max(0.03, 0.5 + a * (1 - u * u) + b * u));
}

/** `T`: the height of the straight line the horizon lands on, as a fraction of the height (the curve's average height). */
export function landing(c) {
  const { a } = values(c);
  return Math.min(0.97, Math.max(0.03, 0.5 + 2 / 3 * a));
}

/** `fs`: the row (a fraction of the camera's height) the output row `down` in the column `across` takes its colour from. */
export function sourceFraction(c, across, down) {
  // The edges are exact (the lower piece's arithmetic can land one step short of 1).
  if (down <= 0) return 0;
  if (down >= 1) return 1;
  const h = horizon(c, across);
  const t = landing(c);
  const fs = down <= t ? down * h / t : h + (down - t) * (1 - h) / (1 - t);
  return Math.min(1, Math.max(0, fs));
}

/** How much taller than the camera drew them the most stretched rows become, over 256 columns (1 when off; about 2.7 for (0.40, 0.15)). */
export function largestStretch(c) {
  const t = landing(c);
  let largest = 1;
  for (let column = 0; column < 256; column += 1) {
    const h = horizon(c, (column + 0.5) / 256);
    largest = Math.max(largest, t / h, (1 - t) / (1 - h));
  }
  return largest;
}

/**
 * The formula for a fragment shader (GLSL ES 1.0), to be included after the shader's precision statement: `straighten` is (Straighten,
 * Level), and (0, 0) is the identity. Sample the picture at vec2(across, sourceDown(across, down)).
 */
export const GLSL_STRAIGHTEN = `uniform vec2 straighten;
float sourceDown(float across, float down) {
  if (down <= 0.0) return 0.0;
  if (down >= 1.0) return 1.0;
  float u = 2.0 * across - 1.0;
  float h = clamp(0.5 + straighten.x * (1.0 - u * u) + straighten.y * u, 0.03, 0.97);
  float t = clamp(0.5 + 2.0 / 3.0 * straighten.x, 0.03, 0.97);
  float fs = down <= t ? down * h / t : h + (down - t) * (1.0 - h) / (1.0 - t);
  return clamp(fs, 0.0, 1.0);
}
`;

/**
 * The formula as drawImage rectangles, for a picture and a canvas both `width` × `height`: each strip of `step` columns is drawn in two
 * pieces, above the landing row and below it, and the formula is linear on each piece of a column, so stretching the strip's source
 * rectangle into its destination reproduces it (the horizon taken in the strip's middle). Every source rectangle stays inside the picture.
 * Off: the whole picture, once. -> [{ sx, sy, sw, sh, dx, dy, dw, dh }]
 */
export function stripPlan(c, width, height, step = 2) {
  if (!isOn(c)) return [{ sx: 0, sy: 0, sw: width, sh: height, dx: 0, dy: 0, dw: width, dh: height }];
  const columns = Math.max(1, Math.floor(step) || 1);
  const top = landing(c) * height;
  const plan = [];
  for (let dx = 0; dx < width; dx += columns) {
    const dw = Math.min(columns, width - dx);
    const h = horizon(c, (dx + dw / 2) / width) * height;
    plan.push({ sx: dx, sy: 0, sw: dw, sh: h, dx, dy: 0, dw, dh: top });
    plan.push({ sx: dx, sy: h, sw: dw, sh: height - h, dx, dy: top, dw, dh: height - top });
  }
  return plan;
}

// MARK: Drawing

const VERTEX = `attribute vec2 p; varying vec2 uv; void main() { uv = p * 0.5 + 0.5; gl_Position = vec4(p.x, -p.y, 0.0, 1.0); }`;

// highp where the graphics have it: mediump (16-bit on phones) cannot address every row of a tall picture.
const FRAGMENT = `#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 uv; uniform sampler2D picture;
${GLSL_STRAIGHTEN}
void main() { gl_FragColor = vec4(texture2D(picture, vec2(uv.x, sourceDown(uv.x, uv.y))).rgb, 1.0); }`;

/** A WebGL drawer on `canvas` (the formula in the shader, bilinear sampling); null when the browser gives no WebGL context. */
function createGLDrawer(canvas) {
  const gl = canvas.getContext('webgl', { alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false });
  if (!gl || gl.isContextLost()) return null;
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
  const uStraighten = gl.getUniformLocation(program, 'straighten');
  const largest = gl.getParameter(gl.MAX_TEXTURE_SIZE);
  return {
    gl: true,
    /**
     * Draws `source` (its own size `width` × `height`) straightened over the whole canvas; false when WebGL cannot (a lost context, a
     * picture larger than its largest texture, which it would draw black, or a picture it refuses).
     */
    draw(source, c, width, height) {
      if (gl.isContextLost() || !(width <= largest && height <= largest)) return false;
      gl.viewport(0, 0, canvas.width, canvas.height);
      try { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, source); } catch { return false; }
      const { a, b } = values(c);
      gl.uniform2f(uStraighten, a, b);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      return true;
    },
    /** Frees the context at once (a page gets only so many). */
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

/**
 * A 2D drawer on `canvas` through the strip plan (made by `planner`, stripPlan's signature); null when the browser gives no 2D context
 * either. The plan is kept while the correction and the canvas size stay the same: a video's frames reuse it.
 */
function create2DDrawer(canvas, planner) {
  const context = canvas.getContext('2d', { alpha: false });
  if (!context) return null;
  let plan = null;
  let planned = { a: NaN, b: NaN, width: 0, height: 0 };
  return {
    gl: false,
    /** Draws `source` (its own size `width` × `height`) straightened over the whole canvas; false when the browser could not draw it yet. */
    draw(source, c, width, height) {
      const { a, b } = values(c);
      if (!plan || a !== planned.a || b !== planned.b || canvas.width !== planned.width || canvas.height !== planned.height) {
        plan = planner(c, canvas.width, canvas.height);
        planned = { a, b, width: canvas.width, height: canvas.height };
      }
      const kx = width / canvas.width, ky = height / canvas.height;
      context.imageSmoothingEnabled = true;
      try {
        for (const r of plan) context.drawImage(source, r.sx * kx, r.sy * ky, r.sw * kx, r.sh * ky, r.dx, r.dy, r.dw, r.dh);
      } catch {
        return false;     // not ready
      }
      return true;
    },
    destroy() {},
  };
}

/** The canvas size for a picture `width` × `height` shown in a `boxWidth` × `boxHeight` box with `fit`: never more pixels than the picture has. */
function backingSize(fit, boxWidth, boxHeight, width, height, ratio) {
  const contain = Math.min(boxWidth / width, boxHeight / height);
  const cover = Math.max(boxWidth / width, boxHeight / height);
  const shown = fit === 'cover' || fit === 'fill' ? cover : fit === 'none' ? 1 : fit === 'scale-down' ? Math.min(1, contain) : contain;
  const scale = Math.min(1, shown * ratio);
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}

/**
 * Draws `source` (a <video> or an <img>) straightened by `correction` on a canvas inserted right after it, with the source's classes plus
 * `straightened` and the source's hidden, object-fit and object-position, so the picture sits exactly where the source's would (see-through
 * until it has drawn a picture); the source gets `straighten-source` (invisible, but a video keeps decoding and its frame callbacks keep
 * firing). A video is drawn at each of its frames, an image when it loads; both when the correction changes and when the source's size
 * does. Off, there is no canvas and nothing runs. The source must be in the page (have a parent) when the view is made or set on: one
 * without a parent is left as it is and nothing is drawn (the camera's own picture stays; a later set() tries again). `planner` is for tests
 * (stripPlan, counted).
 * -> { canvas (null while off), set(correction), destroy() }
 */
export function createStraightenedView({ source, correction, planner = stripPlan }) {
  const isVideo = source.localName === 'video';
  let current = correction;
  let canvas = null;
  let drawer = null;
  let style = null;          // the source's computed style (live)
  let frame = null;          // { id, video } the frame callback a video waits for
  let attributes = null;     // a MutationObserver on the source's class and hidden
  let resize = null;         // a ResizeObserver on the source
  let destroyed = false;

  const redraw = () => draw();

  /** The canvas takes the source's classes (but straighten-source), hidden, object-fit and object-position. */
  function sync() {
    if (!canvas) return;
    const className = [...String(source.className || '').split(/\s+/).filter((name) => name && name !== SOURCE_CLASS), VIEW_CLASS].join(' ');
    if (canvas.className !== className) canvas.className = className;
    if (canvas.hidden !== Boolean(source.hidden)) canvas.hidden = Boolean(source.hidden);
    if (style) {
      if (canvas.style.objectFit !== style.objectFit) canvas.style.objectFit = style.objectFit;
      if (canvas.style.objectPosition !== style.objectPosition) canvas.style.objectPosition = style.objectPosition;
    }
  }

  function draw() {
    if (!canvas) return;
    sync();
    const width = isVideo ? source.videoWidth : source.naturalWidth;
    const height = isVideo ? source.videoHeight : source.naturalHeight;
    if (!width || !height || (isVideo && source.readyState < 2)) return;     // no picture yet
    const boxWidth = source.clientWidth, boxHeight = source.clientHeight;
    if (!boxWidth || !boxHeight) return;                                      // not shown: drawn when it is
    const size = backingSize(style?.objectFit, boxWidth, boxHeight, width, height, window.devicePixelRatio || 1);
    if (canvas.width !== size.width) canvas.width = size.width;
    if (canvas.height !== size.height) canvas.height = size.height;
    if (drawer.draw(source, current, width, height)) {
      if (canvas.style.opacity) canvas.style.opacity = '';     // a picture: shown from now on (install)
    } else if (drawer.gl) fallBack();
  }

  function schedule() {
    if (!isVideo || !canvas || frame) return;
    if (typeof source.requestVideoFrameCallback === 'function') frame = { id: source.requestVideoFrameCallback(onFrame), video: true };
    else frame = { id: requestAnimationFrame(onFrame), video: false };
  }

  function onFrame() {
    frame = null;
    draw();
    schedule();
  }

  /** Puts `next` right after the source and hides the source; false (nothing changed) when the canvas could not be put there. */
  function install(next, nextDrawer) {
    next.setAttribute('aria-hidden', 'true');
    // See-through until it has drawn a picture: an opaque canvas (alpha: false) is black until then, over the snapshot under a tile's video.
    next.style.opacity = '0';
    source.after(next);
    if (!source.parentNode || next.parentNode !== source.parentNode) {
      nextDrawer.destroy();
      next.remove();
      return false;
    }
    canvas = next;
    drawer = nextDrawer;
    if (drawer.gl) canvas.addEventListener('webglcontextlost', fallBack);
    sync();
    source.classList.add(SOURCE_CLASS);    // only now: a source with no canvas in its place stays visible
    return true;
  }

  /**
   * WebGL cannot draw this picture (the browser took the context back, the picture is larger than its largest texture, or it refused the
   * picture): a 2D canvas takes the place of the WebGL one, for good.
   */
  function fallBack() {
    if (!canvas || !drawer.gl) return;
    const old = canvas;
    old.removeEventListener('webglcontextlost', fallBack);
    drawer.destroy();
    old.remove();
    canvas = drawer = null;
    const next = document.createElement('canvas');   // a canvas that had a WebGL context can have no other
    const flat = create2DDrawer(next, planner);
    if (!flat || !install(next, flat)) { stop(); return; }
    draw();
  }

  function start() {
    if (!source.parentNode) return;                   // nowhere to put a canvas: the camera's own picture stays
    let next = document.createElement('canvas');
    let nextDrawer = createGLDrawer(next);
    if (!nextDrawer) {
      next = document.createElement('canvas');
      nextDrawer = create2DDrawer(next, planner);
    }
    if (!nextDrawer) return;                          // no way to draw: the camera's own picture stays
    style = typeof getComputedStyle === 'function' ? getComputedStyle(source) : null;
    if (!install(next, nextDrawer)) { style = null; return; }
    if (isVideo) schedule();
    else source.addEventListener('load', redraw);
    if (typeof MutationObserver === 'function') {
      attributes = new MutationObserver(sync);
      attributes.observe(source, { attributes: true, attributeFilter: ['class', 'hidden'] });
    }
    if (typeof ResizeObserver === 'function') {
      resize = new ResizeObserver(redraw);
      resize.observe(source);
    }
    draw();
  }

  function stop() {
    if (frame) {
      if (frame.video) source.cancelVideoFrameCallback?.(frame.id);
      else cancelAnimationFrame(frame.id);
      frame = null;
    }
    source.removeEventListener('load', redraw);
    attributes?.disconnect();
    resize?.disconnect();
    attributes = resize = null;
    if (canvas) {
      canvas.removeEventListener('webglcontextlost', fallBack);
      drawer.destroy();
      canvas.remove();
    }
    canvas = drawer = style = null;
    source.classList.remove(SOURCE_CLASS);
  }

  function set(next) {
    if (destroyed) return;
    current = next;
    if (!isOn(next)) stop();
    else if (!canvas) start();
    else draw();
  }

  set(correction);
  return {
    get canvas() { return canvas; },
    set,
    destroy() { stop(); destroyed = true; },
  };
}

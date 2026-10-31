// The pan/tilt pad of the Monitor (a camera that pans and tilts, opened on its own): a tap turns the camera one step; holding an arrow
// keeps stepping until it is let go. Zoom in and out (+ and −) for a camera that zooms. Every step stops by itself, so nothing leaves a
// camera turning. Arrow keys (and + / −) work while the pad has focus.
// While an arrow is held, the next step goes out only once the bridge has answered the last one (and at most every REPEAT_MS): a slow camera
// never gets a pile of moves that keep it turning after the arrow is let go. The stop on release goes out at once.
import { post } from '../api.js';
import { h } from '../dom.js';

const DIRECTIONS = [
  { key: 'up', label: 'Tilt up', pan: 0, tilt: 1, glyph: '▲', area: 'up', keys: ['ArrowUp'] },
  { key: 'left', label: 'Pan left', pan: -1, tilt: 0, glyph: '◀', area: 'left', keys: ['ArrowLeft'] },
  { key: 'right', label: 'Pan right', pan: 1, tilt: 0, glyph: '▶', area: 'right', keys: ['ArrowRight'] },
  { key: 'down', label: 'Tilt down', pan: 0, tilt: -1, glyph: '▼', area: 'down', keys: ['ArrowDown'] },
];
const ZOOMS = [
  { key: 'zoomIn', label: 'Zoom in', zoom: 1, glyph: '+', keys: ['+', '='] },
  { key: 'zoomOut', label: 'Zoom out', zoom: -1, glyph: '−', keys: ['-', '_'] },
];
const REPEAT_MS = 500;
const SPEED = 0.6;

export function createPanTiltPad({ send: sendMove = (id, body) => post(`cameras/${id}/pan-tilt`, body), setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (t) => clearTimeout(t), now = () => performance.now() } = {}) {
  let cameraId = null;
  let held = null;      // the direction held
  let timer = null;
  let presses = 0;       // +1 for every press and release: a step's answer that comes after them starts no next step
  let problem = '';

  const status = h('p', { class: 'mon-ptz-status', role: 'status', 'aria-live': 'polite' });

  /** One request to the camera; resolves true when the bridge took it. A refusal is said under the pad and lets go of the arrow. */
  async function send(body) {
    if (!cameraId) return false;
    try {
      await sendMove(cameraId, body);
      if (problem) { problem = ''; status.textContent = ''; }
      return true;
    } catch (error) {
      problem = error.message;
      status.textContent = problem;
      release();
      return false;
    }
  }

  const step = (d) => send(d.zoom ? { pan: 0, tilt: 0, zoom: d.zoom } : { pan: d.pan * SPEED, tilt: d.tilt * SPEED });

  /** Steps while `direction` is held: the next one after the last has been answered, and no sooner than REPEAT_MS after the last began. */
  async function keepStepping(direction, mine) {
    while (held === direction && presses === mine) {
      const began = now();
      if (!(await step(direction))) return;
      if (held !== direction || presses !== mine) return;
      const rest = Math.max(0, REPEAT_MS - (now() - began));
      if (rest > 0) await new Promise((resolve) => { timer = setTimer(() => { timer = null; resolve(); }, rest); });
    }
  }

  function press(direction) {
    if (held === direction) return;
    held = direction;
    presses += 1;
    if (timer !== null) { clearTimer(timer); timer = null; }
    buttons.get(direction.key)?.setAttribute('aria-pressed', 'true');
    keepStepping(direction, presses);
  }

  function release() {
    if (!held) return;
    buttons.get(held.key)?.setAttribute('aria-pressed', 'false');
    const wasZoom = !!held.zoom;
    held = null;
    presses += 1;
    if (timer !== null) { clearTimer(timer); timer = null; }
    if (!wasZoom) send({ pan: 0, tilt: 0 });
  }

  const buttons = new Map();
  for (const d of [...DIRECTIONS, ...ZOOMS]) {
    const button = h('button', { class: `mon-ptz-btn ${d.area ?? d.key}`, type: 'button', 'aria-label': d.label, 'aria-pressed': 'false', title: d.label,
      onpointerdown: (event) => { event.preventDefault(); button.setPointerCapture?.(event.pointerId); press(d); },
      onpointerup: release, onpointercancel: release, onlostpointercapture: release,
      onkeydown: (event) => { if (event.key === ' ' || event.key === 'Enter') { event.preventDefault(); press(d); } },
      onkeyup: (event) => { if (event.key === ' ' || event.key === 'Enter') release(); },
    }, d.glyph);
    buttons.set(d.key, button);
  }
  const stop = h('button', { class: 'mon-ptz-btn stop', type: 'button', 'aria-label': 'Stop', title: 'Stop', onclick: () => { release(); send({ pan: 0, tilt: 0 }); } }, '■');

  const pad = h('div', { class: 'mon-ptz-pad', role: 'group', 'aria-label': 'Pan and tilt', tabindex: '0',
    onkeydown: (event) => {
      const d = [...DIRECTIONS, ...(zoomOn ? ZOOMS : [])].find((x) => x.keys.includes(event.key));
      if (d) { event.preventDefault(); press(d); }
    },
    onkeyup: (event) => { if ([...DIRECTIONS, ...ZOOMS].some((x) => x.keys.includes(event.key))) release(); },
    onblur: release,
  }, buttons.get('up'), buttons.get('left'), stop, buttons.get('right'), buttons.get('down'));

  let zoomOn = false;
  const zoomRow = h('div', { class: 'mon-ptz-zoom', role: 'group', 'aria-label': 'Zoom', hidden: true }, buttons.get('zoomOut'), buttons.get('zoomIn'));
  const heading = h('strong', null, 'Pan and tilt');
  const el = h('div', { class: 'mon-ptz', hidden: true },
    h('div', { class: 'mon-timeline-head' }, heading), pad, zoomRow, status);

  return {
    el,
    /** The camera the pad moves (null hides it), and whether it zooms. */
    setCamera(id, { zoom = false } = {}) {
      if (id !== cameraId) {
        release();
        cameraId = id;
        problem = '';
        status.textContent = '';
      }
      zoomOn = zoom;
      zoomRow.hidden = !zoom;
      heading.textContent = zoom ? 'Pan, tilt and zoom' : 'Pan and tilt';
      el.hidden = id === null;
    },
    destroy() { release(); },
  };
}

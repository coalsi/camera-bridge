// The pan/tilt pad of the Monitor (a camera that pans and tilts, opened on its own): a tap turns the camera one step; holding an arrow
// keeps stepping until it is let go. Zoom in and out (+ and −) for a camera that zooms. Every step stops by itself, so nothing leaves a
// camera turning. Arrow keys (and + / −) work while the pad has focus.
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

export function createPanTiltPad() {
  let cameraId = null;
  let held = null;      // the direction held
  let timer = null;
  let problem = '';

  const status = h('p', { class: 'mon-ptz-status', role: 'status', 'aria-live': 'polite' });

  async function send(pan, tilt) {
    if (!cameraId) return;
    try {
      await post(`cameras/${cameraId}/pan-tilt`, { pan, tilt });
      if (problem) { problem = ''; status.textContent = ''; }
    } catch (error) {
      problem = error.message;
      status.textContent = problem;
      release();
    }
  }

  async function sendZoom(zoom) {
    if (!cameraId) return;
    try {
      await post(`cameras/${cameraId}/pan-tilt`, { pan: 0, tilt: 0, zoom });
      if (problem) { problem = ''; status.textContent = ''; }
    } catch (error) {
      problem = error.message;
      status.textContent = problem;
      release();
    }
  }

  const step = (d) => (d.zoom ? sendZoom(d.zoom) : send(d.pan * SPEED, d.tilt * SPEED));

  function press(direction) {
    if (held === direction) return;
    held = direction;
    clearInterval(timer);
    step(direction);
    timer = setInterval(() => step(direction), REPEAT_MS);
    buttons.get(direction.key)?.setAttribute('aria-pressed', 'true');
  }

  function release() {
    if (!held) return;
    buttons.get(held.key)?.setAttribute('aria-pressed', 'false');
    const wasZoom = !!held.zoom;
    held = null;
    clearInterval(timer);
    timer = null;
    if (!wasZoom) send(0, 0);
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
  const stop = h('button', { class: 'mon-ptz-btn stop', type: 'button', 'aria-label': 'Stop', title: 'Stop', onclick: () => { release(); send(0, 0); } }, '■');

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

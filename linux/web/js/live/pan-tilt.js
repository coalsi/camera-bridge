// The pan/tilt pad of the Monitor (a camera that pans and tilts, opened on its own): hold an arrow and the camera turns; let go and it
// stops. The bridge stops a move by itself 1.5 s after the last ask, so the pad repeats it while held (a closed page never leaves the
// camera turning). Arrow keys work while the pad has focus.
import { post } from '../api.js';
import { h } from '../dom.js';

const DIRECTIONS = [
  { key: 'up', label: 'Tilt up', pan: 0, tilt: 1, glyph: '▲', area: 'up', keys: ['ArrowUp'] },
  { key: 'left', label: 'Pan left', pan: -1, tilt: 0, glyph: '◀', area: 'left', keys: ['ArrowLeft'] },
  { key: 'right', label: 'Pan right', pan: 1, tilt: 0, glyph: '▶', area: 'right', keys: ['ArrowRight'] },
  { key: 'down', label: 'Tilt down', pan: 0, tilt: -1, glyph: '▼', area: 'down', keys: ['ArrowDown'] },
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

  function press(direction) {
    if (held === direction) return;
    held = direction;
    clearInterval(timer);
    send(direction.pan * SPEED, direction.tilt * SPEED);
    timer = setInterval(() => send(direction.pan * SPEED, direction.tilt * SPEED), REPEAT_MS);
    buttons.get(direction.key)?.setAttribute('aria-pressed', 'true');
  }

  function release() {
    if (!held) return;
    buttons.get(held.key)?.setAttribute('aria-pressed', 'false');
    held = null;
    clearInterval(timer);
    timer = null;
    send(0, 0);
  }

  const buttons = new Map();
  for (const d of DIRECTIONS) {
    const button = h('button', { class: `mon-ptz-btn ${d.area}`, type: 'button', 'aria-label': d.label, 'aria-pressed': 'false', title: d.label,
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
      const d = DIRECTIONS.find((x) => x.keys.includes(event.key));
      if (d) { event.preventDefault(); press(d); }
    },
    onkeyup: (event) => { if (DIRECTIONS.some((x) => x.keys.includes(event.key))) release(); },
    onblur: release,
  }, buttons.get('up'), buttons.get('left'), stop, buttons.get('right'), buttons.get('down'));

  const el = h('div', { class: 'mon-ptz', hidden: true },
    h('div', { class: 'mon-timeline-head' }, h('strong', null, 'Pan and tilt')), pad, status);

  return {
    el,
    /** The camera the pad moves (null hides it). */
    setCamera(id) {
      if (id === cameraId) return;
      release();
      cameraId = id;
      problem = '';
      status.textContent = '';
      el.hidden = id === null;
    },
    destroy() { release(); },
  };
}

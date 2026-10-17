// Night vision: how the camera sees in the dark (Auto, Night with its IR lights on, Day with them off) and, for a camera that has one, its
// IR lamp, switched through POST cameras/:id/night-vision. Only for a camera whose status.nightVision says what it offers (the bridge leaves
// it out otherwise). The camera page shows a card (createNightVisionCard); the Monitor, beside one camera opened on its own, a few compact
// buttons (createNightVisionButtons) in the column with the pan/tilt pad (createMonitorSide). One request at a time for a camera: the
// controls stay where they are and keep the keyboard (marked unavailable) until the camera answered, then show what the bridge has, read
// back; a refusal shows the bridge's sentence.
import { api, get } from '../api.js';
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { putCamera } from '../store.js';
import { inlineError } from './common.js';

/** The modes in the order the page shows them, with the words for each (`label` on the camera page, `short` on the Monitor's buttons). */
export const NIGHT_VISION_MODES = [
  { mode: 'auto', label: 'Auto', short: 'Auto', icon: 'contrast', hint: 'The camera switches by itself when it gets dark.' },
  { mode: 'on', label: 'Night (IR on)', short: 'Night', icon: 'moon', hint: 'Black and white, with the IR lights on.' },
  { mode: 'off', label: 'Day (IR off)', short: 'Day', icon: 'sun', hint: 'Colour, with the IR lights off.' },
];

/** Every other word the controls show, in one place. */
export const NIGHT_VISION_TEXT = {
  title: 'Night vision',
  desc: 'How the camera sees in the dark.',
  light: 'IR lights',
  lightDesc: 'Turns the camera’s IR lamp on or off.',
  unknown: 'The camera hasn’t said which one it uses.',
  busy: 'Switching…',
  failed: 'The camera didn’t take the change. Try again.',
};

/** A change can wait for an ONVIF camera that is slow to answer, and for the bridge's second try; it is never endless. */
export const NIGHT_VISION_TIMEOUT_MS = 30_000;

/**
 * What the controls show for `camera`, from status.nightVision: null when it has none (or offers neither a mode nor a lamp), else
 *   modes    the modes it offers, in the page's order, each with its words
 *   mode     the mode it is in: 'auto', 'on', 'off', or null while unknown (the bridge then leaves the key out)
 *   light    it has a lamp the bridge switches; lightOn: whether it is on (null while unknown)
 *   hint     one line about the mode it is in
 */
export function nightVisionView(camera) {
  const offer = camera?.status?.nightVision;
  if (!offer || typeof offer !== 'object') return null;
  const listed = new Set(Array.isArray(offer.modes) ? offer.modes : []);
  const modes = NIGHT_VISION_MODES.filter((entry) => listed.has(entry.mode));
  const light = offer.light === true;
  if (!modes.length && !light) return null;
  const known = NIGHT_VISION_MODES.find((entry) => entry.mode === offer.mode) ?? null;
  return { modes, mode: known?.mode ?? null, light, lightOn: light && typeof offer.lightOn === 'boolean' ? offer.lightOn : null, hint: known?.hint ?? NIGHT_VISION_TEXT.unknown };
}

/** `camera` with `change` ({ mode } and/or { light }) in its status.nightVision: what to show when the camera can't be read back. */
export function withNightVision(camera, change) {
  const offer = camera?.status?.nightVision;
  if (!offer) return camera;
  const next = { ...offer };
  if (change.mode !== undefined) next.mode = change.mode;
  if (change.light !== undefined) next.lightOn = change.light;
  return { ...camera, status: { ...camera.status, nightVision: next } };
}

/**
 * The sentence for a change that didn't happen: the bridge's own (an ApiError: a 422 says what the camera did, a 409 that it can't switch
 * now, status 0 that the bridge didn't answer), else a plain one (never a script's own error text).
 */
export function nightVisionErrorText(error) {
  const message = error && typeof error === 'object' && 'status' in error && typeof error.message === 'string' ? error.message.trim() : '';
  return message || NIGHT_VISION_TEXT.failed;
}

/**
 * The requests, one at a time for each camera. `change(camera, body)` resolves { camera } (the camera as the bridge has it afterwards: the
 * answer when it is the camera, else read back, else `camera` with the change applied; also given to `apply`, which puts it in the page's
 * store) or { message } (why it didn't happen); null when a change of that camera is already on its way.
 * `deps` are for tests: send(path, body), read(path), apply(camera).
 */
export function createNightVisionRequests({
  send = (path, body) => api('POST', path, body, { timeoutMs: NIGHT_VISION_TIMEOUT_MS }),
  read = (path) => get(path),
  apply = putCamera,
} = {}) {
  const busy = new Set();   // ids of the cameras with a change on its way
  return {
    busy: (id) => busy.has(id),
    async change(camera, body) {
      const id = camera?.id;
      if (!id || busy.has(id)) return null;
      busy.add(id);
      try {
        const answer = await send(`cameras/${id}/night-vision`, body);   // the bridge answers 204; a camera in the answer is used as it is
        let updated = answer && typeof answer === 'object' && answer.id === id && answer.status ? answer : null;
        if (!updated) {
          try { updated = await read(`cameras/${id}`); } catch { updated = null; }   // the event stream brings it anyway
        }
        if (!updated || updated.id !== id) updated = withNightVision(camera, body);
        apply(updated);
        return { camera: updated };
      } catch (error) {
        return { message: nightVisionErrorText(error) };
      } finally {
        busy.delete(id);
      }
    },
  };
}

/** A control waiting for an answer keeps its place and the keyboard (a disabled one would drop the focus), marked unavailable. */
function markBusy(control, busy) {
  if (busy) control.setAttribute('aria-disabled', 'true');
  else control.removeAttribute('aria-disabled');
}

// MARK: The camera page

/**
 * The camera page's Night vision card: the modes as one segmented control with a line about the one in use, and the IR lights switch for a
 * camera with a lamp. It follows the camera in place (`update(camera)`), hidden while the camera offers no night vision (it may say so a
 * moment after it started). Returns { el, update, destroy }.
 */
export function createNightVisionCard(camera, deps) {
  const requests = createNightVisionRequests(deps);
  let current = camera;
  let problem = '';
  let shownProblem = null;
  let pendingLight = null;   // where the IR lights switch was put, while that change is on its way (the camera's own state once it answered)
  let destroyed = false;

  const buttons = new Map(NIGHT_VISION_MODES.map((entry) => [entry.mode,
    h('button', { class: 'nv-mode', type: 'button', 'aria-pressed': 'false', dataset: { mode: entry.mode }, onclick: () => choose({ mode: entry.mode }) },
      icon(entry.icon), h('span', null, entry.label))]));
  const group = h('div', { class: 'nv-modes', role: 'group', 'aria-label': NIGHT_VISION_TEXT.title }, [...buttons.values()]);
  const hint = h('p', { class: 'nv-hint' });
  const lightInput = h('input', { type: 'checkbox', role: 'switch',
    onclick: (event) => { if (requests.busy(current?.id)) event.preventDefault(); },   // a click while waiting changes nothing
    onchange: () => choose({ light: lightInput.checked }) });
  const lightRow = h('label', { class: 'switch-row nv-light' },
    h('span', { class: 'text' }, h('span', { class: 'title' }, NIGHT_VISION_TEXT.light), h('span', { class: 'desc' }, NIGHT_VISION_TEXT.lightDesc)),
    h('span', { class: 'switch' }, lightInput));
  const state = h('span', { class: 'save-state', role: 'status', 'aria-live': 'polite' });
  const errorHost = h('div', { class: 'nv-problem' });
  const el = h('div', { class: 'card nv-card', hidden: true },
    h('div', { class: 'row spread' }, h('h2', null, NIGHT_VISION_TEXT.title), state),
    h('p', { class: 'desc' }, NIGHT_VISION_TEXT.desc), group, hint, lightRow, errorHost);

  function draw() {
    const view = nightVisionView(current);
    el.hidden = !view;
    if (!view) return;
    const busy = requests.busy(current.id);
    const offered = new Set(view.modes.map((entry) => entry.mode));
    for (const [mode, button] of buttons) {
      button.hidden = !offered.has(mode);
      button.setAttribute('aria-pressed', String(mode === view.mode));
      markBusy(button, busy);
    }
    group.hidden = offered.size === 0;
    hint.hidden = offered.size === 0;
    if (hint.textContent !== view.hint) hint.textContent = view.hint;
    lightRow.hidden = !view.light;
    lightInput.checked = pendingLight ?? (view.lightOn === true);   // never back to the old place while the camera answers
    markBusy(lightInput, busy);
    el.setAttribute('aria-busy', String(busy));
    state.textContent = busy ? NIGHT_VISION_TEXT.busy : '';
    if (problem !== shownProblem) {   // drawn again only when it changes, so a screen reader hears it once
      shownProblem = problem;
      replace(errorHost, problem ? inlineError(problem) : null);
    }
  }

  async function choose(change) {
    const target = current;
    const view = nightVisionView(target);
    if (!view || requests.busy(target.id)) return;
    if (change.mode !== undefined && change.mode === view.mode) return;   // already so
    problem = '';
    if (change.light !== undefined) pendingLight = change.light;
    const pending = requests.change(target, change);
    draw();
    const result = await pending;
    pendingLight = null;   // the switch shows the lamp again: the answer's, or where it was when the camera refused
    if (destroyed) return;
    if (result?.camera && current?.id === result.camera.id) current = result.camera;
    if (result?.message) problem = result.message;
    draw();
  }

  draw();
  return {
    el,
    update(next) {
      if (destroyed || !next || next.id !== current?.id) return;
      current = next;
      draw();
    },
    destroy() { destroyed = true; },
  };
}

// MARK: The Monitor

/**
 * The Monitor's night vision buttons for the camera opened on its own: the modes as small icon buttons (their words under the icon and in the
 * tooltip) and the IR lights as a toggle. `setCamera(camera)` shows them for that camera (null, or a camera without night vision, hides
 * them); it is called on every draw of the wall and only touches the DOM when something changed. Returns { el, setCamera, destroy }.
 */
export function createNightVisionButtons(deps) {
  const requests = createNightVisionRequests(deps);
  let current = null;
  let problem = '';
  let shownProblem = '';
  let drawn = '';
  let destroyed = false;

  const modeButtons = new Map(NIGHT_VISION_MODES.map((entry) => [entry.mode,
    h('button', { class: 'mon-nv-btn', type: 'button', 'aria-pressed': 'false', 'aria-label': entry.label, title: `${entry.label}: ${entry.hint}`, dataset: { mode: entry.mode },
      onclick: () => choose({ mode: entry.mode }) },
    icon(entry.icon), h('span', { class: 'mon-nv-word', 'aria-hidden': 'true' }, entry.short))]));
  const lightState = h('span', { class: 'mon-nv-state', 'aria-hidden': 'true' });
  const lightButton = h('button', { class: 'mon-nv-btn mon-nv-light', type: 'button', 'aria-pressed': 'false', 'aria-label': NIGHT_VISION_TEXT.light,
    title: NIGHT_VISION_TEXT.lightDesc, onclick: () => choose({ light: nightVisionView(current)?.lightOn !== true }) },
  icon('bulb'), h('span', { class: 'mon-nv-word', 'aria-hidden': 'true' }, NIGHT_VISION_TEXT.light), lightState);
  const modes = h('div', { class: 'mon-nv-modes', role: 'group', 'aria-label': `${NIGHT_VISION_TEXT.title} mode` }, [...modeButtons.values()]);
  const status = h('p', { class: 'mon-ptz-status', role: 'status', 'aria-live': 'polite' });
  const el = h('div', { class: 'mon-nv', role: 'group', 'aria-label': NIGHT_VISION_TEXT.title, hidden: true },
    h('div', { class: 'mon-timeline-head' }, h('strong', null, NIGHT_VISION_TEXT.title)), modes, lightButton, status);

  function draw() {
    const view = nightVisionView(current);
    const busy = view ? requests.busy(current.id) : false;
    const key = view ? JSON.stringify([current.id, view.modes.map((entry) => entry.mode), view.mode, view.light, view.lightOn, busy, problem]) : '';
    if (key === drawn) return;
    drawn = key;
    el.hidden = !view;
    if (!view) return;
    const offered = new Set(view.modes.map((entry) => entry.mode));
    for (const [mode, button] of modeButtons) {
      button.hidden = !offered.has(mode);
      button.setAttribute('aria-pressed', String(mode === view.mode));
      markBusy(button, busy);
    }
    modes.hidden = offered.size === 0;
    lightButton.hidden = !view.light;
    lightButton.setAttribute('aria-pressed', String(view.lightOn === true));
    lightState.textContent = view.lightOn === null ? '' : view.lightOn ? 'On' : 'Off';
    markBusy(lightButton, busy);
    el.setAttribute('aria-busy', String(busy));
    status.textContent = busy ? NIGHT_VISION_TEXT.busy : problem;
    // A new refusal comes into view: in the column that scrolls (a narrower screen, with the pad above) it would be under the buttons.
    if (!busy && problem && problem !== shownProblem) status.scrollIntoView?.({ block: 'nearest' });
    shownProblem = problem;
  }

  async function choose(change) {
    const target = current;
    const view = nightVisionView(target);
    if (!view || requests.busy(target.id)) return;
    if (change.mode !== undefined && change.mode === view.mode) return;
    problem = '';
    const pending = requests.change(target, change);
    draw();
    const result = await pending;
    if (destroyed) return;
    if (current?.id === target.id) {
      if (result?.camera) current = result.camera;
      if (result?.message) problem = result.message;
    }
    draw();
  }

  return {
    el,
    /** The camera whose night vision the buttons switch (null hides them). */
    setCamera(camera) {
      if ((camera?.id ?? null) !== (current?.id ?? null)) problem = '';
      current = camera ?? null;
      draw();
    },
    destroy() { destroyed = true; },
  };
}

/**
 * The Monitor's column between the timeline and the events, for the camera opened on its own: the pan/tilt pad (`pad`, live/pan-tilt.js)
 * for a camera that turns, the night vision buttons (`buttons`, createNightVisionButtons) for one that has night vision, hidden with
 * neither. With both it says so (data-both): stacked, they are taller than the events and the row under the wall would take that height
 * from the picture, so monitor.css puts them side by side where the row is wide enough. `setCamera(camera)` (null: no camera on its own)
 * is called on every draw of the wall. Returns { el, setCamera, destroy }.
 */
export function createMonitorSide(pad, buttons) {
  const el = h('div', { class: 'mon-side', hidden: true, dataset: { both: 'false' } }, pad.el, buttons.el);
  return {
    el,
    setCamera(camera) {
      const status = camera?.status ?? null;
      const turns = status?.panTilt === true;
      pad.setCamera(turns ? camera.id : null, { zoom: status?.zoom === true });
      buttons.setCamera(camera ?? null);   // hides itself for a camera without night vision
      const night = !buttons.el.hidden;
      if (el.hidden === (turns || night)) el.hidden = !(turns || night);
      const both = String(turns && night);
      if (el.dataset.both !== both) el.dataset.both = both;
    },
    destroy() { pad.destroy(); buttons.destroy(); },
  };
}

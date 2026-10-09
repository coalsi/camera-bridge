// Pieces several screens share.
import { h } from '../dom.js';
import { icon } from '../icons.js';
import { timeAgo } from '../format.js';

/** The camera's state as one pill: what it is doing now, in the Mac app's words. */
export function statePill(camera, extraClass = '') {
  const s = camera.status;
  let kind = 'idle', text = 'Waiting', pulse = false;
  if (!camera.isEnabled) { kind = 'idle'; text = 'Turned off'; }
  else if (!s) { kind = 'idle'; text = 'Starting'; pulse = true; }
  else if (s.connection === 'online') {
    if (s.recordingNow) { kind = 'recording'; text = 'Recording'; }
    else if (s.motion) { kind = 'motion'; text = 'Motion'; }
    else { kind = 'live'; text = 'Live'; }
  } else if (s.connection === 'connecting') { kind = 'idle'; text = 'Connecting…'; pulse = true; }
  else if (s.connection === 'offline') { kind = 'offline'; text = 'Offline — retrying'; }
  else if (s.connection === 'disabled') { kind = 'idle'; text = 'Turned off'; }
  else { kind = 'idle'; text = 'Idle'; }
  return h('span', { class: `pill ${kind} ${pulse ? 'pulse' : ''} ${extraClass}` }, text);
}

/** "Added to Apple Home" or "Not added yet". */
export function homeState(camera) {
  const paired = camera.status?.paired;
  return h('span', { class: `home-state ${paired ? 'ok' : ''}` }, icon(paired ? 'check' : 'home'), paired ? 'Added to Apple Home' : 'Not added yet');
}

export function lastEventText(camera) {
  const s = camera.status;
  if (!s?.lastEvent) return '';
  return s.lastEventDate ? `${s.lastEvent} · ${timeAgo(s.lastEventDate)}` : s.lastEvent;
}

export function kindName(camera) {
  return camera.kind === 'doorbell' ? 'Video doorbell' : 'Camera';
}

export function field(label, control, { hint, error, id } = {}) {
  const controlId = id || control.id || `f-${Math.random().toString(36).slice(2, 8)}`;
  if (!control.id && control.tagName) control.id = controlId;
  return h('div', { class: 'field' }, h('label', { for: controlId }, label), control,
    hint ? h('span', { class: 'hint' }, hint) : null, error ? h('span', { class: 'error', role: 'alert' }, error) : null);
}

/** A switch row: `onchange(checked)`. */
export function switchRow({ title, desc, checked, onchange, disabled = false, id }) {
  const input = h('input', { type: 'checkbox', id, checked: !!checked, disabled, role: 'switch', onchange: () => onchange?.(input.checked) });
  const label = h('label', { class: 'switch-row' }, h('span', { class: 'text' }, h('span', { class: 'title' }, title), desc ? h('span', { class: 'desc' }, desc) : null),
    h('span', { class: 'switch' }, input));
  return label;
}

export function selectField(label, options, value, onchange, { hint } = {}) {
  const select = h('select', { onchange: () => onchange(select.value) },
    options.map(([v, text]) => h('option', { value: v, selected: v === value }, text)));
  return field(label, select, { hint });
}

export function backLink(href, text) {
  return h('a', { class: 'breadcrumb', href }, icon('back', { size: 18 }), text);
}

export function inlineError(message) {
  return h('div', { class: 'banner error', role: 'alert' }, icon('alert'), h('div', { class: 'text' }, message));
}

// The Record switch in its places, the Record card on the camera page, and the keyframe note. Every one follows the bridge's own word
// about the camera (store.cameras, kept current by the event stream), so a switch pressed in one place moves in every other place.
// Elements are updated in place and never rebuilt, so a toggle leaves keyboard focus where it was.
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { store, subscribe } from '../store.js';
import { onPending, pending, recordingView, sentence, setRecordSound, setRecording } from './record.js';

export { chooseStorage, storageCard } from './storage.js';

let sequence = 0;

const KEYFRAME_STEPS = 'To fix it, open the camera’s own settings, turn off Smart codec (also called H.264+, H.265+ or Smart Coding) and set the I-frame '
  + 'interval (also called key frame interval or GOP) to twice the frame rate, for example 40 for 20 frames a second. Video recorded after the change '
  + 'scrubs quickly; video recorded before it stays as it was.';

/** The note text the bridge reports for a camera, by id ('sound' or 'keyframe'), or ''. */
function noteText(camera, id) {
  return camera.status?.nvr?.notes?.find((note) => note.id === id)?.text || '';
}

/** The explanation shown on the camera page when recordings have long gaps between keyframes (status.nvr.notes, above 10 s), or null. */
export function keyframeNote(camera) {
  const text = noteText(camera, 'keyframe');
  if (!text) return null;
  return h('div', { class: 'banner info nvr-keyframe' }, icon('info'),
    h('div', { class: 'text' }, h('span', { class: 'title' }, sentence(text)), h('span', { class: 'small' }, KEYFRAME_STEPS)));
}

/** A switch row (the page's usual look) whose parts are updated in place. */
function switchControl({ title, onchange }) {
  const input = h('input', { type: 'checkbox', role: 'switch', onchange: () => onchange(input.checked) });
  const desc = h('span', { class: 'desc', 'aria-live': 'polite' });
  const el = h('label', { class: 'switch-row' }, h('span', { class: 'text' }, h('span', { class: 'title' }, title), desc), h('span', { class: 'switch' }, input));
  return {
    el,
    set({ checked, busy, disabled = false, text }) {
      input.checked = checked;
      input.disabled = disabled;
      input.setAttribute('aria-busy', String(Boolean(busy)));
      if (desc.textContent !== (text || '')) desc.textContent = text || '';   // the same words again are not announced again
    },
  };
}

/** Keeps `render()` current: it runs when this camera changes, and when a Record request for it starts, moves on or ends. */
function follow(id, render) {
  const stopStore = subscribe((kind, detail) => { if (kind === 'camera' && (!detail || detail.id === id)) render(); });
  const stopPending = onPending(id, render);
  return () => { stopStore(); stopPending(); };
}

/**
 * The Record switch. variant 'corner' is a button in the top right corner of a picture (its parent must be positioned); 'panel' is the same
 * button in a row of controls; 'card' is a switch row for a card. The words say what Record is doing: Record, REC, Waiting, Paused.
 * Returns { el, destroy }.
 */
export function recordSwitch(camera, { variant = 'corner' } = {}) {
  const id = camera.id;
  const latest = () => store.cameras.get(id) || camera;
  const toggle = () => { setRecording(id, !recordingView(latest(), pending(id)).on); };

  if (variant === 'card') {
    const row = switchControl({ title: 'Record', onchange: (on) => setRecording(id, on) });
    const render = () => {
      const view = recordingView(latest(), pending(id));
      row.set({ checked: view.on, busy: view.busy, text: view.line });
    };
    render();
    return { el: row.el, destroy: follow(id, render) };
  }

  const helpId = `rec-help-${++sequence}`;
  const text = h('span', { class: 'rec-text' });
  const help = h('span', { class: 'sr-only', id: helpId });
  const button = h('button', { type: 'button', role: 'switch', 'aria-describedby': helpId, onclick: toggle }, h('span', { class: 'rec-dot', 'aria-hidden': 'true' }), text);
  const el = h('span', { class: `rec-switch ${variant === 'panel' ? 'panel' : 'corner'}` }, button, help);
  const render = () => {
    const current = latest();
    const view = recordingView(current, pending(id));
    button.className = `rec-toggle ${view.kind}`;
    button.setAttribute('aria-checked', String(view.on));
    button.setAttribute('aria-busy', String(view.busy));
    button.setAttribute('aria-label', `Record ${current.name}`);
    if (view.detail) button.title = view.detail; else button.removeAttribute('title');
    text.textContent = view.chip;
    help.textContent = view.help;
  };
  render();
  return { el, destroy: follow(id, render) };
}

/** The first card in the camera page's right column: Record, Record sound, what they are doing, and the way to the recordings. Returns { el, destroy }. */
export function recordCard(camera) {
  const id = camera.id;
  const latest = () => store.cameras.get(id) || camera;
  const record = recordSwitch(camera, { variant: 'card' });
  const soundRow = switchControl({ title: 'Record sound', onchange: (on) => setRecordSound(id, on) });
  const soundNote = h('p', { class: 'rec-note small', hidden: true });
  const noteHost = h('div');
  const heading = h('h2', { id: `record-card-${++sequence}` }, 'Record');
  const el = h('section', { class: 'card nvr-card', 'aria-labelledby': heading.id },
    heading,
    h('p', { class: 'desc' }, 'Saves this camera’s video at full quality on the bridge, so you can scrub back through it. This is separate from recording in the Apple Home app.'),
    record.el, soundRow.el, soundNote, noteHost,
    h('div', { class: 'row nvr-actions' },
      h('a', { class: 'btn', href: `#/camera/${id}/watch` }, icon('film'), 'Watch recordings'),
      h('a', { class: 'btn ghost', href: '#/settings/recording' }, 'Recording settings')));

  function render() {
    const current = latest();
    const request = pending(id)?.recordSound || null;
    const soundOn = request ? request.value : current.nvrRecordSound === true;
    const audioOff = current.audioEnabled === false;
    soundRow.set({
      checked: soundOn, busy: Boolean(request), disabled: audioOff && !soundOn,
      text: audioOff ? 'Turn on Camera audio first.' : 'Saves the camera’s sound too. This page plays video only for now.',
    });
    const note = noteText(current, 'sound');
    soundNote.textContent = note ? sentence(note) : '';
    soundNote.hidden = !note;
    replace(noteHost, keyframeNote(current));
  }

  render();
  const stopFollowing = follow(id, render);
  return { el, destroy() { stopFollowing(); record.destroy(); } };
}

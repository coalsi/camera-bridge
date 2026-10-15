// Turning Record and Record sound on and off. One request at a time for each camera, in the order the person pressed; every wait is
// explained (a slow bridge is named after 3 seconds) and none is endless (a lost answer is given up after 30 seconds).
import { api } from '../api.js';
import { toast } from '../dom.js';
import { putCamera } from '../store.js';
import { chooseStorage } from './storage.js';

export const SLOW_AFTER_MS = 3000;
export const ABANDON_AFTER_MS = 30000;
export const SLOW_TEXT = 'The bridge is busy applying a camera change';

/** "waiting for the camera" -> "Waiting for the camera." The bridge words its short states in lower case, without a full stop. */
export function sentence(text) {
  const trimmed = String(text ?? '').trim();
  if (!trimmed) return '';
  const capital = trimmed[0].toUpperCase() + trimmed.slice(1);
  return /[.!?]$/.test(capital) ? capital : `${capital}.`;
}

/**
 * What Record shows for a camera, as plain data, so every place that shows it agrees. `pending` is what `recorder.pending(id)` returns.
 *   on     the switch position (the answer being waited for, else what the bridge has)
 *   kind   'off' | 'rec' | 'wait' | 'paused'   (colour and shape of the chip)
 *   chip   the few words on the chip ("Record", "REC", "Waiting", "Paused", "Starting…")
 *   line   one sentence for the Record card
 *   detail why it is waiting or paused, or null
 */
export function recordingView(camera, pending = null) {
  const stored = camera?.nvrEnabled === true;
  const request = pending?.enabled || null;
  const on = request ? request.value : stored;
  if (request) {
    const line = `Turning ${request.value ? 'on' : 'off'}…${request.slow ? ` ${SLOW_TEXT}.` : ''}`;
    return { on, busy: true, slow: request.slow, kind: 'wait', chip: request.value ? 'Starting…' : 'Stopping…', line, detail: request.slow ? `${SLOW_TEXT}.` : null, help: line };
  }
  if (!stored) return { on, busy: false, slow: false, kind: 'off', chip: 'Record', line: 'Off', detail: null, help: 'Record is off' };
  const nvr = camera.status?.nvr || null;
  const state = nvr?.state === 'recording' || nvr?.state === 'paused' ? nvr.state : 'waiting';
  if (state === 'recording') {
    return { on, busy: false, slow: false, kind: 'rec', chip: 'REC', line: 'Saving video now', detail: null, help: 'Recording to this bridge' };
  }
  const detail = sentence(nvr?.detail) || (state === 'paused' ? 'Recording is paused.' : 'Waiting for the camera.');
  return { on, busy: false, slow: false, kind: state === 'paused' ? 'paused' : 'wait', chip: state === 'paused' ? 'Paused' : 'Waiting', line: detail, detail, help: detail };
}

/**
 * The recorder. Everything it touches comes in through `deps`, so the tests drive it with fakes and a clock they move by hand.
 *   patchCamera(id, body, signal) -> Promise<camera>     PATCH cameras/:id/nvr
 *   readCamera(id)                -> Promise<camera>     GET cameras/:id
 *   chooseStorage({ reason })     -> Promise<boolean>    the "Where should recordings be stored?" dialog
 *   applyCamera(camera)                                  puts the answer where the rest of the page sees it
 *   notify(message, kind)                                a toast
 */
export function createRecorder({ patchCamera, readCamera, chooseStorage: ask, applyCamera, notify, setTimer = setTimeout, clearTimer = clearTimeout }) {
  const chains = new Map();      // camera id -> the end of that camera's queue
  const entries = new Map();     // camera id -> { enabled, recordSound }, each null or { value, outstanding, slow }
  const listeners = new Map();   // camera id -> Set of functions

  const entryFor = (id) => {
    if (!entries.has(id)) entries.set(id, { enabled: null, recordSound: null });
    return entries.get(id);
  };

  function emit(id) {
    for (const fn of [...(listeners.get(id) || [])]) {
      try { fn(pending(id)); } catch (error) { console.error(error); }
    }
  }

  /** What is being applied for the camera, or null: { enabled: { value, slow } | null, recordSound: { value, slow } | null }. */
  function pending(id) {
    const entry = entries.get(id);
    if (!entry || (!entry.enabled && !entry.recordSound)) return null;
    const copy = (item) => (item ? { value: item.value, slow: item.slow } : null);
    return { enabled: copy(entry.enabled), recordSound: copy(entry.recordSound) };
  }

  /** fn(pending) runs whenever the camera's pending state changes; returns the function that stops it. */
  function onPending(id, fn) {
    if (!listeners.has(id)) listeners.set(id, new Set());
    listeners.get(id).add(fn);
    return () => listeners.get(id)?.delete(fn);
  }

  function begin(id, field, value) {
    const entry = entryFor(id);
    entry[field] = { value, outstanding: (entry[field]?.outstanding ?? 0) + 1, slow: false };
    emit(id);
  }

  function end(id, field) {
    const entry = entryFor(id);
    const item = entry[field];
    if (!item) return;
    entry[field] = item.outstanding <= 1 ? null : { ...item, outstanding: item.outstanding - 1, slow: false };
    emit(id);
  }

  function markSlow(id, field) {
    const item = entryFor(id)[field];
    if (!item) return;
    item.slow = true;
    emit(id);
  }

  /** One PATCH, with the two clocks: the bridge is called slow after 3 s, and the request is given up after 30 s. */
  async function send(id, field, body) {
    const controller = new AbortController();
    const slow = setTimer(() => { markSlow(id, field); notify(SLOW_TEXT, ''); }, SLOW_AFTER_MS);
    const abandon = setTimer(() => controller.abort(), ABANDON_AFTER_MS);
    try {
      return await patchCamera(id, body, controller.signal);
    } finally {
      clearTimer(slow);
      clearTimer(abandon);
    }
  }

  async function fail(id, field, value, error) {
    if (error?.status === 401) return;   // the page is signing out
    if (error?.name === 'AbortError') {
      try { applyCamera(await readCamera(id)); } catch { /* the bridge's next event shows how it ended */ }
      const what = field === 'enabled' ? 'Record' : 'Record sound';
      notify(`The bridge didn’t answer in time. ${what} may still turn ${value ? 'on' : 'off'}; check the switch in a moment.`, '');
      return;
    }
    notify(error?.message || 'That change could not be made.', 'error');
  }

  async function apply(id, field, value) {
    const body = field === 'enabled' ? { enabled: value } : { recordSound: value };
    try {
      let camera;
      try {
        camera = await send(id, field, body);
      } catch (error) {
        // No place to store recordings yet: ask where, then say it again. Cancel sends nothing at all.
        const needsFolder = field === 'enabled' && value === true && error?.status === 409 && error.code === 'folder_required';
        if (!needsFolder) throw error;
        if (!(await ask({ reason: 'record' }))) return false;
        camera = await send(id, field, body);
      }
      applyCamera(camera);
      return true;
    } catch (error) {
      await fail(id, field, value, error);
      return false;
    } finally {
      end(id, field);
    }
  }

  function request(id, field, value) {
    begin(id, field, value);   // the switch shows the new position at once
    const previous = chains.get(id) || Promise.resolve();
    const result = previous.then(() => apply(id, field, value));
    const tail = result.then(() => {}, () => {});
    chains.set(id, tail);
    tail.then(() => { if (chains.get(id) === tail) chains.delete(id); });
    return result;
  }

  return {
    setRecording: (id, on) => request(id, 'enabled', Boolean(on)),
    setRecordSound: (id, on) => request(id, 'recordSound', Boolean(on)),
    pending,
    onPending,
  };
}

const recorder = createRecorder({
  patchCamera: (id, body, signal) => api('PATCH', `cameras/${id}/nvr`, body, { signal }),
  readCamera: (id) => api('GET', `cameras/${id}`),
  chooseStorage,
  applyCamera: putCamera,
  notify: (message, kind = '') => toast(message, kind),
});

/** Turns Record on or off for a camera. Resolves true when the bridge applied it, false when it did not (cancelled, refused, or lost). */
export const setRecording = (cameraId, on) => recorder.setRecording(cameraId, on);
/** Turns Record sound on or off. Resolves true when the bridge applied it. */
export const setRecordSound = (cameraId, on) => recorder.setRecordSound(cameraId, on);
export const pending = (cameraId) => recorder.pending(cameraId);
export const onPending = (cameraId, fn) => recorder.onPending(cameraId, fn);

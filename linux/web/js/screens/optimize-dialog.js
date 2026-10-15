// "Make scrubbing smoother": the confirm dialog for the smart-codec fix. The fix is the HomeKit optimizer, not a key-frame-only change, so the dialog
// says what it can change, that the camera restarts its stream, and that it can be undone. The POST is sent once and never retried.
import { api, onAuthChange } from '../api.js';
import { h, modal, replace, spinner } from '../dom.js';
import { icon } from '../icons.js';

export const OPTIMIZE_TIMEOUT_MS = 120_000;

export const WHAT_IT_CAN_CHANGE = [
  'Lowers the main stream to 6 Mbit/s if it is higher.',
  'Changes H.265 to H.264 if the camera uses H.265.',
  'Keeps the frame rate between 15 and 25 frames a second.',
  'Changes the video profile if the camera uses B-frames.',
  'Adjusts the sub stream in the same way.',
];

export const MANUAL_STEPS = [
  'Open the camera’s own settings page or app and go to the video settings of the main stream.',
  'Turn off Smart Codec, H.264+ or H.265+ (the name differs by brand; some call it Dynamic GOP or U-Code).',
  'Set the I-frame (key frame) interval to twice the frame rate, for example 40 at 20 frames a second. That is a key frame every 2 seconds.',
  'Save. Recordings made from now on scrub smoothly; older ones keep their long interval.',
];

/** The answer of POST cameras/:id/optimize as the dialog shows it. */
export function describeOptimizeResult(result) {
  const applied = Array.isArray(result?.applied) ? result.applied.filter((a) => a && a.title) : [];
  const failed = Array.isArray(result?.failed) ? result.failed.filter((f) => f && f.reason) : [];
  return {
    applied,
    failed,
    canUndo: result?.canUndo === true && applied.length > 0,
    reenable: result?.mayNeedRecordingReEnabled === true,
    outcome: applied.length > 0 ? 'applied' : 'failed',
  };
}

/** One sentence for whatever went wrong. */
export function optimizeErrorText(error) {
  if (error?.code === 'optimize_busy' || error?.status === 409) return 'This camera is already being changed. Try again in a minute.';
  if (error?.code === 'timeout') return 'The bridge didn’t answer in two minutes. The camera may still be changing: check it before trying again.';
  if (error?.code === 'not_found' || error?.status === 404) return 'This bridge’s software doesn’t have the camera optimizer yet.';
  if (error?.code === 'optimize_failed') return error.message || 'The camera didn’t accept the changes. Nothing was changed.';
  return error?.message || 'Something went wrong. Nothing was changed.';
}

/** Resolves 'applied' (something changed and stayed), 'cancelled' (nothing changed, or it was undone) or 'failed'. */
export function optimizeDialog(camera) {
  const state = { outcome: 'cancelled' };
  return modal((close) => {
    const box = h('div', { class: 'nvr-optimize' });
    const stopAuth = onAuthChange(() => close(state.outcome));          // signed out: the dialog goes with the session
    queueMicrotask(() => box.closest('dialog')?.addEventListener('close', stopAuth, { once: true }));
    const buttons = (...items) => h('div', { class: 'buttons' }, items);
    const button = (text, onclick, { primary = false, danger = false, autofocus = false } = {}) =>
      h('button', { class: `btn${primary ? ' primary' : ''}${danger ? ' danger' : ''}`, type: 'button', autofocus, onclick }, text);

    function working(text) {
      replace(box, h('h2', null, 'Please wait'), h('div', { class: 'row' }, spinner(), h('span', null, text)),
        h('p', { class: 'muted small' }, 'Don’t close this page. It can take up to a minute.'));
      const dialog = box.closest('dialog');
      if (dialog && !dialog.dataset.locked) {
        dialog.dataset.locked = '1';
        dialog.addEventListener('cancel', (event) => { if (dialog.dataset.locked === '1') event.preventDefault(); });
      }
    }
    const unlock = () => { const dialog = box.closest('dialog'); if (dialog) dialog.dataset.locked = '0'; };

    function problem(text) {
      unlock();
      replace(box, h('h2', null, 'Nothing was changed'), h('div', { class: 'banner error', role: 'alert' }, icon('alert'), h('div', { class: 'text' }, text)),
        buttons(button('Close', () => close(state.outcome), { primary: true, autofocus: true })));
    }

    function done(info) {
      unlock();
      state.outcome = info.outcome;
      replace(box,
        h('h2', null, info.applied.length ? 'Camera settings changed' : 'Nothing could be changed'),
        info.applied.length ? h('ul', { class: 'events' }, info.applied.map((a) => h('li', null, a.title))) : null,
        info.failed.length ? h('div', null, h('p', { class: 'small muted' }, 'These could not be changed:'),
          h('ul', { class: 'events' }, info.failed.map((f) => h('li', null, f.reason)))) : null,
        info.applied.length ? h('p', null, 'The camera restarted its stream, so recording has a short gap. Recordings made from now on scrub better; older ones keep their long interval.') : null,
        info.reenable ? h('p', { class: 'small muted' }, 'Home recording may need to be turned off and on again for this camera in the Home app.') : null,
        buttons(info.canUndo ? button('Undo changes', undo, { danger: true }) : null, button('Done', () => close(state.outcome), { primary: true, autofocus: true })));
    }

    async function apply() {
      working('Applying the changes on the camera…');
      try {
        done(describeOptimizeResult(await api('POST', `cameras/${camera.id}/optimize`, { confirm: true }, { timeoutMs: OPTIMIZE_TIMEOUT_MS })));
      } catch (error) {
        state.outcome = 'failed';
        problem(optimizeErrorText(error));
      }
    }

    async function undo() {
      working('Undoing the changes…');
      try {
        await api('POST', `cameras/${camera.id}/optimize/undo`, {}, { timeoutMs: OPTIMIZE_TIMEOUT_MS });
        state.outcome = 'cancelled';
        unlock();
        replace(box, h('h2', null, 'Changes undone'), h('p', null, 'The camera’s settings are back as they were.'),
          buttons(button('Done', () => close(state.outcome), { primary: true, autofocus: true })));
      } catch (error) {
        problem(optimizeErrorText(error));
      }
    }

    replace(box,
      h('h2', null, 'Make scrubbing smoother?'),
      h('p', null, 'Recordings scrub best when the camera sends a key frame every 2 seconds. This camera sends them much further apart.'),
      h('p', null, 'This runs the same optimizer Camera Bridge uses to prepare cameras for Apple Home. It is not a key-frame-only fix, so it can change more than the interval:'),
      h('ul', { class: 'steps' }, WHAT_IT_CAN_CHANGE.map((line) => h('li', null, line))),
      h('p', null, 'The camera restarts its stream, so recording has a short gap, and only recordings made afterwards scrub better. You can undo it right afterwards.'),
      h('details', { class: 'small' }, h('summary', null, 'Or do it by hand on the camera'), h('ol', { class: 'steps' }, MANUAL_STEPS.map((line) => h('li', null, line)))),
      buttons(button('Cancel', () => close('cancelled'), { autofocus: true }), button('Apply changes', apply, { primary: true })));
    return box;
  }, { label: 'Make scrubbing smoother' }).then((value) => value ?? state.outcome);
}

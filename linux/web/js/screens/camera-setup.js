// "Set up for Camera Bridge": one camera made right for the bridge in one step, with a look before any change, one backup and a way back
// (docs/superpowers/specs/2026-10-16-camera-setup-design.md). The page never runs it by itself: the person presses the button, sees every
// change, and confirms. Each POST is sent once and never retried.
import { api } from '../api.js';
import { h, modal, replace, spinner } from '../dom.js';
import { icon } from '../icons.js';

/** Every name the setup shows, in one table, so it can be renamed in one place. */
export const SETUP_TEXT = {
  button: 'Set up for Camera Bridge',
  section: 'Camera setup',
  restore: 'Restore original settings',
  setUp: (version) => `Set up for Camera Bridge (${version})`,
  notSetUp: 'Not set up',
  unfinished: 'Setup did not finish',
};

/** The cameras the setup works with (the bridge reaches them through their own API or ONVIF). */
export const SETUP_VENDORS = new Set(['hikvision', 'onvif', 'reolink', 'amcrest']);

export const SETUP_READ_TIMEOUT_MS = 60_000;
export const SETUP_TIMEOUT_MS = 180_000;

const STATUS = {
  willChange: ['Will change', 'info'],
  alreadyRight: ['Already right', 'live'],
  notSupported: ['Not supported by this camera', 'idle'],
  notOffered: ['Not offered here', 'idle'],
  done: ['Done', 'live'],
  refused: ['The camera refused', 'offline'],
  notRun: ['Not run', 'idle'],
  restored: ['Restored', 'live'],
};

export function setupSupported(camera) {
  return SETUP_VENDORS.has(camera?.vendor);
}

/** "Set up for Camera Bridge (1) on 16 Oct 2026", "Setup did not finish" or "Not set up". */
export function setupStatusLine(camera, locale) {
  const state = camera?.setupState;
  if (!state) return SETUP_TEXT.notSetUp;
  if (!state.applied) return SETUP_TEXT.unfinished;
  const date = new Date(state.applied);
  const when = Number.isNaN(date.getTime()) ? '' : ` on ${date.toLocaleDateString(locale, { day: 'numeric', month: 'short', year: 'numeric' })}`;
  return `${SETUP_TEXT.setUp(state.version || 1)}${when}`;
}

/** One step as the page shows it: its title, the status in words, the changes ("Main stream: H.265 … → H.264 …") and why. */
export function describeStep(step) {
  const [statusText, tone] = STATUS[step?.status] || [String(step?.status || ''), 'idle'];
  const changes = Array.isArray(step?.changes) ? step.changes.filter((c) => c && c.label) : [];
  const lines = changes.map((c) => `${c.label}: ${c.now} → ${c.after}`);
  let detail = typeof step?.detail === 'string' && step.detail ? step.detail : null;
  if (step?.status === 'notSupported' && detail === 'not supported by this camera') detail = null;   // the status says it
  if (step?.status === 'done' && detail && /^via /.test(detail)) detail = null;                         // how is not news
  return { id: step?.id, title: step?.title || '', statusText, tone, lines, detail: detail ? sentence(detail) : null, needsRestart: step?.needsRestart === true };
}

/** A summary of a preview or a run for the dialog's text. */
export function summarize(report) {
  const steps = Array.isArray(report?.steps) ? report.steps : [];
  const count = (status) => steps.filter((s) => s.status === status).length;
  return {
    toChange: count('willChange'),
    done: count('done'),
    refused: count('refused'),
    restored: count('restored'),
    stoppedAt: steps.find((s) => s.id === report?.stoppedAt)?.title || null,
    needsRestart: steps.some((s) => s.needsRestart === true),
    canRestore: report?.canRestore === true,
    streamRestarted: report?.streamRestarted === true,
    reenable: report?.mayNeedRecordingReEnabled === true,
    streamsWillChange: steps.some((s) => s.id === 'streams' && s.status === 'willChange'),
  };
}

function sentence(text) {
  const trimmed = text.trim();
  if (!trimmed) return trimmed;
  const first = trimmed[0].toUpperCase() + trimmed.slice(1);
  return /[.!?)]$/.test(first) ? first : `${first}.`;
}

function stepList(report) {
  const steps = (report?.steps || []).map(describeStep);
  return h('ul', { class: 'events setup-steps' }, steps.map((step) => h('li', null,
    h('div', null, h('div', { class: 'title' }, step.title),
      step.lines.map((line) => h('div', { class: 'change' }, line)),
      step.detail ? h('div', { class: 'change' }, step.detail) : null,
      step.needsRestart ? h('div', { class: 'change' }, 'Applies after the camera restarts.') : null),
    h('span', { class: `pill ${step.tone}` }, step.statusText))));
}

/** One sentence for whatever went wrong. */
export function setupErrorText(error) {
  if (error?.code === 'camera_setup_busy' || error?.status === 409) return 'This camera’s settings are already being changed. Try again in a minute.';
  if (error?.code === 'timeout') return 'The bridge didn’t answer in time. The camera may still be changing: open this page again before trying again.';
  if (error?.code === 'not_found' || error?.status === 404) return 'This bridge’s software doesn’t have the camera setup yet, or the camera was removed.';
  return error?.message || 'Something went wrong.';
}

/**
 * The setup's dialog: reads the camera, shows every change (now → after), applies on confirmation, and shows what was done. `restore: true`
 * opens it on "Restore original settings" instead. Resolves 'applied', 'restored', 'cancelled' or 'failed'.
 */
export function cameraSetupDialog(camera, { restore = false } = {}) {
  const state = { outcome: 'cancelled' };
  return modal((close) => {
    const box = h('div', { class: 'camera-setup' });
    const buttons = (...items) => h('div', { class: 'buttons' }, items);
    const button = (text, onclick, { primary = false, danger = false, autofocus = false } = {}) =>
      h('button', { class: `btn${primary ? ' primary' : ''}${danger ? ' danger' : ''}`, type: 'button', autofocus, onclick }, text);
    const dialog = () => box.closest('dialog');
    const lock = (on) => {
      const d = dialog();
      if (!d) return;
      d.dataset.locked = on ? '1' : '0';
      if (!d.dataset.guarded) {
        d.dataset.guarded = '1';
        d.addEventListener('cancel', (event) => { if (d.dataset.locked === '1') event.preventDefault(); });
      }
    };

    function working(text, wait) {
      lock(true);
      replace(box, h('h2', null, 'Please wait'), h('div', { class: 'row' }, spinner(), h('span', null, text)),
        wait ? h('p', { class: 'muted small' }, wait) : null);
    }

    function problem(title, text) {
      lock(false);
      replace(box, h('h2', null, title), h('div', { class: 'banner error', role: 'alert' }, icon('alert'), h('div', { class: 'text' }, text)),
        buttons(button('Close', () => close(state.outcome), { primary: true, autofocus: true })));
    }

    async function load() {
      working('Reading the camera’s settings…', 'Nothing is changed yet.');
      try {
        preview(await api('GET', `cameras/${camera.id}/setup`, undefined, { timeoutMs: SETUP_READ_TIMEOUT_MS }));
      } catch (error) {
        problem('The camera’s settings could not be read', setupErrorText(error));
      }
    }

    function preview(report) {
      lock(false);
      const info = summarize(report);
      replace(box,
        h('h2', null, info.toChange ? `${SETUP_TEXT.button}?` : 'Nothing to change'),
        h('p', null, info.toChange
          ? `Here is what changes on “${camera.name}”. Nothing has changed yet. The current settings are saved first, so “${SETUP_TEXT.restore}” can put every one back.`
          : `“${camera.name}” is already set up the way Camera Bridge wants it, or the camera can’t change the rest.`),
        stepList(report),
        info.streamsWillChange ? h('p', { class: 'small muted' }, 'The camera restarts its stream, so recording has a short gap.') : null,
        h('p', { class: 'small muted' }, 'Camera Bridge never changes the camera’s address, ports, users or passwords, and never restarts it.'),
        buttons(
          report?.canRestore ? button(`${SETUP_TEXT.restore}…`, () => confirmRestore(), { danger: true }) : null,
          button(info.toChange ? 'Cancel' : 'Close', () => close(state.outcome), { autofocus: true }),
          info.toChange ? button('Apply changes', apply, { primary: true }) : null));
    }

    function result(report, { restored = false } = {}) {
      lock(false);
      const info = summarize(report);
      const title = restored
        ? (info.refused ? 'Some settings could not be put back' : 'Original settings restored')
        : (info.refused ? 'The setup stopped' : info.done ? 'Camera set up' : 'Nothing was changed');
      replace(box,
        h('h2', null, title),
        info.stoppedAt ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' },
          `The camera refused “${info.stoppedAt}”, so the setup stopped there. The changes before it stay; “${SETUP_TEXT.restore}” puts them back.`)) : null,
        restored && info.refused ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' },
          'The saved values the camera didn’t take back are kept, so you can try again.')) : null,
        stepList(report),
        info.needsRestart ? h('p', { class: 'small muted' }, 'The camera says some changes apply after it restarts. Restart it from its own web page when it suits you; Camera Bridge doesn’t restart cameras.') : null,
        info.streamRestarted ? h('p', { class: 'small muted' }, 'The camera’s stream restarted, so recording had a short gap.') : null,
        info.reenable ? h('p', { class: 'small muted' }, 'Home recording may need to be turned off and on again for this camera in the Home app.') : null,
        buttons(
          !restored && info.canRestore ? button(`${SETUP_TEXT.restore}…`, () => confirmRestore(), { danger: true }) : null,
          button('Done', () => close(state.outcome), { primary: true, autofocus: true })));
    }

    async function apply() {
      working('Changing the camera’s settings…', 'Don’t close this page. It can take up to a minute.');
      try {
        const report = await api('POST', `cameras/${camera.id}/setup`, { confirm: true }, { timeoutMs: SETUP_TIMEOUT_MS });
        state.outcome = summarize(report).done ? 'applied' : state.outcome;
        result(report);
      } catch (error) {
        state.outcome = 'failed';
        problem('The setup did not run', setupErrorText(error));
      }
    }

    function confirmRestore() {
      lock(false);
      replace(box,
        h('h2', null, `${SETUP_TEXT.restore}?`),
        h('p', null, `Every setting the setup changed on “${camera.name}” is written back as the camera had it: its streams, its own labels, its clock, and its cloud and UPnP.`),
        buttons(button('Cancel', () => close(state.outcome), { autofocus: true }), button(SETUP_TEXT.restore, restoreNow, { danger: true })));
    }

    async function restoreNow() {
      working('Putting the camera’s settings back…', 'Don’t close this page. It can take up to a minute.');
      try {
        const report = await api('POST', `cameras/${camera.id}/setup/restore`, { confirm: true }, { timeoutMs: SETUP_TIMEOUT_MS });
        state.outcome = 'restored';
        result(report, { restored: true });
      } catch (error) {
        state.outcome = 'failed';
        problem('The settings were not put back', setupErrorText(error));
      }
    }

    queueMicrotask(() => (restore ? confirmRestore() : load()));
    replace(box, h('div', { class: 'checking' }, spinner()));
    return box;
  }, { label: SETUP_TEXT.button }).then((value) => value ?? state.outcome);
}

/** The local-only help: what the setup turned off, and the router steps that survive a factory reset. No camera change. */
export function localOnlyCard(camera) {
  const steps = camera?.setupState?.steps || [];
  const off = ['cloud', 'upnp'].filter((id) => steps.some((s) => s.id === id && (s.status === 'done' || s.status === 'alreadyRight')));
  const names = { cloud: 'its cloud (Hik-Connect)', upnp: 'UPnP' };
  const address = camera?.endpoint?.host ? ` (${camera.endpoint.host})` : '';
  return h('details', { class: 'local-only' },
    h('summary', null, h('h3', { class: 'section-title' }, 'Keep this camera local')),
    h('p', { class: 'desc' }, off.length
      ? `The setup turned off ${off.map((id) => names[id]).join(' and ')} on this camera. A factory reset turns them on again, so also do one of these on your router:`
      : 'Camera Bridge needs no internet to show or record this camera. To keep the camera itself off the internet, do one of these on your router (they stay in place even after a factory reset):'),
    h('ol', { class: 'steps' },
      h('li', null, `Block this camera’s internet: give it a fixed address${address} with a DHCP reservation, then block that address from the internet in the router’s firewall or parental controls.`),
      h('li', null, 'Or put your cameras on a network of their own (a camera VLAN or a guest network) that reaches Camera Bridge but not the internet.')),
    h('p', { class: 'small muted' }, 'What stops working: the maker’s phone app away from home, and its cloud recordings and alerts. Camera Bridge, Apple Home and your recordings keep working.'));
}

/** The camera page's section: the status line, the button, Restore, and the local-only help. `onDone` runs after the dialog changed something. */
export function cameraSetupCard(camera, { onDone } = {}) {
  const state = camera.setupState;
  const unfinished = state && !state.applied;
  const canRestore = Boolean(camera.setupBackup);
  const open = async (restore) => {
    const outcome = await cameraSetupDialog(camera, { restore });
    if (outcome !== 'cancelled') onDone?.(outcome);
  };
  return h('div', { class: 'card camera-setup-card' },
    h('h2', null, SETUP_TEXT.section),
    h('div', { class: 'row' }, h('span', { class: `pill ${state?.applied ? 'live' : unfinished ? 'warning' : 'plain'}` }, setupStatusLine(camera))),
    h('p', { class: 'desc' }, 'Makes this camera right for the bridge in one step: streams for recording, Apple Home and live view, no labels of its own, the bridge’s time zone and time, and the maker’s cloud and UPnP off. You see every change first, and can put everything back.'),
    unfinished ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' },
      `The last setup didn’t finish (the bridge restarted during it). Run it again to finish, or restore the original settings.`)) : null,
    h('div', { class: 'row' },
      h('button', { class: 'btn small primary', type: 'button', onclick: () => open(false) }, icon('sliders'), `${SETUP_TEXT.button}…`),
      canRestore ? h('button', { class: 'btn small', type: 'button', onclick: () => open(true) }, icon('refresh'), `${SETUP_TEXT.restore}…`) : null),
    localOnlyCard(camera));
}

// "Set up for Camera Bridge": one camera made right for the bridge in one step, with a look before any change, one backup and a way back
// (docs/superpowers/specs/2026-10-16-camera-setup-design.md). The page never runs it by itself: the person presses the button, sees every
// change, and confirms. Each POST is sent once and never retried. "Restart the camera now" (in the setup's result and on the Security card)
// is there only while the camera waits for a restart to apply a change it took, and restarts it only once pressed and confirmed.
import { api } from '../api.js';
import { h, modal, replace, spinner } from '../dom.js';
import { icon } from '../icons.js';
import { MANUAL_TEXT, manualHelpBlock, manualHelpView } from './manual-help.js';
import { GUARD_TEXT } from './security.js';

/** Every name the setup shows, in one table, so it can be renamed in one place. */
export const SETUP_TEXT = {
  button: 'Set up for Camera Bridge',
  section: 'Camera setup',
  restore: 'Restore original settings',
  setUp: (version) => `Set up for Camera Bridge (${version})`,
  notSetUp: 'Not set up',
  unfinished: 'Setup did not finish',
  /** Under a preview that will point the camera's DNS at the bridge (the Internet guard blocks every lookup at once). */
  watchNote: `“${GUARD_TEXT.watchStep}” points the camera’s internet lookups at Camera Bridge, which blocks every one, so the maker’s app stops working `
    + 'away from home. Camera Bridge, Apple Home and your recordings keep working.',
  /** What Restore writes back. */
  restoreWhat: `its streams, its own labels, its clock, its internet lookups (${GUARD_TEXT.watch}) and any address it fixed (back on DHCP), its video password `
    + 'and extra services, and its cloud and UPnP',
};

/** The cameras the setup works with (the bridge reaches them through their own API or ONVIF). */
export const SETUP_VENDORS = new Set(['hikvision', 'onvif', 'reolink', 'amcrest']);

export const SETUP_READ_TIMEOUT_MS = 60_000;
export const SETUP_TIMEOUT_MS = 180_000;
/** The camera answers a restart before it goes offline. */
export const RESTART_TIMEOUT_MS = 30_000;

/** "Restart the camera now": its words, in one table. */
export const RESTART_TEXT = {
  button: 'Restart the camera now',
  why: 'The camera says some changes apply after it restarts.',
  confirm: (name) => `Restart it now? “${name}” goes offline for about a minute: no live view and no recording until it is back.`,
  yes: 'Restart',
  cancel: 'Cancel',
  working: 'Asking the camera to restart…',
  sent: 'The camera is restarting. It is back in about a minute.',
  failed: 'The camera wasn’t restarted. Try again.',
};

/** "Fix its address so the DNS stays": its words, in one table. `a` is the camera's address as the bridge read it (`address`, `subnetMask`,
 *  `gateway`, and `hardwareAddress` when the camera showed one). */
export const FIX_ADDRESS_TEXT = {
  choice: (address) => `Fix its address so the DNS stays (keeps ${address})`,
  keeps: (a) => `Keeps its address ${a.address}, mask ${a.subnetMask} and gateway ${a.gateway} as they are, instead of taking them from the router `
    + `(DHCP), so its DNS stays pointed at Camera Bridge. “${SETUP_TEXT.restore}” puts DHCP back.`,
  reserve: (a) => MANUAL_TEXT.reserve(a.address, a.hardwareAddress),
};

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const MAC = /^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$/i;
const isIPv4 = (text) => typeof text === 'string' && IPV4.test(text) && text.split('.').every((part) => Number(part) <= 255);

/** An address the bridge read (`CameraAddressing`) as the page may show it: an IPv4 address, mask and gateway, and a hardware address only
 *  when it is one; null for anything else. */
function addressing(value) {
  if (!value || !isIPv4(value.address)) return null;
  const mask = isIPv4(value.subnetMask) ? value.subnetMask : null;
  const gateway = isIPv4(value.gateway) ? value.gateway : null;
  const hardwareAddress = typeof value.hardwareAddress === 'string' && MAC.test(value.hardwareAddress) ? value.hardwareAddress : null;
  return { address: value.address, subnetMask: mask, gateway, hardwareAddress };
}

/** A preview step's "Fix its address so the DNS stays" offer (its address whole, and what changes with it), or null where the bridge does
 *  not offer it. */
function fixAddressOffer(step) {
  const keeps = addressing(step?.fixAddress?.addressing);
  if (!keeps?.subnetMask || !keeps.gateway) return null;
  const changes = Array.isArray(step.fixAddress.changes) ? step.fixAddress.changes.filter((c) => c && c.label) : [];
  return { keeps, changes };
}

/** The preview with the person's choice: where the bridge offers it and it is chosen, "Watch its internet" will change the camera's address
 *  (kept as it is) and its DNS, as the offer says. Without the choice the report is as the bridge sent it. */
export function withFixAddress(report, chosen) {
  if (!chosen || !Array.isArray(report?.steps)) return report;
  return { ...report, steps: report.steps.map((step) => {
    const offer = fixAddressOffer(step);
    return offer ? { ...step, status: 'willChange', changes: offer.changes, detail: null, manualHelp: null } : step;
  }) };
}

/** The preview's heading and first sentence for `camera` (`name`): what changes; with only "Fix its address so the DNS stays" on offer and not
 *  chosen, that nothing changes unless it is; else that nothing is to change. `open` says the dialog offers something to apply or choose. */
export function previewText(report, chosen, name) {
  const info = summarize(withFixAddress(report, chosen));
  const offered = (report?.steps || []).some((step) => fixAddressOffer(step));
  if (info.toChange) {
    return { title: `${SETUP_TEXT.button}?`, open: true,
      text: `Here is what changes on “${name}”. Nothing has changed yet. The current settings are saved first, so “${SETUP_TEXT.restore}” can put every one back.` };
  }
  if (offered) {
    return { title: `${SETUP_TEXT.button}?`, open: true,
      text: `Nothing changes on “${name}” unless you choose “Fix its address so the DNS stays” below. The current settings are saved first, so “${SETUP_TEXT.restore}” can put every one back.` };
  }
  return { title: 'Nothing to change', open: false, text: `“${name}” is already set up the way Camera Bridge wants it, or the camera can’t change the rest.` };
}

/** The run's request: confirmed, and with the choice the camera's address as the preview showed it (the bridge changes nothing if the camera
 *  has another one by then). */
export function setupRequest(report, chosen) {
  const offer = chosen ? (report?.steps || []).map(fixAddressOffer).find(Boolean) : null;
  if (!offer) return { confirm: true };
  const { address, subnetMask, gateway } = offer.keeps;
  return { confirm: true, fixAddress: true, keeps: { address, subnetMask, gateway } };
}

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

/** One step as the page shows it: its title, the status in words, the changes ("Main stream: H.265 … → H.264 …"), why, and the bridge's
 *  "Change it by hand" for a step the camera refused or does not support (`manual`, manual-help.js; null for the others). */
export function describeStep(step) {
  const [statusText, tone] = STATUS[step?.status] || [String(step?.status || ''), 'idle'];
  const changes = Array.isArray(step?.changes) ? step.changes.filter((c) => c && c.label) : [];
  const lines = changes.map((c) => `${c.label}: ${c.now} → ${c.after}`);
  let detail = typeof step?.detail === 'string' && step.detail ? step.detail : null;
  if (step?.status === 'notSupported' && detail === 'not supported by this camera') detail = null;   // the status says it
  if (step?.status === 'done' && detail && /^via /.test(detail)) detail = null;                         // how is not news
  const fixed = addressing(step?.fixedAddress);
  return { id: step?.id, title: step?.title || '', statusText, tone, lines, detail: detail ? sentence(detail) : null, needsRestart: step?.needsRestart === true,
    manual: manualHelpView(step?.manualHelp), fix: fixAddressOffer(step), reserve: fixed ? FIX_ADDRESS_TEXT.reserve(fixed) : null };
}

/** The dialog's heading after a run or a restore. A step refused without stopping the run (the streams step when the camera still sends
 *  another codec) is not "stopped". */
export function resultTitle(info, { restored = false } = {}) {
  if (restored) return info.refused ? 'Some settings could not be put back' : 'Original settings restored';
  if (info.stoppedAt) return 'The setup stopped';
  if (info.refused) return 'Camera set up, but not every change took';
  return info.done ? 'Camera set up' : 'Nothing was changed';
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
    // "Watch its internet" runs after a refused step unless that refusal kept it from the camera (its record says not run).
    watchAfterStop: Boolean(report?.stoppedAt) && report.stoppedAt !== 'internetWatch'
      && steps.some((s) => s.id === 'internetWatch' && (s.status === 'done' || s.status === 'refused')),
    needsRestart: steps.some((s) => s.needsRestart === true),
    // A run's change the camera takes "after it restarts" (a restore's result has none waiting on the bridge: nothing to restart from here).
    restartWaits: steps.some((s) => s.status === 'done' && s.needsRestart === true),
    canRestore: report?.canRestore === true,
    streamRestarted: report?.streamRestarted === true,
    reenable: report?.mayNeedRecordingReEnabled === true,
    streamsWillChange: steps.some((s) => s.id === 'streams' && s.status === 'willChange'),
    watchWillChange: steps.some((s) => s.id === 'internetWatch' && s.status === 'willChange'),
  };
}

/** The banner of a run that stopped at a step the camera refused; null when it did not stop. */
export function stoppedText(info) {
  if (!info?.stoppedAt) return null;
  return info.watchAfterStop
    ? `The camera refused “${info.stoppedAt}”, so the setup stopped there, except for “${GUARD_TEXT.watchStep}”, which still ran. The changes made stay; `
      + `“${SETUP_TEXT.restore}” puts them back.`
    : `The camera refused “${info.stoppedAt}”, so the setup stopped there. The changes before it stay; “${SETUP_TEXT.restore}” puts them back.`;
}

function sentence(text) {
  const trimmed = text.trim();
  if (!trimmed) return trimmed;
  const first = trimmed[0].toUpperCase() + trimmed.slice(1);
  return /[.!?)]$/.test(first) ? first : `${first}.`;
}

/** The dialog's list of steps: each with its changes, why, and "Change it by hand" under a step the camera refused or does not support; the
 *  router reservation under a step that fixed the camera's address. A preview passes `fixAddress: {chosen, onChange}`: a step the bridge offers
 *  "Fix its address so the DNS stays" then has its checkbox (off unless chosen). */
export function stepList(report, { fixAddress = null } = {}) {
  const steps = (report?.steps || []).map(describeStep);
  return h('ul', { class: 'events setup-steps' }, steps.map((step) => h('li', null,
    h('div', null, h('div', { class: 'title' }, step.title),
      step.lines.map((line) => h('div', { class: 'change' }, line)),
      step.detail ? h('div', { class: 'change' }, step.detail) : null,
      step.needsRestart ? h('div', { class: 'change' }, 'Applies after the camera restarts.') : null,
      step.reserve ? h('div', { class: 'change' }, step.reserve) : null,
      fixAddress && step.fix ? fixAddressChoice(step.fix, fixAddress) : null,
      manualHelpBlock(step.manual)),
    h('span', { class: `pill ${step.tone}` }, step.statusText))));
}

/** The checkbox "Fix its address so the DNS stays (keeps <address>)", with what it keeps. */
function fixAddressChoice(offer, { chosen, onChange }) {
  const input = h('input', { type: 'checkbox', id: 'fix-address', checked: chosen === true, onchange: (event) => onChange?.(event.target.checked === true) });
  return h('label', { class: 'check-row fix-address', for: 'fix-address' }, input,
    h('span', { class: 'text' }, h('span', { class: 'title' }, FIX_ADDRESS_TEXT.choice(offer.keeps.address)),
      h('span', { class: 'desc' }, FIX_ADDRESS_TEXT.keeps(offer.keeps))));
}

/** Whether the bridge offers "Restart the camera now" for `camera`: its word (`restartOffered` on the camera resource,
 *  `BridgeEngine.offersCameraRestart`), never worked out here. */
export function restartOffered(camera) {
  return camera?.restartOffered === true;
}

/**
 * "Restart the camera now": null unless `offered` (the camera resource's `restartOffered`, or a setup run's result in its dialog). Pressing it
 * asks first, in place: the camera goes offline for about a minute. Only "Restart" sends `POST cameras/:id/restart`, once, never retried;
 * `onRestarted()` runs once the camera took it. `send(path)` is for tests.
 */
export function restartControl(camera, {
  offered = restartOffered(camera),
  send = (path) => api('POST', path, undefined, { timeoutMs: RESTART_TIMEOUT_MS }),
  onRestarted = null,
} = {}) {
  if (!offered || !camera?.id) return null;
  const host = h('div', { class: 'restart-camera' });
  let state = 'idle';   // idle, asking, sending, sent
  let problem = '';
  const small = (text) => h('p', { class: 'small' }, text);
  const btn = (text, onclick, extra = '') => h('button', { class: `btn small${extra}`, type: 'button', onclick }, text);

  function draw(focus) {
    host.dataset.state = state;
    const main = btn(RESTART_TEXT.button, () => { state = 'asking'; problem = ''; draw('cancel'); });
    const cancel = btn(RESTART_TEXT.cancel, () => { state = 'idle'; draw('main'); });
    // While it is sent and once it is, no button is left: the keyboard waits on the line that says what happens.
    const working = h('span', { tabindex: '-1' }, RESTART_TEXT.working);
    const sent = h('p', { class: 'small', role: 'status', tabindex: '-1' }, RESTART_TEXT.sent);
    replace(host,
      state === 'sent' ? sent : small(RESTART_TEXT.why),
      state === 'idle' ? h('div', { class: 'row' }, main) : null,
      state === 'asking' ? [small(RESTART_TEXT.confirm(camera.name || 'The camera')), h('div', { class: 'row' }, cancel, btn(RESTART_TEXT.yes, restart, ' danger'))] : null,
      state === 'sending' ? h('div', { class: 'row' }, spinner(), working) : null,
      problem ? h('div', { class: 'banner error', role: 'alert' }, icon('alert'), h('div', { class: 'text' }, problem)) : null);
    // The keyboard stays with the control as its buttons change.
    const target = { cancel, main, working, sent }[focus];
    target?.focus?.();
  }

  async function restart() {
    if (state !== 'asking') return;
    state = 'sending';
    draw('working');
    try {
      await send(`cameras/${camera.id}/restart`);
      state = 'sent';
      onRestarted?.();
      draw('sent');
    } catch (error) {
      state = 'idle';
      problem = (typeof error?.message === 'string' && error.message.trim()) || RESTART_TEXT.failed;
      draw('main');
    }
  }

  draw();
  return host;
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

    // "Fix its address so the DNS stays": off unless the person ticks it in the preview.
    let fixChosen = false;

    function preview(report, { focusChoice = false } = {}) {
      lock(false);
      const shown = withFixAddress(report, fixChosen);
      const info = summarize(shown);
      const words = previewText(report, fixChosen, camera.name);
      replace(box,
        h('h2', null, words.title),
        h('p', null, words.text),
        stepList(shown, { fixAddress: { chosen: fixChosen, onChange: (value) => { fixChosen = value; preview(report, { focusChoice: true }); } } }),
        info.streamsWillChange ? h('p', { class: 'small muted' }, 'The camera restarts its stream, so recording has a short gap.') : null,
        info.watchWillChange ? h('p', { class: 'small muted' }, SETUP_TEXT.watchNote) : null,
        h('p', { class: 'small muted' }, 'Camera Bridge never changes the camera’s address unless you choose to fix it as it is, never changes its ports, users '
          + 'or passwords, and never restarts it unless you ask.'),
        buttons(
          report?.canRestore ? button(`${SETUP_TEXT.restore}…`, () => confirmRestore(), { danger: true }) : null,
          button(words.open ? 'Cancel' : 'Close', () => close(state.outcome), { autofocus: !focusChoice }),
          info.toChange ? button('Apply changes', () => apply(setupRequest(report, fixChosen)), { primary: true }) : null));
      // The keyboard stays on the choice as the preview redraws.
      if (focusChoice) box.querySelector?.('#fix-address')?.focus?.();
    }

    function result(report, { restored = false } = {}) {
      lock(false);
      const info = summarize(report);
      const title = resultTitle(info, { restored });
      replace(box,
        h('h2', null, title),
        info.stoppedAt ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' }, stoppedText(info))) : null,
        restored && info.refused ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' },
          'The saved values the camera didn’t take back are kept, so you can try again.')) : null,
        stepList(report),
        info.restartWaits ? restartControl(camera, { offered: true }) : info.needsRestart
          ? h('p', { class: 'small muted' }, 'The camera says some changes apply after it restarts. Restart it from its own web page when it suits you.') : null,
        info.streamRestarted ? h('p', { class: 'small muted' }, 'The camera’s stream restarted, so recording had a short gap.') : null,
        info.reenable ? h('p', { class: 'small muted' }, 'Home recording may need to be turned off and on again for this camera in the Home app.') : null,
        buttons(
          !restored && info.canRestore ? button(`${SETUP_TEXT.restore}…`, () => confirmRestore(), { danger: true }) : null,
          button('Done', () => close(state.outcome), { primary: true, autofocus: true })));
    }

    async function apply(request) {
      working('Changing the camera’s settings…', 'Don’t close this page. It can take up to a minute.');
      try {
        const report = await api('POST', `cameras/${camera.id}/setup`, request, { timeoutMs: SETUP_TIMEOUT_MS });
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
        h('p', null, `Every setting the setup changed on “${camera.name}” is written back as the camera had it: ${SETUP_TEXT.restoreWhat}.`),
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

/** What the setup's Cloud step turned off, in words: Hikvision's Hik-Connect, or another maker's cloud. */
export function cloudName(camera) {
  return /hikvision/i.test(camera?.manufacturer || '') ? 'its cloud (Hik-Connect)' : 'the maker’s cloud';
}

/**
 * Step-by-step help for common routers: reserve the camera's address, then block that address from the internet (never the "block device"
 * kind, which takes it off the home network and away from Camera Bridge too). Each step is `(address) => text`, `address` being " (192.0.2.14)"
 * or "". Menu names differ between versions, and the card says so.
 */
export const ROUTER_HELP = [
  { id: 'eero', name: 'eero',
    reserve: [(a) => `In the eero app, open Settings › Network settings › Reservations & port forwarding, choose Add a reservation and pick the camera${a}.`],
    block: [() => 'Then pause its internet: open the camera in the device list and pause it, or add it to a profile and pause the profile. Don’t use Block: that takes it off your network.'] },
  { id: 'google', name: 'Google Nest Wifi or Google Wifi',
    reserve: [(a) => `In the Google Home app, open Wi‑Fi › Settings › Advanced networking › DHCP IP reservations, add a reservation and pick the camera${a}.`],
    block: [() => 'Then, under Wi‑Fi › Family Wi‑Fi, put the camera in a group of its own and pause that group’s internet.'] },
  { id: 'unifi', name: 'UniFi',
    reserve: [(a) => `In UniFi Network, open the camera under Client Devices, then its Settings, and turn on Fixed IP Address${a}.`],
    block: [() => 'Then block it from the internet: in Settings › Security (Traffic & Firewall Rules, or the Policy Engine in newer versions), add a rule that blocks '
      + 'the camera’s traffic to the internet. Don’t use the client’s Block button: that takes it off your network.'] },
  { id: 'asus', name: 'ASUS',
    reserve: [(a) => `On the router’s web page, open LAN › DHCP Server, turn on Manual Assignment, choose the camera${a} to reserve its address, add it and apply.`],
    block: [() => 'Then, in Network Map › Clients, open the camera and turn on Block Internet Access (or use Parental Controls › Time Scheduling with no time allowed).'] },
  { id: 'deco', name: 'TP-Link Deco',
    reserve: [(a) => `In the Deco app, open More › Advanced › Address Reservation, add a reservation and pick the camera${a}.`],
    block: [() => 'Then, in Parental Controls (under HomeShield in newer versions), make a profile with the camera in it and pause its internet. Don’t use Block on '
      + 'the client: that takes it off your network.'] },
  { id: 'orbi', name: 'Netgear Orbi',
    reserve: [(a) => `On the Orbi’s web page, open Advanced › Setup › LAN Setup and add the camera${a} under Address Reservation, then apply.`],
    block: [() => 'Then block its internet: in the Orbi app, open the camera under Devices and pause it (where your Orbi offers that), or on the web page use '
      + 'Advanced › Security › Block Services with the camera’s address, the service Any, and Always.'] },
  { id: 'other', name: 'Another router',
    reserve: [(a) => `Open your router’s app or web page and find DHCP (sometimes under LAN, Address reservation or Static leases). Reserve the camera’s current address${a} for it.`],
    block: [() => 'Then find Parental controls, Access control, Firewall or Internet access rules, and block that address from the internet at all times. Pick a '
      + 'rule that blocks only the internet: Camera Bridge must still reach the camera on your network.'] },
];

/** What removing a camera whose Watch kept its DNS servers does to them (camera.js's remove dialog); '' for any other camera. The engine gives
 *  the servers back before the camera goes: the box stops answering it once it is removed. They are kept also when the step was refused or not
 *  run (a camera can take part of a change), so only a watched camera is said to point at Camera Bridge (`watchDone`). */
export function removalNote(camera) {
  if (!camera?.setupBackup?.internetWatch) return '';
  if (!watchDone(camera)) {
    return `Camera Bridge gives the camera the DNS servers it had before “${GUARD_TEXT.watchStep}” back first. If the camera doesn’t answer, `
      + 'check its DNS on the camera afterwards.';
  }
  return `Its DNS points at Camera Bridge (${GUARD_TEXT.watchStep}): Camera Bridge gives the camera its own DNS servers back first. If the camera `
    + 'doesn’t answer, change its DNS on the camera afterwards, or it can’t look up names.';
}

/** Whether the Internet guard watches the camera: the engine's verdict (`internetWatched` on the camera resource, `internetWatchDone`: its
 *  DNS points at the bridge as the newest of the setup's result and the guard's readings says, whoever set it). Never worked out here. */
function watchDone(camera) {
  return camera?.internetWatched === true;
}

/** The camera's own address on the home network, for the router steps; '' when Camera Bridge reaches it through something else (go2rtc's
 *  helper on this box, a UniFi console) or at a loopback address, so the steps never name the helper or the console as the camera. */
function cameraAddress(camera) {
  const host = typeof camera?.endpoint?.host === 'string' ? camera.endpoint.host.trim() : '';
  if (!host || behindSomething(camera)) return '';
  const lower = host.toLowerCase().replace(/^\[|\]$/g, '');
  if (lower === 'localhost' || lower === '::1' || /^127\./.test(lower)) return '';
  return host;
}

function behindSomething(camera) {
  return camera?.vendor === 'go2rtc' || camera?.vendor === 'unifi' || Boolean(camera?.integration);
}

/**
 * "Keep this camera local": what the setup turned off and whether the Internet guard watches the camera, the router steps that survive a
 * factory reset, the same for common routers step by step, and what stops working. No camera change. The camera page shows it in the Security
 * card (security.js, the Internet guard's section); the setup card shows it where there is no Security card. The steps name the camera's
 * address only where it is the camera's own (`cameraAddress`).
 */
export function localOnlyCard(camera) {
  const steps = camera?.setupState?.steps || [];
  const done = (id) => steps.some((s) => s.id === id && (s.status === 'done' || s.status === 'alreadyRight'));
  const off = ['cloud', 'upnp'].filter(done);
  const watched = watchDone(camera);
  const names = { cloud: cloudName(camera), upnp: 'UPnP' };
  const host = cameraAddress(camera);
  const address = host ? ` (${host})` : '';
  const said = [off.length ? `The setup turned off ${off.map((id) => names[id]).join(' and ')} on this camera.` : null,
    watched ? `The ${GUARD_TEXT.name} watches its internet lookups.` : null].filter(Boolean);
  const list = (lines) => h('ol', { class: 'steps' }, lines.map((line) => h('li', null, line(address))));
  return h('details', { class: 'local-only' },
    h('summary', null, h('h3', { class: 'section-title' }, 'Keep this camera local')),
    h('p', { class: 'desc' }, said.length
      ? `${said.join(' ')} A factory reset undoes this, so also do this on your router:`
      : 'Camera Bridge needs no internet to show or record this camera. To keep the camera itself off the internet, do this on your router (it stays in place even after a factory reset):'),
    h('ol', { class: 'steps' },
      h('li', null, `Give it a fixed address${address} with a DHCP reservation, so its address never changes.`),
      h('li', null, 'Then block that address from the internet (parental controls, access control or a firewall rule). Use a rule that blocks only the internet: '
        + 'a “block device” or MAC filter takes it off your network, and away from Camera Bridge too.'),
      h('li', null, 'Or put your cameras on a network of their own (a camera VLAN) that reaches Camera Bridge but not the internet. A guest network usually does '
        + 'the opposite: internet, but no way to Camera Bridge.')),
    behindSomething(camera) ? h('p', { class: 'small' }, 'Camera Bridge reaches this camera through another app or a console, so in your router use the camera’s '
      + 'own address (its app or the console shows it).') : null,
    h('p', { class: 'small' }, 'Step by step for your router:'),
    h('div', { class: 'router-help' }, ROUTER_HELP.map((router) => h('details', { dataset: { router: router.id } },
      h('summary', null, router.name), list([...router.reserve, ...router.block])))),
    h('p', { class: 'small muted' }, 'Menu names differ between routers and versions, so look for the closest match.'),
    h('p', { class: 'small muted' }, 'Afterwards, check that this camera’s picture still shows in Camera Bridge. If it doesn’t, the rule blocked more than the internet: undo it.'),
    h('p', { class: 'small muted' }, 'What stops working: the maker’s phone app away from home, and its cloud recordings and alerts. Camera Bridge, Apple Home and your recordings keep working.'));
}

/**
 * The camera page's section: the status line, the button, Restore, and the local-only help (`localHelp: false` leaves it out, where the page
 * shows it in its Security card). `onDone` runs after the dialog changed something.
 */
export function cameraSetupCard(camera, { onDone, localHelp = true } = {}) {
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
    h('p', { class: 'desc' }, 'Makes this camera right for the bridge in one step: streams for recording, Apple Home and live view, no labels of its own, the bridge’s '
      + `time zone and time, the maker’s cloud and UPnP off and, on Camera Bridge OS, its internet watched by the ${GUARD_TEXT.name}. You see every change first, `
      + 'and can put everything back.'),
    unfinished ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' },
      `The last setup didn’t finish (the bridge restarted during it). Run it again to finish, or restore the original settings.`)) : null,
    h('div', { class: 'row' },
      h('button', { class: 'btn small primary', type: 'button', onclick: () => open(false) }, icon('sliders'), `${SETUP_TEXT.button}…`),
      canRestore ? h('button', { class: 'btn small', type: 'button', onclick: () => open(true) }, icon('refresh'), `${SETUP_TEXT.restore}…`) : null),
    localHelp ? localOnlyCard(camera) : null);
}

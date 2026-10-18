// "Set up for Camera Bridge": one camera made right for the bridge in one step, with a look before any change, one backup and a way back
// (docs/superpowers/specs/2026-10-16-camera-setup-design.md). The page never runs it by itself: the person presses the button, sees every
// change, and confirms. Each POST is sent once and never retried.
import { api } from '../api.js';
import { h, modal, replace, spinner } from '../dom.js';
import { icon } from '../icons.js';
import { manualHelpBlock, manualHelpView } from './manual-help.js';
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
  restoreWhat: `its streams, its own labels, its clock, its internet lookups (${GUARD_TEXT.watch}), its video password and extra services, and its cloud and UPnP`,
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

/** One step as the page shows it: its title, the status in words, the changes ("Main stream: H.265 … → H.264 …"), why, and the bridge's
 *  "Change it by hand" for a step the camera refused or does not support (`manual`, manual-help.js; null for the others). */
export function describeStep(step) {
  const [statusText, tone] = STATUS[step?.status] || [String(step?.status || ''), 'idle'];
  const changes = Array.isArray(step?.changes) ? step.changes.filter((c) => c && c.label) : [];
  const lines = changes.map((c) => `${c.label}: ${c.now} → ${c.after}`);
  let detail = typeof step?.detail === 'string' && step.detail ? step.detail : null;
  if (step?.status === 'notSupported' && detail === 'not supported by this camera') detail = null;   // the status says it
  if (step?.status === 'done' && detail && /^via /.test(detail)) detail = null;                         // how is not news
  return { id: step?.id, title: step?.title || '', statusText, tone, lines, detail: detail ? sentence(detail) : null, needsRestart: step?.needsRestart === true,
    manual: manualHelpView(step?.manualHelp) };
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

/** The dialog's list of steps: each with its changes, why, and "Change it by hand" under a step the camera refused or does not support. */
export function stepList(report) {
  const steps = (report?.steps || []).map(describeStep);
  return h('ul', { class: 'events setup-steps' }, steps.map((step) => h('li', null,
    h('div', null, h('div', { class: 'title' }, step.title),
      step.lines.map((line) => h('div', { class: 'change' }, line)),
      step.detail ? h('div', { class: 'change' }, step.detail) : null,
      step.needsRestart ? h('div', { class: 'change' }, 'Applies after the camera restarts.') : null,
      manualHelpBlock(step.manual)),
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
        info.watchWillChange ? h('p', { class: 'small muted' }, SETUP_TEXT.watchNote) : null,
        h('p', { class: 'small muted' }, 'Camera Bridge never changes the camera’s address, ports, users or passwords, and never restarts it.'),
        buttons(
          report?.canRestore ? button(`${SETUP_TEXT.restore}…`, () => confirmRestore(), { danger: true }) : null,
          button(info.toChange ? 'Cancel' : 'Close', () => close(state.outcome), { autofocus: true }),
          info.toChange ? button('Apply changes', apply, { primary: true }) : null));
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

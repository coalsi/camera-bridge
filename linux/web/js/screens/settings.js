// Bridge-wide settings, in sections: General (name, time zone), Security (the password, signed-in browsers, the Apple TV and iPhone card, sign
// out), Away from home (the box's own VPN for phones away from home; #/settings/away opens Settings at it), Video and recording (one label on
// every camera, recording), Apple Home and other systems (ports, webhook), AI (descriptions of events), Troubleshooting (the log). The
// appearance is the menu's button. (Sky Watcher's own setup, where the box is and the flight feed, is on its page, #/sky.) #/pair/<code>, the
// address in an Apple TV's or iPhone's QR code, opens Settings at the Apple TV and iPhone card (params ['apple-tv', code], see app.js).
import { get, patch, post } from '../api.js';
import { confirmDialog, h, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { loadNVR } from '../nvr/lite.js';
import { cameraList, setBridgeZone, store } from '../store.js';
import { createAISettingsCard } from './ai-settings.js';
import { createAwayCard } from './away-card.js';
import { field, inlineError, selectField, switchRow } from './common.js';
import { importMacCard } from './import-mac.js';
import { monitorCardFor } from './monitor-card.js';
import { createSessionsCard } from './sessions-card.js';
import { createViewersCard } from './viewers-card.js';

/**
 * The ports Camera Bridge OS's firewall opens to the local network (linux/os/mkosi.extra/etc/nftables.conf: TCP 21090 to 21199). The webhook and
 * the sensors bridge may use any of them; the cameras' Apple Home accessories use 21100 to 21199, one port each from the first camera port upward.
 * A new port outside its range is refused (as the bridge refuses it, WebApp+Bridge.swift `firewallProblem`); one saved before is kept as it is, and
 * the page says the network can't reach it. A development daemon (a Mac, or the daemon run as a plain program) has no such firewall.
 */
export const OPEN_PORTS = Object.freeze({ low: 21090, high: 21199 });
export const CAMERA_PORTS = Object.freeze({ low: 21100, high: 21199 });
/** Any port a program may listen on without root: the ports of a development daemon, which has no firewall to keep to. */
const ANY_PORT = Object.freeze({ low: 1024, high: 65535 });

const inRange = (port, { low, high }) => Number.isInteger(port) && port >= low && port <= high;

/**
 * The ports the page accepts: `{ base, open }`, the first camera port's range and the webhook's and sensors bridge's. On Camera Bridge OS
 * (`onTheBox`) they are the firewall's: the first camera port anywhere from 21100 to 21199 (cameras keep the ports they have; a new one gets the
 * lowest free port from there up), the other two from 21090 to 21199, as the bridge rules. Elsewhere any port from 1024.
 */
export function portRanges({ onTheBox = true } = {}) {
  return onTheBox ? { base: CAMERA_PORTS, open: OPEN_PORTS } : { base: ANY_PORT, open: ANY_PORT };
}

/**
 * What a ports form sends: `{ changes }`, the fields whose value changed (each inside its range), or `{ error }`, the sentence for the first
 * that is not a port of its range. A field that still holds its saved value is left out, so a saved port outside the range stays as it is.
 * `fields`: [{ key (the setting), value (the input's text), range, name (for the sentence) }]; `saved`: the settings as the bridge sent them.
 */
export function portChanges(fields, saved) {
  const changes = {};
  for (const { key, value, range, name } of fields) {
    const text = String(value ?? '').trim();
    const port = /^\d{1,5}$/.test(text) ? Number(text) : NaN;
    if (port === saved?.[key]) continue;
    if (!inRange(port, range)) return { error: `Choose a ${name} from ${range.low} to ${range.high}.` };
    changes[key] = port;
  }
  return { changes };
}

/**
 * The saved ports the network can't reach, each as its sentence: the first camera port outside 21100-21199, the sensors bridge's port and (while
 * the webhook is on) the webhook's outside 21090-21199. Port 0 (any free port, which only development runs use) is not judged, nor is anything off
 * the box (`onTheBox` false: a development daemon has no firewall).
 */
export function unreachablePorts(settings, { onTheBox = true } = {}) {
  if (!onTheBox) return {};
  const out = (port, range) => Number.isInteger(port) && port !== 0 && !inRange(port, range);
  const sentences = {};
  if (out(settings?.basePort, CAMERA_PORTS)) {
    sentences.basePort = `New cameras would get ports from ${settings.basePort} upward, which your network can’t reach: the bridge’s firewall keeps them closed, so Apple Home could not add those cameras. Choose a first camera port from ${CAMERA_PORTS.low} to ${CAMERA_PORTS.high}.`;
  }
  if (out(settings?.sensorsBridgePort, OPEN_PORTS)) {
    sentences.sensorsBridgePort = `Your network can’t reach the sensors bridge on port ${settings.sensorsBridgePort}: the bridge’s firewall keeps that port closed, so Apple Home can’t add it or use it. Choose a port from ${OPEN_PORTS.low} to ${OPEN_PORTS.high}.`;
  }
  if (settings?.webhookEnabled && out(settings?.webhookPort, OPEN_PORTS)) {
    sentences.webhookPort = `Your network can’t reach the webhook on port ${settings.webhookPort}: the bridge’s firewall keeps that port closed, so requests from other systems don’t arrive. Choose a port from ${OPEN_PORTS.low} to ${OPEN_PORTS.high}.`;
  }
  return sentences;
}

const portWarning = (text) => h('div', { class: 'banner warning', role: 'status' }, icon('alert'), h('div', { class: 'text' }, text));

export function renderSettings({ params, setTitle }) {
  const root = h('div', { class: 'settings' });
  const recordingHost = h('div', { id: 'recording' });
  const importCard = importMacCard();
  let recording = null;   // the Recording card: { el, refresh, destroy }, made once and put back by every draw()
  let kept = null;        // the Kept recordings card under it (nvr/kept.js): { el, refresh, destroy }
  const sessions = createSessionsCard();   // Signed-in browsers: made once (it loads its own list)
  // The Apple TV and iPhone card: made once too. A device added from the #/pair/<code> address leaves that address, so a reload does not fill the code again.
  const viewers = createViewersCard({ onApproved: () => { if (location.hash.startsWith('#/pair/')) history.replaceState(null, '', '#/settings'); } });
  const away = createAwayCard();          // Away from home: made once too (it reads the box's card itself, and again every 15 s while on)
  let monitorShown = false;               // the monitoring token is shown (Show), across the draws of Settings
  let aiCard = null;      // the AI descriptions card: { el, update }, made once (it keeps what is being typed and Try it's answer)
  let settings = null;
  let onTheBox = true;   // Camera Bridge OS, whose firewall decides which ports work; false for a development daemon (GET system's mode)
  let destroyed = false;
  let wanted = params?.[0] ?? null;   // the address #/settings/recording, #/settings/away or #/settings/ai scrolls to that card; #/pair/<code> ('apple-tv', the code) to the Apple TV and iPhone card

  async function load() {
    try {
      const [loaded, system] = await Promise.all([get('settings'), get('system').catch(() => null)]);
      settings = loaded;
      onTheBox = system?.mode !== 'development';
    } catch (error) {
      replace(root, inlineError(error.message));
      return;
    }
    if (!destroyed) draw();
  }

  async function change(partial, message = 'Saved.') {
    try {
      settings = await patch('settings', partial);
      if ('timeZone' in partial) setBridgeZone(settings.timeZone);   // every time on the page follows (store.js bridgeZone)
      if (partial.bridgeName) {
        store.session.bridgeName = settings.bridgeName;
        const name = document.querySelector('.brand span');
        if (name) name.textContent = settings.bridgeName;
        setTitle('Settings');
      }
      toast(message, 'ok');
      draw();
    } catch (error) {
      toast(error.message, 'error');
      draw();
    }
  }

  function nameCard() {
    const name = h('input', { type: 'text', value: settings.bridgeName, maxlength: 60, autocomplete: 'off' });
    return h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); change({ bridgeName: name.value }, 'Name saved.'); } },
      h('h2', null, 'This bridge'),
      h('p', { class: 'desc' }, 'The name shown at the top of this page.'),
      field('Name', name), h('button', { class: 'btn', type: 'submit' }, 'Save name'));
  }

  /** One look on every camera: the bridge's label style, whether Apple Home's video carries it, and clean pictures from the cameras.
   *  A change sends only the setting changed, to every camera: what else a camera's own page set differently stays as it is. */
  function labelsCard() {
    const status = h('p', { class: 'small muted', role: 'status' });
    async function everyCamera(word, work) {
      const cameras = cameraList();
      if (!cameras.length) { status.textContent = 'Add a camera first.'; return; }
      status.textContent = `${word}…`;
      const failed = [];
      for (const camera of cameras) {
        try { await work(camera); } catch (error) { failed.push(`${camera.name}: ${error.message}`); }
      }
      status.textContent = failed.length ? `Done, except ${failed.join('; ')}` : `Saved on ${cameras.length === 1 ? 'the camera' : `all ${cameras.length} cameras`}.`;
    }
    return labelsCardFor(cameraList(), {
      status,
      apply: (partial) => everyCamera('Saving', (c) => patch(`cameras/${c.id}`, { timestampOverlay: partial })),
      cleanPictures: () => everyCamera('Turning the cameras’ own labels off', (c) => post(`cameras/${c.id}/clean-picture`, { clean: true })),
    });
  }

  /** The bridge's time zone: the timestamp it draws on video and the clocks it sets on cameras follow it. */
  function timeZoneCard() {
    const here = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const zones = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : [here];
    const current = settings.timeZone || '';
    const options = [...new Set([current, here, ...zones].filter(Boolean))].map((zone) => [zone, zone.replaceAll('_', ' ')]);
    return h('div', { class: 'card' }, h('h2', null, 'Time zone'),
      h('p', { class: 'desc' }, current
        ? 'The timestamp the bridge draws on video, and the clocks it sets on cameras, use this time zone.'
        : 'The bridge has no time zone yet, so it uses UTC. Choose yours.'),
      selectField('Time zone', current ? options : [['', 'Not set (UTC)'], ...options], current, (zone) => { if (zone) change({ timeZone: zone }, 'Time zone saved.'); }),
      current !== here ? h('button', { class: 'btn small', type: 'button', onclick: () => change({ timeZone: here }, 'Time zone saved.') }, `Use this device’s: ${here.replaceAll('_', ' ')}`) : null);
  }

  function passwordCard() {
    const current = h('input', { type: 'password', autocomplete: 'current-password' });
    const next = h('input', { type: 'password', autocomplete: 'new-password' });
    const again = h('input', { type: 'password', autocomplete: 'new-password' });
    const errors = h('div');
    return h('form', { class: 'card', onsubmit: async (e) => {
      e.preventDefault();
      replace(errors);
      if (next.value.length < 8) return replace(errors, inlineError('Use at least 8 characters.'));
      if (next.value !== again.value) return replace(errors, inlineError('The two new passwords don’t match.'));
      try {
        await post('auth/password', { current: current.value, new: next.value });
        current.value = next.value = again.value = '';
        toast('Password changed. Other browsers were signed out.', 'ok');
      } catch (error) { replace(errors, inlineError(error.message)); }
    } },
    h('h2', null, 'Password'),
    h('p', { class: 'desc' }, 'Changing it signs every other browser out.'),
    field('Current password', current), field('New password', next, { hint: 'At least 8 characters.' }), field('New password again', again), errors,
    h('button', { class: 'btn', type: 'submit' }, 'Change password'));
  }

  /** Sends what a ports form changed, or says why it can't (in `errors`). Every port is checked here: a saved one outside the range is kept. */
  function savePorts(fields, errors, message) {
    replace(errors);
    const { changes, error } = portChanges(fields, settings);
    if (error) return replace(errors, inlineError(error));
    if (!Object.keys(changes).length) return toast('Nothing to save.');
    change(changes, message);
  }

  function portsCard() {
    const ranges = portRanges({ onTheBox });
    const base = h('input', { type: 'number', inputmode: 'numeric', min: ranges.base.low, max: ranges.base.high, step: 1, value: settings.basePort });
    const sensors = h('input', { type: 'number', inputmode: 'numeric', min: ranges.open.low, max: ranges.open.high, step: 1, value: settings.sensorsBridgePort });
    const errors = h('div');
    const unreachable = unreachablePorts(settings, { onTheBox });
    return h('form', { class: 'card', novalidate: true, onsubmit: (e) => {
      e.preventDefault();
      savePorts([{ key: 'basePort', value: base.value, range: ranges.base, name: 'first camera port' },
        { key: 'sensorsBridgePort', value: sensors.value, range: ranges.open, name: 'sensors bridge port' }], errors, 'Ports saved.');
    } },
      h('h2', null, 'Apple Home ports'),
      h('p', { class: 'desc' }, onTheBox
        ? `Each camera is its own accessory with its own port, from ${CAMERA_PORTS.low} to ${CAMERA_PORTS.high}. The sensors bridge and the webhook use ports from ${OPEN_PORTS.low} to ${OPEN_PORTS.high}. These are the ports the bridge’s firewall lets in from your network.`
        : 'Each camera is its own accessory with its own port.'),
      unreachable.basePort ? portWarning(unreachable.basePort) : null,
      unreachable.sensorsBridgePort ? portWarning(unreachable.sensorsBridgePort) : null,
      h('div', { class: 'inline-fields' },
        field('First camera port', base, { hint: [onTheBox ? `From ${ranges.base.low} to ${ranges.base.high}.` : '', 'New cameras get ports from here upward. Cameras you already added keep theirs.'].filter(Boolean).join(' ') }),
        field('Sensors bridge port', sensors, { hint: [onTheBox ? `From ${ranges.open.low} to ${ranges.open.high}.` : '', 'The accessory that carries all the sensors.'].filter(Boolean).join(' ') })),
      errors,
      h('div', { class: 'row' }, h('button', { class: 'btn', type: 'submit' }, 'Save ports'), h('a', { class: 'btn ghost', href: '#/pair/sensors' }, icon('home'), 'Add the sensors bridge to Apple Home')));
  }

  function webhookCard() {
    const { open } = portRanges({ onTheBox });
    const port = h('input', { type: 'number', inputmode: 'numeric', min: open.low, max: open.high, step: 1, value: settings.webhookPort });
    const portErrors = h('div');
    const unreachable = unreachablePorts(settings, { onTheBox });
    const token = h('code', null, settings.webhookToken);
    return h('div', { class: 'card' }, h('h2', null, 'Webhook'),
      h('p', { class: 'desc' }, 'Lets Home Assistant, Frigate or another system tell Camera Bridge about motion, doorbell rings and detections.'),
      settings.webhookProblem ? inlineError(settings.webhookProblem) : null,
      switchRow({ title: 'Listen for webhook requests', checked: settings.webhookEnabled, onchange: (v) => change({ webhookEnabled: v }, v ? 'The webhook is on.' : 'The webhook is off.') }),
      settings.webhookEnabled ? h('div', { class: 'stack' },
        unreachable.webhookPort ? portWarning(unreachable.webhookPort) : null,
        h('form', { novalidate: true, onsubmit: (e) => {
          e.preventDefault();
          savePorts([{ key: 'webhookPort', value: port.value, range: open, name: 'webhook port' }], portErrors, 'Webhook port saved.');
        } },
          field('Port', port, { hint: onTheBox ? `From ${open.low} to ${open.high}.` : undefined }), portErrors, h('button', { class: 'btn small', type: 'submit' }, 'Save port')),
        h('div', { class: 'field' }, h('span', { class: 'label' }, 'Token'),
          h('div', { class: 'token' }, token,
            h('button', { class: 'btn small', type: 'button', onclick: async () => { try { await navigator.clipboard.writeText(settings.webhookToken); toast('Copied.'); } catch { toast('Select the token and copy it.'); } } }, icon('copy'), 'Copy'),
            h('button', { class: 'btn small danger', type: 'button', onclick: async () => {
              if (await confirmDialog({ title: 'Make a new token?', body: 'Systems that use the current token stop working until you give them the new one.', confirm: 'Make a new token', danger: true })) change({ regenerateWebhookToken: true }, 'New token ready.');
            } }, 'New token')),
          h('span', { class: 'hint' }, 'Send it as “Authorization: Bearer <token>”. Each camera’s page lists its URLs.'))) : null);
  }

  function monitorCard() {
    return monitorCardFor(settings, {
      change, shown: monitorShown, setShown: (on) => { monitorShown = on; draw(); },
      say: (result) => toast(result === 'copied' ? 'Copied.' : result === 'selected' ? 'Selected: copy it with your keyboard.' : 'Select it and copy it.'),
    });
  }

  function diagnosticsCard() {
    return h('div', { class: 'card' }, h('h2', null, 'Log and tests'),
      selectField('Log detail', [['error', 'Errors only'], ['warning', 'Warnings'], ['notice', 'Notices'], ['info', 'Normal'], ['debug', 'Everything (for troubleshooting)']], settings.logLevel,
        (v) => change({ logLevel: v }, 'Log detail saved.'), { hint: 'The diagnostics download always includes the full detailed log.' }),
      switchRow({ title: 'Motion comparison test', desc: 'Runs built-in motion detection next to each camera’s own events and compares them. It never changes what reaches Home. The result shows in the diagnostics.',
        checked: settings.motionShadowTest, onchange: (v) => change({ motionShadowTest: v }, v ? 'The test is on.' : 'The test is off.') }),
      h('div', { class: 'row' }, h('a', { class: 'btn', href: '/api/v1/diagnostics', download: '' }, icon('download'), 'Download diagnostics'), h('a', { class: 'btn ghost', href: '#/logs' }, 'Open the log')),
      h('p', { class: 'small muted' }, 'The diagnostics file holds the log and each camera’s status. It has no passwords, tokens or setup codes. Nothing is sent anywhere.'));
  }

  function accountCard() {
    return h('div', { class: 'card' }, h('h2', null, 'Sign out'), h('p', { class: 'desc' }, 'You’ll need the password to come back.'),
      h('button', { class: 'btn', type: 'button', onclick: async () => {
        try { await post('auth/logout'); } catch { /* signed out anyway */ }
        location.hash = '#/';
        location.reload();
      } }, 'Sign out'));
  }

  /** The Recording card comes from the recording code, which is loaded on demand. Without it the rest of Settings still works. */
  async function mountRecording() {
    const nvr = await loadNVR();
    if (destroyed) return;
    recording = nvr ? nvr.storageCard() : null;
    kept = nvr?.keptCard ? nvr.keptCard() : null;
    replace(recordingHost, recording ? recording.el
      : h('div', { class: 'card' }, h('h2', null, 'Recording'), inlineError('The recording settings could not load. Reload the page to try again.')), kept?.el);
    showWanted();
  }

  /**
   * Scrolls to the card the address names (Recording, Away from home, AI descriptions, Apple TV and iPhone) once, when both it and the other settings
   * are on the page. The AI card also waits for the Recording card, which loads on demand above it and would push it down (mountRecording asks
   * again). The Apple TV and iPhone card and the Away from home card, above the Recording card, are not pushed by it. The Apple TV and iPhone card
   * gets the code from the address and the keyboard on Add, and nothing is added until the owner presses Add.
   */
  function showWanted() {
    const host = wanted === 'recording' ? recordingHost : wanted === 'ai' ? aiCard?.el : wanted === 'away' ? away.el : wanted === 'apple-tv' ? viewers.el : null;
    if (!host || !settings || !host.firstChild || !host.isConnected) return;
    if (wanted === 'ai' && !recordingHost.firstChild) return;
    const appleTV = wanted === 'apple-tv';
    wanted = null;
    host.scrollIntoView({ block: 'start' });
    if (appleTV) viewers.fill(params?.[1]);
    else host.querySelector('h2')?.focus({ preventScroll: true });
  }

  function draw() {
    const section = (title, ...cards) => h('section', { class: 'settings-section' }, h('h2', { class: 'section-title' }, title), h('div', { class: 'card-columns' }, cards));
    if (aiCard) aiCard.update(settings);
    else aiCard = createAISettingsCard(settings, { onSettings: (next) => { settings = next; } });
    replace(root,
      // Bringing cameras over from the Mac app is a first-day step: offered while the bridge has none.
      section('General', nameCard(), timeZoneCard(), cameraList().length ? null : importCard),
      section('Security', passwordCard(), sessions.el, viewers.el, accountCard()),
      section('Away from home', away.el),
      section('Video and recording', labelsCard(), recordingHost),
      section('Apple Home and other systems', portsCard(), webhookCard(), monitorCard()),
      section('AI', aiCard.el),
      section('Troubleshooting', diagnosticsCard()));
    showWanted();
  }

  replace(root, h('div', { class: 'checking' }, spinner()));
  load();
  mountRecording();
  return { el: h('div', null, h('div', { class: 'page-head' }, h('h1', null, 'Settings')), root), destroy() { destroyed = true; recording?.destroy(); kept?.destroy(); sessions.destroy(); viewers.destroy(); away.destroy(); aiCard?.destroy(); } };
}

const LABEL_DEFAULTS = { enabled: false, position: 'topRight', size: 'medium', showCameraName: true, showDate: true, showSeconds: true, use24Hour: false };

/**
 * The cameras' label settings as the Video label card shows them: each setting the value every camera has, or, where they differ, the one most of
 * them have (the first camera's on a tie), with `differ` naming the settings that are not the same on every camera.
 */
export function sharedLabelStyle(cameras) {
  const styles = cameras.map((camera) => ({ ...LABEL_DEFAULTS, ...Object.fromEntries(Object.entries(camera?.timestampOverlay ?? {}).filter(([, v]) => v !== undefined && v !== null)) }));
  const style = { ...LABEL_DEFAULTS, ...(styles[0] ?? {}) };
  const differ = new Set();
  for (const name of Object.keys(LABEL_DEFAULTS)) {
    const counts = new Map();
    for (const one of styles) counts.set(one[name], (counts.get(one[name]) ?? 0) + 1);
    if (counts.size > 1) {
      differ.add(name);
      let best = style[name];
      for (const [value, count] of counts) if (count > (counts.get(best) ?? 0)) best = value;
      style[name] = best;
    }
  }
  return { style, differ };
}

/**
 * The Video label card for `cameras`: `apply(partial)` saves the one setting changed (`{ showSeconds: false }`) on every camera, never the
 * others, so turning on seconds does not also put the label into Apple Home's video of a camera that had it off. Where the cameras differ, the
 * card says so beside the setting.
 */
export function labelsCardFor(cameras, { apply, cleanPictures = () => {}, status = h('p', { class: 'small muted', role: 'status' }) }) {
  const { style, differ } = sharedLabelStyle(cameras);
  const note = (name) => (differ.has(name) ? 'Not the same on every camera: a change here sets it on all of them.' : undefined);
  const change = (name) => (value) => { style[name] = value; differ.delete(name); apply({ [name]: value }); };
  const differs = differ.size > 0
    ? h('p', { class: 'small muted' }, 'Your cameras don’t all have the same label. A change here sets only that setting, on every camera.')
    : null;
  return h('div', { class: 'card' }, h('h2', null, 'Video label'),
    h('p', { class: 'desc' }, 'The camera’s name and the date and time, the same on every camera: on the Monitor, on recordings, burned into saved clips and, if you want, into Apple Home’s video.'),
    differs,
    h('div', { class: 'inline-fields' },
      selectField('Corner', [['topRight', 'Top right'], ['topLeft', 'Top left'], ['bottomRight', 'Bottom right'], ['bottomLeft', 'Bottom left']], style.position, change('position'), { hint: note('position') }),
      selectField('Size', [['small', 'Small'], ['medium', 'Medium'], ['large', 'Large']], style.size, change('size'), { hint: note('size') })),
    switchRow({ title: 'Camera name', desc: note('showCameraName'), checked: style.showCameraName, onchange: change('showCameraName') }),
    switchRow({ title: 'Date', desc: note('showDate'), checked: style.showDate, onchange: change('showDate') }),
    switchRow({ title: 'Seconds', desc: note('showSeconds'), checked: style.showSeconds, onchange: change('showSeconds') }),
    switchRow({ title: '24-hour time', desc: note('use24Hour'), checked: style.use24Hour, onchange: change('use24Hour') }),
    switchRow({ title: 'In Apple Home’s video', desc: [note('enabled'), 'Burns the label into what Apple Home shows and records. The bridge then converts the video instead of passing it through, which uses more of the box.'].filter(Boolean).join(' '),
      checked: style.enabled, onchange: change('enabled') }),
    h('div', { class: 'row' },
      h('button', { class: 'btn small', type: 'button', onclick: () => cleanPictures() }, 'Turn off the cameras’ own labels')),
    h('p', { class: 'small muted' }, 'Removes the clock and text each camera draws itself, so only this label shows. A camera’s page can put them back.'),
    status);
}

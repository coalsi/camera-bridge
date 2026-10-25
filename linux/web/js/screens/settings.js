// Bridge-wide settings, in sections: General (name, time zone, password, sign out), Video and recording (one label on every camera,
// recording), Apple Home and other systems (ports, webhook), AI (descriptions of events), Troubleshooting (the log). The appearance is the
// menu's button. (Sky Watcher's own setup, where the box is and the flight feed, is on its page, #/sky.)
import { get, patch, post } from '../api.js';
import { confirmDialog, h, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { loadNVR } from '../nvr/lite.js';
import { cameraList, store } from '../store.js';
import { createAISettingsCard } from './ai-settings.js';
import { field, inlineError, selectField, switchRow } from './common.js';
import { importMacCard } from './import-mac.js';

export function renderSettings({ params, setTitle }) {
  const root = h('div', { class: 'settings' });
  const recordingHost = h('div', { id: 'recording' });
  const importCard = importMacCard();
  let recording = null;   // the Recording card: { el, refresh, destroy }, made once and put back by every draw()
  let aiCard = null;      // the AI descriptions card: { el, update }, made once (it keeps what is being typed and Try it's answer)
  let settings = null;
  let destroyed = false;
  let wanted = params?.[0] ?? null;   // the address #/settings/recording or #/settings/ai scrolls to that card

  async function load() {
    try {
      settings = await get('settings');
    } catch (error) {
      replace(root, inlineError(error.message));
      return;
    }
    if (!destroyed) draw();
  }

  async function change(partial, message = 'Saved.') {
    try {
      settings = await patch('settings', partial);
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
   *  Each change is saved on every camera at once (a camera's own page can still set it differently). */
  function labelsCard() {
    const first = cameraList()[0]?.timestampOverlay ?? {};
    const style = { enabled: first.enabled ?? false, position: first.position ?? 'topRight', size: first.size ?? 'medium',
      showCameraName: first.showCameraName ?? true, showDate: first.showDate ?? true, showSeconds: first.showSeconds ?? true, use24Hour: first.use24Hour ?? false };
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
    const apply = (partial) => { Object.assign(style, partial); everyCamera('Saving', (c) => patch(`cameras/${c.id}`, { timestampOverlay: { ...style } })); };
    return h('div', { class: 'card' }, h('h2', null, 'Video label'),
      h('p', { class: 'desc' }, 'The camera’s name and the date and time, the same on every camera: on the Monitor, on recordings, burned into saved clips and, if you want, into Apple Home’s video.'),
      h('div', { class: 'inline-fields' },
        selectField('Corner', [['topRight', 'Top right'], ['topLeft', 'Top left'], ['bottomRight', 'Bottom right'], ['bottomLeft', 'Bottom left']], style.position, (v) => apply({ position: v })),
        selectField('Size', [['small', 'Small'], ['medium', 'Medium'], ['large', 'Large']], style.size, (v) => apply({ size: v }))),
      switchRow({ title: 'Camera name', checked: style.showCameraName, onchange: (v) => apply({ showCameraName: v }) }),
      switchRow({ title: 'Date', checked: style.showDate, onchange: (v) => apply({ showDate: v }) }),
      switchRow({ title: 'Seconds', checked: style.showSeconds, onchange: (v) => apply({ showSeconds: v }) }),
      switchRow({ title: '24-hour time', checked: style.use24Hour, onchange: (v) => apply({ use24Hour: v }) }),
      switchRow({ title: 'In Apple Home’s video', desc: 'Burns the label into what Apple Home shows and records. The bridge then converts the video instead of passing it through, which uses more of the box.',
        checked: style.enabled, onchange: (v) => apply({ enabled: v }) }),
      h('div', { class: 'row' },
        h('button', { class: 'btn small', type: 'button', onclick: () => everyCamera('Turning the cameras’ own labels off', (c) => post(`cameras/${c.id}/clean-picture`, { clean: true })) },
          'Turn off the cameras’ own labels')),
      h('p', { class: 'small muted' }, 'Removes the clock and text each camera draws itself, so only this label shows. A camera’s page can put them back.'),
      status);
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

  function portsCard() {
    const base = h('input', { type: 'number', min: 1024, max: 65535, value: settings.basePort });
    const sensors = h('input', { type: 'number', min: 0, max: 65535, value: settings.sensorsBridgePort });
    return h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); change({ basePort: Number(base.value), sensorsBridgePort: Number(sensors.value) }, 'Ports saved.'); } },
      h('h2', null, 'Apple Home ports'),
      h('p', { class: 'desc' }, 'Each camera is its own accessory with its own port. The bridge allows them through its firewall from 21100 to 21199.'),
      h('div', { class: 'inline-fields' },
        field('First camera port', base, { hint: 'New cameras get ports from here upward. Cameras you already added keep theirs.' }),
        field('Sensors bridge port', sensors, { hint: 'The accessory that carries all the sensors.' })),
      h('div', { class: 'row' }, h('button', { class: 'btn', type: 'submit' }, 'Save ports'), h('a', { class: 'btn ghost', href: '#/pair/sensors' }, icon('home'), 'Add the sensors bridge to Apple Home')));
  }

  function webhookCard() {
    const port = h('input', { type: 'number', min: 1024, max: 65535, value: settings.webhookPort });
    const token = h('code', null, settings.webhookToken);
    return h('div', { class: 'card' }, h('h2', null, 'Webhook'),
      h('p', { class: 'desc' }, 'Lets Home Assistant, Frigate or another system tell Camera Bridge about motion, doorbell rings and detections.'),
      settings.webhookProblem ? inlineError(settings.webhookProblem) : null,
      switchRow({ title: 'Listen for webhook requests', checked: settings.webhookEnabled, onchange: (v) => change({ webhookEnabled: v }, v ? 'The webhook is on.' : 'The webhook is off.') }),
      settings.webhookEnabled ? h('div', { class: 'stack' },
        h('form', { onsubmit: (e) => { e.preventDefault(); change({ webhookPort: Number(port.value) }, 'Webhook port saved.'); } },
          field('Port', port), h('button', { class: 'btn small', type: 'submit' }, 'Save port')),
        h('div', { class: 'field' }, h('span', { class: 'label' }, 'Token'),
          h('div', { class: 'token' }, token,
            h('button', { class: 'btn small', type: 'button', onclick: async () => { try { await navigator.clipboard.writeText(settings.webhookToken); toast('Copied.'); } catch { toast('Select the token and copy it.'); } } }, icon('copy'), 'Copy'),
            h('button', { class: 'btn small danger', type: 'button', onclick: async () => {
              if (await confirmDialog({ title: 'Make a new token?', body: 'Systems that use the current token stop working until you give them the new one.', confirm: 'Make a new token', danger: true })) change({ regenerateWebhookToken: true }, 'New token ready.');
            } }, 'New token')),
          h('span', { class: 'hint' }, 'Send it as “Authorization: Bearer <token>”. Each camera’s page lists its URLs.'))) : null);
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
    replace(recordingHost, recording ? recording.el
      : h('div', { class: 'card' }, h('h2', null, 'Recording'), inlineError('The recording settings could not load. Reload the page to try again.')));
    showWanted();
  }

  /**
   * Scrolls to the card the address names (Recording, AI descriptions) once, when both it and the other settings are on the page. The AI
   * card also waits for the Recording card, which loads on demand above it and would push it down (mountRecording asks again).
   */
  function showWanted() {
    const host = wanted === 'recording' ? recordingHost : wanted === 'ai' ? aiCard?.el : null;
    if (!host || !settings || !host.firstChild || !host.isConnected) return;
    if (wanted === 'ai' && !recordingHost.firstChild) return;
    wanted = null;
    host.scrollIntoView({ block: 'start' });
    host.querySelector('h2')?.focus({ preventScroll: true });
  }

  function draw() {
    const section = (title, ...cards) => h('section', { class: 'settings-section' }, h('h2', { class: 'section-title' }, title), h('div', { class: 'card-columns' }, cards));
    if (aiCard) aiCard.update(settings);
    else aiCard = createAISettingsCard(settings, { onSettings: (next) => { settings = next; } });
    replace(root,
      // Bringing cameras over from the Mac app is a first-day step: offered while the bridge has none.
      section('General', nameCard(), timeZoneCard(), cameraList().length ? null : importCard, passwordCard(), accountCard()),
      section('Video and recording', labelsCard(), recordingHost),
      section('Apple Home and other systems', portsCard(), webhookCard()),
      section('AI', aiCard.el),
      section('Troubleshooting', diagnosticsCard()));
    showWanted();
  }

  replace(root, h('div', { class: 'checking' }, spinner()));
  load();
  mountRecording();
  return { el: h('div', null, h('div', { class: 'page-head' }, h('h1', null, 'Settings')), root), destroy() { destroyed = true; recording?.destroy(); aiCard?.destroy(); } };
}


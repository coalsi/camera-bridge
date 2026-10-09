// Bridge-wide settings: its name, the password, ports, the webhook, the timestamp for every camera, and the log.
import { get, patch, post } from '../api.js';
import { confirmDialog, h, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { cameraList, store } from '../store.js';
import { field, inlineError, selectField, switchRow } from './common.js';

export function renderSettings({ setTitle }) {
  const root = h('div', { class: 'stack' });
  let settings = null;
  let destroyed = false;

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

  function overlayCard() {
    const o = { enabled: false, position: 'topRight', size: 'medium', showCameraName: false, showDate: true, showSeconds: true, use24Hour: false };
    const first = cameraList()[0]?.timestampOverlay;
    if (first) Object.assign(o, first);
    const set = (key) => (value) => { o[key] = value; };
    return h('div', { class: 'card' }, h('h2', null, 'Timestamp on video'),
      h('p', { class: 'desc' }, 'Draws the date and time on live view and recordings of every camera. You can also set it camera by camera. Turning it on makes the bridge convert the video instead of passing it through.'),
      switchRow({ title: 'Show the timestamp', checked: o.enabled, onchange: set('enabled') }),
      h('div', { class: 'inline-fields' },
        selectField('Position', [['topRight', 'Top right'], ['topLeft', 'Top left'], ['bottomRight', 'Bottom right'], ['bottomLeft', 'Bottom left']], o.position, set('position')),
        selectField('Size', [['small', 'Small'], ['medium', 'Medium'], ['large', 'Large']], o.size, set('size'))),
      switchRow({ title: 'Camera name', checked: o.showCameraName, onchange: set('showCameraName') }),
      switchRow({ title: 'Date', checked: o.showDate, onchange: set('showDate') }),
      switchRow({ title: 'Seconds', checked: o.showSeconds, onchange: set('showSeconds') }),
      switchRow({ title: '24-hour time', checked: o.use24Hour, onchange: set('use24Hour') }),
      h('button', { class: 'btn', type: 'button', disabled: !cameraList().length, onclick: async (e) => {
        const button = e.currentTarget;
        button.disabled = true;
        try {
          await Promise.all(cameraList().map((camera) => patch(`cameras/${camera.id}`, { timestampOverlay: o })));
          toast(`Applied to ${cameraList().length} camera${cameraList().length === 1 ? '' : 's'}.`, 'ok');
        } catch (error) { toast(error.message, 'error'); }
        button.disabled = false;
      } }, 'Apply to all cameras'));
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

  function draw() {
    replace(root, nameCard(), passwordCard(), portsCard(), webhookCard(), overlayCard(), diagnosticsCard(), accountCard());
  }

  replace(root, h('div', { class: 'checking' }, spinner()));
  load();
  return { el: h('div', null, h('div', { class: 'page-head' }, h('h1', null, 'Settings')), root), destroy() { destroyed = true; } };
}


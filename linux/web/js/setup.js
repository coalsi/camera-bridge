// The setup hotspot's page (setup.html): a phone that joins the "CameraBridge-XXXX" network is sent here. It lists the networks the box saw,
// asks for the password (and for the bridge's administrator password once it has one), and the box restarts to join the network. If it can't,
// the hotspot comes back and this page says why. These two routes need no session.
import { api } from './api.js';
import { h, replace } from './dom.js';

const root = typeof document === 'undefined' ? null : document.getElementById('setup');

export function signalWords(signal) {
  if (signal >= 70) return 'strong';
  if (signal >= 45) return 'good';
  if (signal >= 25) return 'weak';
  return 'very weak';
}

/** The network to show first: one the box knows already, else the strongest. */
export function preferred(networks, saved) {
  return networks.find((network) => saved.includes(network.ssid))?.ssid ?? networks[0]?.ssid ?? '';
}

function call(method, body) {
  return api(method, 'setup/wifi', body);
}

function form(state) {
  const { networks, saved, lastError, needsAdminPassword, hotspot } = state;
  const select = h('select', { id: 'ssid', required: true },
    networks.map((network) => h('option', { value: network.ssid }, `${network.ssid} (${signalWords(network.signal)}${network.security ? '' : ', open'})`)),
    h('option', { value: '' }, 'Another network…'));
  select.value = preferred(networks, saved);
  const other = h('input', { id: 'other', type: 'text', autocomplete: 'off', autocapitalize: 'none', spellcheck: 'false', maxlength: '32', placeholder: 'Network name', hidden: select.value !== '' });
  const password = h('input', { id: 'password', type: 'password', autocomplete: 'off', autocapitalize: 'none', spellcheck: 'false', maxlength: '63', placeholder: 'Wi-Fi password' });
  const show = h('input', { id: 'show', type: 'checkbox' });
  const admin = needsAdminPassword ? h('input', { id: 'admin', type: 'password', autocomplete: 'current-password', placeholder: 'Bridge administrator password' }) : null;
  const message = h('p', { class: 'setup-message', role: 'alert' }, lastError || '');
  const button = h('button', { class: 'btn primary', type: 'submit' }, 'Join this network');
  select.addEventListener('change', () => { other.hidden = select.value !== ''; if (!other.hidden) other.focus(); });
  show.addEventListener('change', () => { password.type = show.checked ? 'text' : 'password'; });
  const el = h('form', { class: 'card setup-form' },
    h('label', { for: 'ssid' }, 'Your Wi-Fi network'), select, other,
    h('label', { for: 'password' }, 'Its password'), password,
    h('label', { class: 'setup-check' }, show, ' Show the password'),
    admin ? [h('label', { for: 'admin' }, 'This bridge is already set up: its administrator password'), admin] : null,
    message, button,
    h('p', { class: 'small muted' }, `You are on the box's own network, ${hotspot.ssid}. After you join, the box restarts and joins your network; your phone goes back to your own Wi-Fi. If the box can't join, ${hotspot.ssid} comes back in about a minute and this page tells you why.`));
  el.addEventListener('submit', async (event) => {
    event.preventDefault();
    const ssid = select.value || other.value.trim();
    if (!ssid) { message.textContent = 'Choose a network, or type its name.'; return; }
    if (password.value && (password.value.length < 8 || password.value.length > 63)) { message.textContent = 'A Wi-Fi password has 8 to 63 characters.'; return; }
    button.disabled = true;
    message.textContent = '';
    try {
      await call('POST', { ssid, password: password.value, adminPassword: admin?.value ?? '' });
      done(ssid);
    } catch (error) {
      message.textContent = error.message;
      button.disabled = false;
    }
  });
  return el;
}

function done(ssid) {
  replace(root, h('img', { src: '/mark.svg', alt: '', width: 56, height: 56 }), h('h1', null, 'Joining your network'),
    h('div', { class: 'card' },
      h('p', null, `The box is restarting to join “${ssid}”. That takes about a minute.`),
      h('ol', { class: 'steps' },
        h('li', null, `Connect this phone back to “${ssid}”.`),
        h('li', null, 'Open http://camera-bridge.local in the browser (on Android, if that name doesn’t open, use the address your router shows for “camera-bridge”).')),
      h('p', { class: 'small muted' }, 'If the box can’t join (a wrong password, or the network is out of reach), its own network comes back and you can try again.')));
}

async function start() {
  try {
    const state = await call('GET');
    replace(root, h('img', { src: '/mark.svg', alt: '', width: 56, height: 56 }), h('h1', null, 'Connect Camera Bridge to your Wi-Fi'),
      state.networks.length === 0 ? h('p', { class: 'muted' }, 'No network was found. You can type its name below.') : null, form(state));
  } catch (error) {
    replace(root, h('img', { src: '/mark.svg', alt: '', width: 56, height: 56 }), h('h1', null, 'Camera Bridge'), h('p', null, error.message),
      h('p', null, h('a', { class: 'btn', href: '/' }, 'Open Camera Bridge')));
  }
}

if (root) start();

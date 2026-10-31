// Settings › Apple Home and other systems: Monitoring, for Home Assistant or Uptime Kuma. A switch (PATCH settings { monitorEnabled }) makes
// or forgets the token; while it is on, the token (hidden until Show, with Copy and New token: PATCH settings { regenerateMonitorToken: true })
// and the address GET /api/v1/monitor, which answers only with "Authorization: Bearer <token>" (read-only health: cameras, recordings, the
// archive, updates and wrong passwords).
import { confirmDialog, h } from '../dom.js';
import { icon } from '../icons.js';
import { switchRow } from './common.js';
import { copyText } from './manual-help.js';

/** The address a monitoring system asks: this page's own origin (the box's address as this browser reaches it). */
export function monitorURL(origin = globalThis.location?.origin ?? '') {
  return `${origin}/api/v1/monitor`;
}

/**
 * The card for `settings` (GET settings: monitorEnabled, monitorToken). `change(partial, message)` saves and draws Settings again;
 * `shown` and `setShown(on)` keep whether the token is shown across those draws. -> the card element
 */
export function monitorCardFor(settings, { change, shown = false, setShown = () => {}, confirm = confirmDialog, copy = copyText, say = () => {}, origin } = {}) {
  const on = settings?.monitorEnabled === true;
  const token = typeof settings?.monitorToken === 'string' ? settings.monitorToken : '';
  const address = monitorURL(origin);
  const tokenText = h('code', { class: 'monitor-token' }, shown ? token : '•'.repeat(Math.min(24, token.length || 24)));
  const addressText = h('code', { class: 'monitor-url' }, address);
  const details = on ? h('div', { class: 'stack' },
    h('div', { class: 'field' }, h('span', { class: 'label' }, 'Address'),
      h('div', { class: 'token' }, addressText,
        h('button', { class: 'btn small', type: 'button', onclick: async () => say(await copy(address, addressText)) }, icon('copy'), 'Copy'))),
    h('div', { class: 'field' }, h('span', { class: 'label' }, 'Token'),
      h('div', { class: 'token' }, tokenText,
        h('button', { class: 'btn small', type: 'button', 'aria-pressed': String(shown), onclick: () => setShown(!shown) }, icon(shown ? 'eyeOff' : 'eye'), shown ? 'Hide' : 'Show'),
        h('button', { class: 'btn small', type: 'button', onclick: async () => {
          if (!shown) { setShown(true); return; }        // shown first, so that a browser without the clipboard can select it
          say(await copy(token, tokenText));
        } }, icon('copy'), 'Copy'),
        h('button', { class: 'btn small danger', type: 'button', onclick: async () => {
          if (await confirm({ title: 'Make a new token?', body: 'Home Assistant, Uptime Kuma or anything else that uses the current token stops getting answers until you give it the new one.', confirm: 'Make a new token', danger: true })) {
            change({ regenerateMonitorToken: true }, 'New token ready.');
          }
        } }, 'New token')),
      h('span', { class: 'hint' }, 'Send it as “Authorization: Bearer <token>”. It only reads: the cameras, recording, storage, updates and wrong passwords.'))) : null;
  return h('div', { class: 'card monitor-card' }, h('h2', null, 'Monitoring'),
    h('p', { class: 'desc' }, 'Lets Home Assistant, Uptime Kuma or another monitor check that the bridge, its cameras and its recordings are all right.'),
    switchRow({ title: 'Answer monitoring requests', checked: on,
      onchange: (value) => change({ monitorEnabled: value }, value ? 'Monitoring is on.' : 'Monitoring is off. The token no longer works.') }),
    details);
}

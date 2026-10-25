// The Wi-Fi card on the System page: where the box is on the network (and on which radio), the saved networks, and a search for others.
// 2.4 GHz gets a short warning: many cameras at once are too much for it (Camera Bridge OS moves the box to 5 GHz by itself when the network
// offers it and the signal is good, so what shows here is what is left).
import { h, spinner } from '../dom.js';
import { icon } from '../icons.js';

export const WIFI_STATES = {
  online: 'On the network.',
  hotspot: 'No network: the setup hotspot is open.',
  searching: 'Looking for a network…',
  'no-wifi': 'This computer has no Wi-Fi the bridge can use. It works with a network cable.',
  'no-hotspot': 'No network, and this Wi-Fi chip cannot open the setup hotspot. Use a network cable.',
};

export const SLOW_BAND_WARNING = '2.4 GHz is slow for many cameras; an Ethernet cable or 5 GHz is better.';

/** The band the box is on ("2.4 GHz", "5 GHz", "6 GHz") when the report says so and the box is not on a cable; else ''. */
export function wifiBand(wifi) {
  if (!wifi || wifi.wired || !wifi.ssid) return '';
  return ['2.4 GHz', '5 GHz', '6 GHz'].includes(wifi.band) ? wifi.band : '';
}

/**
 * The card for `wifi` (`GET system/wifi`), or null where it does not apply. `networks`: the last search (null before one), `busy`: the name of the
 * running job; `scan()`, `join(ssid, open)` and `forget(ssid)` are the page's actions.
 */
export function wifiCardFor(wifi, { networks = null, busy = '', scan, join, forget } = {}) {
  if (!wifi || wifi.state === 'unavailable') return null;
  const band = wifiBand(wifi);
  const where = wifi.wired ? 'Connected with a network cable.'
    : wifi.ssid ? `On the Wi-Fi network “${wifi.ssid}”${band ? ` · ${band}` : ''}.` : (WIFI_STATES[wifi.state] || wifi.message);
  return h('div', { class: 'card' }, h('h2', null, 'Wi-Fi'),
    h('p', { class: 'desc' }, 'The bridge joins a saved Wi-Fi network by itself. With no network cable and no network it can join, it opens its own setup network, “CameraBridge-…”: join it with a phone and a page asks which Wi-Fi to use.'),
    h('p', { class: 'muted' }, where),
    band === '2.4 GHz' ? h('p', { class: 'wifi-slow' }, SLOW_BAND_WARNING) : null,
    wifi.lastError ? h('p', { class: 'problems' }, wifi.lastError) : null,
    wifi.saved.length ? h('div', { class: 'found' }, wifi.saved.map((ssid) => h('div', { class: 'row' },
      h('span', null, ssid, ssid === wifi.ssid ? h('span', { class: 'small muted' }, ' · in use') : null),
      h('button', { class: 'btn small', type: 'button', disabled: !!busy, onclick: () => forget(ssid) }, 'Forget')))) : null,
    !wifi.hasWifi ? null : h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: scan }, busy === 'wifi-scan' ? spinner() : icon('search'), 'Find Wi-Fi networks'),
    networks === null ? null : networks.length === 0 ? h('p', { class: 'muted' }, 'No network was found.')
      : h('div', { class: 'found' }, networks.map((network) => h('div', { class: 'card disk' },
        h('div', null, h('strong', null, network.ssid), h('div', { class: 'small muted' }, `${network.signal}%${network.security ? ` · ${network.security}` : ' · open'}`)),
        h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: () => join(network.ssid, !network.security) }, 'Join…')))));
}

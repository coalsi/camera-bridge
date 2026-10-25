// The Secure address card on the System page: the box's https name (a real certificate through camera-bridge.app), when the certificate
// renews, what went wrong in plain words, a test for routers that hide names pointing into the home (DNS rebind protection), and the switch
// that sends the plain address to the secure one. The card shows only where the box has the pieces for it (`report.available`).
import { get, post } from '../api.js';
import { h, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { switchRow } from './common.js';

/** Where a router allows a name to point into the home, by maker. */
export const ROUTER_HELP = [
  ['FRITZ!Box', 'Home Network › Network › Network Settings › Home Network, then add box.camera-bridge.app under “DNS rebind protection”.'],
  ['OpenWrt', 'Network › DHCP and DNS › General, then add box.camera-bridge.app to “Domain whitelist”.'],
  ['pfSense', 'Services › DNS Resolver › General Settings › Custom Options: private-domain: "box.camera-bridge.app".'],
  ['DD-WRT', 'Services › Services › Additional DNSMasq Options: rebind-domain-ok=/box.camera-bridge.app/'],
  ['Ubiquiti and others', 'Look for “DNS rebind protection” (or “DNS rebinding”) in the router’s DNS settings and allow box.camera-bridge.app.'],
];

function dateText(value) {
  return new Date(value).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
}

/**
 * The card for `report` (`GET system/secure-address`), or null where it does not apply. `actions` are called with the new report:
 * `{ retry, check, setRedirect }` return promises; the card asks `redraw()` to draw it again when one ends.
 */
export function secureAddressCard(report, { busy = '', retry, check, setRedirect, rebind = report?.rebind } = {}) {
  if (!report?.available) return null;
  const parts = [h('h2', null, icon('lock', { size: 18 }), ' Secure address')];
  if (report.state === 'ready') {
    parts.push(
      h('p', { class: 'desc' }, 'Your bridge’s secure address is ', h('a', { href: report.url, class: 'secure-url' }, report.url),
        '. Open it once, then install the app from there.'),
      h('p', { class: 'muted secure-renews' }, report.renewsOn
        ? `The certificate renews by itself around ${dateText(report.renewsOn)} (it is valid until ${dateText(report.expiresOn)}).`
        : 'The certificate renews by itself before it ends.'));
  } else if (report.state === 'error') {
    parts.push(h('div', { class: 'banner warning', role: 'alert' }, h('div', { class: 'text' }, report.problem?.message || 'The secure address could not be set up.')),
      h('p', { class: 'muted' }, 'The plain address, http://camera-bridge.local, keeps working. The box tries again by itself.'),
      h('div', { class: 'row' }, h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: retry }, busy === 'retry' ? spinner() : null, 'Try again now')));
  } else {
    parts.push(h('p', { class: 'desc' }, report.state === 'waiting'
      ? 'The box is getting its certificate. This takes a few minutes. The plain address works meanwhile.'
      : 'The box will set up a secure address by itself once it has internet.'));
    if (report.state === 'waiting' && report.problem) parts.push(h('p', { class: 'muted', role: 'status' }, report.problem.message));
  }
  if (report.host) {
    parts.push(h('div', { class: 'row' },
      h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: check }, busy === 'check' ? spinner() : null, 'Test this address')));
    if (rebind) parts.push(rebindResult(rebind));
  }
  parts.push(switchRow({ title: 'Send camera-bridge.local to the secure address', checked: report.redirect, disabled: !!busy,
    desc: report.redirectActive ? 'Pages opened at the plain address move to the secure one. The bridge’s other helpers keep using the plain address.'
      : 'Takes effect once the secure address works. Turn it off to keep using the plain address.',
    onchange: setRedirect }));
  return h('div', { class: 'card secure-address' }, parts);
}

function rebindResult(rebind) {
  if (rebind.state === 'ok') return h('p', { class: 'muted secure-rebind ok', role: 'status' }, icon('check'), ` ${rebind.message}`);
  if (rebind.state !== 'blocked') return h('p', { class: 'muted secure-rebind', role: 'status' }, rebind.message);
  return h('div', { class: 'banner warning secure-rebind blocked', role: 'status' }, h('div', { class: 'text' },
    h('span', { class: 'title' }, rebind.message),
    'The secure address needs your router to allow the name box.camera-bridge.app. The plain address keeps working meanwhile. In the router’s settings:',
    h('ul', null, ROUTER_HELP.map(([maker, steps]) => h('li', null, h('strong', null, maker), ': ', steps)))));
}

/** The card with its own state: loads the report and draws itself into a host element. */
export function secureAddressSection(onChange = () => {}) {
  const host = h('div', null);
  let report = null;
  let busy = '';
  let destroyed = false;
  const draw = () => {
    if (destroyed) return;
    const card = secureAddressCard(report, { busy, retry: () => act('retry', () => post('system/secure-address/retry', {})),
      check: () => act('check', async () => { const answer = await post('system/secure-address/check', {}); return { ...report, rebind: answer.rebind }; }),
      setRedirect: (enabled) => act('redirect', () => post('system/secure-address/redirect', { enabled })) });
    replace(host, card);
    onChange();
  };
  async function act(name, work) {
    busy = name;
    draw();
    try { report = await work(); } catch (error) { toast(error.message, 'error'); }
    busy = '';
    draw();
  }
  get('system/secure-address').then((value) => { report = value; draw(); }).catch(() => {});
  // While the certificate is on its way, look again now and then.
  const timer = setInterval(async () => {
    if (!report || (report.state === 'ready' && !busy) || busy) return;
    try { report = { ...(await get('system/secure-address')), rebind: report.rebind ?? undefined }; draw(); } catch { /* the next try */ }
  }, 10000);
  return { el: host, destroy() { destroyed = true; clearInterval(timer); } };
}

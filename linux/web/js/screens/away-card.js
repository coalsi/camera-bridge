// Settings › Away from home: the box's own VPN, which lets a paired iPhone, or a device with the WireGuard app, reach the box from anywhere
// over IPv6, straight to the home (docs/superpowers/specs/2026-11-12-away-from-home-design.md). The card says each state of the box's card
// (GET away: { on, state, problem, port, address, name, router, addressChangedAt, devices }) in plain words: off; checking; no IPv6 at home;
// the router step (an eero's own four steps, or one sentence for any other router) with how to check it from the phone; working, with when
// each device last reached the box from away; the address changed; a problem, with Try again. The switch is POST away { on }; turning it on
// turns the secure address on too, and the card says so. Each device has Remove (DELETE away/devices/:id, asked first). "Add a device with
// the WireGuard app" (POST away/devices { name } -> 201 { device, config }) shows the device's configuration once, as a QR code its app
// scans (qr.js): the box keeps only the device's public key, and the page keeps nothing of it once the dialog closes. While on, the card
// reads itself again every 15 s, and until a first read works it keeps trying; a read that changes only the device lines' times updates
// them in place, so the keyboard, an open Check and the problem's alert stay as they are. A box without Away from home (503 unavailable)
// gets one line and no switch.
import { del, get, post } from '../api.js';
import { confirmDialog, h, modal, promptDialog, replace, svg, toast } from '../dom.js';
import { timeAgo } from '../format.js';
import { encodeQR, qrPath } from '../qr.js';
import { inlineError, switchRow } from './common.js';

/** The card's words. The user guide gives the eero steps exactly as `routerStep` says them. */
export const AWAY_TEXT = Object.freeze({
  // The Settings section above the card is "Away from home" already, so the card's heading and its switch say it in other words.
  heading: 'Watch from anywhere',
  switchTitle: 'Use Away from home',
  description: 'Your iPhone, or any device with the WireGuard app, can watch your cameras from anywhere, straight from your home, with nothing in between. Turn it on here; your router may need one setting too.',
  unavailable: 'Away from home is part of Camera Bridge OS.',
  checking: 'Looking at how your home reaches the internet…',
  noIPv6: 'Phones can’t reach this home from outside yet, because the internet connection has no IPv6. Ask your provider whether they offer it.',
  router: 'On your router',
  check: 'Check',
  checkHow: 'On your iPhone, turn off Wi-Fi and open the Camera Bridge app. When it reaches the box from away, this card names the phone.',
  checkWireGuard: 'On a device with the WireGuard app, turn the tunnel on while the device is off your home network (on a phone, turn off Wi-Fi). When it reaches the box from away, this card names the device.',
  // Until a device has it. The iPhone app's switch comes with an update; the WireGuard app works for any device meanwhile.
  phoneStep: 'Turn on Away from home in the Camera Bridge app on your iPhone, or add a device for the WireGuard app below.',
  addressChanged: 'Your home’s address changed. The router rule needs the new one:',
  // A WireGuard app's configuration holds the box's address itself (the away name holds only a TXT record, which the app can't read), and
  // the box keeps no device's private key to show its code again.
  newCodes: 'Devices with the WireGuard app need a new code too: remove each one, then add it again.',
  address: 'The box’s address on the internet: ',
  website: 'The camera-bridge.app website, an outside service, keeps the box’s away name pointed at your home and sees nothing else. While it is down, phones use the last address they know.',
  tryAgain: 'Try again',
  add: 'Add a device with the WireGuard app',
  secureToo: 'The secure address is on too: Away from home needs it.',
  shownOnce: 'Shown once: the box keeps only the device’s public key.',
  unreadable: 'Away from home can’t be read right now.',
});

/** The port the router lets in, when the card doesn't say (it always does: Away from home uses no other). */
const PORT = 51820;

/**
 * The last four groups of an IPv6 address, written out the way eero lists a device's addresses (lower case, no leading zeros, a zero
 * group as 0): '2001:db8:4:7000::1' → '0:0:0:1'. '' for anything that isn't an IPv6 address.
 */
export function addressTail(address) {
  const text = String(address ?? '').trim().replace(/^\[(.*)\]$/, '$1').toLowerCase();
  if (!/^[0-9a-f:]+$/.test(text) || text.split('::').length > 2) return '';
  const groupsOf = (part) => (part ? part.split(':') : []);
  let groups = groupsOf(text);
  if (text.includes('::')) {
    const [head, tail] = text.split('::').map(groupsOf);
    const zeros = 8 - head.length - tail.length;
    if (zeros < 1) return '';
    groups = [...head, ...Array(zeros).fill('0'), ...tail];
  }
  if (groups.length !== 8 || !groups.every((group) => /^[0-9a-f]{1,4}$/.test(group))) return '';
  return groups.slice(4).map((group) => parseInt(group, 16).toString(16)).join(':');
}

/**
 * The router step for `card` (its `router`, `address` and `port`): { brand, steps }. An eero gets its own app's four steps, which tell the box apart by
 * its address and never by a name (owners rename devices in the eero app); any other router gets the rule itself and where routers keep it.
 */
export function routerStep(card) {
  const port = card?.port ?? PORT;
  if (card?.router === 'eero') {
    return {
      brand: 'eero',
      steps: [
        'In the eero app: Settings › Network settings › Reservations & port forwarding › IPv6 firewall rules › Add.',
        'Choose the device that is the box. The eero app lists devices by name and may show it under a name you gave it; the address in the next step tells you which one it is.',
        // The eero app offers each of the device's addresses, temporary ones too; only the box's stable address keeps working.
        `Choose the address ending in ${addressTail(card.address)} (exactly that one).`,
        `Enter port ${port}, UDP.`,
      ],
    };
  }
  return {
    brand: null,
    steps: [
      `Allow incoming IPv6 traffic to ${card?.address ?? 'the box'}, UDP port ${port}.`,
      'Routers usually keep that setting with their firewall or port forwarding settings, often under IPv6.',
    ],
  };
}

const nameOf = (device) => device?.name || 'Device';

/** 'Reached from away: Laptop, 5 minutes ago.', or 'Laptop hasn’t reached the box from away yet.' (a handshake at home doesn't count). */
export function deviceLine(device, now = Date.now()) {
  const at = Date.parse(device?.lastAwayAt ?? '');
  if (!Number.isFinite(at)) return `${nameOf(device)} hasn’t reached the box from away yet.`;
  // The box's clock may run a little ahead of this browser's: a time to come is "just now".
  return `Reached from away: ${nameOf(device)}, ${timeAgo(Math.min(at, now), now)}.`;
}

/** What Remove asks: an iPhone stays paired and loses only its way in from away; a WireGuard device needs a new code to come back. */
function removeQuestion(device) {
  const name = nameOf(device);
  if (device.kind === 'app') {
    return { title: `Remove ${name} from Away from home?`, confirm: 'Remove', danger: true,
      body: `${name} stays paired and keeps working at home. To reach the box from away again, turn on Away from home in its Camera Bridge app.` };
  }
  return { title: `Remove ${name}?`, confirm: 'Remove', danger: true,
    body: `${name} can’t reach the box from away any more. To use it again, add it again and scan the new code.` };
}

/** Turning it off takes every device's way in at once, so the switch asks first while there is a device to lose it. */
const TURN_OFF = Object.freeze({ title: 'Turn off Away from home?', confirm: 'Turn off', danger: true,
  body: 'The box closes its VPN and forgets every device’s key at once. Each device has to be set up again to reach the box from away.' });

/** The first `input` inside `node`: the switch inside a switchRow's label. */
function firstInput(node) {
  for (const child of node?.childNodes ?? []) {
    if (child.localName === 'input') return child;
    const inside = firstInput(child);
    if (inside) return inside;
  }
  return null;
}

/** The name of a new device with the WireGuard app: the text typed, or undefined when cancelled. */
const askDeviceName = () => promptDialog({ title: AWAY_TEXT.add, label: 'Name', placeholder: 'Laptop', confirm: 'Add',
  body: 'The box makes a key for the device and shows it once, as a QR code to scan with the WireGuard app.' });

/** The QR code of `text` as an SVG with its quiet zone, or null for a text too long for one (no configuration is). */
function qrPicture(text, label) {
  let code;
  try { code = encodeQR(text); } catch { return null; }
  const side = code.size + 8;
  return svg('svg', { viewBox: `0 0 ${side} ${side}`, role: 'img', 'aria-label': label, 'shape-rendering': 'crispEdges' },
    svg('rect', { width: side, height: side, fill: '#fff' }), svg('path', { d: qrPath(code), fill: '#000' }));
}

/**
 * The dialog that shows a new WireGuard device's configuration once: the QR code, the text folded under it (a computer pastes it), and that it
 * is shown once. It resolves when closed; the dialog leaves the page then, and with it the only copy of the device's private key.
 */
export function showConfigQR(config, device = {}) {
  const name = nameOf(device);
  return modal((close) => h('div', { class: 'away-qr-dialog' },
    h('h2', null, 'Scan this with the WireGuard app'),
    h('p', { class: 'muted' }, `In the WireGuard app on ${name}, add a tunnel from a QR code and scan this one. On a computer, use the text below instead.`),
    h('div', { class: 'qr away-qr' }, qrPicture(config, `The QR code of ${name}’s configuration`)),
    h('details', { class: 'away-config' }, h('summary', null, 'The configuration as text'), h('pre', null, config)),
    h('p', { class: 'small muted' }, AWAY_TEXT.shownOnce),
    h('div', { class: 'buttons' }, h('button', { class: 'btn primary', type: 'button', onclick: () => close() }, 'Done'))),
  { label: `${name}’s configuration` }).then(() => undefined);
}

/**
 * The card -> { el, refresh(), destroy() }. Everything it calls can be given:
 *   load()               GET away, the card document; setOn(on) POST away { on }, the card document
 *   addDevice(name)      POST away/devices { name } -> { device, config }; removeDevice(id) DELETE away/devices/:id
 *   secureAddress()      GET system/secure-address, whose `enabled` says whether turning on also turns the secure address on
 *   confirm(question)    asks before Remove and before turning off; askName() the new device's name; showQR(config, device) the dialog
 *   now()                the time, in ms; every: how often the card reads itself again while on
 */
export function createAwayCard({ load = () => get('away'), setOn = (on) => post('away', { on }), addDevice = (name) => post('away/devices', { name }),
  removeDevice = (id) => del('away/devices/' + encodeURIComponent(id)), secureAddress = () => get('system/secure-address'), confirm = confirmDialog,
  askName = askDeviceName, showQR = showConfigQR, now = Date.now, every = 15_000 } = {}) {
  const body = h('div', { class: 'away-body' });
  const el = h('section', { class: 'card away-card', 'aria-labelledby': 'away-heading' },
    h('h2', { id: 'away-heading', tabindex: '-1' }, AWAY_TEXT.heading),   // #/settings/away puts the keyboard here
    body);
  let card = null;          // the box's latest card document
  let unavailable = false;  // GET away answered 503 unavailable: this system has no Away from home
  let unread = '';          // why the card couldn't be read
  let said = '';            // the box's refusal of the owner's last action
  let busy = false;         // an action is out: its controls wait
  let destroyed = false;
  let timer = null;
  let asked = 0;            // each request for a card document gets a number; an answer older than the one drawn is dropped
  let shown = 0;
  let drawn = '';           // what the card shows now apart from the device lines' text, so a read that changed nothing else redraws nothing
  let lineNodes = [];       // the device lines drawn, in order, whose text a read updates in place
  let keyed = new Map();    // the controls drawn, by their key, so a redraw can give the keyboard back to the same one
  let waiting;              // the key of a control that had the keyboard and was disabled while an action ran
  let checkOpen = false;    // the owner opened Check: it stays open across redraws

  function draw({ force = false } = {}) {
    if (destroyed) return;
    const at = now();
    const lines = (card?.devices ?? []).map((device) => deviceLine(device, at));
    // Everything drawn, apart from the device lines' text, which changes every minute ("5 minutes ago") and is updated in place: a read every
    // 15 s then moves no keyboard focus, closes no Check and doesn't say the problem's alert again. A handshake time isn't shown at all.
    const signature = JSON.stringify([shape(card), unavailable, unread, said, busy]);
    if (!force && signature === drawn) {
      lines.forEach((line, index) => { if (lineNodes[index] && lineNodes[index].textContent !== line) lineNodes[index].textContent = line; });
      return;
    }
    drawn = signature;
    // The keyboard goes back to the same control in the new drawing. A control that waits for an action (busy) is disabled and can't take
    // it, so it gets it back when the action ends, unless the keyboard went somewhere else meanwhile.
    const active = globalThis.document?.activeElement;
    const dropped = !active || active === globalThis.document?.body;
    const focused = active && body.contains(active) ? active.dataset?.key : dropped ? waiting : undefined;
    lineNodes = [];
    keyed = new Map();
    replace(body, content(lines));
    const target = focused ? keyed.get(focused) : undefined;
    waiting = target?.disabled ? focused : undefined;
    if (target && !target.disabled) target.focus();
  }

  /** What of `shownCard` the card draws, besides the device lines' text. */
  function shape(shownCard) {
    if (!shownCard) return null;
    const { on, state, problem, port, address, router, devices } = shownCard;
    return { on, state, problem, port, address, router, devices: devices.map(({ id, kind, name }) => [id, kind, name]) };
  }

  /** `element` as the control `key` names, so the keyboard goes back to its new copy after a redraw. */
  function control(key, element) {
    element.dataset.key = key;
    keyed.set(key, element);
    return element;
  }

  function content(lines) {
    if (unavailable) return h('p', { class: 'muted away-unavailable' }, AWAY_TEXT.unavailable);
    const parts = [h('p', { class: 'desc' }, AWAY_TEXT.description)];
    if (!card) return [...parts, unread ? inlineError(unread) : null];
    const row = switchRow({ title: AWAY_TEXT.switchTitle, checked: card.on, disabled: busy, onchange: (value) => turn(value) });
    const input = firstInput(row);
    if (input) control('switch', input);
    parts.push(row);
    if (unread) parts.push(inlineError(unread));
    parts.push(stateParts(card));
    if (card.on && card.devices.length) parts.push(deviceList(lines));
    if (said) parts.push(h('div', { class: 'away-said' }, inlineError(said)));
    if (card.on && card.address) {
      parts.push(h('div', { class: 'row' }, control('add', h('button', { class: 'btn', type: 'button', disabled: busy, onclick: () => addWireGuard() }, AWAY_TEXT.add))));
    }
    if (card.on) parts.push(h('p', { class: 'small muted away-website' }, AWAY_TEXT.website));
    return parts;
  }

  function stateParts(shownCard) {
    const hasWireGuard = shownCard.devices.some((device) => device.kind === 'wireguard');
    switch (shownCard.state) {
      case 'checking':
        return h('p', { class: 'away-note', role: 'status' }, AWAY_TEXT.checking);
      case 'no_ipv6':
        return h('p', { class: 'away-note', role: 'status' }, AWAY_TEXT.noIPv6);
      case 'setup':
        return [
          routerPart(shownCard),
          h('details', { class: 'away-check', open: checkOpen, ontoggle: (event) => { checkOpen = !!event.target?.open; } },
            control('check', h('summary', null, AWAY_TEXT.check)), h('p', null, AWAY_TEXT.checkHow), h('p', null, AWAY_TEXT.checkWireGuard)),
          // Once a device has it, of either kind, the next step is the router's and Check.
          shownCard.devices.length ? null : h('p', { class: 'away-phone' }, AWAY_TEXT.phoneStep),
        ];
      case 'working':
        return shownCard.address ? h('p', { class: 'small muted away-address' }, AWAY_TEXT.address, h('code', null, shownCard.address)) : null;
      case 'address_changed':
        return [
          h('p', { class: 'away-changed' }, AWAY_TEXT.addressChanged),
          h('p', { class: 'away-address' }, h('code', null, shownCard.address)),
          routerPart(shownCard),
          hasWireGuard ? h('p', null, AWAY_TEXT.newCodes) : null,
        ];
      case 'problem':
        return h('div', { class: 'banner warning away-problem', role: 'alert' }, h('div', { class: 'text' }, shownCard.problem || 'Away from home isn’t working.',
          h('div', { class: 'actions' }, control('try-again', h('button', { class: 'btn small', type: 'button', disabled: busy, onclick: () => tryAgain() }, AWAY_TEXT.tryAgain)))));
      default:
        return null;
    }
  }

  function routerPart(shownCard) {
    if (!shownCard.address) return null;
    const { brand, steps } = routerStep(shownCard);
    return h('div', { class: 'away-router' }, h('h3', null, AWAY_TEXT.router),
      brand ? h('ol', { class: 'away-steps' }, steps.map((step) => h('li', null, step))) : steps.map((step) => h('p', null, step)));
  }

  function deviceList(lines) {
    return h('ul', { class: 'away-devices' }, card.devices.map((device, index) => {
      const line = h('span', { class: 'away-device-line' }, lines[index]);
      lineNodes.push(line);
      return h('li', { class: 'away-device row spread', dataset: { id: device.id } }, line,
        control(`remove:${device.id}`, h('button', { class: 'btn small', type: 'button', disabled: busy, 'aria-label': `Remove ${nameOf(device)}`, onclick: () => remove(device) }, 'Remove')));
    }));
  }

  /** Takes a card document the box answered to request number `ticket`, unless a newer one is drawn already. */
  function accept(ticket, answer) {
    if (destroyed || ticket < shown) return false;
    shown = ticket;
    card = answer && typeof answer === 'object' ? { ...answer, devices: Array.isArray(answer.devices) ? answer.devices : [] } : null;
    unavailable = false;
    unread = '';
    draw();
    return true;
  }

  /**
   * While on, the card is read again `every` ms; off, unavailable or gone, it isn't. Until a first read has worked it is tried again as often:
   * the box may be restarting, and the card would otherwise say it can't be read until the page is opened again.
   */
  function schedule() {
    clearTimeout(timer);
    timer = null;
    if (destroyed || unavailable || !(card?.on || (!card && unread))) return;
    timer = setTimeout(refresh, every);
  }

  async function refresh() {
    if (destroyed) return;
    const ticket = ++asked;
    try {
      accept(ticket, await load());
    } catch (error) {
      if (destroyed || ticket < shown) return;
      shown = ticket;
      if (error?.status === 503 && error?.code === 'unavailable') {
        unavailable = true;
        card = null;
      } else {
        unread = error?.message || AWAY_TEXT.unreadable;
      }
      draw();
    }
    schedule();
  }

  /** Runs one of the owner's actions: its controls wait meanwhile, and a refusal is said on the card (`fallback` when it has no words). */
  async function act(work, fallback) {
    busy = true;
    said = '';
    draw();
    try {
      await work();
    } catch (error) {
      said = error?.message || fallback;
    } finally {
      // Always drawn again, since the controls stop waiting: a switch the box refused goes back to what the card says.
      busy = false;
      draw();
      schedule();
    }
  }

  async function turn(on) {
    if (busy || destroyed || !card) return;
    if (!on && card.devices.length && !(await confirm(TURN_OFF))) {
      // Nothing changed, so only a forced draw puts back the switch the owner moved.
      draw({ force: true });
      return;
    }
    if (destroyed) return;
    await act(async () => {
      // The box turns the secure address on with Away from home; asked first, so the page can say it did.
      const secureWasOff = on ? await secureAddress().then((report) => report?.enabled === false, () => false) : false;
      if (accept(++asked, await setOn(on)) && secureWasOff) toast(AWAY_TEXT.secureToo, 'ok');
    }, 'Away from home couldn’t be changed.');
  }

  /** Sends the same choice again: the box keeps the owner's choice when its system doesn't take it, and tries again with it. */
  async function tryAgain() {
    if (busy || destroyed || !card) return;
    const choice = card.on;
    await act(async () => { accept(++asked, await setOn(choice)); }, 'Away from home couldn’t be changed.');
  }

  async function addWireGuard() {
    if (busy || destroyed) return;
    const name = await askName();
    if (name === undefined || name === null || destroyed) return;
    let added = null;
    await act(async () => { added = await addDevice(name); }, 'That device couldn’t be added.');
    if (!added || destroyed) return;
    refresh();
    // The configuration goes to the dialog and nowhere else: not to the card, not to the browser's storage.
    await showQR(added.config, added.device);
  }

  async function remove(device) {
    if (busy || destroyed) return;
    if (!(await confirm(removeQuestion(device))) || destroyed) return;
    await act(async () => {
      try {
        await removeDevice(device.id);
      } catch (error) {
        if (error?.status !== 404) throw error;   // 404: it is gone already
      }
      card = { ...card, devices: card.devices.filter((other) => other.id !== device.id) };
    }, 'That device couldn’t be removed.');
    await refresh();
    // A removal the system didn't take (503 `system`) stays removed on the box, which tries again and says so in its card's problem; that
    // sentence holds the refusal's, so it is said once.
    if (said && card?.state === 'problem' && card.problem?.includes(said)) {
      said = '';
      draw();
    }
  }

  refresh();
  return { el, refresh, destroy() { destroyed = true; clearTimeout(timer); } };
}

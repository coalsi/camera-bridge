// "Add it to Apple Home": the QR code and setup code the server draws, how to use them, and what to do when they are not offered.
import { get, post } from '../api.js';
import { confirmDialog, h, parseSVG, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { subscribe } from '../store.js';

/**
 * `source`: 'cameras/<id>' or 'sensors-bridge'. Polls every 2 s until the accessory is in Apple Home, and follows the event stream
 * (a camera that gets paired flips the panel at once).
 */
export function pairingPanel({ cameraId, cameraName, source, intro = false, onPaired } = {}) {
  const path = source || `cameras/${cameraId}/pairing`;
  const el = h('div', { class: 'card', 'aria-live': 'polite' }, h('div', { class: 'checking' }, spinner(), 'Getting the setup code…'));
  let timer = null;
  let stopped = false;
  let lastPaired = null;

  async function refresh() {
    if (stopped) return;
    let data;
    try {
      data = await get(path);
    } catch (error) {
      if (!stopped) replace(el, h('div', { class: 'banner error' }, icon('alert'), h('div', { class: 'text' }, error.message)));
      return;
    }
    if (stopped) return;
    render(data);
    if (data.paired && lastPaired === false) onPaired?.();
    lastPaired = !!data.paired;
    schedule(data);
  }

  function schedule(data) {
    clearTimeout(timer);
    // Keep watching until it is in Home; slower once a code is on screen.
    timer = setTimeout(refresh, data.paired ? 15000 : data.setupCode ? 4000 : 1500);
  }

  async function bridgeAction(action) {
    try { await post('bridge/resume'); refresh(); } catch (error) { toast(error.message, 'error'); }
  }

  async function resetPairing() {
    if (!cameraId) return;
    const ok = await confirmDialog({
      title: `Reset pairing for “${cameraName || 'this camera'}”?`,
      body: `“${cameraName || 'This camera'}” stops working in the Home app and gets a new setup code. Remove it from the Home app, then add it again.`,
      confirm: 'Reset pairing', danger: true,
    });
    if (!ok) return;
    try {
      await post(`cameras/${cameraId}/reset-pairing`);
      toast('Pairing reset. The camera has a new setup code.', 'ok');
      lastPaired = null;
      refresh();
    } catch (error) { toast(error.message, 'error'); }
  }

  function render(data) {
    if (data.paired) {
      replace(el, h('div', { class: 'banner ok' }, icon('check'), h('div', { class: 'text' },
        h('span', { class: 'title' }, 'Added to Apple Home'),
        source ? 'The sensors bridge is in your Home.' : `“${cameraName || data.accessoryName}” is in your Home. Open the Home app to see it.`)),
      cameraId ? h('div', { class: 'row' }, h('button', { class: 'btn danger small', onclick: resetPairing }, 'Reset pairing…')) : null);
      return;
    }
    if (data.blocker || data.available === false) {
      const message = data.blockerMessage || data.message || 'The setup code is not available yet.';
      replace(el, h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' }, message,
        data.blockerAction ? h('div', { class: 'actions' }, h('button', { class: 'btn small primary', onclick: () => bridgeAction(data.blockerAction) }, data.blockerAction === 'start' ? 'Start bridge' : 'Resume bridge')) : null)));
      if (data.blocker === 'waiting') replace(el, h('div', { class: 'checking' }, spinner(), message));
      return;
    }
    const code = h('div', { class: 'setup-code', 'aria-label': `Setup code ${data.setupCode.replaceAll('-', ' ')}` }, data.setupCode);
    replace(el,
      h('div', { class: 'pairing' },
        h('div', { class: 'qr', role: 'img', 'aria-label': 'QR code to scan with the Home app' }, parseSVG(data.qrSVG)),
        h('div', { class: 'howto' },
          h('h2', null, 'Scan with the Home app'),
          code,
          h('ol', { class: 'steps' },
            h('li', null, 'On your iPhone or iPad, open the Home app.'),
            h('li', null, 'Tap Add (+), then Add Accessory.'),
            h('li', null, 'Scan this code, or choose “More options”, pick the accessory and type the code.'),
            h('li', null, 'When Home says the accessory isn’t certified, tap Add Anyway.')),
          h('p', { class: 'small muted' }, 'Your iPhone or iPad must be on the same network as this bridge for the first setup.'))));
  }

  const stop = subscribe((kind, detail) => {
    if (kind === 'camera' && detail?.id === cameraId && detail.status?.paired !== undefined && lastPaired !== null && detail.status.paired !== lastPaired) refresh();
  });
  refresh();

  return {
    el,
    destroy() {
      stopped = true;
      clearTimeout(timer);
      stop();
    },
  };
}


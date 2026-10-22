// The bridge's own state as a slim status line: paused, starting, not running. Notices are notifications now (notifications.js).
import { post } from '../api.js';
import { h, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { store, subscribe } from '../store.js';

async function bridgeAction(path) {
  try {
    await post(path);
  } catch (error) {
    toast(error.message, 'error');
  }
}

function bridgeBanner() {
  const { state, stateText } = store.bridge;
  if (state === 'running') return null;
  if (state === 'paused') {
    return h('div', { class: 'banner warning' }, icon('pause'),
      h('div', { class: 'text' }, h('span', { class: 'title' }, 'The bridge is paused'),
        'Apple Home shows your cameras as not responding until you resume it.',
        h('div', { class: 'actions' }, h('button', { class: 'btn small primary', onclick: () => bridgeAction('bridge/resume') }, 'Resume bridge'))));
  }
  if (state === 'starting') {
    return h('div', { class: 'banner info' }, icon('info'), h('div', { class: 'text' }, h('span', { class: 'title' }, 'The bridge is starting'), 'Cameras appear as they connect.'));
  }
  return h('div', { class: 'banner error' }, icon('alert'),
    h('div', { class: 'text' }, h('span', { class: 'title' }, state === 'failed' ? stateText : 'The bridge isn’t running'),
      'Apple Home can’t reach your cameras. The log shows why.',
      h('div', { class: 'actions' },
        h('button', { class: 'btn small primary', onclick: () => bridgeAction('bridge/resume') }, 'Start bridge'),
        h('a', { class: 'btn small', href: '#/logs' }, 'Open the log'))));
}

/**
 * A live region for the bridge's own state while it lasts (paused, not running, starting). It is a state, not an event, so it stays a slim
 * line; everything that happened (a notice) is a notification instead (notifications.js). Call `.destroy()` when the screen goes away.
 */
export function banners() {
  const host = h('div', { class: 'banners' });
  let shown = null;
  const render = () => {
    // Redraw only when the state changed, so a button is not rebuilt under the pointer (or the keyboard focus) by an update that says the same.
    const signature = JSON.stringify(store.bridge);
    if (signature === shown) return;
    shown = signature;
    replace(host, bridgeBanner());
  };
  render();
  const stop = subscribe((kind) => { if (kind === 'bridge') render(); });
  host.destroy = stop;
  return host;
}

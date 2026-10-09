// Messages about the bridge itself: paused, not running, and what the network is doing to live view.
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

function noticeBanner(notice) {
  return h('div', { class: `banner ${notice.severity === 'warning' ? 'warning' : 'info'}` }, icon(notice.severity === 'warning' ? 'alert' : 'info'),
    h('div', { class: 'text' }, h('span', { class: 'title' }, notice.title), notice.detail));
}

/** A live region of banners; call `.destroy()` when the screen goes away. */
export function banners() {
  const host = h('div', { class: 'banners' });
  const render = () => replace(host, bridgeBanner(), store.notices.map(noticeBanner));
  render();
  const stop = subscribe((kind) => { if (kind === 'bridge' || kind === 'notices') render(); });
  host.destroy = stop;
  return host;
}

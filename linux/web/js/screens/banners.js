// Messages about the bridge itself: paused, not running, and what the network is doing to live view.
import { post } from '../api.js';
import { h, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { loadNVR } from '../nvr/lite.js';
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

/** The button a notice can carry (`notice.action`, set by the bridge). An action this page does not know gets no button. */
const NOTICE_ACTIONS = {
  'choose-folder': { label: 'Choose where to record', run: chooseFolder },
  'open-settings': { label: 'Open Recording settings', run: () => { location.hash = '#/settings/recording'; } },
};

async function chooseFolder() {
  const nvr = await loadNVR();
  if (!nvr) {
    toast('The recording settings could not load. Reload the page and try again.', 'error');
    return;
  }
  if (await nvr.chooseStorage({ reason: 'banner' })) toast('Saved. Recording starts again in a moment.', 'ok');
}

function noticeBanner(notice) {
  const action = NOTICE_ACTIONS[notice.action];
  return h('div', { class: `banner ${notice.severity === 'warning' ? 'warning' : 'info'}` }, icon(notice.severity === 'warning' ? 'alert' : 'info'),
    h('div', { class: 'text' }, h('span', { class: 'title' }, notice.title), notice.detail,
      action ? h('div', { class: 'actions' }, h('button', { class: 'btn small primary', type: 'button', onclick: action.run }, action.label)) : null));
}

/** A live region of banners; call `.destroy()` when the screen goes away. */
export function banners() {
  const host = h('div', { class: 'banners' });
  let shown = null;
  const render = () => {
    // Redraw only when what is shown changed, so a button is not rebuilt under the pointer (or the keyboard focus) by an update that says the same.
    const signature = JSON.stringify([store.bridge, store.notices.map((n) => [n.id, n.severity, n.title, n.detail, n.action])]);
    if (signature === shown) return;
    shown = signature;
    replace(host, bridgeBanner(), store.notices.map(noticeBanner));
  };
  render();
  const stop = subscribe((kind) => { if (kind === 'bridge' || kind === 'notices') render(); });
  host.destroy = stop;
  return host;
}

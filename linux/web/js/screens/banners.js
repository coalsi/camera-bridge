// Messages about the bridge itself: paused, not running, what the network is doing to live view, recording storage, and the Internet
// guard's notice for the day, with a button for each camera that tried ("See what Patio New tried": its page at the Security card).
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

/** The internet guard's notice gives a button to at most this many cameras (the ones that tried most; the bridge lists them most first). */
export const NOTICE_CAMERA_BUTTONS = 3;

/** Asks the camera page on screen to bring its Security card into view again: `detail` is the camera's id (camera.js listens on window). */
export const SHOW_SECURITY_EVENT = 'cb-show-security';

/** The address of a camera's page opened at its Security card (app.js routes it to camera.js, which scrolls to the card). */
export function securityAddress(id) {
  return `#/camera/${id}/security`;
}

const CAMERA_ID = /^[0-9A-Fa-f-]{36}$/;

/**
 * Opens camera `id`'s page at its Security card. When that camera's page is already on screen (with or without the card in its address),
 * the page is asked to show the card again instead (`SHOW_SECURITY_EVENT`), so nothing on it is built again.
 */
export function openCameraSecurity(id) {
  const shown = /^#\/?camera\/([0-9A-Fa-f-]{36})(?:\/security)?\/?$/.exec(location.hash);
  if (shown && shown[1].toLowerCase() === String(id).toLowerCase()) {
    window.dispatchEvent(new CustomEvent(SHOW_SECURITY_EVENT, { detail: shown[1] }));
    return;
  }
  location.hash = securityAddress(id);
}

/** The usable cameras of `list`: each { id, name, mostAsked }; one without a usable id is left out, one without a name takes the name the
 *  page has for it; `mostAsked` (the name it asked for most, as the bridge shows it) or null. */
function usableCameras(list) {
  return list.filter((camera) => camera && typeof camera.id === 'string' && CAMERA_ID.test(camera.id)).map((camera) => ({
    id: camera.id,
    name: typeof camera.name === 'string' && camera.name.trim() ? camera.name.trim() : store.cameras.get(camera.id)?.name || 'this camera',
    mostAsked: typeof camera.mostAsked === 'string' && camera.mostAsked ? camera.mostAsked : null,
  }));
}

/**
 * The cameras an "open-camera" notice names, most first: its `cameras` list (the internet guard's, since 2026-10-18), else, when there is
 * none or none of it is usable (a bridge from before), the one camera of `cameraID` and `cameraName`. Each { id, name, mostAsked }.
 */
export function noticeCameras(notice) {
  const listed = usableCameras(Array.isArray(notice?.cameras) ? notice.cameras : []);
  return listed.length ? listed : usableCameras(notice?.cameraID ? [{ id: notice.cameraID, name: notice.cameraName }] : []);
}

/**
 * The buttons a notice can carry (`notice.action`, set by the bridge), each { label, run, title }. An action this page does not know gets
 * no button. "open-camera" gives one button for each camera the notice names, at most `NOTICE_CAMERA_BUTTONS`: on the internet guard's
 * notice "See what Patio New tried", which opens that camera's page at its Security card, its tooltip the name it asked for most ("Most
 * asked: *.p2p.example.com"); on another notice "Open Patio New".
 */
const NOTICE_ACTIONS = {
  'choose-folder': () => [{ label: 'Choose where to record', run: chooseFolder }],
  'open-settings': () => [{ label: 'Open Recording settings', run: () => { location.hash = '#/settings/recording'; } }],
  'open-camera': (notice) => noticeCameras(notice).slice(0, NOTICE_CAMERA_BUTTONS).map((camera) => (notice.kind === 'internetGuard'
    ? { label: `See what ${camera.name} tried`, run: () => openCameraSecurity(camera.id), title: camera.mostAsked ? `Most asked: ${camera.mostAsked}` : null }
    : { label: `Open ${camera.name}`, run: () => { location.hash = `#/camera/${camera.id}`; } })),
};

async function chooseFolder() {
  const nvr = await loadNVR();
  if (!nvr) {
    toast('The recording settings could not load. Reload the page and try again.', 'error');
    return;
  }
  if (await nvr.chooseStorage({ reason: 'banner' })) toast('Saved. Recording starts again in a moment.', 'ok');
}

/** One notice's banner: its title, its text and its buttons (the first one primary). */
export function noticeBanner(notice) {
  const actions = Object.hasOwn(NOTICE_ACTIONS, notice.action) ? NOTICE_ACTIONS[notice.action](notice) : [];
  return h('div', { class: `banner ${notice.severity === 'warning' ? 'warning' : 'info'}` }, icon(notice.severity === 'warning' ? 'alert' : 'info'),
    h('div', { class: 'text' }, h('span', { class: 'title' }, notice.title), notice.detail,
      actions.length ? h('div', { class: 'actions' }, actions.map((action, index) =>
        h('button', { class: index === 0 ? 'btn small primary' : 'btn small', type: 'button', title: action.title ?? null, onclick: action.run }, action.label))) : null));
}

/** A live region of banners; call `.destroy()` when the screen goes away. */
export function banners() {
  const host = h('div', { class: 'banners' });
  let shown = null;
  const render = () => {
    // Redraw only when what is shown changed, so a button is not rebuilt under the pointer (or the keyboard focus) by an update that says the same.
    const signature = JSON.stringify([store.bridge, store.notices.map((n) => [n.id, n.severity, n.title, n.detail, n.action, noticeCameras(n)])]);
    if (signature === shown) return;
    shown = signature;
    replace(host, bridgeBanner(), store.notices.map(noticeBanner));
  };
  render();
  const stop = subscribe((kind) => { if (kind === 'bridge' || kind === 'notices') render(); });
  host.destroy = stop;
  return host;
}

// Cameras (#/cameras): managing them. One row per camera with everything about it: a small picture (with its date and time), what it is and
// where, whether it answers, its video, recording, events and Apple Home, and the way into its page. Watching live is the Monitor's job, so
// the pictures here are small and refreshed slowly, and only while the row is on screen.
import { h, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { loadNVR, nvrSupported } from '../nvr/lite.js';
import { cameraList, subscribe } from '../store.js';
import { stampText } from '../stamp.js';
import { banners } from './banners.js';
import { kindName, lastEventText, statePill } from './common.js';

const THUMB_INTERVAL = 30_000;

// The last picture of each camera (its address and when it was taken), kept while the bridge's pages are visited: coming back shows it at once.
const lastPictures = new Map();

function eventsText(camera) {
  const s = camera.status;
  if (camera.vendor === 'rtsp') return 'None (RTSP cameras send no events)';
  if (camera.vendor === 'go2rtc') return 'Built-in motion detection';
  return s?.eventChannelConnected ? 'Connected' : 'Not connected';
}

function recordingText(camera) {
  const s = camera.status;
  if (!nvrSupported(camera)) return null;
  if (!camera.nvrEnabled) return 'Off';
  return s?.nvr?.pause ? 'Paused' : 'Recording';
}

/** One labelled value of a row: on a phone the label shows above it. */
function field(label, ...value) {
  return h('td', { dataset: { label } }, ...value);
}

function cameraRow(camera) {
  const img = h('img', { alt: '', decoding: 'async', hidden: true });
  const placeholder = h('span', { class: 'cam-thumb-empty' }, icon('camera'));
  const stamp = h('span', { class: 'cam-thumb-stamp', hidden: true });
  const thumb = h('a', { class: 'cam-thumb', href: `#/camera/${camera.id}`, tabindex: '-1', 'aria-hidden': 'true' }, img, placeholder, stamp);
  const name = h('a', { class: 'cam-name', href: `#/camera/${camera.id}` });
  const what = h('span', { class: 'cam-what' });
  const status = h('td', { dataset: { label: 'Status' } });
  const video = field('Video');
  const recordHost = h('div');
  const recording = field('Recording', recordHost);
  const events = field('Events');
  const home = field('Apple Home');
  const row = h('tr', { dataset: { id: camera.id } },
    h('td', { class: 'cam-main' }, thumb, h('div', { class: 'cam-ident' }, name, what)),
    status, video, recording, events, home,
    h('td', { class: 'cam-open' }, h('a', { class: 'btn small', href: `#/camera/${camera.id}` }, 'Open', icon('chevron'))));

  let current = camera;
  let loaded = false;
  let recordHandle = null;
  let gone = false;
  row.visible = false;

  function showLast() {
    const last = lastPictures.get(current.id);
    if (!last || loaded) return;
    img.src = last.url; img.hidden = false; placeholder.hidden = true; loaded = true;
    replace(stamp, stampText(last.at)); stamp.hidden = false;
  }

  row.refreshPicture = () => {
    if (gone) return;
    if (!row.visible) { showLast(); return; }
    if (!(current.isEnabled && current.status?.connection === 'online')) { showLast(); return; }
    const url = `/api/v1/cameras/${current.id}/snapshot?t=${Date.now()}`;
    const next = new Image();
    next.onload = () => {
      if (gone) return;
      const at = Date.now();
      lastPictures.set(current.id, { url, at });
      img.src = url; img.hidden = false; placeholder.hidden = true; loaded = true;
      replace(stamp, stampText(at)); stamp.hidden = false;
    };
    next.src = url;
  };

  row.update = (next) => {
    current = next;
    const s = next.status;
    replace(name, next.name);
    replace(what, [kindName(next), next.vendorName, next.address].filter(Boolean).join(' · '));
    replace(status, statePill(next), s?.connection === 'offline' && s.connectionReason ? h('div', { class: 'cam-sub warn' }, s.connectionReason) : null);
    replace(video, s?.videoSummary || h('span', { class: 'faint' }, 'No picture yet'),
      s?.subStreamProblem ? h('div', { class: 'cam-sub warn' }, `Sub stream: ${s.subStreamProblem}`) : null);
    const rec = recordingText(next);
    if (!recordHandle) replace(recordHost, rec ? h('span', null, rec) : h('span', { class: 'faint' }, 'Not available'));
    const homeRec = s?.recordingNow ? 'Home is recording now' : s?.recordingEnabled ? 'Home recording on' : null;
    recording.querySelector('.cam-sub')?.remove();
    if (homeRec) recording.append(h('div', { class: 'cam-sub' }, homeRec));
    const last = lastEventText(next);
    replace(events, eventsText(next), last ? h('div', { class: 'cam-sub' }, last) : null);
    replace(home, s?.paired
      ? h('span', { class: 'home-state ok' }, icon('check'), 'Added')
      : next.isEnabled ? h('a', { class: 'btn small', href: `#/camera/${next.id}/pair` }, 'Add to Apple Home') : h('span', { class: 'faint' }, 'Turned off'));
    row.dataset.state = !next.isEnabled ? 'off' : s?.connection ?? 'connecting';
  };

  row.update(camera);
  showLast();
  if (nvrSupported(camera)) {
    loadNVR().then((nvr) => {
      if (gone || !nvr) return;
      recordHandle = nvr.recordSwitch(camera, { variant: 'panel' });
      replace(recordHost, recordHandle.el);
    });
  }
  row.destroy = () => { gone = true; recordHandle?.destroy(); img.removeAttribute('src'); };
  return row;
}

export function renderCameras() {
  const bannerHost = banners();
  const content = h('div');
  const summary = h('p', { class: 'lede' });
  const rows = new Map();
  let timer = null;

  // Only the rows on screen load a picture.
  const onScreen = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      const row = entry.target;
      const was = row.visible;
      row.visible = entry.isIntersecting;
      if (row.visible && !was) row.refreshPicture?.();
    }
  });

  function describe(cameras) {
    const online = cameras.filter((c) => c.isEnabled && c.status?.connection === 'online').length;
    const recording = cameras.filter((c) => c.nvrEnabled).length;
    const home = cameras.filter((c) => c.status?.paired).length;
    const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
    summary.textContent = `${plural(cameras.length, 'camera')} · ${online} online · ${recording} recording · ${home} in Apple Home`;
  }

  function renderAll() {
    const cameras = cameraList();
    onScreen.disconnect();
    for (const old of rows.values()) old.destroy();
    rows.clear();
    describe(cameras);
    if (!cameras.length) {
      summary.textContent = '';
      replace(content, h('div', { class: 'empty' },
        h('img', { src: '/mark.svg?v=3', alt: '' }),
        h('h2', null, 'No cameras yet'),
        h('p', null, 'Add an ONVIF or RTSP camera and it shows up in the Apple Home app, with live view and HomeKit Secure Video recording. It only takes a minute.'),
        h('a', { class: 'btn primary', href: '#/add' }, icon('plus'), 'Add your first camera')));
      return;
    }
    const body = h('tbody', null, cameras.map((camera) => {
      const row = cameraRow(camera);
      rows.set(camera.id, row);
      onScreen.observe(row);
      return row;
    }));
    replace(content, h('div', { class: 'cam-table-wrap' }, h('table', { class: 'cam-table' },
      h('thead', null, h('tr', null, ['Camera', 'Status', 'Video', 'Recording', 'Events', 'Apple Home', ''].map((t) => h('th', { scope: 'col' }, t)))),
      body)));
  }

  const stop = subscribe((kind, detail) => {
    if (kind === 'camera' && detail && rows.has(detail.id)) { rows.get(detail.id).update(detail); describe(cameraList()); }
    else if (kind === 'camera' || kind === 'removed') renderAll();
    else if (kind === 'doorbell') toast(`${detail.name}: doorbell ring`);
  });

  function tick() {
    if (document.hidden) return;
    for (const row of rows.values()) row.refreshPicture();
  }
  timer = setInterval(tick, THUMB_INTERVAL);
  renderAll();

  return {
    el: h('div', null,
      h('div', { class: 'page-head' }, h('h1', null, 'Cameras'),
        h('div', { class: 'actions' }, h('a', { class: 'btn primary', href: '#/add' }, icon('plus'), 'Add a camera'))),
      summary, bannerHost, content),
    destroy() {
      clearInterval(timer);
      stop();
      onScreen.disconnect();
      for (const row of rows.values()) row.destroy();
      bannerHost.destroy();
    },
  };
}

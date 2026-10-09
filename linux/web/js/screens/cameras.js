// The overview: a card for every camera, with its picture refreshed every few seconds.
import { h, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { cameraList, store, subscribe } from '../store.js';
import { banners } from './banners.js';
import { homeState, kindName, lastEventText, statePill } from './common.js';

const THUMB_INTERVAL = 8000;

function cameraCard(camera) {
  const img = h('img', { alt: '', loading: 'lazy', decoding: 'async' });
  const placeholder = h('div', { class: 'placeholder' });
  const badges = h('div', { class: 'badges' });
  const title = h('a', { href: `#/camera/${camera.id}` }, camera.name);
  const meta = h('div', { class: 'meta' });
  const event = h('div', { class: 'meta' });
  const foot = h('div', { class: 'foot' });
  const card = h('article', { class: 'card camera-card', dataset: { id: camera.id }, 'aria-label': camera.name },
    h('div', { class: 'thumb' }, img, placeholder, badges),
    h('div', { class: 'body' }, h('h3', null, title), meta, event, foot));
  let current = camera;
  let loaded = false;

  function showPicture(url) {
    const next = new Image();
    next.onload = () => { img.src = url; loaded = true; placeholder.hidden = true; img.hidden = false; };
    next.onerror = () => { if (!loaded) { img.hidden = true; placeholder.hidden = false; setTimeout(() => card.isConnected && card.refreshPicture(), 2500); } };
    next.src = url;
  }

  card.refreshPicture = () => {
    const live = current.isEnabled && current.status?.connection === 'online';
    if (!live) { if (!loaded) { img.hidden = true; placeholder.hidden = false; } return; }
    showPicture(`/api/v1/cameras/${current.id}/snapshot?t=${Date.now()}`);
  };

  let lastTry = 0;
  card.update = (next) => {
    current = next;
    // A camera that has just come online has no picture yet: try as soon as it says it is live, at most every 3 s.
    if (!loaded && next.isEnabled && next.status?.connection === 'online' && Date.now() - lastTry > 3000) {
      lastTry = Date.now();
      setTimeout(() => card.refreshPicture(), 400);
    }
    const s = next.status;
    title.textContent = next.name;
    card.setAttribute('aria-label', next.name);
    replace(badges, statePill(next));
    replace(meta, `${kindName(next)} · ${next.vendorName}${next.address ? ` · ${next.address}` : ''}`);
    replace(event, s?.connection === 'offline' && s.connectionReason ? `Offline: ${s.connectionReason}` : lastEventText(next) || (s?.videoSummary ?? ''));
    replace(foot, homeState(next),
      s && !s.paired && next.isEnabled ? h('a', { class: 'btn small', href: `#/camera/${next.id}/pair` }, 'Add to Apple Home') : null);
    if (!loaded) {
      replace(placeholder, icon('camera'), next.isEnabled ? (s?.connection === 'offline' ? 'The camera isn’t answering' : 'Waiting for a picture…') : 'This camera is turned off');
      if (!img.hidden) img.hidden = true;
      placeholder.hidden = false;
    }
  };
  card.update(camera);
  card.refreshPicture();
  return card;
}

export function renderCameras() {
  const bannerHost = banners();
  const grid = h('div', { class: 'camera-grid' });
  const content = h('div');
  const cards = new Map();
  let timer = null;

  function renderAll() {
    const cameras = cameraList();
    cards.clear();
    if (!cameras.length) {
      replace(content, h('div', { class: 'empty' },
        h('img', { src: '/mark.svg', alt: '' }),
        h('h2', null, 'No cameras yet'),
        h('p', null, 'Add an ONVIF or RTSP camera and it shows up in the Apple Home app, with live view and HomeKit Secure Video recording. It only takes a minute.'),
        h('a', { class: 'btn primary', href: '#/add' }, icon('plus'), 'Add your first camera')));
      return;
    }
    replace(grid, cameras.map((camera) => {
      const card = cameraCard(camera);
      cards.set(camera.id, card);
      return card;
    }), h('a', { class: 'add-card', href: '#/add' }, icon('plus'), h('strong', null, 'Add a camera'), h('span', { class: 'small' }, 'Find it on your network or enter its address')));
    replace(content, grid);
  }

  const stop = subscribe((kind, detail) => {
    if (kind === 'camera' && detail && cards.has(detail.id)) cards.get(detail.id).update(detail);
    else if (kind === 'camera' || kind === 'removed') renderAll();
    else if (kind === 'doorbell') toast(`${detail.name}: doorbell ring`);
  });

  function tick() {
    if (document.hidden) return;
    for (const card of cards.values()) card.refreshPicture();
  }
  timer = setInterval(tick, THUMB_INTERVAL);
  const onVisible = () => { if (!document.hidden) tick(); };
  document.addEventListener('visibilitychange', onVisible);
  renderAll();

  return {
    el: h('div', null,
      h('div', { class: 'page-head' }, h('h1', null, 'Cameras'),
        h('div', { class: 'actions' }, h('a', { class: 'btn primary', href: '#/add' }, icon('plus'), 'Add a camera'))),
      bannerHost, content),
    destroy() {
      clearInterval(timer);
      stop();
      bannerHost.destroy();
      document.removeEventListener('visibilitychange', onVisible);
    },
  };
}

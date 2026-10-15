// A camera's picture as the page has always shown it: a snapshot every few seconds, or on request the multipart live preview (about one picture
// a second). Extracted from the camera page (camera.js `previewCard`, lines 112-149) so that the watch screen can put it under the video.
//
//   const preview = createPreview(camera);          // camera.js:  replace(left, preview.el, ...); preview.start();
//   preview.stop();  preview.start();  preview.destroy();
//
// `options.note` and `options.toggle` (both true by default) hide the status pill and the "Start live preview" button. The picture reads the
// camera from the store each time, so a rename or a status change reaches it without rebuilding the card.
import { h, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { store } from '../store.js';

export const SNAPSHOT_INTERVAL_MS = 5000;

export function createPreview(camera, { note: withNote = true, toggle: withToggle = true } = {}) {
  const id = camera.id;
  const current = () => store.cameras.get(id) || camera;
  let live = false;
  let timer = null;
  let lastSnapshot = '';
  let destroyed = false;

  const img = h('img', { alt: `Picture from ${camera.name}`, hidden: true });
  const placeholder = h('div', { class: 'placeholder' }, h('div', null, icon('camera', { size: 34 }), h('div', null, 'Waiting for a picture…')));
  const toggle = h('button', { class: 'btn small', type: 'button' });
  const note = h('span', { class: 'pill plain' });

  const showSnapshot = () => {
    if (destroyed || live || document.hidden) return;
    const c = current();
    const s = c.status;
    if (!c.isEnabled || s?.connection !== 'online') {
      img.hidden = true;
      placeholder.hidden = false;
      replace(placeholder, h('div', null, icon('camera', { size: 34 }),
        h('div', null, c.isEnabled ? (s?.connection === 'offline' ? 'The camera isn’t answering' : 'Waiting for a picture…') : 'This camera is turned off')));
      return;
    }
    const next = new Image();
    next.onload = () => {
      if (destroyed || live) return;
      lastSnapshot = next.src;
      img.src = next.src;
      img.alt = `Picture from ${current().name}`;
      img.hidden = false;
      placeholder.hidden = true;
    };
    next.src = `/api/v1/cameras/${id}/snapshot?t=${Date.now()}`;
  };

  const setLive = (on, { snapshot = true } = {}) => {
    live = on;
    if (on) {
      img.hidden = false;
      placeholder.hidden = true;
      img.src = `/api/v1/cameras/${id}/live?t=${Date.now()}`;
      replace(toggle, icon('pause'), 'Stop live preview');
      replace(note, 'Live preview · about one picture a second');
    } else {
      // Closing the multipart stream: show the last snapshot meanwhile (the camera page used to leave the picture empty until the next one).
      if (lastSnapshot) img.src = lastSnapshot; else img.removeAttribute('src');
      replace(toggle, icon('play'), 'Start live preview');
      replace(note, 'Picture refreshes every few seconds');
      if (snapshot) showSnapshot();
    }
  };

  img.addEventListener('error', () => {
    if (live) { toast('The live preview stopped. The camera may be offline.'); setLive(false); }
  });
  toggle.addEventListener('click', () => setLive(!live));
  setLive(false, { snapshot: false });

  const overlay = withNote || withToggle ? h('div', { class: 'overlay' }, withNote ? note : null, withToggle ? toggle : null) : null;
  const el = h('div', null, h('div', { class: 'preview' }, img, placeholder, overlay));

  function stop() {
    clearInterval(timer);
    timer = null;
    if (live) setLive(false, { snapshot: false });
  }

  return {
    el,
    /** Shows a snapshot now and every 5 s. Calling it again restarts the timer. */
    start() {
      if (destroyed) return;
      clearInterval(timer);
      showSnapshot();
      timer = setInterval(showSnapshot, SNAPSHOT_INTERVAL_MS);
    },
    /** Stops refreshing and closes a live preview; the last picture stays on screen. */
    stop,
    destroy() {
      destroyed = true;
      clearInterval(timer);
      timer = null;
      img.removeAttribute('src');          // also closes a live preview
    },
  };
}

// The smoke page: mounts the real watch screen with a made-up camera, the fake player and a stand-in for app.js (navigate, sign-out).
import { onAuthChange } from '/js/api.js';
import { store } from '/js/store.js';
import { renderWatch } from '/js/screens/watch.js';

const id = '11111111-2222-4333-8444-555555555555';
store.cameras.set(id, {
  id, name: 'Front door', isEnabled: true, nvrEnabled: true, vendorName: 'Demo',
  status: { connection: 'online', summary: 'Live', nvr: { state: 'recording', detail: null, pause: null, notes: [] } },
});
store.bridge = { state: 'running', stateText: 'Running' };
try { localStorage.setItem('cb.nvr.debug', '1'); } catch { /* the hook is then missing and the checks say so */ }

window.__mount = (params) => {
  window.__screen?.destroy?.();
  window.__screen = renderWatch({ params, navigate: (path) => { window.__navigated = path; }, setTitle: () => {} });
  document.getElementById('main').replaceChildren(window.__screen.el);
};
// What app.js does when a request finds the session gone: drop the screen and show the sign-in.
onAuthChange((kind) => {
  if (kind !== 'unauthorized') return;
  window.__screen?.destroy?.();
  window.__screen = null;
  document.getElementById('main').replaceChildren(Object.assign(document.createElement('input'), { type: 'password', id: 'signin-probe' }));
});
const fromAddress = location.hash.match(/watch\/(\d+)/);
window.__mount(fromAddress ? [id, fromAddress[1]] : [id]);

// Scripted states for screenshots: /?do=preset:6h,scrub:6600000,pause,gop,optimize,apply
const steps = (new URLSearchParams(location.search).get('do') || '').split(',').filter(Boolean);
setTimeout(async () => {
  for (const step of steps) {
    const [name, argument] = step.split(':');
    const { session } = window.__cbWatch;
    if (name === 'preset') document.querySelector(`.nvr-preset[data-preset="${argument}"]`).click();
    if (name === 'scrub') { session.beginScrub(); session.scrub(Date.now() - Number(argument)); session.endScrub(); }
    if (name === 'pause') session.pause();
    if (name === 'gop') (await import('/js/nvr/catalog.js')).SMOKE.typicalGOP = 12;
    if (name === 'optimize') document.querySelector('.watch-gop .btn').click();
    if (name === 'apply') [...document.querySelectorAll('dialog .btn')].find((b) => b.textContent === 'Apply changes').click();
    await new Promise((resolve) => setTimeout(resolve, 700));
  }
}, 600);

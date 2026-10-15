// Smoke stand-in for T09's js/nvr/lite.js: a Record switch that does nothing.
import { h } from '../dom.js';
export const hasNVR = (camera) => camera.nvrEnabled === true;
export function loadNVR() {
  return Promise.resolve({
    recordSwitch: (camera) => ({
      el: h('label', { class: 'switch-row' }, h('span', { class: 'text' }, 'Record'),
        h('span', { class: 'switch' }, h('input', { type: 'checkbox', role: 'switch', checked: camera.nvrEnabled }))),
      destroy() {},
    }),
  });
}

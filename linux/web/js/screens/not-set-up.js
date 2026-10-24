// The Add Camera check's answer for a camera that has no admin password yet (the server words it: `notSetUp` of the /probe answer), and the
// note under a camera that was found through its maker's own interface.
import { h } from '../dom.js';
import { icon } from '../icons.js';

// `info`: { maker, title, step, webPage, openLabel, checkAgainLabel }. The camera's page opens in a new tab; Check again asks again.
export function notSetUpCard(info, { onCheckAgain }) {
  return h('div', { class: 'card not-set-up' },
    h('h2', null, info.title),
    h('p', null, info.step),
    h('div', { class: 'row' },
      h('a', { class: 'btn primary', href: info.webPage, target: '_blank', rel: 'noopener' }, info.openLabel),
      h('button', { class: 'btn', type: 'button', onclick: onCheckAgain }, info.checkAgainLabel)));
}

export function ownInterfaceBanner(note) {
  return note ? h('div', { class: 'banner info' }, icon('info'), h('div', { class: 'text' }, note)) : null;
}

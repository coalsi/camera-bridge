// The Setup panel at the top of the Sky Watcher page (#/sky): the box's own Sky Watcher settings, which used to be a section of Settings: where
// the box is, the flight feed with "Find a feed", and the AI's daily limit. It reads the bridge's settings once and builds the card from them
// (sky-card.js createSkySettingsCard: a `<details>`, open until the box has a place); a bridge that does not answer gets a sentence and a way to
// try again. Nothing here is the card's business: the card saves with `PATCH settings { sky }` and keeps what is being typed.
import { get } from '../api.js';
import { h, replace } from '../dom.js';
import { inlineError } from './common.js';
import { createSkySettingsCard } from './sky-card.js';
import { SKY_TEXT, refusalOf } from './sky-model.js';

/**
 * -> { el, destroy() }
 *   settings()   GET settings (a promise of the settings, which carry `sky`)
 *   ...card      the card's own options (save, find, geolocate, onSettings, open), for a test
 */
export function createSkySetupPanel({ settings = () => get('settings'), ...card } = {}) {
  const T = SKY_TEXT.settings;
  const el = h('div', { class: 'sky-setup-host' });
  let made = null;
  let destroyed = false;

  function load() {
    replace(el, h('p', { class: 'small muted', role: 'status' }, T.loading));
    Promise.resolve().then(settings).then((answer) => {
      if (destroyed) return;
      made = createSkySettingsCard(answer, card);
      replace(el, made.el);
    }, (error) => {
      if (destroyed) return;
      replace(el, h('div', { class: 'card sky-settings-card' }, h('h2', null, T.title), inlineError(refusalOf(error).text),
        h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', onclick: () => load() }, T.retry))));
    });
  }

  load();
  return {
    el,
    destroy() {
      destroyed = true;
      made?.destroy();
    },
  };
}

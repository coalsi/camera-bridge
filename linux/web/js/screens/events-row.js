// The pieces of one event as the Events page and the Monitor's events list draw them: what the AI saw (a chip), how much it matters (a red or
// amber dot on its sentence), "Describing…" while the words are on their way, and the Events page's row. The AI's words go in as text only
// (never markup) and are isolated for bidirectional text by the stylesheet.
import { h } from '../dom.js';
import { stampText } from '../stamp.js';
import { concernWord, durationText } from './wall-events-model.js';

const KIND_WORDS = { person: 'Person', vehicle: 'Vehicle', animal: 'Animal', delivery: 'Delivery', other: 'Other', nothing: 'Nothing' };

/** The word for what the AI saw. */
export const kindWord = (kind) => KIND_WORDS[kind] ?? 'Other';

/** The chip for what the AI saw, or null when it has not described the event. */
export function aiChip(description) {
  return description ? h('span', { class: 'ev-chip', dataset: { kind: description.kind } }, kindWord(description.kind)) : null;
}

/**
 * The AI's sentence, or “Describing…” while the words are on their way, or null. The sentence carries `data-concern` (alarm, unusual, routine,
 * nothing) and the stylesheet draws the dot from it: red for alarm, amber for unusual, none for routine; "Nothing notable" is dimmed.
 */
export function aiSays(description, { describing = false } = {}) {
  if (description) return h('span', { class: 'mon-event-ai ev-ai', title: concernWord(description.concern), dataset: { concern: description.concern } }, description.text);
  return describing ? h('span', { class: 'ev-describing', role: 'status' }, 'Describing…') : null;
}

/** What a screen reader hears for an event: the type, camera, time, duration, then the AI's concern and words. */
export function eventLabel(event, { recorded = true } = {}) {
  const duration = durationText(event.endAt !== null ? event.endAt - event.at : null);
  const word = event.description ? concernWord(event.description.concern) : null;
  const said = event.description ? `, ${kindWord(event.description.kind).toLowerCase()}, ${word ? `${word.toLowerCase()}: ` : ''}${event.description.text}` : '';
  return `${event.label}, ${event.cameraName}, ${stampText(event.at)}${duration ? `, ${duration}` : ''}${recorded ? '' : ', not recorded'}${said}`;
}

/**
 * One row of the Events page: `{ thumb }` is the snapshot tile (nvr/thumbs.js), `href` the Monitor's address or null when nothing was recorded,
 * `describing` whether words are on their way. A row with an address is a link, so Enter, a middle click and "open in a new tab" all work.
 */
export function eventRow(event, { thumb, href, describing = false }) {
  const duration = durationText(event.endAt !== null ? event.endAt - event.at : null);
  const attrs = {
    class: 'ev-row', 'aria-label': eventLabel(event, { recorded: href !== null }),
    title: href !== null ? 'Open the Monitor at this moment and play from just before it' : 'Nothing was recorded at this moment',
  };
  const body = [
    thumb,
    h('div', { class: 'ev-body' },
      h('div', { class: 'ev-head' },
        h('strong', { class: 'ev-camera' }, event.cameraName),
        h('time', { datetime: new Date(event.at).toISOString() }, stampText(event.at)),
        duration ? h('span', { class: 'ev-duration' }, duration) : null),
      h('div', { class: 'ev-meta' },
        h('span', { class: 'ev-type', dataset: { level: event.level } }, event.label),
        href === null ? h('span', { class: 'ev-note' }, 'Not recorded') : null,
        aiChip(event.description))),
  ];
  const says = aiSays(event.description, { describing });
  if (says) body[1].append(h('p', { class: 'ev-says' }, says));
  const row = href !== null ? h('a', { ...attrs, href: `#${href}` }, body) : h('div', attrs, body);
  return h('li', { class: 'ev-item', dataset: { concern: event.description?.concern ?? '', recorded: String(href !== null) } }, row);
}

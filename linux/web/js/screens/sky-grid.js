// Sky Watcher's grid (sky-log.js, #/sky): a night's entries as cards, under the hours they began in (or, in an order that is not by time, one
// grid with no hours), made as they come near the screen. A night can hold 2,600 entries: the cards are made sixty at a time (a whole number of
// rows at one to six columns, the most the page shows), the first sixty at once and each other sixty when the person scrolls near it; until
// then a block of its height holds its place, so the page is as long as the night from the start and the strip can jump to any hour at once.
// Sixty that the person has scrolled far from are given back the same way (their cards and pictures let go, the block put back): however far
// a phone is scrolled, it holds a few hundred cards at most.
//
// A card is the still's close-up of the light with its path drawn over it (sky-model.js closeUpRect; the whole picture for a light that
// crossed more of the sky than a close-up holds), or a quiet picture of its kind when no still was kept; its kind as a chip in the strip's
// colour, how long it lasted, its time, and a short line: a plane's flight, a satellite's name, an unexplained light's first reason (which of
// its group it was, for one that moved with others; logged before the guide, its direction and how it moved). An unexplained light's card has
// its priority as a badge: High in the unexplained colour, glowing as the strip's dots do; Medium; Low quiet. A tap opens it (the page: the clip
// player, with the light's details and the corrections).
//
// A correction changes a card's kind at once. A card the filters no longer show then leaves the grid: it fades, the cards after it close up,
// its hour counts one light less (and goes with its last one), and the page keeps its place: what is at the top of the screen stays there.
// The picture on a card is the box's small one (`GET …/still?size=thumb`, at most 480 wide: a night of hundreds of lights does not download hundreds
// of pictures of 1920): the close-up already cut around the light, or all of the picture, small. Which it is, and so where the path goes over it, is
// told from its size (sky-model.js thumbGeometry); when the small picture fails, or is none the page can place, the whole picture is asked for and
// drawn the way it always was, and when that fails the card shows the kind's sign.
import { h, replace, svg } from '../dom.js';
import { plural } from '../format.js';
import { icon } from '../icons.js';
import {
  SKY_TEXT, cardLine, closeUpRect, durationShort, durationText, entryBucket, hourGroups, kindWord, lastedSeconds, pathPoints, priorityOf, priorityWord, thumbGeometry,
  timeText,
} from './sky-model.js';

const TEXT = SKY_TEXT.log;
/** Cards made at a time: sixty fill whole rows at 1, 2, 3, 4, 5 or 6 columns, so a batch never leaves half a row before one not made yet. */
export const BATCH = 60;
/** How far ahead of the screen (above and below) a batch is made, and how far away it is given back. */
const AHEAD = '1600px 0px';
const FAR = '5000px 0px';
const HOUR = 3_600_000;
/** How long a leaving card fades (sky.css .sky-tile[data-leaving]); none for a person who asks for less motion. */
export const FADE_MS = 200;

/** The kind's picture on a card without a still. */
const KIND_ICONS = { unexplained: 'spark', planes: 'plane', satellites: 'satellite', meteors: 'meteor', bugsAndBirds: 'bird', notSure: 'question' };
const iconOf = (entry) => (entry.display === 'bug' && entryBucket(entry) === 'bugsAndBirds' ? 'bug' : KIND_ICONS[entryBucket(entry)] ?? 'spark');
const round = (value) => Math.round(value * 100) / 100;

function defaultObserver(callback, options) {
  return typeof IntersectionObserver === 'function' ? new IntersectionObserver(callback, options) : null;
}

function defaultFrame(fn) {
  return typeof requestAnimationFrame === 'function' ? requestAnimationFrame(fn) : setTimeout(fn, 16);
}

const lessMotion = () => globalThis.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches === true;

/** The index of the first of `items` (in order) for which `test` holds, `test` being false and then true along them; items.length for none. */
function firstWhere(items, test) {
  let lo = 0;
  let hi = items.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (test(items[mid])) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

/**
 * The grid, empty until shown.
 * -> { el, show(view, { keepPlace }), setGroups(groups), refresh(entry), leave(id), has(id), focusFor(id), reveal(id), jumpTo(ms), span(top, bottom), remeasure(), destroy() }
 *   thumbAddress(entry)        the address of an entry's small picture (the box cuts it around the light)
 *   stillAddress(entry)        the address of its whole picture (asked for when the small one cannot be had)
 *   picture()                  how big the night's pictures are, { width, height }, or null when the bridge did not say
 *   onOpen(entry, card)        a card was tapped
 *   onChange()                 a card left the grid (the page's band follows what is on the screen)
 *   createObserver(fn, opts)   an IntersectionObserver-like { observe, unobserve, disconnect } (tests drive one by hand); null: every card at once
 *   frame(fn)                  the next frame (requestAnimationFrame): the cards' size is measured once they are on the page
 *   wait(fn, ms)               a timer (setTimeout): a leaving card's fade
 *   viewTop()                  where the screen's view of the grid begins (the foot of the page's dock), in the window's coordinates
 *   scrollBy(dy)               scrolls the page (the window) by dy CSS pixels: the page keeps its place when the grid changes above it
 */
export function createSkyGrid({ thumbAddress, stillAddress, picture = () => null, onOpen = () => {}, onChange = () => {},
  createObserver = defaultObserver, frame = defaultFrame, wait = (fn, ms) => setTimeout(fn, ms), viewTop = () => 0,
  scrollBy = (dy) => globalThis.window?.scrollBy?.(0, dy) } = {}) {
  const el = h('div', { class: 'sky-results' });
  let zone = '';
  let moving = new Map();            // the lights that moved together (sky-model.js groupsOf): a card says which of its group it is
  let sections = [];                 // [{ hour, el, head, count, size, tiles, batches }]: one with hour null when the order is not by time
  let batches = [];                  // every batch, in the order shown: { entries, holder, built, section }
  const batchOf = new Map();         // a batch's holder (the block in its place) -> the batch
  const cards = new Map();           // entry id -> { card, refresh() }
  const times = new WeakMap();       // a card or a holder -> [the start of its first entry, of its last]
  const leaving = new Set();         // entry ids whose cards are fading out of the grid
  const instead = new Map();         // entry id -> the card that took the place of its card when it left (the focus goes back there)
  let emptyEl = null;                // what is shown when nothing is left
  let shownAt = 0;                   // which show() this is: a fade begun before the next one ends with it
  let metrics = null;                // { cols, row, gap }: what a batch's holder is measured by
  let measuring = false;
  let tries = 0;                     // frames the measuring waited for the grid to be on the page
  let destroyed = false;
  let sequence = 0;
  const observer = createObserver ? createObserver((seen) => {
    for (const item of seen) if (item.isIntersecting) build(batchOf.get(item.target));
  }, { rootMargin: AHEAD }) : null;
  // A made batch's first and last cards: while neither is within FAR of the screen, the batch is given back.
  const ends = new Map();            // a made batch's first or last card -> the batch
  const away = createObserver ? createObserver((seen) => {
    for (const item of seen) {
      const batch = ends.get(item.target);
      if (!batch?.built) continue;
      if (item.isIntersecting) batch.near.add(item.target);
      else batch.near.delete(item.target);
      if (!batch.near.size) unbuild(batch);
    }
  }, { rootMargin: FAR }) : null;

  // MARK: A card

  /**
   * The picture on a card: the small one (the close-up the box cut around the light, drawn as it is; or all of the picture, small, magnified to the
   * close-up), the whole one when the small one fails or cannot be placed, the kind's sign when that fails too. The path is drawn over it, in the
   * still's own pixels.
   */
  function still(entry, frameEl) {
    let source = 'thumb';   // which picture is being asked for: 'thumb', then 'full'
    const img = h('img', { class: 'sky-tile-img', src: thumbAddress(entry), alt: '', loading: 'lazy', decoding: 'async', draggable: 'false' });
    const overlay = svg('svg', { class: 'sky-path', 'aria-hidden': 'true', focusable: 'false', preserveAspectRatio: 'xMidYMid meet' });
    /** The path over the picture: `box` is the part of the still the frame shows, `size` the still's size its coordinates are in. */
    function drawPath(box, size, radius) {
      overlay.setAttribute('viewBox', `${box.x} ${box.y} ${box.width} ${box.height}`);
      while (overlay.firstChild) overlay.removeChild(overlay.firstChild);
      const points = pathPoints(entry.path, size.width, size.height);
      const list = points ? points.split(' ').map((pair) => pair.split(',')) : [];
      if (list.length >= 2) overlay.append(svg('polyline', { class: 'sky-path-line', points, fill: 'none' }));
      if (list.length >= 1) overlay.append(svg('circle', { class: list.length >= 2 ? 'sky-mark sky-mark--start' : 'sky-mark sky-mark--point', cx: list[0][0], cy: list[0][1], r: radius }));
      if (list.length >= 2) overlay.append(svg('circle', { class: 'sky-mark sky-mark--end', cx: list.at(-1)[0], cy: list.at(-1)[1], r: radius }));
    }
    /** The small picture is no use: the whole one is asked for in its place. */
    function wholeInstead() {
      source = 'full';
      frameEl.dataset.view = 'loading';
      while (overlay.firstChild) overlay.removeChild(overlay.firstChild);
      img.setAttribute('src', stillAddress(entry));
    }
    function draw() {
      const natural = { width: img.naturalWidth, height: img.naturalHeight };
      if (!(natural.width > 0 && natural.height > 0)) return;
      const geometry = source === 'thumb' ? thumbGeometry(entry.path, natural, picture()) : { mode: 'whole', picture: natural };
      if (!geometry) {
        wholeInstead();
        return;
      }
      const { width, height } = geometry.picture;
      if (geometry.mode === 'crop') {
        // The close-up itself: it fills the card's 16:9 frame as it is, and the path is drawn in the rectangle of the still it was cut from.
        frameEl.dataset.view = 'thumb';
        overlay.setAttribute('preserveAspectRatio', 'none');
        drawPath(geometry.rect, geometry.picture, round(Math.max(geometry.rect.width, geometry.rect.height) * 0.03));
        return;
      }
      overlay.setAttribute('preserveAspectRatio', 'xMidYMid meet');
      const crop = closeUpRect(entry.path, width, height);
      const box = crop ?? { x: 0, y: 0, width, height };
      frameEl.dataset.view = crop ? 'closeup' : 'whole';
      if (crop) {
        // The picture placed so that the crop fills the card's 16:9 frame (sky.css): its width and its corner, in per cent of the frame.
        frameEl.style.setProperty('--sky-crop-w', String(round((width / crop.width) * 100)));
        frameEl.style.setProperty('--sky-crop-x', String(round((crop.x / crop.width) * 100)));
        frameEl.style.setProperty('--sky-crop-y', String(round((crop.y / crop.height) * 100)));
      }
      drawPath(box, geometry.picture, round(Math.max(box.width, box.height) * (crop ? 0.03 : 0.014)));
    }
    img.addEventListener('load', draw);
    // A picture the box no longer has: the whole one, then the card shows its kind instead.
    img.addEventListener('error', () => {
      if (source === 'thumb') {
        wholeInstead();
        return;
      }
      frameEl.dataset.view = 'none';
      img.remove();
      overlay.remove();
      frameEl.insertBefore(h('span', { class: 'sky-tile-none' }, icon(iconOf(entry))), frameEl.firstChild);
    });
    if (img.complete && img.naturalWidth > 0) draw();
    return [img, overlay];
  }

  /** The card of an entry: a button that opens it. Its kind, chip and words follow a correction (refresh). */
  function makeCard(entry) {
    const pic = h('span', { class: 'sky-tile-pic', dataset: { view: entry.hasStill ? 'loading' : 'none' } });
    pic.append(...(entry.hasStill ? still(entry, pic) : [h('span', { class: 'sky-tile-none' }, icon(iconOf(entry)))]));
    const word = h('span', { class: 'sky-tile-word' });
    const chip = h('span', { class: 'sky-tile-kind' }, h('span', { class: 'sky-tile-dot', 'aria-hidden': 'true' }), word);
    const yours = h('span', { class: 'sky-tile-yours', title: TEXT.yours, hidden: true }, icon('check'));
    const badge = h('span', { class: 'sky-tile-priority', 'aria-hidden': 'true', hidden: true });
    const seconds = lastedSeconds(entry);
    pic.append(chip, yours, badge, h('span', { class: 'sky-tile-length', 'aria-hidden': 'true' }, durationShort(seconds)));
    const line = h('span', { class: 'sky-tile-line' });
    const when = timeText(entry.start, zone, { seconds: true });
    const card = h('button', { class: 'sky-tile', type: 'button', dataset: { entry: entry.id }, onclick: () => onOpen(entry, card) },
      pic,
      h('span', { class: 'sky-tile-meta' }, h('time', { class: 'sky-tile-when', datetime: new Date(entry.start).toISOString() }, when), line));
    times.set(card, [entry.start, entry.start]);
    function refresh() {
      const kind = entryBucket(entry);
      const what = kindWord(entry);
      const text = cardLine(entry, moving);
      const priority = priorityOf(entry);
      card.dataset.kind = kind;
      chip.dataset.kind = kind;
      word.textContent = what;
      line.textContent = text;
      yours.hidden = !entry.correction;
      badge.hidden = !priority;
      badge.dataset.priority = priority ?? '';
      badge.textContent = priorityWord(priority);
      card.setAttribute('aria-label', [when, what, priority ? `${priorityWord(priority)} priority` : '', durationText(seconds), text, entry.correction ? TEXT.yours : '']
        .filter(Boolean).join(', '));
    }
    refresh();
    return { card, refresh };
  }

  // MARK: Batches

  /** Makes a batch's cards in its holder's place. */
  function build(batch) {
    if (!batch || batch.built || destroyed) return;
    batch.built = true;
    observer?.unobserve(batch.holder);
    batchOf.delete(batch.holder);
    const parent = batch.holder.parentNode;
    for (const entry of batch.entries) {
      const made = makeCard(entry);
      cards.set(entry.id, made);
      parent?.insertBefore(made.card, batch.holder);
    }
    batch.holder.remove();
    batch.near = new Set();
    watchEnds(batch);
  }

  /** A made batch's first and last cards are watched: while neither is within FAR of the screen, the batch is given back. */
  function watchEnds(batch) {
    if (!away || !batch.entries.length) return;
    const wanted = new Set([batch.entries[0], batch.entries.at(-1)].map((entry) => cards.get(entry.id)?.card).filter(Boolean));
    for (const [card, owner] of [...ends]) {
      if (owner !== batch || wanted.has(card)) continue;
      ends.delete(card);
      away.unobserve(card);
      batch.near?.delete(card);
    }
    for (const card of wanted) {
      if (ends.has(card)) continue;
      ends.set(card, batch);
      away.observe(card);
    }
  }

  /**
   * Gives a batch's cards back (the person scrolled far from them): its holder, as tall as they were, takes their place again, to be made again
   * when the person comes back. Not before the cards were measured (the holder must be as tall as they are), nor with the focus in it.
   */
  function unbuild(batch) {
    if (!batch.built || destroyed || !metrics) return;
    const made = batch.entries.map((entry) => cards.get(entry.id)).filter(Boolean);
    const focused = globalThis.document?.activeElement;
    if (!made.length || (focused && made.some(({ card }) => card === focused || card.contains(focused)))) return;
    const parent = made[0].card.parentNode;
    if (!parent) return;
    hold(batch);
    parent.insertBefore(batch.holder, made[0].card);
    for (const { card } of made) {
      if (ends.delete(card)) away?.unobserve(card);
      card.remove();
    }
    for (const entry of batch.entries) cards.delete(entry.id);
    batch.built = false;
    batch.near = null;
    batchOf.set(batch.holder, batch);
    observer?.observe(batch.holder);
  }

  /** A holder is as tall as its batch's rows will be, once a card has been measured (before that, sky.css gives it a height). */
  function hold(batch) {
    if (!metrics) return;
    const rows = Math.ceil(batch.entries.length / metrics.cols);
    batch.holder.style.height = `${Math.max(0, rows * metrics.row - metrics.gap)}px`;
  }

  /** The columns and a row's height, from a card on the page; then every holder's height. */
  function measure() {
    measuring = false;
    if (destroyed || !batches.length) return;
    const first = batches.find((batch) => batch.built);
    const card = first ? cards.get(first.entries[0].id)?.card : null;
    if (!card || typeof getComputedStyle !== 'function') return;
    const box = card.isConnected ? card.getBoundingClientRect() : null;
    const tiles = card.parentNode;
    if (!(box?.width > 0) || !tiles) {
      if (++tries < 30) queueMeasure();   // not on the page yet (the route puts it there), or not laid out
      return;
    }
    tries = 0;
    const style = getComputedStyle(tiles);
    const columnGap = Number.parseFloat(style.columnGap) || 0;
    const gap = Number.parseFloat(style.rowGap) || 0;
    const cols = Math.max(1, Math.round((tiles.getBoundingClientRect().width + columnGap) / (box.width + columnGap)));
    metrics = { cols, row: box.height + gap, gap };
    for (const batch of batches) if (!batch.built) hold(batch);
  }

  function queueMeasure() {
    if (measuring || destroyed) return;
    measuring = true;
    frame(measure);
  }

  function reset() {
    observer?.disconnect();
    away?.disconnect();
    ends.clear();
    batchOf.clear();
    cards.clear();
    leaving.clear();
    instead.clear();
    sections = [];
    batches = [];
    tries = 0;
    shownAt += 1;
  }

  // MARK: Showing a night

  /**
   * Shows `entries` (filtered and in their order):
   *   zone      the box's time zone (the cards' times and the hours)
   *   byHour    under the hours they began in (an order by time), else one grid
   *   capped    hour -> its note (sky-model.js cappedByHour), at the hour's heading; notes: the same notes over the grid when there are no hours
   *   together  the night's lights that moved together (sky-model.js groupsOf), for the cards' lines
   *   empty     what is shown when there is no entry (or none is left)
   * With `keepPlace`, what was at the top of the screen stays there (a card back in the grid after a correction, above or below it).
   */
  function show({ entries = [], zone: inZone = '', byHour = true, capped = new Map(), notes = [], together = new Map(), empty = null } = {},
    { keepPlace = false } = {}) {
    const anchor = keepPlace ? anchorAt(viewTop()) : null;
    reset();
    zone = inZone;
    moving = together;
    emptyEl = empty;
    if (!entries.length) {
      replace(el, empty);
      return;
    }
    const groups = byHour ? hourGroups(entries, zone) : [{ hour: null, label: '', entries }];
    for (const group of groups) {
      const tiles = h('div', { class: 'sky-tiles' });
      const section = { hour: group.hour, tiles, batches: [], el: null, head: null, count: null, size: group.entries.length };
      if (group.hour === null) {
        section.el = h('section', { class: 'sky-hour sky-hour--all' },
          notes.length ? h('div', { class: 'sky-capped' }, notes.map((line) => h('p', { class: 'small sky-capped-hour' }, line))) : null, tiles);
      } else {
        const id = `sky-hour-${++sequence}`;
        const note = capped.get(group.hour);
        section.count = h('span', { class: 'sky-hour-count' }, plural(group.entries.length, 'light'));
        section.head = h('h3', { class: 'sky-hour-head', id }, h('span', { class: 'sky-hour-name' }, group.label), section.count,
          note ? h('span', { class: 'sky-hour-note' }, note) : null);
        section.el = h('section', { class: 'sky-hour', dataset: { hour: String(group.hour) }, 'aria-labelledby': id }, section.head, tiles);
      }
      for (let at = 0; at < group.entries.length; at += BATCH) {
        const part = group.entries.slice(at, at + BATCH);
        const batch = { entries: part, section, built: false, holder: h('div', { class: 'sky-pending', 'aria-hidden': 'true' }) };
        times.set(batch.holder, [part[0].start, part.at(-1).start]);
        batchOf.set(batch.holder, batch);
        tiles.append(batch.holder);
        section.batches.push(batch);
        batches.push(batch);
      }
      sections.push(section);
    }
    replace(el, sections.map((section) => section.el));
    // The first cards at once, sixty at most (they are what the screen shows first); the others as the person scrolls near them.
    let made = 0;
    for (const batch of batches) {
      if (made > 0 && made + batch.entries.length > BATCH) break;
      build(batch);
      made += batch.entries.length;
    }
    for (const batch of batches) {
      if (batch.built) continue;
      if (observer) observer.observe(batch.holder);
      else build(batch);
    }
    for (const batch of batches) if (!batch.built) hold(batch);
    // A card's size does not change with what is shown: it is measured once (and again when the window changes size), at once when the grid
    // is on the page, else in a frame or two, once it is.
    if (!metrics) {
      if (el.isConnected) measure();
      else queueMeasure();
    }
    if (anchor) keepAt(anchor);
  }

  // MARK: Leaving the grid, and keeping the page's place

  /**
   * What keeps its place on the screen when the grid changes: the first hour heading, card or block whose top is on the screen (below `top`,
   * the dock's foot), else the one the screen's top falls in; never `skip` or a card that is leaving. -> { el, top, id, hour } or null
   */
  function anchorAt(top, skip = null) {
    let partly = null;
    for (const section of sections) {
      const box = section.el.getBoundingClientRect();
      if (!(box.height > 0) || box.bottom <= top) continue;
      const items = [section.head, ...section.tiles.children].filter(Boolean);
      for (let at = firstWhere(items, (item) => item.getBoundingClientRect().bottom > top); at < items.length; at += 1) {
        const item = items[at];
        if (item === skip || leaving.has(item.dataset?.entry)) continue;
        const itemTop = item.getBoundingClientRect().top;
        const found = { el: item, top: itemTop, id: item.dataset?.entry ?? batchOf.get(item)?.entries[0]?.id ?? null, hour: item === section.head ? section.hour : null };
        if (itemTop >= top) return found;
        partly ??= found;
      }
    }
    return partly;
  }

  /** Scrolls the page by as much as the anchor moved (`anchor.el`, or after a new show() the same light or hour), so it is where it was. */
  function keepAt(anchor) {
    let target = anchor.el;
    if (!el.contains(target)) {
      target = anchor.id ? reveal(anchor.id) : sections.find((section) => section.hour !== null && section.hour === anchor.hour)?.head ?? null;
    }
    if (!target || !el.contains(target)) return;
    const moved = target.getBoundingClientRect().top - anchor.top;
    if (Math.abs(moved) >= 0.5) scrollBy(moved);
  }

  /** The batch an entry is in. */
  const batchWith = (id) => batches.find((batch) => batch.entries.some((entry) => entry.id === id)) ?? null;

  /** The card that takes a card's place in the grid: the next one, else the one before it (null when it is the last). */
  function neighborOf(card) {
    const list = sections.flatMap((section) => [...section.tiles.children])
      .filter((node) => node === card || (node.classList?.contains('sky-tile') && !leaving.has(node.dataset?.entry)));
    const at = list.indexOf(card);
    return at < 0 ? null : list[at + 1] ?? list[at - 1] ?? null;
  }

  /**
   * An entry the filters no longer show (a correction made it another kind) leaves the grid: its card fades out (at once for less motion), then
   * goes. -> whether it was in the grid
   */
  function leave(id) {
    if (destroyed || !batchWith(id)) return false;
    if (leaving.has(id)) return true;
    const made = cards.get(id);
    if (!made || lessMotion()) {
      drop(id);
      return true;
    }
    leaving.add(id);
    made.card.dataset.leaving = 'true';
    made.card.setAttribute('aria-hidden', 'true');
    made.card.tabIndex = -1;
    const mine = shownAt;
    wait(() => { if (mine === shownAt) drop(id); }, FADE_MS);
    return true;
  }

  /**
   * The entry out of the grid: its card off the page and the cards after it closed up, its batch and its hour one light less (the hour goes with
   * its last light; the grid's empty state with the last of all), the focus on the card that took its place, and the page where it was.
   */
  function drop(id) {
    leaving.delete(id);
    const batch = batchWith(id);
    if (destroyed || !batch) return;
    const made = cards.get(id);
    const anchor = anchorAt(viewTop(), made?.card ?? null);
    const next = made ? neighborOf(made.card) : null;
    if (next) instead.set(id, next);
    const focused = Boolean(made) && globalThis.document?.activeElement === made.card;
    batch.entries.splice(batch.entries.findIndex((entry) => entry.id === id), 1);
    if (made) {
      if (ends.delete(made.card)) away?.unobserve(made.card);
      batch.near?.delete(made.card);
      made.card.remove();
      cards.delete(id);
    }
    const section = batch.section;
    if (!batch.entries.length) {
      if (!batch.built) {
        observer?.unobserve(batch.holder);
        batchOf.delete(batch.holder);
        batch.holder.remove();
      }
      batches.splice(batches.indexOf(batch), 1);
      section.batches.splice(section.batches.indexOf(batch), 1);
    } else if (batch.built) {
      watchEnds(batch);
    } else {
      times.set(batch.holder, [batch.entries[0].start, batch.entries.at(-1).start]);
      hold(batch);
    }
    section.size -= 1;
    if (section.count) section.count.textContent = plural(section.size, 'light');
    if (section.size <= 0) {
      section.el.remove();
      sections.splice(sections.indexOf(section), 1);
    }
    if (!sections.length) replace(el, emptyEl);
    if (focused) next?.focus?.({ preventScroll: true });
    if (anchor) keepAt(anchor);
    onChange();
  }

  // MARK: Finding a place

  /** The hour nearest a time (the one it falls in, else the closest), among those shown. */
  function hourNear(ms) {
    let best = null;
    let distance = Infinity;
    for (const section of sections) {
      if (section.hour === null) continue;
      const gap = ms < section.hour ? section.hour - ms : ms >= section.hour + HOUR ? ms - section.hour - HOUR + 1 : 0;
      if (gap < distance) {
        best = section;
        distance = gap;
      }
    }
    return best;
  }

  /** Brings the hour of `ms` (or the nearest one shown) to the top, its first cards made. Returns its hour, or null when there are no hours. */
  function jumpTo(ms, { smooth = false } = {}) {
    const section = hourNear(ms);
    if (!section) return null;
    build(section.batches[0]);
    section.el.scrollIntoView?.({ block: 'start', behavior: smooth ? 'smooth' : 'auto' });
    return section.hour;
  }

  /** The card of an entry, made if it was not yet (null when the entry is not shown). */
  function reveal(id) {
    if (!cards.has(id)) build(batches.find((batch) => !batch.built && batch.entries.some((entry) => entry.id === id)));
    return cards.get(id)?.card ?? null;
  }

  /**
   * The times of what is on the screen between `top` and `bottom` (the window's own coordinates): { from, to, first }, from the earliest entry
   * seen to the latest (a holder counts with its batch's times), and `first` the time of the first one in the grid's order; null when none is.
   */
  function span(top, bottom) {
    let from = Infinity;
    let to = -Infinity;
    let first = null;
    for (const section of sections) {
      const box = section.tiles.getBoundingClientRect();
      if (!(box.height > 0) || box.bottom <= top) continue;
      if (box.top >= bottom) break;
      const items = section.tiles.children;
      const start = firstWhere(items, (item) => item.getBoundingClientRect().bottom > top);
      const end = firstWhere(items, (item) => item.getBoundingClientRect().top >= bottom) - 1;
      if (start > end) continue;
      for (const item of [items[start], items[end]]) {
        const known = item ? times.get(item) : null;
        if (!known) continue;
        first ??= known[0];
        from = Math.min(from, ...known);
        to = Math.max(to, ...known);
      }
    }
    return from <= to ? { from, to, first } : null;
  }

  return {
    el,
    show,
    jumpTo,
    reveal,
    span,
    leave,
    /** Draws an entry's card again after a correction: its kind, chip, priority and words. */
    refresh(entry) { cards.get(entry.id)?.refresh(); },
    /** The lights that moved together, after a correction changed them (the cards are drawn again with `refresh`). */
    setGroups(together) { moving = together; },
    /** Whether an entry is in the grid (its card made, or its block waiting for the person to come near), and not on its way out. */
    has(id) { return !leaving.has(id) && Boolean(batchWith(id)); },
    /** Where the focus goes back to for an entry's card (a player closed on it): the card, or the one that took its place when it left. */
    focusFor(id) {
      const made = cards.get(id);
      if (made && !leaving.has(id)) return made.card;
      if (made) return neighborOf(made.card);
      const next = instead.get(id);
      return next && el.contains(next) ? next : null;
    },
    /** The window changed size: the cards are measured again, and the blocks of those not made yet follow. */
    remeasure() { metrics = null; queueMeasure(); },
    destroy() {
      destroyed = true;
      reset();
    },
  };
}

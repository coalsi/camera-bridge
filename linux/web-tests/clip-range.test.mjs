// The clip's range on the timeline (nvr/clip-range.js) and the clip bar that sets it (nvr/clip.js): the default anchor, the clamping to what
// was recorded, the handles' drags and keys, the lengths, the cap, and the time-lapse choice.
import { after, before, beforeEach, describe, it, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  CLIP_LENGTHS, DEFAULT_LENGTH_MS, MAX_CLIP_MS, MIN_CLIP_MS, defaultRange, edgeKeyDelta, footageOf, lengthLabel, moveEdge, rangeCheck,
} from '../web/js/nvr/clip-range.js';
import { clipUrl, createClip, lapseLength } from '../web/js/nvr/clip.js';
import { installFakeBrowser, makeStorage } from './support/fake-browser.mjs';

const T = 1_800_000_000_000;
const MIN = 60_000;
const footage = { oldestMs: T - 3_600_000, newestMs: T + 600_000 };

describe('the default range', () => {
  it('ends at the playhead and covers the length before it', () => {
    assert.deepEqual(defaultRange({ anchorMs: T, lengthMs: 30_000, footage }), { fromMs: T - 30_000, toMs: T });
    assert.deepEqual(defaultRange({ anchorMs: T }), { fromMs: T - DEFAULT_LENGTH_MS, toMs: T }, '30 s when nothing else is said; any footage');
  });
  it('starts at the playhead when there is not that much footage before it', () => {
    assert.deepEqual(defaultRange({ anchorMs: footage.oldestMs + 5000, lengthMs: 30_000, footage }), { fromMs: footage.oldestMs + 5000, toMs: footage.oldestMs + 35_000 });
  });
  it('stays inside the footage: a playhead past the newest moment (live) ends at the newest', () => {
    assert.deepEqual(defaultRange({ anchorMs: T + 3_600_000, lengthMs: MIN, footage }), { fromMs: footage.newestMs - MIN, toMs: footage.newestMs });
    // Less footage than the length on either side: all of it.
    const short = { oldestMs: T, newestMs: T + 20_000 };
    assert.deepEqual(defaultRange({ anchorMs: T + 10_000, lengthMs: MIN, footage: short }), { fromMs: T, toMs: T + 20_000 });
  });
  it('takes the footage of every camera on offer', () => {
    assert.deepEqual(footageOf([{ oldest: 5, newest: 10 }, null, { oldest: 2, newest: 8 }]), { oldestMs: 2, newestMs: 10 });
    assert.equal(footageOf([null, undefined]), null);
  });
});

describe('the handles', () => {
  const range = { fromMs: T - 30_000, toMs: T };
  it('move either end, inside the footage', () => {
    assert.deepEqual(moveEdge(range, 'from', T - 90_000, footage), { fromMs: T - 90_000, toMs: T });
    assert.deepEqual(moveEdge(range, 'to', T + 45_000, footage), { fromMs: T - 30_000, toMs: T + 45_000 });
    assert.deepEqual(moveEdge(range, 'from', T - 9_000_000, footage), { fromMs: footage.oldestMs, toMs: T });
    assert.deepEqual(moveEdge(range, 'to', T + 9_000_000, footage), { fromMs: T - 30_000, toMs: footage.newestMs });
  });
  it('never cross: an end dragged past the other stops a second before it', () => {
    assert.deepEqual(moveEdge(range, 'from', T + 60_000, footage), { fromMs: T - MIN_CLIP_MS, toMs: T });
    assert.deepEqual(moveEdge(range, 'to', T - 90_000, footage), { fromMs: T - 30_000, toMs: T - 30_000 + MIN_CLIP_MS });
  });
  it('move with the keys: a second, ten with Shift, a minute with Page Up and Page Down', () => {
    assert.equal(edgeKeyDelta({ key: 'ArrowLeft' }), -1000);
    assert.equal(edgeKeyDelta({ key: 'ArrowRight', shiftKey: true }), 10_000);
    assert.equal(edgeKeyDelta({ key: 'PageDown' }), -60_000);
    assert.equal(edgeKeyDelta({ key: 'PageUp', shiftKey: true }), 60_000);
    assert.equal(edgeKeyDelta({ key: 'a' }), null);
  });
});

test('the lengths are 10 s, 30 s, 1 min, 5 min and 15 min, and the cap is two hours', () => {
  assert.deepEqual(CLIP_LENGTHS.map(lengthLabel), ['10 s', '30 s', '1 min', '5 min', '15 min']);
  assert.equal(lengthLabel(95_000), '1 min 35 s');
  assert.equal(lengthLabel(3_900_000), '1 h 5 min');
  assert.equal(MAX_CLIP_MS, 7_200_000);
  assert.deepEqual(rangeCheck({ fromMs: 0, toMs: MAX_CLIP_MS }), { lengthMs: MAX_CLIP_MS, tooShort: false, tooLong: false });
  assert.equal(rangeCheck({ fromMs: 0, toMs: MAX_CLIP_MS + 1 }).tooLong, true);
  assert.equal(rangeCheck({ fromMs: 0, toMs: 500 }).tooShort, true);
});

test('a time-lapse clip asks the bridge for its speed', () => {
  assert.match(clipUrl('c', 0, 3_600_000, 1, 'UTC', false, false, 60), /&part=1&speed=60$/);
  assert.doesNotMatch(clipUrl('c', 0, 3_600_000, 1, 'UTC'), /speed/);
  assert.equal(lapseLength(3_600_000, 60), '1:00');
  assert.equal(lapseLength(3_600_000, 300), '0:12');
});

describe('the clip bar', () => {
  let browser;
  before(() => { browser = installFakeBrowser(); });
  after(() => browser?.restore());
  beforeEach(() => {
    globalThis.localStorage = makeStorage();
    globalThis.fetch = async () => ({ ok: true, status: 200, headers: { get: (name) => (name === 'Content-Type' ? 'application/json' : null) },
      json: async () => ({ parts: [{ index: 1 }], gaps: [], bytes: 1000, soundOmitted: false }) });
  });

  function all(root, match) {
    const out = [];
    const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
    walk(root);
    return out;
  }
  const buttons = (clip) => all(clip.el, (node) => node.localName === 'button');
  const exportButton = (clip) => buttons(clip).find((node) => node.textContent === 'Export clip');
  const text = (clip) => clip.el.textContent;

  function make({ playhead = T, footage: recorded = footage } = {}) {
    const shown = [];
    const urls = [];
    const timeline = { setClipRange: (range, onEdge) => shown.push(range ? { ...range, onEdge } : null) };
    const clip = createClip({ cameras: () => [{ id: 'gate', name: 'Gate' }], endMs: () => playhead, footage: () => recorded, timeline, download: (url) => urls.push(url) });
    return { clip, shown, urls };
  }
  const planned = () => new Promise((resolve) => setTimeout(resolve, 450));

  it('Save clip shows the range on the timeline: the length before the playhead; Cancel takes it away', () => {
    const { clip, shown } = make();
    clip.begin();
    assert.deepEqual(clip.range(), { from: T - 30_000, to: T });
    assert.equal(shown.at(-1).fromMs, T - 30_000);
    assert.equal(typeof shown.at(-1).onEdge, 'function', 'the timeline’s handles move it');
    assert.equal(buttons(clip).find((node) => node.dataset.length === '30000').getAttribute('aria-pressed'), 'true');
    clip.cancel();
    assert.equal(shown.at(-1), null);
    clip.destroy();
  });

  it('a length sets the range again around the same anchor; a drag makes it a length of its own', () => {
    const { clip, shown } = make();
    clip.begin();
    clip.setLength(300_000);
    assert.deepEqual(clip.range(), { from: T - 300_000, to: T });
    shown.at(-1).onEdge('from', T - 400_000);                 // the start handle dragged
    assert.deepEqual(clip.range(), { from: T - 400_000, to: T });
    assert.match(text(clip), /Custom: 6 min 40 s/);
    assert.ok(buttons(clip).filter((node) => node.dataset.length).every((node) => node.getAttribute('aria-pressed') === 'false'));
    clip.moveEdge('to', T + 20_000);
    assert.deepEqual(clip.range(), { from: T - 400_000, to: T + 20_000 });
    clip.setLength(10_000);
    assert.deepEqual(clip.range(), { from: T - 10_000, to: T }, 'back to the anchor');
    clip.destroy();
  });

  it('longer than the cap cannot be saved, and says so', async () => {
    const { clip } = make({ playhead: T + 600_000, footage: { oldestMs: T - 10 * 3_600_000, newestMs: T + 600_000 } });
    clip.begin();
    clip.moveEdge('from', T - 10 * 3_600_000);                // to the oldest footage: 2 h 10 min
    clip.tick();
    await planned();
    assert.match(text(clip), /at most 2 hours/);
    assert.equal(exportButton(clip).disabled, true);
    clip.moveEdge('from', T - 3_000_000);
    clip.tick();
    await planned();
    assert.doesNotMatch(text(clip), /at most 2 hours/);
    assert.ok(!exportButton(clip).disabled, 'it can be saved again');
    clip.destroy();
  });

  it('a time-lapse saves the range sped up, says how long it plays, and refuses a range too short for its speed', async () => {
    const { clip, urls } = make();
    clip.begin();
    clip.setLength(900_000);
    clip.tick();
    await planned();
    const select = all(clip.el, (node) => node.localName === 'select')[0];
    select.value = '60';
    select.dispatchEvent({ type: 'change', target: select });
    assert.match(text(clip), /Time-lapse 60×: 15 min plays in about 0:15, without sound/);
    await clip.exportClip();
    assert.match(urls.at(-1), /&speed=60$/);
    clip.begin();
    clip.setLength(10_000);
    const again = all(clip.el, (node) => node.localName === 'select')[0];
    again.value = '300';
    again.dispatchEvent({ type: 'change', target: again });
    clip.tick();
    await planned();
    assert.match(text(clip), /Too short for a 300× time-lapse: make the range at least 5 min/);
    assert.equal(exportButton(clip).disabled, true);
    clip.destroy();
  });
});

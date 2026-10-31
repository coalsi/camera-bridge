// "Keep this" (js/nvr/kept.js): the stretch an event keeps, the Kept recordings card in Settings › Recording (list, Watch, Let go, the empty
// state), and Keep on the clip bar (nvr/clip.js: one POST nvr/kept per camera of the clip that recorded the range, the bridge's refusals said).
// In the fake browser, with a made-up bridge behind fetch; the bridge's zone is Phoenix and this process runs in Tokyo.
process.env.TZ = 'Asia/Tokyo';

const { after, before, test } = await import('node:test');
const assert = (await import('node:assert/strict')).default;
const { installFakeBrowser, makeStorage } = await import('./support/fake-browser.mjs');

let browser;
let kept;
let createClip;
let setBridgeZone;
before(async () => {
  browser = installFakeBrowser();
  kept = await import('../web/js/nvr/kept.js');
  ({ createClip } = await import('../web/js/nvr/clip.js'));
  ({ setBridgeZone } = await import('../web/js/store.js'));
  setBridgeZone('America/Phoenix');
});
after(() => browser?.restore());

const PORCH = 'AAAAAAAA-0000-4000-8000-00000000000A';
const GARAGE = 'BBBBBBBB-0000-4000-8000-00000000000B';
// 2026-10-31 14:00:00 in Phoenix (UTC−7).
const T = Date.UTC(2026, 9, 31, 21, 0, 0);
const settle = async () => { for (let i = 0; i < 12; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const buttonNamed = (root, text) => all(root, (node) => (node.localName === 'button' || node.localName === 'a') && node.textContent.trim() === text);
const visibleText = (node) => (node.hidden ? '' : node.data !== undefined ? node.data : (node.childNodes ?? []).map(visibleText).join(''));

// MARK: The stretch of an event

test('an event is kept from 30 s before it began to 2 min after it ended, or to 5 min after it began while it is still going', () => {
  assert.deepEqual(kept.eventKeepRange({ at: T, endAt: T + 45_000 }), { from: T - 30_000, to: T + 45_000 + 120_000 });
  assert.deepEqual(kept.eventKeepRange({ at: T, endAt: null }), { from: T - 30_000, to: T + 300_000 }, 'still going');
  assert.deepEqual(kept.eventKeepRange({ at: T, endAt: T - 5 }), { from: T - 30_000, to: T + 300_000 }, 'an end before the start counts as none');
  assert.deepEqual(kept.eventKeepRange({ at: T, endAt: T + 2 * 86_400_000 }), { from: T - 30_000, to: T - 30_000 + 86_400_000 }, 'at most a day, as the bridge keeps');
});

test('a kept stretch is said in the bridge’s time, the end naming its day only when it is another', () => {
  assert.match(kept.keptRangeText(T, T + 330_000), /^Sat,? (31 Oct|Oct 31), 2:00:00\s?PM to 2:05:30\s?PM$/);
  assert.match(kept.keptRangeText(T + 9.5 * 3_600_000, T + 10.5 * 3_600_000), /to Sun,? (1 Nov|Nov 1), 12:30:00\s?AM$/);
  assert.equal(kept.watchKeptPath({ cameraID: PORCH, from: T - 30_000.4 }), `#/nvr/${T - 30_000}?camera=${PORCH}&play=1`);
});

test('what the page says after keeping: the size, each camera’s refusal, and whether anything was kept', () => {
  const porch = { id: PORCH, name: 'Porch' };
  const garage = { id: GARAGE, name: 'Garage' };
  assert.deepEqual(kept.keptSentence({ kept: [{ camera: porch, item: { bytes: 120_000_000 } }], failed: [] }), { ok: true, text: 'Kept: retention won’t delete it (120 MB).' });
  assert.deepEqual(kept.keptSentence({ kept: [{ camera: porch, item: { bytes: 5_000_000 } }], failed: [{ camera: garage, message: 'There is no recording of this camera then, so there is nothing to keep.' }] }),
    { ok: true, text: 'Kept: retention won’t delete it for Porch (5.0 MB). Garage: There is no recording of this camera then, so there is nothing to keep.' });
  assert.deepEqual(kept.keptSentence({ kept: [], failed: [{ camera: porch, message: 'At most 200 stretches can be kept.' }] }), { ok: false, text: 'At most 200 stretches can be kept.' });
});

test('Keep this event: asks for a note, keeps that stretch of its camera, says it; a refusal stays in the dialog; Cancel keeps nothing', async () => {
  const event = { at: T, endAt: T + 20_000, cameraId: PORCH, cameraName: 'Porch', label: 'Person' };
  const sent = [];
  const said = [];
  let refuse = true;
  const send = async (body) => {
    sent.push(body);
    if (refuse) { refuse = false; throw new Error('The recordings are still loading. Try again in a moment.'); }
    return { id: 'k1', ...body, bytes: 8_000_000 };
  };
  // The dialog: its first Keep is refused (the dialog would say so and stay), the second goes through.
  const ask = async (dialog) => {
    assert.equal(dialog.title, 'Keep this event?');
    assert.match(dialog.body, /^Person at Porch: Sat,? (31 Oct|Oct 31), 1:59:30\s?PM to 2:02:20\s?PM\./);
    await assert.rejects(dialog.submit('  At the door ', undefined), /still loading/);
    await dialog.submit('  At the door ', undefined);
    return 'At the door';
  };
  const item = await kept.keepEvent(event, { send, ask, say: (text) => said.push(text) });
  assert.equal(item.id, 'k1');
  assert.deepEqual(sent.at(-1), { cameraID: PORCH, from: T - 30_000, to: T + 20_000 + 120_000, note: 'At the door' });
  assert.deepEqual(said, ['Kept: retention won’t delete it (8.0 MB).']);
  const cancelled = await kept.keepEvent(event, { send, ask: async () => undefined, say: (text) => said.push(text) });
  assert.equal(cancelled, null);
  assert.equal(said.length, 1);
});

test('an Events row offers Keep beside its link only when its moment was recorded', async () => {
  const { eventRow } = await import('../web/js/screens/events-row.js');
  const event = { at: T, endAt: null, cameraId: PORCH, cameraName: 'Porch', label: 'Motion', level: 'motion', description: null };
  const picked = [];
  const recorded = eventRow(event, { thumb: null, href: `/nvr/${T}`, onKeep: (e) => picked.push(e) });
  const keep = all(recorded, (node) => node.localName === 'button')[0];
  assert.ok(keep, 'a Keep button');
  assert.equal(keep.parentNode, recorded, 'beside the link, not in it');
  assert.match(keep.getAttribute('aria-label'), /^Keep this event: Motion, Porch, /);
  keep.dispatchEvent({ type: 'click', preventDefault() {} });
  assert.deepEqual(picked, [event]);
  const missed = eventRow(event, { thumb: null, href: null, onKeep: () => {} });
  assert.equal(all(missed, (node) => node.localName === 'button').length, 0, 'nothing recorded: nothing to keep');
});

// MARK: The card

const ITEMS = [
  { id: 'a1', cameraID: PORCH, cameraName: 'Porch', from: T, to: T + 330_000, note: 'The man at the gate', created: T + 1, bytes: 42_000_000, hasVideo: true },
  { id: 'b2', cameraID: GARAGE, cameraName: 'Garage', from: T - 86_400_000, to: T - 86_000_000, note: '', created: T, bytes: 0, hasVideo: false },
];

test('the card lists each kept stretch: camera, range in the bridge’s time, note, size, Watch at that moment, and Let go', async () => {
  const card = kept.createKeptCard({ load: async () => ({ kept: ITEMS }), forget: async () => {}, confirm: async () => true });
  await settle();
  const rows = byClass(card.el, 'kept-item');
  assert.equal(rows.length, 2);
  assert.match(visibleText(rows[0]), /Sat,? (31 Oct|Oct 31), 2:00:00\s?PM to 2:05:30\s?PM/);
  assert.match(visibleText(rows[0]), /Porch · 42 MB/);
  assert.match(visibleText(rows[0]), /The man at the gate/);
  const watch = buttonNamed(rows[0], 'Watch')[0];
  assert.equal(watch.getAttribute('href'), `#/nvr/${T}?camera=${PORCH}&play=1`, 'the Monitor at that moment, that camera playing');
  assert.match(visibleText(rows[1]), /Its recording is gone/);
  assert.equal(buttonNamed(rows[1], 'Watch').length, 0, 'nothing to watch');
  assert.match(visibleText(card.el), /2 kept stretches\./);
  card.destroy();
});

test('Let go asks first, then lets go of that one only; No leaves it', async () => {
  const forgotten = [];
  let answer = false;
  const asked = [];
  let list = ITEMS;
  const card = kept.createKeptCard({
    load: async () => ({ kept: list }),
    forget: async (id) => { forgotten.push(id); list = list.filter((item) => item.id !== id); },
    confirm: async (question) => { asked.push(question); return answer; },
  });
  await settle();
  const letGo = () => buttonNamed(byClass(card.el, 'kept-item')[0], 'Let go')[0];
  letGo().click();
  await settle();
  assert.equal(asked.length, 1);
  assert.match(asked[0].title, /Let go of this kept recording\?/);
  assert.match(asked[0].body, /^Porch, .*deleted like any other\.$/);
  assert.deepEqual(forgotten, [], 'No: nothing is sent');
  answer = true;
  letGo().click();
  await settle();
  assert.deepEqual(forgotten, ['a1']);
  assert.deepEqual(byClass(card.el, 'kept-item').map((row) => row.dataset.id), ['b2']);
  card.destroy();
});

test('a refusal to let go is said on the card; one already gone (404) just leaves the list', async () => {
  const card = kept.createKeptCard({
    load: async () => ({ kept: ITEMS }),
    forget: async (id) => { throw Object.assign(new Error(id === 'a1' ? 'The recordings are still loading. Try again in a moment.' : 'That kept recording isn’t there any more.'), { status: id === 'a1' ? 503 : 404 }); },
    confirm: async () => true,
  });
  await settle();
  buttonNamed(byClass(card.el, 'kept-item')[0], 'Let go')[0].click();
  await settle();
  assert.equal(visibleText(byClass(card.el, 'kept-problem')[0]), 'The recordings are still loading. Try again in a moment.');
  assert.equal(byClass(card.el, 'kept-item').length, 2, 'still there');
  card.destroy();
});

test('with nothing kept the card says what keeping is for; it says nothing of the kind before the bridge answered', async () => {
  let release;
  const card = kept.createKeptCard({ load: () => new Promise((resolve) => { release = resolve; }) });
  await settle();
  assert.doesNotMatch(visibleText(card.el), /Keep a stretch/, 'not before the answer');
  release({ kept: [] });
  await settle();
  assert.match(visibleText(card.el), /Keep a stretch from the clip bar or an event so retention never deletes it\./);
  assert.equal(byClass(card.el, 'kept-item').length, 0);
  card.destroy();
});

// MARK: Keep on the clip bar

/** A clip bar over `cameras`, its range chosen and planned (the bridge plans one part for each, `noFootage` none); `keep` answers the POSTs. */
async function clipBar(cameras, { keep, noFootage = [] } = {}) {
  globalThis.localStorage = makeStorage();
  globalThis.fetch = async (url) => {
    const empty = noFootage.some((id) => String(url).includes(`/${id}/`));
    return { ok: !empty, status: empty ? 404 : 200, headers: { get: (name) => (name === 'Content-Type' ? 'application/json' : null) },
      json: async () => (empty ? { error: 'not_found', message: 'Nothing was recorded in this time.' } : { parts: [{ index: 1 }], gaps: [], bytes: 1000, soundOmitted: false }) };
  };
  let end = T;
  const keptCalls = [];
  const clip = createClip({ cameras: () => cameras, endMs: () => end, download() {}, keep: async (body) => { keptCalls.push(body); return keep(body); }, onKept: () => keptCalls.push('onKept') });
  clip.begin();
  for (const camera of cameras) clip.toggle(camera.id);
  end += 5_000;
  clip.tick();
  await new Promise((resolve) => setTimeout(resolve, 450));
  return { clip, keptCalls };
}
const note = (clip) => byClass(clip.el, 'nvr-clip-note')[0];
const keepButtonOf = (clip) => buttonNamed(clip.el, 'Keep')[0];

test('Keep sends one POST per camera of the clip that recorded the range, with the note, and says what was kept with its size', async () => {
  const cameras = [{ id: PORCH, name: 'Porch' }, { id: GARAGE, name: 'Garage' }, { id: 'CCCCCCCC-0000-4000-8000-00000000000C', name: 'Side' }];
  const { clip, keptCalls } = await clipBar(cameras, {
    keep: async (body) => ({ id: body.cameraID.slice(0, 4), ...body, bytes: 60_000_000 }),
    noFootage: ['CCCCCCCC-0000-4000-8000-00000000000C'],
  });
  assert.ok(keepButtonOf(clip), 'Keep beside Export');
  assert.ok(!keepButtonOf(clip).disabled);
  note(clip).value = '  Delivery van  ';
  const chosen = clip.range();
  keepButtonOf(clip).click();
  await settle();
  const range = clip.range() ?? null;
  assert.equal(range, null, 'the bar closes once kept');
  const posts = keptCalls.filter((call) => call !== 'onKept');
  assert.equal(posts.length, 2, 'Side recorded nothing then: not asked');
  assert.deepEqual(posts.map((body) => body.cameraID), [PORCH, GARAGE]);
  for (const body of posts) {
    assert.equal(body.note, 'Delivery van');
    assert.deepEqual([body.from, body.to], [chosen.from, chosen.to], 'the red range');
  }
  assert.equal(keptCalls.at(-1), 'onKept', 'the Monitor marks it on the timeline');
  assert.match(visibleText(clip.el), /Kept: retention won’t delete it for Porch, Garage \(120 MB\)\./);
  clip.destroy();
});

test('a refusal is said in the bar, which stays open to try again; the note stays too', async () => {
  const refusal = Object.assign(new Error('Kept recordings can take at most a quarter of the room for recordings. Let go of one you no longer need, or keep a shorter stretch.'), { status: 409 });
  const { clip, keptCalls } = await clipBar([{ id: PORCH, name: 'Porch' }], { keep: async () => { throw refusal; } });
  note(clip).value = 'Gate';
  keepButtonOf(clip).click();
  await settle();
  assert.equal(keptCalls.filter((call) => call !== 'onKept').length, 1);
  assert.ok(!keptCalls.includes('onKept'));
  assert.ok(clip.choosing(), 'the bar stays');
  assert.match(visibleText(clip.el), /It wasn’t kept\. Kept recordings can take at most a quarter of the room for recordings\./);
  assert.equal(note(clip).value, 'Gate', 'what was typed stays');
  clip.destroy();
});

test('one camera refused and another kept: both are said', async () => {
  const { clip } = await clipBar([{ id: PORCH, name: 'Porch' }, { id: GARAGE, name: 'Garage' }], {
    keep: async (body) => {
      if (body.cameraID === GARAGE) throw Object.assign(new Error('At most 200 stretches can be kept. Let go of one you no longer need.'), { status: 409 });
      return { ...body, bytes: 3_000_000 };
    },
  });
  keepButtonOf(clip).click();
  await settle();
  assert.match(visibleText(clip.el), /Kept: retention won’t delete it for Porch \(3\.0 MB\)\. Garage: At most 200 stretches can be kept\./);
  clip.destroy();
});

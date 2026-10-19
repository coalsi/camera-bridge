// nvr/clip.js: the words and the address of a clip, and (in the fake browser) the clip bar's Straightened choice.
import { after, before, beforeEach, describe, it, test } from 'node:test';
import assert from 'node:assert/strict';
import { MINIMUM_MS, WORDS, clipUrl, createClip, durationText, rangeText } from '../web/js/nvr/clip.js';
import { installFakeBrowser, makeStorage } from './support/fake-browser.mjs';

describe('clip words', () => {
  it('writes a duration as m:ss or h:mm:ss', () => {
    assert.equal(durationText(5_000), '0:05');
    assert.equal(durationText(65_400), '1:05');
    assert.equal(durationText(3_723_000), '1:02:03');
  });

  it('names the date of the end only when it is another day', () => {
    const start = new Date(2026, 9, 13, 23, 50, 0).getTime();
    const sameDay = rangeText(start, new Date(2026, 9, 13, 23, 59, 0).getTime());
    const nextDay = rangeText(start, new Date(2026, 9, 14, 0, 10, 0).getTime());
    assert.match(sameDay, / to \d{1,2}:\d{2}:\d{2}/);
    assert.ok(!/Oct.*to .*Oct/.test(sameDay));
    assert.ok(/Oct.* to .*14/.test(nextDay) || /14.* to .*14/.test(nextDay), nextDay);
  });

  it('builds the address of a part from whole milliseconds and an encoded zone', () => {
    assert.equal(clipUrl('abc', 1000.4, 2000.6, 2, 'Europe/Berlin'), '/api/v1/nvr/cameras/abc/clip?from=1000&to=2001&tz=Europe%2FBerlin&part=2');
  });

  it('shares the sentences with the Mac app', () => {
    assert.equal(MINIMUM_MS, 1000);
    assert.equal(WORDS.tooShort, 'Move the end at least 1 second from the start.');
    assert.equal(WORDS.nothing, 'Nothing was recorded in this time.');
  });
});

test('clipUrl asks for straightening only when told', () => {
  assert.match(clipUrl('c', 0, 1000, 1, 'UTC', false, true), /&straighten=1$/);
  assert.doesNotMatch(clipUrl('c', 0, 1000, 1, 'UTC', true, false), /straighten/);
  assert.match(clipUrl('c', 0, 1000, 1, 'UTC', true, true), /&labels=1&straighten=1$/);
});

describe('the Straightened choice', () => {
  const STRAIGHTENED = 'Saves the clip straightened, as you see it. Takes longer to save; unchecked saves it as recorded.';
  const bent = { straighten: 0.4, level: 0.15 };
  let browser;
  before(() => { browser = installFakeBrowser(); });
  after(() => browser?.restore());
  beforeEach(() => {
    globalThis.localStorage = makeStorage();
    // Every camera's plan is one part (the bridge's answer to clip-plan).
    globalThis.fetch = async () => ({ ok: true, status: 200, headers: { get: (name) => (name === 'Content-Type' ? 'application/json' : null) },
      json: async () => ({ parts: [{ index: 1 }], gaps: [], bytes: 1000, soundOmitted: false }) });
  });

  /** Every element under `root` (depth first) that `match` accepts. */
  function all(root, match) {
    const out = [];
    const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
    walk(root);
    return out;
  }
  const straightenBox = (clip) => all(clip.el, (node) => node.localName === 'label' && /Straightened/.test(node.textContent))[0] ?? null;
  const checkbox = (label) => all(label, (node) => node.localName === 'input')[0];

  /** A clip bar over `cameras`, five seconds chosen and planned; `exported()` saves it and answers the addresses it downloaded. */
  async function chosen(cameras, { tick = [] } = {}) {
    let end = 1_800_000_000_000;
    const urls = [];
    const clip = createClip({ cameras: () => cameras, endMs: () => end, download: (url) => urls.push(url) });
    clip.begin();
    for (const id of tick) clip.toggle(id);
    end += 5_000;
    clip.tick();
    await new Promise((resolve) => setTimeout(resolve, 450));   // the plan is asked for once the end has settled (350 ms)
    return { clip, exported: async () => { await clip.exportClip(); return urls; } };
  }

  it('is offered, ticked, for a camera whose picture is straightened, and asks for a straightened clip', async () => {
    const { clip, exported } = await chosen([{ id: 'yard', name: 'Backyard', pictureCorrection: bent }]);
    const label = straightenBox(clip);
    assert.ok(label, 'the Straightened box is there');
    assert.equal(label.getAttribute('title'), STRAIGHTENED);
    assert.equal(checkbox(label).checked, true, 'straightened by default');
    const urls = await exported();
    assert.equal(urls.length, 1);
    assert.match(urls[0], /&straighten=1$/);
    clip.destroy();
  });

  it('unticked saves the clip as recorded, and the next clip bar remembers it', async () => {
    const camera = { id: 'yard', name: 'Backyard', pictureCorrection: bent };
    const first = await chosen([camera]);
    const box = checkbox(straightenBox(first.clip));
    box.checked = false;
    box.dispatchEvent({ type: 'change', target: box });
    assert.equal(localStorage.getItem('cb.clip.straighten'), '0');
    assert.doesNotMatch((await first.exported())[0], /straighten/);
    first.clip.destroy();
    const next = await chosen([camera]);
    assert.ok(!checkbox(straightenBox(next.clip)).checked, 'unticked, as left');   // h() leaves a false `checked` unset, as a new box is
    next.clip.destroy();
  });

  it('is not offered for a camera whose picture is not straightened', async () => {
    localStorage.setItem('cb.clip.straighten', '1');
    for (const pictureCorrection of [undefined, { straighten: 0, level: 0 }]) {
      const { clip, exported } = await chosen([{ id: 'porch', name: 'Porch', pictureCorrection }]);
      assert.equal(straightenBox(clip), null);
      assert.doesNotMatch((await exported())[0], /straighten/);
      clip.destroy();
    }
  });

  it('on the wall, only the straightened cameras ask for it', async () => {
    const cameras = [{ id: 'yard', name: 'Backyard', pictureCorrection: bent }, { id: 'porch', name: 'Porch', pictureCorrection: { straighten: 0, level: 0 } }];
    const porchOnly = await chosen(cameras, { tick: ['porch'] });
    assert.equal(straightenBox(porchOnly.clip), null, 'no straightened camera is ticked');
    porchOnly.clip.destroy();
    const both = await chosen(cameras, { tick: ['yard', 'porch'] });
    assert.ok(straightenBox(both.clip));
    const urls = await both.exported();
    assert.match(urls.find((url) => url.includes('/yard/')), /&straighten=1$/);
    assert.doesNotMatch(urls.find((url) => url.includes('/porch/')), /straighten/);
    both.clip.destroy();
  });

  it('works without storage (a private window): straightened', async () => {
    globalThis.localStorage = makeStorage({ broken: true });
    const { clip } = await chosen([{ id: 'yard', name: 'Backyard', pictureCorrection: bent }]);
    const box = checkbox(straightenBox(clip));
    assert.equal(box.checked, true);
    box.checked = false;
    assert.doesNotThrow(() => box.dispatchEvent({ type: 'change', target: box }));
    clip.destroy();
  });
});

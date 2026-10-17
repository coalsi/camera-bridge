// planner.js: the pure rules of the player.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_POLICY, MESSAGES, POLICY_TABLE, browserClass, bufferSeconds, canSeekInChain, choosePolicy, currentEnvironment, dedupeChains, extendChain, findChainPart,
  follows, governingKey, heldRangeAt, keyStepLookup, lastChain, makeChain, nextFetches, planEviction, rangeAfterHole, rangeHolds, reconcileChains, seekSeconds,
  timestampOffsetSeconds, unsupportedMessage,
} from '../web/js/nvr/planner.js';

const ORIGIN = 1_760_000_000_000;
const BASE = ORIGIN - 400 * 86_400_000;          // the catalog's fixed base: server time minus 400 days
const FILE = 'a1b2c3d4e5f6';

/** A 2 s part of FILE starting at ORIGIN + index * 2000; key every `gop` parts. */
function part(index, { file = FILE, gop = 1, bytes = 100_000, startMs = ORIGIN, length = 2000 } = {}) {
  const start = startMs + index * length;
  return { id: `${file}.${index}`, file, start, end: start + length, bytes, key: index % gop === 0 };
}

function chainOf(from, to, options) {
  const chain = makeChain(part(from, options));
  for (let i = from + 1; i <= to; i += 1) extendChain(chain, part(i, options));
  return chain;
}

function planOf(indices, targetIndex, options = {}) {
  return { found: true, at: 0, exact: options.exact ?? true, targetIndex, parts: indices.map((i) => part(i, options)), files: {} };
}

describe('time arithmetic', () => {
  it('buffer times are positive, near 3.5e7 seconds, and keep millisecond precision', () => {
    assert.equal(BASE, 1_760_000_000_000 - 34_560_000_000);
    assert.equal(bufferSeconds(ORIGIN, BASE), 34_560_000);
    assert.equal(bufferSeconds(BASE + 34_560_000_123, BASE), 34_560_000.123);
    assert.ok(bufferSeconds(BASE, BASE) === 0);
  });

  it('timestampOffsetSeconds puts a file on the shared time line: tfdt + offset = (epoch ms - base) / 1000', () => {
    const mediaStartTicks = 123_456_789;                                 // the first tfdt of the file, 90 kHz
    const anchor = ORIGIN - mediaStartTicks / 90;                         // epoch ms = anchor + media seconds x 1000 (a double)
    const offset = timestampOffsetSeconds(anchor, BASE);
    for (const index of [0, 1, 17, 59]) {
      const p = part(index);
      const tfdtTicks = mediaStartTicks + (p.start - ORIGIN) * 90;
      assert.ok(Math.abs(tfdtTicks / 90_000 + offset - bufferSeconds(p.start, BASE)) < 1e-6, `part ${index}`);
    }
  });

  it('seekSeconds keeps the target 1 ms inside the part', () => {
    const p = part(3);
    assert.equal(seekSeconds(p, p.start + 500, BASE), bufferSeconds(p.start + 500, BASE));
    assert.equal(seekSeconds(p, p.start - 5000, BASE), bufferSeconds(p.start + 1, BASE));
    assert.equal(seekSeconds(p, p.start, BASE), bufferSeconds(p.start + 1, BASE));
    assert.equal(seekSeconds(p, p.end, BASE), bufferSeconds(p.end - 1, BASE));
    assert.equal(seekSeconds(p, p.end + 9000, BASE), bufferSeconds(p.end - 1, BASE));
    const tiny = { id: 'x.1', file: 'x', start: 1000, end: 1002, bytes: 1, key: true };
    assert.equal(seekSeconds(tiny, 1000, 0), 1.001);
    const degenerate = { id: 'x.2', file: 'x', start: 1000, end: 1001, bytes: 1, key: true };
    assert.equal(seekSeconds(degenerate, 5, 0), 1.0005);
  });
});

describe('chains', () => {
  it('canSeekInChain needs 700 ms of chain after the target', () => {
    const chain = chainOf(0, 2);                                          // ORIGIN ... ORIGIN + 6000
    assert.equal(canSeekInChain(chain, ORIGIN + 5300), true);             // exactly 700 ms left
    assert.equal(canSeekInChain(chain, ORIGIN + 5301), false);
    assert.equal(canSeekInChain(chain, ORIGIN + 6000), false);
    assert.equal(canSeekInChain(chain, ORIGIN - 1), false);
    assert.equal(canSeekInChain(chain, ORIGIN), true);
    assert.equal(canSeekInChain(chain, ORIGIN + 5000, { marginMs: 1500 }), false);
    assert.equal(canSeekInChain(chain, ORIGIN + 4500, { marginMs: 1500 }), true);
  });

  it('a chain grows by extendChain and reports follows() only for the next part', () => {
    const chain = makeChain(part(0));
    assert.equal(follows(chain, part(1)), true);
    assert.equal(follows(chain, part(2)), false);
    extendChain(chain, part(1));
    assert.deepEqual([chain.headId, chain.tailId, chain.startMs, chain.endMs], [`${FILE}.0`, `${FILE}.1`, ORIGIN, ORIGIN + 4000]);
    assert.equal(follows(chain, { ...part(2), start: ORIGIN + 4002 }), true);
    assert.equal(follows(chain, { ...part(2), start: ORIGIN + 4003 }), false);
    assert.equal(follows(chain, { ...part(2), start: ORIGIN + 3997 }), false);
  });

  it('lastChain is the newest chain that ends with the part appended last', () => {
    const a = chainOf(0, 2);
    const b = chainOf(10, 12);
    const twin = chainOf(10, 12);
    assert.equal(lastChain([a, b], `${FILE}.12`), b);
    assert.equal(lastChain([a, b, twin], `${FILE}.12`), twin);
    assert.equal(lastChain([a, b], `${FILE}.99`), null);
    assert.equal(lastChain([a, b], null), null);
    assert.equal(lastChain([], `${FILE}.2`), null);
  });

  it('findChainPart is start-inclusive, end-exclusive, and prefers the chain with more data after', () => {
    const short = chainOf(0, 0);
    const long = chainOf(0, 3);
    assert.equal(findChainPart([short, long], ORIGIN + 500).chain, long);
    assert.equal(findChainPart([short], ORIGIN + 2000), null);
    assert.equal(findChainPart([short], ORIGIN).part.id, `${FILE}.0`);
    assert.equal(findChainPart([], ORIGIN), null);
  });

  it('governingKey is the last key part at or before the time', () => {
    const chain = chainOf(0, 7, { gop: 4 });                              // keys at 0 and 4
    assert.equal(governingKey(chain, ORIGIN + 2500).id, `${FILE}.0`);
    assert.equal(governingKey(chain, ORIGIN + 8000).id, `${FILE}.4`);
    assert.equal(governingKey(chain, ORIGIN + 15_900).id, `${FILE}.4`);
  });

  it('dedupeChains drops a chain another chain holds in full, but never the chain appended last', () => {
    const big = chainOf(0, 4);
    const inside = chainOf(2, 3);
    const apart = chainOf(10, 11);
    assert.deepEqual(dedupeChains([big, inside, apart]), [big, apart]);
    assert.deepEqual(dedupeChains([inside, apart]), [inside, apart]);
    const again = chainOf(0, 2);                                          // the same start again, shorter: it was appended last
    assert.deepEqual(dedupeChains([big, again], again.tailId), [big, again]);
    const twin = chainOf(0, 4);
    assert.deepEqual(dedupeChains([big, twin]), [big], 'of two equal chains the first stays');
    assert.deepEqual(dedupeChains([big, twin], twin.tailId), [twin], 'unless the other was appended last');
  });
});

describe('keyStepLookup', () => {
  it('seeks straight into a held chain when 700 ms follow the target', () => {
    const chain = chainOf(0, 2);
    const hit = keyStepLookup([chain], new Map(), ORIGIN + 3000);
    assert.deepEqual([hit.kind, hit.atMs, hit.part.id], ['held', ORIGIN + 3000, `${FILE}.1`]);
  });

  it('near the tail it shows the key picture of the held GOP instead', () => {
    const chain = chainOf(0, 2, { gop: 3 });                              // one GOP of three parts
    const hit = keyStepLookup([chain], new Map(), ORIGIN + 5800);
    assert.deepEqual([hit.kind, hit.atMs, hit.part.id], ['held', ORIGIN + 1, `${FILE}.0`]);
  });

  it('uses a hint: a target the server already mapped to this head needs no request', () => {
    const chain = chainOf(0, 0, { gop: 15 });                             // only the key part is held
    const hints = new Map([[`${FILE}.0`, { fromMs: ORIGIN, toMs: ORIGIN + 20_000 }]]);
    const inside = keyStepLookup([chain], hints, ORIGIN + 12_000);
    assert.deepEqual([inside.kind, inside.atMs], ['held', ORIGIN + 1]);
    assert.equal(keyStepLookup([chain], hints, ORIGIN + 20_001).kind, 'fetch');
    assert.equal(keyStepLookup([chain], hints, ORIGIN - 1).kind, 'fetch');
  });

  it('asks the server when nothing held covers the target', () => {
    assert.equal(keyStepLookup([], new Map(), ORIGIN).kind, 'fetch');
    assert.equal(keyStepLookup([chainOf(0, 1)], new Map(), ORIGIN + 90_000).kind, 'fetch');
  });
});

describe('nextFetches', () => {
  it('starts a new chain at the key part when nothing is held', () => {
    const plan = planOf([4, 5, 6], 1, { gop: 4 });
    const result = nextFetches(plan, [], { maxBytes: 1e9 });
    assert.deepEqual(result.fetch.map((p) => p.id), [`${FILE}.4`, `${FILE}.5`, `${FILE}.6`]);
    assert.equal(result.coarse, false);
    assert.equal(result.extend, null);
  });

  it('extends the chain that holds the key part when it was appended last, fetching only what follows its tail', () => {
    const chain = chainOf(4, 4, { gop: 4 });                              // the key picture is held
    const plan = planOf([4, 5, 6], 1, { gop: 4 });
    const result = nextFetches(plan, [chain], { maxBytes: 1e9, lastAppendedId: chain.tailId });
    assert.deepEqual(result.fetch.map((p) => p.id), [`${FILE}.5`, `${FILE}.6`]);
    assert.equal(result.extend, chain);
  });

  it('cannot continue a chain after something else was appended: a delta part would be dropped, so the GOP starts over from its key part', () => {
    const chain = chainOf(4, 4, { gop: 4 });
    const elsewhere = chainOf(30, 30, { gop: 4 });
    const plan = planOf([4, 5, 6], 1, { gop: 4 });
    const result = nextFetches(plan, [chain, elsewhere], { maxBytes: 1e9, lastAppendedId: elsewhere.tailId });
    assert.deepEqual(result.fetch.map((p) => p.id), [`${FILE}.4`, `${FILE}.5`, `${FILE}.6`]);
    assert.equal(result.extend, null);
    assert.deepEqual(nextFetches(plan, [chain], { maxBytes: 1e9 }).fetch.map((p) => p.id), [`${FILE}.4`, `${FILE}.5`, `${FILE}.6`], 'nothing appended yet counts as elsewhere');
  });

  it('a key part that follows an old chain can start a new chain without fetching the key part again', () => {
    const chain = chainOf(4, 4, { gop: 1 });                              // every part is a key part
    const elsewhere = chainOf(30, 30, { gop: 1 });
    const plan = planOf([4, 5, 6], 2, { gop: 1 });
    const result = nextFetches(plan, [chain, elsewhere], { maxBytes: 1e9, lastAppendedId: elsewhere.tailId });
    assert.deepEqual(result.fetch.map((p) => p.id), [`${FILE}.5`, `${FILE}.6`]);
    assert.equal(result.extend, null);
  });

  it('uses the chain that holds the most of the plan, and the one appended last on a tie', () => {
    const short = chainOf(4, 5, { gop: 4 });
    const long = chainOf(4, 8, { gop: 4 });
    const plan = planOf([4, 5, 6], 1, { gop: 4 });
    assert.deepEqual(nextFetches(plan, [short, long], { maxBytes: 1e9, lastAppendedId: short.tailId }), { fetch: [], coarse: false, extend: null });
    const a = chainOf(4, 5, { gop: 4 });
    const b = chainOf(4, 5, { gop: 4 });                                  // the same parts again: the newest chain with the tail appended last wins
    assert.equal(nextFetches(plan, [a, b], { maxBytes: 1e9, lastAppendedId: b.tailId }).extend, b);
    assert.equal(nextFetches(plan, [b, a], { maxBytes: 1e9, lastAppendedId: b.tailId }).extend, a);
  });

  it('fetches nothing when the whole plan is held', () => {
    const chain = chainOf(4, 8, { gop: 4 });
    const result = nextFetches(planOf([4, 5, 6], 1, { gop: 4 }), [chain], { maxBytes: 1e9 });
    assert.deepEqual(result, { fetch: [], coarse: false, extend: null });
  });

  it('starts over from the key part when the held chain goes on with other parts', () => {
    const chain = chainOf(4, 5, { gop: 4 });
    const other = { ...part(6, { gop: 4 }), id: `${FILE}.99` };            // the chain continues with a part the plan does not list
    extendChain(chain, other);
    const result = nextFetches(planOf([4, 5, 6], 2, { gop: 4 }), [chain], { maxBytes: 1e9 });
    assert.deepEqual(result.fetch.map((p) => p.id), [`${FILE}.4`, `${FILE}.5`, `${FILE}.6`]);
    assert.equal(result.extend, null);
  });

  it('a hole after the tail: a key part next starts a new chain, a delta part means starting over', () => {
    const chain = chainOf(4, 4, { gop: 1 });
    const gapped = planOf([4, 5], 0, { gop: 1 });
    gapped.parts[1] = { ...gapped.parts[1], start: gapped.parts[1].start + 5000, end: gapped.parts[1].end + 5000 };
    const afterKey = nextFetches(gapped, [chain], { maxBytes: 1e9 });
    assert.deepEqual(afterKey.fetch.map((p) => p.id), [`${FILE}.5`]);
    assert.equal(afterKey.extend, null);
    const deltaPlan = planOf([4, 5], 0, { gop: 4 });
    deltaPlan.parts[1] = { ...deltaPlan.parts[1], start: deltaPlan.parts[1].start + 5000, end: deltaPlan.parts[1].end + 5000 };
    const delta = nextFetches(deltaPlan, [chainOf(4, 4, { gop: 4 })], { maxBytes: 1e9 });
    assert.deepEqual(delta.fetch.map((p) => p.id), [`${FILE}.4`, `${FILE}.5`]);
    assert.equal(delta.extend, null);
  });

  it('is coarse when the missing lead-in exceeds maxBytes, and then fetches the key part only', () => {
    const plan = planOf([0, 1, 2, 3, 4], 3, { gop: 8, bytes: 400_000 });   // lead-in = parts 0..3 = 1.6 MB
    const coarse = nextFetches(plan, [], { maxBytes: 1_500_000 });
    assert.equal(coarse.coarse, true);
    assert.deepEqual(coarse.fetch.map((p) => p.id), [`${FILE}.0`]);
    const fine = nextFetches(plan, [], { maxBytes: 1_600_000 });
    assert.equal(fine.coarse, false);
    assert.equal(fine.fetch.length, 5);                                    // the look-ahead part comes too
  });

  it('counts only the missing parts against maxBytes', () => {
    const chain = chainOf(0, 2, { gop: 8, bytes: 400_000 });
    const plan = planOf([0, 1, 2, 3, 4], 3, { gop: 8, bytes: 400_000 });
    const result = nextFetches(plan, [chain], { maxBytes: 450_000, lastAppendedId: chain.tailId });      // only part 3 is missing from the lead-in
    assert.equal(result.coarse, false);
    assert.deepEqual(result.fetch.map((p) => p.id), [`${FILE}.3`, `${FILE}.4`]);
    assert.equal(result.extend, chain);
  });

  it('is coarse when the server says the lead-in is not exact, and holds the key picture when it is already held', () => {
    const plan = planOf([0], 0, { gop: 100, exact: false });
    assert.equal(nextFetches(plan, [], { maxBytes: 1e9 }).coarse, true);
    assert.deepEqual(nextFetches(plan, [chainOf(0, 0, { gop: 100 })], { maxBytes: 1e9 }), { fetch: [], coarse: true, extend: null });
  });

  it('answers nothing for a plan that was not found', () => {
    assert.deepEqual(nextFetches({ found: false, reason: 'gap' }, [], {}), { fetch: [], coarse: false, extend: null });
    assert.deepEqual(nextFetches(null, [], {}), { fetch: [], coarse: false, extend: null });
  });
});

describe('reconcileChains', () => {
  const seconds = (ms) => bufferSeconds(ms, BASE);
  const held = (fromMs, toMs) => ({ start: seconds(fromMs), end: seconds(toMs) });

  it('keeps a chain that is wholly held', () => {
    const chain = chainOf(0, 2);
    assert.deepEqual(reconcileChains([chain], [held(ORIGIN, ORIGIN + 6000)], BASE), [chain]);
  });

  it('keeps the held prefix when the tail was evicted', () => {
    const chain = chainOf(0, 3);
    const [kept] = reconcileChains([chain], [held(ORIGIN, ORIGIN + 4000)], BASE);
    assert.deepEqual(kept.parts.map((p) => p.id), [`${FILE}.0`, `${FILE}.1`]);
    assert.deepEqual([kept.tailId, kept.startMs, kept.endMs], [`${FILE}.1`, ORIGIN, ORIGIN + 4000]);
  });

  it('drops a chain whose first part is gone, or that lies in no held range', () => {
    const chain = chainOf(0, 3);
    assert.deepEqual(reconcileChains([chain], [held(ORIGIN + 2000, ORIGIN + 8000)], BASE), []);
    assert.deepEqual(reconcileChains([chain], [], BASE), []);
    assert.deepEqual(reconcileChains([chain], [held(ORIGIN + 100_000, ORIGIN + 200_000)], BASE), []);
  });

  it('tolerates a few milliseconds of rounding at the edges', () => {
    const chain = chainOf(0, 1);
    const ranges = [{ start: seconds(ORIGIN) + 0.004, end: seconds(ORIGIN + 4000) - 0.004 }];
    assert.equal(reconcileChains([chain], ranges, BASE).length, 1);
  });

  it('keeps the whole chain when its sound starts or ends a frame inside the picture (the Doorbell: 64 ms at 16 kHz AAC)', () => {
    const chain = chainOf(0, 2);
    const [kept] = reconcileChains([chain], [held(ORIGIN + 40, ORIGIN + 6000 - 64)], BASE);
    assert.deepEqual([kept?.tailId, kept?.endMs], [`${FILE}.2`, ORIGIN + 6000], 'the part appended last is still the tail');
    const late = chainOf(0, 1, { length: 640 });                                           // a short part (Patio's 640 ms) a frame short
    assert.equal(reconcileChains([late], [held(ORIGIN, ORIGIN + 1280 - 64)], BASE)[0]?.tailId, `${FILE}.1`);
  });

  it('keeps a chain across a hole under the slack in what the video holds (the first picture of the next file starts late)', () => {
    const chain = chainOf(0, 3);
    const [kept] = reconcileChains([chain], [held(ORIGIN, ORIGIN + 4000), held(ORIGIN + 4100, ORIGIN + 8000)], BASE);
    assert.equal(kept.tailId, `${FILE}.3`);
  });

  it('still drops a part that was removed, however short it is', () => {
    const chain = chainOf(0, 3, { length: 300 });
    const [kept] = reconcileChains([chain], [held(ORIGIN, ORIGIN + 600), held(ORIGIN + 900, ORIGIN + 1200)], BASE);
    assert.deepEqual(kept.parts.map((p) => p.id), [`${FILE}.0`, `${FILE}.1`], 'part 2 is gone, so is everything after it');
    assert.deepEqual(reconcileChains([chainOf(0, 1, { length: 300 })], [held(ORIGIN + 300, ORIGIN + 600)], BASE), [], 'the first part is gone');
    const short = chainOf(0, 3, { length: 150 });                                           // parts of 150 ms, part 2 removed
    const [rest] = reconcileChains([short], [held(ORIGIN, ORIGIN + 300), held(ORIGIN + 450, ORIGIN + 600)], BASE);
    assert.deepEqual(rest.parts.map((p) => p.id), [`${FILE}.0`, `${FILE}.1`], 'a removed 150 ms part, its neighbours held right up to it');
    assert.deepEqual(reconcileChains([chainOf(0, 1, { length: 150 })], [held(ORIGIN + 150, ORIGIN + 300)], BASE), [], 'a removed first part of 150 ms');
  });

  it('keeps a last part shorter than three times its sound\'s shortfall (a file break cut it to 150 ms)', () => {
    const chain = chainOf(0, 3);
    extendChain(chain, { ...part(4), start: ORIGIN + 8000, end: ORIGIN + 8150 });
    const [kept] = reconcileChains([chain], [held(ORIGIN, ORIGIN + 8150 - 64)], BASE);
    assert.equal(kept?.tailId, `${FILE}.4`, 'the part appended last is still the tail');
  });
});

describe('what the video element holds', () => {
  const seconds = (ms) => bufferSeconds(ms, BASE);
  const held = (fromMs, toMs) => ({ start: seconds(fromMs), end: seconds(toMs) });

  it('rangeHolds: a span is held with a quarter second of slack at the edges when the range reaches into it', () => {
    const range = held(ORIGIN + 200, ORIGIN + 1800);
    assert.equal(rangeHolds(range, seconds(ORIGIN), seconds(ORIGIN + 2000)), true);
    assert.equal(rangeHolds(range, seconds(ORIGIN - 100), seconds(ORIGIN + 2000)), false);
    assert.equal(rangeHolds(held(ORIGIN, ORIGIN + 150 - 64), seconds(ORIGIN), seconds(ORIGIN + 150)), true, 'a 150 ms span whose sound ends 64 ms early');
    assert.equal(rangeHolds(held(ORIGIN + 40, ORIGIN + 150), seconds(ORIGIN), seconds(ORIGIN + 150)), true, 'a 150 ms span whose sound starts 40 ms late');
    assert.equal(rangeHolds(held(ORIGIN - 2000, ORIGIN + 2), seconds(ORIGIN), seconds(ORIGIN + 150)), false, 'a range that ends where the span starts');
    assert.equal(rangeHolds(held(ORIGIN + 148, ORIGIN + 2000), seconds(ORIGIN), seconds(ORIGIN + 150)), false, 'a range that starts where the span ends');
  });

  it('heldRangeAt finds the range a playhead stands in, its end included', () => {
    const ranges = [held(ORIGIN, ORIGIN + 4000), held(ORIGIN + 4100, ORIGIN + 8000)];
    assert.equal(heldRangeAt(ranges, seconds(ORIGIN + 4000)), ranges[0]);
    assert.equal(heldRangeAt(ranges, seconds(ORIGIN + 4050)), null);
    assert.equal(heldRangeAt(ranges, seconds(ORIGIN + 4100)), ranges[1]);
  });

  it('rangeAfterHole: the next range when the hole is short and the range long enough for a seek', () => {
    const ranges = [held(ORIGIN, ORIGIN + 4000), held(ORIGIN + 4100, ORIGIN + 8000), held(ORIGIN + 9500, ORIGIN + 20_000)];
    const options = { maxHoleSec: 1, minSec: 0.72 };
    assert.equal(rangeAfterHole(ranges, seconds(ORIGIN + 3400), options), ranges[1]);
    assert.equal(rangeAfterHole(ranges, seconds(ORIGIN + 7500), options), null, 'a hole of 1.5 s is a gap');
    assert.equal(rangeAfterHole([held(ORIGIN, ORIGIN + 4000), held(ORIGIN + 4100, ORIGIN + 4500)], seconds(ORIGIN + 3400), options), null, 'too short to show a picture');
    assert.equal(rangeAfterHole(ranges, seconds(ORIGIN + 4050), options), null, 'not in what is held');
  });
});

describe('planEviction', () => {
  const entry = (startSec, endSec, bytes, key = true) => ({ startSec, endSec, bytes, key });

  it('removes nothing while under the budget', () => {
    const plan = planEviction([entry(0, 2, 5), entry(2, 4, 5)], 1, 10);
    assert.deepEqual(plan.remove, []);
    assert.equal(plan.keptBytes, 10);
  });

  it('removes the farthest GOP units first and never the one under the playhead', () => {
    const ledger = [entry(0, 2, 4), entry(2, 4, 4), entry(4, 6, 4), entry(6, 8, 4), entry(100, 102, 4)];
    const plan = planEviction(ledger, 5, 12);
    assert.deepEqual(plan.remove.map((r) => [r.startSec, r.endSec]), [[100, 102], [0, 2]]);
    assert.equal(plan.keptBytes, 12);
    const tight = planEviction(ledger, 5, 1);
    assert.ok(!tight.remove.some((r) => r.startSec === 4), 'the unit under the playhead stays');
    assert.equal(tight.keptBytes, 4);
  });

  it('treats continuation entries as part of their key entry', () => {
    const ledger = [entry(0, 2, 10, true), entry(2, 4, 10, false), entry(4, 6, 10, false), entry(50, 52, 10, true)];
    const plan = planEviction(ledger, 51, 10);
    assert.deepEqual(plan.remove.map((r) => [r.startSec, r.endSec, r.bytes]), [[0, 6, 30]]);
    assert.equal(plan.remove[0].entries.length, 3);
  });

  it('a delta entry that is not contiguous starts its own unit', () => {
    const plan = planEviction([entry(0, 2, 10, true), entry(10, 12, 10, false)], 100, 10);
    assert.equal(plan.remove.length, 1);
    assert.deepEqual([plan.remove[0].startSec, plan.remove[0].endSec], [0, 2]);
  });
});

describe('what this browser can do', () => {
  const UA = {
    chrome: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36',
    edge: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0',
    safari: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
    firefox: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:131.0) Gecko/20100101 Firefox/131.0',
    iphone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1',
    iphoneChrome: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/129.0.0.0 Mobile/15E148 Safari/604.1',
    ipad: 'Mozilla/5.0 (iPad; CPU OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1',
  };

  it('classifies browsers', () => {
    assert.equal(browserClass({ userAgent: UA.chrome }), 'chromium');
    assert.equal(browserClass({ userAgent: UA.edge }), 'chromium');
    assert.equal(browserClass({ userAgent: UA.safari }), 'safari');
    assert.equal(browserClass({ userAgent: UA.firefox }), 'firefox');
    assert.equal(browserClass({ userAgent: UA.iphone }), 'iphone');
    assert.equal(browserClass({ userAgent: UA.iphoneChrome }), 'iphone');
    assert.equal(browserClass({ userAgent: UA.ipad }), 'ipad');
    assert.equal(browserClass({ userAgent: UA.safari, maxTouchPoints: 5 }), 'ipad');   // iPadOS asks for the desktop page
    assert.equal(browserClass({ userAgent: UA.safari, maxTouchPoints: 0 }), 'safari');
    assert.equal(browserClass({ userAgent: 'curl/8' }), 'other');
    assert.equal(browserClass({}), 'other');
  });

  it('chooses the table entry and the MediaSource this browser has', () => {
    const mac = choosePolicy({ userAgent: UA.chrome, hasMediaSource: true, hasManagedMediaSource: false });
    assert.deepEqual([mac.browser, mac.keySteps, mac.mimeChange, mac.maxTiles, mac.mediaSource, mac.canPlay, mac.reason], ['chromium', true, 'recreate', 9, 'MediaSource', true, null]);
    assert.equal(mac.initAfterBreak, true);
    const safari = choosePolicy({ userAgent: UA.safari, hasMediaSource: true, hasManagedMediaSource: true });
    assert.deepEqual([safari.mediaSource, safari.keySteps, safari.maxTiles, safari.canPlay], ['MediaSource', false, 4, true]);
    const phone = choosePolicy({ userAgent: UA.iphone, hasMediaSource: false, hasManagedMediaSource: true });
    assert.deepEqual([phone.browser, phone.mediaSource, phone.maxTiles, phone.keySteps], ['iphone', 'ManagedMediaSource', 2, false]);
    const pad = choosePolicy({ userAgent: UA.ipad, hasMediaSource: true });
    assert.deepEqual([pad.maxTiles, pad.keySteps, pad.canPlay], [4, false, true]);
  });

  it('is the decision of the spike (T06, linux/web-dev/spike/DECISION.json): key steps for Chrome only, the init again after every abort, iPhone off', () => {
    const column = (name) => Object.fromEntries(Object.entries(POLICY_TABLE).map(([browser, entry]) => [browser, entry[name]]));
    assert.deepEqual(column('keySteps'), { chromium: true, safari: false, firefox: false, ipad: false, iphone: false, other: false });
    assert.deepEqual(column('play'), { chromium: true, safari: true, firefox: true, ipad: true, iphone: false, other: true });
    // Chrome measured 2026-10-14: five 8 MP recordings of the owner's cameras at their full rate.
    assert.deepEqual(column('maxTiles'), { chromium: 9, safari: 4, firefox: 4, ipad: 4, iphone: 2, other: 4 });
    assert.deepEqual(column('mimeChange'), { chromium: 'recreate', safari: 'recreate', firefox: 'recreate', ipad: 'recreate', iphone: 'recreate', other: 'recreate' });
    assert.deepEqual(column('initAfterBreak'), { chromium: true, safari: true, firefox: true, ipad: true, iphone: true, other: true });
  });

  it('DEFAULT_POLICY (a cell or surface built without one) takes the protocol fields from the Chromium row but allows any tile count', () => {
    assert.deepEqual([DEFAULT_POLICY.mimeChange, DEFAULT_POLICY.initAfterBreak, DEFAULT_POLICY.keySteps, DEFAULT_POLICY.canPlay], ['recreate', true, true, true]);
    assert.equal(DEFAULT_POLICY.maxTiles, 9, 'only a session reads the cap, and it chooses its own policy');
  });

  it('cannot play without any MediaSource, and says why', () => {
    const old = choosePolicy({ userAgent: UA.iphone });
    assert.deepEqual([old.canPlay, old.mediaSource, old.reason], [false, null, MESSAGES.needsNewerIOS]);
    assert.equal(choosePolicy({ userAgent: UA.firefox }).reason, MESSAGES.noMediaSource);
  });

  it('a class the spike switched off cannot play even where MediaSource exists, and an iPhone is told so in its own words', () => {
    const phone = choosePolicy({ userAgent: UA.iphone, hasManagedMediaSource: true });
    assert.deepEqual([phone.canPlay, phone.mediaSource, phone.reason], [false, 'ManagedMediaSource', MESSAGES.noIPhone]);
    assert.doesNotMatch(MESSAGES.noIPhone, /Safari|Chrome/, 'an iPhone user is in Safari or Chrome already');
    const table = { ...POLICY_TABLE, firefox: { ...POLICY_TABLE.firefox, play: false } };
    const other = choosePolicy({ userAgent: UA.firefox, hasMediaSource: true }, table);
    assert.deepEqual([other.canPlay, other.mediaSource, other.reason], [false, 'MediaSource', MESSAGES.noMediaSource]);
    const on = { ...POLICY_TABLE, iphone: { ...POLICY_TABLE.iphone, play: true } };
    assert.equal(choosePolicy({ userAgent: UA.iphone, hasManagedMediaSource: true }, on).canPlay, true);
  });

  it('the table is frozen, and an unknown browser gets settle-based scrubbing', () => {
    assert.throws(() => { 'use strict'; POLICY_TABLE.chromium.keySteps = false; });
    assert.equal(choosePolicy({ userAgent: 'curl/8', hasMediaSource: true }).keySteps, false);
  });

  it('reads the environment from a global scope without throwing when parts are missing', () => {
    assert.deepEqual(currentEnvironment({}), { userAgent: '', maxTouchPoints: 0, hasMediaSource: false, hasManagedMediaSource: false });
    const env = currentEnvironment({ navigator: { userAgent: UA.safari, maxTouchPoints: 0 }, MediaSource: class {}, ManagedMediaSource: class {} });
    assert.deepEqual(env, { userAgent: UA.safari, maxTouchPoints: 0, hasMediaSource: true, hasManagedMediaSource: true });
  });

  it('words the unsupported-codec sentence for H.265 and for everything else', () => {
    assert.equal(unsupportedMessage('video/mp4; codecs="hvc1.1.6.L153.B0"'), MESSAGES.cannotPlayHEVC);
    assert.equal(unsupportedMessage('video/mp4; codecs="hev1.1.6.L93.B0"'), MESSAGES.cannotPlayHEVC);
    assert.equal(unsupportedMessage('video/mp4; codecs="avc1.4d0032"'), MESSAGES.cannotPlay);
  });
});

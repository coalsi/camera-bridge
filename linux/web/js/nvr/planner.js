// The rules of the player, as pure functions: time arithmetic, which parts to fetch, what to keep, what this browser can do.
//
// Times are epoch milliseconds in the server's time base. "Buffer seconds" are what the video element sees: (ms - baseMs) / 1000, where
// `baseMs` is the catalog's fixed base for this page load, so every buffer time is positive.
//
// Shapes used here:
//   Part  = { id, file, start, end, bytes, key }          one fragment (the server's list entries)
//   Chain = { headId, tailId, fileKey, parts: Part[], startMs, endMs }
//           consecutive parts of one camera appended in order into one contiguous run, the first one a key part

export const MESSAGES = Object.freeze({
  driveMissing: 'The recordings drive isn’t connected.',
  archiveAway: 'On the archive drive (not connected). It plays again when the drive is plugged back in.',
  unreadable: 'Can’t read this part of the recording.',
  unavailable: 'The recordings aren’t available right now.',
  busy: 'The bridge is busy. Trying again…',
  oldest: 'This is the oldest recording.',
  empty: 'Nothing is recorded for this camera yet.',
  network: 'Lost contact with the bridge.',
  playerFailed: 'This browser stopped playing the recording.',
  cannotPlayHEVC: 'This browser can’t play H.265 recordings. Safari, or Chrome on a Mac, can.',
  cannotPlay: 'This browser can’t play these recordings.',
  noMediaSource: 'This browser can’t play recordings. Try Safari or Chrome, or update this device.',
  needsNewerIOS: 'Recordings need iOS 17.1 or later.',
  noIPhone: 'Recordings can’t be played on an iPhone yet. Open this page on a Mac or an iPad.',
});

// MARK: Time

export function bufferSeconds(ms, baseMs) { return (ms - baseMs) / 1000; }

export function timestampOffsetSeconds(anchorMs, baseMs) { return (anchorMs - baseMs) / 1000; }

/** Where to seek to show `targetMs` inside `part`: the target, kept 1 ms inside the part so it is never a boundary. In buffer seconds. */
export function seekSeconds(part, targetMs, baseMs) {
  const low = part.start + 1;
  const high = part.end - 1;
  const clamped = low > high ? (part.start + part.end) / 2 : Math.min(Math.max(targetMs, low), high);
  return bufferSeconds(clamped, baseMs);
}

// MARK: Chains

export function makeChain(part) {
  return { headId: part.id, tailId: part.id, fileKey: part.file, parts: [part], startMs: part.start, endMs: part.end };
}

export function extendChain(chain, part) {
  chain.parts.push(part);
  chain.tailId = part.id;
  chain.endMs = Math.max(chain.endMs, part.end);
  return chain;
}

/** True when `part` continues `chain` without a hole or an overlap of more than 2 ms. */
export function follows(chain, part) {
  return Math.abs(part.start - chain.endMs) <= 2;
}

/** Hardware decoders hold frames back: a direct seek is allowed only when at least `marginMs` of the chain lies after the target. */
export function canSeekInChain(chain, targetMs, { marginMs = 700 } = {}) {
  return targetMs >= chain.startMs && chain.endMs - targetMs >= marginMs;
}

/** The held part that contains `ms`, with the chain that has the most data after it. */
export function findChainPart(chains, ms) {
  let best = null;
  for (const chain of chains) {
    for (const part of chain.parts) {
      if (part.start <= ms && ms < part.end && (!best || chain.endMs > best.chain.endMs)) best = { chain, part };
    }
  }
  return best;
}

/** The last key part of `chain` that starts at or before `ms`. */
export function governingKey(chain, ms) {
  let found = chain.parts[0];
  for (const part of chain.parts) {
    if (part.start > ms) break;
    if (part.key) found = part;
  }
  return found;
}

/**
 * What a key step (a drag) can do without a request. `hints` maps a chain's head id to { fromMs, toMs }: a keyframe answer for a target inside
 * that range showed this head, and the whole range is in the same GOP.
 *   { kind: 'held', part, atMs }   seek to atMs (inside `part`), no request
 *   { kind: 'fetch' }              ask the server for the key fragment
 */
export function keyStepLookup(chains, hints, targetMs, { marginMs = 700 } = {}) {
  const hit = findChainPart(chains, targetMs);
  if (hit) {
    if (canSeekInChain(hit.chain, targetMs, { marginMs })) return { kind: 'held', part: hit.part, atMs: targetMs };
    const key = governingKey(hit.chain, targetMs);
    if (canSeekInChain(hit.chain, key.start + 1, { marginMs })) return { kind: 'held', part: key, atMs: key.start + 1 };
  }
  for (const chain of chains) {
    const hint = hints.get(chain.headId);
    const head = chain.parts[0];
    if (hint && targetMs >= hint.fromMs && targetMs <= hint.toMs && canSeekInChain(chain, head.start + 1, { marginMs })) {
      return { kind: 'held', part: head, atMs: head.start + 1 };
    }
  }
  return { kind: 'fetch' };
}

/**
 * Which parts of `plan` (a found answer of fragments?at=) to fetch, given the chains already held.
 *   fetch   the parts to append, in order
 *   coarse  the lead-in is too large (or the GOP too long for the server's list): show the key picture only
 *   extend  the chain the first fetched part continues, or null when it starts a new chain (it is then a key part)
 * A chain can be continued only while its tail is the part appended last (`lastAppendedId`): MSE drops delta frames that follow a jump,
 * so after appending anywhere else the chain's next part is not appendable and the GOP starts over from its key part.
 */
export function nextFetches(plan, chains, { maxBytes = Infinity, lastAppendedId = null } = {}) {
  const none = { fetch: [], coarse: false, extend: null };
  if (!plan || plan.found !== true || !plan.parts || plan.parts.length === 0) return none;
  const parts = plan.parts;
  const target = Math.min(Math.max(plan.targetIndex ?? 0, 0), parts.length - 1);

  // The chain that already holds the most of the plan from its start (the one appended last wins a tie), and what can be done with it.
  let heldCount = 0;
  let extend = null;
  const keeper = lastChain(chains, lastAppendedId);
  const holders = chains
    .filter((chain) => chain.parts.some((part) => part.id === parts[0].id))
    .map((chain) => {
      const at = chain.parts.findIndex((part) => part.id === parts[0].id);
      let count = 0;
      while (count < parts.length && chain.parts[at + count]?.id === parts[count].id) count += 1;
      return { chain, at, count, last: chain === keeper };
    })
    .sort((a, b) => b.count - a.count || Number(b.last) - Number(a.last));
  if (holders.length > 0) {
    const { chain: holder, at, count, last } = holders[0];
    heldCount = count;
    if (heldCount < parts.length) {
      const chainContinues = at + heldCount < holder.parts.length;       // the chain goes on with parts that are not the plan's
      if (chainContinues) heldCount = 0;                                // start over from the key part, as a new chain
      else if (last && follows(holder, parts[heldCount])) extend = holder;       // append to the tail
      else if (!parts[heldCount].key) heldCount = 0;                    // the next part cannot start a chain: start over from the key part
    }
  }

  const needed = parts.slice(heldCount);
  const leadBytes = needed.filter((part, index) => heldCount + index <= target).reduce((sum, part) => sum + (part.bytes || 0), 0);
  const coarse = plan.exact === false || leadBytes > maxBytes;
  if (coarse) return { fetch: heldCount === 0 ? [parts[0]] : [], coarse: true, extend: null };
  return { fetch: needed, coarse: false, extend: needed.length > 0 ? extend : null };
}

/**
 * Drops a chain whose parts another chain holds in full (when the other is longer, or is the one appended last, or comes first when they are
 * equal). The chain that ends with `keepTailId`, the part appended last, is never dropped: it is the only one that can be continued.
 */
export function dedupeChains(chains, keepTailId = null) {
  const covers = (other, chain) => chain.parts.every((part) => other.parts.some((candidate) => candidate.id === part.id));
  const keeper = lastChain(chains, keepTailId);
  return chains.filter((chain, index) => {
    if (chain === keeper) return true;
    return !chains.some((other, otherIndex) => other !== chain && covers(other, chain)
      && (other.parts.length > chain.parts.length || other === keeper || otherIndex < index));
  });
}

/** The chain that ends with the part appended last: the newest of the chains with that tail. Null when there is none. */
export function lastChain(chains, lastAppendedId) {
  if (lastAppendedId === null || lastAppendedId === undefined) return null;
  for (let i = chains.length - 1; i >= 0; i -= 1) if (chains[i].tailId === lastAppendedId) return chains[i];
  return null;
}

// MARK: What the video element holds

const EDGE_SLACK_SEC = 0.25;          // the most a buffered range may miss of a span at either edge and still hold it (the surface's HOLD_BACK_SEC)
const ROUNDING_SEC = 0.005;
const AT_EDGE_SEC = 0.003;

/**
 * True when `range` (buffer seconds) holds the span startSec..endSec. With sound a buffered range is where the picture and the sound both have
 * data, and a part's sound can start or end up to a frame inside its picture (64 ms for 16 kHz AAC), so the edges get some slack: a quarter of
 * a second, however short the span (a file break can leave a last part of 150 ms). The range must also reach into the span by more than
 * rounding: a span that was removed leaves ranges that end where it starts or start where it ends, so it is never taken for held.
 */
export function rangeHolds(range, startSec, endSec, { slackSec = EDGE_SLACK_SEC } = {}) {
  const inside = Math.min(ROUNDING_SEC, (endSec - startSec) / 2);
  return range.start <= Math.min(startSec + slackSec, endSec - inside) && range.end >= Math.max(endSec - slackSec, startSec + inside);
}

/** The held range (buffer seconds) that `sec` lies in, its ends included (a playhead stands at the very end of what it played), or null. */
export function heldRangeAt(ranges, sec) {
  return ranges.find((range) => range.start - AT_EDGE_SEC <= sec && sec <= range.end + AT_EDGE_SEC) ?? null;
}

/**
 * A hole in what the video holds right after the range that `sec` lies in: the next held range, when it begins less than `maxHoleSec` after that
 * range ends and is at least `minSec` long (a seek needs the decoders' hold-back after it). Null when there is none. Buffer seconds.
 */
export function rangeAfterHole(ranges, sec, { maxHoleSec, minSec }) {
  const here = heldRangeAt(ranges, sec);
  if (!here) return null;
  let next = null;
  for (const range of ranges) {
    if (range.start > here.end + AT_EDGE_SEC && range.start - here.end < maxHoleSec && (!next || range.start < next.start)) next = range;
  }
  return next && next.end - next.start >= minSec ? next : null;
}

/**
 * Keeps only what the video element still holds. `heldRanges` are buffer seconds. A chain survives as the longest prefix of its parts that are
 * each held (see rangeHolds; consecutive parts of a chain that are held lie at most two slacks apart, as where the sound or the first picture of
 * the next file starts a little late); a chain whose first part is gone is dropped (its later parts could not be decoded).
 */
export function reconcileChains(chains, heldRanges, baseMs, { slackSec = EDGE_SLACK_SEC } = {}) {
  const survivors = [];
  const held = (part) => heldRanges.some((range) => rangeHolds(range, bufferSeconds(part.start, baseMs), bufferSeconds(part.end, baseMs), { slackSec }));
  for (const chain of chains) {
    let keep = 0;
    while (keep < chain.parts.length && held(chain.parts[keep])) keep += 1;
    if (keep === 0) continue;
    if (keep === chain.parts.length) { survivors.push(chain); continue; }
    const parts = chain.parts.slice(0, keep);
    survivors.push({ headId: chain.headId, tailId: parts[parts.length - 1].id, fileKey: chain.fileKey, parts, startMs: parts[0].start, endMs: parts[parts.length - 1].end });
  }
  return survivors;
}

// MARK: Memory

/**
 * Decides what to remove so that at most `budgetBytes` stay. `ledger` entries are { startSec, endSec, bytes, key } in buffer seconds, one per
 * append. Removal is by GOP unit (a key entry and the entries that continue it), farthest from `keepAroundSec` first, and never the unit that
 * contains `keepAroundSec`. Returns { remove: [{ startSec, endSec, bytes, entries }], keptBytes }.
 */
export function planEviction(ledger, keepAroundSec, budgetBytes) {
  const entries = [...ledger].sort((a, b) => a.startSec - b.startSec || a.endSec - b.endSec);
  const units = [];
  for (const entry of entries) {
    const last = units[units.length - 1];
    if (last && !entry.key && Math.abs(entry.startSec - last.endSec) <= 0.005) {
      last.entries.push(entry);
      last.endSec = Math.max(last.endSec, entry.endSec);
      last.bytes += entry.bytes;
    } else {
      units.push({ entries: [entry], startSec: entry.startSec, endSec: entry.endSec, bytes: entry.bytes });
    }
  }
  let kept = units.reduce((sum, unit) => sum + unit.bytes, 0);
  const distance = (unit) => (keepAroundSec >= unit.startSec && keepAroundSec < unit.endSec
    ? 0
    : Math.min(Math.abs(keepAroundSec - unit.startSec), Math.abs(keepAroundSec - unit.endSec)));
  const candidates = units.filter((unit) => distance(unit) > 0).sort((a, b) => distance(b) - distance(a));
  const remove = [];
  for (const unit of candidates) {
    if (kept <= budgetBytes) break;
    remove.push(unit);
    kept -= unit.bytes;
  }
  return { remove: remove.map(({ startSec, endSec, bytes, entries: list }) => ({ startSec, endSec, bytes, entries: list })), keptBytes: kept };
}

// MARK: What this browser can do

export function unsupportedMessage(mime) {
  return /hvc1|hev1|hevc/i.test(String(mime)) ? MESSAGES.cannotPlayHEVC : MESSAGES.cannotPlay;
}

/** 'chromium' | 'safari' | 'firefox' | 'ipad' | 'iphone' | 'other'. Chrome and Firefox on iOS are WebKit, so they are 'iphone' or 'ipad'. */
export function browserClass({ userAgent = '', maxTouchPoints = 0 } = {}) {
  const ua = String(userAgent);
  if (/iPad/.test(ua) || (/Macintosh/.test(ua) && maxTouchPoints > 1)) return 'ipad';
  if (/iPhone|iPod/.test(ua)) return 'iphone';
  if (/Firefox\//.test(ua)) return 'firefox';
  if (/Chrome\/|Chromium\/|Edg\//.test(ua)) return 'chromium';
  if (/Safari\//.test(ua)) return 'safari';
  return 'other';
}

/**
 * What each browser class is allowed to do. The values are the decision of the browser spike (task T06: linux/web-dev/spike/DECISION.json and RESULTS.md,
 * decided 2026-10-11 from one device run, Chrome on a Mac). Where a class has no run the spike's rule applies: key steps off, the addendum's tile cap.
 *   play            false: recordings are not offered in this class at all (the page says so and keeps the snapshot)
 *   keySteps        a drag shows key pictures (false: the picture arrives after the pointer stops)
 *   mimeChange      'recreate' builds a new MediaSource when the codec string changes, 'changeType' keeps the buffer and calls changeType()
 *   maxTiles        the most tiles one page may decode (a session clamps its tileCap to it)
 *   initAfterBreak  append the file's init segment again after every abort() and the new offset (T06's jump protocol abort + offset + init)
 * Chromium's cap was 1 (the spike's rule after a run on a busy Mac); on 2026-10-14 Chrome on an Apple-silicon Mac played five recordings of the
 * owner's cameras at once (two 4256×1888, 3632×1632, 2688×1520, 2560×1920) at their full 20 fps with no dropped frames, so it is 9 (a 3 × 3 grid).
 * The iPhone is off because no iPhone run exists; it is one word to switch it on. `holdCanvas` (false for Chrome in the spike) is not a field here:
 * the screen decides whether to build the canvas, and a canvas that is not needed costs nothing.
 */
export const POLICY_TABLE = Object.freeze({
  chromium: Object.freeze({ play: true, keySteps: true, mimeChange: 'recreate', maxTiles: 9, initAfterBreak: true }),
  safari: Object.freeze({ play: true, keySteps: false, mimeChange: 'recreate', maxTiles: 4, initAfterBreak: true }),
  firefox: Object.freeze({ play: true, keySteps: false, mimeChange: 'recreate', maxTiles: 4, initAfterBreak: true }),
  ipad: Object.freeze({ play: true, keySteps: false, mimeChange: 'recreate', maxTiles: 4, initAfterBreak: true }),
  iphone: Object.freeze({ play: false, keySteps: false, mimeChange: 'recreate', maxTiles: 2, initAfterBreak: true }),
  other: Object.freeze({ play: true, keySteps: false, mimeChange: 'recreate', maxTiles: 4, initAfterBreak: true }),
});

/**
 * What a cell or a surface uses when its caller passes no policy, and what the tests start from. The protocol fields come from the Chromium row (the spike
 * chose the same ones for every class). `maxTiles` is 9, the most a session ever has: only a session reads it, and a session chooses its own policy.
 */
export const DEFAULT_POLICY = Object.freeze({ ...POLICY_TABLE.chromium, maxTiles: 9, browser: 'chromium', mediaSource: 'MediaSource', canPlay: true, reason: null });

/** env = { userAgent, maxTouchPoints, hasMediaSource, hasManagedMediaSource }; see currentEnvironment(). `table` is for tests. */
export function choosePolicy(env = {}, table = POLICY_TABLE) {
  const browser = browserClass(env);
  const entry = table[browser];
  const mediaSource = env.hasMediaSource ? 'MediaSource' : env.hasManagedMediaSource ? 'ManagedMediaSource' : null;
  let reason = null;
  if (!mediaSource) reason = browser === 'iphone' ? MESSAGES.needsNewerIOS : MESSAGES.noMediaSource;
  else if (!entry.play) reason = browser === 'iphone' ? MESSAGES.noIPhone : MESSAGES.noMediaSource;
  return Object.freeze({ ...entry, browser, mediaSource, canPlay: mediaSource !== null && entry.play, reason });
}

export function currentEnvironment(scope = globalThis) {
  const nav = scope.navigator || {};
  return {
    userAgent: nav.userAgent || '',
    maxTouchPoints: nav.maxTouchPoints || 0,
    hasMediaSource: typeof scope.MediaSource !== 'undefined',
    hasManagedMediaSource: typeof scope.ManagedMediaSource !== 'undefined',
  };
}

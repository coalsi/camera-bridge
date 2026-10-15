// Smoke stand-in for T08's js/nvr/catalog.js: three days of footage with one 20 minute gap two hours ago, and an activity answer with bursts.
// While started it asks the smoke server for GET nvr/cameras once a second, like the real catalog, so a 401 reaches the page's sign-out.
import { get } from '../api.js';

const DAY = 86_400_000;
export const SMOKE = { typicalGOP: 2, gapStartOffsetMs: 2 * 3_600_000, gapLengthMs: 20 * 60_000 };
export function createCatalog() {
  const listeners = new Set();
  let running = 0;
  let poll = null;
  const gap = () => { const from = Date.now() - SMOKE.gapStartOffsetMs; return { from, to: from + SMOKE.gapLengthMs }; };
  const bornGap = gap();
  const catalog = {
    baseMs: Date.now() - 400 * DAY,
    version: 1,
    serverNow: () => Date.now(),
    start() {
      running += 1;
      setTimeout(() => listeners.forEach((fn) => fn({ kind: 'extents' })), 50);
      if (!poll) poll = setInterval(() => { get('nvr/cameras').catch(() => {}); }, 1000);
    },
    stop() { running -= 1; if (running <= 0) { clearInterval(poll); poll = null; } },
    get running() { return running; },
    extent: () => ({ oldest: Date.now() - 3 * DAY, newest: Date.now() - 1500, typicalGOP: SMOKE.typicalGOP }),
    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    async activity({ cameras, fromMs, binMs, bins }) {
      const coverage = [];
      const level = [];
      for (let i = 0; i < bins; i += 1) {
        const start = fromMs + i * binMs;
        const inGap = start + binMs > bornGap.from && start < bornGap.to;
        coverage.push(inGap ? 0 : 100);
        const burst = Math.floor(start / 600_000) % 7 === 0 ? 5 : 1;
        level.push(inGap ? 0 : Math.round((1500 + 800 * Math.sin(start / 900_000)) * burst));
      }
      return { from: fromMs, binMs, bins, serverTime: Date.now(), catalogVersion: 1, byCamera: { [cameras[0]]: { typical: 2000, complete: true, coverage, level } } };
    },
  };
  window.__gap = bornGap;
  return catalog;
}

// Fake time shared by the NVR grid tests. A timer set by a timer that runs inside the same `advance` runs too.

export function fakeTime(start = 1_000) {
  let now = start;
  let nextId = 1;
  const timers = new Map();   // id -> { at, fn }
  return {
    now: () => now,
    setTimer(fn, ms) {
      const id = nextId++;
      timers.set(id, { at: now + ms, fn });
      return id;
    },
    clearTimer(id) { timers.delete(id); },
    advance(ms) {
      const end = now + ms;
      for (;;) {
        let due = null;
        for (const [id, timer] of timers) {
          if (timer.at <= end && (due === null || timer.at < timers.get(due).at)) due = id;
        }
        if (due === null) break;
        const timer = timers.get(due);
        timers.delete(due);
        now = Math.max(now, timer.at);
        timer.fn();
      }
      now = end;
    },
    pendingTimers: () => timers.size,
  };
}

/** Lets resolved promises run their continuations. */
export async function settle() {
  for (let i = 0; i < 10; i += 1) await Promise.resolve();
}

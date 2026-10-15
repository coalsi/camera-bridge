// A deterministic clock for the NVR modules: a timer fires only when a test advances time, and every promise chain settles in between.

export function createFakeTimers({ start = 0 } = {}) {
  let current = start;
  let sequence = 0;
  let tasks = [];

  const timers = {
    /** The monotonic reading the modules call `perf()` / `now()`. */
    now: () => current,
    setTimeout(fn, ms = 0) {
      const id = ++sequence;
      tasks.push({ id, at: current + Math.max(0, Number(ms) || 0), fn });
      return id;
    },
    clearTimeout(id) {
      tasks = tasks.filter((task) => task.id !== id);
    },
    sleep(ms) {
      return new Promise((resolve) => timers.setTimeout(resolve, ms));
    },
    pending: () => tasks.length,
    /** Let every promise continuation that can run, run. */
    settle: () => new Promise((resolve) => setImmediate(resolve)),
    /** Move time forward by `ms`, firing timers in order and settling after each. */
    async advance(ms) {
      const end = current + ms;
      await timers.settle();
      for (;;) {
        const due = tasks.filter((task) => task.at <= end).sort((a, b) => a.at - b.at || a.id - b.id)[0];
        if (!due) break;
        tasks = tasks.filter((task) => task !== due);
        current = Math.max(current, due.at);
        due.fn();
        await timers.settle();
      }
      current = end;
      await timers.settle();
    },
    /** Advance until no timer is left or `limitMs` has passed. */
    async idle(limitMs = 600000) {
      const end = current + limitMs;
      await timers.settle();
      while (tasks.length && current < end) {
        const next = Math.min(...tasks.map((task) => task.at));
        await timers.advance(Math.max(0, Math.min(next, end) - current));
      }
    },
  };
  return timers;
}

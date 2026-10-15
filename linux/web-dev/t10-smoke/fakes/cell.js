// Smoke stand-in for T08's js/nvr/cell.js: a cell whose coverage the fake session sets.
export function createCell(options) {
  const listeners = new Set();
  const cell = {
    options,
    coverage: { kind: 'idle', next: null, message: null },
    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    set(kind, extra = {}) { cell.coverage = { kind, next: null, message: null, ...extra }; listeners.forEach((fn) => fn()); },
    destroy() {},
  };
  return cell;
}

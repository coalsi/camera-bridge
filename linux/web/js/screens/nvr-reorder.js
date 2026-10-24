// Moving the Monitor's tiles: drag one onto another's place (mouse, pen, or a press and hold on touch so scrolling still works), or Alt plus
// the arrow keys on a focused tile. This only finds out what the person did and calls back; nvr.js saves the order. No globals: the DOM is
// handed in, so Node tests drive it with plain objects.

export const MOVE_PX = 6;       // a mouse drag starts after this much movement
export const HOLD_MS = 350;     // a touch drag starts after this long a press that has not moved
export const HOLD_SLOP = 10;    // a touch that moves more than this before the hold is a scroll

const ARROWS = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 };
const CONTROLS = 'button, select, input, textarea';

/**
 * grid          the element the tiles are in
 * tileId(node)  the id of the tile a node is in, or null
 * targetAt(x, y) the id of the tile under a point, or null
 * mark(id, kind) shows a tile as 'dragging', as the 'drop' place, or plainly (kind null)
 * enabled()     false while the wall cannot be reordered (one camera on its own, choosing a clip)
 * commit(id, targetId)   the tile `id` was dropped on `targetId`'s place
 * step(id, delta)        Alt + arrow: moves `id` by `delta` places and returns what to announce
 * announce(text)         tells screen readers
 * -> stop()
 */
export function attachReorder(grid, { tileId, targetAt, mark, enabled = () => true, commit, step, announce = () => {}, setTimer = setTimeout, clearTimer = clearTimeout }) {
  let drag = null;          // { id, pointerId, x, y, touch, active, over, hold }
  let swallowClick = false;

  function end() {
    if (!drag) return;
    clearTimer(drag.hold);
    if (drag.active) { mark(drag.id, null); if (drag.over) mark(drag.over, null); }
    try { grid.releasePointerCapture?.(drag.pointerId); } catch { /* not captured */ }
    drag = null;
  }

  function begin() {
    drag.active = true;
    mark(drag.id, 'dragging');
    try { grid.setPointerCapture?.(drag.pointerId); } catch { /* the pointer is gone */ }
  }

  function onDown(event) {
    if (drag) end();
    if (!enabled() || event.isPrimary === false || (event.pointerType === 'mouse' && event.button !== 0)) return;
    if (event.target?.closest?.(CONTROLS)) return;
    const id = tileId(event.target);
    if (!id) return;
    const touch = event.pointerType === 'touch';
    drag = { id, pointerId: event.pointerId, x: event.clientX, y: event.clientY, touch, active: false, over: null, hold: null };
    if (touch) drag.hold = setTimer(() => { if (drag?.id === id) begin(); }, HOLD_MS);
  }

  function onMove(event) {
    if (!drag || event.pointerId !== drag.pointerId) return;
    if (!drag.active) {
      const far = Math.hypot(event.clientX - drag.x, event.clientY - drag.y);
      if (drag.touch) { if (far > HOLD_SLOP) end(); return; }   // moved before the hold: the person is scrolling
      if (far < MOVE_PX) return;
      begin();
    }
    event.preventDefault?.();
    const over = targetAt(event.clientX, event.clientY);
    const next = over && over !== drag.id ? over : null;
    if (next !== drag.over) {
      if (drag.over) mark(drag.over, null);
      if (next) mark(next, 'drop');
      drag.over = next;
    }
  }

  function onUp(event) {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const done = drag;
    const dropped = done.active;
    end();
    if (!dropped) return;
    swallowClick = true;                                  // the click that ends a drag must not open the camera or fill the wall
    setTimer(() => { swallowClick = false; }, 60);
    if (done.over) commit(done.id, done.over);
  }

  const onCancel = (event) => { if (drag && event.pointerId === drag.pointerId) end(); };
  const onClick = (event) => { if (swallowClick) { swallowClick = false; event.preventDefault(); event.stopPropagation(); } };
  // Once a touch drag is on, the page must not scroll with it.
  const onTouchMove = (event) => { if (drag?.active) event.preventDefault(); };
  const onMenu = (event) => { if (drag?.touch) event.preventDefault(); };   // a long press opens the browser's menu

  function onKey(event) {
    if (drag?.active && event.key === 'Escape') { event.stopPropagation(); end(); return; }
    if (!event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || !(event.key in ARROWS) || !enabled()) return;
    const id = tileId(event.target);
    if (!id) return;
    event.preventDefault();      // Alt + Left is "back" in some browsers
    event.stopPropagation();
    const text = step(id, ARROWS[event.key]);
    if (text) announce(text);
  }

  const listeners = [
    ['pointerdown', onDown], ['pointermove', onMove], ['pointerup', onUp], ['pointercancel', onCancel], ['click', onClick, true],
    ['touchmove', onTouchMove, { passive: false }], ['contextmenu', onMenu], ['keydown', onKey, true],
  ];
  for (const [type, fn, options] of listeners) grid.addEventListener(type, fn, options);
  return function stop() {
    end();
    for (const [type, fn, options] of listeners) grid.removeEventListener(type, fn, options);
  };
}

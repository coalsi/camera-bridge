// The wall display: this browser is a screen that stays on the Monitor with nobody at it (a switch in the Monitor's menu, kept in this browser
// only: localStorage cb.monitor.wall). While it is on, the Monitor keeps the screen awake and hides its controls until the pointer moves, and this
// browser takes no notification toasts: the bridge hands each notice to one browser (POST notifications/shown), and a wall would swallow the
// ones the owner's phone or laptop should show. A wall also comes back by itself after a power cut (app.js) and reloads when idle after an
// update (the Monitor), as every browser does.

export const WALL_KEY = 'cb.monitor.wall';

/** Whether this browser is a wall display (false when storage is blocked). */
export function wallMode() {
  try { return localStorage.getItem(WALL_KEY) === '1'; } catch { return false; }
}

/** Makes this browser a wall display, or not; false when it could not be kept (storage blocked: it then lasts until the page closes). */
export function setWallMode(on) {
  try {
    if (on) localStorage.setItem(WALL_KEY, '1'); else localStorage.removeItem(WALL_KEY);
    return true;
  } catch { return false; }
}

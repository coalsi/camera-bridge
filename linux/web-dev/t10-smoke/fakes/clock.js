// Smoke stand-in for T08's js/nvr/clock.js.
export const LIVE_BEHIND_MS = 6000;
export const LIVE_SNAP_MS = 5000;
export class PlaybackClock {
  constructor({ serverNow }) { this.serverNow = serverNow; }
}

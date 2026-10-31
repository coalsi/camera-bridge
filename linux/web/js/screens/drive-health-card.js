// The Box health card of the System page: the drives' health (Camera Bridge OS checks them every day: SMART, an SSD's wear, the errors their file
// systems recorded), whether the clock follows a time server, and a network cable that came up slower than a gigabit. All three come with
// GET system (`driveHealth`, `clock`, `networkLink`); the card is left out where the system reports none of them (a plain program).
import { h } from '../dom.js';
import { icon } from '../icons.js';
import { timeAgo } from '../format.js';

/** What each drive is, in the page's words. */
export const DRIVE_ROLES = { system: 'This box’s disk', recording: 'Recording drive', archive: 'Archive drive' };

/** A drive's state as a pill: its class and its word. */
export const DRIVE_STATES = {
  ok: ['live', 'Healthy'],
  warning: ['warning', 'Needs attention'],
  failing: ['offline', 'Failing'],
  unknown: ['idle', 'Not reported'],
};

/** The sentence for a cable below 1 Gb/s (a bad cable or switch port), or null. */
export function slowLinkWarning(link) {
  if (!link?.wired || typeof link.speedMbps !== 'number' || link.speedMbps >= 1000) return null;
  return `The network cable is connected at ${link.speedMbps} Mb/s instead of 1 Gb/s. Try another cable or switch port: with many cameras the box can run out of room.`;
}

/** The clock in one line: synced with a time server or not. */
export function clockLine(clock, now = Date.now()) {
  if (!clock) return null;
  if (clock.synchronized) {
    const from = clock.source ? ` with ${clock.source}` : '';
    const when = clock.lastSync ? `, checked ${timeAgo(clock.lastSync, now)}` : '';
    return `The clock is in sync${from}${when}.`;
  }
  return 'The clock is not in sync with a time server: the box keeps its own time, so recordings and cameras may drift. Check that the box can reach the internet.';
}

/** One drive's details in a few words: the wear, the temperature, the hours it has run. */
export function driveFacts(drive) {
  const facts = [];
  if (typeof drive.percentUsed === 'number') facts.push(`${drive.percentUsed}% of its rated life used`);
  if (typeof drive.temperatureCelsius === 'number') facts.push(`${drive.temperatureCelsius} °C`);
  if (typeof drive.powerOnHours === 'number') facts.push(`${Math.round(drive.powerOnHours / 24).toLocaleString()} days powered on`);
  return facts.join(' · ');
}

/** The card for GET system's answer `info`, or null when the system reports neither drives, clock nor link. */
export function driveHealthCardFor(info, { now = Date.now() } = {}) {
  const health = info?.driveHealth || null;
  const clock = clockLine(info?.clock, now);
  const slow = slowLinkWarning(info?.networkLink);
  if (!health && !clock && !slow) return null;
  const drives = health?.drives || [];
  return h('div', { class: 'card' }, h('h2', null, 'Box health'),
    h('p', { class: 'desc' }, 'The box checks its drives every day and warns before one wears out, so recordings are not lost to a failing disk.'),
    slow ? h('div', { class: 'banner warning', role: 'status' }, icon('alert'), h('div', { class: 'text' }, slow)) : null,
    drives.length ? h('dl', { class: 'kv' }, drives.flatMap((drive) => {
      const [kind, word] = DRIVE_STATES[drive.state] || DRIVE_STATES.unknown;
      const facts = driveFacts(drive);
      return [h('dt', null, DRIVE_ROLES[drive.role] || drive.role),
        h('dd', null, h('span', { class: `pill ${kind}` }, word), drive.model ? ` ${drive.model}` : '',
          drive.state === 'ok' ? null : h('div', { class: 'small' }, drive.message),
          facts ? h('div', { class: 'small muted' }, facts) : null)];
    })) : health ? h('p', { class: 'muted' }, health.message) : null,
    health?.checked ? h('p', { class: 'small muted' }, `Drives checked ${timeAgo(health.checked, now)}.`) : null,
    clock ? h('p', { class: info.clock.synchronized ? 'muted' : 'problems' }, clock) : null);
}

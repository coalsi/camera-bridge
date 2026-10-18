// What changed in Camera Bridge OS, newest first. The About page (screens/about.js) shows it, and after an update the page says once what is
// new (js/whats-new.js). The file ships inside the system, so a bridge always has the notes of the version it runs.
//
// Until 1.0 there is one product, "Camera Bridge OS beta", updated often but at most one beta a day. Each beta still has its own build
// number (a box needs it to see an update, and it is in the signatures and in bug reports), so each build still gets its own entry here.
// The page shows the beta as one list grouped by day (the date as the heading, each entry's title in bold, its build number small beside
// it), and after an update the notice names every entry since the build the person last saw.
//
// Releasing: add an entry at the top whose `version` is the build number, the os-v tag without "os-v" (os-v0.1.109 -> '0.1.109'), with
// the date, a title and a few plain lines about what an owner notices. Write for the person using the bridge, not for developers. The
// release workflow puts the same lines in the GitHub release. From 1.0 (a version that does not start with "0.") the page shows each
// version on its own again, by number, with no change here; the beta's days follow them.
//
// The release workflow imports this file on its own (notesFor), so it imports nothing.

export const RELEASE_NOTES = [
  {
    version: '0.1.110',
    date: '2026-10-18',
    title: 'Cameras start sooner after a restart',
    items: [
      'A box on Wi-Fi starts its cameras about 20 seconds sooner after a restart: it no longer waits out a network cable that is not plugged in. A camera network without a router counts as a network too.',
      'The box no longer reports itself as degraded because of system services it does not use.',
      'Wyze: Refresh on the Plugins page always looks at the cameras again. Right after signing in it could show the answer from a moment before (for example RTSP still on after you turned it off).',
    ],
  },
  {
    version: '0.1.109',
    date: '2026-10-17',
    title: 'Security badges, the Internet guard, and a better Monitor',
    items: [
      'Every camera gets a security badge on the Cameras page, its own page and the Monitor: gold (local only), green (good), yellow (needs work) or red (outside access possible), with what Camera Bridge found and how to fix it.',
      'Internet guard: Set up for Camera Bridge can now watch a camera’s internet. Camera Bridge OS answers the camera’s internet lookups itself, blocks every one, and shows what the camera tried to reach. A camera watched for a full day with nothing on earns gold.',
      'Cameras that need their maker’s cloud (Wyze, eufy, Ring, Nest, Tuya, Tapo, Blink, Arlo, SimpliSafe) are marked red, and the router help shows how to keep a camera off the internet.',
      'Recorded video plays through the gaps in a camera’s recording instead of freezing, and the Monitor no longer loses contact while scrubbing.',
      'The Monitor fills the whole window with no scrolling, has a Mosaic layout that keeps each camera’s shape, a Fill option with no black bars, and 4 × 3 and 4 × 4 grids that keep their shape. Full quality is the default.',
      'Night vision: switch between Auto, Night (IR on) and Day (IR off), and turn the IR lights on or off, from the camera’s page, the Monitor and Apple Home. Jennov and similar cameras use their own settings for it.',
      'Battery cameras show their charge and whether they are charging from solar or a cable. Camera events are kept with the recordings, so the Monitor’s events list covers the whole timeline.',
      'Set up for Camera Bridge checks the video the camera really sends (a camera that says H.264 but sends H.265 is fixed), turns off more cameras’ clouds, and can require a password for video on cameras that play it without one.',
      'The OS beta is one product now: About shows “Camera Bridge OS beta” with the build, and what changed by day.',
      'Fixed: after a factory reset, SSH could stay on until the next restart.',
      'Fixed: the bridge could stop if writing to the system log failed. If it ever stops unexpectedly, the log now says where, for a bug report.',
    ],
  },
  {
    version: '0.1.108',
    date: '2026-10-16',
    title: 'Set up for Camera Bridge',
    items: [
      'Set up for Camera Bridge: one button on a camera’s page (and offered right after adding one) that makes the camera right for the bridge. It shows every change first, saves a backup, applies, reads each setting back, and Restore original settings puts it all back.',
      'It tunes the streams for recording, Apple Home and live view, turns off the camera’s own labels, sets the bridge’s time zone and takes the time from the bridge, and turns off the camera maker’s cloud (Hik-Connect) and UPnP where the camera has them.',
      'Camera Bridge OS keeps time for your cameras, so they keep the right time with no internet.',
      '4K cameras may keep up to 8 Mbit/s on their main stream (6 for smaller ones), so recordings keep their detail.',
      'Fixed: a Tapo’s snapshot (JPEG) stream could be taken for its sub stream when changing stream settings.',
    ],
  },
  {
    version: '0.1.107',
    date: '2026-10-16',
    title: 'Pan, tilt and zoom for ONVIF cameras',
    items: [
      'ONVIF cameras that pan, tilt or zoom get the pad on the Monitor: open the camera on its own and the pad sits beside the events. Camera Bridge asks each camera what it can do, so only cameras that move show it.',
      'One tap moves the camera one step and stops; hold an arrow to keep stepping. Nothing leaves a camera turning, so a cable never winds up.',
      'Zoom in and out (+ and −) for cameras with a zoom lens.',
    ],
  },
  {
    version: '0.1.106',
    date: '2026-10-16',
    title: 'A new logo, and a steadier start',
    items: [
      'The new Camera Bridge logo: a camera lens with the Golden Gate in its real colours through the glass.',
      'Plugins that use a camera maker’s cloud (Wyze, eufy) say so with a “Needs internet” badge and what goes through the cloud.',
      'Fixed: the bridge could stop once while starting with a eufy or Wyze camera (it started again by itself).',
    ],
  },
  {
    version: '0.1.105',
    date: '2026-10-16',
    title: 'Plugins: Wyze and eufy, battery cameras, pan and tilt, and a new look',
    items: [
      'Plugins: a new section for cameras that need their maker’s account. Sign in once, see your cameras, add them with one click.',
      'Wyze: sign in with two-step verification. Wyze Cam v4, v3 and Pan v3 come in over their own RTSP; the Wyze Cam Pan v4 comes in through Wyze’s cloud, with sound, and its pan and tilt.',
      'eufy: sign in (eufy may ask for a captcha and an emailed code) and add your eufy cameras, battery ones included, with motion and people from eufy’s notifications.',
      'Battery cameras sleep: they wake for a live view, an Apple Home recording or motion, and sleep again when nobody needs the picture. On the Monitor wall they show their latest picture until you open them.',
      'Pan and tilt: open a pan/tilt camera on its own on the Monitor, and a pad beside the events turns it. Hold an arrow to keep turning.',
      'Motion detection on 4K and HEVC cameras runs on the box’s graphics, using a fraction of the processor it did.',
      'A new logo, the Golden Gate seen through a lens, and the red of New England’s covered bridges.',
    ],
  },
  {
    version: '0.1.104',
    date: '2026-10-15',
    title: 'Apple Home records again',
    items: [
      'HomeKit Secure Video records on motion again: the box’s firewall blocked the connection the Home hub uses to collect recordings, so Apple Home showed live video but saved no clips.',
      'The system log keeps earlier boots: the box now has the same machine id on every start.',
    ],
  },
  {
    version: '0.1.103',
    date: '2026-10-15',
    title: 'Zoom into a camera',
    items: [
      'Zoom: with one camera on the wall, drag a box over the picture to zoom into it, or use the wheel or a pinch. Drag the rectangle on the overview to move; double-click or Esc shows the whole picture again.',
      'Enhance sharpens the zoomed picture on your computer’s graphics, so edges and small text come back.',
      'Each camera’s name is shown once, in its label with the date and time.',
    ],
  },
  {
    version: '0.1.102',
    date: '2026-10-15',
    title: 'Live video and sound, one Monitor, and a clean label on every camera',
    items: [
      'Live video for every camera in the browser, with smooth doorbell video.',
      'Sound: a speaker on each camera plays it live and from the recordings, and saved clips keep the sound.',
      'Monitor and recordings are one screen: the wall of cameras with the timeline, events and Save clip under it. Click a camera to fill the wall with it (its own timeline and clips).',
      'Cameras is a list to manage your cameras: names, status, Apple Home and recording at a glance.',
      'One label everywhere: the camera’s name and the date and time look the same on the Monitor, in Apple Home and burned into saved clips.',
      'Clean picture: turn off the clock and text a camera draws itself (Hikvision, Reolink, ONVIF), so only the bridge’s label shows.',
      'Time zone setting. The bridge sets each camera’s clock to it, daylight saving included.',
      'A menu down the left side, full-width pages, and Dark, Light or Auto appearance (Dark by default).',
      'Power off from the menu, and an About page with these notes.',
      'Updates: a box on a beta gets the next beta; after an automatic update it restarts at 3 AM in your time zone.',
      'Tuned for the Beelink Mini S (N150, 12 GB) as the smallest supported box.',
    ],
  },
  {
    version: '0.1.101',
    date: '2026-10-13',
    title: 'Wi-Fi, recording drives and saved clips',
    items: [
      'Wi-Fi: the bridge joins a saved network by itself, or opens a setup hotspot to choose one from a phone.',
      'Record to an attached USB or SATA drive.',
      'Save a clip of any recording from the web page.',
      'Bring your cameras over from the Camera Bridge Mac app.',
    ],
  },
];

/** -1, 0 or 1: how version `a` compares with `b` ("0.1.101" < "0.2.0"). */
export function compareVersions(a, b) {
  const pa = String(a).split('.').map((n) => Number.parseInt(n, 10) || 0);
  const pb = String(b).split('.').map((n) => Number.parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d) return d < 0 ? -1 : 1;
  }
  return 0;
}

/** The notes of `version` itself, if it has any. */
export function notesFor(version) {
  return RELEASE_NOTES.find((entry) => compareVersions(entry.version, version) === 0) ?? null;
}

/** True for a beta: a version before 1.0 ("0.1.108"). "1.0.0" and later are numbered releases. */
export function isBeta(version) {
  const major = String(version ?? '').split('.')[0];
  return /^\d+$/.test(major) && Number(major) === 0;
}

const newestFirst = (a, b) => compareVersions(b.version, a.version);

/** `notes` by the day they came out, newest day first: [{ date, entries }], each day's entries newest first. */
export function notesByDay(notes = RELEASE_NOTES) {
  const days = new Map();
  for (const entry of notes) {
    if (!days.has(entry.date)) days.set(entry.date, []);
    days.get(entry.date).push(entry);
  }
  return [...days].sort(([a], [b]) => (a < b ? 1 : a > b ? -1 : 0)).map(([date, entries]) => ({ date, entries: entries.sort(newestFirst) }));
}

/**
 * What is new to someone who last saw `seen` and now runs `version`: the entries after `seen` up to `version`, newest first. When `seen`
 * is not a version, or is older than every entry, only the newest one (a notice is not the whole history). Empty when nothing is new:
 * `seen` is `version` or later (after a rollback), or no entry is as old as `version`.
 */
export function notesSince(seen, version, notes = RELEASE_NOTES) {
  const upTo = notes.filter((entry) => compareVersions(entry.version, version) <= 0).sort(newestFirst);
  if (!/^\d+(\.\d+)*$/.test(String(seen ?? '').trim())) return upTo.slice(0, 1);
  const newer = upTo.filter((entry) => compareVersions(entry.version, seen) > 0);
  const olderThanAll = notes.every((entry) => compareVersions(entry.version, seen) > 0);
  return olderThanAll ? upTo.slice(0, 1) : newer;
}

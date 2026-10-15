// What changed in each version of Camera Bridge OS, newest first. The About page (screens/about.js) shows them, and after an update the
// page says once that there is something new. The file ships inside the system, so a bridge always has the notes of the version it runs.
//
// Releasing: add an entry at the top whose `version` is the os-v tag without "os-v" (os-v0.1.102 -> '0.1.102'), with the date and a few plain
// lines about what an owner notices. Write for the person using the bridge, not for developers. The release workflow puts the same lines in
// the GitHub release. Versions before 1.0 are betas.

export const RELEASE_NOTES = [
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

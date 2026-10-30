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
    version: '0.1.129',
    date: '2026-10-30',
    title: 'The right time on Apple Home’s video',
    items: [
      'The date and time Camera Bridge draws on a camera’s picture in Apple Home now follows the time zone set in Camera Bridge. Before, the box told it in UTC after every restart, so Home’s video could be hours off while Camera Bridge’s own pages were right.',
    ],
  },
  {
    version: '0.1.128',
    date: '2026-10-26',
    title: 'Sky Watcher: one object, not fifteen',
    items: [
      'A light that the camera loses for a moment (a plane’s strobe between flashes, a brief fade, the seam between two lenses) is joined back into one object when its pieces line up in time, direction and speed. Its card shows the whole path and how many parts it was seen in, and the dark gaps help tell a blinking plane.',
      'Lights logged earlier are joined the same way when you open the page; correcting a joined light corrects every part. Two planes that cross, and lights flying side by side, stay apart.',
    ],
  },
  {
    version: '0.1.127',
    date: '2026-10-26',
    title: 'Sky Watcher sorts what it sees, and ranks the unexplained',
    items: [
      'Rules tell lights apart before anything is called unexplained: blinking strobes are probable planes, steady straight lights are probable satellites, and meteors, bugs and birds are recognised. On a real night they agreed with a careful hand count 85 % of the time.',
      'Every unexplained light gets a priority (High, Medium or Low) with its reasons: several lights moving together, faster or larger than planes there, a sudden stop or a sharp turn. Filter by High priority, or sort by priority.',
      'Lights logged before this update are sorted by the same rules when you open the page.',
      'Probable planes and satellites keep a picture too, so you can check the rules by eye, and small pictures are made right away so the grid loads quickly.',
    ],
  },
  {
    version: '0.1.126',
    date: '2026-10-25',
    title: 'Sky Watcher matches planes, a grid you scroll, and a player you can zoom',
    items: [
      'Planes are matched from flight feeds in the older dump1090 format (heights as “altitude”), which many Raspberry Pi receivers send; before, none of their planes could be read. If a feed answers but its planes can’t be read, the Sky Watcher page now says so.',
      'A camera with two lenses starts its aim the way such a camera really looks, which lets the first planes match.',
      'The sky log is a grid you scroll through: filter by kind, show only lights with a picture, sort, and tap the night strip to jump to any hour. Correcting a light moves it to its kind at once. The cards load small pictures the box makes.',
      'The player can hide the marker, and zooms like the Monitor: drag a box, scroll to zoom, drag to move, double-click to fit. On the Monitor too, while zoomed in a drag now moves the picture and Shift-drag zooms further.',
    ],
  },
  {
    version: '0.1.125',
    date: '2026-10-25',
    title: 'An archive drive for older recordings',
    items: [
      'Add a second drive as an archive: the box keeps recording to its own disk, and when that fills, the oldest recordings move to the archive drive instead of being deleted. When the archive fills too, its oldest recordings go.',
      'Archived recordings play on the Monitor, in events, in saved clips and in Sky Watcher like any others. If the archive drive is unplugged, the box keeps recording and shows those hours as “on the archive drive (not connected)” until it is back.',
      'Moves are gentle (one file at a time, at low priority) and safe: each recording is copied and checked before the box lets go of its own copy. Set it up under Settings, Recording.',
    ],
  },
  {
    version: '0.1.124',
    date: '2026-10-25',
    title: 'Sky Watcher: close-ups, a player on the page, and a cleaner log',
    items: [
      'Each entry in the sky log shows a close-up of the object with its path drawn on it; tap it for the whole picture. Meteors and other explained lights show their picture too, and an unexplained light shows its note.',
      'Play any entry without leaving Sky Watcher: a player opens on the page with the recording from 15 seconds before to 15 seconds after (widen it to a minute or five), slow motion, a picture at a time, the light’s path over the video and a zoom for tiny lights.',
      'Every light that is logged keeps its picture, and pictures that could not be kept at the time are made later from the recordings.',
      'Spots that keep making lights (a tree top, a wire, a lamp, glare) are learned and only counted, the edge of the picture nearest the Sun is left out by day, and at most 200 unexplained lights are logged an hour, so one bad hour can’t bury a night.',
      '“Use this browser’s location” now works, and a steep camera with two lenses starts its aim with a level horizon.',
    ],
  },
  {
    version: '0.1.123',
    date: '2026-10-25',
    title: 'Sky Watcher keeps the lights that hold still',
    items: [
      'A bright light that rises, holds for a few seconds and fades on one spot is now kept in the sky log, however little it moves. Faint stars that only wobble in place are still left out.',
    ],
  },
  {
    version: '0.1.122',
    date: '2026-10-25',
    title: 'Sky Watcher: a log of what crosses your sky',
    items: [
      'A new plugin, Sky Watcher, for a camera pointed at the sky. It stays off until you switch it on in Plugins; then it gets its own page in the menu, and each camera’s settings get a Sky Watcher card.',
      'Every night (and day) it keeps a log of the lights that cross the sky: the night as a strip from sunset to sunrise, the unexplained ones first, each with a picture of its path, the time, the direction and how fast it crossed. Tap an entry to say what it really was.',
      'Planes are named from a flight receiver on your network (dump1090, readsb, tar1090 or PiAware): the Sky Watcher page can find it for you. It works without the internet; the box’s location stays on the box.',
      'A camera with two lenses stitched into one wide picture is treated as two lenses, and the box learns exactly where each one points from the planes it matches, starting from the direction you give it.',
      'Coming next: satellites, meteors and bugs, an alert for the truly strange, and the stars for a precise aim.',
    ],
  },
  {
    version: '0.1.121',
    date: '2026-10-25',
    title: 'Recordings that ride out a shaky network, and Wi-Fi on 5 GHz',
    items: [
      'A camera whose video arrives unevenly (a busy Wi-Fi, a few lost packets) no longer has its recording cut into many short files, and its sound converter keeps running. Only a real jump of the camera’s clock starts a new file. The log says when a camera’s video arrives unevenly.',
      'When your Wi-Fi offers 5 GHz with a good signal, the bridge moves to it (and back to it after a restart), so many cameras fit. The System page shows the band and warns on 2.4 GHz. An Ethernet cable is still best.',
    ],
  },
  {
    version: '0.1.120',
    date: '2026-10-24',
    title: 'Precise playback, time-lapse, and a clip range you can drag',
    items: [
      'Speeds in four groups: slow motion (¼×, ½×), normal, fast (2×, 4×, 8×) and time-lapse (30× to 300×, “1 minute in 2 seconds”), which skips through the key pictures so even a whole night goes by quickly.',
      'Paused stays paused: dragging the timeline, clicking an event, changing speed or stepping never starts playback; only Play does. While paused, step one picture at a time with the buttons or ← and →, with the exact time shown.',
      'Save clip shows the clip as a red band on the timeline, ending where you are. Drag either edge, or pick 10 s, 30 s, 1 min, 5 min or 15 min. A clip can also be saved as a time-lapse.',
      'The Live button now points right, toward the end of the timeline where live is.',
      'Keys: Space play or pause, ← → a picture (paused) or a second, Shift + ← → a minute, , and . slower and faster, L live, C save a clip.',
      'The About page tells what Camera Bridge OS is now: a friendly local recorder for the cameras you already own, with Apple Home as an option.',
    ],
  },
  {
    version: '0.1.119',
    date: '2026-10-24',
    title: 'Safer camera setup, cameras found on the wrong network, and removed cameras keep their Apple Home pairing',
    items: [
      'Watch its internet no longer changes the DNS of a Hikvision-made camera (ANNKE and others) through ONVIF while it gets its address from your router. On some of these cameras that change turned the router address off, so they fell back to 192.168.1.64 after a restart. For other cameras, Camera Bridge checks the network settings after the change and puts the router address straight back if it was turned off.',
      'The camera search also uses Hikvision’s own search, so a camera stuck on another network (such as 192.168.1.64 after a reset) shows up as “Found a camera on another network”, with the steps to bring it home.',
      'A camera you remove keeps its Apple Home pairing for 30 days: add the same camera again within that time and Home keeps the accessory, its room and its automations.',
    ],
  },
  {
    version: '0.1.118',
    date: '2026-10-24',
    title: 'Cameras are added through their maker’s own interface, and a new camera that isn’t set up yet says so',
    items: [
      'Adding a camera: before settling on ONVIF, Camera Bridge asks the camera for its maker’s own interface (Hikvision and the brands built on it such as ANNKE, then Reolink, Dahua and Amcrest) and uses it when it answers, so the Security card can check and turn off UPnP and the maker’s cloud. The page says which one it found.',
      'A Hikvision or ANNKE camera that hasn’t been activated yet (no admin password) no longer shows “nothing found”: Camera Bridge says so, with a button to open the camera’s web page to choose a password and a Check again button. A Reolink still on an empty password is treated the same way and is never added with it.',
    ],
  },
  {
    version: '0.1.117',
    date: '2026-10-23',
    title: 'Put your cameras in your own order, and choose the mosaic by columns',
    items: [
      'Drag a camera on the Monitor to a new place (press and hold on a phone; with the keyboard, Alt and an arrow key on a selected camera). The order is kept on the bridge, so every device shows the same one, and the Cameras list and the Events page follow it.',
      'Mosaic: choose 2, 3 or 4 cameras across. Each camera keeps its own picture shape.',
    ],
  },
  {
    version: '0.1.116',
    date: '2026-10-23',
    title: 'The secure address gets its certificate reliably',
    items: [
      'The secure address now gets its certificate on the first try: the box hands the website the right value to prove the name.',
      'When the Camera Bridge website has trouble, the box waits longer between tries (10 minutes, then up to 6 hours) instead of asking every minute, and after “too many requests” it waits until the next day.',
    ],
  },
  {
    version: '0.1.115',
    date: '2026-10-22',
    title: 'A secure address with a lock, and cameras you can turn off',
    items: [
      'A secure address: your bridge gets its own https address (shown in Settings › System) with a real certificate, so browsers show a lock instead of “Not secure”. Open it once and install the app from there. The bridge renews the certificate by itself, and the plain camera-bridge.local address sends you there (a switch in the same card turns that off).',
      'Only the bridge’s name and its home address go through camera-bridge.app to make this work; video and the pages never leave your network. If your router blocks names that point inside the home, the card says so and how to allow it.',
      'A camera you turn off leaves the Monitor and stays in Apple Home with a “Camera off” picture, so rooms and automations keep working. Its recordings stay on the Events page.',
    ],
  },
  {
    version: '0.1.114',
    date: '2026-10-22',
    title: 'An Events page, notifications that fade away, and faster playback',
    items: [
      'Events: a new page in the menu with every camera’s events, newest first, each with a picture, its type and the AI’s sentence. Alarm and unusual events stand out. Filter by camera, type, what the AI saw, importance or words in the sentence, and click an event to play it on the Monitor from just before it began.',
      'The Monitor’s events list shows the same picture, type and AI details, and a link to the Events page. New AI descriptions show within seconds.',
      'Playback speed on the Monitor: 1×, 2×, 3×, 5× or 10× while you look back in the recordings. Sound is off above 2×, and going live puts it back to 1×.',
      'Notifications now appear in the corner of the page and fade away after a few seconds, and each one shows only once, on every device. The bell in the menu opens the Notifications page, which keeps them all.',
      'The Internet guard no longer warns every day about lookups it blocked: blocking them is the guard doing its job. A camera’s first try gets one notification, and its Security card counts the blocked attempts as a success.',
      'Camera pages keep the preview and its status in view while the settings beside them scroll.',
    ],
  },
  {
    version: '0.1.113',
    date: '2026-10-19',
    title: 'Straighten the picture, AI descriptions of events, and the Internet guard on more cameras',
    items: [
      'Straighten the picture: a new card on a camera’s page for a camera whose horizon bends, such as a panorama camera pointed at the sky. Straighten flattens the curve, Level tips the picture, and Reset puts both back. The preview bends as you drag, and a guide line shows where the horizon lands.',
      'The correction shows everywhere that camera is seen: live view, the Monitor, playback, the Watch screen, zoom, snapshots, Apple Home’s live view and HomeKit Secure Video.',
      'Recordings on the box keep the camera’s original picture, so nothing is lost and you can change the setting or turn it off at any time. Changing it never restarts the camera or cuts a recording.',
      'Apple Home: while a camera is straightened, the box converts its video for Apple Home instead of passing the camera’s own stream through, which uses more of the box’s processor.',
      'A very wide camera in Original quality is sent to Home at most 3840 wide while it is straightened or labelled.',
      'Saved clips are straightened by default. The clip bar has a “Straightened” checkbox for a camera with the correction on; unticked, the clip is saved as recorded, which is quicker.',
      'Camera Bridge can now write one short sentence about an event, such as “A delivery driver leaves a package at the front door”. You see it under the event on the Monitor and on the camera’s page.',
      'It is off until you turn it on. In Settings, choose Claude or another AI service, paste your own key, and press Try it. Then switch on “Describe events with AI” on the page of each camera you want described.',
      'You need your own key from the AI service, and you pay the service whatever it charges. A daily limit, 200 by default, keeps the cost down.',
      'For each event, up to five small still pictures go to the service you chose. No video, no sound, and nothing from a camera whose switch is off, except when you press Try it. A model on your own network, such as Ollama, keeps the pictures at home.',
      'An event the service rates unusual gets an amber dot on the Monitor, and an alarm gets a red one. “Nothing notable” means it saw nothing worth saying.',
      'Watch its internet now puts Camera Bridge in both of a camera’s DNS slots first, and gives a slow camera up to 30 seconds to take the change.',
      'Dahua, Amcrest and Lorex cameras: their DNS is changed in the camera’s own settings first, then through ONVIF.',
      'A Hikvision that gets its address from your router (DHCP) is no longer shown as watched on a DNS setting the router would undo.',
      'New, off unless you tick it: “Fix its address so the DNS stays”, for cameras that drop a DNS server set by hand otherwise. It keeps the camera’s address, mask and gateway exactly as they are and turns DHCP off on the camera. Reserve that address in your router afterwards; Restore original settings puts DHCP back.',
      'A camera that needs a restart to use its new settings shows “Restart the camera now”. Camera Bridge restarts a camera only when you press it.',
      'Setting the DNS by hand: the help has a button that opens the camera’s web page, says what the camera asks now and what to change it to, has Copy buttons for the addresses, and shows the menus of the camera’s maker (Hikvision, Dahua, Axis, Hanwha, Uniview, Foscam, VIGI and more). It warns when the camera has IPv6 on.',
      '“Local only” now needs at least one lookup seen from the camera. A camera that never asks Camera Bridge anything may have a DNS server of its own built in, so it stays at Good and says so.',
    ],
  },
  {
    version: '0.1.112',
    date: '2026-10-18',
    title: 'IPCamera Web cameras sign in, and Jennov cameras keep their DNS',
    items: [
      'Cameras with an “IPCamera Web” page (such as the N801B) now sign in: they answer a successful sign-in without a code, which the last build took for an error.',
      'Jennov and other cameras with the same web page: Watch its internet sets their DNS in the camera’s own network settings, because their ONVIF took the change and later dropped it. A camera that gets its address from DHCP is told how to set Mode Static on its page first (Network › Basic, TCP/IP).',
    ],
  },
  {
    version: '0.1.111',
    date: '2026-10-18',
    title: 'The Internet guard on more cameras, and help for what can’t be changed',
    items: [
      'Watch its internet now points every DNS server of a camera at Camera Bridge (a camera with two kept the second, such as 8.8.8.8). If a camera keeps one, the step says which.',
      'A camera whose DNS you point at Camera Bridge yourself counts as watched. Camera Bridge checks every 30 minutes, when a camera comes back online and when you press Check again, and takes a camera off the list when it no longer asks Camera Bridge.',
      'Reolink: Set up for Camera Bridge now turns UPnP and the cloud (UID) off, takes the time from the bridge and watches the internet, through Reolink’s own settings. With the UID off the Reolink app stops working away from home; doorbell rings still come through Apple Home.',
      'Cameras with an “IPCamera Web” page (such as the N801B) work fully: Camera Bridge could never sign in to their page before, so their cloud, video password and extra services could not be changed.',
      'A setting the camera’s account is not allowed to change says so (use an administrator account in the camera’s settings), and the rest of the setup still runs.',
      'Every step that can’t be done says why and how to change it by hand on that camera.',
      '“Locked” now only means the camera locked its logins; a short pause by Camera Bridge after a refused password says so, with the time in your time zone.',
      'Passwords in a camera’s stream address are kept in the secret store, not in the settings file or logs.',
      'Fixed: a battery camera woken while its last connection was still closing could show no video.',
    ],
  },
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

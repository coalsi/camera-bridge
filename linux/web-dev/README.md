# Dev tools for the NVR web interface

Tools for building and checking the page's recording and playback code without a box, a camera or the Mac app. Nothing here is shipped:
the OS image copies `linux/web` only. No npm, no install: Node 22 or newer (`node --version`) and, for the clips, `ffmpeg`.

```
make-fixtures.sh          writes fixtures/*.mp4 and *.jpg with ffmpeg (7 clips, about 40 MB, git-ignored)
dev-archive-server.mjs    serves linux/web and answers /api/v1 with nine fake cameras and three days of footage
conformance.mjs           checks that a server (this one, the Mac dev daemon, the box) keeps the NVR API contract
lint.mjs                  the page's house rules (CSP-safe code, plain-HTTP limits, lazy NVR code): node linux/web-dev/lint.mjs
lib/                      the pieces: mp4 reader, ids, fixtures, virtual archive, state, routes, server
```

## Run it

```
sh linux/web-dev/make-fixtures.sh
node linux/web-dev/dev-archive-server.mjs            # http://127.0.0.1:8090/ , password: camera-bridge-dev
```

Loopback only by default. `--host 0.0.0.0` (to try an iPad or iPhone over the LAN) needs your own password in `CB_DEV_PASSWORD`; the
server then serves fixture video and a fake bridge to your whole network, so stop it when you are done. `--help` lists the options:
`--latency-ms`, `--jitter-ms` and `--throttle-mbps` slow the archive routes (a Wi-Fi link is `--throttle-mbps 100`),
`--clock-offset-ms` moves the server's clock away from yours (the page must work from server time), `--disk-gb` sizes the pretend drive.

## What is fake, and how

Nine cameras with fixed ids (`0A1B2C3D-0000-4000-8000-00000000000N`) and documentation addresses (192.0.2.x). Five carry a `status.security` (`lib/camera-security.mjs`, the bridge's words), one per level and one watched camera that keeps trying to reach the internet, each with what the Internet guard saw (`guard`), checked three hours ago; the others have not been checked, so the key is absent. `POST cameras/:id/security/check` answers the level checked now, 429 with `Retry-After` within a minute, 409 for a camera turned off, and 422 for a camera without a level. The fake setup offers "Watch its internet" (DNS to 192.0.2.2). Footage is the clips repeated:
fragment `n` of a 15-minute file is fragment `n % clip length` with its `tfdt` advanced, so a camera has three days of footage that
decodes and seeks like the real thing (ids, anchors, keyframe flags, continuation fragments, `mime`, `prft` removed all follow T00 Part C).

| Camera | Clip | What it is for |
|---|---|---|
| Front Door | gop2 (640x360, key every 2 s) | the plain case, no gaps; security red (Hik-Connect linked, UPnP on) |
| Driveway | hd (1280x720, 4 Mbps) | big fragments, a 20-minute gap every day, files 300 ms apart; night vision (Auto, Night, Day) and an IR lamp; pans, tilts and zooms (`POST cameras/:id/pan-tilt` answers 204 and moves nothing), so the Monitor shows the pad and the night vision buttons together; security yellow (cloud unknown, video without a password) |
| Garage | longgop (key every 12 s) | continuation fragments, the keyframe note and caption, the fix; night vision Auto and Day only, no lamp; security green (DDNS unknown, not watched) |
| Back Yard | ntsc (30000/1001 fps) | non-integer frame times, files that overlap by 0.4 ms, a 7-minute gap; security gold (everything off, watched and quiet); Sky Watcher set on (it watches once the plugin is on), as a dual-lens camera facing north (see below) |
| Side Gate | hevc (hvc1) | `isTypeSupported` false in some browsers; night vision whose every change fails (422 `night_vision_failed`) |
| Living Room | gop2 and res-b, alternating every 2 h | a different `mime` and size between files, a 45-minute gap; security yellow from the Internet guard (watched, 47 lookups blocked today, four names, documentation domains) |
| Porch | gop2 | Record sound on, files with `sound: true` |
| Shed | quiet (320x180) | Record off, footage that ended 6 hours ago |
| New Gate | gop2 | began 25 minutes ago: `typical` is null (under 30 minutes) |

`GET nvr/cameras/:id/clip-plan` and `GET nvr/cameras/:id/clip` answer the clip bar: one part per recording file the range touches, the file's init and fragments as they are (`labels` and `straighten` are ignored here); `speed=30|60|120|300` runs ffmpeg as the bridge does for a time-lapse (key pictures only, `setpts`, 30 pictures a second, no sound) and names the file `… time-lapse 60x.mp4`; another `speed` is 400. `GET nvr/events` answers a made-up event log: the schedule of each camera's `recentEvents` over the last seven days (8 to 62 s each, a doorbell ring none), `recorded` where the footage is (or, as the bridge says, for an event less than 2 minutes old of a camera that records), plus what `POST /__dev/event` sent. Every third event carries a made-up AI `description` ({summary, kind, concern}: person, vehicle, animal, delivery, other, nothing; routine, unusual, alarm) so the Events page and the Monitor's card have something to show. Its pages never split a millisecond (`eventPage`, as the bridge's), it answers 503 `archive_unavailable` in the `folderMissing` scenario and no events without a folder. The waveform is a deterministic daily rhythm with bursts (non-key bytes per second per minute). The drive is 512 GB with 40 GB used by
other things; the floor is `max(8 GiB, 5%)`. Retention applies at once when a limit is changed (the janitor would take up to 60 s).

## Sky Watcher

**Sky Watcher is a plugin, and it is off when the server starts**, as on a new box: switch it on in Plugins (`GET plugins` lists it, the only plugin this server has; `PATCH plugins/sky {"enabled": true}` is the switch), or `POST /__dev/sky {"plugin": true}`. While it is off there is no Sky Watcher in the menu, on a camera's page or at `#/sky` (which says it is off), the box reports no `status.sky`, and turning a camera on is refused (400, field `plugins.sky`, "Turn on Sky Watcher in Plugins first."); every camera keeps what it was set to, Back Yard included, so switching it on again brings it back. A reset (`POST /__dev/reset`) is a new box: the plugin is off again.

`lib/sky.mjs` answers Task 5's routes with a made-up night, so the page's card, the sky log (`#/sky`) and its Setup panel (where the box is, the flight feed, the AI's limit) can be tried once the plugin is on: `GET sky/cameras/:id/night?date=&view=night|day`, the still of an entry (a made-up night sky, a JPEG), `POST …/correction`, `POST sky/feeds/find`, `sky` in `GET`/`PATCH settings` (a place on the map, a feed with a host, a limit of 1 to 1000) and `skyDetector` in `PATCH cameras/:id` (enabling needs a place and a recordings folder, and a camera on a battery cannot: the bridge's three sentences). Back Yard watches the sky as soon as the plugin is on. The night is the same night each time it is asked for, and busy as a real one is: about fifty planes (some of them only strobes crawling along the horizon), 190 satellites in two waves after dusk and before dawn, four meteors, a few bugs and birds, and six lights nothing explains (a fast one with the AI's sentence, brief bright ones that rise, hold and fade, and flashes on the skyline). A night runs from 6:30 PM to 7:10 AM in this computer's time zone, a day from midnight to midnight; the latest night is the one that began at the last 6:30 PM, and one still going holds only what has happened. Corrections are kept until `/__dev/reset`. Back Yard's three days of recordings (the test pattern, not a sky) hold the last nights' lights, so the log's **Play** opens the clip player on them; a night older than that has no recording, and the player says so and shows the still. The server sends the box's `Permissions-Policy`, which lets the page ask the browser for its location (`geolocation=(self)`).

`POST /__dev/sky {"plugin": true | false, "aim": "rough" | "good" | "mixed" | "precise", "learning": "learning" | "ready", "problem": "…" | null, "stream": "main" | "sub", "location": {"latitude", "longitude"} | null, "feeds": [url]}` changes what the box reports (the first look is `mixed`: the left lens precise, the right one good) and what it has: `"location": null` makes the first turning-on ask for a place, `"feeds": []` makes **Find a feed** find none. Use a name of its own for the page, so that its session does not meet another dev server's cookie: `node linux/web-dev/dev-archive-server.mjs --port 8143 --allowed-host sky.localhost`, then open `http://sky.localhost:8143/#/sky` (a browser sends `*.localhost` to this computer).

## Reading the picture

The clips are ffmpeg test patterns that draw their own clock and frame number in the top left corner. A camera's footage is its clip
repeated, so the time on screen is where the playhead is inside the clip, not the wall clock: for a file whose `anchor` (from `fragments`)
is `S` and whose clip is `L` long (gop2, longgop, ntsc and Porch: 60 s; hd: 40 s; hevc: 20 s; res-b and quiet: 30 s), the picture at wall time
`t` shows the clip time `(t - S) mod L`. The frame number is that time times the frame rate (25, or 30000/1001 for Back Yard). That is how a
test of "the exact frame appears after a scrub" can tell which frame it got.

## Scenarios

`--scenario NAME` at start, or while it runs: `curl -s -X POST http://127.0.0.1:8090/__dev/scenario -H 'Content-Type: application/json' -d '{"name":"diskFull"}'`
(`/__dev/state` shows the state, `/__dev/reset`, `/__dev/clock {"offsetMs"}`, `/__dev/options {"latencyMs"...}` and `/__dev/night-vision {"id", "fail": true}`
(a camera's night vision changes fail with 422 until `"fail": false`; a sentence instead of `true` is the error) exist too; they answer this computer only).

| Scenario | What the server does |
|---|---|
| `ok` | folder set, recording |
| `noFolder` | no folder: Record on is 409 `folder_required`, storage says `noFolder`, the banner offers `choose-folder`, the archive is empty until a location is chosen (`PATCH nvr/storage {"location":"builtin"}` ends the scenario) |
| `folderMissing` | recording paused, banner `open-settings`, the plan still lists parts, fragment bytes are 410 `gone`, the location check fails |
| `diskFull` | free space below the floor: paused, nothing deleted |
| `lowSpace` | 3.2 GB above the floor: the "almost full" notification, no pause |
| `notWritable` | paused with "Camera Bridge can’t write to that folder." |
| `stalled` | paused with "The drive isn’t answering."; reads wait `--stall-ms` (5 s) then 504 `drive_slow`; so does a folder check (8 s) |
| `noArchive` | the daemon has no archive: R5 to R10 are 503 without `Retry-After` |
| `loading` | 503 with `Retry-After: 2` for `--loading-ms`, then `ok` |

Admission is the real one: 8 archive requests in all, 6 per address, the next is 429 `busy` with `Retry-After: 1` at once.
Not the daemon: the sign-in has no rate limit, sessions live in memory, and routes the NVR work does not need answer 404.

## Check a server

```
CB_PASSWORD=... node linux/web-dev/conformance.mjs http://127.0.0.1:8090 --all
```

Read-only by default (plus requests the server must refuse). `--mutate` adds writes that change nothing and invalid input; `--intrusive`
adds a wrong password and a burst of 40 requests (against a real box those can lock you out or load it); `--all` is both; `--no-burst`
leaves the burst out and reports it as skipped, for a caller that runs it another way (the box's smoke test does, from inside the box,
because QEMU's user-mode port forwarding resets connections that arrive together; every other check here asks one thing at a time);
`--only TEXT` runs the checks whose name contains it. The password comes from the environment and is never printed. Exit status 0 when
nothing failed.

Notifications: the dev server keeps the log in memory (`lib/notifications.mjs`; `/__dev/reset` empties it) and answers `GET notifications`, `POST notifications/shown` and `POST notifications/read`. Living Room (the camera whose Internet guard blocks its attempts) raises the guard's first-try notification, so a fresh sign-in shows one toast; `sh linux/web-tests/run.sh` checks the routes (`notifications-server.test.mjs`).

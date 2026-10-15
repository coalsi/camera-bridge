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

Nine cameras with fixed ids (`0A1B2C3D-0000-4000-8000-00000000000N`) and documentation addresses (192.0.2.x). Footage is the clips repeated:
fragment `n` of a 15-minute file is fragment `n % clip length` with its `tfdt` advanced, so a camera has three days of footage that
decodes and seeks like the real thing (ids, anchors, keyframe flags, continuation fragments, `mime`, `prft` removed all follow T00 Part C).

| Camera | Clip | What it is for |
|---|---|---|
| Front Door | gop2 (640x360, key every 2 s) | the plain case, no gaps |
| Driveway | hd (1280x720, 4 Mbps) | big fragments, a 20-minute gap every day, files 300 ms apart |
| Garage | longgop (key every 12 s) | continuation fragments, the keyframe note and caption, the fix |
| Back Yard | ntsc (30000/1001 fps) | non-integer frame times, files that overlap by 0.4 ms, a 7-minute gap |
| Side Gate | hevc (hvc1) | `isTypeSupported` false in some browsers |
| Living Room | gop2 and res-b, alternating every 2 h | a different `mime` and size between files, a 45-minute gap |
| Porch | gop2 | Record sound on, files with `sound: true` |
| Shed | quiet (320x180) | Record off, footage that ended 6 hours ago |
| New Gate | gop2 | began 25 minutes ago: `typical` is null (under 30 minutes) |

The waveform is a deterministic daily rhythm with bursts (non-key bytes per second per minute). The drive is 512 GB with 40 GB used by
other things; the floor is `max(8 GiB, 5%)`. Retention applies at once when a limit is changed (the janitor would take up to 60 s).

## Reading the picture

The clips are ffmpeg test patterns that draw their own clock and frame number in the top left corner. A camera's footage is its clip
repeated, so the time on screen is where the playhead is inside the clip, not the wall clock: for a file whose `anchor` (from `fragments`)
is `S` and whose clip is `L` long (gop2, longgop, ntsc and Porch: 60 s; hd: 40 s; hevc: 20 s; res-b and quiet: 30 s), the picture at wall time
`t` shows the clip time `(t - S) mod L`. The frame number is that time times the frame rate (25, or 30000/1001 for Back Yard). That is how a
test of "the exact frame appears after a scrub" can tell which frame it got.

## Scenarios

`--scenario NAME` at start, or while it runs: `curl -s -X POST http://127.0.0.1:8090/__dev/scenario -H 'Content-Type: application/json' -d '{"name":"diskFull"}'`
(`/__dev/state` shows the state, `/__dev/reset`, `/__dev/clock {"offsetMs"}` and `/__dev/options {"latencyMs"...}` exist too; they answer this computer only).

| Scenario | What the server does |
|---|---|
| `ok` | folder set, recording |
| `noFolder` | no folder: Record on is 409 `folder_required`, storage says `noFolder`, the banner offers `choose-folder`, the archive is empty until a location is chosen (`PATCH nvr/storage {"location":"builtin"}` ends the scenario) |
| `folderMissing` | recording paused, banner `open-settings`, the plan still lists parts, fragment bytes are 410 `gone`, the location check fails |
| `diskFull` | free space below the floor: paused, nothing deleted |
| `lowSpace` | 3.2 GB above the floor: the "almost full" banner, no pause |
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

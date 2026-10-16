# Camera Bridge web interface

The page `camerabridged` serves at `http://camera-bridge.local`. Plain HTML, CSS and ES modules: no build step, no framework, no CDN,
no external fonts. Dark by default and light with the system (`prefers-color-scheme`), bridge red `#9E2B20` with cream text on
fills and light red `#E06A5A` for text on dark, on dark neutral; the logo is the Golden Gate seen through a lens
(`docs/brand/BRAND.md`). Phone and desktop (a tab bar at the bottom on a phone), keyboard and screen reader friendly (landmarks,
labels, visible focus, live regions, native dialogs, reduced motion).

```
index.html            the shell; one module script
style.css             tokens (colours, spacing), layout, components
js/app.js             boot (first run, sign in, signed in), the hash router, the shell
js/api.js             fetch with the session cookie and the anti-forgery token
js/store.js           cameras and bridge state, kept current by /api/v1/events
js/dom.js             h(), modal dialogs, toasts (everything is built with the DOM API, never innerHTML)
js/screens/           auth, cameras (the Cameras list, #/cameras), nvr (the Monitor: the home page's wall with the recordings), wall-events (its notices), add (the wizard), camera, pairing, settings, logs, system, banners
js/nvr/               recording and playback (see "Recording and playback" below)
nvr-record.css, nvr-watch.css, nvr-grid.css    styles of the recording screens (style.css is not edited for them)
mark.svg, mark-small.svg, site.webmanifest    the logo (mark-small.svg at 32 px and below: favicon, sidebar), the manifest
```

The Content-Security-Policy the server sends allows only these files and media played from a `blob:` URL (`media-src 'self' blob:`): no
inline scripts or styles, so new code must not use `style="…"` attributes, `innerHTML` or `eval` (set `el.style.x` from script, which the
policy allows).

## Recording and playback

Recording, storage settings, banners and playback are plain ES modules under `js/nvr/` and `js/screens/`, loaded on demand: `app.js` wraps the new screens in `lazy()`, and `js/nvr/lite.js` is the only static import, so a broken recording module cannot blank the sign-in page. Times in these modules are epoch milliseconds from the box's clock unless a name says seconds (`startSec`, `bufferSeconds`).

| Files | What |
|---|---|
| `js/nvr/lite.js`, `ui.js`, `record.js`, `storage.js`, `storage-info.js` | The Record switch (camera card, camera page, watch screen), the first-time "Where should recordings be stored?" dialog, Settings > Recording (its numbers and sentences are plain functions in `storage-info.js`) and the keyframe note. `lite.js` loads `ui.js` on demand |
| `js/nvr/fetcher.js`, `catalog.js`, `clock.js`, `planner.js`, `cell.js`, `surface.js`, `session.js` | The player: a page-wide request scheduler (3 byte fetches and 1 JSON request at a time), the catalog and server-clock poll, the playback clock, the pure rules for what to fetch, one tile (`cell.js`, with one MediaSource in `surface.js`) and the shared playhead for one to nine tiles (`session.js`) |
| `js/nvr/timeline/viewport.js`, `ticks.js`, `activity.js`, `model.js`, `draw.js`, `scrub.js`, `keys.js`, `view.js` | The timeline: zoom and pan, calendar-aligned ticks, the activity wave and its scale, the model that follows the live edge (the preset is remembered in `cb.nvr.zoom`), the canvas painter, the pointer handling, the keyboard map and the control that ties them together |
| `js/screens/watch.js`, `watch-state.js`, `preview.js`, `optimize-dialog.js` | The watch screen and its rules (`watch-state.js`, no DOM), the snapshot picture used when Record is off, and the smart-codec dialog |
| `js/screens/nvr.js`, `nvr-model.js`, `nvr-controller.js` | The NVR page: a grid of tiles on one playhead (9 on a page by default, 2 on a phone; the Per page control, `?tiles=` or `cb.nvr.tiles` change it, 1 to 16), its rules and its controller (no DOM) |
| `js/screens/nvr.js` + `monitor.css`, `js/screens/wall-events.js`, `js/live/mux.js` | The Monitor (`#/`, also `#/monitor` and `#/nvr`): every camera on a black wall with the recordings' controls (Live at the live edge; Play/Pause and Back to live while looking back; timeline, presets, clips, grid size, pages), live video for every tile whenever the wall is live (Smooth or Full quality), the date and time on every picture, notices, an events list and sound for motion, detections and doorbell rings; Full screen fills the display |
| `js/stamp.js`, `js/theme.js`, `theme-boot.js`, `js/power.js` | The date-and-time written on every picture; the Auto / Light / Dark appearance; Power off |
| `nvr-record.css`, `nvr-watch.css`, `nvr-grid.css` | Styles of the recording screens; `style.css` is not edited for them |

Recorded video is fetched with `getBytes()` in `js/api.js` (the only place that calls `fetch`) and played through Media Source Extensions: a `blob:` media source is why the Content-Security-Policy has `media-src 'self' blob:`. Nothing in these modules uses WebCodecs, a worker or WebAssembly. `docs/linux/ARCHITECTURE.md` ("Recordings in the browser") explains the flow.

## Run it on a Mac

```
cd Packages/CameraBridgeKit
swift run camerabridged --dev --data-dir /tmp/cb-dev --fake-discovery
open http://127.0.0.1:8080
```

`--dev` keeps the engine on loopback with nothing advertised and the HomeKit ports from 38100, so it never disturbs the Camera Bridge
app. The Add Camera page can add the demo camera (a test pattern with motion every minute) and `--fake-discovery` shows three
sample cameras on documentation addresses. `--preview` serves the engine's fixed sample data instead (no camera runs).
`camerabridged` finds this directory itself when started from the repository (`--static-dir` overrides).

The image installs these files in `/usr/share/camera-bridge/web`.

## Tests and tools

`linux/web-tests/` holds the tests of the pure modules (Node 22 or later, no packages): from the repository root, `node --test 'linux/web-tests/*.test.mjs'` (the quotes matter). `linux/web-dev/` holds the development tools:

| File | What |
|---|---|
| `dev-archive-server.mjs` | A Node server that serves `linux/web` and answers the recording routes from fixture files, with the daemon's Content-Security-Policy; switches for the cases "no folder", "drive missing", "disk full" and "stalled" |
| `make-fixtures.sh` | Builds the fixture files with ffmpeg |
| `conformance.mjs <base-url>` | Signs in and checks the shape of every recording route against a dev server, a daemon on a Mac or a box (the password comes from the environment and is never printed) |
| `lint.mjs` | Rejects what the Content-Security-Policy forbids: `innerHTML`, `style="…"`, `eval`, `fetch` outside `api.js` and the like |
| `spike/` | The browser test pages for plain HTTP (secure context, Media Source Extensions) |
| `soak/` | The Node side of the soak and fault tests: scripted clients, the sampler, the analyzer and the file verifier (`Tools/nvr-soak/README.md` says how a run goes) |
| `t10-run.mjs`, `t10-drive.js`, `t10-checks.js`, `t10-open-at.js`, `t10-smoke/` | Checks of the Watch screen in a throwaway headless Chrome: `node linux/web-dev/t10-run.mjs <url> <file.js>` evaluates the files in the page, and the first lines of each file say what it does |

Both directories live outside `linux/web/` because the image copies that whole directory (`linux/os/build-image.sh`).

`linux/web-dev/README.md` describes the dev server's nine fake cameras and its scenarios, and `linux/web-tests/README.md` the tests; `sh linux/web-tests/run.sh` runs all of them and makes the fixture clips first (tests that need `ffmpeg` skip, with the reason, when it is missing).

Test recordings the way the box shows them. A page from `http://127.0.0.1` is a secure context, so browsers offer features there that they do not offer on `http://camera-bridge.local`, which is not one: print `window.isSecureContext` and `typeof VideoDecoder` to see the difference. To see what the box shows without opening your Mac to the network, give the loopback address a name that is not a secure context. Start the daemon for that name, and map the name to 127.0.0.1 inside one browser only (Chrome: `--host-resolver-rules="MAP nvr.test 127.0.0.1"`, with its own `--user-data-dir`):

```
cd Packages/CameraBridgeKit
swift run camerabridged --dev --data-dir /tmp/cb-nvr --port 8081 --fake-discovery --allowed-host nvr.test
```

Then open `http://nvr.test:8081` in that Chrome. `--dev` keeps the web interface on 127.0.0.1, so only this Mac can reach it, and the daemon advertises nothing and uses HomeKit ports from 38100, so it does not disturb the Camera Bridge app.

## Screenshots

Taken from the daemon on a Mac with the demo camera (a test pattern) and documentation addresses: `docs/linux/screenshots/` (cameras, add a camera, a camera, pairing, log, phone, system in light mode).

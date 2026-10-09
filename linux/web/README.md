# Camera Bridge web interface

The page `camerabridged` serves at `http://camera-bridge.local`. Plain HTML, CSS and ES modules: no build step, no framework, no CDN,
no external fonts. Dark by default and light with the system (`prefers-color-scheme`), amber `#E8A33D` on dark neutral, phone
and desktop (a tab bar at the bottom on a phone), keyboard and screen reader friendly (landmarks, labels, visible focus, live
regions, native dialogs, reduced motion).

```
index.html            the shell; one module script
style.css             tokens (colours, spacing), layout, components
js/app.js             boot (first run, sign in, signed in), the hash router, the shell
js/api.js             fetch with the session cookie and the anti-forgery token
js/store.js           cameras and bridge state, kept current by /api/v1/events
js/dom.js             h(), modal dialogs, toasts (everything is built with the DOM API, never innerHTML)
js/screens/           auth, cameras, add (the wizard), camera, pairing, settings, logs, system, banners
mark.svg, site.webmanifest
```

The Content-Security-Policy the server sends allows only these files: no inline scripts or styles, so new code must not use
`style="…"` attributes, `innerHTML` or `eval` (set `el.style.x` from script, which the policy allows).

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

## Screenshots

Taken from the daemon on a Mac with the demo camera (a test pattern) and documentation addresses: `docs/linux/screenshots/` (cameras, add a camera, a camera, pairing, log, phone, system in light mode).

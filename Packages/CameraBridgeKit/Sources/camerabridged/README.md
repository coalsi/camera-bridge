# camerabridged

The Camera Bridge OS daemon: the bridge engine and its web interface in one process. `main.swift` only calls `BridgeDaemon`.

```
swift run camerabridged --help
swift run camerabridged --dev --data-dir /tmp/cb-dev --port 8080    # on a Mac: loopback, nothing advertised
```

## An Apple TV against a development daemon

`--dev` serves every route an Apple TV uses and announces nothing on the network (a second "Camera Bridge" would show up on every Apple TV in the house).

```
swift run camerabridged --dev --data-dir /tmp/cb-dev        # http://127.0.0.1:8080: set a password, add the demo camera
# tvOS simulator: Enter the address → 127.0.0.1:8080 (the simulator shares this Mac's network). Approve its code on the page
# (Settings › Security › Apple TV, or http://127.0.0.1:8080/#/pair/<code>) or with curl:
curl -s -c /tmp/cb-dev.cookies -H 'Content-Type: application/json' -d '{"password":"<password>"}' http://127.0.0.1:8080/api/v1/auth/login
curl -s -b /tmp/cb-dev.cookies -H 'Content-Type: application/json' -H 'X-CSRF-Token: <csrfToken from the line above>' \
     -d '{"code":"<code>"}' http://127.0.0.1:8080/api/v1/viewers/approve
# The app's own discovery: --dev announces nothing, so announce by hand (with the id GET /api/v1/viewer gives) on a daemon that
# listens on the network; stop both afterwards, every Apple TV in the house sees it:
swift run camerabridged --dev --lan --data-dir /tmp/cb-dev
dns-sd -R "Camera Bridge (dev)" _camera-bridge._tcp local 8080 id=<bridge.id> name="Camera Bridge (dev)" v=0.1 api=1
```

## Additions beyond the contract

New executable (additive; docs/CONTRACT_CHANGES.md 2026-10-08): `camerabridged`, a product of the `CameraBridgeKit` package.

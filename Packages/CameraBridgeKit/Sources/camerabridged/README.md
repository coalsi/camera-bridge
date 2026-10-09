# camerabridged

The Camera Bridge OS daemon: the bridge engine and its web interface in one process. `main.swift` only calls `BridgeDaemon`.

```
swift run camerabridged --help
swift run camerabridged --dev --data-dir /tmp/cb-dev --port 8080    # on a Mac: loopback, nothing advertised
```

## Additions beyond the contract

New executable (additive; docs/CONTRACT_CHANGES.md 2026-10-08): `camerabridged`, a product of the `CameraBridgeKit` package.

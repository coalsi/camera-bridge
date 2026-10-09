# BridgeDaemon

The logic of `camerabridged`, the Camera Bridge OS daemon, as a library so it can be tested: flags and environment variables
(`DaemonOptions`: `--flag`, `CAMERABRIDGE_*` as the OS image sets them, the older `CAMERA_BRIDGE_*`), the engine and web interface
started and stopped together (`Daemon`), SIGTERM and SIGINT handling, the systemd notification socket and watchdog (`SystemD`, no
libsystemd), a journald-friendly log sink (`StdoutLogSink`) and the operating system's privileged actions through request files
(`RequestFileSystemControl`).

## Additions beyond the contract

New module (additive; docs/CONTRACT_CHANGES.md 2026-10-08): `BridgeDaemon` with `Daemon`, `DaemonMain`, `DaemonOptions`,
`DaemonInfo`, `SystemD`, `StdoutLogSink` and `RequestFileSystemControl`.

## Platforms

- Linux: `BridgeEnvironment.linux(dataDirectory:)` (PlatformLinux). `--dev` keeps the engine on loopback and silent.
- macOS: always `BridgeEnvironment.testing` (loopback, nothing advertised, secrets in memory) with a data directory you name; the
  Mac app's own directories are refused. `--dev` also moves the HomeKit ports to 38100 and up.

## The system

`RequestFileSystemControl` writes one JSON file per request into the OS image's request folder and reads the status files the
image's root helper publishes (the contract is `linux/os/README.md`, the daemon's side is in `docs/linux/ARCHITECTURE.md`, "The
system helper"). Without the two folders (a Mac, a plain Linux box) the system is a "development" one and refuses everything
privileged. The tests run it against `FakeRootHelper`, a stand-in for `cb-system process-requests` that uses the same file names,
checks and status files.

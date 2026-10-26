# BridgeDaemon

The logic of `camerabridged`, the Camera Bridge OS daemon, as a library so it can be tested: flags and environment variables
(`DaemonOptions`: `--flag`, `CAMERABRIDGE_*` as the OS image sets them, the older `CAMERA_BRIDGE_*`), the engine and web interface
started and stopped together (`Daemon`), SIGTERM and SIGINT handling, the systemd notification socket and watchdog (`SystemD`, no
libsystemd), a journald-friendly log sink (`StdoutLogSink`), the operating system's privileged actions through request files
(`RequestFileSystemControl`) and, for the NVR, the recordings folder and the host policy the engine cannot find out itself
(`RecordingsFolder`, `DaemonArchivePolicy`).

## Additions beyond the contract

The archive drive (2026-10-25, docs/CONTRACT_CHANGES.md): `DaemonOptions.archiveDirectory` (`--archive-dir`, `CAMERABRIDGE_ARCHIVE_DIR`, a full path) and
`DaemonOptions.effectiveArchiveDirectory(dataDirectory:systemAvailable:)`: the option, else `archive` inside the data directory where Camera Bridge OS is underneath (its
request folders exist), else none, and never for `--preview`; the daemon gives it to the engine as `BridgeEnvironment.archiveDriveFolder`. `DaemonArchivePolicy` sets
`ArchivePlatformPolicy.isSameVolume` (`st_dev`; what cannot be measured counts as the same) and `ArchivePlatformPolicy.lowerThreadPriority`
(`DaemonArchivePolicy.lowerThisThread`: `setpriority` 19 for the calling thread, and util-linux's `ionice -c 3 -p <thread id>` for the idle I/O class, the thread id read
from `/proc/thread-self`, `DaemonArchivePolicy.threadID(fromThreadSelf:)`). `RequestFileSystemControl.archiveDrives()` asks `drive-list` (the recording drive's list) and
gives each disk the archive's view (`archiveEligible`, `archiveProblems`, `isArchiveDrive`, `archiveInUse`; a script without them: the recording drive's view; the
recording drive in use gets "it is the recording drive"), the state from `status/archive-drive.json`; `useArchiveDrive` checks the target, the sentence and the fresh list
and writes `archive-use` (`{"device", "phrase", "keepData"}`); `forgetArchiveDrive` writes `archive-forget`.

The internet guard, Watch (2026-10-17, docs/CONTRACT_CHANGES.md): `RequestFileSystemControl.setGuardedCameras(_:)` writes the `guard-set` request (`{"cameras": [{"address", "level": "watch"}], "timeZone"}`: each address checked and canonical, private IPv4 or unique-local/link-local IPv6, at most 64, the bridge's time zone for "today": `BridgeTime`, its settings' zone, not the process's UTC) and waits for the job, which counts as done only when `status/guard.json` then lists exactly those
cameras (else "The system couldn’t change the internet guard. It still watches another list.", and the engine sends it again);
`RequestFileSystemControl.guardReport()` reads `status/guard.json` (up to 1 MiB, `GuardReport.unavailable` without one). On Camera Bridge OS (the image has `camera-bridge-dns.service`, the request folders exist, not `--dev`) the daemon gives the engine `BridgeEnvironment.hasInternetGuard`, `setGuardedCameras` and `guardReport` through them. Internal: `RequestFileSystemControl.guardedAddress(_:)`, `Daemon.offersInternetGuard(development:systemAvailable:unitDirectory:)`, `Daemon.withInternetGuard(_:system:)`.

Time for the cameras (2026-10-16): on Linux the daemon sets `BridgeEnvironment.servesTime` when `/etc/chrony/chrony.conf` serves other machines (an `allow` line and no `port 0`: Camera Bridge OS's does), so "Set up for Camera Bridge" points cameras' clocks at the box. Internal: `Daemon.servesTime(chronyConfiguration:)`.

Installer stick (2026-10-14): `RequestFileSystemControl.HostFacts.runningFromUSB` reads the device mounted at `/` from `/proc/self/mountinfo` and whether its path in /sys passes through USB; it fills `SystemInfo.runningFromUSB`.

New module (additive; docs/CONTRACT_CHANGES.md 2026-10-08): `BridgeDaemon` with `Daemon`, `DaemonMain`, `DaemonOptions`,
`DaemonInfo`, `SystemD`, `StdoutLogSink` and `RequestFileSystemControl`.

The NVR (2026-10-10, docs/CONTRACT_CHANGES.md): `DaemonOptions.recordingsDirectory` (`--recordings-dir`,
`CAMERABRIDGE_RECORDINGS_DIR`) and `DaemonOptions.effectiveRecordingsDirectory(dataDirectory:)`; `DaemonOptions.lan` (`--lan`: with `--dev` only, the web interface listens on every interface instead of 127.0.0.1, for testing with your own devices; the engine stays on loopback) and `DaemonOptions.demoKeyframeSeconds` (the hidden `--demo-keyframe-seconds N`, with `--dev` or `--preview`: the demo camera keys every N seconds). Internal: `DaemonArchivePolicy`, `RecordingsFolder`, `NoArchiveBackend`.

## Platforms

- Linux: `BridgeEnvironment.linux(dataDirectory:)` (PlatformLinux). `--dev` keeps the engine on loopback and silent.
- macOS: always `BridgeEnvironment.testing` (loopback, nothing advertised, secrets in memory) with a data directory you name; the
  Mac app's own directories are refused. `--dev` also moves the HomeKit ports to 38100 and up.

## Recordings (the NVR)

The recorder and the store are in `BridgeEngine/NVR`; the daemon only says where and on what terms.

- The folder is `recordings` inside the data directory, or the full path of `--recordings-dir` / `CAMERABRIDGE_RECORDINGS_DIR` (relative paths, `..` and control
  characters are refused at start: the engine could not store them). `RecordingsFolder.prepare` makes it before the engine starts, never failing the start. Inside the
  data directory missing levels are made 0700; anywhere else only the folder itself, and only when its parent exists (an unplugged drive is not re-invented on the system
  disk). The recorder never makes the root. `--preview` makes none and offers none.
- `DaemonArchivePolicy` is the `ArchivePlatformPolicy` set as `BridgeEnvironment.archivePolicy` on Linux and on the Mac development daemon: `space` from `statvfs`
  (`total = f_blocks x f_frsize`, `free = f_bavail x f_frsize`, on the nearest existing parent while the folder is not there), `isSystemVolume` by `st_dev` equal to the
  data directory's (what cannot be measured counts as the system volume), the system floor `max(8 GiB, 5%)`, folders named by camera UUID. This is the only place that
  calls `statvfs` or `stat`: `Glibc` and `Darwin` are allowed in this module (and three named files elsewhere, `PortabilityTests`).
- `WebConfiguration.archiveLocations` holds one location, id `builtin`, labelled "This box’s storage" (Linux) or "Development folder" (Mac), with the normalized path of
  that folder. The browser sends the id; the path is display only.
- Starting never waits for the archive: `engine.start()` returns at once as far as the NVR is concerned (the store repairs and loads in the background), so the web
  interface and `READY=1` come up with a huge or damaged archive and with a drive that does not answer.
- `NoArchiveBackend` wraps the backend of `--preview`: no archive, so the NVR routes answer `503 archive_unavailable` without `Retry-After`. Like `DemoDiscoveryBackend` it forwards every `BridgeBackend` requirement, the Sky Watcher's (`skyNightLog`, `correctSkyEntry`, `skyStill` and `findFlightFeeds`) included: a requirement with an extension default is added to both by hand, or they would answer with the default.

## The system

`RequestFileSystemControl` writes one JSON file per request into the OS image's request folder and reads the status files the
image's root helper publishes (the contract is `linux/os/README.md`, the daemon's side is in `docs/linux/ARCHITECTURE.md`, "The
system helper"). Without the two folders (a Mac, a plain Linux box) the system is a "development" one and refuses everything
privileged. The internet guard's list goes out as `guard-set` and its report comes back as `status/guard.json` (linux/os/README.md,
"The internet guard"). The tests run it against `FakeRootHelper`, a stand-in for `cb-system process-requests` that uses the same file names,
checks and status files.

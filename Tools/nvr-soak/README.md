# NVR soak and fault tools

Tools for the NVR's soak and fault tests (task T15 of the NVR build). They answer one question: does the recorder, the archive and the web interface of Camera Bridge keep working, flat and quiet, under hours of recording and a storm of people scrubbing, and do they come back from a killed process, a power cut and a drive that stopped answering?

What is here

- `run-soak.sh` runs a scenario end to end: `soak` (default 2 hours, 8 cameras at 8 Mbit/s, 6 scripted clients), `kill9`, `crash-images`, `hang`, `startup-hang`. Targets: the dev daemon on this Mac, the Linux daemon in the `cb-linux-swift` container, or a daemon that already runs (a box, over ssh).
- `load-sources.sh` makes the load cameras: looping H.264 clips served as RTSP on loopback by the bundled go2rtc helper.
- `daemon.sh`, `lib.sh`, `probe.sh`, `verify-files.sh`: start, stop and kill the daemon on either side, read its resource use, check the recordings from a machine without Node.
- `notifylisten.c` stands in for systemd's notify socket (so READY=1 and WATCHDOG=1 are recorded). `hangshim.c` makes file calls under one folder hang, on demand; `hangshim-selftest.swift` proves that it does. `selftest.sh` runs both checks.
- The Node side (clients, sampler, analyzer, scenario checks, file verifier, damage tool, capture budgets) is in `linux/web-dev/soak/`; its tests are `linux/web-tests/soak-*.test.mjs`.

Rules

- Everything a run makes is under `$SCRATCH/soak/<run id>`; a run is removed only if it holds a `.soak-run` marker. Throwaway data directories, loopback only, ports 18090 (daemon), 18554 (load cameras) and 24400 upward (HomeKit). The owner's app, its data and its keychain are never touched. No process is ever stopped by name: only by the pid file a script wrote.
- The password and setup code of the throwaway daemon are generated per run, kept in 0600 files, and never printed.
- Start with `selftest.sh`, then a rehearsal (`run-soak.sh --rehearsal --scenario soak --minutes 6`), then a 10 minute smoke run against the real daemon, then the 2 hour soak.

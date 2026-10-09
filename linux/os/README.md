# linux/os: Camera Bridge OS image

Build, test and release instructions: `docs/linux/BUILDING.md`. User view: `docs/linux/USER-GUIDE.md`. This file is the contract between the operating system and the daemon (`camerabridged`, written by the web/daemon work) so both sides can be built independently.

## What the OS gives the daemon

The daemon runs as user `camerabridge` (uid 931) from `camerabridged.service` (`units/camerabridged.service.in`, paths from `paths.env`):

| Environment variable | Value | Meaning |
|---|---|---|
| `CAMERABRIDGE_PLATFORM` | `linux-os` | running on Camera Bridge OS |
| `CAMERABRIDGE_DATA_DIR` | `/var/lib/camera-bridge` | the data directory (the data partition; `config.json`, `hap/`, `secrets/`, `Diagnostics/`) |
| `CAMERABRIDGE_WEB_ROOT` | `/usr/share/camera-bridge/web` | static web UI files |
| `CAMERABRIDGE_HTTP_PORT` | `80` | web port (the unit grants `CAP_NET_BIND_SERVICE`) |
| `CAMERABRIDGE_RUN_DIR` | `/run/camera-bridge` | runtime folder |
| `CAMERABRIDGE_OS_REQUEST_DIR` | `/run/camera-bridge/requests` | where to drop privileged requests (below) |
| `CAMERABRIDGE_OS_STATUS_DIR` | `/run/camera-bridge/status` | where the OS publishes status files (read-only for the daemon) |

More can be set in `/etc/camera-bridge/camerabridged.env` (read by the unit if present).

Process requirements of the unit:

* `Type=notify`: send `READY=1` (sd_notify) once the web port is listening.
* `WatchdogSec=30`: send `WATCHDOG=1` at least every 15 s, or systemd kills and restarts the daemon. (If the daemon cannot do this, relax `WatchdogSec` in `units/camerabridged.service.in`.)
* `GET http://127.0.0.1/api/v1/status` must answer with a JSON document without authentication: `camera-bridge-health.service` uses it to decide whether a boot is good (a new OS version that fails this three times is rolled back automatically).
* Writes only to `/var/lib/camera-bridge`, `/tmp` (private) and the request folder; everything else is read-only (`ProtectSystem=strict`). `HOME=/var/lib/camera-bridge`.
* Allowed: TCP/UDP over IPv4/IPv6, Unix sockets (D-Bus for avahi's `dns_sd` compat library), netlink (`RTMGRP_*` monitoring), the GPU render node (`/dev/dri/renderD*`, group `render`). Not allowed: raw/packet sockets, namespaces, `CAP_*` other than `CAP_NET_BIND_SERVICE`.
* The secret store key is created by the OS at first boot: `/var/lib/camera-bridge/secrets/master.key` (32 random bytes, mode 0600, owner `camerabridge`). The daemon should use it (and create it itself if absent).
* `/var/lib/camera-bridge/first-run` exists (a timestamp) until the daemon decides setup is finished; the OS creates it again after a factory reset.
* The firewall allows inbound TCP 80, 443, 21100-21199, UDP 5353 (mDNS), SSH only when enabled, ICMP, answers from UDP source ports 3702/1900/37020/37810 (camera discovery) and UDP to ephemeral ports from the LAN (RTP/SRTP).
* The hostname is `camera-bridge`; avahi publishes `camera-bridge.local` and an `_http._tcp` service for the web UI.

## Privileged actions: request files

The daemon never runs as root. To ask for something privileged (from the web UI), write one JSON object to `/run/camera-bridge/requests/<name>.json` (any user-visible API can map onto this). `camera-bridge-request.path` wakes a root helper (`/usr/sbin/cb-system process-requests`), which accepts **only** these names, validates the JSON with `jq` and runs the action. The request file is consumed (deleted) at once. The daemon writes a request as a temporary file `.<name>.<uuid>.tmp` in the same folder and renames it onto `<name>.json`, so the helper never sees half a request (and may delete the temporary file if it happens to run at that moment; the daemon then writes it again).

| Name | JSON body | Effect |
|---|---|---|
| `update-check` | `{}` | looks for a newer release |
| `update-apply` | `{"reboot": false}` | downloads, verifies, installs into the idle slot (optionally restarts) |
| `auto-update` | `{"enabled": true}` | switches the daily automatic update on/off |
| `ssh-enable` | `{"authorizedKeys": "ssh-ed25519 AAAA... comment\n..."}` | enables key-only root SSH (plain public keys only, up to 20) |
| `ssh-disable` | `{}` | |
| `reboot`, `poweroff` | `{}` | |
| `factory-reset` | `{"confirm": "RESET"}` | erases `/var/lib/camera-bridge`, reboots |
| `install-list` | `{}` | writes `status/install-candidates.json` (the disks and why they are or are not usable) |
| `install-to-disk` | `{"device": "/dev/nvme0n1", "phrase": "ERASE ALL DATA ON nvme0n1", "copyData": true, "poweroff": true, "dryRun": false}` | copies the running system to that disk. The UI must make the user type the phrase; the installer checks it again. |

Status files (world-readable JSON written atomically by the root side; each has `state`, `message`, `updatedAt`):

* `status/<name>.json` for every request above: `queued`, `running`, then `ok` or `failed` (`install-to-disk` ends with the installer's own `ok` or `failed`, see below). A status file is newer than a request when its `updatedAt` is not before the second the request was written; the daemon relies on that, never on the file merely existing.
* `status/update.json`: `state` is `checking`, `available`, `current`, `downloading`, `installing`, `installed`, `failed`; plus `current`, `latest`, `updateAvailable`, `releaseUrl`, `notes`, `rebootRequired`.
* `status/install-candidates.json` (written by `install-list`, no `updatedAt`; the daemon goes by the file's modification time): `{"disks": [{"name": "nvme0n1", "path": "/dev/nvme0n1", "model", "serial", "transport", "removable", "sizeBytes", "partitions": [{"name", "sizeBytes", "fstype", "label", "partlabel"}], "eligible": true, "problems": [], "phrase": "ERASE ALL DATA ON nvme0n1"}]}`.
* `status/install-to-disk.json`: `state`, `step` (`checking`, `stopping`, `partitioning`, `copying`, `boot-entry`, `done`, `refused`, `failed`), `device`.
* `status/system.json`: `version`, `sshEnabled`, `autoUpdate`, `bootEntry` (refreshed after every job).
* `status/health.json`: the last boot health result.

## Files

```
mkosi.conf, mkosi.conf.d/        image definition
repart/image/                    partition layout at build time
paths.env                        daemon and web UI paths (one place)
units/camerabridged.service.in   daemon unit template
mkosi.extra/                     copied into the image (see BUILDING.md)
  etc/                           fstab, nftables.conf, sysctl, journald, networkd, avahi, chrony, sshd
  usr/lib/systemd/system/        camera-bridge-*.service/.timer/.path, data mounts, drop-ins
  usr/lib/camera-bridge/         cb-datadirs, cb-firstboot, cb-health-check, cb-update-fetch, ... lib.sh
  usr/sbin/                      cb-system, cb-update, cb-install-to-disk
  usr/lib/sysupdate.d/           A/B update definitions (root slot + UKI)
  usr/lib/repart.d/              grows the data partition on first boot
build.sh, build-image.sh         build
test-static.sh, test-vm.sh       tests
stub/                            test-only stand-in daemons
```

No custom udev rules are needed: the render node already belongs to group `render` (the unit adds it), and `usbcore.autosuspend=-1` on the kernel command line keeps a USB boot stick from being suspended.

# linux/os: Camera Bridge OS image

Build, test and release instructions: `docs/linux/BUILDING.md`. User view: `docs/linux/USER-GUIDE.md`. This file is the contract between the operating system and the daemon (`camerabridged`, written by the web/daemon work) so both sides can be built independently.

## What the OS gives the daemon

The daemon runs as user `camerabridge` (uid 931) from `camerabridged.service` (`units/camerabridged.service.in`, paths from `paths.env`):

| Environment variable | Value | Meaning |
|---|---|---|
| `CAMERABRIDGE_PLATFORM` | `linux-os` | running on Camera Bridge OS |
| `CAMERABRIDGE_DATA_DIR` | `/var/lib/camera-bridge` | the data directory (the data partition; `config.json`, `hap/`, `secrets/`, `Diagnostics/`, `recordings/`) |
| `CAMERABRIDGE_WEB_ROOT` | `/usr/share/camera-bridge/web` | static web UI files |
| `CAMERABRIDGE_HTTP_PORT` | `80` | web port (the unit grants `CAP_NET_BIND_SERVICE`) |
| `CAMERABRIDGE_RUN_DIR` | `/run/camera-bridge` | runtime folder |
| `CAMERABRIDGE_OS_REQUEST_DIR` | `/run/camera-bridge/requests` | where to drop privileged requests (below) |
| `CAMERABRIDGE_OS_STATUS_DIR` | `/run/camera-bridge/status` | where the OS publishes status files (read-only for the daemon) |

More can be set in `/etc/camera-bridge/camerabridged.env` (read by the unit if present). The unit does not set `CAMERABRIDGE_RECORDINGS_DIR`: the NVR's recordings go to `recordings` inside the data directory (`/var/lib/camera-bridge/recordings`), which the daemon creates itself as `camerabridge` (0700) and which the unit already lets it write. A recordings folder anywhere else is outside `ReadWritePaths` and would need a unit change (external drives, later).

Process requirements of the unit:

* `Type=notify`: send `READY=1` (sd_notify) once the web port is listening.
* `WatchdogSec=30`: send `WATCHDOG=1` at least every 15 s, or systemd kills and restarts the daemon. (If the daemon cannot do this, relax `WatchdogSec` in `units/camerabridged.service.in`.)
* `GET http://127.0.0.1/api/v1/status` must answer with a JSON document without authentication: `camera-bridge-health.service` uses it to decide whether a boot is good (a new OS version that fails this three times is rolled back automatically).
* Writes only to `/var/lib/camera-bridge` (recordings included: `/var/lib/camera-bridge/recordings`), `/tmp` (private) and the request folder; everything else is read-only (`ProtectSystem=strict`). `HOME=/var/lib/camera-bridge`.
* Allowed: TCP/UDP over IPv4/IPv6, Unix sockets (D-Bus for avahi's `dns_sd` compat library), netlink (`RTMGRP_*` monitoring), the GPU render node (`/dev/dri/renderD*`, group `render`). Not allowed: raw/packet sockets, namespaces, `CAP_*` other than `CAP_NET_BIND_SERVICE`.
* The secret store key is created by the OS at first boot: `/var/lib/camera-bridge/secrets/master.key` (32 random bytes, mode 0600, owner `camerabridge`). The daemon should use it (and create it itself if absent).
* `/var/lib/camera-bridge/first-run` exists (a timestamp) until the daemon decides setup is finished; the OS creates it again after a factory reset.
* The firewall allows inbound TCP 80, 443, 21100-21199, UDP 5353 (mDNS), SSH only when enabled, ICMP, answers from UDP source ports 3702/1900/37020/37810 (camera discovery) and UDP to ephemeral ports from the LAN (RTP/SRTP). DNS (TCP/UDP 53) only from the setup hotspot and from the cameras the internet guard watches (below).
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
| `factory-reset` | `{"confirm": "RESET"}` | erases `/var/lib/camera-bridge` (the recordings too), reboots |
| `drive-list` | `{}` | writes `status/recording-drive-candidates.json` (the attached disks, usable or not, and which already are recording drives) |
| `drive-use` | `{"device": "/dev/sdb", "phrase": "ERASE ALL DATA ON sdb", "keepData": false}` | records to that disk: with the phrase it is erased and gets one ext4 file system labelled `CBRECORDINGS`; with `keepData` an existing recording drive is used as it is. The drive is mounted on `/var/lib/camera-bridge/recordings` (the choice, a file-system UUID, is kept in `/srv/system/recording-drive`; a drive that is chosen but not attached is replaced by a read-only placeholder so nothing is written to the box's own disk by mistake; `camera-bridge-recording-drive.service` does it at boot, a udev rule when a `CBRECORDINGS` partition appears). Progress in `status/recording-drive.json` (`internal`, `mounted`, `missing`, `working`, `failed`) |
| `drive-forget` | `{}` | goes back to the box's own disk; the drive and its recordings are left alone |
| `wifi-scan` | `{}` | writes `status/wifi-networks.json` (the networks in range, strongest first) |
| `wifi-join` | `{"ssid": "Home", "password": "…", "reboot": true}` | saves the network (NetworkManager keyfile in `/srv/system/network-connections`) and restarts; the password is never logged. If the box is not online about 30 s after it starts, `cb-wifi --watch` reports the failure (`status/wifi.json` `lastError`) and opens the setup hotspot |
| `wifi-forget` | `{"ssid": "Home"}` | forgets a saved network |
| `install-list` | `{}` | writes `status/install-candidates.json` (the disks and why they are or are not usable) |
| `install-to-disk` | `{"device": "/dev/nvme0n1", "phrase": "ERASE ALL DATA ON nvme0n1", "copyData": true, "poweroff": true, "dryRun": false}` | copies the running system to that disk (with `copyData`, the settings and the recordings folder too). The UI must make the user type the phrase; the installer checks it again. |
| `guard-set` | `{"cameras": [{"address": "192.168.77.21", "level": "watch"}], "timeZone": "America/Los_Angeles"}` | the internet guard watches exactly these cameras (an empty list turns it off; below). Only private IPv4 (10/8, 172.16/12, 192.168/16, 169.254/16) and unique-local or link-local IPv6 (fc00::/7, fe80::/10) addresses, at most 64, level `watch` only; IPv6 is kept as dnsmasq logs it (RFC 5952). `timeZone` (optional, an IANA name; UTC when missing or unknown) is the one `today` is counted in. Kept in `/srv/system/guard/cameras.json` |

Status files (world-readable JSON written atomically by the root side; each has `state`, `message`, `updatedAt`):

* `status/<name>.json` for every request above: `queued`, `running`, then `ok` or `failed` (`install-to-disk` ends with the installer's own `ok` or `failed`, see below). A request of a job that is still running waits (a newer one replaces it) and that job runs it next; only the last run's end is written, so `ok` or `failed` always belongs to the newest request. A status file is newer than a request when its `updatedAt` is not before the second the request was written; the daemon relies on that, never on the file merely existing.
* `status/update.json`: `state` is `checking`, `available`, `current`, `downloading`, `installing`, `installed`, `failed`; plus `current`, `latest`, `updateAvailable`, `releaseUrl`, `notes`, `rebootRequired`.
* `status/install-candidates.json` (written by `install-list`, no `updatedAt`; the daemon goes by the file's modification time): `{"disks": [{"name": "nvme0n1", "path": "/dev/nvme0n1", "model", "serial", "transport", "removable", "sizeBytes", "partitions": [{"name", "sizeBytes", "fstype", "label", "partlabel"}], "eligible": true, "problems": [], "phrase": "ERASE ALL DATA ON nvme0n1"}]}`.
* `status/install-to-disk.json`: `state`, `step` (`checking`, `stopping`, `partitioning`, `copying`, `boot-entry`, `done`, `refused`, `failed`), `device`.
* `status/system.json`: `version`, `sshEnabled`, `autoUpdate`, `bootEntry` (refreshed after every job).
* `status/health.json`: the last boot health result.
* `status/guard.json` (written by `cb-guard` after every `guard-set`, at boot and every minute while a camera is watched; at most about 900 KB; mode 0640, group `camerabridge`: only the daemon reads it, since a name can carry a camera's cloud id): `{"available": true, "running": true, "timeZone": "UTC", "todayStart": "2026-10-17T00:00:00Z", "cameras": [{"address": "192.168.77.21", "level": "watch", "since": "2026-10-16T09:00:00Z", "today": 47, "last24h": 51, "names": [{"name": "p2p.example.com", "count": 47, "first": "2026-10-17T08:00:01Z", "last": "2026-10-17T17:46:01Z"}]}]}`. `running`: the DNS for watched cameras answers now. `since`: watched without a break since then, the latest of when its address was put on the list (a list sent again keeps it; an address taken off and put back begins again), when the history started again, and, while the DNS runs, when it last started. `today` counts lookups since local midnight in `timeZone` (`todayStart`, to the hour), `last24h` those of the last 24 hours (to the hour); `names` are the last 7 days' names, most asked first, at most 50 (fewer when the file would be too large). Questions that never leave the home network are neither counted nor named: single-label names, names under `.local`, `.lan`, `.home.arpa`, `.localdomain`, `.internal` and `.localhost`, reverse lookups of local addresses (10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, fc00::/7, fe80::/10) and questions about the DNS server itself (`version.bind` and the like). Only watched cameras are listed. Names, addresses, counts and times only.

## The internet guard (Watch)

A watched camera's DNS server is the box (the engine's setup step sets it). `camera-bridge-dns.service` runs `dnsmasq` (from `dnsmasq-base`, as user `dnsmasq` with only `CAP_NET_BIND_SERVICE`) with the configuration `cb-guard dns-prepare` writes to `/run/camera-bridge/guard/dnsmasq.conf` (`cb-guard config` prints it): it listens on the box's wired and Wi-Fi interfaces (`interface=en*`, `eth*`, `wl*`, never `lo`, so systemd-resolved keeps 127.0.0.53; `bind-dynamic` follows a changed address), asks nobody (`no-resolv`, `no-hosts`, no cache), answers every name "does not exist" (`address=/#/`, NXDOMAIN) and logs each question with the camera's address to `/run/camera-bridge/guard/log/queries.log` (in memory). The firewall's sets `guarded4`/`guarded6` hold the watched addresses and are the only way in to port 53 besides the setup hotspot on the Wi-Fi (`iifname "wl*"`, so a home network that uses 10.42.0.0/24 reaches no DNS here), so the box is never a resolver for the house; at most 50 questions a second from each address (a burst of 200; 10 new TCP connections a second), the rest dropped, so a host pretending to be a watched camera cannot fill `/run` with the log between two collections. While the setup hotspot is open (`/run/camera-bridge/hotspot-open`, set by `cb-wifi`) the server does not run: NetworkManager's own dnsmasq answers the phones on 10.42.0.1.

`cb-guard` (root) does the rest: `set` (the `guard-set` job) checks the list again and keeps it; `apply` fills the sets and starts the DNS and `camera-bridge-guard-collect.timer` while a camera is watched, else stops them (`camera-bridge-guard.service` at boot, after the firewall, and again when nftables is reloaded or restarted); `collect` (that timer, every minute; `TimeoutStartSec=5min`, since it holds the guard's lock) moves the query log into `/run/camera-bridge/guard/work` (root only, so dnsmasq cannot swap it afterwards), reads it only when it is a plain file dnsmasq owns (a FIFO, a link or a folder is removed unread) and within 120 s, has dnsmasq open a new one (SIGUSR2), adds it to `/srv/system/guard/history.json` (hourly counts per camera and name, 7 days, at most 40 names per camera and hour, the rest only counted, at most 4 MB) and writes `status/guard.json`. A camera no longer watched is dropped from the history; a factory reset removes `/srv/system/guard`. `cameras.json` keeps each address's `since` (epoch seconds). A `guard-set` that arrives while the last one still runs waits in `jobs/guard-set.json` and the running job runs it next (its start merged into that job), reporting only the last one's end; the daemon takes the list as done only when `status/guard.json` lists exactly its cameras. Nothing is forwarded or logged by the firewall yet (that is Seal, the next stage). Self-test: `bash linux/os/test-guard.sh`.

## Files

```
mkosi.conf, mkosi.conf.d/        image definition
repart/image/                    partition layout at build time
paths.env                        daemon, web UI and helper paths (one place)
units/camerabridged.service.in   daemon unit template
mkosi.extra/                     copied into the image (see BUILDING.md)
  etc/                           fstab, nftables.conf, sysctl, journald, networkd, avahi, chrony, sshd
  usr/lib/systemd/system/        camera-bridge-*.service/.timer/.path, data mounts, drop-ins
  usr/lib/camera-bridge/         cb-datadirs, cb-firstboot, cb-health-check, cb-update-fetch, ... lib.sh
  usr/sbin/                      cb-system, cb-update, cb-install-to-disk, cb-wifi, cb-recording-drive, cb-guard
  usr/lib/sysupdate.d/           A/B update definitions (root slot + UKI)
  usr/lib/repart.d/              grows the data partition on first boot
build.sh, build-image.sh         build
fetch-go2rtc.sh                  builds the go2rtc helper (pinned commit and checksums)
build-helpers.sh                 builds our own helpers wyze-lake and eufy-bridge from ../helpers
test-static.sh, test-vm.sh       tests (test-guard.sh, test-prune-betas.sh, test-nvr.py: self-tests the static job runs)
stub/                            test-only stand-in daemons
```

No custom udev rules are needed: the render node already belongs to group `render` (the unit adds it), and `usbcore.autosuspend=-1` on the kernel command line keeps a USB boot stick from being suspended.

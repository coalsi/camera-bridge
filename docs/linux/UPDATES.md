# Camera Bridge OS: updates and rollback

Camera Bridge OS updates the whole system as one unit, and keeps the previous version until the new one has proven itself. A bad update can not leave you with a box that does not start: when the new version does not come up healthy, the box restarts by itself until its three tries are used up (about a quarter of an hour), starts the previous version again and never offers the failed one again.

## What is on the disk

```
 1  boot partition (ESP, 512 MB, FAT)     systemd-boot + one unified kernel image (UKI) per installed version
 2  root A (2.5 GB, read-only)            system version N
 3  root B (2.5 GB, read-only)            empty, or the other version
 4  data (the rest of the disk)           settings, HomeKit pairings, secrets, logs, recordings; updates never touch it
```

A version consists of two files: the root file system image (`cb-root_<version>` is the label of the partition it lives in) and the UKI `cb-os_<version>.efi` (kernel, initrd and the kernel command line `root=PARTLABEL=cb-root_<version>`). Because each UKI names its own root partition by label, booting entry N always uses root N, whichever slot (A or B) it was written to.

## An update, step by step

1. **Look.** `camera-bridge-update.timer` runs 20 minutes after boot and then daily (a random delay of up to two hours is added). It asks GitHub for the newest release whose tag starts with `os-v` (tags starting with `v` are the Mac app): a box on a beta (0.x) takes the newest beta (pre-release), from 1.0 on only full releases. Nothing is downloaded if you already have that version or a newer one, if that version is installed already and waits for the restart (the page keeps saying "restart to use it"), or if that version did not start on this box before (step 7). Installing takes the lock of the system jobs, so the daily run and "Update now" never write at once.
2. **Download, unprivileged.** If automatic updates are on, or you press "Update now" in the web UI (or run `cb-update apply`), the files are fetched by a separate user (`cbupdate`) in a sandbox that can write only its own cache folder on the data partition. Fetched: `SHA256SUMS`, `SHA256SUMS.sig`, `cb-os_<version>_<arch>.efi`, `cb-os_<version>_<arch>_root.raw.zst`.
3. **Verify, twice.** The list `SHA256SUMS` carries a [minisign](https://jedisct1.github.io/minisign/) signature made with the private release key. The matching public key is part of the system image (`/usr/share/camera-bridge/update-key.pub`). The downloader checks the signature and every file's SHA-256; then the root-privileged step checks everything again while copying the files into a staging folder only root can read, hashing the same bytes it writes, so a file cannot change between check and use. Any mismatch stops the update with nothing written.
4. **Write to the idle slot.** `systemd-sysupdate` writes the new root image into the slot that is *not* running (never the one you are using) and puts the new UKI on the boot partition as `cb-os_<version>+3.efi`. The `+3` means "three boot attempts left".
5. **Restart.** The new version starts at the next restart (immediately if you choose "restart now"; with automatic updates the box restarts by itself at 03:00 in the bridge's time zone, `settings.timeZone` in config.json, else UTC; systemd's own `systemd-sysupdate` and `systemd-sysupdate-reboot` timers are masked, cb-update does all of it). systemd-boot lowers the counter at every attempt (`+3` -> `+2-1` -> `+1-2` -> `+0-3`).
6. **Prove itself.** `camera-bridge-health.service` is required by `boot-complete.target` (it only runs on a boot with a try counter). It passes when `camerabridged`'s `http://127.0.0.1/api/v1/health` says the bridge runs (200 `{"ok": true}`; it answers 503 while the engine starts and for good when the engine cannot start, so the check keeps asking for up to 4 minutes), still says so a minute later without the daemon having been restarted once on this boot, `avahi-daemon` is running and the data partition accepts writes. Only then `systemd-bless-boot` renames the entry to plain `cb-os_<version>.efi`: the new version is permanent. (On a version that is kept, a daemon that crashes is simply restarted, with pauses of 3 s growing to 2 minutes while it keeps crashing; it is never given up on.)
7. **Or fall back.** If the health check does not pass, the box restarts by itself at once (`cb-health-check --after-failure`, the service's ExecStopPost, also after a check that hangs), so nobody has to switch it off and on; a kernel that hangs is restarted by the watchdog. After three attempts the counter is zero and systemd-boot starts the previous version again, which is still intact. The failed entry stays on the boot partition marked `+0-3` until the next update replaces it. At that boot `cb-update boot` (`camera-bridge-update-boot.service`) sees it, remembers the version in `/srv/system/update-failed` and reports it: `update.json` says `{"state": "rolled-back", "failedVersion": ...}` with the sentence "Version X did not start properly, so the box went back to version Y by itself", and the System API carries it as `update.failedVersion`. That version is never offered again; the next one is. When the only version on the box fails (a first install), the box stays up instead of restarting in a loop.

A box that is simply offline (no cable) still counts as healthy: only the local daemon is checked.

## Power loss during an update

The running system is never written, so power loss during download or while writing the idle slot leaves you on the current version. A half-written idle slot is not used: its UKI is only added after the root image is complete, and an incomplete entry is unbootable at worst and is skipped after its three tries.

## Checking and controlling updates

In the web UI: System (installed version, update available, automatic updates on/off, "Update now"). From SSH (see the user guide for enabling SSH):

```
cb-update status       # last result (JSON)
cb-update check        # ask GitHub now
cb-update apply        # download, verify, install into the idle slot (then restart)
cat /srv/system/update-failed   # versions that did not start on this box (never offered again)
cb-system auto-update on|off
bootctl status         # shows which entry booted ("Current Entry") and the boot counters
ls "$(bootctl --print-esp-path)/EFI/Linux"
```

## Going back by hand

At power-on, hold or tap the **Space** key (some firmwares: Shift) while systemd-boot appears: it shows a menu with every installed version. Choose the older one for this boot. To make it permanent, install the version you want as a new release (a release with a higher number), or reflash. Older versions are only kept as long as two versions fit (two root slots).

## Releases

Each `os-v<version>` GitHub Release contains:

| File | For |
|---|---|
| `camera-bridge-os-<version>-<arch>.img.xz` (+ `.sha256`, `.sig`) | flashing a new stick or SSD |
| `SHA256SUMS`, `SHA256SUMS.sig` | signed list of every file in the release |
| `cb-os_<version>_<arch>.efi` | the UKI used by updates |
| `cb-os_<version>_<arch>_root.raw.zst` | the root image used by updates |

Version numbers are digits and dots (`0.1`, `0.2`, `1.0.1`); the newer number wins. Drafts are ignored by the updater; pre-releases only by a box on 1.0 or later (a box on a 0.x beta takes them).

## Limits to know

* An update needs about 4 GB free on the data partition (download + staging) and two root slots of 2.5 GB. Use a disk of at least 16 GB.
* Recordings share the data partition. Recording pauses while free space is below 8 GiB or 5% of the partition, whichever is more, which is well above the 4 GB an update needs, so recording leaves room for updates (user guide, section 11).
* Secure Boot is not supported (the boot loader and the kernel images are not signed with a key your firmware knows). Turn Secure Boot off in the firmware.
* Updates are fetched over HTTPS from `api.github.com` and `github.com`. If your network blocks them, update by flashing a new image; settings on the data partition are kept only if you install over the same disk with the installer (otherwise export them first).
* A new version is only as safe as its release key: keep the private key offline. See BUILDING.md, "Release signing".

## What has and has not been tested

Tested in a virtual machine (QEMU, arm64 build, UEFI): update check, refusal of a tampered signature and of a tampered file (nothing is written), update into the idle slot, restart into the new version, blessing, and the automatic fall-back after three failed boots of a deliberately broken version, the box restarting itself each time (test-vm.sh waits for it to come back on the previous version, then checks that the failed version is remembered, reported and not offered again). The health check's restart decision, the rollback memory, the waiting update and the lock are covered without a VM by `linux/os/test-update.sh`. Not tested on real hardware, and not yet with a release downloaded from GitHub (the VM test uses a local stand-in for the GitHub API with the same JSON). See BUILDING.md.

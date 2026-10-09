# Camera Bridge OS: updates and rollback

Camera Bridge OS updates the whole system as one unit, and keeps the previous version until the new one has proven itself. A bad update can not leave you with a box that does not start: it falls back by itself.

## What is on the disk

```
 1  boot partition (ESP, 512 MB, FAT)     systemd-boot + one unified kernel image (UKI) per installed version
 2  root A (2.5 GB, read-only)            system version N
 3  root B (2.5 GB, read-only)            empty, or the other version
 4  data (the rest of the disk)           settings, HomeKit pairings, secrets, logs; updates never touch it
```

A version consists of two files: the root file system image (`cb-root_<version>` is the label of the partition it lives in) and the UKI `cb-os_<version>.efi` (kernel, initrd and the kernel command line `root=PARTLABEL=cb-root_<version>`). Because each UKI names its own root partition by label, booting entry N always uses root N, whichever slot (A or B) it was written to.

## An update, step by step

1. **Look.** `camera-bridge-update.timer` runs 20 minutes after boot and then daily (a random delay of up to two hours is added). It asks GitHub for the newest *stable* release whose tag starts with `os-v` (tags starting with `v` are the Mac app). Nothing is downloaded if you already have that version or a newer one.
2. **Download, unprivileged.** If automatic updates are on, or you press "Update now" in the web UI (or run `cb-update apply`), the files are fetched by a separate user (`cbupdate`) in a sandbox that can write only its own cache folder on the data partition. Fetched: `SHA256SUMS`, `SHA256SUMS.sig`, `cb-os_<version>_<arch>.efi`, `cb-os_<version>_<arch>_root.raw.zst`.
3. **Verify, twice.** The list `SHA256SUMS` carries a [minisign](https://jedisct1.github.io/minisign/) signature made with the private release key. The matching public key is part of the system image (`/usr/share/camera-bridge/update-key.pub`). The downloader checks the signature and every file's SHA-256; then the root-privileged step checks everything again while copying the files into a staging folder only root can read, hashing the same bytes it writes, so a file cannot change between check and use. Any mismatch stops the update with nothing written.
4. **Write to the idle slot.** `systemd-sysupdate` writes the new root image into the slot that is *not* running (never the one you are using) and puts the new UKI on the boot partition as `cb-os_<version>+3.efi`. The `+3` means "three boot attempts left".
5. **Restart.** The new version starts at the next restart (immediately if you choose "restart now"; with automatic updates the box restarts by itself at 03:00 UTC). systemd-boot lowers the counter at every attempt (`+3` -> `+2-1` -> `+1-2` -> `+0-3`).
6. **Prove itself.** `camera-bridge-health.service` is required by `boot-complete.target`. It passes when `camerabridged` answers on `http://127.0.0.1/api/v1/status` with valid JSON, `avahi-daemon` is running and the data partition accepts writes. Only then `systemd-bless-boot` renames the entry to plain `cb-os_<version>.efi`: the new version is permanent.
7. **Or fall back.** If the health check never passes (the daemon crashes, the system hangs or is powered off in the middle), the counter reaches zero after three attempts and systemd-boot starts the previous version again, which is still intact. The failed entry stays on the boot partition marked `+0-3` until the next update replaces it.

A box that is simply offline (no cable) still counts as healthy: only the local daemon is checked.

## Power loss during an update

The running system is never written, so power loss during download or while writing the idle slot leaves you on the current version. A half-written idle slot is not used: its UKI is only added after the root image is complete, and an incomplete entry is unbootable at worst and is skipped after its three tries.

## Checking and controlling updates

In the web UI: System (installed version, update available, automatic updates on/off, "Update now"). From SSH (see the user guide for enabling SSH):

```
cb-update status       # last result (JSON)
cb-update check        # ask GitHub now
cb-update apply        # download, verify, install into the idle slot (then restart)
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

Version numbers are digits and dots (`0.1`, `0.2`, `1.0.1`); the newer number wins. Pre-releases and drafts are ignored by the updater.

## Limits to know

* An update needs about 4 GB free on the data partition (download + staging) and two root slots of 2.5 GB. Use a disk of at least 16 GB.
* Secure Boot is not supported (the boot loader and the kernel images are not signed with a key your firmware knows). Turn Secure Boot off in the firmware.
* Updates are fetched over HTTPS from `api.github.com` and `github.com`. If your network blocks them, update by flashing a new image; settings on the data partition are kept only if you install over the same disk with the installer (otherwise export them first).
* A new version is only as safe as its release key: keep the private key offline. See BUILDING.md, "Release signing".

## What has and has not been tested

Tested in a virtual machine (QEMU, arm64 build, UEFI): update check, refusal of a tampered signature and of a tampered file (nothing is written), update into the idle slot, restart into the new version, blessing, and the automatic fall-back after three failed boots of a deliberately broken version. Not tested on real hardware, and not yet with a release downloaded from GitHub (the VM test uses a local stand-in for the GitHub API with the same JSON). See BUILDING.md.

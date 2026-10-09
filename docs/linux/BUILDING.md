# Building and testing Camera Bridge OS

Everything for the operating system image lives in `linux/os/` (and `.github/workflows/os-image.yml`). The image is built from Debian 13 "trixie" with [mkosi](https://github.com/systemd/mkosi); the engine daemon `camerabridged` is built as a static Swift binary and copied in.

## Quick start

Needs only Docker (Docker Desktop, OrbStack, or `docker.io` on Linux). Roughly 20 GB of free disk space for caches.

```
linux/os/build.sh --version 0.1 --stub-daemon        # OS only, with a tiny stand-in for the daemon (for testing the OS)
linux/os/build.sh --version 0.1                      # also builds camerabridged with Swift in a container
linux/os/build.sh --version 0.1 --arch arm64         # arm64 (development target; native on Apple Silicon)
```

Results are in `linux/os/out/`:

```
camera-bridge-os-0.1-amd64.img.xz          the disk image to flash
camera-bridge-os-0.1-amd64.img.xz.sha256
camera-bridge-os-0.1-amd64.img.xz.sig      minisign signature (only if a signing key was given)
SHA256SUMS, SHA256SUMS.sig                 signed list over all files (what the in-system updater verifies)
cb-os_0.1_amd64.efi                        unified kernel image (update artifact)
cb-os_0.1_amd64_root.raw.zst               root file system image (update artifact)
```

Build the architecture of the machine you are on. On Linux x86-64 (and in GitHub Actions) that is amd64. On an Apple Silicon Mac only `--arch arm64` works: mkosi needs the `mount_setattr()` system call, which Docker's x86 emulation (Rosetta) does not implement; `build.sh` stops with an explanation if you ask for amd64 there. This was tried and fails.

When you are done, `linux/os/build.sh --clean` removes the Docker volumes (`cb-os-*`) and builder images this created.

## How it fits together

| Path | What |
|---|---|
| `linux/os/Dockerfile.builder` | the build container (Debian 13 with the same mkosi / systemd the image uses) |
| `linux/os/build.sh` | host side: builds the daemon (`swift build -c release --static-swift-stdlib --build-system native` in the `swift:6.4-noble` image plus the Avahi, curl and libxml2 development packages), starts the builder container |
| `linux/os/build-image.sh` | inside the container: stages files, runs mkosi, cuts the update artifacts, compresses, hashes, signs |
| `linux/os/paths.env` | **where the daemon and the web UI live in the image** (`CB_DAEMON`, `CB_WEB_ROOT`); `units/camerabridged.service.in` is rendered with these |
| `linux/os/mkosi.conf`, `mkosi.conf.d/` | the image definition (packages, boot loader, kernel command line) |
| `linux/os/repart/image/` | partition layout used when building (`@VERSION@` becomes the root slot's label) |
| `linux/os/mkosi.extra/` | files copied into the image: units, scripts, firewall, sysctl, network, `usr/lib/repart.d` (first-boot growth), `usr/lib/sysupdate.d` (A/B update definitions) |
| `linux/os/mkosi.postinst.chroot`, `mkosi.finalize` | enables units, masks what must not run, os-release |
| `linux/os/stub/` | test-only stand-in daemons (`--stub-daemon`, `--stub-broken`) |
| `linux/os/test-static.sh`, `test-vm.sh` | the tests below |
| `linux/os/README.md` | the contract between the OS and the daemon (environment variables, request files) |

The daemon is installed to `/usr/bin/camerabridged` and the web UI (`linux/web/`, if present) to `/usr/share/camera-bridge/web`; change both in `paths.env` only.

## Release signing

Updates are verified inside the running system with [minisign](https://jedisct1.github.io/minisign/), using a public key baked into the image. The repository contains only a placeholder public key (`linux/os/mkosi.extra/usr/share/camera-bridge/update-key.pub`); an image built with the placeholder refuses to update, and `--release` refuses to build with it.

One-time setup, on a trusted machine (not in CI):

```
minisign -G -p camera-bridge-os.pub -s camera-bridge-os.key      # choose a password, or add -W for none
```

1. Commit the **public** key as `linux/os/mkosi.extra/usr/share/camera-bridge/update-key.pub` (two lines).
2. Store the **secret** key file's content in the GitHub repository secret `MINISIGN_SECRET_KEY` (and its password, if any, in `MINISIGN_PASSWORD`). Keep an offline backup of the secret key. If it is lost, no existing box can be updated again (they would need a reflash); if it leaks, anyone can ship an update to every box.
3. Tag `os-v0.1` and push the tag. The workflow builds, signs, boot-tests and publishes the release.

Local signed build: `MINISIGN_SECRET_KEY="$(cat camera-bridge-os.key)" MINISIGN_PASSWORD=... linux/os/build.sh --version 0.1 --release`. The key is passed to the container through the environment and is never written to `out/` or printed.

Verify a release by hand: `minisign -V -p camera-bridge-os.pub -m SHA256SUMS -x SHA256SUMS.sig && sha256sum -c SHA256SUMS`.

## The GitHub Actions workflow

`.github/workflows/os-image.yml`: on tags `os-v*` and manual dispatch it runs the static checks, builds the amd64 image, boots it in QEMU (with KVM when the runner has it), and on tags creates the release `os-v<version>` with the `.img.xz`, `.sha256`, `.sig`, `SHA256SUMS(.sig)` and the two update files. Action versions are pinned by commit SHA (read from the GitHub API for `actions/checkout` v4.2.2, `actions/upload-artifact` v4.6.2, `actions/download-artifact` v4.3.0); the release is created with the preinstalled `gh` CLI, so no third-party action is used. The workflow itself has **not been run on GitHub** yet; it was written alongside the scripts it calls, which were run locally.

## Tests

### Static checks (no VM, about a minute)

```
linux/os/test-static.sh
```

Runs in a throw-away Debian 13 container: `bash -n` and `shellcheck` on every script, `nft -c -f` on the firewall, `systemd-analyze verify` on every unit, `systemd-sysusers`/`systemd-tmpfiles`/`systemd-repart --dry-run` on the definitions, `mkosi summary` for amd64 and arm64, and the installer's argument checks.

### Boot test in QEMU

```
linux/os/test-vm.sh --image linux/os/out/camera-bridge-os-0.1-arm64.img.xz
```

Needs `qemu-system-*`, UEFI firmware (Linux: `ovmf`, `qemu-efi-aarch64`; macOS: Homebrew `qemu` ships it), `ssh`, `curl`. It uses KVM on Linux, HVF for arm64 on Apple Silicon, and plain emulation otherwise (slow: the wait limit rises to 30 minutes). It never touches a real disk; all disks are files in a scratch folder. What it does:

1. First boot of the 16 GB virtual disk without credentials: the web UI answers, SSH is off.
2. Second boot with an SSH key given as a systemd credential (`cb.ssh.authorized_keys` through SMBIOS/fw_cfg), then the checks: root read-only, volatile `/var`, 4 partitions with the data partition grown, hostname, firewall default-deny, port 80, daemon user, avahi announcing `camera-bridge.local`, DHCP, zram swap and no other swap, boot entry blessed, secrets key, no failed units.
2b. `daemon` (only with an image that has the real `camerabridged`, skipped for `--stub-daemon`): the service is `Type=notify` and active with the 30 s watchdog armed, never restarted, still the same process 45 s later (so `WATCHDOG=1` arrives), it listens on port 80 and found the request folder from the `CAMERABRIDGE_*` variables, `GET /api/v1/status` answers without sign-in, the web UI is served, the boot health check passes, the OS-made secrets key is left alone, and through the web API (first-run setup, then `POST /api/v1/system/update` and `/system/auto-update`) the requests reach the root helper and come back with its status. The sandbox must not produce permission errors in the daemon's log.
3. Reboot persistence (data, secrets key, persistent journal).
4. The request channel from the daemon user: accepted names run, unknown names / symlinks / non-JSON are discarded, the daemon user cannot write the system folder or read the SSH folder.
5. Factory reset through the marker file on the boot partition.
6. The installer on a second virtual disk: `--list`, refusal of the boot disk and of a partition, `--dry-run` writes nothing, wrong phrase and missing confirmation write nothing, real install with `--copy-data`; then the installed disk alone is booted and the copied data checked.

### Update and rollback test

Build three versions with the **same test key**, and tell the test where the newer ones are:

```
minisign -G -W -p test.pub -s test.key
export MINISIGN_SECRET_KEY="$(cat test.key)"
linux/os/build.sh --arch arm64 --stub-daemon --pubkey test.pub --version 0.1 --out out-0.1
linux/os/build.sh --arch arm64 --stub-daemon --pubkey test.pub --version 0.2 --out out-0.2
linux/os/build.sh --arch arm64 --stub-broken --pubkey test.pub --version 0.3 --out out-0.3
linux/os/test-vm.sh --image out-0.1/camera-bridge-os-0.1-arm64.img.xz --tests update \
    --update-dir out-0.2 --broken-dir out-0.3
```

The test serves the releases from a local stand-in for the GitHub API (the same JSON: `tag_name`, `assets[].browser_download_url`) and checks: the update is found; a corrupted signature and a corrupted kernel image are both refused with nothing written to the boot partition or the idle slot; the good update is installed with 3 tries; the next boot runs the new version and blesses it; installing the broken 0.3 (a daemon that exits at once) leads to three boots of 0.3 and then an automatic return to 0.2.

## What has been verified, and what has not

Verified by running it (macOS host, Docker/OrbStack for the builds, QEMU 11 with HVF for the VM):

* Static checks pass (`linux/os/test-static.sh`).
* The **arm64** image builds with `build.sh`/`build-image.sh` and boots in a UEFI VM; all VM tests above pass, including the A/B update, the refusal of tampered updates and the automatic rollback.

Not verified here:

* **Booting on real hardware**, USB boot on actual mini PCs, UEFI quirks, hardware video encoding (VA-API), firmware loading, the hardware watchdog, power-loss behaviour.
* **The amd64 image: it has never been built or booted by this project's tests.** The configuration is the same as arm64 except for the kernel and driver packages (`linux-image-amd64`, `intel-media-va-driver`, both checked to exist in Debian 13 amd64) and the serial console device, and `mkosi summary` parses it; but the amd64 build could not be run on the Apple Silicon development Mac (see above). The first amd64 build will be the GitHub Actions run.
* **The real daemon:** the daemon (`camerabridged`) did not exist when this was written. All tests use the stub daemon, which implements only what the OS needs (listen on port 80, `/api/v1/status`, `sd_notify` READY and WATCHDOG). The daemon must follow the contract in `linux/os/README.md` (in particular: send `WATCHDOG=1`, or the unit restarts it every 30 s).
* The GitHub Actions workflow on GitHub, and a release downloaded from GitHub by the updater (the API stand-in is used instead).
* Building `camerabridged` with Swift inside `build.sh` (the step is written but untested because the daemon target does not exist yet).
* Secure Boot is not supported by design.

## Disk space and cleanup

A build uses several GB in Docker volumes (`cb-os-work`: the mkosi cache and image, `cb-os-swift-<arch>`: Swift build cache). `linux/os/build.sh --clean` removes them. The VM test uses a few GB in its scratch folder, deleted at the end unless `--keep`.

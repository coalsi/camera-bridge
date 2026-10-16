# Building and testing Camera Bridge OS

Everything for the operating system image lives in `linux/os/` (and `.github/workflows/os-image.yml`). The image is built from Debian 13 "trixie" with [mkosi](https://github.com/systemd/mkosi); the engine daemon `camerabridged` is built as a static Swift binary and copied in, and so is the go2rtc streaming helper, built with Go from a pinned commit.

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
| `linux/os/build.sh` | host side: builds the daemon (`swift build -c release --static-swift-stdlib --build-system native` in the `swift:6.4.0-noble` image (pinned: 6.4.1 made the daemon use ~70% more CPU) plus the Avahi, curl and libxml2 development packages), starts the builder container |
| `linux/os/fetch-go2rtc.sh` | host side, run by `build.sh`: builds the go2rtc helper (below) into `build/os-helpers/<arch>/` |
| `linux/os/build-image.sh` | inside the container: stages files, runs mkosi, cuts the update artifacts, compresses, hashes, signs |
| `linux/os/paths.env` | **where the daemon, the web UI and the helpers live in the image** (`CB_DAEMON`, `CB_WEB_ROOT`, `CB_HELPERS_DIR`); `units/camerabridged.service.in` is rendered with these |
| `linux/os/mkosi.conf`, `mkosi.conf.d/` | the image definition (packages, boot loader, kernel command line) |
| `linux/os/repart/image/` | partition layout used when building (`@VERSION@` becomes the root slot's label) |
| `linux/os/mkosi.extra/` | files copied into the image: units, scripts, firewall, sysctl, network, `usr/lib/repart.d` (first-boot growth), `usr/lib/sysupdate.d` (A/B update definitions) |
| `linux/os/mkosi.postinst.chroot`, `mkosi.finalize` | enables units, masks what must not run, os-release |
| `linux/os/stub/` | test-only stand-in daemons (`--stub-daemon`, `--stub-broken`) |
| `linux/os/test-static.sh`, `test-vm.sh` | the tests below |
| `linux/os/README.md` | the contract between the OS and the daemon (environment variables, request files) |

The daemon is installed to `/usr/bin/camerabridged` and the web UI (`linux/web/`, if present) to `/usr/share/camera-bridge/web`; change both in `paths.env` only.

### The go2rtc helper

The engine starts [go2rtc](https://github.com/AlexxIT/go2rtc) (MIT) for the cameras it cannot reach itself (Wyze's own protocol, Ring, Nest, Tuya). The image has it at `/usr/lib/camera-bridge/helpers/go2rtc` (`CB_HELPERS_DIR`, one of the folders `PlatformLinux`'s `ProcessHelperLauncher` searches), `0755 root:root`, with its licence at `/usr/share/doc/go2rtc/copyright`.

`linux/os/fetch-go2rtc.sh --arch amd64|arm64` builds it; `build.sh` runs it before the image and mounts the result into the builder container (`build-image.sh --helpers`; `--release` refuses to build without it). It is built from a pinned commit of go2rtc's master (`GO2RTC_COMMIT`, at present `c245815e75e2`, which reports `1.9.14+dev.c245815`), not the v1.9.14 release binary, because the native Wyze source (`pkg/tutk`, `pkg/wyze`) was fixed after that release. The script:

* fetches exactly that commit with git (and checks `git rev-parse HEAD`), downloads the Go modules and checks them against `go.sum` (`go mod verify`);
* builds in the official Go image pinned by digest (`golang:1.25.14-bookworm@sha256:3b4a…`), running on the machine's own architecture and cross-compiling with `GOARCH`, so there is no emulation on an Apple Silicon Mac: `CGO_ENABLED=0 go build -trimpath -buildvcs=true -ldflags "-s -w -buildid="`;
* accepts the binary only if its SHA-256 equals the one pinned for that architecture (and the same for the `LICENSE` file). The build is reproducible: the same bytes on an Apple Silicon Mac and on x86-64 (checked 2026-10-15). A mismatch installs nothing.

The result is kept in `build/os-helpers/<arch>/` (`go2rtc`, `go2rtc.LICENSE`, `go2rtc.version`); a later build that finds a file with the pinned checksum reuses it. The Go caches are in the Docker volume `cb-os-go` (removed by `build.sh --clean`). The first build takes about a minute; the binary is about 19 MB for amd64 (18 MB for arm64), stripped, not UPX-packed. `--verify` checks the kept file without building, and `--test` also runs go2rtc's own tests and `go vet` of `pkg/tutk`, `pkg/wyze` and `internal/wyze` (only `pkg/tutk` has tests; they pass at the pinned commit).

To move to another go2rtc commit: change `GO2RTC_COMMIT` and `GO2RTC_VERSION` in the script, run it (it prints the new checksum on the mismatch), build on a second machine of the other architecture and compare, set the checksums, run with `--test`, and update `docs/third-party/go2rtc.md`, `NOTICE`, `THIRD_PARTY_LICENSES.md`, `docs/linux/LICENSES.md` and `linux/os/SOURCE-OFFER.txt.in`. The macOS app's go2rtc is separate (`Tools/fetch-go2rtc.sh`, the v1.9.14 release).

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

`.github/workflows/os-image.yml`: on tags `os-v*` and manual dispatch it runs the static checks (and the offline self-test of the NVR test client), builds the amd64 image, boots it in QEMU (with KVM when the runner has it), and on tags creates the release `os-v<version>` with the `.img.xz`, `.sha256`, `.sig`, `SHA256SUMS(.sig)` and the two update files. Action versions are pinned by commit SHA (read from the GitHub API for `actions/checkout` v4.2.2, `actions/upload-artifact` v4.6.2, `actions/download-artifact` v4.3.0); the release is created with the preinstalled `gh` CLI, so no third-party action is used.

The workflow has run on GitHub since 2026-10-09. On the standard Ubuntu 24.04 runners `/dev/kvm` is available; the build job (camerabridged with Swift, then the image) takes 14 to 21 minutes (14 for the run of 2026-10-10, 21 and 21 for the two runs of 2026-10-11) and the original boot test (boot, ssh-off, system, persist, requests, factory-reset, installer, install-boot: 61 checks) about 3 minutes. With the three nvr tests (32 GB disk, up to 4 CPUs) the whole boot test takes about 10 minutes.

A build for testing that publishes nothing: run the workflow by hand (Actions > Camera Bridge OS image > Run workflow, or `gh workflow run os-image.yml -R OWNER/REPO -f version=0.1.90 -f stub_daemon=false`). The version is digits and dots; a manual run never creates a release, it keeps the files as the artifact `camera-bridge-os-<version>-amd64` for 14 days (`gh run download RUN_ID -n camera-bridge-os-0.1.90-amd64`). The input `smoke_tests` picks tests of the list below (empty: all). A failed boot test uploads the serial log, the QEMU log and the NVR diagnostics as the artifact `smoke-logs-<version>` for 7 days.

## Tests

### Static checks (no VM, about a minute)

```
linux/os/test-static.sh
```

Runs in a throw-away Debian 13 container: `bash -n` and `shellcheck` on every script, the go2rtc pins (a full commit hash, a version, the Go image by digest, 64-hex checksums for amd64, arm64 and the licence; `CB_HELPERS_DIR` is a folder the engine searches), `nft -c -f` on the firewall, `systemd-analyze verify` on every unit, `systemd-sysusers`/`systemd-tmpfiles`/`systemd-repart --dry-run` on the definitions, `mkosi summary` for amd64 and arm64, and the installer's argument checks.

### Boot test in QEMU

```
linux/os/test-vm.sh --image linux/os/out/camera-bridge-os-0.1-arm64.img.xz
```

Needs `qemu-system-*`, UEFI firmware (Linux: `ovmf`, `qemu-efi-aarch64`; macOS: Homebrew `qemu` ships it), `ssh`, `curl`. It uses KVM on Linux, HVF for arm64 on Apple Silicon, and plain emulation otherwise (slow: the wait limit rises to 30 minutes). It never touches a real disk; all disks are files in a scratch folder. What it does:

1. First boot of the 16 GB virtual disk without credentials: the web UI answers, SSH is off.
2. Second boot with an SSH key given as a systemd credential (`cb.ssh.authorized_keys` through SMBIOS/fw_cfg), then the checks: root read-only, volatile `/var`, 4 partitions with the data partition grown, hostname, firewall default-deny, port 80, daemon user, avahi announcing `camera-bridge.local`, DHCP, zram swap and no other swap, boot entry blessed, secrets key, no failed units.
2b. `daemon` (the workflow runs it; only with an image that has the real `camerabridged`, skipped for `--stub-daemon`): the service is `Type=notify` and active with the 30 s watchdog armed, never restarted, still the same process 45 s later (so `WATCHDOG=1` arrives), it listens on port 80 and found the request folder from the `CAMERABRIDGE_*` variables, `GET /api/v1/status` answers without sign-in, the web UI is served, the boot health check passes, the OS-made secrets key is left alone, and through the web API (first-run setup, then `POST /api/v1/system/update` and `/system/auto-update`) the requests reach the root helper and come back with its status. The sandbox must not produce permission errors in the daemon's log.
3. Reboot persistence (data, secrets key, persistent journal). (In the script this test runs before `daemon`.)
3b. The NVR (recording to the data partition, see "The nvr tests" below): `nvr`, `nvr-archive`, `nvr-faults`. They need the real daemon and a disk of 32 GB (`--disk-size`, the default): recording keeps 8 GiB of the data partition free for updates and the size cap is the partition minus twice that, so the 16 GB disk that older versions of this script used cannot hold recordings.
4. The request channel from the daemon user: accepted names run, unknown names / symlinks / non-JSON are discarded, the daemon user cannot write the system folder or read the SSH folder.
5. Factory reset through the marker file on the boot partition. Recordings are erased with the settings: the test counts them before and after.
6. The installer on a second virtual disk: `--list`, refusal of the boot disk and of a partition, `--dry-run` writes nothing, wrong phrase and missing confirmation write nothing, real install with `--copy-data`; then the installed disk alone is booted and the copied data checked.

### The nvr tests

`nvr`, `nvr-archive` and `nvr-faults` of `linux/os/test-vm.sh` need an image with the real daemon (they skip themselves on `--stub-daemon`). Their web client is `linux/os/test-nvr.py` (Python 3, standard library only). The client prints `ok` and `FAIL` lines, the script counts them; the box side is bash, tar, ffmpeg, jq and fallocate. The image does have `/usr/bin/python3` (3.13): Debian's `systemd-ukify`, which `mkosi.conf` lists, depends on it, and no package of ours asks for it. The box-side scripts do not rely on that; the one place that uses it is the burst of the `nvr` test when it runs inside the box (below), and that says so, as a FAIL, if the box has no python3.

* `nvr`: the first Record prompt (409 `folder_required`, then the one location, then Record on); the demo camera records; the recordings folder is made by the daemon (camerabridge, mode 700, on the data partition, one folder named after the camera's ID, files 0600); a fragment list, a fragment, the init segment and a key picture are fetched from the host and checked against the contract (video only, no `prft`, `Cache-Control: no-store`, the pinned Content-Security-Policy), and the box's own `ffmpeg` decodes what was served; Record sound (the file keeps its sound, the served segments do not); 401 without a session, CSRF and origin checks, `HEAD` on media is 405, bad input is 400, 404 or 410; 40 simultaneous requests are answered or refused with `429 busy` while `/api/v1/health` stays fast; the unit's hardening is unchanged and the daemon's log has no permission errors, no secret and no line per request. When `linux/web-dev/conformance.mjs` exists and the host has Node 22 or newer, that contract checker (with all its groups) runs against the box as well.
  * **Where the burst and the checker run.** The only way `test-vm.sh` reaches the box is QEMU's user-mode port forwarding, and on a macOS host that resets connections which arrive together: measured on the arm64 image, 40 `/api/v1/health` requests at once lose 12 to 16, two at once lose one, 300 one after the other lose none, and the same 40 from inside the box all answer. So `--burst-from guest` (the default on macOS) runs the burst inside the box over ssh: the same `test-nvr.py`, copied with the run's session into the box's `/tmp` for the length of the phase, run by the box's python3 against its own loopback address. `--burst-from host` (the default on Linux, so on a KVM runner the burst runs from the host, as the CI list assumes) sends the 40 requests from the computer that runs the script. On the KVM runner it ran from the host and all 40 requests were answered (run of 2026-10-11); if a runner's forwarding ever resets too, the burst fails with "no answer at all" and the sentence that names `--burst-from guest`; nothing is retried and nothing is lowered (still 40 requests, still 200 or `429 busy`, still `/api/v1/health` under 2 s). `conformance.mjs` asks one thing at a time, which the forward carries, except its own burst of 40: with `--burst-from guest` it runs with `--no-burst` (it reports that group as skipped, and the burst above is the one that counts), with `--burst-from host` with all its groups.
* `nvr-archive`: a seeded archive of `--seed-files` recordings (default 2000; hard links of one real fragment, each with its own sidecar, spread over 5 days) plus three that are 9 days old, one that is 10 days old, a foreign file and a link named like a recording, and a real recording cut in the middle of a fragment with its sidecar removed (what a power cut leaves). The daemon is restarted: it must say READY no later than 15 s after the time it needs with the small archive of the same run, `/api/v1/health` must answer while the archive loads, the archive routes answer `503 archive_unavailable` until it is ready, the torn recording is cut back to its last whole fragment with a new sidecar and the bytes kept unchanged, retention removes the old recordings (and the day folder that became empty) and nothing else, and a sample of the seeds is read back through the API byte for byte. Then a clean reboot: everything closed before is still there and Record is still on.
* `nvr-faults`: the data partition is filled with `fallocate` to 3 GiB above the floor (the notice "Recording Storage Almost Full"), then below it (recording pauses, the notice "Recording Can't Continue", nothing is deleted), then freed (recording resumes, the notice goes). Then the power is cut (QEMU is killed) while the camera records: the box starts, the daemon starts once, the recording that was open has a valid sidecar again, recording resumes and the archive is served. The phases that wait for "6 s of recording" or ask for a time "3 s before the newest" look at the newest recording file itself (its end and the time N seconds before it must be in the same file), not at the span from the oldest recording to the newest: after a power cut that span is the whole run, with a gap before the file the recorder has just opened, and a time 3 s before its end lies in the gap while the file is shorter than that.

Everything the tests do on the box is in `/var/lib/camera-bridge` (the recordings and a staging folder that is removed) and `/srv/system/nvr-ballast` (removed); the disk is a file under `--work`.

Offline, in a few seconds and without a VM, `python3 -I linux/os/test-nvr.py selftest` checks the client against the golden bytes of the sidecar format, runs the two box-side scripts on a local folder and runs every phase against a small stand-in for the box (and breaks the stand-in in six ways to see that the phases notice: `HEAD` answered, no CSP, no `no-store`, a `prft` left in a segment, connections reset when two arrive together, a changed seed; a seventh case grows a short new recording after a long archive to check that the phases wait for it). The workflow runs it with the static checks.

To run the tests on a Mac without CI: build the arm64 image with the real daemon (`linux/os/build.sh --version 0.1.90 --arch arm64 --out OUT`, which needs the Swift build in Docker and several GB of cache; `build.sh --clean` removes it) and run `linux/os/test-vm.sh --image OUT/camera-bridge-os-0.1.90-arm64.img.xz --arch arm64 --tests nvr,nvr-archive,nvr-faults --cpus 4 --work SCRATCH --keep`. Add `--seed-files 100` while iterating. On a Mac the burst runs inside the box (`--burst-from guest` is the default there). The amd64 image can only be built and booted by the workflow.

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

Verified by the GitHub Actions workflow (Ubuntu 24.04 runners with KVM):

* The **amd64** image builds with the real `camerabridged` (Swift 6.4, static standard library) and boots in QEMU with UEFI; the original list of tests passes (61 checks, run of 2026-10-10).
* The default list with the daemon and the three nvr tests passes on a KVM runner: `RESULT: 220 passed, 0 failed` (image 0.1.92 built from the NVR tree, manual run of 2026-10-11, boot test 7 minutes), with `systemd-analyze security camerabridged` at 1.9 ("OK") and the unit's properties unchanged.

Not verified here:

* **Booting on real hardware**, USB boot on actual mini PCs, UEFI quirks, hardware video encoding (VA-API), firmware loading, the hardware watchdog, power-loss behaviour.
* **The amd64 image on real hardware.** The workflow builds it and boots it in a virtual machine; the Apple Silicon development Mac cannot build it (see above). The configuration is the same as arm64 except for the kernel and driver packages (`linux-image-amd64`, `intel-media-va-driver`) and the serial console device.
* **A complete passing run of the nvr tests on the local arm64 image.** They were run on a local arm64 image (a macOS host, HVF); the failures that were in the checks and not in the box (the fetch after a power cut that asked for a time in a gap, the burst and the checker reset by the port forward) are fixed above; the other failures of that run were in the daemon, not in the checks, and are not described here. A complete green run on this arm64 image is not recorded here; the first complete green run is the one on the KVM runner (below).
* **A real recording camera.** The nvr tests record the demo camera's test pattern (1080p, software H.264) in a virtual machine. They say nothing about a real camera's keyframe interval, bitrate or codec, about a USB disk, or about the speed of the box's own storage.
* A release downloaded from GitHub by the updater (the API stand-in is used instead).
* Secure Boot is not supported by design.

## Disk space and cleanup

A build uses several GB in Docker volumes (`cb-os-work`: the mkosi cache and image, `cb-os-swift-<arch>`: Swift build cache, `cb-os-go`: Go module and build cache for go2rtc). `linux/os/build.sh --clean` removes them. The VM test uses a few GB in its scratch folder, deleted at the end unless `--keep`.

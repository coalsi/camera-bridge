# Camera Bridge OS: hardware

Camera Bridge OS runs on an ordinary small PC. It needs no graphics output, no keyboard and no screen once it is running.

## Reference hardware

| | Minimum (the reference box) | More headroom |
|---|---|---|
| CPU | Intel N150 (Twin Lake) or N100, 4 cores, with its Intel graphics (Quick Sync / VA-API: the box decodes and encodes video on it) | Intel N305 / Core i3 class, 8 cores |
| Memory | 12 GB (8 GB works with fewer cameras) | 16 GB |
| Storage | an internal SATA or NVMe SSD, 512 GB (recordings live there unless you add a recording drive) | 1 TB SSD, or an external recording drive |
| Network | Gigabit Ethernet, or Wi-Fi | Gigabit Ethernet |
| Cameras | up to 12 recording, with a live wall of all of them in a browser | 16 or more |

The reference box is a **Beelink Mini S (Intel N150, 12 GB, 512 GB SATA SSD, Intel Wi-Fi)**: it runs Camera Bridge OS installed on its SSD with five cameras recording around the clock, at about a quarter of its CPU (October 2026). Everything the OS is tuned for (buffers, caches, write-back, the number of parallel reads and live views) assumes at least this machine; smaller ones (USB sticks, 4 GB, no Intel graphics) still boot but are not a target any more.

## Why these numbers

* **Cameras that send H.264 are passed through** to Apple Home without being re-encoded, which costs almost no CPU. What does cost CPU: audio conversion (to Opus for live view, AAC-LC for recording), cameras that send H.265, and the optional timestamp overlay. The Intel graphics decode (snapshots, built-in motion detection) and encode (the conversions) on the N100/N150, so the processor stays mostly free.
* **Live video in the browser** (the Monitor and a camera's page) is the camera's own video, copied, not re-encoded: one connection carries every camera, and the browser decodes. The box's cost is network, not CPU: about 0.5 to 1 Mbit/s per camera on the sub stream, 4 to 10 on the main stream.
* **Memory:** the system itself uses a few hundred MB; each camera adds buffers for HomeKit Secure Video fragments. Compressed RAM (zram) is used instead of a swap file.
* **Recording (the Record switch)** does not re-encode: the box writes the camera's main stream as it arrives. It adds disk writes (a 4 Mbps camera writes about 0.5 MB a second, 43 GB a day) and, by design, very little processing, which has not been measured on real hardware yet. Browsers decode the video when you watch it, not the box.
* **Wired or Wi-Fi:** an Ethernet cable works with no setup. For Wi-Fi the image carries the firmware of the common chips (Intel, Realtek, MediaTek, Qualcomm Atheros, Broadcom, Marvell/NXP, TI). Without a cable and without a Wi-Fi network it knows, the box opens its own setup network, `CameraBridge-XXXX`, about 30 seconds after it starts: join it with a phone and a page asks which Wi-Fi to use. (A few Wi-Fi chips cannot open a hotspot; the box then says so on its screen and needs a cable.) A single cable to a Mac also works for a first look: the box falls back to a 169.254.x.x link-local address and answers at `http://camera-bridge.local`.

## Storage: do not use a cheap stick

The system writes a little all the time (database, logs), and with the data partition on the same device an update writes a few GB. Cheap USB sticks wear out and stall.

* **Best:** the machine's internal SSD or NVMe. Boot the installer from a USB stick once and install to the internal disk (see the user guide).
* **Good:** an SSD in a USB 3 enclosure, or a USB 3 stick from a known brand with good sustained write speed (a "high endurance" or SSD-type stick).
* **Avoid:** unbranded or very old sticks, USB 2 ports, SD cards in adapters.
* Size: 16 GB works for the bridge on its own; the layout needs about 8 GB for the system (two 2.5 GB slots + boot partition) plus room for settings and update downloads (4 GB free is required for an update). Recording changes the sums. The data partition takes all the remaining space, and the recordings go there too; recording pauses when free space on it falls below 8 GiB (about 8.6 GB) or 5% of the partition, whichever is more. On a 16 GB stick the data partition is hardly larger than that (at most about 1.4 GiB above it, before the file system takes its part), so recording would pause soon. Use 64 GB or more. A camera sending 4 Mbps writes about 43 GB a day, so the default limit of 500 GB is about 11.6 days of one camera or about 2.9 days of four.

Two different things are called recording. **HomeKit Secure Video** recordings go to iCloud: the box only streams to the Home hub and to your phone, and stores nothing. The box's own **Record** switch (the NVR) is separate. It keeps the camera's full-quality main stream as MP4 files on the box's data partition, in `/var/lib/camera-bridge/recordings`, and deletes the oldest first (default: keep 7 days and at most 500 GB, both limits apply). A stick you boot from is a poor place for that, because constant writing wears it out: install to the internal SSD first (user guide, section 7), then switch Record on. A factory reset erases the recordings. To record to a separate drive (USB or SATA, a hard disk or an SSD), plug it in and choose it under **System ▸ Recording drive**.

## Graphics, video encoding

Installed: the free Intel media driver (`intel-media-va-driver`, VA-API) and Mesa's VA drivers for AMD, plus `vainfo` to check. The Intel GuC/HuC firmware (`firmware-intel-graphics`) is included because low-power H.264 encoding on N100/N150 needs it. Check on a running box (over SSH): `vainfo` should list `VAProfileH264Main ... VAEntrypointEncSliceLP`. If it does not, the engine falls back to software encoding.

Included network firmware: Realtek (common 2.5G/1G chips). Intel Ethernet (i225/i226/e1000e) needs none. If your machine's network chip is not recognized, it is a missing driver or firmware: please open an issue with the output of `lspci -nn` and `dmesg | grep -i firmware`.

## BIOS / firmware settings

* UEFI boot (not "Legacy" or "CSM").
* **Secure Boot: off.** The boot loader and kernel are not signed with a key your firmware trusts.
* Boot order: USB first for the first start; after installing to the internal disk, internal first.
* "Restore on AC power loss" = Power On, so the box comes back after a power cut.
* Wake on LAN is not needed. Disable "ErP/Deep sleep" modes that cut power to the USB ports if you boot from USB.

## Raspberry Pi 5 (later)

An arm64 image of the same system is planned, camera passthrough only (no video re-encoding): the Pi 5 has no hardware H.264 encoder. The build already supports `--arch arm64` and boots in UEFI virtual machines, but the Raspberry Pi boot chain (firmware, device tree, bootloader) is **not** done, so there is no Pi image. Do not try to flash the arm64 image on a Pi.

## What has been verified

* **Real hardware:** the reference box (Beelink Mini S, Intel N150, 12 GB, 512 GB SATA SSD, Intel Wi-Fi) runs Camera Bridge OS installed on its SSD every day since October 2026: UEFI boot from a USB stick, install to the internal disk, Wi-Fi, VA-API decoding and encoding on the Intel graphics, updates from signed releases, recording five cameras around the clock, live video and sound in the browser, and pairing with the Home app.
* **Virtual machines:** every release image boots in QEMU/UEFI in GitHub Actions before it is published, and the test suite there covers first start, install to a second disk, updates and automatic rollback (see BUILDING.md).
* **Not yet verified:** other mini PCs (AMD, other Intel generations, other network and Wi-Fi chips), long-term power-loss behaviour, and USB stick endurance. Please report what you find in an issue, with `lspci -nn` and `dmesg | grep -i firmware` for hardware problems.

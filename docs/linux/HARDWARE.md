# Camera Bridge OS: hardware

Camera Bridge OS runs on an ordinary small PC. It needs no graphics output, no keyboard and no screen once it is running.

## Reference hardware

| | Recommended | Minimum |
|---|---|---|
| CPU | Intel N100 or N150 (Alder Lake-N / Twin Lake), 4 cores | any 64-bit x86 (amd64) CPU with UEFI; Intel with a Gen8+ graphics unit for hardware video encoding |
| Memory | 8 GB (16 GB if you want headroom) | 4 GB |
| Storage | an SSD (internal, or in a USB 3 enclosure), 64 GB or more | 16 GB, a good-quality USB stick |
| Network | wired Gigabit Ethernet | wired Ethernet |
| Cameras | up to 8 | |

Examples of this class of machine: Beelink Mini S13 (N150), Beelink S12 Pro (N100), and the many similar N100/N150 mini PCs from Minisforum, GMKtec, Intel NUC-style barebones and others. These are examples of the class, not a tested list: **no real mini PC has been tested yet** (see "What has been verified" below).

## Why these numbers

* **Cameras that send H.264 are passed through** to Apple Home without being re-encoded, which costs almost no CPU. What does cost CPU: audio conversion (to AAC-ELD for live view, AAC-LC for recording), cameras that send H.265, and the optional timestamp overlay. With hardware encoding (VA-API on Intel graphics) the N100/N150 handles eight such cameras; software-only encoding of eight streams will not fit.
* **Memory:** the system itself uses a few hundred MB; each camera adds buffers for HomeKit Secure Video fragments. Compressed RAM (zram) is used instead of a swap file.
* **Wired only (version 1):** there is no Wi-Fi setup in Camera Bridge OS yet. Connect the box to your router or switch with an Ethernet cable. (Cameras on Wi-Fi are fine; they only need to be on the same local network as the box.) A single cable to a Mac also works for a first look: the box falls back to a 169.254.x.x link-local address and answers at `http://camera-bridge.local`.

## Storage: do not use a cheap stick

The system writes a little all the time (database, logs), and with the data partition on the same device an update writes a few GB. Cheap USB sticks wear out and stall.

* **Best:** the machine's internal SSD or NVMe. Boot the installer from a USB stick once and install to the internal disk (see the user guide).
* **Good:** an SSD in a USB 3 enclosure, or a USB 3 stick from a known brand with good sustained write speed (a "high endurance" or SSD-type stick).
* **Avoid:** unbranded or very old sticks, USB 2 ports, SD cards in adapters.
* Size: 16 GB works; the layout needs about 8 GB for the system (two 2.5 GB slots + boot partition) plus room for settings and update downloads (4 GB free is required for an update). Bigger is only useful if you plan to add recording features later; the data partition takes all the remaining space.

Camera recordings are **not** stored on the box: HomeKit Secure Video recordings go to iCloud, and the box only streams to the Home hub and to your phone.

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

* The image boots, updates, rolls back and installs to a second disk in a QEMU/UEFI virtual machine (arm64 build, hardware-accelerated on an Apple Silicon Mac). See BUILDING.md for exactly which tests.
* The amd64 image (the one mini PCs need) uses the same configuration but **has not been built or booted yet**: the development machine is an ARM Mac, which cannot build it. The first build is done by GitHub Actions; until that has run and been tested on an x86 machine or VM, treat amd64 as unproven.
* **Not verified on real hardware:** UEFI boot from a USB stick on actual mini PCs, VA-API hardware encoding on N100/N150, firmware blobs, network chips, watchdog behaviour, power-loss behaviour, USB stick endurance. Expect to find hardware-specific problems; please report them.

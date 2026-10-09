# Camera Bridge OS: user guide

Camera Bridge OS turns a small PC into a bridge between your IP cameras (ONVIF / RTSP) and Apple Home. You plug in the box, open a web page, add your cameras, and Apple Home records them with HomeKit Secure Video. No Mac and no NVR are needed.

You need: a mini PC (see HARDWARE.md), a USB stick or SSD (16 GB or more), an Ethernet cable to your router, an Apple Home hub (Apple TV or HomePod) and an iCloud+ plan for HomeKit Secure Video.

> Menu names in this guide ("System" and so on) follow the web UI design and may differ slightly in the build you have.

> Status: this is a first version. The system image has been tested in virtual machines, not yet on many real mini PCs. Photos of what you see and hardware reports are welcome.

## 1. Download

Open the project's **Releases** page on GitHub and pick the newest release whose tag starts with `os-v` (for example `os-v0.1`). Releases tagged `v1.0`, `v1.1` ... are the Mac app, not this.

Download `camera-bridge-os-<version>-amd64.img.xz`. Optionally also download the `.sha256` file and check it:

* macOS / Linux: `shasum -a 256 camera-bridge-os-0.1-amd64.img.xz` (Linux: `sha256sum`) and compare with the number in the `.sha256` file.
* Windows (PowerShell): `Get-FileHash .\camera-bridge-os-0.1-amd64.img.xz -Algorithm SHA256`

Do not unpack the `.xz` file; the tools below read it directly.

## 2. Write it to a USB stick or SSD

**Everything on the stick or SSD is erased.** Check twice that you picked the right device.

### balenaEtcher (macOS, Windows, Linux; easiest)

1. Install [balenaEtcher](https://etcher.balena.io/).
2. "Flash from file": choose the `.img.xz`.
3. "Select target": choose your USB stick / SSD. Etcher hides your system disk by default.
4. Flash. When it finishes, eject the stick.

### The command line (macOS / Linux)

On a Mac:

```
diskutil list                      # find the stick, e.g. /dev/disk4 (check the size!)
diskutil unmountDisk /dev/disk4
xz -dc camera-bridge-os-0.1-amd64.img.xz | sudo dd of=/dev/rdisk4 bs=4m
diskutil eject /dev/disk4
```

On Linux (use `lsblk` to find the stick, for example `/dev/sdX`; a wrong device name destroys data):

```
xz -dc camera-bridge-os-0.1-amd64.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

On Windows without Etcher: Rufus (DD image mode) also works.

The first start grows the data partition to fill the whole stick, so the size of the stick does not matter beyond the 16 GB minimum.

## 3. Start the mini PC from the stick

1. Connect the Ethernet cable and the power; insert the stick (a blue USB 3 port is best).
2. Power on and press the boot-menu key repeatedly. Common keys: **F7** (Beelink, GMKtec, Minisforum also **Del**), **F12** (Dell, Lenovo, Acer), **F9** or **Esc** (HP), **F10** (Intel NUC), **F2** / **Esc** (ASUS). If the boot menu does not show, press **Del** or **F2** to enter the firmware setup and change the boot order there.
3. Choose the entry for your USB stick; if you see two entries for it, take the one that says **UEFI**.
4. If nothing boots: in the firmware setup, **turn Secure Boot off** and make sure the boot mode is UEFI (not Legacy/CSM). Camera Bridge OS is not signed for Secure Boot.

If a monitor is attached you will see the system start (a few seconds) and then a text screen with the line **Web UI: http://camera-bridge.local** and the box's network address. There is no login on this screen; everything is set up in the browser.

## 4. Open the web page

On any computer or phone on the same network open **http://camera-bridge.local**. (Windows 10/11, macOS, iPhone/iPad and most Linux systems resolve `.local` names. If yours does not, use the address shown on the box's screen or in your router's list of connected devices, for example `http://192.0.2.10`.)

The first time, the page asks you to choose an administrator password. Until you do, it shows nothing else. Choose a long password: it protects your camera passwords.

## 5. Add your cameras

1. **Add camera** (or **Discover**): the box looks for ONVIF cameras on the network. You can also enter a camera by hand: type, address, port, user name and password.
2. Use **Test** before saving. It checks the credentials and shows what the camera sends (video codec, audio).
3. Give each camera a name. Save.

Tips: give the cameras fixed addresses (a DHCP reservation in your router), and use a separate camera user with a strong password. Cameras on a different VLAN need your router to allow the box to reach them.

## 6. Add them to Apple Home

Every camera appears in Home as its own accessory.

1. In the camera's page in the web UI, show the **pairing code** (QR code and 8-digit code).
2. On your iPhone: Home app > **+** > **Add Accessory** > scan the QR code (or enter the code manually).
3. Home asks you to name the camera and choose a room, and whether to enable recording (HomeKit Secure Video: needs an iCloud+ plan and a home hub).

If Home says "Accessory not found", check that the phone is on the same network, wait a minute for the box to finish starting, and see Troubleshooting.

## 7. Install to the internal SSD (recommended)

Running from a USB stick works, but an SSD is faster and lasts longer. You can copy the system to the machine's internal disk.

**This erases the whole internal disk.** The installer refuses the disk it is running from and any disk that is in use, shows what is on the disk, and asks you to type a confirmation sentence.

In the web UI: **System > Install to a disk in this machine**. Choose the disk from the list (disks that can’t be used are listed with the reason and have no button), choose whether to **copy my settings and pairings** (otherwise the new system starts empty), type the sentence shown (`ERASE ALL DATA ON <disk name>`) and confirm. It takes a few minutes. When it says it is done, the box powers off: **remove the USB stick**, then switch it on again. If you copied your settings, do not run the USB stick again afterwards (two boxes with the same pairings would confuse Home).

From a terminal (SSH, see "Advanced"):

```
cb-install-to-disk --list                                 # which disks can be used
cb-install-to-disk --device /dev/nvme0n1 --dry-run        # shows exactly what would happen, changes nothing
cb-install-to-disk --device /dev/nvme0n1 --copy-data      # asks you to type: ERASE ALL DATA ON nvme0n1
```

## 8. Updates

The box checks GitHub for a newer `os-v...` release every day. In **System** you can switch on **automatic updates** (the box then installs and restarts at 03:00 UTC) or press **Update now**. A new version is checked (signature and SHA-256), written next to the current one, and the current one stays as a fallback: if the new version does not start properly three times, the box returns to the old one by itself. Details: UPDATES.md.

## 9. Factory reset

This erases your cameras, passwords and HomeKit pairings (the cameras then have to be removed from Home by hand and added again).

* In the web UI: **System > Factory reset** (type `RESET` to confirm).
* From a terminal: `cb-system factory-reset --yes`.
* If the web UI cannot be reached: **write the image to the stick again** (this also resets everything on that stick).
* Advanced: create an empty file named `camera-bridge-factory-reset` in the top folder of the stick's small boot partition (label `CB-ESP`) and start the box; it erases the settings during start-up and removes the file. On Linux that partition mounts like any FAT disk. macOS and Windows hide this kind of partition: on macOS use `diskutil list` and `sudo diskutil mount /dev/diskNs1`, on Windows use `diskpart` and assign a letter. (These two have not been tested.)

## 10. Advanced: SSH

SSH is **off** by default. To use it, enable it in **System > SSH** and paste your **public** key; only key login for the user `root` is possible, no passwords. From a terminal on the box you can then use `cb-update`, `cb-system`, `cb-install-to-disk`, `journalctl -u camerabridged`, `vainfo`. Turn it off again when you are done.

## Troubleshooting

| Problem | What to try |
|---|---|
| The PC does not boot from the stick | Boot menu key (section 3); Secure Boot off; UEFI mode; try another USB port (USB 2 ports are fine for booting but slow); write the image again. |
| `camera-bridge.local` does not open | Wait two minutes after power-on (the first start sets up the disk). Use the address shown on the box's screen or find it in your router. Make sure your computer is on the same network (not a guest network). Try `http://` explicitly (not `https://`). |
| The box has no address | Check the Ethernet cable and the router's DHCP. If you connected it straight to a Mac, wait up to a minute for the 169.254.x.x link-local address and open `http://camera-bridge.local`. |
| The page loads but cameras are not found | The box and the cameras must be on the same network segment (or the router must allow traffic between them). Add the camera by hand with its address. Use the **Test** button to see the error. |
| Home says "No Response" | The box must be on and reachable; the iPhone must be on the same network for the first pairing; a home hub (Apple TV / HomePod) is needed for remote access and recording. If you reinstalled the box without copying the settings, remove the old accessory from Home and pair again. |
| The picture is jerky or the box is hot | Too many cameras for the CPU (see HARDWARE.md), or the cameras send H.265. Lower the camera's bit rate; use H.264. |
| The clock is wrong | The box sets its clock from the internet (NTP). It needs internet access for that; wait a few minutes after a power cut. |
| It runs, but slowly, from a USB stick | Use a USB 3 port and a better stick, or install to the internal SSD (section 7). |
| After an update the old version came back | That is the safety net working: the new version did not start properly. See UPDATES.md; the web UI (or `cb-update status`) says why. Try again later or report it with the diagnostics export. |
| Logs | Web UI > Logs, or the diagnostics export. Over SSH: `journalctl -u camerabridged -b`, `journalctl -b -p warning`. |
| Power cut | The data lives in a journaled file system and recovers by itself. Do not pull the power during an update more often than you must; the old version is kept anyway. |

## What this version does not do

* No Wi-Fi setup (wired only).
* No Secure Boot, no disk encryption (the secrets file on the data partition is protected by file permissions, not by a TPM yet).
* Only amd64 mini PCs; Raspberry Pi 5 is planned.
* The box is for your local network only. Do not forward ports to it from the internet. Apple Home reaches it through your home hub.

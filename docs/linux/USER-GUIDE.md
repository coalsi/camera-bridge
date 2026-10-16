# Camera Bridge OS: user guide

Camera Bridge OS turns a small PC into a bridge between your IP cameras (ONVIF / RTSP) and Apple Home. You plug in the box, open a web page, add your cameras, and Apple Home records them with HomeKit Secure Video. No Mac and no NVR are needed. If you also want recordings of your own to watch in the web page, the box can keep them (section 11); that is optional and separate from HomeKit Secure Video.

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

**Do this right away, on a network you trust.** A new box has no password yet, so whoever opens its page first can set one. On a home network that means only people already on it, and only until you finish this step. Don't plug a new box into a shared or public network. (A one-time setup code that must be typed before the first password can be set is supported by the program but not switched on in this version.)

## 5. Add your cameras

1. **Add camera** (or **Discover**): the box looks for ONVIF cameras on the network. You can also enter a camera by hand: type, address, port, user name and password.
2. Use **Test** before saving. It checks the credentials and shows what the camera sends (video codec, audio).
3. Give each camera a name. Save.

Tips: give the cameras fixed addresses (a DHCP reservation in your router), and use a separate camera user with a strong password. Cameras on a different VLAN need your router to allow the box to reach them.

**Set up for Camera Bridge** (offered right after you add a Hikvision, Reolink, Amcrest or ONVIF camera, and in its page's **Camera setup** section) makes the camera right for the box in one step: its streams for recording, Apple Home and live view, its own on-screen labels off, the box's time zone, its clock set from the box, and on Hikvision cameras Hik-Connect (the maker's cloud) and UPnP off. It reads the camera first and shows every change (now → after) before anything happens; it saves the camera's settings first, and **Restore original settings** puts them all back. It never changes the camera's address, ports, users or passwords, and never restarts it. The box answers time requests from your local network only (the firewall allows nothing else).

## 6. Add them to Apple Home

Every camera appears in Home as its own accessory.

1. In the camera's page in the web UI, show the **pairing code** (QR code and 8-digit code).
2. On your iPhone: Home app > **+** > **Add Accessory** > scan the QR code (or enter the code manually).
3. Home asks you to name the camera and choose a room, and whether to enable recording (HomeKit Secure Video: needs an iCloud+ plan and a home hub).

If Home says "Accessory not found", check that the phone is on the same network, wait a minute for the box to finish starting, and see Troubleshooting.

## 7. Install to the internal SSD (recommended)

Running from a USB stick works, but an SSD is faster and lasts longer. You can copy the system to the machine's internal disk.

**This erases the whole internal disk.** The installer refuses the disk it is running from and any disk that is in use, shows what is on the disk, and asks you to type a confirmation sentence.

In the web UI: **System > Install to a disk in this machine**. Choose the disk from the list (disks that can’t be used are listed with the reason and have no button), choose whether to **copy my settings and pairings** (otherwise the new system starts empty; the copy also includes the recordings folder, which can be hundreds of GB and may not fit, so **install first and switch Record on afterwards**), type the sentence shown (`ERASE ALL DATA ON <disk name>`) and confirm. It takes a few minutes. When it says it is done, the box powers off: **remove the USB stick**, then switch it on again. If you copied your settings, do not run the USB stick again afterwards (two boxes with the same pairings would confuse Home).

From a terminal (SSH, see "Advanced"):

```
cb-install-to-disk --list                                 # which disks can be used
cb-install-to-disk --device /dev/nvme0n1 --dry-run        # shows exactly what would happen, changes nothing
cb-install-to-disk --device /dev/nvme0n1 --copy-data      # asks you to type: ERASE ALL DATA ON nvme0n1 (copies recordings too)
```

## 8. Updates

The box checks GitHub for a newer `os-v...` release every day. In **System** you can switch on **automatic updates** (the box then installs and restarts at 3 AM in the bridge's time zone, set in **Settings**; UTC until one is set) or press **Update now**. A new version is checked (signature and SHA-256), written next to the current one, and the current one stays as a fallback: if the new version does not start properly three times, the box returns to the old one by itself. Details: UPDATES.md.

## 9. Factory reset

This erases your cameras, passwords, HomeKit pairings **and all recordings made with Record** (the cameras then have to be removed from Home by hand and added again). The confirmation in the web UI says so.

* In the web UI: **System > Factory reset** (type `RESET` to confirm).
* From a terminal: `cb-system factory-reset --yes`.
* If the web UI cannot be reached: **write the image to the stick again** (this also resets everything on that stick).
* Advanced: create an empty file named `camera-bridge-factory-reset` in the top folder of the stick's small boot partition (label `CB-ESP`) and start the box; it erases the settings and the recordings during start-up and removes the file. On Linux that partition mounts like any FAT disk. macOS and Windows hide this kind of partition: on macOS use `diskutil list` and `sudo diskutil mount /dev/diskNs1`, on Windows use `diskpart` and assign a letter. (These two have not been tested.)

## 10. Advanced: SSH

SSH is **off** by default. To use it, enable it in **System > SSH** and paste your **public** key; only key login for the user `root` is possible, no passwords. From a terminal on the box you can then use `cb-update`, `cb-system`, `cb-install-to-disk`, `journalctl -u camerabridged`, `vainfo`. Turn it off again when you are done.

## 11. Record, watch and scrub (the NVR)

Two different things are called recording, and neither needs the other:

* **HomeKit Secure Video** (section 6): Apple Home records clips of events to iCloud. The box only streams to your Home hub and stores nothing.
* **Record** (this section): the box keeps the camera's own full-quality video on its own storage, around the clock, and you can watch it in this web page. It is optional, it stays off until you switch it on for a camera, and it works without Apple Home or iCloud.

### What gets recorded

With **Record** on, the box writes the camera's main stream exactly as the camera sends it. Nothing is converted, so the picture keeps the camera's full quality and recording needs no video encoding. It uses the stream the box already receives for Apple Home, so it puts no extra load on the camera.

The files are ordinary fragmented MP4 files with a small index file beside each, in `/var/lib/camera-bridge/recordings/<camera id>/<date>/<time>.mp4`, named with the box's own clock, which is set to UTC. A new file starts about every 15 minutes, and also when the camera reconnects or changes its picture settings. If the power is cut, the last half minute or so may be missing, and the box repairs the file it was writing when it starts again.

### Turn Record on

Record has a switch on the **Record** card of each camera's page and in the corner of each camera on the **Cameras** page. Nothing is recorded until you switch it on for a camera.

The first time, the page asks **Where should recordings be stored?** and lists the places the box offers. On a box that is one place, **This box’s storage**, with its free and total space. Choose it and Record turns on. **Cancel** changes nothing and leaves Record off.

Turning Record on or off does not restart the camera, so Apple Home live view and HomeKit Secure Video carry on undisturbed.

**Record sound** is a second switch under Record. It is off by default, and it records sound only while **Camera audio** (the Audio card on the camera's page) is on. The sound is stored in the files, but this version of the page does not play it yet; the picture plays as usual.

A camera that is recording shows **REC**. If Record is on but the camera is not sending video, the page shows it as waiting, and recording carries on by itself when video returns. When recording has to stop, a banner says why and what to do (see Troubleshooting).

### Where recordings go, and how much fits

**Settings > Recording** shows where recordings are stored, how much space they use, how much is free, and the oldest and newest recording. Two limits decide how long recordings are kept, and both apply, oldest first, across all cameras:

* **Keep for**: 1, 3, 7 (the default), 14, 30 or 90 days.
* **Maximum size**: 100, 250, 500 (the default), 1000, 2000, 4000 or 8000 GB. Gigabytes here are decimal: 1 GB is 1,000,000,000 bytes.

Recordings older than **Keep for** are deleted, and then the oldest recordings go until the total is under **Maximum size**. The box does this about once a minute, only ever deletes its own recording files, and never deletes anything just because the disk is getting full. If you lower a limit so that recordings would be deleted, the page tells you roughly how many gigabytes and asks first. On a small disk the box may keep less than you chose; Settings shows the real limit.

The size limit usually decides first. Video costs about 10.8 GB a day for each megabit per second of the camera's bit rate:

| Camera bit rate | One camera, a day | Seven days of it | Days that 500 GB holds, one camera | Days that 500 GB holds, four cameras |
|---|---|---|---|---|
| 2 Mbps | 21.6 GB | 151 GB | 23.1 | 5.8 |
| 4 Mbps | 43.2 GB | 302 GB | 11.6 | 2.9 |
| 6 Mbps | 64.8 GB | 454 GB | 7.7 | 1.9 |
| 8 Mbps | 86.4 GB | 605 GB | 5.8 | 1.4 |

Settings shows the same sum for your cameras, for example "About 43 GB a day. This storage holds about 2.3 days, fewer than the 7 days you chose, so older recordings are deleted sooner." When the storage holds fewer days than **Keep for**, that smaller number is what you will really have.

The same partition holds the box's settings, HomeKit keys and update downloads, so recording keeps a reserve free: it pauses when free space falls below 8 GiB or 5% of the partition, whichever is more, and starts again when there is 1 GiB more than that. (A GiB is 1.07 GB.) The reserve is more than the 4 GB an update needs, so recording leaves room for updates. A banner warns when less than 5 GiB remains above the reserve. A 16 GB stick has at most about 1.4 GiB above the reserve before the file system takes its part, and one that holds less than about 14.5 GB has no room above the reserve at all, so recording would pause soon, or even at once: install to an SSD of 64 GB or more (section 7) and switch Record on afterwards.

A factory reset erases the recordings (section 9).

### Watch and scrub

Open a camera's page and press **Watch recordings**. The Watch screen shows the picture on top, a row of controls under it and the timeline below.

* **Play** or **Pause**, the time of the picture (in your browser's time zone), **Go live** and the Record switch are in the row above the timeline.
* The buttons **10 min**, **1 h**, **6 h**, **24 h** and **All** choose how much time the timeline shows, and **−** and **+** zoom out and in. **All** is everything that is recorded.
* The wave in the timeline shows how much was going on: the amount of picture change the camera had to send. A quiet night is low, a person walking past is high. A dashed line marks what is normal for that camera (the middle value of the last 24 hours); bars more than one and a half times above it are amber. Hatched stretches have no recording.
* **Click or drag** the timeline to look at any moment. In Chrome the picture follows you one key picture at a time while you drag; in other browsers it catches up when you pause. When you stop, the exact picture arrives a fraction of a second later. When you let go, the video plays from there. Let go within a few seconds of now, or later, and it goes live.
* If nothing was recorded at the moment you chose, the page keeps the last picture, says there is no recording at that time and offers to jump to the next recording.
* Hold **Ctrl** or **Cmd** and turn the mouse wheel to zoom around the pointer; **Shift** with the wheel, or a sideways swipe, moves along the timeline. The shortest view is one minute.
* Keys, when the focus is not in a text box: **Space** plays or pauses; **Left** and **Right** move 1 second (with **Shift** 10 seconds, with **Alt** 1 minute); **L** goes live; **+** and **-** zoom the timeline; **Home** goes to the oldest recording; **Esc** goes back to the camera’s page.
* When the camera's key pictures are more than 4 seconds apart, a note under the timeline says scrubbing will be coarse and shows how to fix it on the camera (see "Cameras that jump while you scrub").

### What "live" means here

On the Watch screen and the NVR page, **Live** shows the newest part of the recording: the real picture a few seconds late, about 6 seconds, because the page stays a little behind the newest piece so that playback never has to wait. The page shows the real delay.

Live needs Record. With Record off, or while recording is paused or waiting, the page shows what the camera page has always shown: a slideshow of snapshots with a new picture every few seconds, labelled "Picture changes every few seconds". The box does not make a low-delay live video for browsers yet. Turn Record on for smooth video. Apple Home's live view is separate and unchanged.

### All cameras at once: the NVR page

The **Monitor** (the first page) is a wall of your cameras (9 on a page by default, with arrows to move between pages) playing live, with **Live** shown under it. The recordings share one playhead and one timeline: drag or click the timeline and every camera shows that moment, **Play** and **Pause** play them together, and **Back to live** returns to the live picture. Click a camera to open its Watch screen at the same moment, and use your browser's Back button to return. The wave in the timeline combines the cameras: at each moment it shows whichever camera is busiest compared with its own normal.

A browser can only decode so many pictures at once, so it may play fewer cameras than the page shows. A note then says, for example, "This browser plays recordings for one camera at a time on this page. The other cameras stay on snapshots; open one to watch it." At present Chrome on a Mac plays one camera at a time here.

Four to a page is the default because a modest computer, a phone or Wi-Fi may not keep up with more. To show more cameras on a page, add `?tiles=6` (up to 9) to the address before the `#`.

### Cameras that jump while you scrub

A video is a full picture (a key picture) every so often and small changes in between. Scrubbing jumps from key picture to key picture, so it is only as fine as the camera's key picture interval. A camera with a "smart codec" mode (names like H.264+, H.265+ or Smart Coding) can stretch that interval to 10 or 30 seconds to save space, and its recordings then scrub in jumps that long. When the box measures more than 10 seconds, the camera's page shows a note, "keyframe every N s: scrubbing is slow".

To fix it, switch the smart codec off in the camera's own settings and set its key picture interval (often called the I-frame interval) to about twice its frame rate, which is one every 2 seconds. The change applies to what is recorded from then on; older recordings stay coarse.

The note under the timeline on the Watch screen also has a button, **Make scrubbing smoother…**, that changes the camera's encoder settings for you. It asks first and lists what it can change, because it is the same optimizer that prepares a camera for HomeKit: it can lower a bit rate above 6 Mbps to 6 Mbps, change H.265 to H.264, keep the frame rate between 15 and 25 frames a second and change the video profile. It restarts the camera's stream, which leaves a short gap in the recording, and **Undo changes**, right after it has run, puts the settings back.

### Browsers

Recordings are played by your browser's own video player, and the box serves plain HTTP, so what plays depends on the browser:

* **Safari and Chrome on a Mac** are the supported browsers. In Chrome the picture follows you while you drag the timeline; in Safari it catches up when you pause.
* **Safari on an iPad** should work too. **An iPhone cannot play recordings yet**: the page says "Recordings can’t be played on an iPhone yet. Open this page on a Mac or an iPad." and keeps showing snapshots.
* **Firefox** should play H.264 recordings. Cameras that send H.265 (HEVC) should play in Safari; Chrome plays them only if your computer can decode H.265 in hardware.
* If your browser cannot play a recording, the page says so and keeps showing snapshots. The switches, the settings and the storage numbers still work.

Open the box with `http://`, not `https://`, as in section 4.

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
| A banner says "Recording Can’t Continue" | Read the sentence under the title. "Choose where to store recordings." means Record is on but no place was chosen: press the banner's button. "There isn’t enough free space on the recordings drive." means the reserve described in section 11 was reached; nothing is deleted to make room, so lower **Maximum size** (or **Keep for**) in **Settings > Recording**, or use a bigger disk. "The recordings folder isn’t available." or "The drive isn’t answering." should not happen on the box's own storage: restart the box, and if it comes back, export the diagnostics and report it. Recording carries on by itself when the problem is gone. |
| A banner says "Recording Storage Almost Full" | Less than 5 GiB is left above the reserve. Recording goes on until the reserve is reached. Lower the limits or use a bigger disk (section 11). |
| Record is on but nothing is recorded | The camera is not sending video (look at its page), or the box is still loading its list of recordings after a start; wait a minute. |
| The video does not play, and the page says the browser cannot play recordings | Use Safari or Chrome on a Mac. A camera that sends H.265 should play in Safari, or in a Chrome that can decode H.265. Snapshots, switches and settings still work. |
| Live looks like a slideshow | Record is off or paused. Live video is the newest part of the recording: switch Record on (section 11). |
| The picture jumps by many seconds when I drag the timeline | The camera sends a key picture only every N seconds (a "smart codec"). See "Cameras that jump while you scrub" in section 11. |
| The times are wrong | The box takes its time from the internet. If a camera's clock is more than a minute away from the box's, the box stamps the recordings with its own clock. The page shows times in your browser's time zone. |

## What this version does not do

* No Wi-Fi setup (wired only).
* No Secure Boot, no disk encryption (the secrets file on the data partition is protected by file permissions, not by a TPM yet).
* Only amd64 mini PCs; Raspberry Pi 5 is planned.
* The box is for your local network only. Do not forward ports to it from the internet. Apple Home reaches it through your home hub.
* Recordings go only to the box's own storage. Recording to a separate USB drive comes in a later version.
* The page does not play recorded sound yet (it is stored when Record sound is on).
* No export or download of clips, and no motion or person markers on the timeline: the wave shows how much was going on, not what.
* The web page is plain HTTP; an HTTPS option comes later.

## Recording to an attached drive

By default the box records to its own disk. To record to a bigger drive instead (a USB or SATA hard disk or SSD), plug it in, open **System**, and under **Recording drive** choose **Find drives**. Pick the drive and **Erase and record here…**; type the sentence shown to confirm. The drive is erased and made into a recording drive (it is then readable on Linux, not on a Mac or Windows PC without extra software). The bridge restarts for a moment. If the drive is unplugged the bridge says so and records nothing until it is back; it never fills its own disk by mistake. A drive that was made this way earlier (for example before you installed a new version) can be chosen again with **Record to this drive**, which keeps what is on it. **Use the box's own disk again** puts recording back on the box's disk and leaves the drive alone. A factory reset does not touch the drive.

## Wi-Fi

With a network cable the box needs nothing else. For Wi-Fi there are three ways:

1. **Before the first start:** after writing the image to the USB stick, open the stick on your computer (it shows up as a small drive) and add a text file named `camera-bridge-wifi.txt` with two lines:

   ```
   network=Your network name
   password=Your Wi-Fi password
   ```

   At its start the box saves the network and deletes the file. It keeps the network when you install it on the computer's own disk.
2. **The setup hotspot:** with no cable and no network it knows, the box opens its own Wi-Fi, `CameraBridge-XXXX`, about 30 seconds after it starts. Join it with a phone: a page opens by itself (as hotel Wi-Fi does). Choose your network, type its password and press Join. The box restarts and joins it; your phone goes back to your own Wi-Fi, and the box is at `http://camera-bridge.local`. If it can't join, its own network comes back and the page says why. Once the box is set up, the page also asks for its administrator password.
3. **System > Wi-Fi** in the web page: find networks, join one (the box restarts), forget one.

The box looks for its saved networks again every five minutes while nobody is using its hotspot, so it comes back by itself after a Wi-Fi outage.

## Moving from Camera Bridge for Mac

1. On the Mac: Camera Bridge › Settings › Backup › Export…. Save the file.
2. On the box: Settings › Move from Camera Bridge for Mac › Choose the backup file…, and pick that file. The cameras in it are listed with their addresses and user names.
3. Type the cameras' passwords (one for all of them, or each its own) and press Import. Cameras keep their settings, and Record stays on for the ones that recorded on the Mac (to the box's own storage until you choose a recording drive under System).
4. When the cameras run on the box: turn off recording in the Mac app (or quit it), add the box in the Home app, and remove the Mac's bridge from Home.

Importing the same file again adds nothing twice. A camera without a password is added turned off; type its password on its page.


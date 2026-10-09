# DoorBird

**Status: working** against a loopback test device; needs a real-device check of the event monitor.

Uses DoorBird's **official LAN API** (revision 0.36, <https://www.doorbird.com/api>): no cloud, no account beyond a user on the doorbell. DoorBird grants a licence to build integrations on its API; Camera Bridge follows its public document (no code was copied).

## What works

- **Video:** RTSP `rtsp://<ip>/mpeg/720p/media.amp` (newer firmware; tried first) or `rtsp://<ip>/mpeg/media.amp`, H.264 with the user's credentials.
- **Doorbell press and motion** from the event monitor `GET /bha-api/monitor.cgi?ring=doorbell,motionsensor`: lines `doorbell:H` and `motionsensor:H` (released: `:L`). A press counts once; motion holds 20 seconds. The monitor sends nothing while the door is quiet, so Camera Bridge restarts it every ten minutes (a cheap request; the device allows eight monitor streams and one new connection a second).
- **Device information** from `info.cgi`: model (`DEVICE-TYPE`), firmware, MAC address.
- **Live image** from `image.cgi` for the Overview and Home snapshots.

## What does not

- **Two-way audio, the door relay and light** are not offered yet.
- **Permissions.** The DoorBird user needs **"Watch always"**; without it video and images only work for about a minute after a ring and the device answers HTTP 204 (Camera Bridge says so). It needs no other permission (do not give it "API operator").
- **The DoorBird app wins.** The device allows one live call at a time; when the DoorBird app is open, Camera Bridge's stream can be cut and reconnects.
- **Rate and lock-out.** After wrong credentials DoorBird blocks the address for a minute (HTTP 423). Camera Bridge stops sending after the first rejection (two minutes, shared with ONVIF) and the event channel waits ten minutes.
- HTTPS is not used for video; events use plain HTTP on the LAN (with Use HTTPS on, events fall back to URLSession and may arrive late).
- The UDP broadcast notifications and HTTP favorites/schedules that DoorBird also offers are not used: the monitor needs no setup on the doorbell. (Revision 0.34 of the API notes calls "event monitoring" deprecated in favour of the UDP scheme but the monitor is still documented in 0.36.)

## Set up

1. DoorBird app › **Administration › Users**: add a user for Camera Bridge, give it **Watch always**.
2. Add Camera › **DoorBird**, pick it or type its address, sign in with that user and password.

## Tested how

`info.cgi` parsing (current and old firmware), the monitor's lines in any chunking, the mapper, a loopback doorbell with Digest authentication (probe with the HD fallback, snapshot with 204, event stream, the ten-minute restart, login guard and 423). **Needs a real-device test**: the monitor's actual framing and behaviour while the DoorBird app is in use.

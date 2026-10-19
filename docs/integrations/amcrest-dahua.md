# Amcrest and Dahua

**Status: working** against a loopback test camera; needs a real-camera check of the event stream.

Amcrest cameras and doorbells are Dahua-built and share its HTTP API; Dahua's own cameras, doorbells (VTO) and NVR channels use the same one. The adapter uses the camera's **own HTTP interface**, with Digest authentication, and its RTSP streams.

## What works

- **Video:** `rtsp://<ip>:554/cam/realmonitor?channel=1&subtype=0` (main) and `subtype=1` (sub stream, used for built-in motion and low-bandwidth live views).
- **Device information:** `magicBox.cgi` (`getSystemInfo`, `getSoftwareVersion`, `getDeviceClass`): model, serial number, firmware, and whether it is a doorbell (class `VTO`, or a model starting `AD`, `DB6`, `DB2`, `VTO`, `AV-V`).
- **Events** from `/cgi-bin/eventManager.cgi?action=attach&codes=[All]&heartbeat=5`:
  - `VideoMotion` → motion; `SmartMotionHuman` / `SmartMotionVehicle` → person / vehicle (and motion);
  - IVS rules (`CrossLineDetection`, `CrossRegionDetection`, `LeftDetection`, `TakenAwayDetection`, `WanderDetection`, `MoveDetection`, `ParkingDetection`, `RioterDetection`, `CrowdDetection`) → motion, with person or vehicle from `data.Object.ObjectType`; `FaceDetection` → face and motion;
  - `VideoBlind`, `VideoUnFocus`, `VideoAbnormalDetection` → tamper; `AudioMutation`, `AudioAnomaly`, `AudioIntensity` → sound alarm; `AlarmLocal` → alarm input;
  - **doorbell press:** `CallNoAnswered`, `PhoneCallDetect`, `_DoTalkAction_` with `Action: Invite` (Amcrest AD110/AD410), `BackKeyLight` with state 1 or 2 (Dahua VTO). Presses within three seconds count once.
- **Snapshots:** `snapshot.cgi?channel=1` (a vendor block some firmware appends after the JPEG is cut off).
- **DNS for the Internet guard** ("Set up for Camera Bridge" › Watch its internet): the camera's own `configManager.cgi` reads `table.Network.DefaultInterface` and `table.Network.<interface>.DnsServers[0|1]`, and `setConfig` puts Camera Bridge's address in both slots of that interface (the DNS fields are editable while the camera is on DHCP); Restore writes the old two slots back. An answer that is not Dahua's (a login page, a 404) leaves the camera to ONVIF.
- **Login safety:** after one rejected login Camera Bridge sends nothing more to the camera's API for two minutes (shared with ONVIF; an event channel that meets this pause waits for it, one refused itself waits ten minutes): Amcrest and Dahua cameras lock accounts after a few wrong passwords, which would also block the stream.

## What does not

- **Two-way audio.** The Amcrest app's call button stops working while a client holds the camera's speaker, so it is not offered here. (ONVIF Profile T audio works through the **ONVIF / RTSP** type.)
- Event codes that are not listed are ignored (system, storage and network events).
- Event detail depends on the model: the camera must have the smart feature turned on for `SmartMotion*` and IVS events.
- The AD310 and other doorbells that report a press with another code are not known; enable the **Webhook** for doorbells that never ring and tell us the `Code=` the camera sends (the log shows unmapped events at debug level).

## Set up

1. On the camera's web page: **Setup › Account**: create a user for Camera Bridge (an admin or operator account reads events; a viewer may not).
2. Keep HTTP on port 80 and RTSP on 554, or enter your ports (Add Camera › Advanced).
3. Add Camera › **Amcrest / Dahua**, pick the camera or type its address, sign in.

## Protocol notes and licences

Written from Dahua's HTTP API as it is documented in the public MIT-licensed [rroller/dahua](https://github.com/rroller/dahua) Home Assistant integration and Home Assistant's documentation (the code table, `heartbeat`, `Code=…;action=…;index=…;data={…}` framing). The Dahua PDF itself is not public. python-amcrest is GPL-2.0 and was **not** used; Scrypted's Amcrest plug-in was not read.
- The event response is `multipart/x-mixed-replace`; Camera Bridge reads it on a raw HTTP connection (not URLSession, which would hold each part back until the next boundary) and looks for `Code=` lines, so framing differences between firmware versions do not matter. It needs plain HTTP; with **Use HTTPS** on, events fall back to URLSession and may arrive late.
- `codes=[All]` is sent with literal brackets.
- **The DNS write sends encoded brackets, and this has not been checked on a real camera.** The request is built with the URL builder, which always writes `[` and `]` in a query as `%5B` and `%5D`: `GET /cgi-bin/configManager.cgi?action=setConfig&Network.eth0.DnsServers%5B0%5D=192.168.77.10&Network.eth0.DnsServers%5B1%5D=192.168.77.10` (the vendor's documentation, `curl -g` and browsers send them raw). Dahua firmware very likely decodes the key, but if a camera answers the change with "Error" or an HTTP error, or says "OK" and still shows none of the bridge's servers after the 30-second read-back (it ignored the keys), Camera Bridge does not stop there: it falls through to ONVIF for that run, and Restore does the same, so such a camera behaves as before the CGI was used. A camera that shows the bridge beside a server it kept keeps today's "kept" refusal. An account that may not change the network (HTTP 403) and a refused login do end the step. A test pins the exact request line and its Digest `uri`.

## Tested how

Recorded-style event streams (motion, IVS with multi-line JSON containing semicolons, braces and quotes, doorbell variants) in every chunking, the mapper, a loopback camera with Digest authentication (probe, snapshot, event stream, reconnect, login guard). **Needs a real-camera test**: the actual event framing, doorbell codes of your model, the lock-out behaviour, and the DNS change (the encoded brackets above; the answer "OK").

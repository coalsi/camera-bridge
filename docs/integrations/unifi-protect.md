# UniFi Protect

**Status: working, with one dependency.** Uses Ubiquiti's **official Protect Integration API** (an API key you create) for the camera list, snapshots, RTSPS streams and events. Video needs the go2rtc helper.

## What works

- **Live view and HomeKit Secure Video recording.** The API hands out the camera's RTSPS address (`rtsps://console:7441/<key>?enableSrtp`). Camera Bridge's own RTSP client speaks plain RTSP only, so the address goes to the go2rtc helper as `rtspx://console:7441/<key>` (go2rtc's TLS RTSP for Ubiquiti; the `?enableSrtp` suffix is dropped, as go2rtc's documentation advises) and Camera Bridge reads the helper's local RTSP. **Without the helper there is no video.**
- **Events from the console's WebSocket** (`wss://console/proxy/protect/integration/v1/subscribe/events`, the same API key): motion, smart detections (person, vehicle, animal, package, face) and **doorbell rings** (Protect doorbells). Smart detections also raise motion so HKSV records them. A missed "event ended" message cannot hold motion on: each event lapses after two minutes.
- Snapshots from the API.
- The camera list in the wizard, so the person picks a camera by name.

## What does not

- Two-way audio, door and light controls, the package camera's second view and licence-plate text (the public API does not carry them).
- Several Protect firmware versions differ in what the public API offers; the console's application version is read (`meta/info`) and shown in Device Info as "Protect 7.x". The endpoints used appear in the API description from Protect 5.3 on. Versions older than that are not supported.
- Plain `rtsp://console:7447/…` addresses (older Protect versions served them) are **not** used: the official API returns RTSPS only, and go2rtc reportedly cannot always negotiate the 7447 variant.

## Set up

1. In UniFi Protect: **Settings › Control Plane › Integrations › Create API Key**. Copy the key (it can see every camera on that console).
2. In Camera Bridge: Add Camera › **UniFi Protect**. Enter the console's address (for example `192.168.1.1`) and the key, press **Find Cameras**, choose the camera. Add a camera per Protect camera you want in Home.
3. Camera Bridge asks the console to enable the camera's RTSPS stream (if it is not on; this is the same as the "RTSP" toggle in a camera's Advanced settings), and hands it to the helper. The camera's `high` stream is used; `medium`/`low` can be chosen in `config.json` (`integration.details.protectQuality`).

The API key is the camera's Keychain "password". Replace it: camera page › Connection › **Replace Key…**; change the console's address: **Console › Change…**.

## Certificates

Protect consoles use a **self-signed certificate** by default. Camera Bridge accepts it for the address you entered (HTTPS calls and the WebSocket) and for the helper (`rtspx` ignores certificate verification, which is what Ubiquiti setups need). It does not check the console's identity beyond that address; use a network you trust.

## Terms and risks

Official, documented API: no terms problem. The key is powerful; keep it in the Keychain (it is), and revoke it in Protect if the Mac is lost. Ubiquiti can change the API in a Protect update.

## Tested how

The camera list, stream creation and reuse, snapshot handling, the event messages (recorded sessions written from Ubiquiti's API description), the event tracker (open events ended by partial updates) and the driver, with a loopback console and a fake helper. **Needs a real-console test**: RTSPS through go2rtc on your Protect version, the WebSocket (headers, certificate, ping), and the console's behaviour when streams are enabled by the API.

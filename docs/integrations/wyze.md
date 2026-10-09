# Wyze

Two routes, and the first is better when the camera has it.

## Wyze Cam v3 / Pan v3: Wyze's official RTSP

**Status: working preset** (needs a real-camera check of the path).

Wyze added RTSP to the production firmware of the **Cam v3 (4.36.16.5654)** and **Pan v3 (4.50.16.5654)** in February 2026 (Wyze app 3.9 or later). It is Wyze's own feature: no cloud, no account in Camera Bridge, no terms-of-service question.

### Set up

1. Update the camera's firmware and the Wyze app.
2. In the Wyze app: open the camera › **Settings › Advanced Settings › RTSP**, turn it on and create an RTSP **user name and password** (the app limits them; they are only for this camera).
3. In Camera Bridge: Add Camera › **Wyze Cam v3 / Pan v3 (Official RTSP)**. Enter the camera's **IP address** (give it a fixed address in your router) and that user and password. Camera Bridge tries `rtsp://<ip>:554/stream0` and then `rtsp://<ip>:554/live`, and keeps the one that works. If the Wyze app shows a different address, use the **RTSP URL** type and paste it.

### What works and what does not

- Live view and HomeKit Secure Video recording. Audio as the camera sends it.
- **No events:** Wyze sends no motion over RTSP; built-in motion detection is used.
- Wyze's RTSP is reported to stop after some hours on some cameras; Camera Bridge reconnects.
- The path is **not confirmed from a primary source**: Wyze's support page could not be read; Wyze's forum and a camera catalogue point at `/stream0` on port 554 for the 2026 firmware, while the older beta firmware used `/live`. That is why both are tried. Report the path your camera uses.
- Wyze's other models (Cam v4, v3 Pro, Pan v2, Outdoor, Doorbell, Floodlight) have no official RTSP announced; Cam v2 and Pan v1 had an older unmaintained beta firmware, which also serves `/live`.

## Other models through go2rtc

**Status: partial.** Uses go2rtc's `wyze:` source ([go2rtc docs](https://github.com/AlexxIT/go2rtc/tree/v1.9.14/internal/wyze)), a pure-Go implementation of Wyze's local P2P protocol.

- Needs a **Wyze account**, a **Wyze developer API key** and ID (from Wyze's developer console, per [Wyze's article](https://support.wyze.com/hc/en-us/articles/16129834216731)), and a camera with **DTLS-enabled firmware**. The internet is used only while go2rtc loads your camera list; streaming is a local connection to the camera.
- **Not supported by go2rtc:** Gwell-based cameras (Wyze Cam OG series, Pan v4).
- Set up: Add Camera › **Wyze (Other Models)** › **Open Sign-In Page**, choose go2rtc's **Add › Wyze**, enter your API ID, API key, email and password, choose the camera, copy the `wyze://…` source and paste it into Camera Bridge. The account password is typed into go2rtc's page; it writes it into that page-helper's configuration in a private temporary folder, deleted when the page closes.
- No events (built-in motion), no doorbell press. Camera Bridge keeps the stream open, so use cameras on mains power.

### Terms

**Unofficial.** Wyze's terms forbid applications other than Wyze's that interact with its products or services without written consent, and forbid reverse engineering; this route is inside that language. The protocol also changes with firmware and new camera lines (DTLS, Gwell), so it can break. Use at your own risk, and prefer the official RTSP where the camera offers it.

## Tested how

Address building, path fallback, the rejected-login stop (one attempt, because cameras lock accounts), source parsing and the helper are covered by tests; no Wyze camera or account was contacted. **Needs a real-device test**: the RTSP path on each firmware, and go2rtc's Wyze source.

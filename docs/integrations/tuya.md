# Tuya / Smart Life

**Status: partial.** Uses go2rtc's `tuya:` source (Tuya Smart API or Tuya Cloud API). Unofficial for the app-account route.

## First, check for ONVIF/RTSP

Many Tuya cameras offer **ONVIF/RTSP** in their own settings (the Smart Life/Tuya app › device › Settings › ... or the camera's web page; availability depends on the model). If yours does, use **ONVIF / RTSP Camera** instead: it is local, official and has no account involved.

## What works

- Live view and HomeKit Secure Video recording through the go2rtc helper ([go2rtc-helper.md](go2rtc-helper.md)).
- No events (built-in motion detection), no two-way audio.

## Set up

go2rtc documents two routes ([Tuya source](https://github.com/AlexxIT/go2rtc/blob/v1.9.14/internal/tuya/README.md)):

- **Tuya Smart API (recommended).** Needs a **Tuya Smart** app account. *Smart Life accounts are not supported*: if the camera is in the Smart Life app, remove it there and add it again in the Tuya Smart app. In Camera Bridge: Add Camera › **Tuya / Smart Life** › **Open Sign-In Page**, choose go2rtc's **Add › Tuya**, select your region and sign in, copy the `tuya://…` source for your camera and paste it into Camera Bridge. The source contains the account email and password: they are kept in your Keychain like any source.
- **Tuya Cloud API.** Needs a project on the Tuya Developer Platform (`device_id`, `uid`, `client_id`, `client_secret`) and the paid **IoT Video Live Stream** service (a free trial exists). Build `tuya://openapi.tuyaus.com?device_id=…&uid=…&client_id=…&client_secret=…` (use the host for your data centre) and paste it under **Other go2rtc Source** or **Tuya**.

## Limits and risks

- **Unofficial** for the app-account route: it imitates the Tuya Smart app's own sign-in. It can break when Tuya changes, and Tuya's terms may not allow it. Use at your own risk.
- The video is a cloud WebRTC session each time it is watched or recorded; Camera Bridge keeps the stream open, so use mains-powered cameras.
- The Tuya Cloud route depends on a paid subscription.

## Tested how

Source validation (both forms), the helper's configuration and secret handling are covered by tests; no Tuya account was contacted. **Needs a real-device test.**

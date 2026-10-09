# Ring

**Status: partial.** Works through go2rtc's `ring:` source with a Ring refresh token. Unofficial.

## What works

- Live view in Camera Bridge and the Home app, and HomeKit Secure Video recordings, from Ring cameras and doorbells.
- Video comes from Ring's servers (WebRTC) through the go2rtc helper ([go2rtc-helper.md](go2rtc-helper.md)) as local RTSP.

## What does not

- **No Ring events.** Motion comes from Camera Bridge's built-in motion detection, which decodes the stream. A **doorbell press is not detected** (Ring's push events are not part of go2rtc's source). The Add Camera webhook can ring the Home doorbell if something else knows about the press.
- **Always streaming.** Camera Bridge keeps the stream open to detect motion and to record, so the camera streams from Ring's servers all the time. Use **mains-powered** cameras. A battery camera or doorbell would drain in hours, and Ring may limit how long a live session lasts or how many are open (Ring's own live view may be refused while Camera Bridge holds one).
- Two-way audio is not offered.

## Set up

Camera Bridge needs a **source** of the form `ring:?camera_id=…&device_id=…&refresh_token=…` (go2rtc's documented format). Two ways to get it:

1. **Easiest: go2rtc's sign-in page.** In Add Camera choose **Ring**, then **Open Sign-In Page**. A page from go2rtc opens in your browser on this Mac (it runs only on `127.0.0.1`). Choose **Add › Ring**, sign in with your Ring email and password and the 2FA code Ring sends, pick the camera, and copy the `ring:?…` source it shows. Paste it into Camera Bridge. Camera Bridge never sees your Ring password.
2. **By hand.** Run `npx -y -p ring-client-api ring-auth-cli` in Terminal (the MIT-licensed [ring-client-api](https://github.com/dgreif/ring), the tool Ring integrations use for tokens; follow its prompts) to get a refresh token. The camera's `camera_id` and `device_id` are shown by go2rtc's sign-in page; there is no other place that lists them.

Camera Bridge stores the source in your Keychain and only the word "ring" in `config.json`.

## Limits and risks

- **Unofficial.** This imitates Ring's own app. Ring's terms prohibit reverse engineering of its software and do not clearly allow third-party clients; Ring can change its service or sign tokens out at any time, which stops the camera (the status says go2rtc's message). Use at your own risk, preferably with a Ring account you can afford to have flagged.
- **Tokens expire.** When Ring invalidates the token, the camera goes offline: repeat the sign-in and use camera page › Connection › Replace Source….
- Ring's official Appstore API (WHEP / RTSP bridge, partner certification) is not used; it is gated to approved partners.

## Tested how

Source parsing and validation, the helper's configuration, secret handling and the driver are covered by tests with doubles; a real Ring account was never contacted. **Needs a real-device test**: signing in through go2rtc's page, a stream starting, and token expiry behaviour.

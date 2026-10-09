# Google Nest

**Status: working guided setup, with Google's limits.** Uses Google's official Device Access (Smart Device Management) API through go2rtc's `nest:` source.

## What works

- Nest cameras and doorbells: live view and HomeKit Secure Video recording through the go2rtc helper ([go2rtc-helper.md](go2rtc-helper.md)). Wired and newer cameras and doorbells stream over WebRTC, legacy cameras (Nest Cam, Hub Max) over RTSP; the wizard picks what the camera lists.
- A guided setup in the Add Camera wizard: links to Google's consoles, the sign-in link, the code exchange and the camera list (Camera Bridge calls Google's documented endpoints for those steps; nothing is sent before you press the button).

## What does not

- **No Nest events** in Camera Bridge (Device Access delivers them through Google Pub/Sub, which needs a public endpoint or your own Cloud project). Motion is the built-in detection; a doorbell press is not detected.
- **Sessions last five minutes.** Google ends each live stream after five minutes, so the stream restarts now and then; battery cameras cannot extend a WebRTC session. Camera Bridge keeps the stream open to detect motion and record, so use mains-powered cameras.
- Google's RTSP streams for legacy cameras allow one client at a time.
- Device Access is limited while a project is not approved for commercial use (the sandbox allows a handful of users and structures); for your own home that is enough.

## Set up

1. **Register for Device Access** at <https://console.nest.google.com/device-access>. Google charges a one-time **US$5** fee to its console account. Create a **project**; note its project ID.
2. **Create an OAuth client** in [Google Cloud](https://console.cloud.google.com/apis/credentials) (Credentials › Create credentials › OAuth client ID, type **Web application**), add `https://www.google.com` as an **authorized redirect URI**, and enable the **Smart Device Management API** in the same Cloud project. Put the **client ID** in the Device Access project's OAuth settings. Note the client ID and secret.
3. In Camera Bridge: Add Camera › **Google Nest**: enter the project ID, client ID and client secret. Press **Open Google's Sign-In Link**, sign in with the Google account that owns the cameras and allow access to your devices (Google lists the home's devices to choose).
4. Google then shows a page with a code in its address (Chrome may say the page cannot be reached: that is expected, the address is what matters). Copy the whole address (or the part after `code=`) and paste it into **Code**, then **Connect**. Camera Bridge exchanges the code for a refresh token and lists the cameras; choose one.

The client secret and refresh token are kept inside the camera's go2rtc source in your Keychain. The code is used once and forgotten.

## Limits and risks

- Official API, so no terms-of-service problem; the practical risks are Google's sandbox limits, the $5 fee, and that a refresh token can be revoked (Google account › Security › third-party access), which takes the camera offline until you repeat step 3–4 (camera page › Connection › Replace Source… needs a new source; use the wizard to add the camera again).
- Google's documentation: <https://developers.google.com/nest/device-access>.

## Tested how

The authorization link, code extraction, the token exchange, device listing and the source built from them are covered by tests with a fake transport; Google was never contacted. **Needs a real-device test**: the whole sign-in, the stream, and the five-minute restarts.

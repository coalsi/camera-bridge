# TP-Link Tapo

**Status: guide (no new code).** Tapo cameras already work through Camera Bridge's ONVIF/RTSP support; the Camera Type page has a Tapo entry that routes to ONVIF and shows the setup steps.

## Set up

1. In the Tapo app: the camera › **Settings › Advanced Settings › Camera Account**, create a user name and password. This is a separate account for RTSP and ONVIF, **not your TP-Link login**.
2. In Camera Bridge: Add Camera › **TP-Link Tapo**, pick the camera or type its address, and sign in with the camera account. Tapo's ONVIF service is on port 2020; Camera Bridge finds it.
3. RTSP, if you need it by hand: `rtsp://<account>:<password>@<ip>:554/stream1` (HD) and `/stream2` (SD).

## Limits

- About 40 models support RTSP/ONVIF; **battery-powered Tapo cameras do not**.
- Events: ONVIF events where the model offers them (some Tapo cameras close the event subscription quickly; Camera Bridge then falls back to its built-in motion detection by itself).
- Cloud storage, the SD card and NVR recording can compete for the camera's few streams.
- go2rtc also has a `tapo://` source (the cloud password; two-way audio). It can be used under **Other go2rtc Source**, but is not needed for video and is not set up by the wizard.

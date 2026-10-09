# Camera integrations

Camera Bridge reads ONVIF and RTSP cameras directly. This folder describes everything else it can add, with what works, how to set it up, what does not, and what the service's terms say. The list is in the Add Camera wizard's first page, Camera Type.

| Camera | How | Live view | HomeKit recording | Events | Status |
|---|---|---|---|---|---|
| ONVIF / RTSP (auto-detect), Hikvision, Reolink | direct | yes | yes | camera events (ISAPI, Reolink API, ONVIF) or built-in motion | shipped earlier |
| [TP-Link Tapo](tapo.md) | ONVIF + RTSP (preset and guide) | yes | yes | ONVIF where the model allows, else built-in motion | guide only |
| [Amcrest / Dahua](amcrest-dahua.md) | native adapter | yes | yes | motion, people, vehicles, tamper, sound, doorbell press | working, needs a real-camera check |
| [DoorBird](doorbird.md) | native adapter (official LAN API) | yes | yes | doorbell press, motion | working, needs a real-device check |
| [UniFi Protect](unifi-protect.md) | official Integration API + go2rtc for RTSPS | yes | yes | motion, smart detections, doorbell ring (WebSocket) | working, needs a real-console check |
| [Wyze Cam v3 / Pan v3](wyze.md) | Wyze's official RTSP | yes | yes | built-in motion only | working preset, needs a real-camera check |
| [Wyze (other models)](wyze.md#other-models-through-go2rtc) | go2rtc `wyze:` (unofficial P2P) | yes | yes | built-in motion only | partial: depends on go2rtc and DTLS firmware |
| [Ring](ring.md) | go2rtc `ring:` (unofficial cloud) | yes | yes | built-in motion only | partial: paste a source; unofficial |
| [Google Nest](google-nest.md) | go2rtc `nest:` with Google's official Device Access | yes | yes | built-in motion only | working guided setup; limits below |
| [Tuya / Smart Life](tuya.md) | go2rtc `tuya:` (unofficial cloud) | yes | yes | built-in motion only | partial: paste a source; unofficial |
| Other go2rtc source | go2rtc (`kasa:`, `tapo:`, `xiaomi:`, `rtspx:` …) | yes | yes | built-in motion only | partial: paste a source |

Not built, and why: **Arlo** (cloud-only, no public API, impersonation of the vendor's own clients), **eufy** (reverse-engineered cloud and P2P with captcha handling; HomeKit-capable eufy models and RTSP-capable ones work through the normal types). See [../research/camera-integrations.md](../research/camera-integrations.md).

## How the cloud and console types work

Cameras that offer no RTSP or ONVIF address are reached through **go2rtc** (MIT), a small program that speaks those services' protocols and republishes each camera as plain RTSP. Camera Bridge ships go2rtc inside the app and runs it as a managed helper on this Mac: [go2rtc-helper.md](go2rtc-helper.md). Nothing is installed by the person, there is no plug-in store, and the helper listens on `127.0.0.1` only.

Camera Bridge keeps each camera's stream open to detect motion and to record, so a cloud camera is streamed from its service all the time. Use cameras on mains power. Battery cameras and doorbells would drain in hours, and some services cap session length.

## Motion and doorbell events

Native adapters (Amcrest/Dahua, DoorBird, UniFi Protect, Hikvision, Reolink, ONVIF) receive the camera's own events. Cameras behind go2rtc send none: Camera Bridge's built-in motion detection (Motion › Built-in) is the motion source, and a doorbell press cannot be detected (the webhook can ring the doorbell if something else knows).

## Terms of service

Official routes (ONVIF/RTSP, Amcrest/Dahua CGI, DoorBird LAN API, UniFi Integration API, Google Device Access, Wyze's own RTSP) are what the vendor documents or ships. Unofficial routes (Ring, Wyze P2P, Tuya) work by imitating the vendor's own app; they can stop working without notice, and the vendor's terms may not allow them. Each page says so. You use them at your own risk; Camera Bridge never sees the account password of those services (the person types it into go2rtc's own page, or builds the token themselves) and keeps only the resulting source in the Keychain.

## Licences

Protocols were implemented from vendors' public documentation and from MIT- or Apache-licensed projects, each cited in the code where it is followed. No code of Scrypted's plug-ins (mostly unlicensed) or of GPL projects (python-amcrest) was copied. go2rtc's licence text: [../third-party/go2rtc.md](../third-party/go2rtc.md).

## What needs a real device

Everything here is tested against recorded payloads and local doubles; none was run against a real camera or account (this was built without contacting any). The first real use of each should be watched: the **Amcrest/Dahua event stream** (framing, doorbell codes), **DoorBird's monitor**, **UniFi's WebSocket** and RTSPS through go2rtc, **Wyze's official RTSP path** (`/stream0` or `/live`), and each **cloud source** (Ring, Nest, Wyze, Tuya). The Add Camera wizard shows what the service said when a check fails.

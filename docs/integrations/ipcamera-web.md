# The IPCamera Web family (cameras whose web page is titled "IPCamera Web")

A family of OEM cameras whose web page is titled **IPCamera Web** has its own web API next to ONVIF. The owner's "Patio New" is one: model
`N801B-RB-IRC-WM701`, ONVIF manufacturer `A_ONVIF_CAMERA`, the maker's phone app VisionEye. Camera Bridge adds them as ONVIF cameras
(streams, events, time zone and time stay ONVIF) and uses their API for the security check and three steps of Set up for Camera Bridge.
Code: `Packages/CameraBridgeKit/Sources/CameraAdapters/IPCamWeb/`. It is not the [IP camera web API](ip-camera-web-api.md) (Jennov and other
Anjvision cameras): another family, another protocol.

The protocol below was checked by hand with the owner signed in to the camera's page. The bridge's use of it is tested against a fake
camera (`FakeIPCamWebCamera`) only.

## What Camera Bridge does with it

| Feature | How |
|---|---|
| Security check | Reads the cloud of the VisionEye app (`mobile`), DDNS, RTMP, UPnP, the other clouds (`cloud`, `p2p`, `platform`), the extra services (`hik`, `meari`: one that is on with `authorized` 0 lets anyone at home connect without a password, which counts as video without a password) and whether RTSP and ONVIF ask for the password; never writes |
| Set up for Camera Bridge, **Cloud off** | `mobile` `on` 1 → 0, read back; Restore turns it back on |
| Set up for Camera Bridge, **Video password** | `rtsp` and `onvif` `authorized` 0 → 1, read back. Offered only when Camera Bridge has a password saved for the camera (it already sends the camera's username and password when its RTSP asks for them) |
| Set up for Camera Bridge, **Extra services off** | `hik` (a Hikvision-compatible protocol on port 8000) and `meari` (the Meari service on port 10000) `on` 1 → 0, read back |

Each step's old values are kept in the camera's one setup backup, and "Restore original settings" writes them back, each read back. The
UPnP step says "not supported by this camera": the family has no UPnP (`get=upnp` answers "no option"). Other cameras are not offered the
Video password and Extra services steps.

## Which cameras are asked

The sign-in value is the camera's login, so Camera Bridge sends it only to a camera whose page is the family's, checked without
credentials: `GET /` must be titled `IPCamera Web` and load `../js/script/land.js`, and `GET /js/script/land.js` must answer 200 and hold
`auth.cgi?act=auth`. A page that does not load (a connection error, a timeout, a 5xx) is not known yet and is asked again next time.
Only ONVIF cameras are checked this way, and only when the camera is not of the IP camera web API's family.

## The protocol

- Every call is an HTTP `GET` without a body on the camera's web port (80): `/cgi/<name>.cgi?<op>=<what>&auth=<authid>&data=<xml>&guid=<ms>`.
  Every value is percent-encoded (everything but letters, digits and `-._~`), so the camera reads the XML exactly. `guid` is the time in
  milliseconds.
- Sign in: `GET /cgi/auth.cgi?act=auth&auth=123456&data=<xml>&guid=<ms>` with
  `<?xml version='1.0'?><root><mode>1</mode><encrypt>HEX</encrypt></root>`. `HEX` is the lowercase MD5 of `username:password` (32 hex
  characters, as ASCII) encrypted with RC4 under the key `pwnsd`, each byte as two lowercase hex digits. Vectors: `admin` / `pa55word` →
  MD5 `8c7796aa1c0c8a48b36c8c1c445b2040` → `675c8aa16a7497f0969783ab123741ac64b225369591e2430e465d4403c211a3`; `admin` with an empty password
  → `6e598af2667295a491c78bf9483445a134b0246c9fc0b1445b4b5b1601c211f0`.
- The answer `<root><code>0</code>…<authid>SESSION</authid>…</root>` (or code 531355, also signed in) gives the session, reused for every
  call until the camera answers 531203 (session expired): then Camera Bridge signs in once more and asks again, once.
- Any other sign-in answer is a refusal. Camera Bridge then sends nothing more to the camera's API until the camera starts again in the
  bridge, says so once in the camera's log, and pauses the camera's logins (shared with ONVIF: the same account).
- Reads: `GET /cgi/network.cgi?get=<what>&auth=<authid>&guid=<ms>`. Writes: `…?set=<what>&auth=<authid>&data=<xml>&guid=<ms>`, read back
  after. Answers are `<root>…</root>`; an error is `<root><code>N</code><error>text</error></root>`, and 532229 ("no option") means the
  camera has no such feature.
- Nothing the camera answers, no session and no sign-in value is ever logged or kept. The `mobile` answer holds the camera's cloud id and
  the `ddns` answer a DDNS account: only the switches are looked at.

### Readings (identifiers left out)

| Read | Answer on the owner's camera | Camera Bridge |
|---|---|---|
| `get=mobile` | `<mobile on="0" sendalarm="1" cuid="…"/>` | the VisionEye app's cloud: `on="1"` is on, link to an account unknown |
| `get=ddns` | `<version version="0"/><ddns on="0" type="0" account="…" port="80" name="" pwd="…" times="3600"/>` | DDNS |
| `get=rtmp` | `<version version="1"/><rtmp on="0"><url …/></rtmp>` | RTMP push |
| `get=upnp`, `get=cloud`, `get=p2p`, `get=platform` | code 532229 | absent |
| `get=meari` | `<meari on="1" authorized="0" port="10000"/>` | an extra service (`authorized="0"`: no password) |
| `get=hik` | `<hik on="1" authorized="0" port="8000" dataport="8200"/>` | an extra service |
| `get=onvif` | `<version version="4"/><onvif on="1" … authorized="0" companyname="A_ONVIF_CAMERA" …/>` | ONVIF without a password |
| `get=rtsp` | `<version version="1"/><rtsp port="554" rtspsport="322" authorized="0" mtu="1400" …/>` | RTSP without a password (a DESCRIBE without credentials really answers 200 with the SDP) |
| `get=wifiap` | `on="1"`, but `devicemanage.cgi?get=sysinfo` says `wifi="0"` | not read: the camera has no radio |

### Writes (as the camera's page writes them)

| Write | `data` |
|---|---|
| `set=mobile` | `<?xml version='1.0'?><root><mobile on='0'></mobile></root>` (`on='1'` to restore) |
| `set=rtsp`, `set=onvif` | `<?xml version='1.0'?><root>` + the element as read with only `authorized` changed + `</root>` |
| `set=hik`, `set=meari` | the element as read with only `on` changed (the page writes `<meari on='0' authorized='0' port='10000' />`) |

## Security levels

The check's readings go into the camera's security level (red "Outside access possible", yellow "Needs work", green "Good", gold "Local
only"; `BridgeEngine/Security/CameraSecurity.swift`). On the owner's camera as it was: the VisionEye cloud on with its link unknown is red;
with the cloud off, the open RTSP and ONVIF keep it yellow; with the video password on, the Meari and Hikvision services keep it green until
they are off too; gold needs the Internet guard as well (Camera Bridge OS).

Tests: `IPCamWebTests` (RC4 and MD5 vectors computed outside Camera Bridge, the page check, the sign-in and its session, the latch, the
query encoding, no secrets in the log), `IPCamWebSetupTests` and `RemoteAccessTests` against `FakeIPCamWebCamera`.

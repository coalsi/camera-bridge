# IP camera web API (cameras with the "IP Camera Web Login" page)

A family of OEM pan/tilt and bullet cameras built on an Anjvision platform (made by ESUNSTAR and others, sold under many brands, for
example Jennov) has its own web API next to ONVIF. Their sign-in page shows **IP Camera Web Login**; the firmware version reads like
`JM800S5_AF_V100-A_YSSD-RTMP-H5 V3.4.0.3 build 2024-10-23`. Camera Bridge adds them as ONVIF cameras and uses this API for what their
ONVIF reports wrongly. Code: `Packages/CameraBridgeKit/Sources/CameraAdapters/IPCWeb/`.

What their ONVIF gets wrong (checked by hand on a JM800S5, 2026-10-16): imaging IR-cut writes are ignored and always read back `AUTO`;
the PTZ node lists a `tt:Lamp` auxiliary command and then refuses it (`ActionNotSupported`); the on-screen display read-back can say
done when nothing changed. Its DNS servers too (2026-10-18): the owner's took ONVIF's `SetDNS` for the internet guard and read it back as
the bridge, and later `GetDNS` showed its original server again (`FromDHCP` false, `DNSManual` 1.1.1.1). ONVIF's encoder and time/NTP
settings do work, and the streams are RTSP `/stream0` and `/stream1` on port 554.

## What Camera Bridge does with it

| Feature | How |
|---|---|
| Night vision (auto, on, off) and the IR lights | The camera's video settings (`Capture`), read back after every change |
| Set up for Camera Bridge, **Clean picture** | The on-screen text switch (`Overlay Enable`); `0` takes the camera's title and clock off |
| Set up for Camera Bridge, **Cloud off** | The maker's cloud switch (`P2PConfig Enable`), its kind and sign-in value kept for Restore |
| Set up for Camera Bridge, **Watch its internet**, and the Internet guard's readings of the camera's DNS | The camera's own network settings (`LANConfig` `DNS1` and `DNS2`), read back after the change; only in Mode Static (below) |
| Security check | Reads only: the cloud (`P2PConfig Enable`; whether it is linked to an account is not known: `LoginStatus` says whether it is signed in now, not whether it is bound) and UPnP (`UPNPConfig Enable`). RTMP stays unknown: `getMediaStreamConfig` is not among the calls checked by hand, and a call the camera lacks pauses its web API (and night vision) until the camera restarts in the bridge |
| Apple Home **Night Vision** | On is the camera's own automatic mode, off is the day picture with the IR lights off; a change the camera does not take (or that the bridge cannot pass on yet) puts Home back as it was |

Everything else (streams, time zone, time from the bridge) stays ONVIF. A camera that does not speak the API is used through ONVIF
only, and so is the DNS of one whose web API shows no `LANConfig`. A camera of the family never gets ONVIF's night vision, on-screen
display or DNS, whose answers these cameras get wrong: while its web API is paused, does not answer, or cannot take its username or
password, night vision is not offered yet (it is asked again), Clean picture, Cloud off and Watch its internet say why and change
nothing, and the Internet guard's reading of its DNS is unreadable (it changes nothing).

## Which cameras are asked

The sign-in values below can be turned back into the username and password by anyone who sees them (the key is in the camera's own
page). So Camera Bridge first loads the camera's sign-in script (`GET /jsCore/rpcLogin.js` on its web port, with no credentials) and
sends them only when the script holds both `des("WebLogin"` and `/ipcLogin`. The sign-in page itself can't tell: its HTML title is
empty and scripts draw the "IP Camera Web Login" box. Every other ONVIF camera gets nothing new: only that one script load, at each
start. The answer is remembered for the camera's address until the camera next starts in the bridge.

Three answers are told apart. A 2xx with both markers: the family. A 2xx without them, or a 4xx such as 404: another camera, not asked
again. No answer (a connection error, a timeout, or a 5xx while the camera starts): not known yet, so nothing is remembered and the next
use asks again. Night vision then waits: it is asked again, and only once ONVIF answers while the web server still does not (three more
tries, about a minute) does the camera get ONVIF's night vision. The setup takes no answer as no web API for that run.

## The protocol

- Every call is `POST http://<camera>:<web port>/<name>` (the camera's web port, usually 80). The `Content-Type` must be exactly
  `application/x-www-form-urlencoded`, with no charset: with any other type the request reaches the camera's ONVIF server, which answers
  HTTP 500 with a `SOAP-ENV:Fault`. No cookie or session.
- The body is this envelope (`\t` is a literal tab), with the call's own body (often empty) in place of `BODY`:

  ```text
  <?xml version="1.0"?><soap:Envelope xmlns:soap="http://www.w3.org/2001/12/soap-envelope"><soap:Header>\t<userid>U</userid>\t<passwd>P</passwd></soap:Header><soap:Body>BODY</soap:Body></soap:Envelope>
  ```

- `U` and `P` are the username and the password (as typed, not hashed), each encrypted with DES-ECB under the 8-byte key `WebLogin`
  after zero-padding to a multiple of 8 bytes, in lowercase hex; an empty text gives an empty value. The camera's page works per
  character code, so the text is taken as ISO-8859-1: a username or password with a character above U+00FF cannot be sent. The sign-in
  script still shows such a camera is of the family (it needs no login): it gets no night vision through the bridge, and Clean picture and
  Cloud off say the username or password has a character the camera's web API cannot take. Vectors: `admin` → `52851dbd7918bbae`; `abcdefgh` → `4b24819b8505b9b5`; `abcdefghi` →
  `4b24819b8505b9b5e8b7e01c8a97a456`. These values are as good as the password: they are never logged or shown.
- Reads answer 200 with XML; writes answer 202 Accepted with an empty body. A non-2xx status, a SOAP fault, or a read without its
  expected root element is a failure.
- What a wrong password answers is not known, and the camera locks its account after repeated failures. After one refusal (a non-2xx
  status, a fault, or the words `passwordError` / `passwordLock`) Camera Bridge sends nothing more to that camera's web API until the
  camera starts again in the bridge, and says so once in the camera's log.
- The web API and ONVIF sign in with the same account, so they share Camera Bridge's login pause: nothing is sent to the web API while
  ONVIF's logins to the camera are paused, and `passwordError` (or HTTP 401 / 403) pauses them for two minutes, `passwordLock` for 30.
  Other refusals pause only the web API (they may not be about the login).

### Calls

| Call | Body | Answer |
|---|---|---|
| `getSystemVersionInfo` | empty | `<SystemVersionInfo><VersionInfo kernelVersion="…" fsVersion="…"/><SerialNumber …/></SystemVersionInfo>`: the probe |
| `getSystemControlString` | empty | Plain text feature flags joined by `+`: night vision needs `ircut_setting`, the IR lights `ircut_leddelay`, the cloud `p2p_config` (or a `P2PConfig` element in `getNetworkConfig`) |
| `getMediaVideoConfig` | empty | `<Video><Capture …>…</Capture><Encode>…</Encode><JpegConfig …/><Overlay …>…</Overlay><Mask>…</Mask>…</Video>`, attributes over several lines |
| `setMediaVideoCaptureConfig` | `<Video>` + the `Capture` element as read, only the changed values replaced, + `</Video>` | 202 |
| `setIRCutManual_DayNight` | `DayMode` or `NightMode` | 202; only takes effect while `IrcutMode` is 3, and has no read |
| `setMediaVideoOverlayConfig` | the `Overlay` element as read, with `Enable` changed | 202 |
| `getNetworkConfig` | empty | `<NetworkConfig><LANConfig …/>…<P2PConfig Enable="1" Type="…" Authcode="…"/>…</NetworkConfig>`; also holds e-mail, FTP and Wi-Fi passwords: never logged or kept whole |
| `setNetworkLANConfig` | the `LANConfig` element as read, with only `DNS1` and `DNS2` changed (the page sends `<LANConfig …/>` alone, no `NetworkConfig` around it) | 202; the camera may restart its network service |
| `setNetworkP2PConfig` | `<NetworkConfig><P2PConfig Enable="0" Type="…" Authcode="…"/></NetworkConfig>` with the kind and sign-in value read (XML-escaped) | 202 |
| `getNetworkStatus` | empty | `<NetworkStatus>…<CLOUD Enable="1" Type="…" LoginStatus="1" ID="…"/></NetworkStatus>` (`LoginStatus` 1: signed in to its cloud) |
| `getMediaStreamConfig` | empty | the stream settings with `<StreamAccess … enable_rtmp="0" or "1" …/>`: not sent until it is confirmed on a real camera (a call the camera lacks pauses its web API, and night vision with it) |

Every write is a read-modify-write of the element as the camera wrote it (read just before, read back after). Night vision and the
IR lights write the same `Capture` element, so their changes run one at a time.

### Night vision and the IR lights (`Capture`)

| `IrcutMode` | Meaning | Camera Bridge |
|---|---|---|
| 0 | Automatic, from the picture | auto |
| 1 | By the clock (`IrcutNightStartTime` to `IrcutNightEndTime`) | auto |
| 2 | The light sensor (the factory setting) | auto |
| 3 | Manual, day or night set with `setIRCutManual_DayNight` | the mode the bridge last set, else unknown |
| 6 | Manual, lights always on | on |
| 7 | Manual, lights always off | off |

- **auto** leaves 0, 1 and 2 as they are; from a manual mode it goes back to the automatic mode last seen during this run, else 2.
- **on** (IR on, a black-and-white night picture) is `IrcutMode` 3, then `NightMode`; **off** (IR off, a colour day picture) is 3, then
  `DayMode`. When the day/night command fails after the switch to 3, the mode from before is written back once (best effort), so the
  camera is not left in a manual mode nothing shows.
- `led_mode`: 0 infrared, 1 white light, 2 smart dual light. `led_brightness_mode`: 1 manual, 2 automatic (the factory setting), 3 low
  power. `led_brightness_value`: 0–100 in steps of 10, the manual brightness (0: the lights are off).
- The lights are on unless the brightness is manual at 0. Off is `led_brightness_mode` 1 with `led_brightness_value` 0; on is
  `led_brightness_mode` 2, with the manual brightness put back (the last non-zero value seen, else 100) so manual never stays at 0.

### On-screen text and the cloud (Set up for Camera Bridge)

- **Clean picture**: `Overlay Enable="0"` removes both the camera's title and its clock from the picture. The old value is the backup.
- **Cloud off**: `P2PConfig Enable` 1 → 0, keeping `Type` and `Authcode`. The setup backup holds the switch and `Type`. The `Authcode`
  (the camera's sign-in to its maker's cloud) is kept apart, in the platform's secret store (the Keychain on a Mac), because the
  camera's configuration and its setup backup go to the bridge's page and into the Mac's backup files; it is never logged, and it is
  deleted once a restore gave it back (or when the camera is removed, even if its password could not be deleted). Restore writes all
  three back (the camera's own `Authcode` when none was kept); when the secret store cannot be read, the cloud step fails, changes
  nothing and keeps the saved value for the next try.
- The cameras have a UPnP switch in `getNetworkConfig` but no known call to change it: the UPnP step says Camera Bridge can't change it yet
  and to block the camera's internet in the router (the security check reads the switch).

### DNS servers (the Internet guard's Watch, `LANConfig`)

What the camera's own page does, read in its `networkConfig.js` (Network › Basic, the TCP/IP tab; the page names the fields Mode,
Preferred DNS Server and Alternate DNS Server): it reads `getNetworkConfig` and takes the first `LANConfig`, whose attributes are
`MacAddress`, `DHCP`, `dhcpOffTime`, `ALLNET`, `IPAddress`, `Netmask`, `Gateway`, `DNS1`, `DNS2`, `hostname` and `MTU` (the order the
camera's settings export has; the owner's has exactly these). `DHCP` 0 is Mode Static, anything else DHCP. Confirm writes
`setNetworkLANConfig` with all eleven, as typed, unescaped. In Mode DHCP the page disables the address, mask, gateway and both DNS fields
and sends them as read: the page changes DNS servers only in Mode Static.

- **Read** (the setup's preview, and the Internet guard's reading every 30 minutes and in the security check): the servers are `DNS1` and
  `DNS2`, each once, an empty slot (`0.0.0.0`) none; from DHCP unless `DHCP` is 0. On DHCP the page shows the servers the camera has now
  as it shows its leased address, so they are taken as the servers in use (if the router's DHCP hands out the bridge while the camera
  shows others, it reads as not watched: the safe side). The backup keeps `DNS1` and `DNS2` as they are and `DHCP`, `DNS1`, `DNS2` as
  text (`CameraDNSBackup.ipcWebAPI`), nothing else of the answer.
- **Watch** (Mode Static only): `LANConfig` as the camera wrote it with `DNS1` and `DNS2` the bridge's address (IPv4) and every other
  character as it was, sent only when it holds all eleven attributes, each once, and its `IPAddress` is the address Camera Bridge reaches
  the camera at; anything else is refused rather than written ("not ones Camera Bridge can write back exactly"), because the call takes
  the camera's address with it. A camera on DHCP is refused, and its mode never switched (that would fix its address): the step says
  so and points at Network › Basic (TCP/IP), Mode Static; the preview does not offer the change. Already done when the camera asks the
  bridge and no other (its router's DHCP may hand it out).
- **Read back** through the same call, every 2 seconds for up to 30: the camera may restart its network service after the write, so a
  request that gets no answer meanwhile (a dropped connection, a timeout), and a write it did not answer, are no refusal. A refusal (an
  HTTP error, a SOAP fault) pauses the web API as any other does, and the step says so.
- **Restore** writes the backup's `DNS1` and `DNS2` back the same way, read back, nothing written when the camera already has them. A
  camera switched to DHCP since is refused (its page cannot take them). A backup saved through ONVIF by a build before 2026-10-18 (the
  servers ONVIF showed) goes back through this API, one server in both slots, when the camera is in Mode Static, and through ONVIF as
  that build wrote it when the camera is on DHCP (Watch never writes the page then) or the backup cannot be said in two slots.

Not yet done on a real camera. The owner's settings export of 2026-10-16 shows it on DHCP (`DHCP` 1, `DNS1` 8.8.8.8, `DNS2` 1.1.1.1):
while it is, its Watch is refused, saying where to set Mode Static.

Tests: `IPCWebTests`, `IPCWebSetupTests`, `IPCWebDNSTests` (the DNS: exact `setNetworkLANConfig` bodies, the restart, Restore, DHCP,
ONVIF beside it), `RemoteAccessTests` (fake camera `FakeIPCWebCamera`) and `IPCWebSetupEngineTests`; nothing was tested against a real
camera by the test suite.

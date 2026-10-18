# The IPCamera Web family (cameras whose web page is titled "IPCamera Web")

A family of OEM cameras whose web page is titled **IPCamera Web** has its own web API next to ONVIF. The owner's "Patio New" is one: model
`N801B-RB-IRC-WM701`, ONVIF manufacturer `A_ONVIF_CAMERA`, the maker's phone app VisionEye. Camera Bridge adds them as ONVIF cameras
(streams, events, time zone and time stay ONVIF) and uses their API for the security check, three steps of Set up for Camera Bridge, and
"Watch its internet" where ONVIF cannot point both of the camera's DNS servers at the bridge.
Code: `Packages/CameraBridgeKit/Sources/CameraAdapters/IPCamWeb/`. It is not the [IP camera web API](ip-camera-web-api.md) (Jennov and other
Anjvision cameras): another family, another protocol.

The protocol below was checked by hand with the owner signed in to the camera's page, and against the page's own scripts (`land.js`,
`common.js`, `md5-min.js`, loaded without signing in; Oct 18, 2026). The bridge's use of it is tested against a fake camera
(`FakeIPCamWebCamera`) only. Through build 0.1.110 the bridge encrypted the lowercase MD5 (see the sign-in below), so the owner's camera
refused every sign-in. Build 0.1.111 could not read a code from the answer to its corrected sign-in and stopped the API ("answered Camera
Bridge's sign-in without a code": that one line stood for no `<root>`, no `<code>` and a code that is not a number). It was most likely
`<root>` without `<code>`, which the camera's page reads as 0, signed in (see the codes below); later builds log the three apart
("something other than its XML", "a code that is not a number"). Whether that answer held a session has not been seen yet.

## What Camera Bridge does with it

| Feature | How |
|---|---|
| Security check | Reads the cloud of the VisionEye app (`mobile`), DDNS, RTMP, UPnP, the other clouds (`cloud`, `p2p`, `platform`), the extra services (`hik`, `meari`: one that is on with `authorized` 0 lets anyone at home connect without a password, which counts as video without a password) and whether RTSP and ONVIF ask for the password; never writes |
| Set up for Camera Bridge, **Cloud off** | `mobile` `on` 1 → 0, read back; Restore turns it back on |
| Set up for Camera Bridge, **Video password** | `rtsp` and `onvif` `authorized` 0 → 1, read back. Offered only when Camera Bridge has a password saved for the camera (it already sends the camera's username and password when its RTSP asks for them) |
| Set up for Camera Bridge, **Extra services off** | `hik` (a Hikvision-compatible protocol on port 8000) and `meari` (the Meari service on port 10000) `on` 1 → 0, read back |
| Set up for Camera Bridge, **Watch its internet** (Camera Bridge OS) | ONVIF `SetDNS` first; when ONVIF keeps a server that is not the bridge, `eth`'s `dns` `ondhcp` 0 with the bridge as both `dns1` and `dns2`, read back. See [DNS](#dns-watch-its-internet) |

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
  `guid` is the time in milliseconds. The page appends the XML to the URL as it is (`AjaxSubmitEx`), so its browser percent-encodes only
  what a URL's query can't hold (the WHATWG URL standard's special-query set: controls, space, `"`, `#`, `'`, `<`, `>`, and what is not
  ASCII) and sends `=`, `/`, `?` and `:` raw. Camera Bridge sends the same bytes, and also encodes `&`, `+` and `%` (they would change the
  query's meaning) and `[`, `\`, `]`, `^`, `` ` ``, `{`, `|`, `}` (a URL can't carry them raw). The sign-in of the vector below goes out as
  `/cgi/auth.cgi?act=auth&auth=123456&data=%3C?xml%20version=%271.0%27?%3E%3Croot%3E%3Cmode%3E1%3C/mode%3E%3Cencrypt%3E677c…11a3%3C/encrypt%3E%3C/root%3E&guid=…`.
- Sign in: `GET /cgi/auth.cgi?act=auth&auth=123456&data=<xml>&guid=<ms>` with
  `<?xml version='1.0'?><root><mode>1</mode><encrypt>HEX</encrypt></root>`. `HEX` is the MD5 of `username:password` in **uppercase** hex
  (32 characters, as ASCII: the page's `md5-min.js` ends with `.toUpperCase()`) encrypted with RC4 under the key `pwnsd`, each byte as two
  lowercase hex digits (the page's `RC4Hex(md5(user + ":" + password), true)`). Vectors (Python's hashlib and RC4 written apart, OpenSSL's
  `rc4-40`): `admin` / `pa55word` → MD5 `8C7796AA1C0C8A48B36C8C1C445B2040` →
  `677c8aa16a74b7d096b7838b121741ac44b2251695b1e2630e465d6403c211a3`; `admin` with an empty password → `1F7D50C56381BB05217922BDA930004C` →
  `6e798ad26672b5a491c78bf9681445a134b0246c9fc091647b4b5b1601c211d0`. A camera never matches the lowercase hash.
- The answer codes are the page's (`land.js`, `common.js`). The page reads an answer's code with `hXmlVal({t:'code'})`, whose default is 0:
  an answer of the camera's (`<root>…</root>`) without `<code>` (or with an empty one) is code 0.

  | Code | At the sign-in | At a read or write |
  |---|---|---|
  | 0 | signed in: `<authid>SESSION</authid>` is the session, reused for every call; without an `authid`, "the camera signed in without giving a session" (`IPCamWebUnavailable.noSession`; nothing is latched) | done |
  | none (`<root>` without `<code>`) | 0, as the page reads it: signed in with its `authid` (else no session, as for 0). most likely how Patio New answered build 0.1.111's sign-in, which that build could not read and stopped the API for | 0: done (the reads never carry a code) |
  | 532379 | signed in, with a session, but the camera calls the password insecure (the page then asks for a new one: 9 to 16 characters with a letter, a digit and a symbol). Camera Bridge uses the session, says once in the camera's log that the camera asks for a stronger password, and keeps it for the address (`IPCamWebClient.asksForStrongerPassword`, for the security check) | — |
  | 532227 | a refusal | the session is not valid (the page goes back to its sign-in): Camera Bridge signs in once more and asks again, once |
  | 532374 | a refusal, said as "no privilege" by every step after it (the latch keeps the code): use an administrator account in the camera's settings. Those steps are changes the account may not make (owner decision, Oct 18): the setup goes on with the steps after them | "No Privilege": the account may not do this, said as such, with the same advice; the session still serves. At a write it is a change the account may not make (`CameraAdapterError.notPermitted`, "the account Camera Bridge uses may not change this; use an administrator account in the camera’s settings"): nothing is latched, and the setup goes on with the steps after it |
  | 532229 | — | "no option": the camera has no such feature |
  | any other | a refusal (the page says "Login Failed!" for all of them; what a wrong password answers is not known) | an error with its code |

- A refused sign-in (or any request answered HTTP 401 or 403) stops only the camera's web API. Camera Bridge logs the camera's code
  (never the URL, the sign-in value, a session or the answer) once, and sends nothing more to the API until the camera's username or
  password changes in Camera Bridge, or the camera restarts in the bridge 30 minutes or more after the refusal
  (`IPCamWebLatch.cameraStarted`): a restart of the camera in the bridge (a setup run, a settings change) never resends a password the
  camera refused, while a restart of Camera Bridge itself (a reboot, an update) tries once more, since nothing is saved. The latch
  keeps the credentials only as the SHA-256 of `username:password`, in memory. ONVIF's logins are not paused: the family's ONVIF and RTSP
  may ask no password at all (Patio New's don't), and pausing them stopped its events and snapshots for 2 minutes at every start. The other
  way round still holds: while ONVIF's logins are paused or locked (the same account), the web sign-in is not tried. A sign-in answer
  that is not the camera's XML (no `<root>`, such as a web page from a server in front of it), or whose code is not a number, is
  unreadable (`invalidResponse`), not a refused password: it stops the API the same way, without the word "refused". A call's answer that
  is not the camera's XML is `invalidResponse` too.
- Set up for Camera Bridge signs in before its steps read anything, so a refusal makes each of this API's steps say why, and the setup goes
  on with the steps that don't need it (a login refusal would end the setup). A sign-in the camera does not answer (a 5xx, a connection
  error, a timeout) is not a refusal: that step says "the camera’s web page did not answer Camera Bridge’s sign-in (HTTP 503)" without
  signing in a second time, and the next step tries again.
- Reads: `GET /cgi/network.cgi?get=<what>&auth=<authid>&guid=<ms>`. Writes: `…?set=<what>&auth=<authid>&data=<xml>&guid=<ms>`, read back
  after. Answers are `<root>…</root>`; an error is `<root><code>N</code><error>text</error></root>`.
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
| `get=eth` | not yet seen from Camera Bridge (the sign-in was refused); the page reads `eth` `ondhcp`, `ip`, `submask`, `gateway`, `ip6`, `submask6`, `gateway6`, `dhcp_mode`, `dhcp_fixed_time`, `hostname` and its `dns` `ondhcp`, `dns1`, `dns2` | Watch: the `dns` values, kept in the backup |

### Writes (as the camera's page writes them)

| Write | `data` |
|---|---|
| `set=mobile` | `<?xml version='1.0'?><root><mobile on='0'></mobile></root>` (`on='1'` to restore) |
| `set=rtsp`, `set=onvif` | `<?xml version='1.0'?><root>` + the element as read with only `authorized` changed + `</root>` |
| `set=hik`, `set=meari` | the element as read with only `on` changed (the page writes `<meari on='0' authorized='0' port='10000' />`) |
| `set=eth` | `<?xml version='1.0'?><root><eth ondhcp='…' ip='…' submask='…' gateway='…' ip6='…' submask6='…' gateway6='…' dhcp_mode='…' dhcp_fixed_time='…' hostname='…' ><dns ondhcp='0' dns1='BRIDGE' dns2='BRIDGE' /></eth></root>`, every `eth` value as read (Restore writes the old `dns` the same way) |

### DNS (Watch its internet)

The camera's page has two DNS slots, "Preferred" (`dns1`) and "Alternative" (`dns2`), and its own switch for them (`dns` `ondhcp`; the
address can stay on DHCP while the DNS is set by hand). On 2026-10-18 ONVIF's `SetDNS` with the bridge alone filled only the first slot
of "Patio New": its `GetDNS` then showed the bridge and 8.8.8.8, both set by hand. So Watch goes:

1. ONVIF `SetDNS`, the bridge alone; then the bridge twice; then the bridge and an empty entry; each read back with `GetDNS`. ONVIF goes
   first because it touches only the DNS and needs no web sign-in.
2. If ONVIF still shows another server (or refused), and the family's API can be asked: `get=eth`, then `set=eth` with the interface exactly
   as the page writes it (its attributes in the page's order with every value as the camera answered it) and only `dns` changed. The
   write rewrites the whole interface, the camera's address included, so an answer the page would not write back unchanged (another
   attribute or child, one missing, a value that is not an address, a number or a plain host name) is refused instead of written.
3. The camera restarts its network service after the write and forgets the session ("Restarting the service…" on its page), so Camera
   Bridge reads `get=eth` and ONVIF's `GetDNS` again every 2 s for up to 30 s, signing in again once; no answer meanwhile is not a refusal.
   Done when both show the bridge alone.

A refusal says what the camera kept ("the camera asks Camera Bridge first but kept 8.8.8.8 as its other DNS server"), and when the
family's API cannot be asked (a refused sign-in) it says so too. The backup keeps `dns`'s three values as they were before anything was
written; Restore writes them back through `set=eth` whenever the API can be asked (both slots come back exactly), else through ONVIF
(DHCP, or the old servers). The `eth` answer holds the camera's addresses and host name: it is never logged or kept. The first `set=eth` on
a real camera has not been made yet. Tests: `CameraDNSOwnAPITests` (the write byte for byte, the restart, Restore, the refusals) against
`FakeIPCamWebCamera` beside a `MockONVIFCamera`.

## Security levels

The check's readings go into the camera's security level (red "Outside access possible", yellow "Needs work", green "Good", gold "Local
only"; `BridgeEngine/Security/CameraSecurity.swift`). On the owner's camera as it was: the VisionEye cloud on with its link unknown is red;
with the cloud off, the open RTSP and ONVIF keep it yellow; with the video password on, the Meari and Hikvision services keep it green until
they are off too; gold needs the Internet guard as well (Camera Bridge OS).

Tests: `IPCamWebTests` (RC4 and MD5 vectors computed outside Camera Bridge, the uppercase hash, the query as the page's browser sends it
and the exact URLs, the page check, the sign-in, its answer codes (a missing one is 0, as the page reads it) and its session, the latch
and when it gives the sign-in a new try, ONVIF left alone after a refusal, no secrets in the log), `IPCamWebSetupTests` and
`RemoteAccessTests` against `FakeIPCamWebCamera`.

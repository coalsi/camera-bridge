# Reolink cameras and doorbells: Set up for Camera Bridge and the security check

Camera Bridge reaches a Reolink camera or doorbell through Reolink's own HTTP API (`/api.cgi`, a token login): its streams, events and
snapshots, the security check, and every step of "Set up for Camera Bridge". The camera's ONVIF serves the doorbell's ring events
(`Visitor`) and reads: the video profiles the streams step reads (as for every camera), and the DNS servers DHCP hands out to a camera on
automatic DNS (below). Two steps can still write through it, and only for a change Reolink's API cannot make at all (below): Streams and
Clean picture. Code: `Packages/CameraBridgeKit/Sources/CameraAdapters/Reolink/` and the Reolink parts of
`Packages/CameraBridgeKit/Sources/CameraAdapters/ONVIF/CameraSettingsService+*.swift`.

Why not ONVIF for the settings: Reolink refuses ONVIF's writes to its ONVIF user. On Oct 18, 2026 the owner's Reolink Video Doorbell WiFi
answered "Time from the bridge" (ONVIF `SetNTP`) with `NotAuthorized` while it answered the reads with the same account. Camera Bridge took
that for a wrong password and paused every ONVIF login to the doorbell for 2 minutes, so the setup stopped there, "Watch its internet"
never ran, and the security check right after it could not read the DNS servers the owner had set by hand. Since then (owner decision,
Oct 18) every Reolink step goes through Reolink's API, and a change the camera does not let the account make is said as such (below).

**What can still go through ONVIF.** The time zone, UPnP off and Cloud off never write through ONVIF; Time from the bridge only on a
Reolink without `GetNtp`, and Watch its internet only on one without `GetLocalLink` (each "not support"), Restore included. Streams and
Clean picture try Reolink's API first, always (also when ONVIF changed the streams last time), and go on to ONVIF
(`SetVideoEncoderConfiguration`; `DeleteOSD`, `SetOSD`) only when Reolink's API cannot make the change at all: a codec change (the codec
follows the picture size, below), `GetEnc` or `GetOsd` answered "not support", `SetOsd` answered "not support" or "ability error", a
stream, picture size or value `GetEnc` does not show. After any other answer of Reolink's API (the account may not make the change,
another refusal, a change that did not stick, no answer) nothing is sent to ONVIF: its ONVIF user would be refused too, and an ONVIF
`NotAuthorized` as a first call is a refused login that pauses the camera's logins. Restore puts the streams back the same way, and the
labels back the way they were turned off (`CreateOSD` / `SetOSD` when that was ONVIF). One switch outside Set up for Camera Bridge still
falls back to ONVIF after any refusal of Reolink's API: hiding the camera's own clock (the timestamp overlay's "camera clock" switch,
`POST cameras/:id/camera-clock`, `hideCameraClock`).

Everything here is checked against Reolink's *Camera HTTP API User Guide* v8 (2023-4) and the behaviour of reolink_aio (the library behind
Home Assistant's Reolink integration; read, no code copied), and tested against a fake camera (`MockReolinkCamera`). None of the writes
has been made on a real camera yet.

## The steps

| Step | Read | Write (then read back) | Restore |
|---|---|---|---|
| Time zone | `GetTime`: `Time.timeZone` and `Dst` (the switch and its rule) | `SetTime` with `Dst` as read and only what changes (`enable`, the rule), and `Time` with only `timeZone`, each sent only when it changes | `SetTime` with the `timeZone` and every `Dst` number the backup kept |
| Time from the bridge | `GetNtp`: `Ntp.enable`, `server`, `port`, `interval` | `SetNtp` with `Ntp` as read and `enable` 1, `server` the bridge, `port` 123 (`interval` as the camera had it) | `SetNtp` with the saved `enable`, `server`, `port`, `interval` (a backup saved through ONVIF: below) |
| Clean picture | `GetOsd` | `SetOsd` with the whole `Osd` as read and only the labels' switches off | the saved `Osd` |
| Streams | `GetEnc` with `action` 1 (the value and the range) | `SetEnc` (below) | the saved encoder settings |
| UPnP off | `GetUpnp`: `Upnp.enable` | `SetUpnp {"Upnp":{"enable":0}}` | `enable` 1 |
| Cloud off (the UID) | `GetP2p`: `P2p.enable` only | `SetP2p {"P2p":{"enable":0}}` | `enable` 1 |
| Watch its internet (Camera Bridge OS) | `GetLocalLink`: `dns.auto`, `dns1`, `dns2` (with `auto` 1, the servers in use from ONVIF: below) | `SetLocalLink` (below) | the saved `dns` values (a backup saved through ONVIF: below) |

Every body is the guide's shape: `[{"cmd":"SetUpnp","action":0,"param":{"Upnp":{"enable":0}}}]`. A setting succeeded when the answer's
`code` is 0 and its `value.rspCode` is 200; any other `rspCode` is a refusal, said with the camera's `detail` ("the camera refused the change
(Reolink error -4: set config failed)").

**Cloud off.** Turning the UID off stops the Reolink app from working away from home. Apple Home keeps working, and a doorbell's rings
still come through Apple Home; the step's preview says so (owner decision, Oct 18). `GetP2p` also answers the camera's `uid`, its
identity at Reolink's cloud: Camera Bridge never reads, logs, keeps or sends it back. `GetDdns` answers the DDNS account's name and
password: only its switch is read.

**Watch its internet.** `SetLocalLink` takes the whole `LocalLink` as read, with only `dns` changed: `auto` 0 and the bridge in `dns1` and
`dns2`. The camera's address stays as it is (`type` DHCP, or Static with its `static` block as read). Camera Bridge refuses rather than
writes when that could change the address: a `type` other than DHCP or Static, none, or a fixed address that is not the one Camera Bridge
reaches the camera at. The camera restarts its network service after the write, and a Wi-Fi doorbell drops off the network for a few
seconds: Camera Bridge reads it back every 2 s for up to 30 s, and what fails meanwhile (no answer, HTTP 503, a session the camera forgot)
is no refusal. The security check reads the DNS servers through `GetLocalLink` too, which is what the Reolink app and Client set: DNS the
owner points at the bridge on the camera counts as watched, and so does DNS the router's DHCP hands out (`auto` 1) when it is the bridge
alone (the step then says the router can change it when it renews the camera's address). With `auto` 1, `dns1` and `dns2` are not taken as
the servers in use: the guide's own `GetLocalLink` example has `auto` 1 with 114.114.114.114 in `dns2`, so the slots may keep the servers
set by hand (an owner who typed the bridge into both and then turned automatic DNS back on is not asking the bridge). The servers in use
are then ONVIF `GetDNS`'s `DNSFromDHCP` (a read, which the doorbell's ONVIF user answers), at the camera's ONVIF port as its events find
it: the saved one, else the `onvifPort` `GetNetPort` reports, else 8000 (no port is searched for; nothing is asked when `GetNetPort` says
ONVIF is off). When ONVIF does not say (off, no answer, a refused or paused login, no `GetDNS`, an answer that is not from DHCP), the
servers are unknown, not none: such a reading never counts as pointing at the bridge, the step still offers the change, and the Internet
guard takes it as a read that gave nothing, which changes nothing (owner decision, Oct 18: a doorbell watched through its router's DHCP
stays on the list when its Wi-Fi ONVIF times out). A Reolink that has no `LocalLink` goes through ONVIF (`GetDNS` / `SetDNS`), as other
cameras do; `LocalLink` takes an IPv4 address only.

**Backups saved through ONVIF.** Builds before Oct 18 read a Reolink's time source and DNS through ONVIF, and the setup keeps the oldest
backup of each step: the owner's doorbell holds a time source `onvifMinimal`, NTP, pool.ntp.org and DNS `onvifMinimal` from DHCP with no
servers. A run now changes them through Reolink's API, so Restore puts them back that way too, read back, and never through ONVIF's
`SetNTP` / `SetDNS`, which the doorbell refuses: `SetNtp` with `Ntp` as read, `enable` 1 for NTP (0 for a clock set by hand), `server` the
backup's first server, `port` and `interval` as the backup has them, else as read. Such a backup that names no server (the camera took it
from DHCP, as ONVIF showed it) gets the camera's own `server`, `port` and `interval` as `GetNtp` reads them when a run changes the time
source (they are not the bridge's then), and Restore puts those back; one of NTP that still names none is refused with why ("set its time
server in the Reolink app or Client"), nothing written, rather than leave the bridge as the camera's time server and call it restored (a
clock set by hand gets NTP off, the server left as it is). `SetLocalLink` with `LocalLink` as read and `dns.auto` 1 for DHCP, its slots as
they are (read back by `auto` alone: the camera asks DHCP's servers then), or `auto` 0 with the backup's servers in `dns1` and `dns2`.
ONVIF only for a Reolink without `GetNtp` or `LocalLink`.

**Time zone.** `timeZone` is an offset in seconds. The guide's range (-46800 to 43200, from UTC+13 to UTC−12) counts it west of UTC, as a
POSIX TZ string does, and so does reolink_aio's zone with daylight saving (its zone without daylight saving reads the other way). The
camera's own clock settles it: `GetTime`'s `Time` is the camera's local time, so a camera whose clock is UTC plus `timeZone` (within 15
minutes, daylight saving allowed for) counts east, and is read and written its way. A clock that fits neither way keeps the guide's sign.
The bridge's POSIX rule maps onto `Dst` one to one: "M3.2.0/2" is `startMon` 3, `startWeek` 2 (5 is the last week), `startWeekday` 0
(Sunday), `startHour` 2; `offset` is the shift in hours, 1 or 2. A zone whose shift is another (Lord Howe's half hour), or whose rule is not
"Mm.w.d", is not offered ("Camera Bridge can't give this camera the daylight-saving rule of …"). The camera's clock itself is never written.
A time-zone backup from a build before Oct 18 kept only the daylight-saving switch, which is all that build changed; a run that changes the
time zone completes it with the camera's `timeZone` and `Dst` rule as read (still its own) and the old switch as `Dst.enable`, so Restore
puts back the offset and the rule as they were.

**Streams.** `SetEnc` takes the camera's `Enc` as read, with only this stream's values changed and each inside the range `GetEnc` gave with
`action` 1: the nearest `frameRate` and `bitRate` the camera offers, `gop` (whole seconds of frames, of the frame rate asked for) within
its bounds, a profile it offers. The frame rate is `frameRate` (builds through 0.1.110 wrote `frame`, which is no field of Reolink's, and
read the frame rate as unknown). `width`, `height` and `resolution` ("internal use only, not needed for SetEnc") are not sent. The codec
follows the picture size (the range ties each size to one `vType`, and `vType` is not a `SetEnc` field; reolink_aio changes it through
Reolink's other protocol): H.264 at a size the camera offers only as H.265 is not possible through the API, and the step says so; nor is a
size change alone to a size the range ties to another codec than the one the camera sends (it would switch the codec unnoticed). Those
changes, which Reolink's API cannot make, go on to ONVIF (above), which a Reolink may refuse.

## Rights: a change the account may not make

Reolink accounts are administrators or guests (Settings › Advanced › User Management in the Reolink app). `GetAbility` with the account's
name says, for each module, whether the camera has it (`ver` 0: no) and what the account may do with it (`permit`: 1 option, 2 write,
4 read; 6 is read and write). Camera Bridge reads it once per run. A change the account may not make is not sent: the step says "the
account Camera Bridge uses may not change this; use an administrator account in the camera's settings". A setting the camera refuses with
a credential code (-7, -27) after the session's login worked is the same answer (`CameraAdapterError.notPermitted`), and neither is
tried again through ONVIF. Neither is a wrong password: no login is paused, and the setup goes on with every step after it, "Watch its
internet" too (owner decision, Oct 18). A login
the camera refuses at UPnP off or Cloud off is Reolink's login, so "Watch its internet", which goes through `LocalLink` with the same
login, is held then (another refused login could lock the account). The modules: `ntp`, `time`, `localLink`, `upnp`, `p2p` (device-wide),
`enc`, `osd` (the channel's).

## The session and the camera's answers

One API session (one login, one token) serves a whole setup run or a security check; it is logged out at the end of the run. The camera's
answers, as the v8 error table (§4.1) and reolink_aio read them:

| Answer | What Camera Bridge does |
|---|---|
| -6 "please login first", -21 "error token" | logs in again once and asks again |
| -7 "login failed", -27 "invalid user", -501 "the user does not exist", -502 "password err", or a detail saying "password wrong" | wrong credentials: the usual wait after a refused login |
| -503 "login deny", -506 "login locked", or a detail saying "locked" | the camera locked its logins: no login for 30 minutes |
| -5 "max session", -105 "frequent logins", -500 (too many addresses), -507 (too many logins) | no login for 5 minutes |
| -12 "get config failed", -13 "set config failed", -17 "rcv failed" | the camera did not get it (a Wi-Fi or battery camera waking up): asked once more after 1 s |
| -9 "not support", -26 "ability error" | the camera does not have it |

## Changing it by hand

What a step can't change, the person can change on the camera:

- **UPnP and the UID** (Reolink support articles 900000627963 and 4404480742425): in the Reolink Client on a computer, Device Settings ›
  Network › Advanced (older Clients say Camera Settings). The phone app has neither setting. Or block the camera's internet in the router
  (Keep this camera local).
- **DNS**: Reolink's API calls the fields "auto get DNS", "Preferred DNS Server" and "Alternate DNS server". Where they sit on the Reolink
  app's and Client's network screens is not confirmed from Reolink's documents (the address settings are in the app at Settings › the
  camera › Network Information, and in the Client at Device Settings › Network › Network Information). Menu names differ between models.
- **Time from the bridge**: the Reolink Client's NTP page is not confirmed (Reolink's article on it is gone). Menu names differ between
  models.

## What needs a real camera

The first real run on the owner's doorbell should be watched: whether its account is an administrator (`GetAbility`'s permits), the sign
of its `timeZone`, its encoder range (the -13 it answered `SetEnc` on Oct 16 fits a value outside it, a guest account, or a camera that did
not get the command), whether it has UPnP and UID switches at all, and how long `SetLocalLink` keeps it off the network. What `dns1` and
`dns2` show while `auto` is 1 is not confirmed either: Camera Bridge does not rely on them (above).

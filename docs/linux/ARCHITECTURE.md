# Camera Bridge OS: architecture

Camera Bridge OS is a small Linux system on a USB stick (or the SSD of a mini PC) that runs the same engine as Camera Bridge for Mac. You plug in ONVIF or RTSP cameras, open a web page, and Apple Home records them with HomeKit Secure Video. No Mac and no NVR are needed.

One repository, two products, one engine:

| Product | What it is | Release tag | Artifact |
|---|---|---|---|
| Camera Bridge for Mac (archived October 2026; source in `Archive/mac-app`) | SwiftUI app, Developer ID signed, Sparkle updates | `v1.0`, `v1.1`, … | `CameraBridge-1.0.dmg` |
| Camera Bridge OS | Debian 13 image with the engine, a web UI and A/B updates | `os-v0.1`, `os-v0.2`, … | `camera-bridge-os-0.1-amd64.img.xz` (+ `.sha256`, `.sig`) |

## The engine is shared

`Packages/CameraBridgeKit` holds the engine. Every module except `PlatformApple` is portable Swift (the rule in `Tests/PortabilityTests`). A platform supplies these services (`BridgeSupport/PlatformServices.swift`, `MediaCore/Codecs.swift`):

| Service | macOS (`PlatformApple`) | Linux (`PlatformLinux`) |
|---|---|---|
| `NetworkTransport` (TCP, UDP) | Network.framework | POSIX sockets + Dispatch |
| `ServiceAdvertiser`, `ServiceBrowsing` (mDNS) | `dns_sd` | `dns_sd` API from `libavahi-compat-libdnssd` (same calls) |
| `SecretStore` | Keychain | encrypted file store (AES-GCM, key file `secrets/master.key` `0600`, the one the image creates at first boot; optional TPM seal) |
| `NetworkChangeMonitoring` | `NWPathMonitor` | netlink (`RTMGRP_LINK`, `RTMGRP_IPV4_IFADDR`, `RTMGRP_IPV6_IFADDR`) |
| `PowerManaging` | IOPM assertions | no-op (the box never sleeps) |
| `InstanceLocking` | flock | flock |
| `MediaCodecs` (decode, encode, scale, overlay, audio transcode, JPEG) | VideoToolbox, AudioToolbox, ImageIO | `ffmpeg` child processes, VA-API hardware encode when present |
| Helper process (go2rtc) | `ProcessHelperLauncher` | `Foundation.Process` |

HomeKit Secure Video needs H.264 video passed through untouched wherever possible. Transcoding is only needed for audio (AAC-ELD / Opus for live view, AAC-LC for recording), for cameras that send H.265, and for the timestamp overlay.

## Processes on the box

```
camerabridged        Swift daemon: BridgeEngine + web API (one process, user camerabridge)
  ├─ go2rtc          helper for Wyze / Ring / Nest / Tuya (started on demand): /usr/lib/camera-bridge/helpers/go2rtc
  ├─ wyze-lake       helper for Wyze's cloud-only cameras (on demand): /usr/lib/camera-bridge/helpers/wyze-lake
  ├─ eufy-bridge     helper for the Eufy account (while the eufy plugin is on): helpers/eufy-bridge -> helpers/eufy/node
  └─ ffmpeg          codecs (started per stream)
avahi-daemon         mDNS (HomeKit advertising, and `_camera-bridge._tcp` for the Apple TV and iPhone apps)
camerabridge-web     not a process: camerabridged serves the web UI itself on :80, plain HTTP; nginx on :443 is the TLS front for the secure address (`<name>.box.camera-bridge.app`) and passes everything to it
```

go2rtc (MIT) is part of the image: built from a pinned commit of its master (`1.9.14+dev.c245815`, for the fixes to its native Wyze source after v1.9.14) by `linux/os/fetch-go2rtc.sh`, checked against a pinned SHA-256, installed `0755 root:root` at `/usr/lib/camera-bridge/helpers/go2rtc` (the folder `ProcessHelperLauncher` searches after `CAMERABRIDGE_HELPERS_DIR` and the daemon's own folder), licence at `/usr/share/doc/go2rtc/copyright`. It runs as a child of `camerabridged`, so as user `camerabridge` inside the daemon's sandbox. See BUILDING.md, "The go2rtc helper". Our own helpers `wyze-lake` (Go, MIT) and `eufy-bridge` (Node.js 24 with the eufy SDK, Apache-2.0; amd64 images) are built from `linux/helpers/` by `linux/os/build-helpers.sh` and installed in the same folder the same way; they run as children of the daemon too (BUILDING.md, "Our own helpers").

State lives in `/var/lib/camera-bridge` (a separate data partition, so updates never touch it): `config.json`, `hap/`, `secrets/` (the encrypted items and `master.key`), `ai/usage.json` (how many AI descriptions were asked for on each of the last 8 days), `Diagnostics/`, and `recordings/` (the NVR's files, once Record is on). This is the same layout the Mac app uses in `~/Library/Application Support/CameraBridge`.

## Web API (served by `camerabridged`)

JSON over HTTP on port 80 (`http://camera-bridge.local`). Types follow the Mac app's models (`CameraConfiguration`, `CameraStatus`, `DiscoveredCamera`, `NetworkNotice`) and its words (`StatusText`, the Add Camera wizard's pages and messages), so the two UIs say the same things. Errors are `{"error": "<code>", "code": "<the same code>", "message": "<a sentence for the person>", "field": "<input, when one is to blame>"}` with the usual status codes (400 invalid, 401 unauthorized or viewer_key, 403 csrf / cross_origin / setup_required / password_required / wrong_password, 404 (`gap`: nothing recorded at that time), 409 (`folder_required`, `confirm_required`), 410 gone, 415, 422 the engine refused (`folder_rejected`), 429 too_many_attempts, too_many_streams or busy, 502 unreadable, 503 no_picture or archive_unavailable, 504 drive_slow). Every answer carries `Cache-Control: no-store` and the security headers.

Sessions: the `cb_session` cookie (see Security). Everything needs a session except the rows marked "open". Requests that change something also carry `X-CSRF-Token` (from `/session`, `/auth/login` or `/auth/setup`) and `Content-Type: application/json`.

The rows marked "viewer" also take an Apple TV's or iPhone's key (from pairing, `/viewers/pair/status`) instead of a session: `Authorization: Bearer <key>`, with no cookie and no `X-CSRF-Token` (a body is still `Content-Type: application/json`, and a request that changes something still must not come from another site). A key that is there decides alone: a wrong, expired or removed one is 401 viewer_key ("This device was removed from Camera Bridge. Pair it again.") with `WWW-Authenticate: Bearer`, even next to a valid session cookie, and no cookie is cleared. Without the header a viewer row applies exactly the session rules. `token=` or `access_token=` in a viewer row's query is 400 invalid (field `token`: "Send the key in the Authorization header (Bearer), never in the address."), even with a good header. On every other row the key is never looked at: a row that needs a session answers it 401 unauthorized, and an open row answers it as it would anyone.

```
GET    /api/v1/status                 open: {product, version, name, setupRequired, authenticated}; signed in: + state, uptime, camera counts, notices, system summary
GET    /api/v1/health                 open: 200 while the bridge runs (or is paused on purpose), 503 otherwise (the A/B update's health check)
GET    /api/v1/session                open: {authenticated, setupRequired, setupTokenRequired, bridgeName, csrfToken?}
POST   /api/v1/auth/setup             open, once: {password, bridgeName?, setupToken?} -> session
POST   /api/v1/auth/login             open: {password} -> {csrfToken, bridgeName} + cookie        (429 after 5 wrong tries per address)
POST   /api/v1/auth/logout
POST   /api/v1/auth/password          {current, new}; signs every other browser out
GET    /api/v1/auth/sessions          {sessions: [{id, browser, address, created, lastSeen, current}]}: the signed-in browsers, the one used last first; browser is
                                      "Safari on iPhone" and the like (from the User-Agent at sign-in, "A browser" for one from before), address where it signed in
                                      from (null for those); id is derived from the session and signs nobody in
DELETE /api/v1/auth/sessions/:id      signs that browser out -> 204 (404 when it is not signed in); the browser that asks also gets its cookie cleared
GET    /api/v1/monitor                open, but only with `Authorization: Bearer <monitorToken>` (never in the URL: a `token=` query is 400): read-only health for
                                      Home Assistant or Uptime Kuma -> {time, version, state, cameras: [{id, name, enabled, online, connection, recording,
                                      recordingState, lastSegment}], recordings: {state, freeBytes, totalBytes, floorBytes}|null, archive: {state, freeBytes,
                                      totalBytes, floorBytes}|null, update: {state, available, current, latest}|null, signIn: {failedLastHour, failedLastDay,
                                      lockedAddresses, everyoneWaits}}; 403 monitor_off while monitoring is off, 401 monitor_token without the right token
POST   /api/v1/viewers/pair           open: {name?, device?} -> {request, secret, code, expiresIn, interval}: an Apple TV, iPhone or iPad asks to be added and shows the code
                                      ("BCDF-GHJK": 8 letters without vowels); the request lasts 10 minutes (expiresIn, seconds) and the TV asks again every
                                      interval seconds; 429 too_many_pairings with Retry-After (3 open per address, an IPv6 network counting once; 20 in all)
POST   /api/v1/viewers/pair/status    open: {request, secret} -> {state: "waiting"}, or once {state: "approved", token, viewer: {id, name}}: the TV's key (64 hex),
                                      after which the request is over; 404 pairing_gone when it ended, is unknown, the secret is wrong, the key was collected
                                      already or the TV was removed meanwhile
POST   /api/v1/viewers/approve        {code}, typed in any case with or without the dash -> 201 {viewer}: the TV is added and collects its key with its next question;
                                      404 no_such_code, 409 too_many_viewers (20 at most), 500 storage (nothing is added, and the code waits)
GET    /api/v1/viewers                {viewers: [viewer]}: the Apple TVs, iPhones and iPads (the name defaults to "Device"), the one used last first; viewer is {id, name, device, created, lastSeen, address}, every key
                                      always there (null when not known); id signs nobody in, and the key and its hash are never shown
DELETE /api/v1/viewers/:id            removes that device -> 204 (404 not_found when it is not added); a key it has not collected yet is dropped with it
GET    /api/v1/viewer                 viewer: what an Apple TV or iPhone draws its screens from: {bridge: {id, name, version, secureURL}, cameras: [camera]}, every key always
                                      there; id is the box's identity (32 hex, kept until a factory reset), version what About shows, secureURL the secure address
                                      while its certificate is ready (else null); cameras come in the owner's order, each {id, name, kind (camera|doorbell),
                                      enabled, connection (online|connecting|idle|disabled|offline), motion, recordingNow (the box's own recorder is writing it now,
                                      not Apple Home's recording), panTilt and zoom (as its status has them: what its control says, less what the owner turned off),
                                      sound (its "Camera audio" switch), main and sub ({width, height, codec: h264|hevc}, or null before that stream has shown a
                                      picture), lastEvent ({kind as GET nvr/events names it, date ISO 8601 UTC}, or null)}; a camera with no status yet is idle
                                      (disabled when turned off), with false and null elsewhere; no address, user name, stream URL, setting, token or setup code
GET    /api/v1/camera-types           the Mac app's Camera Type page: groups, types, setup steps, what you get, which inputs
GET    /api/v1/cameras                {cameras: [camera]}; a camera is its CameraConfiguration JSON plus `status` (live state), vendorName, kindName, address,
                                      motionSourceName, internetWatched (the Internet guard watches it: the engine's verdict) and restartOffered (the
                                      camera waits for a restart to apply a change it took: "Restart the camera now"), both always there; `skyDetector`
                                      is the Sky Watcher's settings of the camera, or null when they were never saved; `status.sky` is its Sky Watcher
                                      while it is on (absent while the plugin or the camera's switch is off): {running, stream (main|sub), analysisWidth,
                                      picturesPerSecond, decoding (gpu|software), aim, learning, problem (a sentence, or null), profile}; `status.panTiltDetected`
                                      and `status.zoomDetected` say what the camera's control says it can do (asked when the camera starts; false until it answers
                                      and while the camera does not run), `status.panTilt` and `status.zoom` that less what the owner turned off (`panTiltEnabled`,
                                      `zoomEnabled` false): what the page's pad and an Apple TV offer
POST   /api/v1/cameras                add: {type, host, httpPort, rtspPort, onvifPort, useHTTPS, username, password, mainStreamURL, subStreamURL, source,
                                      apiKey, unifiCameraID, nestSession, nestDeviceID, name, kind, motionSource, motionSensitivity, motionHoldSeconds,
                                      sensors, audioEnabled, twoWayAudio}; checks the camera again, then adds it (201)
GET    /api/v1/cameras/{id}
PATCH  /api/v1/cameras/{id}           name, isEnabled, username, password, endpoint{host,ports,useHTTPS}, mainStreamURL, subStreamURL, motionSource,
                                      motionSensitivity, motionHoldSeconds, sensors{}, audioEnabled, twoWayAudio, liveStreamMode, liveQualityMode,
                                      liveMaxBitrateOverride, recordingStreamMode, recordingQualityMode, timestampOverlay{},
                                      pictureCorrection{straighten, level} (the whole value; clamped, never refused; never restarts the camera), aiDescriptions
                                      (AI descriptions of this camera's events on or off; applied in place, the camera is not restarted), skyDetector{enabled,
                                      facing (0 up to 360° from north), tilt (0 to 90), groundPercent (0 to 60), nightProfile, lensLayout ("single", "dual" or
                                      null: automatic)} (the Sky Watcher; what is left out stays; applied in place; 400 with the field skyDetector.facing,
                                      .tilt, .groundPercent or .lensLayout; saying enabled: true needs the Sky Watcher plugin switched on, a camera that can
                                      watch the sky, a place for the box and a recordings folder: 400 "Turn on Sky Watcher in Plugins first." (field
                                      plugins.sky; PATCH /plugins/sky {enabled} is the switch, off on a new box), "Battery cameras can’t watch the sky: it would
                                      keep them awake." (field skyDetector.enabled), "Set where the box is first." (field sky.location) or "Choose a recordings
                                      folder first: the sky log is kept with the recordings." (field nvrFolder), in that order; saying "off" or changing the aim
                                      needs none of them, and a camera keeps its settings while the plugin is off), panTiltEnabled and zoomEnabled (the owner's
                                      switches for a camera whose control says it pans and tilts, or zooms, when it can't: false turns that off, true gives it back
                                      to the control; true or false only (400 with the field), null or left out changes nothing; absent from the camera until set;
                                      applied in place, the camera is not restarted)
PATCH  /api/v1/cameras/{id}/nvr       {enabled?, recordSound?}: Record on or off, Record sound on or off, in place (the camera is not restarted);
                                      409 folder_required until a place for recordings was chosen
DELETE /api/v1/cameras/{id}
GET    /api/v1/cameras/{id}/snapshot  viewer: JPEG, straightened by the camera's pictureCorrection; ?original=1: the camera's own picture (the camera
                                      page straightens that itself while its sliders move) (503 + Retry-After while there is none)
GET    /api/v1/cameras/{id}/live      multipart/x-mixed-replace JPEGs (the fallback where a browser cannot play live video), at most 15 minutes;
                                      straightened like snapshot, ?original=1: the camera's own pictures
POST   /api/v1/cameras/{id}/clean-picture {clean}       every label the camera draws itself off (clock, name, text, logo), or back as saved
POST   /api/v1/cameras/{id}/camera-clock {shown}        the camera's own on-screen date and time on or off (vendor API, then ONVIF OSD)
POST   /api/v1/cameras/{id}/camera-time-zone            the camera's clock set to the bridge's time zone (ONVIF SetSystemDateAndTime): {timeZone: POSIX string}
POST   /api/v1/hls/tickets        viewer: {camera, kind: "live", stream?: "sub"|"main"|"automatic", audio?} or {camera, kind: "recorded", from, to} (ms, at most 2 hours) ->
                                      {url: "/api/v1/hls/<ticket>/index.m3u8", expiresIn: 300}: a ticket that opens one camera, read-only, for AirPlay and CarPlay (AVPlayer
                                      needs an address). 404 for an unknown camera; live: 429 too_many_streams with no live slot free; recorded: 404 gap when
                                      nothing is recorded in the range, 400 range_too_long, 429 busy. A camera whose Camera audio switch is off is sent without sound
GET    /api/v1/hls/:ticket/:file      open (the ticket in the path is the access; see Security): index.m3u8 (master), media.m3u8, init-<n>.mp4, seg-<n>.m4s. Live is
                                      a sliding playlist of segments one key interval long: with a key frame every 2 s it starts in about 7 s and runs 7 to 17 s behind live, and both grow with the camera's key interval (14 to 16 s to start at 4 s, about 32 s at 10 s); recorded is a VOD playlist. A bad ticket or file is an empty 404;
                                      a first live playlist waits up to 18 s for three segments, then 503 with Retry-After (the master answers 200 at 18 s from one segment if at least one is out). `Cache-Control: no-store`. Home network only for now
GET    /api/v1/live?cameras=<id>,…&stream=sub|main|automatic[&width=]   viewer: live video of 1 to 32 cameras in one answer: the cameras' own H.264/HEVC as fragmented MP4, framed per camera (type, camera, length; see BridgeWeb/WebApp+LiveVideo.swift); at most 16 live answers at a time; an Apple TV's answer ends within 5 s of the TV being removed
POST   /api/v1/cameras/{id}/pan-tilt  viewer: {pan, tilt, zoom?} (-1 to 1 each; both 0 stops): moves a camera that pans and tilts for 1.5 s (the page
                                      and the TV repeat it while a button is held); zoom is one step in or out, pan and tilt then ignored -> 204; 400 (field
                                      pan) outside -1 to 1, 404 not_found when there is no such camera, 409 no_pan_tilt when the camera can't pan and tilt
                                      (or zoom) now or the owner turned it off (panTiltEnabled, zoomEnabled false; nothing reaches the camera; for a zoom step the
                                      sentence says zoom), 422 pan_tilt_failed
GET    /api/v1/cameras/{id}/pairing   {accessoryName, paired, setupCode, setupURI, qrSVG, blocker?, blockerMessage?, blockerAction?}
POST   /api/v1/cameras/{id}/reset-pairing
POST   /api/v1/cameras/{id}/optimize        {confirm: true}: the HomeKit optimizer for this camera (one at a time, 20 to 40 s; it can lower the bit rate,
                                      change H.265 to H.264 and restarts the camera) -> {applied, failed, canUndo, mayNeedRecordingReEnabled, scoreBefore, scoreAfter}
POST   /api/v1/cameras/{id}/optimize/undo   -> 204
GET    /api/v1/cameras/{id}/setup     "Set up for Camera Bridge", read only: {steps: [{id, title, status, changes: [{label, now, after}], detail?, needsRestart,
                                      fixAddress?: {addressing: {address, subnetMask, gateway, hardwareAddress?, interface?}, changes, method}}], state?, canRestore,
                                      streamRestarted, mayNeedRecordingReEnabled}; status willChange, alreadyRight, notSupported or notOffered; fixAddress: Watch
                                      offers "Fix its address so the DNS stays" (off unless chosen)
POST   /api/v1/cameras/{id}/setup     {confirm: true, fixAddress?: true, keeps?: {address, subnetMask, gateway}}: applies it (time zone, time from the bridge,
                                      clean picture, streams, video password, extra services off, UPnP off, cloud off, Watch; each read back; one backup in the
                                      camera's setupBackup) -> the same shape, steps done, refused or notRun, stoppedAt?, a Watch step's fixedAddress? (for the
                                      router reservation); fixAddress needs keeps (the preview's address: nothing is written when the camera has another), else
                                      400; 409 camera_setup_busy
POST   /api/v1/cameras/{id}/setup/restore   {confirm: true}: writes every saved value back -> steps restored or refused; canRestore false once all are back
POST   /api/v1/cameras/{id}/security/check  checks the camera now (read only) -> {level: red|yellow|green|gold, title, summary, checkedAt,
                                      findings: [{feature, state, level, sentence, canChange, linked, service}]}, as status.security has it (absent until
                                      the first check; checked at start, daily and after the setup); 429 security_check_too_soon (Retry-After) within a
                                      minute of the camera's last check, 409 camera_offline, 422 security_check_unavailable
POST   /api/v1/cameras/{id}/restart      "Restart the camera now" (the page confirms first): restarts the camera, only while it waits for a restart
                                      to apply a change it took (the camera's restartOffered) -> 204; 409 camera_restart_not_needed otherwise,
                                      409 camera_setup_busy, 422 camera_restart_failed
POST   /api/v1/cameras/{id}/test-motion
POST   /api/v1/discover               ONVIF WS-Discovery -> {cameras: [{host, name, hardware, onvifPort, alreadyAdded}]}
POST   /api/v1/probe                  the same body as POST /cameras (no choices needed) -> {ok: true, vendor, model, streams, capabilities, suggestions,
                                      motionSources, sensorsByMotionSource, alreadyAdded?} or {ok: false, error}
POST   /api/v1/integrations/unifi/cameras   {host, apiKey, ...} -> the console's cameras
POST   /api/v1/integrations/nest/authorize  {projectID, clientID} -> {url};  .../nest/connect {projectID, clientID, clientSecret, code} -> {session, cameras}
GET    /api/v1/sensors-bridge         same shape as pairing; POST /api/v1/sensors-bridge/reset-pairing
GET    /api/v1/nvr/storage            where recordings go and the numbers: state, keepDays, maxSizeGB, used / free / total / floor / room bytes, effective maximum, oldest, newest;
                                      archive: null, or the archive drive {state: connected|notConnected|notAnswering|failing|refused, message, used / free / total / floor bytes,
                                      oldest, newest, moving: {cameraID, cameraName, start, bytes, doneBytes} | null, waitingFiles, waitingBytes, movedFiles, movedBytes}
GET    /api/v1/nvr/storage/locations  the places this bridge offers (one on the box) with free space and any problem; the browser sends the id, never a path
PATCH  /api/v1/nvr/storage            {location?, keepDays?, maxSizeGB?, confirm?}: choose the place and the limits; 409 confirm_required when it would delete recordings
GET    /api/v1/nvr/cameras            viewer: {serverTime, catalogVersion, cameras: [{id, oldest, newest, typicalGOP}]}: what is recorded
GET    /api/v1/nvr/activity?cameras=&from=&binMs=&bins=      viewer: the timeline's activity per camera (coverage, bytes per second, typical, and away: the percent of each bin on an archive drive that is not connected)
GET    /api/v1/nvr/events?cameras=&from=&to=&limit=          viewer: {from, to, serverTime, more, events: [{id, cameraID, kind, start, end, recorded, description}]}: the cameras' events that began in from..<to (at most 31 days, 1 to 16 cameras), newest first, at most limit (1 to 1000, default 200); more: older ones were left out (ask again with to = the oldest start). A page never splits a millisecond: the events of its oldest start are all in it or all in the next (more than limit at one moment with nothing newer: that moment whole). 503 archive_unavailable (Retry-After) while the recordings load or their folder is missing, never an empty answer. description: what an AI service said it saw at the event's start, {summary, kind (person, vehicle, animal, delivery, other, nothing), concern (routine, unusual, alarm)}, or null when none was written (the model and the time stay in the log)
GET    /api/v1/nvr/kept                                       {kept: [{id, cameraID, cameraName, from, to, note, created, bytes, hasVideo}]}: the stretches kept from retention ("Keep this"), newest first, times in epoch ms
POST   /api/v1/nvr/kept {cameraID, from, to, note?}           201 with the kept stretch; 400 for a range that is not one, longer than 24 hours or with no recording of the camera; 409 when 200 are kept or together they would take more than a quarter of the box's limit for recordings
DELETE /api/v1/nvr/kept/:id                                   204; 404 when it is not there. Retention may take that stretch again
GET    /api/v1/nvr/cameras/{id}/fragments?at=ms[&ahead=n] | ?after=id[&limit=n]    viewer: which pieces to play: ids, times, sizes and the codec string
GET    /api/v1/nvr/cameras/{id}/fragments/{fid}         viewer: one piece, video only, as fragmented MP4 (at most 16 MiB; no Range; HEAD is 405)
GET    /api/v1/nvr/cameras/{id}/fragments/{fid}/init    viewer: the matching initialization segment
GET    /api/v1/nvr/cameras/{id}/keyframe?at=ms[&picture=1]    viewer: the whole key piece of the group of pictures that contains the time; X-CB-Part describes it.
                                                              picture=1: only that piece's first picture, as a piece of one sample (no sound); X-CB-Part is the same but its end is where
                                                              the picture ends. picture=0 or none is the whole piece; any other value is 400 invalid with the field picture.
                                                              The answer-size limit (16 MiB; 502 unreadable above it) applies to the bytes sent: with picture=1, to the picture
GET    /api/v1/settings               {bridgeName, basePort, sensorsBridgePort, webhookEnabled, webhookPort, webhookToken, webhookProblem, logLevel, motionShadowTest,
                                      monitorEnabled, monitorToken|null (GET monitor's token, shown for the owner to copy),
                                      ai: {provider: "anthropic"|"openAICompatible"|null, model, baseURL|null, dailyLimit, keySaved, keyHint|null,
                                      today, last7Days (today and the 6 days before, the bridge's time zone), limitReached, paused (the key was
                                      refused: nothing is described until it or the service changes, or Try it works), lastError|null (the
                                      sentence), lastErrorAt|null, needsRecordingsFolder (none is chosen: no event is kept, so none is described),
                                      retryAt|null (the service could not take 3 events in a row: none is described before then)},
                                      sky: {location: {latitude, longitude, heightMeters}|null, flightFeedURL|null, aiDailyLimit}}; never the key.
                                      The place is shown here, to the signed-in page, and nowhere else
PATCH  /api/v1/settings               the same keys (+ regenerateWebhookToken; monitorEnabled makes or forgets the monitoring token, regenerateMonitorToken makes a new one); `ai: {provider (string or null), model, baseURL (string or null), dailyLimit}`:
                                      what is left out stays; 400 with the field ai.provider, ai.model, ai.baseURL or ai.dailyLimit (an OpenAI-compatible
                                      provider needs an http or https address with no user name, password, query or fragment; dailyLimit 1 to 5000;
                                      model 1 to 100 printable characters); a saved key is deleted in the same update when the provider changes or
                                      the scheme, host or port of an OpenAI-compatible address does (a model, a daily limit or a path keeps it);
                                      `sky: {location ({latitude, longitude, heightMeters?} or null), flightFeedURL (a string or null; "" too), aiDailyLimit}`:
                                      what is left out stays, null takes the place or the feed away, a place is replaced whole (no height: 0 m); 400 with the
                                      field sky.location (a latitude from -90 to 90, a longitude from -180 to 180, not 0 and 0, a height from -500 to 9000),
                                      sky.flightFeedURL (http or https with a host, no name or password, no #, one line of at most 500 characters) or
                                      sky.aiDailyLimit (1 to 1000, 50 by default); the words never repeat what was sent
PUT    /api/v1/ai/key                 {key}: the AI service's key (spaces, tabs and line breaks trimmed; then 1 to 500 characters of visible ASCII, 0x21 to
                                      0x7E) -> 204; 400 with the field key; 422 ai_key_failed. Write-only: it is kept in the secret store and shown
                                      nowhere; `keyHint` is its last four characters (none for a key under eight)
DELETE /api/v1/ai/key                 -> 204
POST   /api/v1/ai/try                 {cameraID}: Try it, the pictures around now of the camera described by the chosen service; nothing is stored, it
                                      counts toward the day -> {summary, kind, concern, seconds}; 502 {error, message} with the sentence ("The key was
                                      refused.", "Today’s limit of 200 descriptions is reached.", …); 409 {error, message} "A try is already
                                      running." (one at a time); 404 for a camera the bridge does not have; 400 with the field cameraID
GET    /api/v1/sky/cameras/{id}/night?date=yyyy-MM-dd&view=night|day     the Sky Watcher's log of one camera: {camera, night, view, from, to, serverTime,
                                      entries[], conditions[], counts, aim, learning, capped[]}. A night (sunset to sunrise) is named by the local date of its
                                      sunset, a day (sunrise to sunset) by its own date, in the bridge's time zone; no date: the latest (the night in
                                      progress or the one that ended this morning; for the day view, today's); no view: the night. Times are epoch
                                      milliseconds. An entry: {id, camera, kind (track | newLight | flash), start, end, path[{t (s from its start),
                                      x, y (0 to 1 of the camera's original picture)}] (at most 64), measures{azimuth, elevation, azimuthEnd,
                                      elevationEnd, duration, speed, acceleration, turnRate, maxTurn, straightness, shape (straight | curved | suddenStop |
                                      sharpTurn), sizeDegrees, brightness, blinks, blinkRate|null, focus, strobePeriod|null (s), strobeStrength|null,
                                      seenShare|null, wobble|null (degrees off a smooth path), turns|null} (on the sky, in degrees and ratios, never a real
                                      size or speed; the last five since 2026-10-26, null in an entry logged before them), label (unexplained | plane |
                                      probablePlane | satellite | probableSatellite | satelliteFlare | meteor | bug | bird),
                                      display (what the log shows: a person's correction wins, "notSure" shows label), by|null (flight | orbit | rule |
                                      model | ai | person), detail|null ("TEST123 · 35,000 ft"), unusual[] (faster | larger | brighter | suddenStop |
                                      sharpTurn), speedVsPlanes|null (a ratio), candidate, alerted, hasStill, priority|null (high | medium | low: the
                                      guide to the unexplained; null for the rest), reasons[] (short phrases for the person,
                                      the most telling first), doubtful (the rules doubt it was a light at all), group|null (the lights that moved together
                                      share it: "g-" and the first one's id, set as the log is read), sortedLater (since 2026-10-26: logged before the rules
                                      and sorted by them as the log is read; its label, by, detail and the guide's keys are theirs, and the log is not
                                      written), pieces (how many pieces the box saw the light in: 1 for a light seen whole), parts[] (a light the log kept
                                      in pieces, joined as it is read, before it is sorted: its parts' ids, its own first; [] otherwise; it is one entry and
                                      counts once), stillPart|null {id, path[]} (the part whose picture the light shows: its still and small picture are asked
                                      for by that part's id; null for a light the log kept whole), ai|null {kind, sentence, model, at}, correction|null (plane
                                      | bird | bug | satellite | meteor | notSure), watch (the recordings' moment to open: start minus 3 s)}. conditions[]:
                                      {from, to, state (clear | cloudy | notVisible | unknown), cloudCover|null}. counts:
                                      {unexplained, planes, satellites, meteors, bugsAndBirds, notSure, explained}, counted by what the log shows (a person's
                                      word wins; a light the box explained and the person was not sure of is notSure; explained = all but unexplained). aim:
                                      {quality (rough | good | precise), planes, stars, residualPixels|null, updated|null, lenses[{quality, planes, stars,
                                      residualPixels|null}], note|null}; learning: {ready, planes, satellites, planesNeeded, satellitesNeeded}. capped[]:
                                      {hour (the clock hour's start), count}: the hours of the view in which more lights were followed than the 200 a
                                      camera logs an hour (lights that no flight explains and that the rules leave unexplained or call a meteor, a bug or
                                      a bird; never their probable planes and satellites), and how many more (the page's "4 PM: 212 more lights weren’t logged"). picture|null: {width, height}, how
                                      big the night's pictures are in pixels (from the newest light with one that can be read; null when none can), which
                                      the page needs to draw a light's path over a thumbnail of it. 400 with the field date or view; 404 for a camera the
                                      bridge does not have; 409 no_location ("Set where the box is first.") or
                                      no_folder ("Choose a recordings folder first: the sky log is kept with the recordings."); 503 archive_unavailable
                                      (Retry-After) while the recordings' drive is away, 504 drive_slow while it does not answer
GET    /api/v1/sky/cameras/{id}/entries/{eid}/still?night=yyyy-MM-dd[&size=thumb|full]    the picture kept with an entry: image/jpeg (private, one hour); 404
                                      when it has none; 400 with the field night. size=thumb (the grid's cards) is a small one, at most 480 pixels wide: the
                                      close-up of the light around its path (the rectangle the page draws the path in: 16:9, the path's box with half its
                                      size more on every side, at least 160 x 90, inside the picture), or all of the picture, small, for a light that
                                      crossed more of the sky than a close-up holds. It is made once, when the picture is written (or the first time it is
                                      asked for, when it could not be made then), and kept beside the picture (<night>/<id>.thumb.jpg, mode 0600, counted in the camera's pictures and gone with the night; made again
                                      when the picture is written again), at low priority and at most two at a time. When it cannot be made the answer
                                      is the whole picture, 200 all the same, for a minute only (private, max-age=60). size=full and no size are the whole
                                      picture; any other size is 400 with the field size
POST   /api/v1/sky/cameras/{id}/entries/{eid}/correction   {night, label}: "That was a…", label plane | bird | bug | satellite | meteor | notSure -> the entry
                                      (as the log reads it: one logged before the rules sorted by them); the last word of an entry wins; a word on a joined
                                      light (sent with any part's id) is written to every part of it, and the answer is the joined light, sorted as one; 400
                                      with the field label or night; 404 for an entry the night's log does not hold
POST   /api/v1/sky/feeds/find         "Find a feed": the flight feeds (dump1090, readsb, tar1090, PiAware) on the box's own network, one address per host
                                      -> {feeds: [url]}; it asks only the hosts in the box's neighbour table, a few places each, for at most 20 s
POST   /api/v1/bridge/pause | resume
GET    /api/v1/logs?since=&limit=&level=   {lines: [{date, level, category, message, cameraID}]}; with Accept: text/event-stream, `event: log` lines live
GET    /api/v1/diagnostics            the text bundle the Mac app exports (attachment)
GET    /api/v1/events                 server-sent events: bridge, camera, removed, motion, doorbell, notices (the current state first), and ping (`data: {}`) every 15 s while nothing else is said
GET    /api/v1/system                 {product, version, build, mode (installed | development), osName, hostname, hardware, architecture, can*, canManage,
                                      sshEnabled?, automaticUpdates?, update?, install?}
POST   /api/v1/system/update          {action: "check" | "apply"}: check answers when the answer is in (at most 60 s); apply answers at once with state "downloading",
                                      then GET /system follows update.state (downloading -> ready, or error)
POST   /api/v1/system/reboot | poweroff   {confirm: true} -> 202
GET    /api/v1/system/disks           {disks: [{id, name, model, sizeBytes, note, eligible, problems[], phrase}]}: the installer's own list, usable or not
GET    /api/v1/system/recording-drives  {state: internal|mounted|missing|working|failed, message, drives: [{id, name, model, sizeBytes, note, eligible, problems[], phrase, isRecordingDrive, inUse}]}: the attached disks that could take recordings, and where recordings go now
POST   /api/v1/system/recording-drive   {targetID, phrase?, keepData?, password?}: phrase is "ERASE ALL DATA ON <disk name>" (erases and makes an ext4 file system labelled CBRECORDINGS; needs password, below); keepData: use a disk that already is a Camera Bridge recording drive as it is; -> 202
POST   /api/v1/system/recording-drive/forget  {confirm: true}: back to the box's own disk, the drive left alone; -> 202
GET    /api/v1/system/archive-drives  {state: none|mounted|missing|working|failed, message, drives: [{id, name, model, sizeBytes, note, eligible, problems[], phrase, isArchiveDrive, inUse}]}: the recording drive's list in the archive's view (the recording drive in use is never eligible); inUse: the archive drive now
POST   /api/v1/system/archive-drive   {targetID, phrase?, keepData?, password?}: phrase is "ERASE ALL DATA ON <disk name>" (erases and makes an ext4 file system labelled CBARCHIVE; needs password, below); keepData: use a disk that already is a Camera Bridge archive drive as it is; -> 202
POST   /api/v1/system/archive-drive/forget  {confirm: true}: stop using the archive drive, the drive and its recordings left alone; -> 202
GET    /api/v1/nvr/cameras/:id/clip-plan?from=ms&to=ms&tz=Zone  {camera, cameraName, parts: [{index, start, end, leadInMs, bytes, samples, fileName}], gaps: [{from, to, held}], soundOmitted, bytes, durationMs}: what a clip of that camera in that range would be, from the recordings' headers only
GET    /api/v1/nvr/cameras/:id/clip?from=ms&to=ms&tz=Zone&part=1   one MP4 (`attachment`, with `Content-Length`): the clip's part as planned, exactly `bytes` long, the video copied untouched; a part that cannot be finished (a drive gone, a damaged piece) ends the answer short, so the browser marks the download failed
       &labels=1 and/or &straighten=1   the part re-encoded by ffmpeg and streamed as fragmented MP4 (chunked, its size not known in advance; a conversion that fails ends without the last chunk, a failed download): with the camera's label burned in, and straightened by the camera's picture correction (straighten=1 is ignored while the correction is off: the copy above)
POST   /api/v1/import/mac-backup/preview  {file: <the Mac app's .camerabridge-backup JSON>} -> {cameras: [{id, name, vendor, host, username, record, enabled, alreadySetUp}], unreadable, appVersion, exportedAt}
POST   /api/v1/import/mac-backup          {file, passwords: {<camera id>: <password>}} -> {added[], addedOff[], alreadySetUp[], failed: [{name, message}], recordingPlaceChosen}: cameras keep their id, get a port of this box, are on only with a password; Record on with no place chosen yet picks the box's own storage
GET    /api/v1/system/wifi           {state, message, ssid, hotspot, saved[], lastError, hasWifi, wired, networks[]}: how the box is on the network
POST   /api/v1/system/wifi/scan      {} -> {networks: [{ssid, signal, security}]}: networks in range, strongest first
POST   /api/v1/system/wifi           {ssid, password}: save the network and restart to join it; -> 202
POST   /api/v1/system/wifi/forget    {ssid}; -> 204
GET    /api/v1/setup/wifi            (no session; only while the setup hotspot is open, else 409) {hotspot, networks, saved, lastError, needsAdminPassword, bridgeName}
POST   /api/v1/setup/wifi            (no session; only while the hotspot is open) {ssid, password, adminPassword?}: adminPassword is required once the bridge has one; -> 202, the box restarts
                                     While the hotspot is open, a request to any unknown host name is answered 302 -> http://10.42.0.1/setup.html (captive portal).
POST   /api/v1/system/install         {targetID, phrase, copyData?, password}: phrase is "ERASE ALL DATA ON <disk name>", typed by the person; -> 202, progress in GET /system install
POST   /api/v1/system/ssh             {enabled, authorizedKeys?, password?}: key login for root, plain public keys only (up to 20); turning it on needs password -> the system
POST   /api/v1/system/auto-update     {enabled} -> the system
POST   /api/v1/system/factory-reset   {confirm: "RESET", password} -> 202 (erases settings and pairings, restarts)
GET    /api/v1/system/secure-address  {available, enabled, state: off|waiting|ready|error, host, url, address, expiresOn, renewsOn, redirect, redirectActive,
                                      problem: {code, message} | null, rebind}: the HTTPS name; `waiting` also while the box has no internet (problem.code no_internet)
POST   /api/v1/system/secure-address/enabled   {enabled}: the switch (on by default); off, the box calls neither the website nor Let’s Encrypt and stops the redirect -> the report
POST   /api/v1/system/secure-address/redirect  {enabled}: send browsers opening http://camera-bridge.local to the secure address -> the report
POST   /api/v1/system/secure-address/check     the DNS rebind self-test -> {rebind: {state: ok|blocked|no_internet|wrong_address, message, checkedAt}}
POST   /api/v1/system/secure-address/retry     try again now -> the report
```

What gives root or erases asks for the administrator password once more, in the body's `password`: turning SSH on, a factory reset, installing to a disk, and a recording or archive drive that is erased (not one chosen with `keepData`). On the plain-HTTP address the session cookie and the CSRF token cross the network in clear text, so a session alone is not enough for these. The password goes through the sign-in limiter (Security). A missing one answers `403 {"error": "password_required", "code": "password_required", "message", "field": "password"}`, a wrong one `403 … "wrong_password" …` (403, not 401: the page stays signed in), too many tries `429 too_many_attempts` with `Retry-After`. The other fields are checked first, so a request that is wrong anyway costs no try.

Changes to the first draft of this contract: `POST /probe` and `POST /cameras` take the wizard's inputs by camera type (`GET /camera-types` says which); `/auth/setup | login | logout | password` are separate routes; `/health`, `/session`, `/camera-types`, `/bridge/pause|resume`, `/sensors-bridge`, `/integrations/*` and `/system/disks` were added; `/system/update` takes an `action`; `reset-pairing` and `test-motion` are per camera.

### The system helper

`camerabridged` runs as an unprivileged user and never starts anything privileged. The image offers a privilege-separated, asynchronous protocol (the contract is `linux/os/README.md`): the daemon writes one small JSON file per request into `CAMERABRIDGE_OS_REQUEST_DIR` (`/run/camera-bridge/requests`), named `<name>.json` with `<name>` one of `update-check`, `update-apply`, `auto-update`, `ssh-enable`, `ssh-disable`, `reboot`, `poweroff`, `factory-reset`, `install-list`, `install-to-disk`, `drive-list`, `drive-use`, `drive-forget`, `archive-use`, `archive-forget`, `wifi-scan`, `wifi-join`, `wifi-forget`, `guard-set`, `tls-obtain`. A systemd path unit wakes a root helper (`cb-system process-requests`) that first moves the file into a folder only root can change, checks the name and the JSON of that copy, and runs the job. The helper publishes how it goes as JSON files in `CAMERABRIDGE_OS_STATUS_DIR` (`/run/camera-bridge/status`): `<name>.json` (`state` queued, running, ok or failed; `message`; `updatedAt`), `update.json`, `install-candidates.json`, `install-to-disk.json` (`state`, `step`, `device`), `system.json` (`version`, `sshEnabled`, `autoUpdate`, `clock`, `link`), `disk-health.json` (the drives' daily check), `guard.json` (the internet guard, below) and `health.json`.

`RequestFileSystemControl` (BridgeDaemon) is the daemon's side:

| Web action | Request(s) | What the call waits for |
|---|---|---|
| `GET /system` | none: reads `system.json`, `update.json`, `install-to-disk.json` | nothing |
| update check | `update-check` `{}` | `update.json` reaching `available`, `current` or `failed` after the request (or `status/update-check.json` ok or failed), at most 60 s, then it gives up; the answer is `update.json` as the page's `UpdateStatus` |
| update apply | `update-apply` `{"reboot": false}` | only that the helper took the request; answers `downloading`, the page follows `GET /system` |
| reboot, power off | `reboot`, `poweroff` `{}` | only pickup |
| factory reset | `factory-reset` `{"confirm":"RESET"}` | only pickup |
| SSH on / off | `ssh-enable` `{"authorizedKeys": "<keys, one per line>"}` / `ssh-disable` `{}` | the job's `ok` or `failed` (30 s), then a moment for `system.json` |
| automatic updates | `auto-update` `{"enabled": bool}` | the same |
| disks | `install-list` `{}` | `install-candidates.json` newer than the request (30 s) |
| install | `install-list` first (fresh), then `install-to-disk` `{"device":"/dev/<name>","phrase":"ERASE ALL DATA ON <name>","copyData":bool,"poweroff":true,"dryRun":false}` | only pickup; `install-to-disk.json` has the steps |
| recording drives / archive drives | `drive-list` `{}` (one list for both) | `recording-drive-candidates.json` newer than the request (30 s); the state from `recording-drive.json` / `archive-drive.json` |
| use a recording drive / an archive drive | the list first (fresh), then `drive-use` / `archive-use` `{"device":"/dev/<name>","phrase":"ERASE ALL DATA ON <name>" or "","keepData":bool}` | only pickup |
| forget the recording drive / the archive drive | `drive-forget` / `archive-forget` `{}` | only pickup |
| watched cameras (the engine, `setGuardedCameras`) | `guard-set` `{"cameras":[{"address":"192.168.77.21","level":"watch"}],"timeZone":"<the bridge's>"}` | the job's `ok` or `failed` (30 s) |
| the guard's report (the engine, `guardReport`) | none: reads `guard.json` (up to 1 MiB) | nothing |

Rules it keeps: the file name always comes from a fixed list (`Request`), never from input; the body is built from validated values only (SSH keys are plain public keys, the disk is a kernel name from the installer's own list that is usable, the phrase is exactly `ERASE ALL DATA ON <name>`, a watched camera's address is a private IPv4 or a unique-local or link-local IPv6 address, at most 64); a request is written under a temporary name in the same folder and renamed onto `<name>.json`, so the helper never sees half a request; a request nobody takes within 15 s is withdrawn and reported; every wait is a bounded loop; a status file only counts when its `updatedAt` is not before the second the request was written. When the two folders do not exist (a Mac, a plain Linux box) the mode is `development` and every privileged action is refused with a sentence. There is no `sudo`, no setuid program and no shell in the path.

### The internet guard (Watch)

Stage 1 of docs/superpowers/specs/2026-10-17-internet-guard-design.md. A watched camera's DNS server is the box. `camera-bridge-dns.service` runs `dnsmasq` (as user `dnsmasq`, only `CAP_NET_BIND_SERVICE`) on the box's wired and Wi-Fi interfaces (never loopback: systemd-resolved keeps 127.0.0.53; `bind-dynamic` follows a changed address). It asks nobody and answers every name "does not exist" (NXDOMAIN), so the camera cannot find its cloud, and logs each question with the camera's address in memory (`/run/camera-bridge/guard/log`). The firewall's sets `guarded4`/`guarded6` (the watched addresses) are the only way in to port 53 besides the setup hotspot's own DNS, so the box is never a resolver for the house; it pauses while the setup hotspot is open. The root helper `cb-guard` keeps the list (`/srv/system/guard/cameras.json`, from the `guard-set` job), fills the sets and starts or stops the DNS (at boot `camera-bridge-guard.service`, after the firewall), and every minute while a camera is watched (`camera-bridge-guard-collect.timer`) adds the log to a 7-day hourly history (`/srv/system/guard/history.json`) and writes `status/guard.json` (readable by the daemon only): per watched camera since when it has been watched without a break (`since`), the lookups today (in the bridge's time zone, sent with the list) and in the last 24 hours, and its names with counts and first and last times, questions that never leave the home network left out of those and only counted (`local`, never named: since 2026-10-19, the bridge's proof that the camera asks the box); `running` says whether the DNS answers now. Port 53 takes at most 50 questions a second from each watched address. A request that comes while its job still runs is run by that job next (cb-system), and the daemon checks the report lists the cameras it sent. The daemon cannot read the journal or capture packets; this file is all it sees. Names, addresses, counts and times only, kept 7 days on the box, never sent anywhere.

The daemon offers the guard to the engine where the image has `camera-bridge-dns.service` and the request folders exist (not with `--dev`): `BridgeEnvironment.hasInternetGuard`, `setGuardedCameras` (the `guard-set` request through `RequestFileSystemControl`) and `guardReport` (`status/guard.json` as a `GuardReport`, nil while there is none). The Mac app has none. Seal (the camera's gateway is the box, nothing forwarded) is the next stage; nothing sets it yet.

### The daemon

```
camerabridged [--data-dir /var/lib/camera-bridge] [--port 80] [--static-dir|--web-root /usr/share/camera-bridge/web] [--loopback-only]
              [--allowed-host NAME] [--setup-token-file PATH] [--run-dir /run/camera-bridge] [--os-request-dir DIR] [--os-status-dir DIR]
              [--recordings-dir DIR] [--archive-dir DIR] [--log-level info] [--hap-base-port N] [--sensors-port N] [--dev] [--preview [scenario]] [--fake-discovery]
              [--no-demo-camera]
```

Every flag has a variable; a flag wins. The image's unit sets `CAMERABRIDGE_DATA_DIR`, `CAMERABRIDGE_WEB_ROOT`, `CAMERABRIDGE_HTTP_PORT`, `CAMERABRIDGE_RUN_DIR`, `CAMERABRIDGE_OS_REQUEST_DIR` and `CAMERABRIDGE_OS_STATUS_DIR` (the request and status folders default to `requests` and `status` in the run folder); `CAMERABRIDGE_RECORDINGS_DIR` (or `--recordings-dir`) is optional and not set by the unit; the older `CAMERA_BRIDGE_*` spellings (`_DATA_DIR`, `_PORT`, `_STATIC_DIR`, `_LOOPBACK_ONLY`, `_ALLOWED_HOSTS`, `_SETUP_TOKEN`, `_LOG_LEVEL`) still work, and the `CAMERABRIDGE_*` name wins when both are set. It logs to standard output (journald priorities when under systemd; the engine's diagnostics log in `<data>/Diagnostics` as always), sends `READY=1` once the web interface listens, `WATCHDOG=1` every WatchdogSec/3 (10 s for the image's `WatchdogSec=30`) while the engine runs and the interface listens (use `Type=notify`, `WatchdogSec=`), and shuts down on SIGTERM or SIGINT: web interface first, then the engine, within 10 seconds. `GET /api/v1/status` and `GET /api/v1/health` need no sign-in (the image's boot health check asks `health`: 200 while the engine runs, 503 while it starts or when it failed). `--setup-token-file` makes first-run setup ask for a code, so nobody else on the network can claim a new bridge; the image does not set one yet (the first person on the setup page sets the password).

### Recordings (the NVR)

The recorder, the catalog and the retention rules live in the engine (`BridgeEngine/NVR`) and are the same on the Mac and on the box; the daemon supplies what only the host knows. The folder is `recordings` inside the data directory (`/var/lib/camera-bridge/recordings`, which is `/srv/camera-bridge/recordings` on the data partition) unless `--recordings-dir` names a full path. The daemon makes the folder as the unprivileged user (0700) before the engine starts; inside the data directory it makes missing levels, anywhere else only the folder itself and only when its parent exists, so an unplugged drive cannot be re-invented on the system disk. The recorder never makes the folder or a parent of it. The web interface offers that one folder as the location `builtin` (the browser sends the id, never a path). Free space comes from `statvfs` (`f_bavail`); the data directory's device (`st_dev`) is the system volume, which keeps `max(8 GiB, 5% of the partition)` free (recording pauses below it and resumes 1 GiB above it) because settings, HomeKit keys, the journal and `cb-update`'s 4 GB share that partition; a folder on another device keeps 2 GiB. Camera folders are named by the camera's UUID, `camera.json` inside carries the name. Starting never waits for the archive: the store repairs unclosed files and loads its catalog in the background, and `READY=1` does not depend on it (`TimeoutStartSec=120`; three unblessed boots roll the OS back). The hardened unit lets the daemon write only inside `/var/lib/camera-bridge`, so a recordings folder anywhere else needs the unit changed; that comes with external drives. `--preview` has no recordings and no archive.

#### The archive drive

A second drive where older recordings move when the recordings drive fills, instead of being deleted (`cb-recording-drive --archive`, linux/os/README.md;
the engine's side is BridgeEngine's README, "the archive drive"). It is separate from the recording drive, which replaces the box's own disk for every
recording: the archive keeps the recordings folder (and the Sky Watcher's `.sky` and the events' `.events`, which never move) on the box's disk.

```
recordings drive (the box's SSD)                       archive drive (USB, /var/lib/camera-bridge/archive, label CBARCHIVE)
  <recordings>/<camera>/<date>/<HH-mm-ss>.mp4 ──move──►  <archive>/<camera>/<date>/<HH-mm-ss>.mp4   (same names, same fragment ids)
  <recordings>/.events, .sky   (never move)              .camera-bridge-archive   (the OS's marker: without it nothing is written there)
```

- **Choosing it.** The System page's "Archive drive" card lists the disks (`GET system/archive-drives`: the recording drive's `drive-list`, in the archive's
  view) and makes one the archive (`POST system/archive-drive`): erased with the typed `ERASE ALL DATA ON <disk>` (one GPT partition, ext4 `CBARCHIVE`, as a
  recording drive is made), or used as it is when it already is one. `cb-recording-drive --archive` mounts it on `/var/lib/camera-bridge/archive` (inside the
  unit's `ReadWritePaths`; mounts there reach the running engine), writes the marker, keeps the choice in `/srv/system/archive-drive`, mounts it at boot and when
  it is plugged in, and puts a read-only placeholder there while it is chosen but away. The engine is never restarted for it.
- **Moving.** With the archive connected, answering and loaded, retention moves what its size rule would delete: oldest first, while the archive has room
  within its size minus twice its floor (2 GiB) and above its floor; the archive deletes its own oldest to take newer files and keeps the same `nvrKeepDays`.
  A move is a copy to a temporary name (SHA-256 as it is read, `fsync`), a read back that must match, the names in place, the catalog switched, then the box's
  copy deleted once the archive's is found whole again (it waits while the drive is away); one file at a time on a thread at `nice` 19 and the idle I/O class, at most 32 MiB/s, waiting while someone watches archived video. A crash at
  any step leaves exactly one good copy after the next start. Without a usable archive (none chosen, unplugged, not answering, failing, full) retention deletes
  exactly as before, and recording never pauses because of it: over the box's size minus 1.5 floors the oldest are deleted even with an archive.
- **Reading.** The catalog knows each file's drive; the playback, clips, events, their pictures and the Sky Watcher's player read archived video the same way,
  through the archive's own read queue (the same 5 s deadline), so a slow USB drive cannot hold up the box's own reads. While the drive is away its recordings
  stay on the timeline as "on the archive drive (not connected)" (`nvr/activity` `away`, a plan's `reason: "archiveAway"` with where video plays again; a list
  in the data directory remembers them across a restart without the drive); plugged back in, they play again. `GET nvr/storage` has its `archive`: state,
  used and free, how far back it goes, what moves now and what waits.

### Recordings in the browser

Recorded video reaches the page as small pieces, and the browser's own video decoder does the decoding; the box decodes nothing. The box serves plain HTTP, and the browser features for decoding in script (WebCodecs) exist only on secure pages, so the page uses Media Source Extensions, which work on any page. `linux/web/README.md` lists the modules.

- **Pieces.** The recorder cuts every file into fragments of at most 2.5 s: at every keyframe, or 2.5 s into a long group of pictures. `GET /nvr/cameras/{id}/fragments?at=ms` returns the plan for a moment: the fragment that holds it, the key fragment its group of pictures starts in, and the next few, each with an opaque id (`<12 hex digits>.<index>`, stable across restarts), its times and size, and per file the codec string (`mime`), the picture size, the file's `anchor` time and which fragment's `/init` to fetch. The page appends the init segment and the pieces to one MediaSource per tile. The box serves video only: `ArchiveMedia` (in `BridgeEngine/NVR`, because `BridgeWeb` may not import `FMP4`) drops the `prft` box and, for a file with sound, the audio track.
- **Dragging** the timeline: where the browser's row of `POLICY_TABLE` (`js/nvr/planner.js`) has key steps on (at present Chrome on a Mac, the only class the browser spike ran on a device), the page fetches `GET /nvr/cameras/{id}/keyframe?at=ms`, the whole key fragment of the moment's group of pictures, and shows its first picture; in every other browser the picture arrives only after the pointer pauses. About 80 ms after the pointer stops, the page fetches the pieces from there to the moment and shows the exact frame. Releasing plays: `fragments?after=<id>` keeps the buffer a few seconds ahead.
- **Time.** Every time on the wire is Unix epoch milliseconds from the box's clock. The page measures its offset from `serverTime` in `GET /nvr/cameras` (polled every second while a recordings screen is open) and uses it for every "now". A file's media time maps to epoch time through its `anchor`; the page adds a fixed base so that buffer times stay positive.
- **Live** is the recorded edge, played 6 s behind the box's time. With Record off or paused the page falls back to the snapshot preview (`GET /cameras/{id}/snapshot`, a new picture every 5 s).
- **Banners.** The `notices` event (and `GET /status`) carries one more notice while Record is on for a camera: id `nvr-storage`, "Recording Can’t Continue" with the reason and an `action` (`choose-folder` or `open-settings`), or "Recording Storage Almost Full" when less than 5 GiB remains above the floor. Older pages ignore the new `action` field.
- **When the recordings are out of reach.** A read answers `410 gone` when the piece is no longer there (retention took it, or its drive is away), `504 drive_slow` (with `Retry-After: 2`) when the disk did not answer within 5 s, and `502 unreadable` when the piece cannot be read (a damaged piece, or a file that was open when its volume vanished). The page asks the status which it is: a 504 always means the drive, and a 410 or a 502 means the drive while the camera's `status.nvr.pause` is `folderMissing`. The tile then keeps its last picture, stops the clock, says "The recordings drive isn’t connected." and looks again every 5 s with one small read; when the box answers, playback starts again from the same place. Without that pause, a 410 makes the page ask for a new plan once (retention changed the catalog), and a 410 or a 502 after that is shown as a part that cannot be read.
- **Kept recordings ("Keep this").** A stretch of one camera's recordings (at most 24 hours) the person keeps, in `<recordings>/.kept.json` (0600; a file that does not decode is set aside as `.kept.json.unreadable`). A recording file that overlaps one is never a retention candidate on either drive and never moves to the archive; its bytes still count against the box's limits, so newer files make room for it, and together kept files may take at most a quarter of the box's limit (`KeptRecordings.shareOfMaximum`), so recording never pauses because of them. The camera's event days it touches are kept too. Letting it go makes it an ordinary recording again.
- **Events.** The engine keeps every camera's events beside the recordings, whether or not its video is recorded: `<recordings>/.events/<CAMERA-UUID>/<yyyy-MM-dd>.jsonl` (one file per camera per UTC day of the events' starts, 0600 in folders of 0700; the dot keeps it out of the catalog). Each line is one JSON object: an event began (`{"camera", "id", "kind", "start", "v": 1, "video"}`, `video`: the camera's recorder was writing), ended (`{"end", "id", "v": 1}`, in the same file) or was described by an AI service (`{"ai": {"summary", "kind", "concern", "model", "at"}, "id", "v": 1}`, `at` in milliseconds like every time here; written to the day file of the event's start whenever the answer comes, so retention takes both together; the last one of an id wins, one of an id the file does not hold is ignored, a line over 2 KiB is not written or read, and a build that does not know `ai` skips the line as neither a start nor an end). The router's rising and falling edges write them (the names `status.recentEvents` uses: Motion, Person, Vehicle, Animal, Package, Face, Doorbell ring, Tamper, Alarm input …, Sound; a ring ends as it begins); a line that does not parse (a torn last line after a power cut) is skipped and the next append starts on a new line, and an event the bridge stopped during has no end. Retention deletes whole day files by the recordings' rules: days that ended before the keep time, and days before the newest file the size rule deleted; a new place for recordings starts a new log there. Nothing is kept while no place for recordings is chosen. `GET /nvr/events` reads them (`recorded`: the recordings hold video at the event's start now, or the recorder was writing it less than 2 minutes ago). One publication of the router stamps all its edges alike (a ring with its motion, a motion with its person), so a page never splits a millisecond: asked again with `to` = the oldest start, the next page finds that moment whole. Only a bridge with no place for recordings answers no events without looking; while the recordings load or their folder is missing the route answers `503 archive_unavailable` with `Retry-After`, and the page tries again instead of taking the range for empty. `.events` and the camera folders are never written, read or pruned through a link. The Monitor's events list asks for the timeline's range, newest first a page of 200 at a time (older pages when the range grows or on "Show older events"; the newest part again every 30 s while it follows live, and when more than a page began there, the rest of it at once, so a burst leaves no hole), merged with the live events and `status.recentEvents`; a row the archive says is not recorded is dimmed.
- **The Sky Watcher's log.** Beside the events, `<recordings>/.sky/<CAMERA-UUID>/<yyyy-MM-dd>.jsonl` (one file per camera per night, 0600 in folders of 0700; the dot keeps it out of the catalog), appended one JSON object per line, keys sorted, times in milliseconds: a light (`{"entry": {…}, "v": 1}`), a person's word on it (`{"correction": {"at", "label"}, "id", "v": 1}`), the AI's answer (`{"ai": {"at", "kind", "model", "sentence"}, "id", "v": 1}`), an alert (`{"alerted": true, "id", "v": 1}`) and how the sky was (`{"conditions": {"cloudCover", "from", "state", "to"}, "v": 1}`). A night is named by the local date of its sunset and a day by its own date; an entry is filed by its time, so a night is one file across midnight, and one file holds a day and the night that follows it (the log named D reaches from the sunrise of D to the sunrise of D+1). The first entry line of an id wins and the lines after it apply to it (the last correction and the last answer win; one for an id the file does not hold is ignored); a line that does not parse is skipped. The picture of an entry is `<yyyy-MM-dd>/<id>.jpg` in the camera's folder (at most 2 MiB). Writes run on a queue of their own and never wait for a drive (what cannot be written waits, at most 1000 lines and 16 MiB of pictures); `.sky`, a camera's folder, a night's file and its folder of pictures are never written, read or pruned through a link. Retention deletes a night with its pictures when its date and the day after it are over by the events' cutoff. Nothing is kept while no place for recordings is chosen. Where the box is is in none of it.
- **Limits.** The archive routes (`fragments`, `keyframe`, `activity`, `events`) allow 24 requests in flight in all and 16 per peer address (`maximumArchiveReads`, `maximumArchiveReadsPerAddress`); the next gets `429 busy` with `Retry-After: 1` at once, and `503 archive_unavailable` while the store loads (the daemon does not wait for it to start). An answer is at most 16 MiB. The page keeps to 3 byte fetches and 1 JSON request at a time and does not abort one to cancel it, because a buffered answer cannot be cancelled on the box; it gives up on a request only when the screen is left or after 8 s without an answer.
- **Security.** Every NVR route needs a session (the session cookie), and the seven a player reads recordings with (the catalog, activity, events, fragment plans, fragments, init segments and key pictures: the "viewer" rows above) also take an Apple TV's or iPhone's key as `Authorization: Bearer <key>`; storage, Record, Keep this and the rest are the owner's page only. GET needs no CSRF token, PATCH and POST need the usual one. The browser sends ids and times, never a path. Footage is `Cache-Control: no-store`, HEAD on a media route is 405, and the Content-Security-Policy gains exactly `media-src 'self' blob:`. No credential, path or camera address appears in an answer, a log line or a URL.

## Security

- The web interface is for the local network only; the box never opens a port to the internet. Only IP addresses, `localhost`, `*.local`, `*.home.arpa`, names without a dot and `--allowed-host` names are served (DNS rebinding).
- First boot: no admin yet. The UI asks you to set a password on first visit (and the setup code, when the image has one). Until then the API offers only `/status`, `/session`, `/health` and `/auth/setup` (`/monitor` is open too, but answers only to a token, which needs a signed-in owner to make; so are `/viewers/pair` and `/viewers/pair/status`, which only make a code that a signed-in owner must approve).
- Passwords: PBKDF2-HMAC-SHA256, 600,000 rounds, 16-byte salt per password (swift-crypto), 8 to 256 bytes. Wrong guesses: 5 free per address (an IPv6 address counts by its /64), then a 15 s lockout that doubles up to 15 min; 60 failures from anywhere slow everyone for a minute. A check is admitted before its password is hashed and the checks still running count as failures already, so guesses sent in parallel cannot get past the 5; at most 4 checks run or wait at once, from everywhere, and the next answers 429 at once instead of queueing. The login, the setup code, the password change, and the setup hotspot's administrator password all go through it. Comparisons are constant time.
- Sessions are random 256-bit tokens in `HttpOnly; SameSite=Strict` cookies, kept server-side only as SHA-256 hashes (`<data>/web/auth.json`, 0600), 7 days idle, 30 days at most, signed out by a password change. Changing requests need a matching `Origin`, the session's HMAC-derived `X-CSRF-Token` and a JSON content type.
- Apple TVs, iPhones and iPads: a device is added only when the signed-in owner types the code it shows, and it collects its key once: 32 random bytes as 64 hex. The box keeps only the key's SHA-256, with the device's name, model, when it was added and when and from where it was last used, in `auth.json` beside the sessions; the key itself is only on the device, and no admin password is typed into or kept on one. The key works only as `Authorization: Bearer` (never in the address) and only on the twelve "viewer" routes: live and recorded video, pictures, `GET /viewer`, moving a camera that pans and tilts, and `POST /hls/tickets`. It changes nothing else on the box: every other route that needs a session answers it 401, and an open route answers it as it would anyone. A key unused for a year stops working; at most 20 devices; changing the password keeps them, a factory reset removes them. Removing a device in Settings refuses its key at once and ends a live view it has open within 5 s (`WebConfiguration.viewerRecheckInterval`).
- HLS tickets: AVPlayer (AirPlay, CarPlay) needs an address and cannot send a header, so `POST /hls/tickets` (a viewer route) trades a key (or a browser's session) for a ticket that goes in the path of `GET /hls/<ticket>/<file>`. **That is a deliberate exception to the rule that no token is accepted in an address**: the viewer key itself stays refused in any address, and the ticket opens one camera, read-only, for minutes. A ticket is 32 random bytes as hex, held in memory only (never in `auth.json`, gone at a restart), compared in constant time, and ends 5 minutes after its last use or 6 hours after it was made; a device holds at most 8 (the oldest goes first). A device removed from the list, or a browser signed out or whose password changed, loses its tickets at its next request. An unknown, ended or foreign ticket and a missing file are the same empty 404, and every answer is `no-store`. A live ticket plays only the packager it was made against: once that one has stopped (30 s after its last request) the ticket gets 404 and the player asks for a new ticket. HLS is for the home network only for now: nothing here is meant to be reached from the internet, and the box is not exposed to it.
- `auth.json` that is there but cannot be read or decoded is never taken for a new bridge (setup would be open to whoever comes first): the daemon reads `auth.json.bak` instead when there is one (a copy somebody put there: saving never keeps the file it replaces, so nothing on the box makes it), and without one nobody can sign in (`503 auth_unreadable`, with the way out) until a factory reset (the `camera-bridge-factory-reset` marker on the boot partition); the damaged file is left as it is. While the file cannot be written (a full or read-only data partition) a sign-in still works: the session is kept in memory and saved once the disk takes it again; a first-run setup that cannot be saved is undone.
- Strict headers: a Content-Security-Policy that allows only the bridge's own files (no inline script or style; `media-src 'self' blob:` lets the page play video it assembled itself), `nosniff`, no referrer, no framing, same-origin resource and opener policies.
- Camera passwords, cloud sources, HomeKit keys and the AI service's key (`ai.key`) are in the encrypted secret store; none appears in an answer, the log, the diagnostics or the web interface's files. The AI key is write-only: `PUT /api/v1/ai/key` stores it, `DELETE` removes it, and the settings answer carries only whether one is saved and its last four characters (none for a key under eight). It belongs to one service: the settings update that changes the service, or the scheme, host or port of an OpenAI-compatible address, deletes it first, so a key is never sent to another service.
- `nftables` default-deny inbound. From the local network only (the private and link-local ranges and the prefixes the box's own network is on, IPv6 included: IPv6 has no NAT to hide behind): 80 (UI), 443 (the TLS front), the HAP ports (21100–21199), mDNS, NTP, SSH only if enabled, and the engine's ephemeral media ports. DNS only from the setup hotspot and the cameras the internet guard watches.
- Where the box is (`sky.location`, for the Sky Watcher) stays on the box: it is in `config.json` and in `GET /settings` for a signed-in page, and nowhere else. No log line, diagnostics report, notification, AI request or export holds it, `SkyLocation` prints as "location hidden", and no sentence of an error repeats what was typed.
- A burst of wrong passwords (an address locked out, or everyone slowed down) becomes one security notification, "Wrong Passwords Entered" (`kind` `signInAttempts`, in the notification log and as a toast for one browser); every wrong password until a day passes without one is part of the same burst.
- No telemetry. The only outbound calls are to the cameras, Apple's push relay (through the HomeKit hub), GitHub for update checks, go2rtc's cloud sources if you add Ring or Nest, the AI service you choose (only for cameras with AI descriptions on, and only still pictures), and, for the secure address while its switch is on (the default), www.camera-bridge.app and Let’s Encrypt: the box registers once with its public key (the website then sees the home's public address), tells the website its private home address whenever that changes (it becomes the public DNS record of `<name>.box.camera-bridge.app`), and asks Let’s Encrypt for a certificate (the website writes the DNS challenge; certificates are listed in public Certificate Transparency logs, so box names can be found there). `POST /api/v1/system/secure-address/enabled {enabled: false}` stops all of it; a box with no internet shows the secure address as waiting, not as an error.
- **AI descriptions** are the one call that sends pictures from your cameras to a cloud service, and they are off until the owner chooses a service in Settings, saves its key (if the service needs one) and switches AI descriptions on for a camera (`CameraConfiguration.aiDescriptions`, off by default). The daemon makes the call, never the web page (the Content-Security-Policy still allows only the box's own files). For each event on such a camera it sends one HTTPS request (an `http://` address is allowed only for a model on the home network: a private, loopback, link-local or 100.64/10 IPv4 address, a unique-local or link-local IPv6 address, a `.local`, `.lan`, `.home.arpa` or `.internal` name, or a name with no dot; then the key, if any, and the pictures travel unencrypted on the home network. The engine refuses `http://` to any other host, "Use https:// for a service on the internet.", and a saved one is not used) to Claude (`https://api.anthropic.com/v1/messages`) or to `<address>/chat/completions` of an OpenAI-compatible service the owner typed (OpenAI, OpenRouter, Ollama, LM Studio …; one at home keeps the pictures on the home network). It carries at most 5 JPEGs, each at most 768 px wide, gathered when the event starts (up to 2 keyframes before, the camera's own event picture or the event's frames, up to 2 keyframes after, at most 6 s later), the camera's name, the kind of event and the local time; no video, no sound. Nothing is sent for a camera whose switch is off; the one exception is Try it (`POST /api/v1/ai/try`), which the owner presses for a camera chosen in Settings, works with the switch off and sends that camera's pictures at that moment. Limits: events are described one at a time (one event's pictures are made and sent before the next event's; Try it runs beside them, one Try it at a time); at most one per camera per 60 s, counted from the last event picked, except a doorbell ring 10 s or more after the camera's last one picked (the ring that follows the person who walked up to the door); a set that waited more than 60 s is dropped; at most `dailyLimit` a day (200 by default, 1 to 5000), counted in `<data>/ai/usage.json` so a restart keeps the count; the HTTPS request times out after 20 s and a network error or a 5xx is tried once more; a send the service could not take (not reached, a 5xx, a 429) is given back, and after 3 such events in a row nothing is gathered or sent for a while (1 minute, doubling up to 15; `retryAt` in the settings), so a service that is down neither uses up the day's limit nor makes pictures for nothing. The camera's switch and the service are read again right before each send, the first and the retry: an event whose switch went off, or whose settings, service or key changed (or Off was chosen), while its pictures were made or the retry waited, is dropped unsent (and, before its first send, uncounted). The AI HTTP client never follows a redirect (`AuthenticatingHTTPClient(followsRedirects: false)`, the camera clients keep theirs): the key and the pictures go only to the saved address, and a 3xx is the answer "The service tried to send the request elsewhere; check the address." Other statuses have their own plain sentences too: 400 "The service refused the request; check the model name.", Claude's `stop_reason` "refusal" "The service declined to describe these pictures.", and a 401 from an OpenAI-compatible service with no key saved "The service needs a key." (which pauses nothing; a refused key, "The key was refused.", pauses). A summary is cut to its first line, stripped of control and format characters (bidi overrides, zero-width marks; the joiner inside an emoji stays) and capped at 140 characters and 600 UTF-8 bytes at a word; every change to the AI settings starts a new generation of the describer (the last error is forgotten, a pause may end, and nothing under way is sent on to what replaced it). The camera page's Security card says "Its event pictures go to <service> for AI descriptions." while the camera's switch is on and the service is Claude or an OpenAI-compatible address that is not on the home network (a private, loopback or link-local IPv4 address, or a `.local` or `.lan` name); no badge or level changes. The pictures are not kept. The answer, a sentence with a kind and a concern, is stored in the event log (see Events) and shown on the Monitor's events list and the camera page. A refused key pauses descriptions until the key or the service changes or Try it works; viewing, recording, Apple Home and the guard never wait for the service.

## Operating system

- Debian 13 (trixie), minimal; built with `mkosi` into a GPT disk image.
- UEFI + systemd-boot. Partitions: ESP (512 MB), root A and root B (read-only, 2.5 GB each), data (the rest, ext4, grows on first boot).
- A/B updates with `systemd-sysupdate` and `systemd-bless-boot`: a new root is written to the idle slot, booted once, and kept only if `camerabridged` reports healthy.
- Runs straight from the USB stick (the data partition lives on the stick; use a good stick or an SSD in an enclosure) or installs to the machine's internal drive.
- Intel N100 / N150 mini PCs are the reference hardware (hardware H.264 encode through VA-API). Raspberry Pi 5 (arm64) follows, passthrough only.
- Reproducible: the image build is a GitHub Actions workflow (`.github/workflows/os-image.yml`); every release carries SHA-256 and a signature.

## Repository layout (Linux parts)

```
Packages/CameraBridgeKit/Sources/PlatformLinux/   Linux implementations of the platform services
Packages/CameraBridgeKit/Sources/BridgeWeb/       portable HTTP server + JSON API over NetworkTransport (testable on a Mac)
Packages/CameraBridgeKit/Sources/BridgeDaemon/    the daemon's logic: flags, systemd, logging, the system helper (testable)
Packages/CameraBridgeKit/Sources/camerabridged/   the daemon (executable; only a main)
linux/web/                                        the web UI (static files; no build step needed at runtime)
linux/web-tests/                                  tests of the web UI's pure modules (Node); outside linux/web because the image copies that whole directory
linux/web-dev/                                    web UI development tools: a dev server for the recording routes, fixtures, the conformance check, the lint
linux/os/                                         mkosi config, systemd units, sysupdate, installer, first-boot
docs/linux/                                       this file, the user guide, the build guide
```

## Build and test

- macOS: `swift test` in `Packages/CameraBridgeKit` runs everything that is portable, including `BridgeWeb`.
- The UI on a Mac: `swift run camerabridged --dev --data-dir /tmp/cb-dev --fake-discovery` (in `Packages/CameraBridgeKit`), then open `http://127.0.0.1:8080`. It runs the real engine with demo cameras, nothing advertised, the HomeKit ports from 38100; `--preview` serves the engine's sample data instead.
- Linux: `Tools/linux-test.sh` runs the same tests in a Swift container (Docker or OrbStack). CI does it on every push.
- Web UI: `node --test 'linux/web-tests/*.test.mjs'` from the repository root runs the tests of the page's pure modules (Node 22 or later, no packages; the quotes matter). `linux/web-dev/` has the dev server and the conformance check against a running daemon (`linux/web/README.md`).
- OS image: `linux/os/build.sh` (needs Linux and root) or the GitHub Actions workflow.

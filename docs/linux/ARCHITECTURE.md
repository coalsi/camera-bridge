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
avahi-daemon         mDNS (HomeKit advertising)
camerabridge-web     not a process: camerabridged serves the web UI itself on :80, plain HTTP (nothing listens on :443; HTTPS is a later option)
```

go2rtc (MIT) is part of the image: built from a pinned commit of its master (`1.9.14+dev.c245815`, for the fixes to its native Wyze source after v1.9.14) by `linux/os/fetch-go2rtc.sh`, checked against a pinned SHA-256, installed `0755 root:root` at `/usr/lib/camera-bridge/helpers/go2rtc` (the folder `ProcessHelperLauncher` searches after `CAMERABRIDGE_HELPERS_DIR` and the daemon's own folder), licence at `/usr/share/doc/go2rtc/copyright`. It runs as a child of `camerabridged`, so as user `camerabridge` inside the daemon's sandbox. See BUILDING.md, "The go2rtc helper". Our own helpers `wyze-lake` (Go, MIT) and `eufy-bridge` (Node.js 24 with the eufy SDK, Apache-2.0; amd64 images) are built from `linux/helpers/` by `linux/os/build-helpers.sh` and installed in the same folder the same way; they run as children of the daemon too (BUILDING.md, "Our own helpers").

State lives in `/var/lib/camera-bridge` (a separate data partition, so updates never touch it): `config.json`, `hap/`, `secrets/` (the encrypted items and `master.key`), `ai/usage.json` (how many AI descriptions were asked for on each of the last 8 days), `Diagnostics/`, and `recordings/` (the NVR's files, once Record is on). This is the same layout the Mac app uses in `~/Library/Application Support/CameraBridge`.

## Web API (served by `camerabridged`)

JSON over HTTP on port 80 (`http://camera-bridge.local`). Types follow the Mac app's models (`CameraConfiguration`, `CameraStatus`, `DiscoveredCamera`, `NetworkNotice`) and its words (`StatusText`, the Add Camera wizard's pages and messages), so the two UIs say the same things. Errors are `{"error": "<code>", "message": "<a sentence for the person>", "field": "<input, when one is to blame>"}` with the usual status codes (400 invalid, 401 unauthorized, 403 csrf / cross_origin / setup_required, 404 (`gap`: nothing recorded at that time), 409 (`folder_required`, `confirm_required`), 410 gone, 415, 422 the engine refused (`folder_rejected`), 429 too_many_attempts, too_many_streams or busy, 502 unreadable, 503 no_picture or archive_unavailable, 504 drive_slow). Every answer carries `Cache-Control: no-store` and the security headers.

Sessions: the `cb_session` cookie (see Security). Everything needs a session except the rows marked "open". Requests that change something also carry `X-CSRF-Token` (from `/session`, `/auth/login` or `/auth/setup`) and `Content-Type: application/json`.

```
GET    /api/v1/status                 open: {product, version, name, setupRequired, authenticated}; signed in: + state, uptime, camera counts, notices, system summary
GET    /api/v1/health                 open: 200 while the bridge runs (or is paused on purpose), 503 otherwise (the A/B update's health check)
GET    /api/v1/session                open: {authenticated, setupRequired, setupTokenRequired, bridgeName, csrfToken?}
POST   /api/v1/auth/setup             open, once: {password, bridgeName?, setupToken?} -> session
POST   /api/v1/auth/login             open: {password} -> {csrfToken, bridgeName} + cookie        (429 after 5 wrong tries per address)
POST   /api/v1/auth/logout
POST   /api/v1/auth/password          {current, new}; signs every other browser out
GET    /api/v1/camera-types           the Mac app's Camera Type page: groups, types, setup steps, what you get, which inputs
GET    /api/v1/cameras                {cameras: [camera]}; a camera is its CameraConfiguration JSON plus `status` (live state), vendorName, kindName, address,
                                      motionSourceName, internetWatched (the Internet guard watches it: the engine's verdict) and restartOffered (the
                                      camera waits for a restart to apply a change it took: "Restart the camera now"), both always there; `skyDetector`
                                      is the Sky Watcher's settings of the camera, or null when they were never saved; `status.sky` is its Sky Watcher
                                      while it is on (absent while the plugin or the camera's switch is off): {running, stream (main|sub), analysisWidth,
                                      picturesPerSecond, decoding (gpu|software), aim, learning, problem (a sentence, or null), profile}
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
                                      needs none of them, and a camera keeps its settings while the plugin is off)
PATCH  /api/v1/cameras/{id}/nvr       {enabled?, recordSound?}: Record on or off, Record sound on or off, in place (the camera is not restarted);
                                      409 folder_required until a place for recordings was chosen
DELETE /api/v1/cameras/{id}
GET    /api/v1/cameras/{id}/snapshot  JPEG, straightened by the camera's pictureCorrection; ?original=1: the camera's own picture (the camera
                                      page straightens that itself while its sliders move) (503 + Retry-After while there is none)
GET    /api/v1/cameras/{id}/live      multipart/x-mixed-replace JPEGs (the fallback where a browser cannot play live video), at most 15 minutes;
                                      straightened like snapshot, ?original=1: the camera's own pictures
POST   /api/v1/cameras/{id}/clean-picture {clean}       every label the camera draws itself off (clock, name, text, logo), or back as saved
POST   /api/v1/cameras/{id}/camera-clock {shown}        the camera's own on-screen date and time on or off (vendor API, then ONVIF OSD)
POST   /api/v1/cameras/{id}/camera-time-zone            the camera's clock set to the bridge's time zone (ONVIF SetSystemDateAndTime): {timeZone: POSIX string}
GET    /api/v1/live?cameras=<id>,…&stream=sub|main|automatic[&width=]   live video of 1 to 32 cameras in one answer: the cameras' own H.264/HEVC as fragmented MP4, framed per camera (type, camera, length; see BridgeWeb/WebApp+LiveVideo.swift); at most 16 live answers at a time
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
GET    /api/v1/nvr/storage            where recordings go and the numbers: state, keepDays, maxSizeGB, used / free / total / floor / room bytes, effective maximum, oldest, newest
GET    /api/v1/nvr/storage/locations  the places this bridge offers (one on the box) with free space and any problem; the browser sends the id, never a path
PATCH  /api/v1/nvr/storage            {location?, keepDays?, maxSizeGB?, confirm?}: choose the place and the limits; 409 confirm_required when it would delete recordings
GET    /api/v1/nvr/cameras            {serverTime, catalogVersion, cameras: [{id, oldest, newest, typicalGOP}]}: what is recorded
GET    /api/v1/nvr/activity?cameras=&from=&binMs=&bins=      the timeline's activity per camera (coverage, bytes per second, typical)
GET    /api/v1/nvr/events?cameras=&from=&to=&limit=          {from, to, serverTime, more, events: [{id, cameraID, kind, start, end, recorded, description}]}: the cameras' events that began in from..<to (at most 31 days, 1 to 16 cameras), newest first, at most limit (1 to 1000, default 200); more: older ones were left out (ask again with to = the oldest start). A page never splits a millisecond: the events of its oldest start are all in it or all in the next (more than limit at one moment with nothing newer: that moment whole). 503 archive_unavailable (Retry-After) while the recordings load or their folder is missing, never an empty answer. description: what an AI service said it saw at the event's start, {summary, kind (person, vehicle, animal, delivery, other, nothing), concern (routine, unusual, alarm)}, or null when none was written (the model and the time stay in the log)
GET    /api/v1/nvr/cameras/{id}/fragments?at=ms[&ahead=n] | ?after=id[&limit=n]    which pieces to play: ids, times, sizes and the codec string
GET    /api/v1/nvr/cameras/{id}/fragments/{fid}         one piece, video only, as fragmented MP4 (at most 16 MiB; no Range; HEAD is 405)
GET    /api/v1/nvr/cameras/{id}/fragments/{fid}/init    the matching initialization segment
GET    /api/v1/nvr/cameras/{id}/keyframe?at=ms          the whole key piece of the group of pictures that contains the time; X-CB-Part describes it
GET    /api/v1/settings               {bridgeName, basePort, sensorsBridgePort, webhookEnabled, webhookPort, webhookToken, webhookProblem, logLevel, motionShadowTest,
                                      ai: {provider: "anthropic"|"openAICompatible"|null, model, baseURL|null, dailyLimit, keySaved, keyHint|null,
                                      today, last7Days (today and the 6 days before, the bridge's time zone), limitReached, paused (the key was
                                      refused: nothing is described until it or the service changes, or Try it works), lastError|null (the
                                      sentence), lastErrorAt|null, needsRecordingsFolder (none is chosen: no event is kept, so none is described)},
                                      sky: {location: {latitude, longitude, heightMeters}|null, flightFeedURL|null, aiDailyLimit}}; never the key.
                                      The place is shown here, to the signed-in page, and nowhere else
PATCH  /api/v1/settings               the same keys (+ regenerateWebhookToken); `ai: {provider (string or null), model, baseURL (string or null), dailyLimit}`:
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
                                      entries[], conditions[], counts, aim, learning}. A night (sunset to sunrise) is named by the local date of its
                                      sunset, a day (sunrise to sunset) by its own date, in the bridge's time zone; no date: the latest (the night in
                                      progress or the one that ended this morning; for the day view, today's); no view: the night. Times are epoch
                                      milliseconds. An entry: {id, camera, kind (track | newLight | flash), start, end, path[{t (s from its start),
                                      x, y (0 to 1 of the camera's original picture)}] (at most 64), measures{azimuth, elevation, azimuthEnd,
                                      elevationEnd, duration, speed, acceleration, turnRate, maxTurn, straightness, shape (straight | curved | suddenStop |
                                      sharpTurn), sizeDegrees, brightness, blinks, blinkRate|null, focus} (on the sky, in degrees and ratios, never a real
                                      size or speed), label (unexplained | plane | probablePlane | satellite | satelliteFlare | meteor | bug | bird),
                                      display (what the log shows: a person's correction wins, "notSure" shows label), by|null (flight | orbit | rule |
                                      model | ai | person), detail|null ("TEST123 · 35,000 ft"), unusual[] (faster | larger | brighter | suddenStop |
                                      sharpTurn), speedVsPlanes|null (a ratio), candidate, alerted, hasStill, ai|null {kind, sentence, model, at},
                                      correction|null (plane | bird | bug | satellite | meteor | notSure), watch (the recordings' moment to open: start
                                      minus 3 s)}. conditions[]: {from, to, state (clear | cloudy | notVisible | unknown), cloudCover|null}. counts:
                                      {unexplained, planes, satellites, meteors, bugsAndBirds, notSure, explained}, counted by what the log shows (a person's
                                      word wins; a light the box explained and the person was not sure of is notSure; explained = all but unexplained). aim:
                                      {quality (rough | good | precise), planes, stars, residualPixels|null, updated|null, lenses[{quality, planes, stars,
                                      residualPixels|null}], note|null}; learning: {ready, planes, satellites, planesNeeded, satellitesNeeded}. 400 with the
                                      field date or view; 404 for a camera the bridge does not have; 409 no_location ("Set where the box is first.") or
                                      no_folder ("Choose a recordings folder first: the sky log is kept with the recordings."); 503 archive_unavailable
                                      (Retry-After) while the recordings' drive is away, 504 drive_slow while it does not answer
GET    /api/v1/sky/cameras/{id}/entries/{eid}/still?night=yyyy-MM-dd    the picture kept with an entry: image/jpeg (private, one hour); 404 when it
                                      has none; 400 with the field night
POST   /api/v1/sky/cameras/{id}/entries/{eid}/correction   {night, label}: "That was a…", label plane | bird | bug | satellite | meteor | notSure -> the entry
                                      (as in the log); the last word of an entry wins; 400 with the field label or night; 404 for an entry the night's log
                                      does not hold
POST   /api/v1/sky/feeds/find         "Find a feed": the flight feeds (dump1090, readsb, tar1090, PiAware) on the box's own network, one address per host
                                      -> {feeds: [url]}; it asks only the hosts in the box's neighbour table, a few places each, for at most 20 s
POST   /api/v1/bridge/pause | resume
GET    /api/v1/logs?since=&limit=&level=   {lines: [{date, level, category, message, cameraID}]}; with Accept: text/event-stream, `event: log` lines live
GET    /api/v1/diagnostics            the text bundle the Mac app exports (attachment)
GET    /api/v1/events                 server-sent events: bridge, camera, removed, motion, doorbell, notices (the current state first)
GET    /api/v1/system                 {product, version, build, mode (installed | development), osName, hostname, hardware, architecture, can*, canManage,
                                      sshEnabled?, automaticUpdates?, update?, install?}
POST   /api/v1/system/update          {action: "check" | "apply"}: check answers when the answer is in (at most 60 s); apply answers at once with state "downloading",
                                      then GET /system follows update.state (downloading -> ready, or error)
POST   /api/v1/system/reboot | poweroff   {confirm: true} -> 202
GET    /api/v1/system/disks           {disks: [{id, name, model, sizeBytes, note, eligible, problems[], phrase}]}: the installer's own list, usable or not
GET    /api/v1/system/recording-drives  {state: internal|mounted|missing|working|failed, message, drives: [{id, name, model, sizeBytes, note, eligible, problems[], phrase, isRecordingDrive, inUse}]}: the attached disks that could take recordings, and where recordings go now
POST   /api/v1/system/recording-drive   {targetID, phrase?, keepData?}: phrase is "ERASE ALL DATA ON <disk name>" (erases and makes an ext4 file system labelled CBRECORDINGS); keepData: use a disk that already is a Camera Bridge recording drive as it is; -> 202
POST   /api/v1/system/recording-drive/forget  {confirm: true}: back to the box's own disk, the drive left alone; -> 202
GET    /api/v1/nvr/cameras/:id/clip-plan?from=ms&to=ms&tz=Zone  {camera, cameraName, parts: [{index, start, end, leadInMs, bytes, samples, fileName}], gaps: [{from, to, held}], soundOmitted, bytes, durationMs}: what a clip of that camera in that range would be, from the recordings' headers only
GET    /api/v1/nvr/cameras/:id/clip?from=ms&to=ms&tz=Zone&part=1   one MP4 (chunked, `attachment`): the clip's part as planned, exactly `bytes` long, the video copied untouched
       &labels=1 and/or &straighten=1   the part re-encoded by ffmpeg and streamed as fragmented MP4 (its size not known in advance): with the camera's label burned in, and straightened by the camera's picture correction (straighten=1 is ignored while the correction is off: the copy above)
POST   /api/v1/import/mac-backup/preview  {file: <the Mac app's .camerabridge-backup JSON>} -> {cameras: [{id, name, vendor, host, username, record, enabled, alreadySetUp}], unreadable, appVersion, exportedAt}
POST   /api/v1/import/mac-backup          {file, passwords: {<camera id>: <password>}} -> {added[], addedOff[], alreadySetUp[], failed: [{name, message}], recordingPlaceChosen}: cameras keep their id, get a port of this box, are on only with a password; Record on with no place chosen yet picks the box's own storage
GET    /api/v1/system/wifi           {state, message, ssid, hotspot, saved[], lastError, hasWifi, wired, networks[]}: how the box is on the network
POST   /api/v1/system/wifi/scan      {} -> {networks: [{ssid, signal, security}]}: networks in range, strongest first
POST   /api/v1/system/wifi           {ssid, password}: save the network and restart to join it; -> 202
POST   /api/v1/system/wifi/forget    {ssid}; -> 204
GET    /api/v1/setup/wifi            (no session; only while the setup hotspot is open, else 409) {hotspot, networks, saved, lastError, needsAdminPassword, bridgeName}
POST   /api/v1/setup/wifi            (no session; only while the hotspot is open) {ssid, password, adminPassword?}: adminPassword is required once the bridge has one; -> 202, the box restarts
                                     While the hotspot is open, a request to any unknown host name is answered 302 -> http://10.42.0.1/setup.html (captive portal).
POST   /api/v1/system/install         {targetID, phrase, copyData?}: phrase is "ERASE ALL DATA ON <disk name>", typed by the person; -> 202, progress in GET /system install
POST   /api/v1/system/ssh             {enabled, authorizedKeys?}: key login for root, plain public keys only (up to 20) -> the system
POST   /api/v1/system/auto-update     {enabled} -> the system
POST   /api/v1/system/factory-reset   {confirm: "RESET"} -> 202 (erases settings and pairings, restarts)
```

Changes to the first draft of this contract: `POST /probe` and `POST /cameras` take the wizard's inputs by camera type (`GET /camera-types` says which); `/auth/setup | login | logout | password` are separate routes; `/health`, `/session`, `/camera-types`, `/bridge/pause|resume`, `/sensors-bridge`, `/integrations/*` and `/system/disks` were added; `/system/update` takes an `action`; `reset-pairing` and `test-motion` are per camera.

### The system helper

`camerabridged` runs as an unprivileged user and never starts anything privileged. The image offers a privilege-separated, asynchronous protocol (the contract is `linux/os/README.md`): the daemon writes one small JSON file per request into `CAMERABRIDGE_OS_REQUEST_DIR` (`/run/camera-bridge/requests`), named `<name>.json` with `<name>` one of `update-check`, `update-apply`, `auto-update`, `ssh-enable`, `ssh-disable`, `reboot`, `poweroff`, `factory-reset`, `install-list`, `install-to-disk`, `drive-list`, `drive-use`, `drive-forget`, `wifi-scan`, `wifi-join`, `wifi-forget`, `guard-set`. A systemd path unit wakes a root helper (`cb-system process-requests`) that checks the name and the JSON again, deletes the file and runs the job. The helper publishes how it goes as JSON files in `CAMERABRIDGE_OS_STATUS_DIR` (`/run/camera-bridge/status`): `<name>.json` (`state` queued, running, ok or failed; `message`; `updatedAt`), `update.json`, `install-candidates.json`, `install-to-disk.json` (`state`, `step`, `device`), `system.json` (`version`, `sshEnabled`, `autoUpdate`), `guard.json` (the internet guard, below) and `health.json`.

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
              [--recordings-dir DIR] [--log-level info] [--hap-base-port N] [--sensors-port N] [--dev] [--preview [scenario]] [--fake-discovery]
              [--no-demo-camera]
```

Every flag has a variable; a flag wins. The image's unit sets `CAMERABRIDGE_DATA_DIR`, `CAMERABRIDGE_WEB_ROOT`, `CAMERABRIDGE_HTTP_PORT`, `CAMERABRIDGE_RUN_DIR`, `CAMERABRIDGE_OS_REQUEST_DIR` and `CAMERABRIDGE_OS_STATUS_DIR` (the request and status folders default to `requests` and `status` in the run folder); `CAMERABRIDGE_RECORDINGS_DIR` (or `--recordings-dir`) is optional and not set by the unit; the older `CAMERA_BRIDGE_*` spellings (`_DATA_DIR`, `_PORT`, `_STATIC_DIR`, `_LOOPBACK_ONLY`, `_ALLOWED_HOSTS`, `_SETUP_TOKEN`, `_LOG_LEVEL`) still work, and the `CAMERABRIDGE_*` name wins when both are set. It logs to standard output (journald priorities when under systemd; the engine's diagnostics log in `<data>/Diagnostics` as always), sends `READY=1` once the web interface listens, `WATCHDOG=1` every WatchdogSec/3 (10 s for the image's `WatchdogSec=30`) while the engine runs and the interface listens (use `Type=notify`, `WatchdogSec=`), and shuts down on SIGTERM or SIGINT: web interface first, then the engine, within 10 seconds. `GET /api/v1/status` needs no sign-in (the image's boot health check uses it). `--setup-token-file` makes first-run setup ask for a code the image prints on the console, so nobody else on the network can claim a new bridge.

### Recordings (the NVR)

The recorder, the catalog and the retention rules live in the engine (`BridgeEngine/NVR`) and are the same on the Mac and on the box; the daemon supplies what only the host knows. The folder is `recordings` inside the data directory (`/var/lib/camera-bridge/recordings`, which is `/srv/camera-bridge/recordings` on the data partition) unless `--recordings-dir` names a full path. The daemon makes the folder as the unprivileged user (0700) before the engine starts; inside the data directory it makes missing levels, anywhere else only the folder itself and only when its parent exists, so an unplugged drive cannot be re-invented on the system disk. The recorder never makes the folder or a parent of it. The web interface offers that one folder as the location `builtin` (the browser sends the id, never a path). Free space comes from `statvfs` (`f_bavail`); the data directory's device (`st_dev`) is the system volume, which keeps `max(8 GiB, 5% of the partition)` free (recording pauses below it and resumes 1 GiB above it) because settings, HomeKit keys, the journal and `cb-update`'s 4 GB share that partition; a folder on another device keeps 2 GiB. Camera folders are named by the camera's UUID, `camera.json` inside carries the name. Starting never waits for the archive: the store repairs unclosed files and loads its catalog in the background, and `READY=1` does not depend on it (`TimeoutStartSec=120`; three unblessed boots roll the OS back). The hardened unit lets the daemon write only inside `/var/lib/camera-bridge`, so a recordings folder anywhere else needs the unit changed; that comes with external drives. `--preview` has no recordings and no archive.

### Recordings in the browser

Recorded video reaches the page as small pieces, and the browser's own video decoder does the decoding; the box decodes nothing. The box serves plain HTTP, and the browser features for decoding in script (WebCodecs) exist only on secure pages, so the page uses Media Source Extensions, which work on any page. `linux/web/README.md` lists the modules.

- **Pieces.** The recorder cuts every file into fragments of at most 2.5 s: at every keyframe, or 2.5 s into a long group of pictures. `GET /nvr/cameras/{id}/fragments?at=ms` returns the plan for a moment: the fragment that holds it, the key fragment its group of pictures starts in, and the next few, each with an opaque id (`<12 hex digits>.<index>`, stable across restarts), its times and size, and per file the codec string (`mime`), the picture size, the file's `anchor` time and which fragment's `/init` to fetch. The page appends the init segment and the pieces to one MediaSource per tile. The box serves video only: `ArchiveMedia` (in `BridgeEngine/NVR`, because `BridgeWeb` may not import `FMP4`) drops the `prft` box and, for a file with sound, the audio track.
- **Dragging** the timeline: where the browser's row of `POLICY_TABLE` (`js/nvr/planner.js`) has key steps on (at present Chrome on a Mac, the only class the browser spike ran on a device), the page fetches `GET /nvr/cameras/{id}/keyframe?at=ms`, the whole key fragment of the moment's group of pictures, and shows its first picture; in every other browser the picture arrives only after the pointer pauses. About 80 ms after the pointer stops, the page fetches the pieces from there to the moment and shows the exact frame. Releasing plays: `fragments?after=<id>` keeps the buffer a few seconds ahead.
- **Time.** Every time on the wire is Unix epoch milliseconds from the box's clock. The page measures its offset from `serverTime` in `GET /nvr/cameras` (polled every second while a recordings screen is open) and uses it for every "now". A file's media time maps to epoch time through its `anchor`; the page adds a fixed base so that buffer times stay positive.
- **Live** is the recorded edge, played 6 s behind the box's time. With Record off or paused the page falls back to the snapshot preview (`GET /cameras/{id}/snapshot`, a new picture every 5 s).
- **Banners.** The `notices` event (and `GET /status`) carries one more notice while Record is on for a camera: id `nvr-storage`, "Recording Can’t Continue" with the reason and an `action` (`choose-folder` or `open-settings`), or "Recording Storage Almost Full" when less than 5 GiB remains above the floor. Older pages ignore the new `action` field.
- **When the recordings are out of reach.** A read answers `410 gone` when the piece is no longer there (retention took it, or its drive is away), `504 drive_slow` (with `Retry-After: 2`) when the disk did not answer within 5 s, and `502 unreadable` when the piece cannot be read (a damaged piece, or a file that was open when its volume vanished). The page asks the status which it is: a 504 always means the drive, and a 410 or a 502 means the drive while the camera's `status.nvr.pause` is `folderMissing`. The tile then keeps its last picture, stops the clock, says "The recordings drive isn’t connected." and looks again every 5 s with one small read; when the box answers, playback starts again from the same place. Without that pause, a 410 makes the page ask for a new plan once (retention changed the catalog), and a 410 or a 502 after that is shown as a part that cannot be read.
- **Events.** The engine keeps every camera's events beside the recordings, whether or not its video is recorded: `<recordings>/.events/<CAMERA-UUID>/<yyyy-MM-dd>.jsonl` (one file per camera per UTC day of the events' starts, 0600 in folders of 0700; the dot keeps it out of the catalog). Each line is one JSON object: an event began (`{"camera", "id", "kind", "start", "v": 1, "video"}`, `video`: the camera's recorder was writing), ended (`{"end", "id", "v": 1}`, in the same file) or was described by an AI service (`{"ai": {"summary", "kind", "concern", "model", "at"}, "id", "v": 1}`, `at` in milliseconds like every time here; written to the day file of the event's start whenever the answer comes, so retention takes both together; the last one of an id wins, one of an id the file does not hold is ignored, a line over 2 KiB is not written or read, and a build that does not know `ai` skips the line as neither a start nor an end). The router's rising and falling edges write them (the names `status.recentEvents` uses: Motion, Person, Vehicle, Animal, Package, Face, Doorbell ring, Tamper, Alarm input …, Sound; a ring ends as it begins); a line that does not parse (a torn last line after a power cut) is skipped and the next append starts on a new line, and an event the bridge stopped during has no end. Retention deletes whole day files by the recordings' rules: days that ended before the keep time, and days before the newest file the size rule deleted; a new place for recordings starts a new log there. Nothing is kept while no place for recordings is chosen. `GET /nvr/events` reads them (`recorded`: the recordings hold video at the event's start now, or the recorder was writing it less than 2 minutes ago). One publication of the router stamps all its edges alike (a ring with its motion, a motion with its person), so a page never splits a millisecond: asked again with `to` = the oldest start, the next page finds that moment whole. Only a bridge with no place for recordings answers no events without looking; while the recordings load or their folder is missing the route answers `503 archive_unavailable` with `Retry-After`, and the page tries again instead of taking the range for empty. `.events` and the camera folders are never written, read or pruned through a link. The Monitor's events list asks for the timeline's range, newest first a page of 200 at a time (older pages when the range grows or on "Show older events"; the newest part again every 30 s while it follows live, and when more than a page began there, the rest of it at once, so a burst leaves no hole), merged with the live events and `status.recentEvents`; a row the archive says is not recorded is dimmed.
- **The Sky Watcher's log.** Beside the events, `<recordings>/.sky/<CAMERA-UUID>/<yyyy-MM-dd>.jsonl` (one file per camera per night, 0600 in folders of 0700; the dot keeps it out of the catalog), appended one JSON object per line, keys sorted, times in milliseconds: a light (`{"entry": {…}, "v": 1}`), a person's word on it (`{"correction": {"at", "label"}, "id", "v": 1}`), the AI's answer (`{"ai": {"at", "kind", "model", "sentence"}, "id", "v": 1}`), an alert (`{"alerted": true, "id", "v": 1}`) and how the sky was (`{"conditions": {"cloudCover", "from", "state", "to"}, "v": 1}`). A night is named by the local date of its sunset and a day by its own date; an entry is filed by its time, so a night is one file across midnight, and one file holds a day and the night that follows it (the log named D reaches from the sunrise of D to the sunrise of D+1). The first entry line of an id wins and the lines after it apply to it (the last correction and the last answer win; one for an id the file does not hold is ignored); a line that does not parse is skipped. The picture of an entry is `<yyyy-MM-dd>/<id>.jpg` in the camera's folder (at most 2 MiB). Writes run on a queue of their own and never wait for a drive (what cannot be written waits, at most 1000 lines and 16 MiB of pictures); `.sky`, a camera's folder, a night's file and its folder of pictures are never written, read or pruned through a link. Retention deletes a night with its pictures when its date and the day after it are over by the events' cutoff. Nothing is kept while no place for recordings is chosen. Where the box is is in none of it.
- **Limits.** The archive routes (`fragments`, `keyframe`, `activity`, `events`) allow 8 requests in flight in all and 6 per peer address (`maximumArchiveReads`, `maximumArchiveReadsPerAddress`); the next gets `429 busy` with `Retry-After: 1` at once, and `503 archive_unavailable` while the store loads (the daemon does not wait for it to start). An answer is at most 16 MiB. The page keeps to 3 byte fetches and 1 JSON request at a time and does not abort one to cancel it, because a buffered answer cannot be cancelled on the box; it gives up on a request only when the screen is left or after 8 s without an answer.
- **Security.** Every NVR route needs the session cookie; GET needs no CSRF token, PATCH and POST need the usual one. The browser sends ids and times, never a path. Footage is `Cache-Control: no-store`, HEAD on a media route is 405, and the Content-Security-Policy gains exactly `media-src 'self' blob:`. No credential, path or camera address appears in an answer, a log line or a URL.

## Security

- The web interface is for the local network only; the box never opens a port to the internet. Only IP addresses, `localhost`, `*.local`, `*.home.arpa`, names without a dot and `--allowed-host` names are served (DNS rebinding).
- First boot: no admin yet. The UI asks you to set a password on first visit (and the setup code, when the image has one). Until then the API offers only `/status`, `/session`, `/health` and `/auth/setup`.
- Passwords: PBKDF2-HMAC-SHA256, 600,000 rounds, 16-byte salt per password (swift-crypto), 8 to 256 bytes. Wrong guesses: 5 free per address, then a 15 s lockout that doubles up to 15 min; 60 failures from anywhere slow everyone for a minute. Comparisons are constant time.
- Sessions are random 256-bit tokens in `HttpOnly; SameSite=Strict` cookies, kept server-side only as SHA-256 hashes (`<data>/web/auth.json`, 0600), 7 days idle, 30 days at most, signed out by a password change. Changing requests need a matching `Origin`, the session's HMAC-derived `X-CSRF-Token` and a JSON content type.
- Strict headers: a Content-Security-Policy that allows only the bridge's own files (no inline script or style; `media-src 'self' blob:` lets the page play video it assembled itself), `nosniff`, no referrer, no framing, same-origin resource and opener policies.
- Camera passwords, cloud sources, HomeKit keys and the AI service's key (`ai.key`) are in the encrypted secret store; none appears in an answer, the log, the diagnostics or the web interface's files. The AI key is write-only: `PUT /api/v1/ai/key` stores it, `DELETE` removes it, and the settings answer carries only whether one is saved and its last four characters (none for a key under eight). It belongs to one service: the settings update that changes the service, or the scheme, host or port of an OpenAI-compatible address, deletes it first, so a key is never sent to another service.
- `nftables` default-deny inbound except 80 (UI), 443 (open for the later HTTPS option; nothing listens there yet), the HAP ports (21100–21199), mDNS, SSH only if enabled, and DNS only from the setup hotspot and the cameras the internet guard watches.
- Where the box is (`sky.location`, for the Sky Watcher) stays on the box: it is in `config.json` and in `GET /settings` for a signed-in page, and nowhere else. No log line, diagnostics report, notification, AI request or export holds it, `SkyLocation` prints as "location hidden", and no sentence of an error repeats what was typed.
- No telemetry. The only outbound calls are to the cameras, Apple's push relay (through the HomeKit hub), GitHub for update checks, go2rtc's cloud sources if you add Ring or Nest, and the AI service you choose, only for cameras with AI descriptions on, and only still pictures.
- **AI descriptions** are the one call that sends pictures from your cameras to a cloud service, and they are off until the owner chooses a service in Settings, saves its key (if the service needs one) and switches AI descriptions on for a camera (`CameraConfiguration.aiDescriptions`, off by default). The daemon makes the call, never the web page (the Content-Security-Policy still allows only the box's own files). For each event on such a camera it sends one HTTPS request (an `http://` address is allowed for a model on the home network; then the key, if any, and the pictures travel unencrypted) to Claude (`https://api.anthropic.com/v1/messages`) or to `<address>/chat/completions` of an OpenAI-compatible service the owner typed (OpenAI, OpenRouter, Ollama, LM Studio …; one at home keeps the pictures on the home network). It carries at most 5 JPEGs, each at most 768 px wide, gathered when the event starts (up to 2 keyframes before, the camera's own event picture or the event's frames, up to 2 keyframes after, at most 6 s later), the camera's name, the kind of event and the local time; no video, no sound. Nothing is sent for a camera whose switch is off; the one exception is Try it (`POST /api/v1/ai/try`), which the owner presses for a camera chosen in Settings, works with the switch off and sends that camera's pictures at that moment. Limits: events are described one at a time (one event's pictures are made and sent before the next event's; Try it runs beside them, one Try it at a time); at most one per camera per 60 s, counted from the last event picked; a set that waited more than 60 s is dropped; at most `dailyLimit` a day (200 by default, 1 to 5000), counted in `<data>/ai/usage.json` so a restart keeps the count; the HTTPS request times out after 20 s and a network error or a 5xx is tried once more. The camera's switch and the service are read again right before each send, the first and the retry: an event whose switch went off, or whose settings, service or key changed (or Off was chosen), while its pictures were made or the retry waited, is dropped unsent (and, before its first send, uncounted). The AI HTTP client never follows a redirect (`AuthenticatingHTTPClient(followsRedirects: false)`, the camera clients keep theirs): the key and the pictures go only to the saved address, and a 3xx is the answer "The service tried to send the request elsewhere; check the address." Other statuses have their own plain sentences too: 400 "The service refused the request; check the model name.", Claude's `stop_reason` "refusal" "The service declined to describe these pictures.", and a 401 from an OpenAI-compatible service with no key saved "The service needs a key." (which pauses nothing; a refused key, "The key was refused.", pauses). A summary is cut to its first line, stripped of control and format characters (bidi overrides, zero-width marks; the joiner inside an emoji stays) and capped at 140 characters and 600 UTF-8 bytes at a word; every change to the AI settings starts a new generation of the describer (the last error is forgotten, a pause may end, and nothing under way is sent on to what replaced it). The camera page's Security card says "Its event pictures go to <service> for AI descriptions." while the camera's switch is on and the service is Claude or an OpenAI-compatible address that is not on the home network (a private, loopback or link-local IPv4 address, or a `.local` or `.lan` name); no badge or level changes. The pictures are not kept. The answer, a sentence with a kind and a concern, is stored in the event log (see Events) and shown on the Monitor's events list and the camera page. A refused key pauses descriptions until the key or the service changes or Try it works; viewing, recording, Apple Home and the guard never wait for the service.

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

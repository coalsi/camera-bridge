# PlatformApple

macOS implementations of the platform protocols (BridgeSupport) and codecs (MediaCore); the ONLY module allowed to
import Apple-only frameworks: Network, dnssd (`dns_sd.h`), Security, IOKit, CoreMedia, CoreVideo, VideoToolbox,
AudioToolbox, Accelerate (vDSP, `grayThumbnail`, the timestamp overlay's blur), CoreImage, CoreGraphics and CoreText (the timestamp overlay), ImageIO. Every source file is wrapped in `#if os(macOS)`
so a Linux build compiles it empty. Depends on BridgeSupport and MediaCore. Owners: Wave 0.5 (network, Bonjour,
keychain, power, format descriptions); W1-2 (`Codecs/**`).

## Public entry points

- `AppleNetworkTransport` — `NWListener`/`NWConnection` TCP (`TCP_NODELAY`). `loopbackOnly` binds 127.0.0.1.
  Internal helper: `Network/ListenerPortProbe.swift` (port-conflict probe before a fixed-port listen).
- `DNSSDServiceAdvertiser` (`init()` = all interfaces, `init(scope: .localOnly)` for tests), `DNSSDAdvertisedService`.
- `KeychainSecretStore(service:)` + `KeychainError` (`LocalizedError`: a readable sentence for the app's alerts); `NWPathNetworkChangeMonitor` (+ `cancel()`); `ApplePowerManager`
  (+ `endBackgroundActivity()`, `isBackgroundActivityActive`, `isKeepingSystemAwake`); `ApplePlatform.services()`.
- `VideoFormat.makeFormatDescription()` (avcC / hvcC), `AudioFormat.makeFormatDescription()` (AAC/AAC-ELD with
  ES_Descriptor cookie, Opus, PCMU/PCMA, LPCM). `AppleMediaCodecs`, `PixelBufferFrame` (`grayThumbnail`).
  Internal: `AppleVideoDecoder`, `AppleVideoEncoder` (H.264; HEVC for tests), `AppleVideoTranscoder`
  (`FrameRateLimiter`, `PresentationOrder`), `AppleAudioTranscoder`/`AudioConverterStream`, `JPEGSnapshot`, `SilentAudio`,
  `SyntheticMediaSource`/`TestPattern`.

## Additions beyond the contract

`Display/LiveSampleBuilders.swift` (2026-10-02, docs/CONTRACT_CHANGES.md): `LiveVideoSampleBuilder` turns H.264 / HEVC access units into ready
CoreMedia sample buffers marked "display immediately" for the app's `AVSampleBufferDisplayLayer` (it keeps the format description of the stream,
makes a new one when a keyframe brings another format; SEI NAL units left out), `LiveAudioSampleBuilder` does the same for AAC / AAC-ELD / Opus /
G.711 / LPCM access units at a presentation time of the renderer's own timeline. One builder per consumer (not thread-safe).

`TimestampOverlayPreview` (2026-10-02, docs/CONTRACT_CHANGES.md): the timestamp overlay on a still picture
(`render(image:overlay:at:outputHeight:allowUpscaling:locale:timeZone:)`, `render(image:overlay:at:width:height:locale:timeZone:)`,
`render(imageData:overlay:at:outputHeight:allowUpscaling:locale:timeZone:)`, `png(_:)`), drawn by the same renderer and
compositor the video encoder uses, so the app's preview is the output. `AppleMediaCodecs.makeVideoTranscoder(output:overlay:)`
draws the overlay on every picture it encodes (internal: `TimestampOverlayRenderer`, `TimestampOverlayCompositor`,
`OverlayBitmap`; `AppleVideoEncoder`/`AppleVideoTranscoder` take an optional overlay provider).

`DNSSDServiceAdvertiser.Scope`/`init(scope:)`/`scope`, `DNSSDAdvertisedService` (`registeredName`),
`KeychainSecretStore.service`, `KeychainError`, `NWPathNetworkChangeMonitor.cancel()`,
`ApplePowerManager.endBackgroundActivity()`/`isBackgroundActivityActive`/`isKeepingSystemAwake`, `PixelBufferFrame.init`.
Hardening plan WS-C (2026-10-03): `AppleNetworkTransport` listeners accept connections with TCP keepalive (idle 30 s, interval 10 s,
3 probes) and a 20 s connection drop time; outbound connections keep the system defaults. `NetworkPathSignature` ignores
`utun*`/`awdl*`/`llw*`/`anpi*`/`bridge*`/`lo*` interfaces and gateways off the `en*` networks and includes the stable addresses of
the `en*` interfaces (`InterfaceAddresses`: IPv4, and IPv6 that is neither link-local, temporary nor deprecated), so VPN or AirDrop
churn is no network change and a renewed lease or a new IPv6 prefix is exactly one. `AppleServiceBrowser` (`ServiceBrowsing` over
`NWBrowser` with TXT records: the HAP health monitor's Bonjour check), `AppleInstanceLock` (`InstanceLocking`: an exclusive `flock` on
`instance.lock` in the data directory), `ApplePowerManager.hasBattery` (an internal battery among the IOPS power sources).

`AppleVideoEncoder` uses `VideoEncoderSettings.inputFrameRate` for `ExpectedFrameRate`, `MaxKeyFrameInterval` and the
frame duration; `fps` is the level fit and the transcoder's `FrameRateLimiter`.

## Invariants

- Timestamp overlay: the pill (black at 42 %, capsule), the optional camera name and date in regular weight and the time in
  semibold (SF Pro, tabular figures; white with a soft shadow) are rendered once per distinct text and output size at the
  output's own pixel size (never scaled, so the text is crisp), sized from the output height (`OverlaySize.fontHeightFraction`
  of it) and placed in the chosen corner at an inset of 0.45 pill heights. Each picture is copied first (the decoder's
  picture is shared with its reference frames), then the picture behind the pill is blurred (luma only, vImage box blur
  twice, masked by the pill's shape) and the overlay is blended into the NV12 planes (a few thousand pixels: about 5 ms per
  1080p picture in a Debug build). A picture that is not 8-bit NV12 video range, or too small, goes out without it.

- Transport: `connections` is single-consumer, buffers up to 64 ready connections (more are closed) and finishes when
  the listener closes or fails. Connections are delivered once `.ready`, with bare IP literals (no port/zone;
  IPv4-mapped IPv6 → IPv4); a link-local connection's zone is `TCPConnection.zone` (the peer's interface name, else
  ours; W4 review round 4: a link-local address a controller names is reachable only through it). `connect` throws
  `.connectionRefused` / `.localNetworkDenied` immediately, else waits until `timeout` (`.timedOut`). A connection
  Network.framework leaves in `.waiting(EADDRINUSE)` (its local port completes an existing 4-tuple, e.g. a loopback
  TIME_WAIT; a plain retry gets the same port) is replaced by one bound to the same local address with a kernel-chosen
  port, within the same `timeout`. After `close()` every call throws `.closed`; cancelling a task in `receive`/`connect`
  cancels the connection and throws `CancellationError`. `receive` returns nil after an orderly EOF (and later).
- Listener sockets use address reuse (fixed ports rebind after restart). Because reuse lets a wildcard and a
  specific-address socket share a port, a fixed port is first probed (`SO_REUSEADDR` bind, never listened on) at
  every served address — loopback first, then wildcards and interface addresses (`loopbackOnly`: 127.0.0.1 and
  0.0.0.0) — and any holder → `.addressInUse`. Tests check the every-interface listener's parameters without starting it
  (`AppleTCPListener.makeListener`); `CB_WILDCARD_TESTS=1` also starts one and connects from 127.0.0.1 and ::1
  (`EveryInterfaceListenerTests`).
- DNS-SD: `DNSServiceRef` and callbacks confined to one serial queue. `advertise` waits ≤ 5 s for the first answer;
  an error there is thrown (`-65570` → `.localNetworkDenied`), later ones go to `failures`. TXT keys sorted,
  printable ASCII without `=`, each `key=value` ≤ 255 bytes. Dropping the service withdraws it. Keychain: file-based
  login keychain, generic passwords; deleting a missing item is not an error; its tests need `CB_KEYCHAIN_TESTS=1`.
  Tests register `_cbtest._tcp` LocalOnly only — never advertise on the LAN.
- Codecs: every object is thread-safe (`Mutex`); VideoToolbox/AudioToolbox run synchronously under it, and the
  async video entry points (`decode`, `encode`, `transcode`) run on the object's own serial queue
  (`CodecWorkQueue`), never on a cooperative thread. Decoder → NV12 IOSurface pictures, follows parameter-set
  changes, flushes when a keyframe yields nothing, recreates an invalidated session once; `decodeAllNow` returns every
  picture a call emitted, in decode order (`decode` the newest). Encoder: one output per input (same PTS, wall clock; dts nil, no
  reordering), IDR every keyframe interval, `AverageBitRate` + 1 s `DataRateLimits` 1.5×, profile mapped, H.264
  level = the lowest ≥ the requested one that fits frame size, macroblock rate and per-dimension limit (MediaCore's
  `H264LevelLimits`, Table A-1; `.auto`, > 5.2 or a
  refused level → AutoLevel, logged), letterbox-scales other sizes, duplicate / slightly earlier PTS encoded as is, a
  PTS > 1 s back → new session (IDR); access units exclude SPS/PPS/VPS/AUD; `updateBitrate` is lock-free (next
  picture). Transcoder skips delta frames until a keyframe (also after a parameter-set change or an undecodable delta
  frame, logged); keyframe decode and encoder errors throw; encodes pictures in presentation order
  (`PresentationOrder`: a stream that does not reorder is never held; a frame with dts ≠ pts holds ≥ 4 pictures, and
  reordering seen in the PTS deepens the hold up to 16; a picture presented before one already encoded is dropped,
  logged once; a keyframe or a PTS > 1 s back releases what is held); then decimates to the output fps
  (`FrameRateLimiter`); `requestKeyframe()` (lock-free) → the next output is an IDR, never decimated away.
- Audio: G.711/LPCM in Swift, AAC-LC (1024) / AAC-ELD (480) / Opus (20 ms) via a streaming AudioConverter; PTS
  contiguous on the output clock, shifted by input jumps > max(100 ms, 2 frames); encoder delay compensated (the
  ⌈leadingFrames / packet⌉ priming packets are dropped and the timeline starts at the first input PTS + the rest,
  AAC-LC + 960), re-primed after `flush()`; bit rates clamped into the encoder's applicable range; the Opus decoder
  takes variable packet durations (2.5–120 ms, codes 0–3); G.711/LPCM out in 20 ms chunks (the tail after `flush()`
  may be shorter). Silent AAC repeats one AU.
- JPEG: CoreImage Lanczos + JPEG; `resizeJPEG` via ImageIO thumbnails (unchanged when it fits); aspect kept, never
  upscaled. Synthetic source: real-time 420v pattern (bars, box, noise, counter) → H.264, keyframe first, optional
  440 Hz tone; `stop()` finishes the stream, and `samples()` ends the session it replaces (overlapping calls too).
  `grayThumbnail`: mean of every source pixel per block (8-bit luma via vDSP; 10-bit YCbCr; BT.601 from BGRA/ARGB),
  width ≤ `maxWidth`, aspect kept; nil for other formats or `maxWidth ≤ 0`.

## References

TN3179 (Local Network privacy), TN3137 (Mac keychains), `dns_sd.h`, ISO/IEC 14496-1 §7.2.6.5 (ES_Descriptor),
RFC 6716 §3.1 (Opus TOC), the networking and native-media research notes (not published).3–3.8.

## Additions beyond the contract: helper processes (2026-10-08)

`ProcessHelperLauncher` (`HelperLaunching`): finds helpers in `CAMERABRIDGE_HELPERS_DIR` (development), `Contents/Helpers` of the main bundle, then next to the
executable; starts them with `Process`, an environment of only `PATH`, `TMPDIR` and what the launch names, standard input closed, stdout and stderr merged
and delivered as lines; `terminate()` is SIGTERM and `kill()` SIGKILL; a launch with a pid file writes the process ID (0600) and
`endStaleProcess(pidFile:executable:)` ends a helper left behind by a crashed app, only when the process at that ID is still the same program.
`ApplePlatform.services()` includes it.

# MediaCore

Codec-level media model shared by ingest (RTSP/FLV), live streaming (RTP), recording (FMP4) and snapshots, the
portable codec protocols (`MediaCodecs` and friends; Apple implementation `PlatformApple.AppleMediaCodecs`), G.711 and
the per-camera `MediaHub`. Depends on BridgeSupport only (Foundation, Synchronization) — portability rule.

## Public entry points

- Model: `MediaTime`, `VideoCodec`/`AudioCodec`, `VideoFormat` (`h264(sps:pps:)`, `hevc(vps:sps:pps:)`), `AudioFormat`
  (`samplesPerFrame`, `aacLC`), `EncodedVideoFrame`/`EncodedAudioFrame`, `MediaSample`, `MediaSource`, `StreamInfo`,
  `NALUnits`, `H264SPS`, `HEVCSPS`, `GrayImage`.
- `MediaHub` (W1-2): `ingest`, `subscribe(from:bufferLimit:)`, formats, `lastKeyframe`, `measuredFrameRate`,
  `measuredGOPDuration`, `discontinuity()`, `subscriberCount`.
- Codec protocols: `DecodedVideoFrame`, `VideoDecoding`, `VideoEncoding`, `VideoTranscoding`, `AudioTranscoding`,
  `MediaCodecs` (+ `jpeg(fromKeyframe:)`), settings, `MediaCodecError`. `makeFormatDescription()` is in PlatformApple.
- `G711` (W1-2): µ-law / A-law encode/decode, pure Swift.

## Additions beyond the contract

Snapshot decoders (2026-10-02, docs/CONTRACT_CHANGES.md): `MediaCodecs.makeSnapshotDecoder(format:)` (a protocol requirement with
a default that returns `makeVideoDecoder(format:)`; the Apple implementation logs its routine session creation at debug level, not info).

Live pipeline hardening (2026-10-03, docs/CONTRACT_CHANGES.md): `MediaCodecs.makeProbeDecoder(format:)` (a requirement with a default that
returns `makeVideoDecoder(format:)`; the live self-check's low-priority decoder), `TranscoderDiagnostics` with `VideoTranscoding.diagnostics`
and `VideoTranscoding.preferSoftwareDecoding()` (defaults: nothing known, nothing done), `PictureStatistics` with
`DecodedVideoFrame.pictureStatistics()` (default nil), `GOPQueue` (a bounded queue that drops whole GOPs), `MediaHub.newestGOP()` and
`MediaHub.lastVideoArrival`.

Timestamp overlay (2026-10-02, docs/CONTRACT_CHANGES.md): `OverlayPosition`, `OverlaySize`, `TimestampOverlaySettings`
(Codable; every key defaults when missing or unreadable), `TimestampOverlayText` (the words: `make(at:settings:cameraName:locale:timeZone:)`,
`uses24Hour(locale:)`, `systemUses24Hour`), `OverlayClock` with `PictureWallClock`, `FixedOverlayClock` and `OffsetOverlayClock`,
`TimestampOverlay`, `TimestampOverlayProviding` and `StaticTimestampOverlay`; `MediaCodecs.makeVideoTranscoder(output:overlay:)`
(a protocol requirement with a default that ignores the overlay); `MediaHub.wallClockOffset` (the Mac's clock minus a source's
`wallClock`: the smallest recent arrival lag of its video frames).

`VideoEncoderSettings.expectedFrameRate` (+ `init` parameter, default nil) and `inputFrameRate` (review W4 round 3: the
input's expected rate is a rate-control hint; `fps` stays the output's limit, so a rate measured low drops nothing).
`MediaSubscription.replayCount` (how many of a `.prebuffer` subscription's first samples are the replayed GOP; `init` parameter, default 0) and `VideoTranscoding.catchUp(_:)` (decode a GOP, encode only its newest picture as a keyframe; a protocol requirement with a default extension that transcodes every frame), so a live view starts from "now" instead of the camera's next keyframe. `H264SPS.init`, `HEVCSPS.init`, `MediaSubscription.init`, internal `MediaHub.init(retention:now:)` (injectable
monotonic clock for tests). `MediaHub.lastKeyframeArrival` (review W4 round 2): `lastKeyframe` with when it arrived on
the hub's monotonic clock, so a consumer can tell its age without the frame's `wallClock` (for RTSP the camera's clock,
which may run seconds off the Mac's); cleared by `discontinuity()`.

Package-visible bitstream helpers (not public API; the package's only copies — FMP4, RTSP, RTP, BridgeEngine and
PlatformApple use these instead of their own, and `PortabilityTests`' `ScaffoldingTests` rejects a bit reader, the
MSB-first bit extraction or the sampling-frequency table outside MediaCore): `BitReader` (MSB first, reads up to 64
bits, Exp-Golomb, `position`), `NALUnits.h264SliceType` (slice_type of an H.264 slice header, for BridgeEngine's
B-frame detection), `AudioSpecificConfig` (object type with the 31 escape, frequency index or explicit frequency in
1…1 000 000 Hz, channel configuration, `channels`; `encoded` is the one writer, AAC-LC and AAC-ELD, used by
`AudioFormat.aacLC` and RTP's return-audio config), `H264LevelLimits` (Table A-1 MaxFS / MaxMBPS plus the §A.3.1
per-dimension limit √(8 × MaxFS); `fits`, `lowestLevel`), `SampleAspectRatio` (Table E-1 / Extended_SAR) and
`VideoFormat.sampleAspectRatio`, and SPS fields: `H264SPS` chroma_format_idc, bit depths, VUI sample aspect ratio;
`HEVCSPS` sub-layers, temporal-id nesting, profile space, tier, compatibility and constraint flags, chroma_format_idc,
bit depths and VUI sample aspect ratio (what avcC/hvcC and `pasp` need).

## Invariants

- `MediaTime` equality/hash/ordering compare the represented time exactly (cross-timescale; negative timescale negates,
  zero timescale is time 0); `converted(to:)` rounds to nearest (128-bit); `+`/`-` return `lhs.timescale`;
  `seconds(_:timescale:)` never traps (NaN → 0, ±∞/out of range saturate).
- Video frames carry NAL units without start codes; parameter sets live in `VideoFormat.parameterSets` (H.264
  `[SPS, PPS]`, plus further PPS / SPS when the stream uses several: the primary SPS and PPS first, the rest by id —
  `H264ParameterSetStore`; HEVC `[VPS, SPS, PPS]`). `H264SPS`/`HEVCSPS.parse` never trap (fuzzed in `ParameterSetRobustnessTests`).
  A VUI that does not parse leaves the frame rate / sample aspect ratio nil. `HEVCSPS.parse` needs the SPS up to the
  conformance window; the fields after it (bit depths, VUI aspect ratio) are nil when they do not parse or when
  sps_max_sub_layers_minus1 is the reserved 7.
- `AudioFormat.samplesPerFrame`: AAC 1024, AAC-ELD 480, Opus 960, G.711/LPCM 0. `aacLC`: 2-byte config for table
  rates, 5 bytes (explicit frequency) otherwise, none for a rate 24 bits cannot carry (negative, 2²⁴ Hz and above).
- `MediaHub` time: ring trimming and `.prebuffer` use the hub's own monotonic clock (`ContinuousClock`), stamped when
  each keyframe (and the newest sample) arrives — never the samples' `wallClock`, which for RTSP is the camera's clock
  (RTCP sender reports within 3 s of arrival): a camera clock running behind used to shorten the prebuffer.
- `MediaHub` ring: whole GOPs (keyframe + later samples in arrival order); the oldest GOP is dropped once the next one
  arrived at or before newest arrival − `retention`, so ≥ `retention` is held and the ring starts on a keyframe;
  nothing before the first keyframe is kept; hard cap 64 MB (drops oldest GOPs, logs once).
- `subscribe`: `.live` = everything from now on; `.nextKeyframe` waits for a keyframe (earlier audio dropped);
  `.prebuffer(d)` replays from the newest GOP whose keyframe arrived at least d ago (else the oldest), then live
  (empty ring → like `.nextKeyframe`). Per-subscriber queue `bufferLimit` (`GOPQueue`): a full queue loses its oldest
  GOP (or all it holds when that is one GOP, then skipping deltas until a keyframe), so the sample a consumer reads after
  a gap is a keyframe, never a delta whose keyframe it lost; one warning per overflow incident (at most one per 10 s per
  subscriber). A `.prebuffer` subscriber's queue is `bufferLimit` + its replay's sample count, so a replay longer
  than `bufferLimit` still arrives whole from its keyframe. `cancel()` ends the stream after what is queued; a cancelled
  consumer task or a dropped stream removes the subscriber at once. `newestGOP()` is the video frames of the newest GOP
  (snapshots decode forward through them); `lastVideoArrival` is when the newest video frame arrived (health checks).
- `GOPQueue<Element>`: the bounded queue the hub, the in-app live-view pump and the live pipeline's session stream share
  (`push` → queued / dropped / awaiting a keyframe; `makeStream()`; `finish()` / `terminate()`).
- `PictureStatistics` (`DecodedVideoFrame.pictureStatistics()`, default nil): luma mean/deviation and chroma means on a coarse
  grid; `isBlack` / `isUninitialized` (all-zero, shows green) / `isDetailed`. `TranscoderDiagnostics`
  (`VideoTranscoding.diagnostics`): hardware or software decoder and encoder, a sampled input picture, the newest keyframe's
  size, the per-picture time. `VideoTranscoding.preferSoftwareDecoding()`, `MediaCodecs.makeProbeDecoder` (low priority).
- `discontinuity()` clears ring, `videoFormat`, `audioFormat`, `lastKeyframe` and measurements; keyframe-started
  subscribers wait for the next keyframe again; `.live` ones continue. The formats are the reconnected source's once
  it delivers that kind of sample: a source that comes back without audio leaves `audioFormat` nil, so a recording
  records silent AAC instead of declaring a camera audio track that never gets a sample.
- `measuredFrameRate`: last ≤ 90 video decode times (`dts ?? pts`: B-frame PTS step back); `measuredGOPDuration`:
  mean spacing of the last ≤ 4 keyframes (PTS); a time that does not increase restarts its window.
- `EncodedVideoFrame.pts` is the presentation time; with B-frames it steps back in decode order and `dts` (strictly
  increasing per source session) is set (CONTRACT_CHANGES 2026-09-30, MediaCore).
- `G711`: µ-law 14-bit (bias 33, clip ±32124, one's-complement magnitude for negatives as in G.191), A-law 13-bit
  (clip ±32256); decode→encode is the identity on codes (µ-law 0x7F → 0xFF); error ≤ half a step.
- `jpeg(fromKeyframe:)`: rejects delta frames, decodes with a fresh decoder (invalidated afterwards), quality 0.8.

## References

ITU-T G.711 / G.191, ITU-T H.264 §7.3.2.1.1 / §7.3.3 / Table 7-6 / §E.1.1 / Table A-1 / Table E-1, ITU-T H.265
§7.3.2.2 / §7.3.3 / §7.3.4 / §7.3.7 / §E.2.1, ISO/IEC 14496-15 (AVCC/HVCC), ISO/IEC 14496-3 §1.6.2.1 (AudioSpecificConfig), the native-media research notes (not published).8 (GOP ring). Tests:
portable fakes plus (macOS) `MediaHubLiveSourceTests` feeding the hub from `AppleMediaCodecs`' synthetic source.

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

Camera off still (2026-10-22, docs/CONTRACT_CHANGES.md): `MediaCodecs.cameraOffJPEG(cameraName:width:height:)` (a requirement with a default that throws
`MediaCodecError.unsupported`): the dark "Camera off" picture Apple Home gets for a camera that is turned off, exactly `width` × `height`, as JPEG.

The Sky Watcher's small pictures (2026-10-26, docs/CONTRACT_CHANGES.md): `MediaCodecs.croppedJPEG(_:crop:maxWidth:quality:)` (a requirement with a default that throws
`MediaCodecError.unsupported`, so a caller keeps the whole picture) and `ImageCrop` (`x`, `y`, `width`, `height`: a rectangle of a picture in its own pixels from the top
left). The part of a JPEG (or PNG) inside `crop`, or all of it when `crop` is nil, made at most `maxWidth` wide with its shape kept and never larger than the part itself,
as a JPEG at `quality` (0 to 1); a whole picture that already fits comes back unchanged. A crop that is not inside the picture, or data that is not an image, throws
`unsupported`. The ffmpeg codecs cut at the exact pixel (`crop=…:exact=1`) under `nice -n 10`; the Apple ones use ImageIO and CoreGraphics.

The sky detector's decoder (2026-10-25, docs/CONTRACT_CHANGES.md): `MediaCodecs.makeSkyDecoder(format:maxOutputWidth:keepEvery:)` (a requirement with a
default, `makeMotionDecoder`): a decoder for the sky detector, which looks at a luma picture at most `maxOutputWidth` wide a few times a second. It makes a
picture of every `keepEvery`th frame it is given (frames 0, N, 2N, … from the first, a keyframe) and answers nil at once for the others; a codec service that can
drops the others before they are copied back (the ffmpeg one does, on the GPU where the GPU takes the stream), scales with a good filter, never straightens the
picture and runs at low priority. The default makes a picture of every frame, so a caller keeps the rate itself. `VideoDecoding.decodingPlace` (a requirement
with a default, nil) and `DecodingPlace` (`gpu`, `software`) say where a decoder decodes, for a status line: the ffmpeg decoders say it, and say `software` after
the GPU failed on a stream.

Snapshot decoders (2026-10-02, docs/CONTRACT_CHANGES.md): `MediaCodecs.makeSnapshotDecoder(format:)` (a protocol requirement with
a default that returns `makeVideoDecoder(format:)`; the Apple implementation logs its routine session creation at debug level, not info).

Live pipeline hardening (2026-10-03, docs/CONTRACT_CHANGES.md): `MediaCodecs.makeProbeDecoder(format:)` (a requirement with a default that
returns `makeVideoDecoder(format:)`; the live self-check's low-priority decoder), `TranscoderDiagnostics` with `VideoTranscoding.diagnostics`
and `VideoTranscoding.preferSoftwareDecoding()` (defaults: nothing known, nothing done), `PictureStatistics` with
`DecodedVideoFrame.pictureStatistics()` (default nil), `GOPQueue` (a bounded queue that drops whole GOPs), `MediaHub.newestGOP()` and
`MediaHub.lastVideoArrival`.

Recording (NVR, 2026-10-10, docs/CONTRACT_CHANGES.md): `MediaHub.discontinuityCount` (how many times `discontinuity()` was called; readable from any thread, so a
recorder that sees it change knows the source reconnected).

AI descriptions (2026-10-18, docs/CONTRACT_CHANGES.md): `MediaHub.recentKeyframes()` (every keyframe the ring holds, oldest first, read without subscribing
or changing anything; the pictures from before an event come from it); `MediaCodecs.resizeJPEG(_:maxWidth:maxHeight:quality:)` (a requirement with a
default that ignores `quality`; the Apple and ffmpeg implementations encode at it, and an image that already fits still comes back unchanged).

Timestamp overlay (2026-10-02, docs/CONTRACT_CHANGES.md): `OverlayPosition`, `OverlaySize`, `TimestampOverlaySettings`
(Codable; every key defaults when missing or unreadable), `TimestampOverlayText` (the words: `make(at:settings:cameraName:locale:timeZone:)`,
`uses24Hour(locale:)`, `systemUses24Hour`), `OverlayClock` with `PictureWallClock`, `FixedOverlayClock` and `OffsetOverlayClock`,
`TimestampOverlay`, `TimestampOverlayProviding` and `StaticTimestampOverlay`; `MediaCodecs.makeVideoTranscoder(output:overlay:)`
(a protocol requirement with a default that ignores the overlay); `MediaHub.wallClockOffset` (the Mac's clock minus a source's
`wallClock`: the smallest recent arrival lag of its video frames).

Straighten the picture (2026-10-18, docs/superpowers/specs/2026-10-18-straighten-the-picture-design.md): `PictureCorrection` (Codable value:
`straighten` -0.60...0.60 and `level` -0.40...0.40, clamped and rounded to 0.01, both 0 = `.off`; decoding fills every missing or unreadable key
with 0), the one copy of the correction's formula in Swift (`horizon(across:)`, `landing`, `sourceFraction(across:down:)`, `largestStretch`;
resolution-free: columns and rows are fractions of the picture, pixel i's centre is (i + 0.5) / size), `PictureCorrectionProviding` and
`StaticPictureCorrection` (nil = off), `PictureCorrection.snapshotTimeout` (6 s: the longest `MediaCodecs.correctJPEG` may take; the engine
runs the call on a thread of its own and gives up on it a second later). The JavaScript copy and the ffmpeg maps are pinned to it by
`Tests/MediaCoreTests/Fixtures/picture-correction-vectors.json`, generated from the spec's formula by `Tools/picture-correction-vectors.py`.
The ffmpeg side (`PictureCorrection+Remap.swift`): `remapSupersample` (2), `remapMaps(width:height:)` (four 16-bit PGM maps for `remap`:
x and y for the luma plane of the picture made twice as tall, W × 2H; chroma x and chroma y for its two colour planes, W/2 × H, the
picture's width halved and its height as it is) and `ffmpegRemapChain(input:width:height:xMap:yMap:chromaXMap:chromaYMap:output:)` (warp each 4:2:0 plane as grey at twice
the height, merge, then shrink with `area`; ruling R6: half the CPU of a 4:4:4 warp on the box's N150 at the same quality);
`MediaCodecs.supportsPictureCorrection` (default false) and `MediaCodecs.makeVideoTranscoder(output:overlay:correction:)` (a requirement
with a default that ignores the correction and calls `makeVideoTranscoder(output:overlay:)`); `MediaCodecs.correctJPEG(_:correction:)`
(snapshots: the JPEG straightened at its own size; a requirement with a default that throws `MediaCodecError.unsupported`).

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

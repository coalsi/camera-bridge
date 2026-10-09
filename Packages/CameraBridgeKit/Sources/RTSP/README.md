# RTSP

Camera ingest: an RTSP/TCP-interleaved client with Digest/Basic auth, SDP parsing, H.264/H.265/AAC/G.711
depacketizers, the ONVIF audio backchannel, and the `RTSPMediaSource` / `HTTPFLVMediaSource` sources. Portable
(RTP, MediaCore, BridgeSupport only): RTSP reaches the network only through the injected `NetworkTransport`,
HTTP-FLV through `AuthenticatingHTTPClient.stream(for:)`. Owner: W1-5 (also `TestSupport/RTSPTestServer`).

## Entry points

- `RTSPClient(configuration:transport:)` — `connect()` (OPTIONS → DESCRIBE with 401 → Digest, Basic fallback (never
  once the camera asked for Digest: BridgeSupport's `BasicDowngradeGuard`, shared by an `RTSPMediaSource`'s sessions); a
  401 to credentials is returned, not retried, whatever fresh nonce it carries (RFC 2617 §3.2.1), so wrong credentials
  cost one authenticated attempt per connect — retried only for `stale=true`, a Basic → Digest switch, or once for a
  fresh nonce after the camera accepted the credentials →
  SETUP `RTP/AVP/TCP;unicast;interleaved=2n-(2n+1)` for video, first usable audio, backchannel; a refused audio or
  backchannel SETUP skips that track, a non-TCP transport answer is `.protocolError`) → `play()` (PLAY; keepalive
  `GET_PARAMETER`, or `OPTIONS` when unlisted or answered 400/405/451/454/501/551, every session timeout / 2) →
  `sendBackchannel(_:)` → `close()` (TEARDOWN; also sent when `connect()`/`play()` fails after SETUP created a
  session). Single-use (a second `play()` is rejected); errors: `RTSPError`, or `TransportError` from the transport.
  H.264 `packetization-mode=2` is `unsupportedCodec`. Camera text in errors (the rtpmap encoding name of
  `unsupportedCodec`, the transport of a non-TCP SETUP answer) goes through `Redact.cameraText`: at most 200
  characters, control characters replaced (W4 review round 4: a 4 MiB DESCRIBE body could carry a megabyte codec name).
- `RTSPMediaSource` — one fresh client per `samples()`; `HTTPFLVMediaSource` — FLV over HTTP.
- `SDPSession.parse(_:)`, `SDPMedia.rtpmap(for:)` / `fmtp(for:)`.

## Invariants

- Sample streams: video times in 90 kHz, audio `pts` in the sample rate, on one session timeline: the session's first
  unit is at 0 and each other track's first unit is placed relative to it by the camera's capture times when both
  tracks have a sender report that agrees with arrival within 3 s, else by arrival; both ends always come from one
  clock, so a camera clock offset never becomes an A/V offset. Audio `pts` and video decode times (`dts ?? pts`)
  increase strictly per track. Video
  `pts` are the camera's presentation times: with B-frames they step back in decode order, and `dts` (set when it
  differs) gives the decode time (`DecodeTimeline`: a non-keyframe step back of ≥ 8 ms from every recent time, ≤ 1 s
  and ≤ 16 frames deep is reordering; then dts = the (depth + 1)-th latest pts, kept increasing; a stream that never
  reorders has dts nil). RTP timestamps unwrapped to 64 bits; the smoothing runs on decode times and each frame keeps
  its offset from them: bursty delivery keeps source spacing, bogus jumps (> 0.5 s ahead of arrival and > 4× the
  typical step, e.g. Reolink after keyframes, or > 60 s ahead of arrival) and other non-increasing steps (jitter,
  repeats, a keyframe or > 1 s back) are re-timed. HTTP-FLV: pts = smoothed dts + composition offset. Timing arithmetic saturates and SDP
  clock rates outside 1…1 000 000 Hz are replaced (video 90 kHz, G.711 8 kHz) or make the audio track unusable, so
  hostile timestamps and rates never trap. `wallClock` comes from the RTCP sender report when it agrees with
  arrival within 3 s, else arrival; it never goes backwards. Output starts at a keyframe with known parameter sets;
  loss (sequence gap, broken FU/aggregation) drops access units until the next IDR/IRAP. A restarted RTP sender
  (sequence numbers > 100 behind, or a new SSRC with a discontinuity) resynchronises at once at its next keyframe;
  packets up to 100 behind are late duplicates. Access units over 16 MiB (audio 256 KiB) are dropped, so reassembly
  memory is bounded. In-band parameter sets update `format`; H.264 keeps every SPS and PPS sent, by id (`H264ParameterSetStore`), so pictures that refer to a second PPS decode (a decoder rejects a slice whose PPS its format lacks: VideoToolbox -12909); `[SPS, PPS]` for a stream with one of each. The SDP's `sprop-parameter-sets` and an FLV avcC may list several too. RTSP session timeline: when the video's first picture was captured before the audio began (sender reports of both tracks; a camera that starts with the keyframe it kept), the audio's origin moves forward by the difference rather than both starting at 0 (logged). AUD/filler/parameter-set NALs are removed, and so are H.264 SEI NALs (cameras send malformed ones that VideoToolbox's software decoder rejects; the decoder also leaves SEI out); access units end where the codec ends a picture (H.264 first_mb_in_slice 0 or an AUD/SPS/PPS/SEI after a slice; HEVC first_slice_segment_in_pic_flag or a VPS/SPS/PPS/AUD/prefix SEI after a slice), not only at the marker bit and timestamp change, because cameras (Tapo) stamp consecutive pictures alike and mark only some, and two pictures in one access unit fail every one (-12909); the timestamp and marker only end a unit that holds a slice. Timing: a unit stamped at or before its GOP's IDR is mis-stamped, not reordered (no B-frame is learned from it); keyframes stamped ahead of their pictures (a Tapo's IDR runs ~7 pictures ahead of its P clock) are learned and re-timed to one interval after their predecessor, and a repeated or slightly backward stamp is given back by the next catch-up, so the timeline neither wanders from the wall clock nor leaves the audio behind;
  "SPS|start code|PPS|start code|IDR" in one NAL is split; HEVC DONL/DOND are stripped when `sprop-max-don-diff` > 0.
- The message parser skips junk between messages byte by byte against the shape of a start line, so junk never
  swallows the `$` frames after it.
- A stream finishes normally after `close()`/`stop()`, and throws on disconnect (`TransportError.closed`), stall
  (`RTSPError.timeout`: no video RTP packet for `configuration.timeout` — audio and RTCP do not count — or no
  deliverable video frame for max(3 × `timeout`, 30 s)), HTTP errors, EOF or `timeout` without data (FLV). Dropping
  or cancelling an RTSP stream closes its session. Streams buffer at most 1024 samples (`SampleDelivery`) for a slow
  consumer: newer samples are then dropped and video resumes at the next keyframe. Backchannel audio is dropped
  once 1 MiB waits for a camera that stopped reading.
- Backchannel: `Require: www.onvif.org/ver20/backchannel` on DESCRIBE/SETUP/PLAY (DESCRIBE retried without it on
  551); the `sendonly` audio section is set up (without the `Require`, `sendonly` audio is the camera's own audio); G.711 in ≤ 1024-byte packets, AAC as RFC 3640 AAC-hbr; RTP
  timestamps advance by samples sent; the SSRC from the SETUP `Transport` is used when given.
- Credentials never appear in request lines or logs (`Redact.url`, which also masks `password=`/`pwd=` in a
  path; request lines use BridgeSupport's `URL.removingUserInfo`); `user:pass@` in the URL is stripped and used as
  credentials when none are configured. HTTP-FLV requests the URL as given (Reolink puts `user`/`password` in it)
  and maps URLSession errors to `RTSPError.timeout` / `TransportError` values without the URL (BridgeSupport's
  `URLFreeErrors.sanitized`, with RTSP's timeout error and request name); `stop()` (or a newer
  `samples()`) while `samples()` connects cancels it with `TransportError.closed`.

## Additions beyond the contract

`RTSPConfiguration.backchannelOnly`; `RTSPConfiguration.cameraID` (tags the client's log lines, depacketizers
included, with the camera); `RTSPTrack.init`; `RTSPSessionInfo.init`; `RTSPMediaSource.sessionInfo`;
`HTTPFLVMediaSource.init(url:credentials:displayName:timeout:cameraID:)` (`cameraID` likewise, default nil); `SDPSession.attributes`, `.control`,
`init(media:attributes:)`; `SDPMedia.proto`, `.control`, `attributeValues(_:)`, `rtpmap(for:)`, `fmtp(for:)`;
`SDPRTPMap`. Not supported: MP4A-LATM, Opus/L16 ingest, UDP transport, MJPEG video (`unsupportedCodec`).

## Test support (TestSupport, W1-5)

`RTSPTestServer` (loopback, own parser/packetizers/MD5; Digest/Basic, audio + ONVIF backchannel recording, sender
reports with clock offset, faults: drop every Nth FU fragment, stall, close after N s, session-timeout enforcement),
`SyntheticNALSource` (paced frames that carry their index), `ReplayMediaSource`, `TestDigest`.

## References

RFC 2326/7826 (RTSP), RFC 4566 (SDP), RFC 3550 (RTP/RTCP), RFC 6184 (H.264), RFC 7798 (H.265), RFC 3640 (AAC),
RFC 3551 (static payload types), RFC 2617 (Digest), ONVIF Streaming Spec (backchannel), Adobe FLV v10.1 Annex E and
Enhanced RTMP v1, the camera-ingest and native-media research notes (not published);
Scrypted's ONVIF intercom (read for the backchannel flow only). No code was ported.

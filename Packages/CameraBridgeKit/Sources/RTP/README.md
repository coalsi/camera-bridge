# RTP

RTP/RTCP/SRTP, H.264 and audio packetizers, UDP sockets and the HomeKit `LiveStreamSession` (research brief §3.6).
Depends on MediaCore, BridgeSupport and swift-crypto `Crypto` (HMAC-SHA1); SRTP AES-CTR uses CommonCrypto under
`#if canImport(CommonCrypto)` (only in `SRTP*` files), else `_CryptoExtras` `AES._CTR` (linked on Linux only).
`UDPSocket` imports Darwin/Glibc under `#if canImport`. Owner: W1-4 (complete; no stubs left).

## Entry points

- `RTPPacket` (Wave 0), `RTCPPacket.parseCompound` / `serialized()` (SR and RR with `RTCPReportBlock`s, BYE, PLI, FIR; others → `.other(type:)`).
- `SRTPContext` — AES_CM_128_HMAC_SHA1_80, KDR 0: `protectRTP/unprotectRTP/protectRTCP/unprotectRTCP`, `SRTPError`.
- `H264Packetizer` (RFC 6184 mode 1), `AudioPacketizer` (Opus RFC 7587; AAC-ELD/AAC RFC 3640 hbr).
- `UDPSocket` (BSD socket + `DispatchSource`), `SocketAddress`.
- `LiveStreamSession` + `LiveVideoParameters` / `LiveAudioParameters` / `LiveStreamEndReason`.

## Additions beyond the contract

`AudioDepacketizer` (return audio → `EncodedAudioFrame`), `UDPSocketError` (`invalidAddress`, `system`, `closed`),
`RTPError` reused by `RTCPPacket.parseCompound`. `LiveStreamSession.end(reason:)` and `LiveStreamEndReason.pipelineFailed(_:)` (the media
pipeline in front of the session gave up: the log line, the timeline and `waitForEnd()` carry its reason in words instead of "stopped";
`LiveStreamEndReason.description` is the reason in words, 2026-10-03). `LiveStreamSession.waitForController(timeout:)` (W4 review: the first
authenticated controller packet). `UDPSocket.localPort` / `datagrams` are `let` (read-only, as contracted).
Internal: `UDPSocket.closeWithoutWaiting()` / `waitUntilClosed()` (non-blocking close for actors and deinit);
`UDPSocket.wildcard` / `resolve` / `socketAddress` / `configure` (unit-tested without binding).

## Invariants

- `RTPPacket(parsing: p.serialized()) == p` always (wire-form storage; see docs/CONTRACT_CHANGES.md).
- SRTP: per-SSRC state for each of the four operations; ROC advances on sequence wrap (RFC 3711 §3.3.1 estimate on
  both sides); inbound checks the tag in constant time, then a 64-packet replay window, and commits state only after
  success (forged packets leave no trace). SRTCP index starts at 1 per SSRC (libsrtp/werift) with the E bit set.
- `H264Packetizer`: STAP-A (header 24, F = NRI = 0) with in-band SPS/PPS, else the format's for keyframes; single NAL
  when it fits, else FU-A; marker only on the AU's last packet; every serialized RTP packet ≤ `maxPacketSize`
  (floor 15). AUDs and empty NALs dropped.
- `AudioPacketizer`: Opus/G.711 raw with marker on the first packet only; RFC 3640 AU header (13-bit size, 3-bit
  index) with marker on every packet; AUs > 8191 bytes are cut.
- `UDPSocket`: numeric addresses only (no DNS); IPv4 literals map to `::ffff:` on IPv6 sockets and v4-mapped
  senders are reported as IPv4; no `SO_REUSEADDR`; 1 MiB buffers; `datagrams` keeps the newest 1024. Each readiness
  event reads at most 64 datagrams and stops once closing has begun (the source fires again while data remains), so
  a flood cannot hold up closing. `close()` finishes `datagrams` at once and returns after the descriptor is closed
  (at most one datagram read later). deinit and `LiveStreamSession` never block: `closeWithoutWaiting()`, then
  `waitUntilClosed()` awaits the descriptor.
- `LiveStreamSession`: waits for the first keyframe; RTP timestamps = random base + pts delta (video 90 kHz, audio at
  `rtpClockRate`); SRTP packets ≤ `maxPacketSize` (packetizer gets −10 for the tag); SR every `rtcpInterval` per
  stream after its first packet, SR+BYE at the end; a stream that sent no media sends no RTCP at all, not even BYE
  (RFC 3550 §6.1, §6.3.7); any authenticated controller packet (RTCP or return audio) is a keepalive, and
  symmetric RTP latching: the first authenticated packet from a host other than the destination moves the destination
  (both streams, advertised ports kept; `LiveStreamTimeline.latchedDestination`); `waitForController(timeout:)` waits for the first one (integration brief §5.4: video waits ≤ 1 s for the controller's
  RTCP; BridgeEngine holds its first keyframe until then); PLI/FIR →
  `keyframeRequests` (one pending, coalesced); return audio with the audio payload type → `returnAudio` (newest
  128). The session owns its sockets and closes them without blocking when it ends (a flood at its ports cannot delay
  `stop()`); `waitForEnd()` returns once both descriptors are closed. Invalid SRTP key/salt lengths end it with
  `.socketError`. One SRTP key per stream serves both directions (HAPCamera echoes the controller's key in
  SetupEndpoints, as HAP-NodeJS does), so inbound packets carrying one of the session's own SSRCs (RTP bytes 8..<12,
  SRTCP sender SSRC 4..<8) are dropped before authentication: our own packets looped or reflected back (RFC 3550
  §8.2) would otherwise authenticate and count as keepalives and return audio.

## Transport protection (live-view hardening)

A live view must never silently break: every failure is detected, logged in one line, and heals itself or ends so Home
retries. All thresholds are in `LiveStreamTimings` (injectable; tests use milliseconds) and the video socket carries
how it was set up and who to tell (`UDPSocket.transport`, a `LiveStreamTransport`, filled by the streaming delegate).

- `RTCPReportBlock`: SR and RR report blocks are parsed and serialized (`cumulativeLost` is 24-bit signed).
- `ControllerReceptionMonitor`: tells "alive but receiving nothing" from the controller's receiver reports (no block about
  our video, a highest sequence number that stands still while we send ≥ 50 packets, ≥ 230/256 lost), after ≥ 3 reports, a
  session of 4 s and a symptom of 3 s. The session then warns once (bound source, destination, route, counters, last block),
  tells the owner (`onControllerNotReceiving`), scopes both sockets to `recoveryScopes` one after another (every 3 s; the
  bound source stays) and ends with `.controllerNotReceiving` after 10 s. Reports before the first video packet prove nothing.
- `PacedTransmission`: a frame's packets go out in chunks of ≤ 24 with 1 ms between them (≤ 20 ms of pacing per frame);
  ENOBUFS / EAGAIN / EINTR are retried up to 10 times; a lost video packet asks for a fresh keyframe (≤ 1 per second, one
  WARNING per incident); `SendFailureTracker` logs each errno once and ends the session (`.socketError`) when a fatal one
  (EADDRNOTAVAIL, ENETDOWN, ENETUNREACH, EHOSTUNREACH, EPERM) persists 2 s with no send succeeding. `CatchUpPacer` spreads a
  replay at 2× the negotiated bit rate (`LiveStreamTransport.Values.maxBitrateKbps`) while the media runs ahead of the clock.
- Liveness: `.noVideoAtStart` (10 s), `.sourceStalled` (8 s); sender reports stop for a stream that sent nothing for 5 s.
- `DestinationLatch`: the destination latches once; another source is followed only after the latched one was silent 5 s.
- `UDPSocket.bind(interface:)` / `scope(toInterface:)`: `IP_BOUND_IF` / `IPV6_BOUND_IF` (`SO_BINDTODEVICE` elsewhere).
  `injectSendFailures` is the test seam for send errors.

## Tests

`swift test --filter RTPTests` — RFC 3711 B.2/B.3 vectors plus libsrtp reference packets (re-derived with openssl),
RTCP goldens, packetizer round trips through an in-test depacketizer, loopback UDP (127.0.0.1 / ::1) and session
tests (Opus and AAC-ELD, keepalive by RTCP or by return audio alone, the session's own packets reflected back by a
keyless peer, `close()`/`stop()` under a loopback UDP flood).
A flood can overflow lo0's shared input queue and silently drop other sockets' datagrams, so loopback tests that expect
every datagram declare `.loopback` and flood tests `.loopbackFlood`, which runs them alone (`LoopbackGate.swift`;
`LoopbackFlood` refuses to start without it, and the datagram helpers flag a loopback test without `.loopback`).
The app binds the wildcard (dual stack on IPv6) for every live view, which these loopback suites never do:
`UDPSocketWildcardTests` checks the wildcard addresses (family, network-order port, length), IPV6_V6ONLY from
`configure` on an unbound socket, and IPv4-mapped destinations and senders, without binding anything. Opt-in:
`CB_WILDCARD_TESTS=1 swift test --filter UDPSocketWildcardBindTests` binds the IPv4 and IPv6 wildcards and exchanges
datagrams with 127.0.0.1 and ::1 only (the sockets are reachable on every interface meanwhile, hence opt-in).
Oracle (opt-in): `CB_FFMPEG_ORACLE=1 swift test --filter FFmpegOracleTests` — ffmpeg decodes 3 s of our SRTP video
from an SDP with `a=crypto` (`-xerror`, ≥ 80 frames).

## References

RFC 3550, 3551, 3711, 4585, 5104, 5761, 6184, 7587, 3640; ISO/IEC 14496-3 (AAC-ELD AudioSpecificConfig); research
brief §3.6; werift (MIT) and Scrypted SRTP and H.264 packetizer sources (read for reference only; nothing ported).

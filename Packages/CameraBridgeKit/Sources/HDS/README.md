# HDS

HomeKit Data Stream: value codec, frame crypto, listener and connections (used for HKSV `dataSend`).
Depends on HAP (for `HAPSessionHandle`), HAPCore (`HAPCrypto` HKDF/ChaCha20-Poly1305), BridgeSupport. Portable: the
listener uses the injected `NetworkTransport` (`DataStreamServer(transport:loopbackOnly:)`). Owner: task W1-6 (done).

## Public entry points

- `HDSValue`, `HDSDictionary` (ordered), `HDSCodec.encode/decode`, `HDSMessage`, `HDSStatus`, `HDSProtocolReason`.
- `HDSFrameCodec`: `deriveKeys`, `encodePayload`/`decodePayload`, `sealFrame`/`openFrame` (enough for a test client).
- `DataStreamServer`: `prepareSession` (SetupDataStreamTransport), `setHandler(protocol:)`, `stop`, `connectionCount`.
- `DataStreamConnection`: `sendEvent`, `sendResponse(to:)`, `sendRequest(timeout:)`, `close`, `isClosed`, `onClose`.

## Additions beyond the contract

`HDSCodecError` (no `invalidUTF8` case: invalid UTF-8 decodes lossily), `HDSFrameError`, `HDSConnectionError`;
`HDSCodec.maximumDepth` (64); `HDSFrameCodec.maximumPayloadLength` (0xFFFFF); `HDSDictionary.count`;
`DataStreamServer.init(transport:loopbackOnly:log:)` (the logger of the server and its connections, e.g. tagged with the
camera's ID; the contract initializer logs untagged, category "HDS"). A frame whose send makes no progress for
`DataStreamServer.Timing.sendStallTimeout` (15 s) closes its connection (`sendWatchingProgress`, HAP): a hub that vanished without
a FIN no longer holds the recording slot.

## Invariants

- `HDSDictionary` keeps insertion order; setting an existing key replaces it in place; `==` is order-sensitive
  (same pairs in the same order), matching the wire encoding. Repeated keys (decoded input only) stay in `pairs`;
  like HAP-NodeJS (a JavaScript object) the subscript reads the last value, and setting the key leaves one entry at
  the first occurrence's position.
- Encoder (brief §3.8): −1 → 07, 0–39 → 08+n, then int8/16/32/64 by range (full int64); floats as float64; strings and
  data ≤ 32 bytes short form, else the smallest 1/2/4/8-byte LE length prefix; arrays and dictionaries ≤ 14 items
  count form (HN: arrays ≤ 12), else terminated. Never emits back-references (A0–CF). Nesting > 64 throws.
- Decoder: every tag class incl. 6F/9F terminated forms, float32, and back-references with HAP-NodeJS reader
  semantics (booleans, integers, floats, dates, strings, data, UUIDs are remembered; null/containers are not).
  HN bugs fixed: 0x2F = 39, short data (70–90) decodes, int64 > 2³² round-trips. Malformed input throws typed errors
  (truncated, invalid tag/back-reference, non-string key, stray terminator, depth, trailing bytes). Invalid UTF-8 in
  strings and keys decodes with U+FFFD replacements, like HN's `Buffer.toString("utf8")` (Node 24 outputs in tests).
- Payload: `[headerLen u8][header][message]`; `id`/`status` are always written as int64 (hello-response golden);
  header > 255 bytes throws. Decoding tolerates trailing bytes and an absent message (= `{}`), like HN.
- Frame: `[01][len24 BE][ct][tag16]`, AAD = header, nonce `00000000 ‖ LE64(counter)` per direction; keys from
  HKDF-SHA512(sharedSecret, salt = controllerKeySalt ‖ accessoryKeySalt, `HDS-Read-`/`HDS-Write-Encryption-Key`).
- Server: one lazily bound listener (ephemeral port; closes when nothing is prepared/connecting/connected);
  prepared sessions expire after 10 s; first frame must arrive within 10 s and is trial-decrypted at counter 0
  against each prepared session (a match consumes it); first message must be `control/hello` (answered with `{}`);
  a HAP session close drops its prepared sessions and closes its connections.
- Server bounds (HN has none): at most 8 connections may await their first frame; a newcomer beyond that closes the
  one that has waited longest (never itself, so idle sockets cannot lock the hub out; `AccessoryServer`'s cap on
  unverified HAP connections likewise keeps the newcomer); a connection that sends no byte at all within 2 s is closed (the hub sends its hello
  right after connecting; once bytes arrive the 10 s hello window applies); a first frame longer than 1 KiB is
  refused as soon as its header arrives, before buffering or trial decryption. What such peers can put into the log
  is bounded (HAP's package-wide `UnauthenticatedWarningLimiter`): an eviction is logged at most once a minute, a first
  frame that matches no prepared session at most once a minute per remote address; the next line says how many were
  not.
- Server lifetime: a connection the transport delivers after its listener was closed (`stop()` racing the accept
  loop, idle close, restart) is closed at once. Releasing the server without `stop()` closes the listener, prepared
  sessions and every connection (`deinit`); no task keeps the server alive while it waits.
- Listener recovery: a failed bind is thrown to that `prepareSession` and not remembered, and a listener the transport
  stops on its own (NWListener `.waiting`/`.failed`) is forgotten even while connections keep the server busy; either
  way the next `prepareSession` binds a new listener. The engine never restarts a camera's server on wake or a network
  change, so this is HKSV's only way back.
- Connection: handlers run one message at a time in arrival order (long work must be spawned); responses bypass
  handlers; unhandled requests get `.missingProtocol` (HN stays silent), unhandled events are dropped; frames leave
  in nonce order even from concurrent senders; auth failure, oversized frame, peer EOF or a `sendRequest` timeout
  closes the connection and fails pending work with `HDSConnectionError.closed` / `.timeout`.
- Connection backpressure: at most 32 events/requests wait for (or sit in) the handler; at that point the
  connection stops reading from TCP until the handler catches up (so a handler awaiting `sendRequest` while the
  peer floods the queue waits for that request's timeout). Messages still queued when the connection closes are
  dropped, never dispatched.
- Undecodable messages after the hello (HN hands them on as they are): a response still settles its pending request
  with the decoding error (e.g. `HDSFrameError.invalidStatus` for a status outside 0–6) instead of timing out and
  closing the connection; a request with a readable header (protocol, topic, id) is answered with `.payloadError`;
  anything else is dropped.
- No keys, salts or secrets are logged.

## Tests / references

`Tests/HDSTests`: the HAP-NodeJS 2.2.3 goldens in `Fixtures/hds-codec.json` and `Fixtures/hds-frames.json`
(`Interop/node/goldens.mjs`, docs/interop.md; every value, decode-only, invalid, payload, key and sealed-frame case is
checked by `HDSFixtureGoldenTests`), inline codec goldens (brief §3.8 event header and hello response header; other
encodings produced by running HAP-NodeJS 2.1.6's `DataStreamParser`), ported `DataStreamParser.spec.ts`, HKDF and
sealed-frame goldens from Node 24 `crypto`, loopback server tests over `AppleNetworkTransport` (127.0.0.1 only) with a fake `HAPSessionHandle`
and an in-test client built from `HDSFrameCodec`, and deterministic race/lifetime/backpressure/listener-recovery tests
over an in-memory `FakeNetworkTransport` (TestSupport's `FakeTransport.swift`; scripted bind failures, listeners that
fail on their own, cancellable receives). References: brief §3.8; HAP-NodeJS 2.2.3 `lib/datastream/*`
(Apache-2.0; derived files carry the attribution header).

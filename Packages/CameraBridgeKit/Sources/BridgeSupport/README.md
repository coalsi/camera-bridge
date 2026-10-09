# BridgeSupport

Portable utilities shared by every CameraBridgeKit module, plus the platform service protocols. Imports only
Foundation (+ FoundationNetworking / os under `#if canImport`), Synchronization and swift-crypto `Crypto`
(MD5/SHA-256 for HTTP Digest; SHA-1 for the ONVIF WS-UsernameToken digest through `Hashes`).

## Public entry points

- Logging: `Log` (os.Logger subsystem `com.coreysilvia.CameraBridge` where `os` exists + `LogHub` sinks),
  `LogHub` (`addSink` → `LogSinkToken`, `removeSink`, `removeAllSinks`, `minimumLevel`), `LogSink`, `LogEntry`, `LogLevel`.
- `Redact.url` / `Redact.string` — strip `user:pass@` (up to the last `@` before `/` or a line break, so passwords
  containing `@` or spaces do not leak), mask parameters (also nested, `x=a?password=…`) and JSON members whose
  name ends in password/passwd/pwd/pass/pw/token/secret/apikey. `Redact.url` masks them in the path too
  (Xiongmai/XMEye `/user=admin&password=…`, `/snapshot.cgi;pwd=…`; a path value ends at the next `/`), W4 review.
  `Redact.string` is linear in its input (W4 review round 4: the user-info regex backtracked, quadratic on camera text —
  hours for 1 MiB of letters; an internal scan, `maskUserInfo`, finds the same matches).
- `URL.removingUserInfo` — the URL without `user:password@`: the one copy (drivers' StreamInfo URLs,
  `CameraConfiguration.withoutStreamCredentials`, RTSP request lines, the app's wizard and connection editor,
  `Redact.url`). Credentials in the path or query stay (the camera needs them); `Redact.url` masks those for logs.
- Diagnostics: `DiagnosticsLog` (a `LogSink`: every entry redacted by `Redact.string`, 20 000 in a memory ring and 5 × 2 MB
  rotating files `diagnostics.log`, `.1.log` … in a 0700 directory, written on a background queue), `DiagnosticsCenter`
  (`shared`; `install(directory:)` registers the log with `LogHub` at debug level; `begin(kind:id:cameraID:)` →
  `SessionTrace` whose `mark`/`finish` build a `SessionRecord` of a live view's or recording's phases, newest 300 kept).
- `Backoff` — exponential backoff with symmetric jitter, capped.
- HTTP auth: `HTTPCredentials`, `DigestChallenge.parse`, `DigestAuthenticator` (MD5, MD5-sess, SHA-256,
  SHA-256-sess; qop `auth` preferred, else `auth-int` hashing the entity body, else RFC 2069 legacy), `BasicAuth`.
- `AuthenticatingHTTPClient` — URLSession wrapper answering Basic/Digest itself: `data(for:)` (bounded: body limit
  `maximumBodySize`, default `defaultMaximumBodySize` 16 MiB, and `timeout` per round trip in total), `stream(for:)`.
  Never answers Basic for a host that asked for Digest (`BasicDowngradeGuard`, W4 review round 4).
- Platform protocols (PlatformApple implements them): `NetworkTransport`/`TCPListener`/`TCPConnection`, `TransportError`,
  `ServiceAdvertiser`/`AdvertisedService`/`ServiceAdvertisement`, `SecretStore`, `NetworkChangeMonitoring`, `PowerManaging`
  (with `endBackgroundActivity()`, W4 review: the engine ends its App Nap activity on pause/stop),
  `PlatformServices`; `NullServiceAdvertiser`, `InMemorySecretStore`, `NullNetworkChangeMonitor`, `NullPowerManager`.
- HTTP/1.1 framing: `HTTPHeaders`, `HTTPRequestHead`, `HTTPResponseHead`, `HTTPRequestParser`,
  `HTTPResponseParser` (also parses HAP `EVENT/1.0`), `HTTPSerializer`, `HTTPParseError`.
- Bytes: `Data(hex:)`, `Data.hexString`, `ByteReader`, `ByteWriter`, `ByteError`.
- `NTPTime` (RTCP 32.32 timestamps), `AsyncBroadcaster` (multi-subscriber AsyncStream fan-out).
- `PrivateFiles` — the one writer for persisted private files (HAP `state.json`, the engine's `config.json` and
  backups): `write` (atomic: 0600 temporary file, then replace/move; the result is 0600), `prepareDirectory` (every
  missing level created 0700; an existing directory is never changed), `exists`, `unusedURL(in:_:)`.

## Additions beyond the contract

Offline cameras (2026-10-02, docs/CONTRACT_CHANGES.md): `CameraReachability` (one per camera: whether it answers at all. Components
report `reportReachable()` / `reportUnreachable()`; three unreachable reports in a row start a TCP check of the camera's ports, and
when none answers the camera is `offline`: one probe on a 2 s to 60 s backoff, `isOffline`, `waitUntilReachable()`; `Timing`,
`Phase`, `isUnreachable(_:)`, `isGatewayFailure(httpStatus:)`) and `CameraOfflineError` (thrown instead of a request while it is).

`LogEntry.init`, `Log.subsystem`, `HTTPRequestHead.init`, `HTTPResponseHead.init`, `HTTPHeaders.values(for:)`,
`HTTPResponseParser`, `HTTPParseError`, `HTTPSerializer.reasonPhrase(for:)`, `HTTPClientError`,
`DigestChallenge.init`, `DigestAuthenticator.init(credentials:cnonce:)` (deterministic cnonce for vectors),
`DigestAuthenticator.authorization(for:method:uri:body:)` (qop=auth-int; the contract overload uses an empty body),
`LogSinkToken` / `LogHub.removeSink(_:)` (approved, docs/CONTRACT_CHANGES.md), `PrivateFiles` (+ `PrivateFiles.Failure`;
moved from BridgeEngine so HAP shares it, W4 review), `PowerManaging.endBackgroundActivity()` (W4 review; a requirement
with a default no-op in a protocol extension, so conformers written to the contract compile unchanged),
`HTTPClientError.bodyTooLarge(limit:)`, `AuthenticatingHTTPClient.init(credentials:timeout:allowSelfSignedTLS:maximumBodySize:)`
and `AuthenticatingHTTPClient.defaultMaximumBodySize`, `URL.removingUserInfo` (`URLUserInfo.swift`; W4 review),
`TCPConnection.zone` (W4 review round 4: the IPv6 zone of a link-local connection, which `localAddress` and
`remoteAddress` leave out; a requirement with a default, nil, so conformers written to the contract compile unchanged).
Internal: `LogRouter` (tests route a `Log` to a private router instead of changing `LogHub`).

Package-wide (`package` access: every module of CameraBridgeKit, not the app or the contract), in `Concurrency.swift`
unless noted — the one copy of each, so modules do not grow their own (`PortabilityTests` rejects new copies of
user-info stripping, of `Duration` → seconds conversions, of URL-error sanitizing and of hand-written SHA-1):
`withDeadline(_:followsCancellation:_:late:)` + `DeadlineExceeded` (HAPCamera's delegate calls, HAP's handler timeout,
BridgeEngine's runtime, CameraAdapters' `withTimeout`, `AuthenticatingHTTPClient.data(for:)`), `AsyncSerialLock`
(`withLock`, `withLockUnlessCancelled`, `waiterCount`, `isLocked`; HAPCamera's stream services and controller,
BridgeEngine's lifecycle operations), `Duration.timeInterval` (`Backoff.swift`; every module but FMP4, whose dependency
graph has no BridgeSupport), `Hashes.sha1` (`Hashes.swift`, swift-crypto: CameraAdapters' ONVIF PasswordDigest, which
replaced a hand-written SHA-1, W4 review), `URLFreeErrors` (`URLFreeErrors.swift`: `sanitized(_:request:timedOut:passing:)`
throws `AuthenticatingHTTPClient`'s URLSession errors without their failing URL — RTSP's HTTP-FLV source with
`RTSPError.timeout`, CameraAdapters' `CameraHTTP` with the defaults; `describe(_:)` summarises them for the log —
BridgeEngine's snapshot logs; `failingURLStringKey`; review round 2, replacing a copy in each of those modules),
`Redact.cameraText(_:limit:)` + `Redact.cameraTextLimit` (`Redact.swift`: camera-supplied text for an error or a log
line — control, format and separator characters become spaces, at most 200 characters; RTSP's unsupported-codec and
SETUP-transport errors, CameraAdapters' ONVIF SOAP faults; W4 review round 4), `BasicDowngradeGuard` (`HTTPAuth.swift`:
`digestRequested(by:)`, `mayAnswerBasic(from:log:)` — `AuthenticatingHTTPClient`, RTSP's `RTSPClient` /
`RTSPMediaSource` / `HTTPFLVMediaSource` (through the package `AuthenticatingHTTPClient.init(…downgradeGuard:)`), CameraAdapters' Hikvision talkback upload; W4 review round 4),
`HTTPRequestParser.init(maxBodySize:maxHeadSize:maxHeaderCount:)` and `HTTPRequestParser.pendingHead` (`HTTPMessage.swift`:
CameraAdapters' webhook limits heads to 8 KiB / 64 header lines and refuses a wrong token before reading a body, W4
review round 4).

## Invariants

- `Log` messages are evaluated only when `level >= LogHub.minimumLevel`; never pass secrets — use `Redact`.
- `HTTPRequestParser`/`HTTPResponseParser`: Content-Length bodies only (chunked → `unsupportedTransferEncoding`),
  heads ≤ 64 KiB (or the package initializer's `maxHeadSize` and `maxHeaderCount`, else `headTooLarge`), bodies ≤
  `maxBodySize`; any throw means the connection must be closed. Incremental (W4 review round 4): the search for a
  head's end resumes where the previous `feed` stopped, a head is parsed (and its start line checked) once and kept
  while its body arrives (`pendingHead`), and consumed messages leave the buffer once per `feed` — a peer trickling a
  message one byte per read costs work in proportion to its bytes (`HTTPMessageTests.tricklingARequestCostsLinearWork`).
- `HTTPRequestHead.queryItems` never traps: it splits the query itself (same items as `URLComponents` for valid
  queries) and decodes leniently (bad `%` kept literally, invalid UTF-8 → U+FFFD). Never feed network text to
  Foundation's validating `percentEncoded*` setters — they `fatalError`. `path`/`queryItems` ignore a `#fragment`.
- `NTPTime.timestamp` never traps: pre-1900 and non-finite dates → 0; later NTP eras wrap (RFC 5905).
- `HTTPSerializer.response` adds `Content-Length` except for 1xx/204/304.
- `AuthenticatingHTTPClient`: URLSession's own auth handling is suppressed (it re-sends every 401'd request once).
  The session delegate cancels the HTTP challenge and captures the 401; the client retries once with Digest
  (preferred) or Basic and caches the challenge per scheme/host/port for preemptive auth (nc increments).
  Wrong credentials ⇒ exactly one authenticated attempt, then the 401 is returned with an empty body.
  Self-signed TLS accepted by default (Darwin; FoundationNetworking has no server-trust challenge); no certificate is
  pinned yet (trust on first use needs a stored fingerprint per camera: not done).
- No Digest-to-Basic downgrade (W4 review round 4: a host impersonating a Digest camera got the password from one
  `401 Basic`, and the cached `.basic` re-sent it on every request): once a host asked for Digest, a Basic-only
  challenge from it is not answered for the rest of the client's life (`AuthenticatingHTTPClient`; the sessions of one
  `RTSPMediaSource`; a Hikvision talkback sink) and the 401 goes to the caller — also after a rejected Digest retry
  cleared the cached challenge. A warning is logged once per refused host; a host that only ever asks for Basic is
  still answered (noted once per host per process). Keys are `scheme:host:port`; guards are never shared between
  cameras, so a camera switched to Basic on purpose is answered again after a restart.
- `Redact.string` runs in linear time: user info is found by a scan (each scheme run walked back once, each user-info
  span forward once), never by a backtracking regex over camera text. Camera text that goes into an error or a log
  line passes through `Redact.cameraText` first (≤ 200 characters, no control, format or separator characters).
- `data(for:)` treats camera answers as hostile (W4 review: an endless body grew memory without bound): the body is
  collected from session-delegate callbacks and holds at most `maximumBodySize` bytes — a longer body, or a longer
  Content-Length, cancels the task at once and throws `HTTPClientError.bodyTooLarge(limit:)`; each round trip (the
  request, then any authenticated retry) ends within `timeout` in total (`withDeadline`; `URLError(.timedOut)`), on
  top of the idle timeout; a cancelled caller cancels the task and gets `CancellationError`.
- `stream(for:)` uses session-delegate callbacks routed per task (no `URLSession.AsyncBytes`). URLSession reports
  the response head together with the first body bytes (or EOF), so the call returns then; chunks are yielded as
  received (unbounded buffer), EOF finishes, errors throw, and dropping/cancelling the body cancels the task.
- `URLFreeErrors.sanitized` returns no URLError and no error with a URL in its user info (also nested): URLErrors
  map to `TransportError` / the caller's timeout error / `CancellationError`, a caller's own error type passes only
  without a URL, unknown errors keep only domain and code. `describe` gives "URLError <code>" / "<domain> <code>" for
  URL-carrying errors, else `Redact.string` of the description.
- `NullNetworkChangeMonitor.changes` finishes immediately; `NullServiceAdvertiser`'s service never fails.
- `ByteReader` works on `Data` slices; failed reads consume nothing.
- `AsyncBroadcaster` never blocks producers: each subscriber buffers the newest N elements.
- `withDeadline` returns on time even when its body ignores cancellation: the body runs in its own task and is
  cancelled and abandoned at the deadline (`late` gets its eventual outcome). Never bound a call with a task group
  instead — a group always awaits its children, so it returns only once such a body ends. Caller cancellation throws
  `CancellationError` at once (the body never starts if the caller was already cancelled), except with
  `followsCancellation: false` (teardown that must run: the caller waits for the body or the deadline).
- `AsyncSerialLock` is FIFO and runs each body on the caller's actor; `withLock` waits even when its caller is
  cancelled, `withLockUnlessCancelled` leaves the queue at once and returns nil without running the body.

## References

RFC 2617 §3.5 / RFC 7616 §3.9.1 (Digest vectors, in tests), RFC 7230 (framing), RFC 5905 (NTP). Loopback tests only.

## Additions beyond the contract: helper processes (2026-10-08, docs/CONTRACT_CHANGES.md)

`HelperLaunching` / `HelperProcess` / `HelperLaunchSpec` / `HelperExit` / `HelperLaunchError` / `NullHelperLauncher` and `HelperOutput` (line splitting and
clipping of a helper's output) let portable modules run a bundled program (go2rtc) without knowing how: `PlatformServices.helpers` (default
`NullHelperLauncher`). PlatformApple's `ProcessHelperLauncher` runs it with `Process`; a Linux edition will bring its own.
`AuthenticatingHTTPClient.stream(for:)` keeps a `multipart/x-mixed-replace` response open across its parts (a line break marks where one ended).

A first response that is a plain `URLResponse` (the first part of such a stream) no longer fails with `notHTTPResponse`.

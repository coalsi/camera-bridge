# BridgeWeb

The web interface of Camera Bridge OS, as portable Swift: an HTTP/1.1 server over the injected `NetworkTransport`, the JSON API
(`/api/v1`), password and session handling, static file serving and an SVG QR code encoder. It depends on the engine and on
`Crypto` only; every test runs on a Mac against a fake backend, the in-memory transport or the real engine. The API contract is
in `docs/linux/ARCHITECTURE.md`; the interface itself is `linux/web/`.

## Layout

| File | What |
|---|---|
| `HTTPServer.swift`, `HTTPTypes.swift` | Keep-alive and pipelined requests (parsed by BridgeSupport's `HTTPRequestParser`), head, body and time limits, connection limits per peer, chunked streaming answers (server-sent events, multipart JPEG) that end when the client leaves |
| `WebApp.swift`, `WebApp+Routes.swift`, `WebApp+Bridge.swift` | The route table and handlers; Host, Origin, session and CSRF checks; security headers |
| `AuthStore.swift`, `Security.swift` | First-run setup, PBKDF2-HMAC-SHA256 (600,000 rounds, per-password salt), 256-bit session tokens kept as SHA-256 hashes in `<data>/web/auth.json` (0600), login rate limiting, constant-time comparison |
| `CameraSetup.swift`, `CameraTypeCatalog.swift`, `HostInput.swift` | The Mac app's Add Camera wizard as a stateless service: the same types, words and checks |
| `EventHub.swift`, `LogFeed.swift` | Server-sent events from the engine's observable state; the live log |
| `StaticFiles.swift` | The interface's files: content types, ETag and 304, traversal-proof paths |
| `QRCode.swift` | QR Code encoder (byte mode, versions 1 to 10, levels L and M) drawing SVG |
| `BridgeBackend.swift`, `SystemControl.swift` | The seams: `EngineBackend` wraps `BridgeEngine`; `SystemControlling` is the operating system under the bridge |

## Additions beyond the contract

New module (additive; docs/CONTRACT_CHANGES.md 2026-10-08): `BridgeWeb` with `WebService`, `WebApp`, `WebConfiguration`, `HTTPServer`,
`HTTPRequest`, `HTTPResponse`, `ResponseStream`, `AuthStore`, `BridgeBackend`, `EngineBackend`, `BridgeOverview`,
`SystemControlling`, `UnavailableSystemControl`, `SystemInfo`, `UpdateStatus`, `InstallTarget`, `SystemError`, `LogFeed`,
`CameraTypeCatalog`, `CameraTypeSpec` and `QRCode`.

## Security notes

- Only IP addresses, `localhost`, `*.local`, `*.home.arpa`, names without a dot and `allowedHosts` are served (DNS rebinding).
- A request that changes something needs an `Origin` that matches `Host` (or `Sec-Fetch-Site: same-origin`), the session's
  `X-CSRF-Token` and `Content-Type: application/json`.
- The session cookie is `HttpOnly; SameSite=Strict; Path=/` (and `Secure` behind a TLS front end).
- Camera passwords, cloud sources and API keys go to the engine's secret store and never into an answer, the log or a file of the web
  interface.

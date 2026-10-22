# Secure address (trusted HTTPS certificate): plan

Spec: `docs/superpowers/specs/2026-10-22-https-certificate-design.md`. Website contract: unsigned `POST register {publicKey}` -> `{name, host}`;
signed `POST address {ip}`, `POST/DELETE acme {value}`; headers `X-CB-Name`, `X-CB-Timestamp` (unix ms, strictly increasing),
`X-CB-Signature` (base64 Ed25519 over `METHOD\nPATH\nTIMESTAMP\nSHA256hex(body)`); errors `{error}`, 503 = DNS token not set yet.

| # | Task | Files | Tests |
|---|---|---|---|
| 1 | Identity, signer, one client type (transport protocol, strictly rising timestamps) | `BridgeWeb/SecureAddress/BoxIdentity.swift`, `BoxClient.swift` | `BoxClientTests` (signature verifies, fake server, 503, order) |
| 2 | State file + service (register once, send LAN address on change, request/renew certificate 30 days early with backoff, rebind self-test) | `SecureAddressState.swift`, `SecureAddressService.swift` | `SecureAddressServiceTests` |
| 3 | System side: `SystemControlling.certificateStatus/obtainCertificate`, `tls-obtain` request, `status/tls.json` | `SystemControl.swift`, `RequestFileSystemControl.swift`, `Daemon.swift` | `RequestFileSystemControlTests` |
| 4 | Redirect rules and TLS-front trust (loopback peer: X-Forwarded-For/Proto, own Host allowed) | `SecureAddressRules.swift`, `WebApp.swift`, routes `WebApp+SecureAddress.swift` | `SecureAddressRulesTests`, server test |
| 5 | OS: `cb-tls` (lego, install, status), `cb-tls-hook`, `tls-obtain` job in `cb-system`, nginx front + unit drop-in, packages `lego`, `nginx` | `linux/os/mkosi.*`, `usr/sbin/cb-tls`, `usr/lib/camera-bridge/cb-tls-hook` | `linux/os/test-tls.sh`, `test-static.sh` |
| 6 | Page: Secure address card on System | `linux/web/js/screens/system.js`, `secure-address.js` | `secure-address.test.mjs` |
| 7 | Dev server routes, CONTRACT_CHANGES, README | `linux/web-dev/lib/server.mjs`, docs | `run.sh`, `lint.mjs` |

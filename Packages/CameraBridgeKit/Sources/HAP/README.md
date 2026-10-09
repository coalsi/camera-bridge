# HAP

HomeKit Accessory Protocol server (plan task W1-1): accessory model, characteristic/service definitions,
`/accessories` JSON, pair-setup/verify, encrypted sessions, events, `/pairings`, `/resource`, `_hap._tcp`
advertising, persistence. Portable: depends on HAPCore and BridgeSupport only; TCP via the injected
`NetworkTransport`, Bonjour via the injected `ServiceAdvertiser`, secrets via `SecretStore`.

## Public entry points

- Definitions: `CharacteristicType` / `ServiceType` constants for research brief §3.4, generated from HAP-NodeJS by
  `Tools/hap-definitions/generate.mjs` into `Definitions/*+Definitions.swift` (do not edit those by hand).
- Model: `Characteristic` (value, `update`/`sendEvent`, `onRead`/`onWrite`, observers, overrides), `Service`,
  `Accessory` (+ bridged accessories, `onIdentify`, `onResourceRequest`, `setReachable`), `HAPSessionHandle`.
- Server: `AccessoryServer` (start/stop, setup code/URI, `events`, `resetPairings`, `configurationDidChange`, extras).
- Stores: `InMemoryHAPStore`, `FileHAPStore` (`state.json` 0600, written through BridgeSupport `PrivateFiles`: a
  directory it creates is 0700, an existing one is left as it is; identity incl. Ed25519 key in the `SecretStore`
  under `account`), `InMemorySecretStore` (BridgeSupport), `HAPStore.loadOrCreateIdentity()` (the server's and the
  engine's one way to get an identity; see Invariants).

## Additions beyond the contract

`Accessory.init(info:category:stableKey:)` + `stableKey` (aid persistence key; default serial number, else name),
`AccessoryServer.restartAdvertising()`, `AccessoryServer.pairingsLostWithIdentity`, `HAPStore.loadOrCreateIdentity()`,
`HAPStore.replaceIdentity()`, `HAPStore.identityLockName` (a requirement with a default: `""`; `FileHAPStore`: its account),
`HAPJSON` / `HAPJSONObject` / `HAPJSONError` (strict parser, deterministic serializer), `HAPStoreError`,
`HAPPermissions.init(rawValue:)`, `ServiceType.fullUUID`, public memberwise inits of `Pairing`/`HAPIdentity`/
`HAPResourceRequest`, `AccessoryServer.init(accessory:configuration:store:transport:advertiser:log:)` (the server's
logger, e.g. tagged with its camera's ID so the camera's own log shows its pairing, session and listener lines; the
contract initializer logs untagged, category "hap"), `HAPSessionHandle.zone` (W4 review round 4: the connection's IPv6
zone, `TCPConnection.zone`, which a link-local address a controller names in SetupEndpoints needs; a requirement with a
default, nil). Package-wide (`package`): `UnauthenticatedWarningLimiter` (`init`, `log(_:kind:from:level:to:)`;
HDS bounds its pre-hello log lines with it). Internal test hooks: `setTimings(_:)`, `setFailedPairSetupAttempts(_:)`,
`addPairingForTesting(controllerID:publicKey:)` (same effects as pair-setup M5, so tests skip SRP).

**Liveness and recovery (2026-10-03, hardening plan WS-C).** Every send of a connection's writer has a progress watchdog
(`HAPServerTimings.sendStallTimeout`, 15 s; `sendWatchingProgress`): a controller that vanished without a FIN or RST (Wi-Fi dropped,
the hub slept) cannot hold a connection, and what rides on it, forever. `AccessoryServer.relistenNow()` (a down listener listens again
at once, resetting the backoff: the network changed or the Mac woke), `restartListener(because:)` (closes a listener that runs but
does not answer and listens again after `listenerRestartSettle`, keeping the open connections), `dropStaleConnections(inactiveFor:)`
(verified connections silent for that long, default `staleConnectionLimit` 60 s; the wake path), `probeListener(timeout:)` (an
unauthenticated loopback `GET /accessories` must be refused with 470 in time), `advertisedTXT`, `advertisedName`.
`HAPHealthMonitor` (public actor; one per accessory) runs the loopback check, a Bonjour check through `ServiceBrowsing` (`id`, `c#`,
`sf` must match what was registered; two misses in a row register again; a browse that cannot run counts for nothing) and a
controller-liveness check (a paired accessory without a verified connection for 10 minutes is advertised again once and
`controllerSilenceNote` says so) every 30 s; `runOnce()` is one pass, tests move the clock. `c#` now also moves when the *values*
of the camera's Supported video/audio/RTP/recording/data-stream configurations change: the configuration hash is
`<structure>.<values>`, and an accessory without such characteristics keeps the plain structure hash (the first start after this
change bumps `c#` once for a camera, nothing else changes: identity, pairings and identifiers are untouched; the log line says why).
`FileHAPStore.loadIdentity()` falls back to the identity the process already read or saved when the Keychain refuses a read.

Event semantics beyond the contract's case list: when the listener fails while running, the server emits
`.advertisingFailed(message:localNetworkDenied: false)`, withdraws the advertisement, retries `listen` with backoff
(1 s doubling to 60 s; the configured port, else the previous port until it is refused as in use three times, then any
port), reports a restart failure once per distinct error (`localNetworkDenied: true` for `.localNetworkDenied`), and on
success emits `.listening(port:)` and `.advertising` again. Verified sessions stay open meanwhile. An advertising
failure other than Local Network denial (the first `advertise` throws; later, on the registration's `failures`, e.g.
DNS-SD "service not running" after mDNSResponder restarted, which drops the registration; a failed TXT update) emits
`.advertisingFailed(message:localNetworkDenied: false)`, withdraws the dead registration and advertises again with
backoff (1 s doubling to 60 s; a retry failure is reported only when it differs from the last one reported) until it
works, the server stops or `restartAdvertising()` takes over; on success `.advertising`. Local Network denial is
reported (`localNetworkDenied: true`) and not retried: the engine calls `restartAdvertising()` once access is granted.
When `start()` (or the first identity read) finds no identity but pairings in the state, those pairings are removed
(`HAPStore.loadOrCreateIdentity()`), `.unpaired` is emitted and `pairingsLostWithIdentity` counts them.

## Invariants

- Services: `Accessory.init` adds AccessoryInformation and ProtocolInformation (Version "1.1.0"); a bridged accessory's
  `services` (and its `/accessories` entry) leave that ProtocolInformation out — only the published accessory (aid 1)
  carries one, as in HAP-NodeJS (`Accessory.publish`).
- aid 1 = root; bridged aids ≥ 2 persisted by `stableKey`; accessories sharing a stable key get `key#2`, `key#3`… in
  bridge order (warning logged). AccessoryInformation is iid 1 on every accessory; all other iids come from one
  persisted counter keyed `serviceUUID[/subtype]` and `serviceKey/charUUID` (bridged: `key|` prefix). Persisted ids
  outside 2…2^53 are treated as corrupt and reassigned. More than 149 bridged accessories or 100 services per
  accessory (HomeKit limits) log a warning.
- `c#` = SHA-256 (`HAPCrypto.sha256`, swift-crypto) of the canonical value-free `/accessories` JSON; the first hash is only recorded (c# stays 1), later
  changes bump it (65535 → 1). Structure changes are debounced 1 s; TXT updates (pair/unpair/c#) are debounced 1 s.
- Before pair-verify only `POST /identify` (unpaired only), `POST /pair-setup`, `POST /pair-verify`; everything else →
  470 `{"status":-70401}`; another method on those three (or on `/pairings` after verify) → 400 `{"status":-70410}`.
  Unverified input is split one request at a time (head ≤ 8 KiB, body ≤ 16 KiB, else the connection closes), so bytes
  sent behind pair-verify M3 are decrypted with the new keys. After verify: frames ≤ 1024 plaintext bytes, LE length
  as AAD, per-direction counters; any decrypt failure, oversized frame or malformed HTTP closes the connection. A
  re-verify as a different controller drops the connection's subscriptions and timed write. Unknown aid.iid → -70409;
  ids beyond Int64 → 400 -70410.
- Timed writes: `/prepare` takes any non-zero integer `pid` up to 2^64-1 (also an integral double) and `ttl` > 0 ms;
  the next PUT with a `pid` consumes it, and only the same number before the expiry authorizes `tw` characteristics
  (anything else: -70410 for every entry). 0 and non-integers → 400 -70410.
- `/accessories` contacts read handlers only if the previous one was over 5 s ago, otherwise serves stored values
  (HAP-NodeJS). Control points (writable tlv8 without `ev`: SetupEndpoints, SelectedRTPStreamConfiguration,
  SetupDataStreamTransport) are per session: a controller's write, write response or read-handler result is never
  stored, and their read handler is asked on every `/accessories`, so one controller never sees another's request or
  read-back (SetupEndpoints' SRTP keys). Their `value` stays what the accessory set with `update`.
- Unverified connections: closed after 60 s without traffic; at most 32 (the least recently active one is closed).
  One pair-setup at a time (others get M2 Error 7 Busy until it finishes, its connection closes or it stalls for 60 s).
  The connection running pair-setup is closed only after 5 min without traffic while it holds the slot (between M2
  and M3 the user may be typing the setup code shown in the app; HAP-NodeJS has no idle limit here), and is never the
  one the cap closes. Any connection, verified or not: once 16 are open, each new one closes those without traffic for
  an hour (HAP-NodeJS); one whose write queue overflows is closed, and a pair-verify M4 that overflowed it starts no
  session.
- Identity: the identity (device ID, Ed25519 key, setup code) is in the `SecretStore`, everything else in the state.
  Pairings stored without their identity (a reset or lost Keychain, a data directory restored without it) belong to an
  identity no controller can reach: `loadOrCreateIdentity()` removes them (state saved before the new identity, so a
  failure never leaves a new identity next to them) and keeps the rest of the state; the server then advertises
  `sf=1` under the new device ID, accepts pair-setup, emits `.unpaired` and logs an error asking the user to remove the
  accessory from the Home app and add it again (research brief §4, "Keys missing"). `loadOrCreateIdentity()` and
  `replaceIdentity()` (a new identity and no pairings: the engine's Reset Pairing) run under a process-wide lock per
  `HAPStore.identityLockName` (`FileHAPStore`: its secret store account), so two stores over one identity (the engine's
  and the accessory server's) never both create one: the secret store would keep only the last write, and a server
  could run with an identity other than the stored one (review W4 round 3).
- Pairing changes (pair-setup M5, `/pairings` Add and Remove) are answered only once the store has saved them. If it
  cannot (a full disk, an unwritable data directory), the request is refused with kTLVError Unknown (M6, or State 2 on
  `/pairings`) and the pairings in memory stay as they were: no `.paired`/`.unpaired`, no TXT change, no session
  closed or re-permissioned. A relaunch never undoes a change a controller was told succeeded (HAP-NodeJS saves before
  it answers; review W4 round 4). Identifier and `c#` saves only log a failure; the next save that works writes them.
  Add Pairing applies a controller's new permissions to its open sessions at once (admin-only writes such as the
  camera's HomeKitCameraActive check the session's flag).
- Events: `EVENT/1.0`, coalesced 250 ms (newest first, identical queued values dropped), immediate for
  MotionDetected / ProgrammableSwitchEvent / ContactSensorState, never written while a request is in flight, never
  sent to the originating session. A connection whose write queue overflows (512 messages) is closed. Every stored
  value gets a per-characteristic sequence number; a change reported after a newer one was dispatched is dropped
  (concurrent `update` calls), except for ProgrammableSwitchEvent, where every event counts. Observers are called on
  the updating thread and may see concurrent updates out of order.
- Handlers: read/write warn at 3 s, fail -70408 at 9 s; `/resource` warn 8 s, fail 25 s (failure → 207 + status).
  `HandlerTimeout` is BridgeSupport's `withDeadline` (answers on time even if a handler ignores cancellation; the
  handler is cancelled and its late result dropped) and follows the request's cancellation: a cancelled request stops
  waiting at once and its handler is cancelled (-70408 too).
- SRP runs off the server actor; >100 failed proofs → MaxTries. Secrets (setup code, keys) are never logged.
- Controller identifiers reach the log only through `loggable(controllerID:)` (ASCII letters, digits and `-_.:`, else
  `?`; at most 64 characters). Warnings an unauthenticated peer can trigger at will (failed pair-verify M3, malformed
  input before verify, pair-setup after MaxTries) are logged at most once per minute per kind and remote address; the
  next one notes how many were dropped. So are the info lines connection churn causes: an idle unverified connection
  closed, pair-setup refused as Busy (per remote address), and an unverified connection closed for the cap (once per
  minute from any address, since every connect beyond the cap causes one). So is "Identify requested" (`POST /identify`
  needs no authentication while unpaired; per remote address); every identify still calls the `onIdentify` handler.

## References

Research brief §3.1–§3.4; HAP-NodeJS 2.2.3 `lib/{HAPServer.ts,Accessory.ts,Characteristic.ts,Service.ts,
Advertiser.ts,util/eventedhttp.ts,util/hapCrypto.ts,model/*.ts,CharacteristicDefinitions.ts,ServiceDefinitions.ts}`
(Apache-2.0; derived files carry the attribution header). Tests: `Tests/HAPTests` (loopback `HAPTestClient`).

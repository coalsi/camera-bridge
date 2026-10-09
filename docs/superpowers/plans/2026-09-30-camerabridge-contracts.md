# CameraBridge v1 — Module API Contracts

This document is the **source of truth for cross-module public APIs**. Every module agent implements its module to exactly these signatures. You may ADD public API. You may NOT rename, remove, or change the meaning of anything below without recording it in `docs/CONTRACT_CHANGES.md` (date, module, change, reason) — and a change that breaks another module must be avoided unless the orchestrator approves it.

Conventions (all modules):
- Swift 6 language mode, strict concurrency. Package code is nonisolated by default. Types crossing concurrency boundaries are `Sendable`. Prefer `actor` for stateful network components, `final class ... : Sendable` backed by `Mutex` (import Synchronization) for shared mutable model objects, value types elsewhere.
- Durations use `Duration`; wall-clock uses `Date`; media timestamps use `MediaTime`.
- No force unwraps on external input. All parsers throw typed errors on malformed input.
- Logging via `BridgeSupport.Log` only (never `print`). Never log passwords, keys, or URLs containing credentials (use `Redact.url`).
- Constants, TLV layouts, UUIDs and protocol rules: `docs/research/2026-09-30-research-brief-native.md` §3 is normative.

### Portability rule (owner decision 2026-09-30: keep a Raspberry Pi / Linux edition possible)
Every module except `PlatformApple` and the app target must be **portable Swift**: it may import only Foundation (or `FoundationEssentials`; + `FoundationNetworking` and `FoundationXML`, which hold URLSession and XMLParser on Linux, each under `#if canImport(<module>)`), Dispatch, Synchronization, Observation, `Crypto` (swift-crypto — on macOS this re-exports CryptoKit), BigInt, `os` (BridgeSupport's `Log` only, under `#if canImport(os)`), `CommonCrypto` (RTP's SRTP only, see below), and Darwin/Glibc/Musl under `#if canImport(<module>)` in the three BSD-socket files listed below — and only the package dependencies (`Crypto`, BigInt, `_CryptoExtras`) and restricted system modules (`CommonCrypto`, `os`) that the dependency graph below lists for it (SwiftPM would let a module import them transitively; `Tests/PortabilityTests` enforces the graph and the file restrictions below). **No** Apple-only framework outside `PlatformApple`: Network.framework, CryptoKit (use `import Crypto`), CoreMedia, CoreVideo, VideoToolbox, AudioToolbox, AVFoundation, Accelerate, CoreImage, ImageIO, Security, IOKit, AppKit, SwiftUI, dnssd. Platform services reach portable modules only through the protocols in BridgeSupport (`NetworkTransport`, `ServiceAdvertiser`, `SecretStore`, `NetworkChangeMonitoring`, `PowerManaging`) and MediaCore (`MediaCodecs`), injected by the caller. The only platform conditionals (`#if canImport(…)` / `#if os(…)`) in portable modules:
- the guarded `FoundationNetworking`, `FoundationXML` (CameraAdapters' `XMLTree`) and `os` imports above, and BridgeSupport's `Log` → `os.Logger` code under `#if canImport(os)`;
- `CommonCrypto` AES-CTR in RTP's SRTP (`#if canImport(CommonCrypto)`, only in `Sources/RTP/SRTP*`; else `_CryptoExtras` `AES._CTR`, linked only on Linux);
- Darwin/Glibc/Musl BSD-socket imports and calls in exactly three files: RTP's `UDPSocket` (RTP/SRTP media), CameraAdapters' `ONVIFDiscovery` (WS-Discovery multicast) and BridgeEngine's `StreamAddress` (`getifaddrs` / `inet_ntop` / `inet_pton` / `sysctl` route dump: the interface addresses a live stream's accessory address is chosen from, and whether this Mac is on a VPN); `PortabilityTests` rejects these imports in any other file (the third file is pending orchestrator approval: BridgeEngine W4 review row in docs/CONTRACT_CHANGES.md); the Camera Bridge OS daemon (`Sources/BridgeDaemon`, an executable's library: `Daemon.swift` and `DaemonMain.swift` for signals, `SystemD.swift` for the systemd notification socket, `RequestFileSystemControl.swift` for `rename`/`unlink`/`gethostname`/`uname` in the system request files) is the one other place, see its row in docs/CONTRACT_CHANGES.md;
- BridgeSupport's `AuthenticatingHTTPClient` accepts self-signed camera certificates only under `#if canImport(Darwin)` (FoundationNetworking has no server-trust challenge, so Linux keeps default TLS trust);
- `import PlatformApple` and the code using it under `#if os(macOS)` / `#if canImport(Darwin)`: BridgeEngine's `Environment.swift` and TestSupport (graph below).

Module dependency graph (a module may import only the modules listed for it):

```
BridgeSupport      → Crypto (swift-crypto; Digest MD5/SHA-256, ONVIF SHA-1) + (Foundation, Dispatch, Synchronization; FoundationNetworking, os under #if canImport)   portable
HAPCore            → BridgeSupport, BigInt, Crypto (swift-crypto)                    portable
HAP                → HAPCore, BridgeSupport                                          portable (transport/advertiser injected)
HDS                → HAP, HAPCore, BridgeSupport                                     portable
HAPCamera          → HAP, HDS, HAPCore, BridgeSupport                                portable
MediaCore          → BridgeSupport                                                   portable (codecs are protocols)
FMP4               → MediaCore                                                       portable
RTP                → MediaCore, BridgeSupport, Crypto (+CommonCrypto / _CryptoExtras) portable
RTSP               → RTP, MediaCore, BridgeSupport                                   portable (transport injected)
CameraAdapters     → RTSP, RTP, MediaCore, BridgeSupport                             portable
PlatformApple      → BridgeSupport, MediaCore + Network, VideoToolbox, AudioToolbox, CoreMedia, CoreVideo, CoreImage, CoreGraphics, CoreText, ImageIO, Accelerate (vDSP), Security, IOKit, dnssd (+ Foundation, Dispatch, Synchronization, Darwin)   macOS only
BridgeEngine       → all portable package modules (not Crypto/BigInt directly); PlatformApple only inside `#if canImport(Darwin)` in Environment.swift
TestSupport        → HAPCore, HAP, HDS, RTP, RTSP, MediaCore, FMP4, BridgeSupport, PlatformApple (inside `#if os(macOS)` / `#if canImport(Darwin)`) (test-only; never linked by the app)
BridgeWeb          → BridgeEngine, CameraAdapters, RTSP, MediaCore, BridgeSupport, Crypto (swift-crypto)   portable (HTTP server over the injected transport; Camera Bridge OS web interface)
BridgeDaemon       → BridgeWeb, BridgeEngine, CameraAdapters, BridgeSupport (+ Darwin/Glibc under #if canImport, in Sources/BridgeDaemon only: signals, sd_notify)   the `camerabridged` logic
camerabridged      → BridgeDaemon   executable
Test targets       → may import PlatformApple (to get a real transport/codecs on macOS) through the macOS-only dependency; test code using it or an Apple-only framework sits inside `#if os(macOS)` / `#if canImport(<framework>)` so the test targets still build on Linux
```
Package dependencies: `https://github.com/attaswift/BigInt.git` (MIT) and `https://github.com/apple/swift-crypto.git` from 3.0.0 (Apache-2.0; `_CryptoExtras` product only with `condition: .when(platforms: [.linux])`).

---

## BridgeSupport

```swift
// Logging
public enum LogLevel: Int, Sendable, Codable, Comparable, CaseIterable { case debug, info, notice, warning, error }
public struct LogEntry: Sendable, Identifiable, Equatable {
    public let id: UUID; public let date: Date; public let level: LogLevel
    public let category: String; public let message: String; public let cameraID: UUID?
}
public protocol LogSink: Sendable { func record(_ entry: LogEntry) }
public enum LogHub {
    public static func addSink(_ sink: any LogSink)          // thread-safe
    public static func removeAllSinks()
    public static var minimumLevel: LogLevel { get set }     // default .info
}
public struct Log: Sendable {
    public init(category: String, cameraID: UUID? = nil)
    public func debug(_ message: @autoclosure () -> String)
    public func info(_ message: @autoclosure () -> String)
    public func notice(_ message: @autoclosure () -> String)
    public func warning(_ message: @autoclosure () -> String)
    public func error(_ message: @autoclosure () -> String)
}   // writes to os.Logger(subsystem: "com.coreysilvia.CameraBridge", category:) and all LogHub sinks
public enum Redact {
    public static func url(_ url: URL) -> String             // strips user:password and password-like query items
    public static func string(_ s: String) -> String         // masks "password=...", "pwd=...", "token=..."
}

// Retry
public struct Backoff: Sendable {
    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(60), multiplier: Double = 2, jitter: Double = 0.2)
    public mutating func next() -> Duration
    public mutating func reset()
}

// Credentials & auth
public struct HTTPCredentials: Sendable, Hashable, Codable { public var username: String; public var password: String; public init(username: String, password: String) }
public struct DigestChallenge: Sendable, Equatable {
    public var realm: String; public var nonce: String; public var opaque: String?
    public var algorithm: String /* "MD5" default, "SHA-256" supported */; public var qop: [String]; public var stale: Bool
    public static func parse(_ wwwAuthenticate: String) -> DigestChallenge?    // accepts "Digest realm=..., nonce=..."
}
public struct DigestAuthenticator: Sendable {
    public init(credentials: HTTPCredentials)
    public mutating func authorization(for challenge: DigestChallenge, method: String, uri: String) -> String  // full header value "Digest ..."
}
public enum BasicAuth { public static func header(_ credentials: HTTPCredentials) -> String }

/// URLSession wrapper that answers Basic/Digest challenges with the given credentials (per-instance session + delegate).
/// Portable: uses delegate callbacks (no URLSession.AsyncBytes, which is Darwin-only).
public final class AuthenticatingHTTPClient: Sendable {
    public init(credentials: HTTPCredentials?, timeout: Duration = .seconds(10), allowSelfSignedTLS: Bool = true)
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Long-lived streaming body (e.g. Hikvision alertStream, HTTP-FLV). Chunks arrive as received; stream ends on EOF/error.
    public func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)
    public func invalidate()
}

// Platform service protocols (implemented in PlatformApple on macOS; SwiftNIO/Avahi/etc. later on Linux)
public protocol TCPConnection: AnyObject, Sendable {
    var id: UUID { get }
    var localAddress: String { get }          // IP literal of our side of the connection
    var remoteAddress: String { get }
    var isIPv6: Bool { get }
    func receive(maximumLength: Int) async throws -> Data?   // nil = orderly EOF
    func send(_ data: Data) async throws
    func close()
}
public protocol TCPListener: AnyObject, Sendable {
    var port: UInt16 { get }
    var connections: AsyncStream<any TCPConnection> { get }
    func close()
}
public protocol NetworkTransport: Sendable {
    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection
}
public enum TransportError: Error, Equatable, Sendable { case localNetworkDenied, connectionRefused, timedOut, closed, addressInUse, failed(String) }
public struct ServiceAdvertisement: Sendable, Equatable {
    public var name: String; public var type: String /* "_hap._tcp" */; public var port: UInt16; public var txt: [String: String]
    public init(name: String, type: String, port: UInt16, txt: [String: String])
}
public protocol AdvertisedService: AnyObject, Sendable {
    func updateTXT(_ txt: [String: String]) async throws
    var failures: AsyncStream<TransportError> { get }        // e.g. .localNetworkDenied (DNS-SD -65570)
    func cancel()
}
public protocol ServiceAdvertiser: Sendable {
    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService
}
public final class NullServiceAdvertiser: ServiceAdvertiser { public init() }   // tests / advertise=false
public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data?, account: String) throws        // nil deletes
}
public final class InMemorySecretStore: SecretStore { public init() }
public protocol NetworkChangeMonitoring: Sendable { var changes: AsyncStream<Void> { get } }   // path/interface changes
public final class NullNetworkChangeMonitor: NetworkChangeMonitoring { public init() }
public protocol PowerManaging: Sendable {
    func beginBackgroundActivity(reason: String)             // prevents App Nap (idle system sleep still allowed)
    func setKeepSystemAwake(_ awake: Bool, reason: String)
}
public final class NullPowerManager: PowerManaging { public init() }
public struct PlatformServices: Sendable {
    public var transport: any NetworkTransport
    public var advertiser: any ServiceAdvertiser
    public var secrets: any SecretStore
    public var networkChanges: any NetworkChangeMonitoring
    public var power: any PowerManaging
    public init(transport: any NetworkTransport, advertiser: any ServiceAdvertiser, secrets: any SecretStore,
                networkChanges: any NetworkChangeMonitoring, power: any PowerManaging)
}

// Minimal HTTP/1.1 message parsing/serialising (used by HAP server, webhook server, tests)
public struct HTTPHeaders: Sendable, Equatable, Sequence {
    public init(_ pairs: [(String, String)] = [])
    public subscript(name: String) -> String? { get set }      // case-insensitive
    public mutating func add(_ name: String, _ value: String)
    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]>
}
public struct HTTPRequestHead: Sendable, Equatable { public var method: String; public var target: String; public var version: String; public var headers: HTTPHeaders
    public var path: String { get }; public var queryItems: [URLQueryItem] { get } }
public struct HTTPResponseHead: Sendable, Equatable { public var version: String; public var status: Int; public var reason: String; public var headers: HTTPHeaders }
public struct HTTPRequestParser: Sendable {
    public init(maxBodySize: Int = 1 << 20)
    public mutating func feed(_ data: Data) throws -> [(head: HTTPRequestHead, body: Data)]   // Content-Length bodies; throws on malformed/oversize
}
public enum HTTPSerializer {
    public static func response(status: Int, reason: String? = nil, headers: HTTPHeaders, body: Data, version: String = "HTTP/1.1") -> Data
    public static func request(_ head: HTTPRequestHead, body: Data) -> Data
}

// Bytes
extension Data {
    public init?(hex: String); public var hexString: String { get }
}
public struct ByteReader: Sendable {
    public init(_ data: Data); public var remaining: Int { get }; public var isAtEnd: Bool { get }
    public mutating func readUInt8() throws -> UInt8
    public mutating func readUInt16BE() throws -> UInt16; public mutating func readUInt16LE() throws -> UInt16
    public mutating func readUInt24BE() throws -> UInt32
    public mutating func readUInt32BE() throws -> UInt32; public mutating func readUInt32LE() throws -> UInt32
    public mutating func readUInt64BE() throws -> UInt64; public mutating func readUInt64LE() throws -> UInt64
    public mutating func readBytes(_ count: Int) throws -> Data
    public mutating func skip(_ count: Int) throws
}
public struct ByteWriter: Sendable {
    public init(); public private(set) var data: Data
    public mutating func write(_ v: UInt8); public mutating func writeUInt16BE(_ v: UInt16); public mutating func writeUInt16LE(_ v: UInt16)
    public mutating func writeUInt24BE(_ v: UInt32); public mutating func writeUInt32BE(_ v: UInt32); public mutating func writeUInt32LE(_ v: UInt32)
    public mutating func writeUInt64BE(_ v: UInt64); public mutating func writeUInt64LE(_ v: UInt64); public mutating func write(_ d: Data)
}
public enum ByteError: Error, Equatable { case truncated(needed: Int, available: Int) }

// Time
public enum NTPTime {
    public static func timestamp(for date: Date) -> UInt64      // 32.32 fixed point since 1900
    public static func date(from ntp: UInt64) -> Date
}

// Async fan-out
public final class AsyncBroadcaster<Element: Sendable>: Sendable {
    public init(bufferingNewest: Int = 64)
    public func subscribe() -> AsyncStream<Element>             // each subscriber gets all subsequent elements
    public func yield(_ element: Element)
    public func finish()
    public var subscriberCount: Int { get }
}
```

## HAPCore

Uses `import Crypto` (swift-crypto; re-exports CryptoKit on macOS) — never `import CryptoKit`.

```swift
public enum TLV8 {
    public struct Item: Sendable, Equatable { public var type: UInt8; public var value: Data; public init(_ type: UInt8, _ value: Data) }
    public static func encode(_ items: [Item]) -> Data                          // splits values >255 into consecutive same-type items
    public static func decode(_ data: Data) throws(TLV8Error) -> [Item]         // merges consecutive same-type fragments
    public static func splitList(_ items: [Item], separator: UInt8 = 0xFF) -> [[Item]]
}
public enum TLV8Error: Error, Equatable { case truncated, missing(UInt8), invalidLength(UInt8) }
public struct TLVBuilder: Sendable {
    public init()
    public mutating func add(_ type: UInt8, _ value: Data)
    public mutating func add(_ type: UInt8, uint8: UInt8)
    public mutating func add(_ type: UInt8, uint16LE: UInt16)
    public mutating func add(_ type: UInt8, uint32LE: UInt32)
    public mutating func add(_ type: UInt8, uint64LE: UInt64)
    public mutating func add(_ type: UInt8, float32LE: Float)
    public mutating func add(_ type: UInt8, string: String)
    public mutating func add(_ type: UInt8, tlv: TLVBuilder)
    public mutating func addSeparator()
    public var items: [TLV8.Item] { get }
    public var data: Data { get }
}
public struct TLVReader: Sendable {
    public init(_ data: Data) throws(TLV8Error)
    public init(items: [TLV8.Item])
    public var items: [TLV8.Item] { get }
    public func data(_ type: UInt8) -> Data?                    // first item of type
    public func all(_ type: UInt8) -> [Data]
    public func uint8(_ type: UInt8) -> UInt8?
    public func uint16LE(_ type: UInt8) -> UInt16?
    public func uint32LE(_ type: UInt8) -> UInt32?              // accepts 1/2/4-byte encodings
    public func uint64LE(_ type: UInt8) -> UInt64?
    public func float32LE(_ type: UInt8) -> Float?
    public func string(_ type: UInt8) -> String?
    public func nested(_ type: UInt8) throws(TLV8Error) -> TLVReader?
    public func require(_ type: UInt8) throws(TLV8Error) -> Data
}

public enum HAPCrypto {
    public static func hkdfSHA512(inputKey: Data, salt: String, info: String, outputByteCount: Int = 32) -> Data
    public static func hkdfSHA512(inputKey: Data, salt: Data, info: String, outputByteCount: Int = 32) -> Data
    public static func nonce(label: String) -> Data                 // 4 zero bytes + 8 ASCII bytes (e.g. "PS-Msg05")
    public static func nonce(counter: UInt64) -> Data               // 4 zero bytes + UInt64 LE
    public static func chachaSeal(_ plaintext: Data, key: Data, nonce: Data, aad: Data = Data()) throws -> Data   // ciphertext || 16-byte tag
    public static func chachaOpen(_ sealed: Data, key: Data, nonce: Data, aad: Data = Data()) throws -> Data
}

public final class SRPServer {        // non-Sendable; used inside one actor
    public init(username: String = "Pair-Setup", password: String, salt: Data? = nil, privateValue: Data? = nil)
    public let salt: Data                                   // 16 bytes
    public var publicKey: Data { get }                      // B, 384 bytes
    public func setClientPublicKey(_ a: Data) throws(SRPError)
    public func verifyClientProof(_ m1: Data) throws(SRPError) -> Data   // returns M2
    public var sessionKey: Data? { get }                    // K (64 bytes) after setClientPublicKey
}
public final class SRPClient {        // for test controllers
    public init(username: String = "Pair-Setup", password: String, salt: Data, serverPublicKey: Data, privateValue: Data? = nil) throws(SRPError)
    public var publicKey: Data { get }                      // A
    public var proof: Data { get }                          // M1
    public var sessionKey: Data { get }                     // K
    public func verifyServerProof(_ m2: Data) -> Bool
}
public enum SRPError: Error, Equatable { case invalidPublicKey, proofMismatch, notReady }

public struct DeviceID: Sendable, Hashable, Codable, CustomStringConvertible {   // "AA:BB:CC:DD:EE:FF"
    public init?(_ string: String); public static func random() -> DeviceID; public var description: String { get }
}
public struct SetupCode: Sendable, Hashable, Codable, CustomStringConvertible {
    public init?(_ string: String)                           // accepts "12345678" or "123-45-678"
    public static func random() -> SetupCode                 // never trivial
    public var digits: String { get }                        // "12345678"
    public var formatted: String { get }                     // "123-45-678" (this is the SRP password)
    public var isTrivial: Bool { get }                       // all-same digits, 12345678, 87654321
    public var description: String { get }                   // formatted
}
public enum AccessoryCategory: UInt16, Sendable, Codable { case other = 1, bridge = 2, sensor = 10, ipCamera = 17, videoDoorbell = 18 }
public enum SetupPayload {
    public static func uri(code: SetupCode, setupID: String, category: AccessoryCategory) -> String   // "X-HM://..." (goldens in brief §3.3)
    public static func setupHash(setupID: String, deviceID: DeviceID) -> String                       // TXT "sh"
    public static func randomSetupID() -> String                                                       // 4 chars [0-9A-Z]
}
public struct HAPLongTermKey: Sendable {                     // Ed25519
    public init(); public init(rawRepresentation: Data) throws
    public var rawRepresentation: Data { get }; public var publicKey: Data { get }
    public func signature(for data: Data) throws -> Data
    public static func isValidSignature(_ signature: Data, for data: Data, publicKey: Data) -> Bool
}
```

## HAP

```swift
public enum HAPFormat: String, Sendable, Codable { case bool, uint8, uint16, uint32, uint64, int, float, string, tlv8, data }
public struct HAPPermissions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public static let pairedRead, pairedWrite, events, additionalAuthorization, timedWrite, hidden, writeResponse: HAPPermissions
    public var jsonStrings: [String] { get }                 // ["pr","pw","ev","aa","tw","hd","wr"]
}
public enum HAPUnit: String, Sendable { case celsius, percentage, arcdegrees, lux, seconds }
public enum HAPValue: Sendable, Hashable {
    case null, bool(Bool), int(Int64), uint(UInt64), float(Double), string(String), data(Data)   // tlv8 & data formats use .data
    public var boolValue: Bool? { get }; public var intValue: Int64? { get }; public var doubleValue: Double? { get }
    public var stringValue: String? { get }; public var dataValue: Data? { get }
}
public enum HAPStatus: Int, Error, Sendable {
    case success = 0
    case insufficientPrivileges = -70401, serviceCommunicationFailure = -70402, resourceBusy = -70403
    case readOnly = -70404, writeOnly = -70405, notificationNotSupported = -70406, outOfResource = -70407
    case operationTimedOut = -70408, resourceDoesNotExist = -70409, invalidValue = -70410
    case insufficientAuthorization = -70411, notAllowedInCurrentState = -70412
}
public struct CharacteristicType: Sendable, Hashable {
    public let uuid: String                    // short form ("22") for Apple-defined; full UUID otherwise
    public let name: String; public let format: HAPFormat; public let permissions: HAPPermissions
    public let unit: HAPUnit?; public let minValue: Double?; public let maxValue: Double?; public let minStep: Double?
    public let validValues: [Int]?; public let maxLength: Int?
    public init(uuid: String, name: String, format: HAPFormat, permissions: HAPPermissions, unit: HAPUnit? = nil,
                minValue: Double? = nil, maxValue: Double? = nil, minStep: Double? = nil, validValues: [Int]? = nil, maxLength: Int? = nil)
    public var fullUUID: String { get }        // "00000022-0000-1000-8000-0026BB765291"
    // Static constants for every characteristic listed in research brief §3.4 (named in lowerCamelCase,
    // e.g. .motionDetected, .programmableSwitchEvent, .setupEndpoints, .selectedCameraRecordingConfiguration,
    // .setupDataStreamTransport, .supportedDataStreamTransportConfiguration, .homeKitCameraActive, .recordingAudioActive,
    // .statusActive, .statusFault, .statusTampered, .occupancyDetected, .currentAmbientLightLevel, .currentTemperature,
    // .currentRelativeHumidity, .contactSensorState, .on, .mute, .volume, .name, .configuredName, .identify, .manufacturer,
    // .model, .serialNumber, .firmwareRevision, .hardwareRevision, .version, .active, .streamingStatus, ...)
}
public struct ServiceType: Sendable, Hashable {
    public let uuid: String; public let name: String
    public let required: [CharacteristicType]; public let optional: [CharacteristicType]
    public init(uuid: String, name: String, required: [CharacteristicType], optional: [CharacteristicType] = [])
    // Static constants: .accessoryInformation, .protocolInformation, .cameraRTPStreamManagement, .cameraRecordingManagement,
    // .cameraOperatingMode, .dataStreamTransportManagement, .microphone, .speaker, .doorbell, .statelessProgrammableSwitch,
    // .motionSensor, .occupancySensor, .lightSensor, .temperatureSensor, .humiditySensor, .contactSensor, .battery, .switch
}

public protocol HAPSessionHandle: AnyObject, Sendable {
    var id: UUID { get }
    var controllerID: String { get }
    var isAdmin: Bool { get }
    var sharedSecret: Data { get }             // pair-verify X25519 shared secret (used for HDS key derivation)
    var localAddress: String { get }           // IP of our interface this connection arrived on
    var remoteAddress: String { get }
    var isIPv6: Bool { get }
    func onClose(_ handler: @escaping @Sendable () -> Void)   // called once when the HAP connection closes
}
public struct HAPRequestContext: Sendable {
    public let session: any HAPSessionHandle
    public init(session: any HAPSessionHandle)
}

public final class Characteristic: Sendable {
    public init(_ type: CharacteristicType, value: HAPValue? = nil)      // default value derived from format/min
    public let type: CharacteristicType
    public var iid: UInt64 { get }                                       // assigned when the accessory is published
    public var value: HAPValue { get }
    public var validValuesOverride: [Int]? { get set }
    public var minValueOverride: Double? { get set }; public var maxValueOverride: Double? { get set }
    /// Updates the stored value and notifies subscribed controllers if it changed (always notifies for
    /// event-type characteristics: ProgrammableSwitchEvent). `origin` = session that caused it (not notified).
    public func update(_ value: HAPValue, origin: UUID? = nil)
    public func sendEvent(_ value: HAPValue)                             // always notifies (stateless)
    public func onRead(_ handler: @escaping @Sendable (HAPRequestContext?) async throws(HAPStatus) -> HAPValue)
    /// Handler returns an optional write-response value (for "r":true writes, e.g. SetupDataStreamTransport).
    public func onWrite(_ handler: @escaping @Sendable (HAPValue, HAPRequestContext) async throws(HAPStatus) -> HAPValue?)
    public func addObserver(_ observer: @escaping @Sendable (HAPValue, UUID?) -> Void) -> ObserverToken
    public func removeObserver(_ token: ObserverToken)
}
public struct ObserverToken: Sendable, Hashable { }
public final class Service: Sendable {
    public init(_ type: ServiceType, name: String? = nil, subtype: String? = nil)   // creates required characteristics (+ Name if name given)
    public let type: ServiceType; public let subtype: String?
    public var iid: UInt64 { get }
    public var characteristics: [Characteristic] { get }
    public var isPrimary: Bool { get set }; public var isHidden: Bool { get set }
    public var linkedServices: [Service] { get }
    @discardableResult public func characteristic(_ type: CharacteristicType) -> Characteristic   // returns existing or adds it
    public func existingCharacteristic(_ type: CharacteristicType) -> Characteristic?
    public func addLinkedService(_ service: Service)
}
public struct AccessoryInfo: Sendable, Codable, Hashable {
    public var name: String; public var manufacturer: String; public var model: String
    public var serialNumber: String; public var firmwareRevision: String; public var hardwareRevision: String?
    public init(name: String, manufacturer: String, model: String, serialNumber: String, firmwareRevision: String, hardwareRevision: String? = nil)
}
public struct HAPResourceRequest: Sendable { public var type: String; public var width: Int; public var height: Int; public var aid: UInt64?; public var reason: Int? }
public final class Accessory: Sendable {
    public init(info: AccessoryInfo, category: AccessoryCategory)          // adds AccessoryInformation (iid 1) + ProtocolInformation
    public let category: AccessoryCategory
    public var info: AccessoryInfo { get }
    public var aid: UInt64 { get }                                          // 1 when published directly; ≥2 when bridged
    public var services: [Service] { get }
    public var bridgedAccessories: [Accessory] { get }                     // non-empty only for bridges
    public var informationService: Service { get }
    @discardableResult public func addService(_ service: Service) -> Service
    public func removeService(_ service: Service)
    public func addBridgedAccessory(_ accessory: Accessory)                 // aid assigned stably (persisted by name/serial key)
    public func removeBridgedAccessory(_ accessory: Accessory)
    public func onIdentify(_ handler: @escaping @Sendable () -> Void)
    public func onResourceRequest(_ handler: @escaping @Sendable (HAPResourceRequest, HAPRequestContext) async throws(HAPStatus) -> Data)
    public func setReachable(_ reachable: Bool)                              // bridged accessories only
}

// Persistence
public struct Pairing: Sendable, Codable, Hashable { public var identifier: String; public var publicKey: Data; public var isAdmin: Bool }
public struct HAPIdentity: Sendable, Codable {
    public var deviceID: DeviceID; public var longTermKey: Data   // Ed25519 raw private key
    public var setupCode: SetupCode; public var setupID: String
    public static func generate() -> HAPIdentity
}
public struct HAPPersistentState: Sendable, Codable {
    public var pairings: [Pairing]; public var configNumber: UInt32; public var configHash: String
    public var iids: [String: UInt64]; public var nextIID: UInt64; public var aids: [String: UInt64]; public var nextAID: UInt64
    public var extras: [String: Data]                               // for controllers (e.g. selected recording configuration)
    public init()
}
public protocol HAPStore: Sendable {
    func loadIdentity() throws -> HAPIdentity?
    func saveIdentity(_ identity: HAPIdentity) throws
    func loadState() throws -> HAPPersistentState?
    func saveState(_ state: HAPPersistentState) throws
    func deleteAll() throws
}
public final class InMemoryHAPStore: HAPStore { public init() }
public final class FileHAPStore: HAPStore {
    /// JSON files in `directory` (0700/0600). `secretStore` (BridgeSupport.SecretStore) holds the identity incl. long-term key — e.g. Keychain.
    public init(directory: URL, secretStore: any SecretStore, account: String)
}
public typealias HAPSecretStore = SecretStore            // compatibility alias; InMemorySecretStore lives in BridgeSupport

// Server
public struct AccessoryServerConfiguration: Sendable {
    public var port: UInt16                    // 0 = ephemeral
    public var advertise: Bool                 // false in some tests
    public var serviceName: String             // Bonjour instance name
    public var loopbackOnly: Bool              // tests: bind 127.0.0.1
    public init(port: UInt16 = 0, advertise: Bool = true, serviceName: String, loopbackOnly: Bool = false)
}
public enum AccessoryServerEvent: Sendable, Equatable {
    case listening(port: UInt16)
    case advertising
    case advertisingFailed(message: String, localNetworkDenied: Bool)
    case paired(controllerID: String)
    case unpaired
    case sessionsChanged(count: Int)
}
public actor AccessoryServer {
    public init(accessory: Accessory, configuration: AccessoryServerConfiguration, store: any HAPStore,
                transport: any NetworkTransport, advertiser: any ServiceAdvertiser)
    public func start() async throws
    public func stop() async
    public nonisolated var events: AsyncStream<AccessoryServerEvent> { get }   // multi-subscriber (AsyncBroadcaster)
    public var port: UInt16? { get }
    public var isPaired: Bool { get }
    public var setupCode: SetupCode { get throws }
    public var setupURI: String { get throws }
    public var deviceID: DeviceID { get throws }
    public var sessionCount: Int { get }
    public func resetPairings() async throws                  // clears pairings, sf=1, closes sessions, re-advertises
    public func configurationDidChange() async                 // recompute config hash → bump c# if changed → re-advertise
    public func store(extra data: Data?, forKey key: String) async throws   // HAPPersistentState.extras
    public func extra(forKey key: String) async -> Data?
}
```

## HDS

```swift
public struct HDSDictionary: Sendable, Equatable, Sequence {        // ordered (encoding order matters for goldens)
    public init(_ pairs: [(String, HDSValue)] = [])
    public subscript(key: String) -> HDSValue? { get set }
    public var pairs: [(String, HDSValue)] { get }
}
public indirect enum HDSValue: Sendable, Equatable {
    case null, bool(Bool), int(Int64), float(Double), string(String), data(Data), uuid(UUID), date(Date)
    case array([HDSValue]), dictionary(HDSDictionary)
}
public enum HDSCodec {
    public static func encode(_ value: HDSValue) throws -> Data
    public static func decode(_ data: Data) throws -> HDSValue
}
public enum HDSStatus: Int64, Sendable { case success = 0, outOfMemory, timeout, headerError, payloadError, missingProtocol, protocolSpecificError }
public enum HDSProtocolReason: Int64, Sendable, Error { case normal = 0, notAllowed, busy, cancelled, unsupported, unexpectedFailure, timeout, badData, protocolError, invalidConfiguration }
public struct HDSMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case event, request(id: Int64), response(id: Int64, status: HDSStatus) }
    public var kind: Kind; public var protocolName: String; public var topic: String; public var body: HDSDictionary
}
public enum HDSFrameCodec {                                  // public so TestSupport can build a client
    public static func deriveKeys(sharedSecret: Data, controllerKeySalt: Data, accessoryKeySalt: Data) -> (accessoryToController: Data, controllerToAccessory: Data)
    public static func encodePayload(_ message: HDSMessage) throws -> Data
    public static func decodePayload(_ payload: Data) throws -> HDSMessage
    public static func sealFrame(_ payload: Data, key: Data, counter: UInt64) throws -> Data     // [0x01][len24][ct][tag]
    public static func openFrame(header: Data, body: Data, key: Data, counter: UInt64) throws -> Data
}
public actor DataStreamConnection {
    public nonisolated let id: UUID
    public nonisolated let hapSessionID: UUID
    public func sendEvent(protocol: String, topic: String, body: HDSDictionary) async throws
    public func sendResponse(to request: HDSMessage, status: HDSStatus, body: HDSDictionary) async throws
    public func sendRequest(protocol: String, topic: String, body: HDSDictionary, timeout: Duration = .seconds(10)) async throws -> HDSMessage
    public func close() async
    public nonisolated var isClosed: Bool { get }
    public nonisolated func onClose(_ handler: @escaping @Sendable () -> Void)
}
public actor DataStreamServer {
    public init(transport: any NetworkTransport, loopbackOnly: Bool = false)
    /// For SetupDataStreamTransport. Starts the listener lazily; session expires after 10 s if unused.
    public func prepareSession(controllerKeySalt: Data, session: any HAPSessionHandle) async throws -> (port: UInt16, accessoryKeySalt: Data)
    /// Handles every request/event for `protocolName` on any connection (e.g. "dataSend"). "control/hello" is internal.
    public func setHandler(protocol protocolName: String, _ handler: @escaping @Sendable (HDSMessage, DataStreamConnection) async -> Void)
    public func stop() async
    public var connectionCount: Int { get }
}
```

## HAPCamera

```swift
public enum H264Profile: UInt8, Sendable, Codable, CaseIterable { case baseline = 0, main = 1, high = 2 }
public enum H264Level: UInt8, Sendable, Codable, CaseIterable { case level3_1 = 0, level3_2 = 1, level4_0 = 2 }
public struct VideoResolution: Sendable, Hashable, Codable { public var width: Int; public var height: Int; public var fps: Int; public init(_ width: Int, _ height: Int, _ fps: Int) }
public enum StreamingAudioCodec: UInt8, Sendable, Codable { case pcmu = 0, pcma = 1, aacELD = 2, opus = 3, msbc = 4, amr = 5, amrWB = 6 }
public enum StreamingSampleRate: UInt8, Sendable, Codable { case khz8 = 0, khz16 = 1, khz24 = 2; public var hertz: Int { get } }
public enum RecordingAudioCodec: UInt8, Sendable, Codable { case aacLC = 0, aacELD = 1 }
public enum RecordingSampleRate: UInt8, Sendable, Codable { case khz8 = 0, khz16, khz24, khz32, khz44_1, khz48; public var hertz: Int { get } }
public enum SRTPCryptoSuite: UInt8, Sendable, Codable { case aesCm128HmacSha1_80 = 0, aesCm256HmacSha1_80 = 1, none = 2 }
public struct SRTPParameters: Sendable, Equatable { public var suite: SRTPCryptoSuite; public var masterKey: Data; public var masterSalt: Data }

public struct CameraStreamingOptions: Sendable {
    public var resolutions: [VideoResolution]; public var profiles: [H264Profile]; public var levels: [H264Level]
    public var audioCodecs: [(codec: StreamingAudioCodec, sampleRates: [StreamingSampleRate])]   // v1: [(.opus, [.khz16, .khz24])]
    public var twoWayAudio: Bool
    public var cryptoSuites: [SRTPCryptoSuite]                                                   // v1: [.aesCm128HmacSha1_80]
    public init(resolutions: [VideoResolution], profiles: [H264Profile] = [.main], levels: [H264Level] = [.level3_1, .level3_2, .level4_0],
                audioCodecs: [(codec: StreamingAudioCodec, sampleRates: [StreamingSampleRate])] = [(.opus, [.khz16, .khz24])],
                twoWayAudio: Bool, cryptoSuites: [SRTPCryptoSuite] = [.aesCm128HmacSha1_80])
}
public struct CameraRecordingOptions: Sendable, Equatable {
    public var prebufferLengthMs: Int; public var fragmentLengthMs: Int
    public var resolutions: [VideoResolution]; public var profiles: [H264Profile]; public var levels: [H264Level]
    public var audioCodec: RecordingAudioCodec; public var audioSampleRates: [RecordingSampleRate]; public var audioChannels: Int
    public init(prebufferLengthMs: Int = 4000, fragmentLengthMs: Int = 4000, resolutions: [VideoResolution],
                profiles: [H264Profile] = [.baseline, .main, .high], levels: [H264Level] = [.level3_1, .level3_2, .level4_0],
                audioCodec: RecordingAudioCodec = .aacLC, audioSampleRates: [RecordingSampleRate] = [.khz32], audioChannels: Int = 1)
}
public struct CameraRecordingConfiguration: Sendable, Codable, Equatable {
    public var prebufferLengthMs: Int; public var eventTriggers: UInt64; public var fragmentLengthMs: Int
    public var videoProfile: H264Profile; public var videoLevel: H264Level; public var videoBitrateKbps: Int; public var iFrameIntervalMs: Int
    public var resolution: VideoResolution
    public var audioCodec: RecordingAudioCodec; public var audioChannels: Int; public var audioSampleRate: RecordingSampleRate; public var audioMaxBitrateKbps: Int
}
public enum SnapshotReason: Int, Sendable { case periodic = 0, event = 1 }
public struct SnapshotRequest: Sendable { public var width: Int; public var height: Int; public var reason: SnapshotReason? }
public struct PrepareStreamRequest: Sendable {
    public var sessionID: UUID; public var controllerAddress: String; public var isIPv6: Bool
    public var controllerVideoPort: UInt16; public var controllerAudioPort: UInt16
    public var videoSRTP: SRTPParameters; public var audioSRTP: SRTPParameters
    public var localAddress: String                        // our interface address for this HAP connection
}
public struct PrepareStreamResponse: Sendable {
    public var accessoryAddress: String; public var videoPort: UInt16; public var audioPort: UInt16
    public var videoSSRC: UInt32; public var audioSSRC: UInt32
    public var videoSRTP: SRTPParameters; public var audioSRTP: SRTPParameters      // usually echo the controller's
    public init(accessoryAddress: String, videoPort: UInt16, audioPort: UInt16, videoSSRC: UInt32, audioSSRC: UInt32, videoSRTP: SRTPParameters, audioSRTP: SRTPParameters)
}
public struct SelectedVideoParameters: Sendable, Equatable {
    public var profile: H264Profile; public var level: H264Level; public var resolution: VideoResolution
    public var payloadType: UInt8; public var controllerSSRC: UInt32; public var maxBitrateKbps: Int; public var rtcpIntervalSeconds: Double; public var mtu: Int
}
public struct SelectedAudioParameters: Sendable, Equatable {
    public var codec: StreamingAudioCodec; public var channels: Int; public var sampleRate: StreamingSampleRate; public var packetTimeMs: Int
    public var payloadType: UInt8; public var controllerSSRC: UInt32; public var maxBitrateKbps: Int; public var rtcpIntervalSeconds: Double
    public var comfortNoisePayloadType: UInt8?
}
public enum StreamRequest: Sendable {
    case start(sessionID: UUID, video: SelectedVideoParameters, audio: SelectedAudioParameters?)
    case reconfigure(sessionID: UUID, video: SelectedVideoParameters)
    case stop(sessionID: UUID)
}
public protocol CameraStreamingDelegate: AnyObject, Sendable {
    func snapshot(_ request: SnapshotRequest) async throws -> Data                         // JPEG
    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse
    func handleStreamRequest(_ request: StreamRequest) async throws
}
public struct RecordingPacket: Sendable { public var data: Data; public var isLast: Bool; public init(data: Data, isLast: Bool) }
public protocol CameraRecordingDelegate: AnyObject, Sendable {
    func updateRecordingActive(_ active: Bool) async
    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) async
    func updateRecordingAudioActive(_ active: Bool) async
    /// First packet MUST be the fMP4 initialization segment; subsequent packets are whole moof+mdat fragments.
    func recordingStream(streamID: Int) async throws -> AsyncThrowingStream<RecordingPacket, any Error>
    func acknowledgeStream(streamID: Int) async
    func closeRecordingStream(streamID: Int, reason: HDSProtocolReason?) async
}
public struct CameraOperatingState: Sendable, Equatable {
    public var homeKitCameraActive: Bool; public var eventSnapshotsActive: Bool; public var periodicSnapshotsActive: Bool
    public var recordingActive: Bool; public var recordingAudioActive: Bool; public var nightVision: Bool?; public var indicatorEnabled: Bool?
}
public struct CameraControllerConfiguration: Sendable {
    public var streamCount: Int                       // CameraRTPStreamManagement services (v1: 2)
    public var streaming: CameraStreamingOptions
    public var recording: CameraRecordingOptions?     // nil = no HKSV
    public var isDoorbell: Bool
    public var supportsNightVisionControl: Bool; public var supportsIndicatorControl: Bool
    public init(streamCount: Int = 2, streaming: CameraStreamingOptions, recording: CameraRecordingOptions?, isDoorbell: Bool,
                supportsNightVisionControl: Bool = false, supportsIndicatorControl: Bool = false)
}
public final class CameraController: Sendable {
    public init(configuration: CameraControllerConfiguration, streamingDelegate: any CameraStreamingDelegate,
                recordingDelegate: (any CameraRecordingDelegate)?, dataStreamServer: DataStreamServer)
    /// Adds all services (RTP mgmt ×N, Microphone, Speaker if twoWayAudio, recording mgmt, operating mode,
    /// data stream transport, MotionSensor linked to recording, Doorbell primary if isDoorbell) and wires handlers,
    /// including the accessory's /resource snapshot handler.
    public func install(on accessory: Accessory, server: AccessoryServer) async
    public func setMotionDetected(_ detected: Bool)
    public func ringDoorbell()                        // ProgrammableSwitchEvent 0 (+ caller also pulses motion)
    public func setStreamingAvailable(_ available: Bool)
    public func setSensorStatus(active: Bool, fault: Bool, tampered: Bool)
    public var operatingState: CameraOperatingState { get }
    public nonisolated var operatingStateChanges: AsyncStream<CameraOperatingState> { get }
    public var motionService: Service? { get }
    public var activeRecordingStreams: Int { get }
    public var activeLiveStreams: Int { get }
}
public enum RecordingEventTrigger { public static let motion: UInt64 = 1 << 0; public static let doorbell: UInt64 = 1 << 1 }
```

## MediaCore

```swift
public enum VideoCodec: String, Sendable, Codable { case h264, hevc }
public enum AudioCodec: String, Sendable, Codable { case aac, aacELD, opus, pcmu, pcma, linearPCM }
public struct MediaTime: Sendable, Hashable, Comparable, Codable {
    public var value: Int64; public var timescale: Int32
    public init(value: Int64, timescale: Int32)
    public static func seconds(_ s: Double, timescale: Int32 = 90_000) -> MediaTime
    public var seconds: Double { get }
    public func converted(to timescale: Int32) -> MediaTime
    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime   // result in lhs.timescale
    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime
}
public struct VideoFormat: Sendable, Hashable {
    public var codec: VideoCodec; public var width: Int; public var height: Int
    public var parameterSets: [Data]          // H.264: [SPS, PPS]; HEVC: [VPS, SPS, PPS]; raw NAL units, no start codes
    public var profile: UInt8; public var profileCompatibility: UInt8; public var level: UInt8   // from SPS (H.264 avcC bytes)
    public init(codec: VideoCodec, width: Int, height: Int, parameterSets: [Data], profile: UInt8 = 0, profileCompatibility: UInt8 = 0, level: UInt8 = 0)
    public static func h264(sps: Data, pps: Data) -> VideoFormat?          // parses SPS for size/profile/level
    public static func hevc(vps: Data, sps: Data, pps: Data) -> VideoFormat?
    // makeFormatDescription() lives in PlatformApple (CoreMedia is not portable)
}
public struct AudioFormat: Sendable, Hashable {
    public var codec: AudioCodec; public var sampleRate: Int; public var channels: Int
    public var audioSpecificConfig: Data?     // AAC
    public init(codec: AudioCodec, sampleRate: Int, channels: Int, audioSpecificConfig: Data? = nil)
    public var samplesPerFrame: Int { get }   // AAC 1024, AAC-ELD 480/512, Opus 960 (20 ms @48k equivalent), G.711 variable (0)
    public static func aacLC(sampleRate: Int, channels: Int) -> AudioFormat   // builds the 2-byte AudioSpecificConfig
}
public struct EncodedVideoFrame: Sendable {
    public var format: VideoFormat
    public var nalUnits: [Data]               // access unit NALs, no start codes/length prefixes, parameter sets & AUD removed
    public var isKeyframe: Bool
    public var pts: MediaTime                 // 90 kHz, monotonic per source session (pending, docs/CONTRACT_CHANGES.md B-frame row: presentation time; `dts ?? pts` is the monotonic one)
    public var dts: MediaTime?                // nil when equal to pts
    public var wallClock: Date
    public init(format: VideoFormat, nalUnits: [Data], isKeyframe: Bool, pts: MediaTime, dts: MediaTime? = nil, wallClock: Date)
    public var lengthPrefixedData: Data { get }    // AVCC/HVCC 4-byte length prefixes
    public var annexBData: Data { get }
}
public struct EncodedAudioFrame: Sendable {
    public var format: AudioFormat
    public var data: Data                     // one codec access unit (raw AAC AU without ADTS, one Opus packet, G.711 bytes)
    public var pts: MediaTime                 // timescale = sampleRate
    public var sampleCount: Int
    public var wallClock: Date
    public init(format: AudioFormat, data: Data, pts: MediaTime, sampleCount: Int, wallClock: Date)
}
public enum MediaSample: Sendable {
    case video(EncodedVideoFrame), audio(EncodedAudioFrame)
    public var wallClock: Date { get }
}
public protocol MediaSource: AnyObject, Sendable {
    var displayName: String { get }
    /// Connects and starts delivering samples. The stream finishes (throwing) on disconnect; call again to reconnect.
    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error>
    func stop() async
}
public struct StreamInfo: Sendable, Codable, Hashable {
    public var url: URL                       // never contains credentials
    public var videoCodec: VideoCodec?; public var width: Int?; public var height: Int?; public var fps: Double?
    public var audioCodec: AudioCodec?; public var audioSampleRate: Int?; public var audioChannels: Int?
    public init(url: URL, videoCodec: VideoCodec? = nil, width: Int? = nil, height: Int? = nil, fps: Double? = nil,
                audioCodec: AudioCodec? = nil, audioSampleRate: Int? = nil, audioChannels: Int? = nil)
}

// NAL / SPS utilities
public enum NALUnits {
    public static func splitAnnexB(_ data: Data) -> [Data]
    public static func splitLengthPrefixed(_ data: Data, lengthSize: Int = 4) -> [Data]
    public static func h264Type(_ nal: Data) -> UInt8                 // nal[0] & 0x1F
    public static func hevcType(_ nal: Data) -> UInt8                 // (nal[0] >> 1) & 0x3F
    public static func removeEmulationPrevention(_ data: Data) -> Data
}
public struct H264SPS: Sendable, Equatable {
    public var profileIDC: UInt8; public var constraintFlags: UInt8; public var levelIDC: UInt8
    public var width: Int; public var height: Int; public var frameRate: Double?
    public static func parse(_ sps: Data) -> H264SPS?
}
public struct HEVCSPS: Sendable, Equatable { public var width: Int; public var height: Int; public var generalProfileIDC: UInt8; public var generalLevelIDC: UInt8; public static func parse(_ sps: Data) -> HEVCSPS? }

// Fan-out + prebuffer
public enum SubscriptionStart: Sendable { case live, nextKeyframe, prebuffer(Duration) }
public struct MediaSubscription: Sendable {
    public let samples: AsyncStream<MediaSample>
    public let cancel: @Sendable () -> Void
}
public actor MediaHub {
    public init(retention: Duration = .seconds(12))
    public func ingest(_ sample: MediaSample)
    /// .prebuffer(d): starts at the newest keyframe whose wallClock ≤ now − d (or the oldest keyframe held), then live. (pending, docs/CONTRACT_CHANGES.md MediaCore review-fixes row: the newest keyframe that arrived at least d ago, on the hub's ContinuousClock)
    public func subscribe(from start: SubscriptionStart = .nextKeyframe, bufferLimit: Int = 900) -> MediaSubscription
    public var videoFormat: VideoFormat? { get }
    public var audioFormat: AudioFormat? { get }
    public var lastKeyframe: EncodedVideoFrame? { get }
    public var measuredFrameRate: Double? { get }
    public var measuredGOPDuration: Duration? { get }
    public func discontinuity()                 // source reconnected: clears ring, keeps subscribers
    public var subscriberCount: Int { get }
}

// Codec abstraction (portable protocols; Apple implementation = PlatformApple.AppleMediaCodecs)
public struct VideoEncoderSettings: Sendable, Equatable {
    public var width: Int; public var height: Int; public var fps: Int; public var bitrateKbps: Int
    public var profile: EncoderProfile; public var level: EncoderLevel; public var keyframeInterval: Duration; public var realtime: Bool
    public enum EncoderProfile: Sendable, Equatable { case baseline, main, high }
    public enum EncoderLevel: Sendable, Equatable { case level3_1, level3_2, level4_0, level4_1, level5_1, auto }
    public init(width: Int, height: Int, fps: Int, bitrateKbps: Int, profile: EncoderProfile = .main, level: EncoderLevel = .level4_0,
                keyframeInterval: Duration = .seconds(4), realtime: Bool = true)
}
public struct AudioEncoderSettings: Sendable, Equatable {
    public var codec: AudioCodec; public var sampleRate: Int; public var channels: Int; public var bitrate: Int?
    public init(codec: AudioCodec, sampleRate: Int, channels: Int = 1, bitrate: Int? = nil)
}
public struct GrayImage: Sendable, Equatable { public var width: Int; public var height: Int; public var pixels: [UInt8]; public init(width: Int, height: Int, pixels: [UInt8]) }
/// A decoded picture. Apple implementation wraps CVPixelBuffer.
public protocol DecodedVideoFrame: Sendable {
    var width: Int { get }
    var height: Int { get }
    var pts: MediaTime { get }
    func grayThumbnail(maxWidth: Int) -> GrayImage?          // luma, downscaled keeping aspect (for motion detection)
}
public protocol VideoDecoding: AnyObject, Sendable {
    func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)?
    func invalidate()
}
public protocol VideoEncoding: AnyObject, Sendable {
    func encode(_ frame: any DecodedVideoFrame, wallClock: Date, forceKeyframe: Bool) async throws -> [EncodedVideoFrame]
    func invalidate()
}
public protocol VideoTranscoding: AnyObject, Sendable {       // decode → scale → encode H.264
    func transcode(_ frame: EncodedVideoFrame) async throws -> [EncodedVideoFrame]
    func requestKeyframe()
    func updateBitrate(kbps: Int)
    func invalidate()
}
public protocol AudioTranscoding: AnyObject, Sendable {       // AAC/AAC-ELD/Opus/G.711/PCM ↔ AAC-LC/AAC-ELD/Opus/G.711
    var outputFormat: AudioFormat { get }
    func transcode(_ frame: EncodedAudioFrame) throws -> [EncodedAudioFrame]
    func flush() throws -> [EncodedAudioFrame]
}
public protocol MediaCodecs: Sendable {
    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame]
    /// Demo camera / tests: moving test pattern (+ optional tone), H.264 at the given fps/GOP.
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                             audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource
}
extension MediaCodecs {
    /// Decodes a keyframe with a fresh decoder and encodes JPEG.
    public func jpeg(fromKeyframe frame: EncodedVideoFrame, maxWidth: Int?, maxHeight: Int?) async throws -> Data
}
public enum G711 {                                            // pure Swift
    public static func decodeMuLaw(_ data: Data) -> [Int16]; public static func encodeMuLaw(_ samples: [Int16]) -> Data
    public static func decodeALaw(_ data: Data) -> [Int16];  public static func encodeALaw(_ samples: [Int16]) -> Data
}
public enum MediaCodecError: Error, Equatable { case unsupported(String), sessionFailed(Int32), noFrame }
```

## PlatformApple (macOS only — the ONLY module allowed to import Apple-only frameworks)

```swift
public final class AppleNetworkTransport: NetworkTransport { public init() }        // Network.framework NWListener/NWConnection;
                                                                                    // maps .waiting(.localNetworkDenied)/-65570 → TransportError.localNetworkDenied
public final class DNSSDServiceAdvertiser: ServiceAdvertiser { public init() }     // dns_sd DNSServiceRegister + TXT updates; -65570 → .localNetworkDenied
public final class KeychainSecretStore: SecretStore { public init(service: String = "com.coreysilvia.CameraBridge") }  // generic password, file-based keychain
public final class NWPathNetworkChangeMonitor: NetworkChangeMonitoring { public init() }
public final class ApplePowerManager: PowerManaging { public init() }             // ProcessInfo.beginActivity + IOPMAssertion
public final class AppleMediaCodecs: MediaCodecs { public init() }                 // VideoToolbox, AudioToolbox, CoreImage/ImageIO
public struct PixelBufferFrame: DecodedVideoFrame, @unchecked Sendable { public let pixelBuffer: CVPixelBuffer; public let pts: MediaTime }
extension VideoFormat { public func makeFormatDescription() throws -> CMVideoFormatDescription }
extension AudioFormat { public func makeFormatDescription() throws -> CMAudioFormatDescription }
public enum ApplePlatform { public static func services() -> PlatformServices }   // all of the above wired together
```

## FMP4

```swift
public struct FMP4Configuration: Sendable {
    public var video: VideoFormat
    public var audio: AudioFormat?            // AAC-LC only (esds from ES_Descriptor)
    public var videoTimescale: Int32          // 90000
    public var writeProducerReferenceTime: Bool   // prft before moof, flags 0 (HEVC/HKSV3; off for classic)
    public init(video: VideoFormat, audio: AudioFormat?, videoTimescale: Int32 = 90_000, writeProducerReferenceTime: Bool = false)
}
public struct FMP4Muxer: Sendable {
    public init(configuration: FMP4Configuration) throws
    public func initializationSegment() -> Data               // ftyp + moov(mvhd, trak×n with avc1/hvc1 + avcC/hvcC, mp4a + esds, mvex/trex)
    /// One moof (one traf per track, ONE trun per traf, tfhd default-base-is-moof) + mdat.
    /// video.first must be a keyframe. tfdt is rebased so the first fragment of this muxer starts at 0.
    public mutating func fragment(video: [EncodedVideoFrame], audio: [EncodedAudioFrame]) throws -> Data
}
public struct GOPFragmenter: Sendable {                        // groups samples into keyframe-aligned fragments
    public init(targetDuration: Duration)
    /// Returns completed fragments (each starts with a keyframe). A fragment closes at the next keyframe once ≥ targetDuration,
    /// or at every keyframe if GOP ≥ targetDuration.
    public mutating func push(_ sample: MediaSample) -> [(video: [EncodedVideoFrame], audio: [EncodedAudioFrame])]
    public mutating func flush() -> (video: [EncodedVideoFrame], audio: [EncodedAudioFrame])?
}
public struct MP4Box: Sendable { public var type: String; public var offset: Int; public var size: Int; public var children: [MP4Box] }
public enum MP4BoxReader { public static func parse(_ data: Data) throws -> [MP4Box] }   // recursive for container boxes
```

## RTP

```swift
public struct RTPPacket: Sendable, Equatable {
    public var marker: Bool; public var payloadType: UInt8; public var sequenceNumber: UInt16; public var timestamp: UInt32; public var ssrc: UInt32
    public var csrcs: [UInt32]; public var extensionProfile: UInt16?; public var extensionData: Data?; public var payload: Data
    public init(marker: Bool = false, payloadType: UInt8, sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data)
    public init(parsing data: Data) throws
    public func serialized() -> Data
    public static func isRTCP(_ data: Data) -> Bool                 // payload type 200–204 (RTCP mux)
}
public enum RTCPPacket: Sendable, Equatable {
    case senderReport(ssrc: UInt32, ntp: UInt64, rtpTimestamp: UInt32, packetCount: UInt32, octetCount: UInt32)
    case receiverReport(ssrc: UInt32)
    case bye(ssrcs: [UInt32])
    case pictureLossIndication(senderSSRC: UInt32, mediaSSRC: UInt32)
    case fullIntraRequest(senderSSRC: UInt32, mediaSSRC: UInt32)
    case other(type: UInt8)
    public static func parseCompound(_ data: Data) throws -> [RTCPPacket]
    public func serialized() -> Data
}
public struct H264Packetizer: Sendable {
    public init(payloadType: UInt8, ssrc: UInt32, maxPacketSize: Int = 1200, initialSequence: UInt16 = .random(in: 0...UInt16.max))
    /// STAP-A(SPS,PPS) before every keyframe, single-NAL when it fits, else FU-A; marker on the last packet of the AU.
    public mutating func packetize(_ frame: EncodedVideoFrame, rtpTimestamp: UInt32) -> [RTPPacket]
}
public struct AudioPacketizer: Sendable {           // Opus: one frame per packet; AAC-ELD: RFC 3640 AU header section
    public init(codec: AudioCodec, payloadType: UInt8, ssrc: UInt32, initialSequence: UInt16 = .random(in: 0...UInt16.max))
    public mutating func packetize(_ frame: EncodedAudioFrame, rtpTimestamp: UInt32) -> RTPPacket
}
public struct SRTPContext: Sendable {                 // AES_CM_128_HMAC_SHA1_80 (RFC 3711), key derivation rate 0; AES-CTR via CommonCrypto on Darwin, _CryptoExtras on Linux; HMAC via Crypto
    public init(masterKey: Data, masterSalt: Data) throws
    public mutating func protectRTP(_ packet: Data) throws -> Data
    public mutating func unprotectRTP(_ packet: Data) throws -> Data
    public mutating func protectRTCP(_ packet: Data) throws -> Data
    public mutating func unprotectRTCP(_ packet: Data) throws -> Data
}
public enum SRTPError: Error, Equatable { case authenticationFailed, malformed, replay }
public struct SocketAddress: Sendable, Hashable, CustomStringConvertible { public var host: String; public var port: UInt16; public init(host: String, port: UInt16) }
public final class UDPSocket: Sendable {                 // BSD socket + DispatchSource
    public static func bind(host: String? = nil, port: UInt16 = 0, ipv6: Bool = false) throws -> UDPSocket
    public var localPort: UInt16 { get }
    public func send(_ data: Data, to address: SocketAddress) throws
    public var datagrams: AsyncStream<(data: Data, from: SocketAddress)> { get }
    public func close()
}
public struct LiveVideoParameters: Sendable {
    public var payloadType: UInt8; public var ssrc: UInt32; public var srtp: (key: Data, salt: Data); public var maxPacketSize: Int
    public var rtcpInterval: Duration
    public init(payloadType: UInt8, ssrc: UInt32, srtpKey: Data, srtpSalt: Data, maxPacketSize: Int = 1200, rtcpInterval: Duration = .milliseconds(500))
}
public struct LiveAudioParameters: Sendable {
    public var codec: AudioCodec /* .opus or .aacELD */; public var payloadType: UInt8; public var ssrc: UInt32
    public var srtp: (key: Data, salt: Data); public var rtpClockRate: Int; public var packetTime: Duration; public var rtcpInterval: Duration
    public init(codec: AudioCodec, payloadType: UInt8, ssrc: UInt32, srtpKey: Data, srtpSalt: Data, rtpClockRate: Int, packetTime: Duration, rtcpInterval: Duration = .milliseconds(500))
}
public enum LiveStreamEndReason: Sendable, Equatable { case stopped, controllerTimeout, socketError(String), sourceEnded }
public actor LiveStreamSession {
    public init(controller: SocketAddress /* host only; ports below */, videoPort: UInt16, audioPort: UInt16,
                videoSocket: UDPSocket, audioSocket: UDPSocket?, video: LiveVideoParameters, audio: LiveAudioParameters?,
                controllerTimeout: Duration = .seconds(30))
    public func start(video: AsyncStream<EncodedVideoFrame>, audio: AsyncStream<EncodedAudioFrame>?)
    public func stop()
    public nonisolated var returnAudio: AsyncStream<EncodedAudioFrame> { get }   // decrypted, depacketized audio from the controller
    public nonisolated var keyframeRequests: AsyncStream<Void> { get }           // PLI/FIR from controller
    public func waitForEnd() async -> LiveStreamEndReason
}
```

## RTSP

```swift
public struct RTSPConfiguration: Sendable {
    public var url: URL                         // no credentials in URL
    public var credentials: HTTPCredentials?
    public var requestBackchannel: Bool         // ONVIF "Require: www.onvif.org/ver20/backchannel"
    public var timeout: Duration
    public var userAgent: String
    public init(url: URL, credentials: HTTPCredentials?, requestBackchannel: Bool = false, timeout: Duration = .seconds(10), userAgent: String = "CameraBridge/1.0")
}
public struct RTSPTrack: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case video, audio, backchannel }
    public var kind: Kind; public var control: String; public var payloadType: UInt8; public var encoding: String
    public var clockRate: Int; public var channels: Int; public var fmtp: [String: String]
}
public struct RTSPSessionInfo: Sendable {
    public var tracks: [RTSPTrack]; public var videoFormat: VideoFormat?; public var audioFormat: AudioFormat?
    public var backchannelFormat: AudioFormat?
}
public actor RTSPClient {
    public init(configuration: RTSPConfiguration, transport: any NetworkTransport)
    public func connect() async throws -> RTSPSessionInfo                       // OPTIONS, DESCRIBE (auth), SETUP (TCP interleaved)
    public func play() async throws -> AsyncThrowingStream<MediaSample, any Error>   // PLAY + keepalive; depacketized samples
    public func sendBackchannel(_ frame: EncodedAudioFrame) async throws        // requires backchannel track
    public func close() async                                                   // TEARDOWN
}
public enum RTSPError: Error, Equatable { case unauthorized, notFound, badStatus(Int), protocolError(String), timeout, noVideoTrack, unsupportedCodec(String) }
public final class RTSPMediaSource: MediaSource { public init(configuration: RTSPConfiguration, displayName: String, transport: any NetworkTransport) }
public final class HTTPFLVMediaSource: MediaSource { public init(url: URL, credentials: HTTPCredentials?, displayName: String) }   // uses AuthenticatingHTTPClient.stream
public struct SDPSession: Sendable { public static func parse(_ sdp: String) throws -> SDPSession; public var media: [SDPMedia] }
public struct SDPMedia: Sendable { public var type: String; public var port: Int; public var formats: [UInt8]; public var attributes: [(String, String?)] ; public var direction: String? }
```

## CameraAdapters

```swift
public enum CameraVendor: String, Sendable, Codable, CaseIterable { case hikvision, reolink, onvif, rtsp, demo }
public enum DetectedObjectKind: String, Sendable, Codable, CaseIterable { case person, vehicle, animal, package, face }
public enum CameraEvent: Sendable, Equatable {
    case motion(Bool)
    case object(DetectedObjectKind, Bool)
    case doorbellPressed
    case tamper(Bool)
    case dayNight(isNight: Bool)
    case digitalInput(id: String, active: Bool)
    case temperature(celsius: Double)
    case humidity(percent: Double)
    case audioAlarm(Bool)
    case eventChannel(connected: Bool)
    case authenticationFailed            // camera rejected credentials (added 2026-09-30)
}
public enum CameraEventKind: String, Sendable, Codable, CaseIterable { case motion, person, vehicle, animal, package, face, doorbell, tamper, dayNight, digitalInput, temperature, humidity, audioAlarm }
public struct CameraEndpoint: Sendable, Codable, Hashable {
    public var host: String; public var httpPort: Int; public var rtspPort: Int; public var onvifPort: Int?; public var useHTTPS: Bool
    public init(host: String, httpPort: Int = 80, rtspPort: Int = 554, onvifPort: Int? = nil, useHTTPS: Bool = false)
}
public struct CameraCapabilities: Sendable, Codable, Equatable {
    public var events: Set<CameraEventKind>; public var twoWayAudio: Bool; public var isDoorbell: Bool; public var snapshotAPI: Bool
    public var nightVisionControl: Bool; public var indicatorControl: Bool
}
public struct CameraProbeResult: Sendable, Codable, Equatable {
    public var vendor: CameraVendor; public var manufacturer: String; public var model: String; public var serialNumber: String; public var firmware: String
    public var mainStream: StreamInfo?; public var subStream: StreamInfo?; public var capabilities: CameraCapabilities
}
public protocol CameraEventSource: Sendable {
    /// Self-reconnecting (Backoff). Emits .eventChannel(connected:) on (dis)connect.
    func events() -> AsyncStream<CameraEvent>
    func stop() async
}
public protocol TalkbackSink: Sendable {
    var inputFormat: AudioFormat { get }        // what `send` expects (e.g. PCMU 8 kHz mono)
    func open() async throws
    func send(_ frame: EncodedAudioFrame) async throws
    func close() async
}
public protocol CameraDriver: Sendable {
    var vendor: CameraVendor { get }
    func probe() async throws -> CameraProbeResult
    func makeEventSource() -> (any CameraEventSource)?
    func snapshot() async throws -> Data?                       // JPEG from the camera API, nil if unsupported
    func makeTalkbackSink() -> (any TalkbackSink)?
}
public enum CameraDrivers {
    public static func make(vendor: CameraVendor, endpoint: CameraEndpoint, credentials: HTTPCredentials?,
                            mainStreamURL: URL?, subStreamURL: URL?, transport: any NetworkTransport) -> any CameraDriver
    /// Tries Hikvision ISAPI, Reolink API, then ONVIF; nil if none answer.
    public static func detectVendor(endpoint: CameraEndpoint, credentials: HTTPCredentials?) async -> CameraVendor?
}
public struct DiscoveredCamera: Sendable, Hashable, Codable { public var host: String; public var name: String?; public var hardware: String?; public var xAddrs: [URL] }
public enum ONVIFDiscovery { public static func discover(timeout: Duration = .seconds(3)) async -> [DiscoveredCamera] }   // BSD UDP multicast (portable)
public actor SoftMotionDetector {
    public init(sensitivity: Double /* 0...1 */, analysisWidth: Int = 320)
    /// Feed luma thumbnails (from DecodedVideoFrame.grayThumbnail; any rate, internally sampled ~4 fps).
    /// Returns true/false on state transitions, nil otherwise.
    public func process(_ image: GrayImage, at time: Date) -> Bool?
}
public actor WebhookServer {
    public init(port: UInt16, token: String, loopbackOnly: Bool = false, transport: any NetworkTransport)
    public func start() async throws
    public func stop() async
    public nonisolated var events: AsyncStream<(cameraID: UUID, event: CameraEvent)> { get }   // POST /cameras/<uuid>/(motion|motion/stop|doorbell|person|...)
}
```

## BridgeEngine

```swift
public enum CameraKind: String, Sendable, Codable, CaseIterable { case camera, doorbell }
public enum MotionSource: String, Sendable, Codable, CaseIterable { case cameraEvents, softMotion, webhook }
public struct SensorOptions: Sendable, Codable, Equatable {
    public var person = false, vehicle = false, animal = false, package = false
    public var dayNight = false, digitalInputs = false, temperature = false, humidity = false
    public init()
}
public struct CameraConfiguration: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID; public var name: String; public var kind: CameraKind; public var vendor: CameraVendor
    public var endpoint: CameraEndpoint; public var username: String
    public var mainStreamURL: URL?; public var subStreamURL: URL?          // no credentials
    public var motionSource: MotionSource; public var motionSensitivity: Double; public var motionHoldSeconds: Int
    public var sensors: SensorOptions; public var audioEnabled: Bool; public var twoWayAudio: Bool
    public var hapPort: UInt16; public var isEnabled: Bool
    public var manufacturer: String; public var model: String; public var serialNumber: String; public var firmware: String
    public var capabilities: CameraCapabilities?
    public init(id: UUID = UUID(), name: String, kind: CameraKind, vendor: CameraVendor, endpoint: CameraEndpoint, username: String)
}
public struct BridgeSettings: Sendable, Codable, Equatable {
    public var webhookEnabled: Bool; public var webhookPort: UInt16; public var webhookToken: String
    public var keepMacAwake: Bool; public var sensorsBridgePort: UInt16; public var logLevel: LogLevel; public var basePort: UInt16
    public init()
}
public struct CredentialStore: Sendable {                   // camera passwords on top of the platform SecretStore
    public init(secrets: any SecretStore)                    // accounts "camera.<uuid>"
    public func password(for cameraID: UUID) throws -> String?
    public func setPassword(_ password: String?, for cameraID: UUID) throws
}

public enum ConnectionState: Sendable, Equatable { case idle, connecting, online, offline(String), disabled }
public struct CameraStatus: Sendable, Identifiable, Equatable {
    public var id: UUID; public var name: String; public var kind: CameraKind; public var vendor: CameraVendor
    public var connection: ConnectionState; public var eventChannelConnected: Bool
    public var videoSummary: String?            // "H.264 1920×1080 · 20 fps"
    public var isPaired: Bool; public var setupCode: String; public var setupURI: String; public var hapPort: UInt16?
    public var motionActive: Bool; public var recordingEnabled: Bool; public var recordingNow: Bool; public var liveViewers: Int
    public var lastEvent: String?; public var lastEventDate: Date?; public var lastError: String?
}
public struct SensorsBridgeStatus: Sendable, Equatable { public var isPaired: Bool; public var setupCode: String; public var setupURI: String; public var accessoryCount: Int }
public enum EngineState: Sendable, Equatable { case stopped, starting, running, paused, failed(String) }
public enum LocalNetworkAccess: Sendable, Equatable { case unknown, granted, denied }
public struct BridgeEnvironment: Sendable {
    public var dataDirectory: URL               // Application Support/CameraBridge (container when sandboxed)
    public var platform: PlatformServices       // transport, advertiser, secrets, network changes, power
    public var codecs: any MediaCodecs
    public var loopbackOnly: Bool               // tests
    public var advertise: Bool                  // tests may disable Bonjour
    public init(dataDirectory: URL, platform: PlatformServices, codecs: any MediaCodecs, loopbackOnly: Bool = false, advertise: Bool = true)
    #if canImport(Darwin)
    public static func live() -> BridgeEnvironment             // ApplePlatform.services() + AppleMediaCodecs, Application Support dir
    public static func testing(directory: URL) -> BridgeEnvironment   // Apple transport/codecs, InMemorySecretStore, loopback, no advertising
    #endif
}
@MainActor @Observable
public final class BridgeEngine {
    public init(environment: BridgeEnvironment)
    public static func preview() -> BridgeEngine                 // static fake data for SwiftUI previews; never starts networking
    public private(set) var state: EngineState
    public private(set) var cameras: [CameraStatus]
    public private(set) var configurations: [CameraConfiguration]
    public private(set) var sensorsBridge: SensorsBridgeStatus?
    public private(set) var localNetworkAccess: LocalNetworkAccess
    public private(set) var recentLogs: [LogEntry]                // newest last, capped at 1000
    public var settings: BridgeSettings { get }
    public func start() async
    public func stop() async
    public func pause() async
    public func resume() async
    public func updateSettings(_ settings: BridgeSettings) async throws
    public func addCamera(_ configuration: CameraConfiguration, password: String?) async throws
    public func updateCamera(_ configuration: CameraConfiguration, password: String?) async throws   // nil = unchanged
    public func removeCamera(id: UUID) async
    public func resetPairing(cameraID: UUID) async throws
    public func resetSensorsBridgePairing() async throws
    public func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String,
                            mainStreamURL: URL?, subStreamURL: URL?) async throws -> CameraProbeResult
    public func discoverCameras() async -> [DiscoveredCamera]
    public func snapshot(cameraID: UUID) async -> Data?
    public func checkLocalNetworkAccess(host: String?) async -> LocalNetworkAccess
    public func triggerTestMotion(cameraID: UUID) async          // developer/demo aid
    public func systemDidWake() async                            // App forwards NSWorkspace.didWakeNotification (AppKit stays in the app target)
}
```

BridgeEngine must not import AppKit/SwiftUI; the app target owns sleep/wake notifications and forwards them. Network path changes arrive via `PlatformServices.networkChanges`.

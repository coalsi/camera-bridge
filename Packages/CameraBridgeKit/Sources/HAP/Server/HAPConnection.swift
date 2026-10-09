// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// The encrypted frame layer follows HAP-NodeJS util/hapCrypto.ts (layerEncrypt/layerDecrypt) and the per-connection
// event queue follows util/eventedhttp.ts (HAPConnection).

import BridgeSupport
import Dispatch
import Foundation
import HAPCore
import Synchronization

/// Timings of the accessory server (tests shorten them).
struct HAPServerTimings: Sendable {
    /// Characteristic read/write handlers: warn after `handlerWarning`, fail with -70408 after `handlerTimeout` in total.
    var handlerWarning: Duration
    var handlerTimeout: Duration
    /// `/resource` (snapshot) handlers.
    var resourceWarning: Duration
    var resourceTimeout: Duration
    /// Non-immediate events are collected for this long before one `EVENT/1.0` message is written.
    var eventCoalescing: Duration
    /// Structure changes are collected for this long before the configuration hash is recomputed.
    var configurationDebounce: Duration
    /// TXT record updates are collected for this long.
    var advertisementDebounce: Duration
    /// After the listener fails, listening again is retried after this delay, doubling up to the maximum.
    var listenerRetryDelay: Duration
    var listenerRetryMaximumDelay: Duration
    /// After advertising failed (other than Local Network denial), advertising again is retried after this delay,
    /// doubling up to the maximum.
    var advertisingRetryDelay: Duration
    var advertisingRetryMaximumDelay: Duration
    /// A connection that has not completed pair-verify is closed after this long without traffic.
    var unverifiedIdleTimeout: Duration
    /// The connection running pair-setup (waiting for M3 while the user types the setup code, or for M5) is closed only
    /// after this long without traffic, while it holds the pair-setup slot.
    var pairSetupIdleTimeout: Duration
    /// Unverified connections beyond this count close the least recently active one.
    var maximumUnverifiedConnections: Int
    /// A pair-setup that has not progressed for this long no longer blocks other controllers (which get Busy until then).
    var pairSetupTimeout: Duration
    /// Once this many connections are open, each new one closes those without traffic for `maximumIdleTime` (HAP-NodeJS).
    var connectionPruneThreshold: Int
    var maximumIdleTime: Duration
    /// A write the transport has not completed for this long means the controller is gone without a FIN or RST (its
    /// receive window closed, Wi-Fi dropped, the Mac slept mid-send): the connection is closed, which frees what it held
    /// (a stream session, the HDS connection and the recording slot behind it).
    var sendStallTimeout: Duration
    /// `dropStaleConnections` (the wake path) closes verified connections that sent nothing for this long.
    var staleConnectionLimit: Duration
    /// `restartListener` waits this long after closing a running listener before it listens on the same port again (the
    /// platform releases the port a moment after `close()`; listening at once would find it taken and fall back to a
    /// different port, which controllers would have to find again).
    var listenerRestartSettle: Duration

    init(handlerWarning: Duration = .seconds(3), handlerTimeout: Duration = .seconds(9), resourceWarning: Duration = .seconds(8),
         resourceTimeout: Duration = .seconds(25), eventCoalescing: Duration = .milliseconds(250), configurationDebounce: Duration = .seconds(1),
         advertisementDebounce: Duration = .seconds(1), listenerRetryDelay: Duration = .seconds(1), listenerRetryMaximumDelay: Duration = .seconds(60),
         advertisingRetryDelay: Duration = .seconds(1), advertisingRetryMaximumDelay: Duration = .seconds(60),
         unverifiedIdleTimeout: Duration = .seconds(60), pairSetupIdleTimeout: Duration = .seconds(300), maximumUnverifiedConnections: Int = 32,
         pairSetupTimeout: Duration = .seconds(60), connectionPruneThreshold: Int = 16, maximumIdleTime: Duration = .seconds(3600),
         sendStallTimeout: Duration = .seconds(15), staleConnectionLimit: Duration = .seconds(60),
         listenerRestartSettle: Duration = .milliseconds(300)) {
        self.handlerWarning = handlerWarning
        self.handlerTimeout = handlerTimeout
        self.resourceWarning = resourceWarning
        self.resourceTimeout = resourceTimeout
        self.eventCoalescing = eventCoalescing
        self.configurationDebounce = configurationDebounce
        self.advertisementDebounce = advertisementDebounce
        self.listenerRetryDelay = listenerRetryDelay
        self.listenerRetryMaximumDelay = listenerRetryMaximumDelay
        self.advertisingRetryDelay = advertisingRetryDelay
        self.advertisingRetryMaximumDelay = advertisingRetryMaximumDelay
        self.unverifiedIdleTimeout = unverifiedIdleTimeout
        self.pairSetupIdleTimeout = pairSetupIdleTimeout
        self.maximumUnverifiedConnections = maximumUnverifiedConnections
        self.pairSetupTimeout = pairSetupTimeout
        self.connectionPruneThreshold = connectionPruneThreshold
        self.maximumIdleTime = maximumIdleTime
        self.sendStallTimeout = sendStallTimeout
        self.staleConnectionLimit = staleConnectionLimit
        self.listenerRestartSettle = listenerRestartSettle
    }
}

struct CharacteristicKey: Hashable, Sendable {
    var aid: UInt64
    var iid: UInt64
}

enum HAPFrameError: Error, Equatable {
    case oversizedFrame(Int)
    case authenticationFailed
}

/// Outbound encrypted frames: `[u16 LE length][ChaCha20-Poly1305(plaintext ≤ 1024)][tag]`, AAD = length bytes,
/// nonce = 4 zero bytes ‖ LE64(counter).
struct HAPFrameEncryptor {
    static let maximumPlaintext = 1024
    let key: Data
    private(set) var counter: UInt64 = 0

    init(key: Data) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        var out = Data()
        var offset = plaintext.startIndex
        repeat {
            let end = min(offset + Self.maximumPlaintext, plaintext.endIndex)
            let chunk = Data(plaintext[offset..<end])
            let aad = Data([UInt8(chunk.count & 0xFF), UInt8(chunk.count >> 8)])
            out.append(aad)
            out.append(try HAPCrypto.chachaSeal(chunk, key: key, nonce: HAPCrypto.nonce(counter: counter), aad: aad))
            counter += 1
            offset = end
        } while offset < plaintext.endIndex
        return out
    }
}

/// Inbound encrypted frames (buffers partial frames across reads). Any failure is fatal for the connection.
struct HAPFrameDecryptor {
    let key: Data
    private(set) var counter: UInt64 = 0
    private var buffer = Data()

    init(key: Data) {
        self.key = key
    }

    /// Buffers received ciphertext.
    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Decrypts the next complete frame; nil = more bytes needed.
    mutating func nextFrame() throws(HAPFrameError) -> Data? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8
        guard length <= HAPFrameEncryptor.maximumPlaintext else { throw .oversizedFrame(length) }
        guard buffer.count >= 2 + length + 16 else { return nil }
        let aad = Data(buffer[start..<(start + 2)])
        let sealed = Data(buffer[(start + 2)..<(start + 2 + length + 16)])
        let plaintext: Data
        do {
            plaintext = try HAPCrypto.chachaOpen(sealed, key: key, nonce: HAPCrypto.nonce(counter: counter), aad: aad)
        } catch {
            throw .authenticationFailed
        }
        counter += 1
        buffer = Data(buffer[(start + 2 + length + 16)...])
        return plaintext
    }

    /// Removes and returns the bytes not yet decrypted (they belong to the next session after a re-verify).
    mutating func takeBuffered() -> Data {
        defer { buffer = Data() }
        return buffer
    }

    /// Buffers `data` and decrypts every complete frame.
    mutating func open(_ data: Data) throws(HAPFrameError) -> Data {
        append(data)
        var plaintext = Data()
        while let frame = try nextFrame() { plaintext.append(frame) }
        return plaintext
    }
}

/// Splits plaintext requests off the byte stream until pair-verify completes, one request at a time: the bytes after
/// pair-verify M3 may already be encrypted with the new session keys and must never reach the HTTP parser as plaintext.
/// Also bounds what an unverified peer can make the server buffer (pairing TLVs are well under 1 KB).
enum PlaintextRequestFraming {
    static let maximumHeadSize = 8 * 1024
    static let maximumBodySize = 16 * 1024

    enum Failure: Error, Equatable {
        case headTooLarge
        case bodyTooLarge
        case invalidContentLength
    }

    private static let terminator = Data("\r\n\r\n".utf8)

    /// Byte length of the first complete request (head + Content-Length body) in `buffer`; nil = incomplete.
    static func firstRequestLength(in buffer: Data) throws(Failure) -> Int? {
        guard let end = buffer.firstRange(of: terminator) else {
            if buffer.count > maximumHeadSize { throw .headTooLarge }
            return nil
        }
        let headLength = end.lowerBound - buffer.startIndex
        guard headLength <= maximumHeadSize else { throw .headTooLarge }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var bodyLength = 0
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let length = Int(value) else {
                throw .invalidContentLength
            }
            guard length <= maximumBodySize else { throw .bodyTooLarge }
            bodyLength = max(bodyLength, length)
        }
        let total = headLength + terminator.count + bodyLength
        return buffer.count >= total ? total : nil
    }
}

/// An HTTP response the server writes.
struct HAPResponse {
    var status: Int
    var headers: HTTPHeaders
    var body: Data

    static let hapJSON = "application/hap+json"
    static let pairingTLV = "application/pairing+tlv8"

    static func json(_ status: Int, _ json: HAPJSON) -> HAPResponse {
        HAPResponse(status: status, headers: HTTPHeaders([("Content-Type", hapJSON)]), body: json.serialized())
    }

    /// `{"status": <HAP status>}`.
    static func status(_ status: Int, _ hapStatus: HAPStatus) -> HAPResponse {
        json(status, ["status": .int(Int64(hapStatus.rawValue))])
    }

    static func tlv(_ status: Int, _ builder: TLVBuilder) -> HAPResponse {
        HAPResponse(status: status, headers: HTTPHeaders([("Content-Type", pairingTLV)]), body: builder.data)
    }

    /// `{State: state, Error: error}`.
    static func pairingError(state: UInt8, error: PairingError, status: Int = 200) -> HAPResponse {
        var builder = TLVBuilder()
        builder.add(PairingTLV.state, uint8: state)
        builder.add(PairingTLV.error, uint8: error.rawValue)
        return tlv(status, builder)
    }

    static let noContent = HAPResponse(status: 204, headers: HTTPHeaders(), body: Data())

    func serialized() -> Data {
        HTTPSerializer.response(status: status, headers: headers, body: body)
    }
}

/// Pairing TLV8 types (research brief §3.2).
enum PairingTLV {
    static let method: UInt8 = 0x00
    static let identifier: UInt8 = 0x01
    static let salt: UInt8 = 0x02
    static let publicKey: UInt8 = 0x03
    static let proof: UInt8 = 0x04
    static let encryptedData: UInt8 = 0x05
    static let state: UInt8 = 0x06
    static let error: UInt8 = 0x07
    static let signature: UInt8 = 0x0A
    static let permissions: UInt8 = 0x0B
}

enum PairingError: UInt8 {
    case unknown = 1, authentication = 2, backoff = 3, maxPeers = 4, maxTries = 5, unavailable = 6, busy = 7
}

/// Runs CPU-heavy work (SRP modular exponentiation) on a Dispatch queue instead of blocking a Swift-concurrency
/// cooperative thread or the server actor.
func offloadComputation<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

/// The accessory side of one SRP exchange, usable off the server actor (the modular exponentiations take long enough
/// in Debug builds that they would stall event delivery to other controllers).
final class SRPSession: Sendable {
    let salt: Data
    let publicKey: Data
    private let server: Mutex<SRPServer>

    init(password: String) {
        let server = SRPServer(password: password)
        salt = server.salt
        publicKey = server.publicKey
        self.server = Mutex(server)
    }

    /// Sets A and checks M1; returns M2.
    func verify(clientPublicKey: Data, clientProof: Data) throws(SRPError) -> Data {
        try server.withLock { server throws(SRPError) -> Data in
            try server.setClientPublicKey(clientPublicKey)
            return try server.verifyClientProof(clientProof)
        }
    }

    var sessionKey: Data? { server.withLock { $0.sessionKey } }
}

/// One TCP connection of the accessory server. Confined to the `AccessoryServer` actor (not Sendable).
final class HAPConnection {
    enum PairSetupStage {
        case awaitingM3(SRPSession)
        case awaitingM5(SRPSession)
    }

    struct PairVerifyStage {
        var accessoryPublicKey: Data
        var controllerPublicKey: Data
        var sharedSecret: Data
        var encryptionKey: Data
    }

    struct PendingSession {
        var session: HAPSession
        var readKey: Data     // controller → accessory
        var writeKey: Data    // accessory → controller
    }

    let id: UUID
    let transport: any TCPConnection
    let outbound: AsyncStream<Data>.Continuation
    var parser = HTTPRequestParser()
    /// Received bytes not yet split into requests (before pair-verify completes).
    var plaintextBuffer = Data()
    /// Bumped whenever pair-verify switches the session keys.
    var keyGeneration = 0
    /// Closes the connection if it stays unverified and idle (`HAPServerTimings.unverifiedIdleTimeout`).
    var idleTask: Task<Void, Never>?
    var decryptor: HAPFrameDecryptor?
    var encryptor: HAPFrameEncryptor?
    var session: HAPSession?
    var pendingSession: PendingSession?
    var pairSetup: PairSetupStage?
    var pairVerify: PairVerifyStage?
    var subscriptions: Set<CharacteristicKey> = []
    var pendingEvents: [(key: CharacteristicKey, value: HAPJSON)] = []
    var immediateEventsQueued = false
    var eventTimer: Task<Void, Never>?
    var handlingRequest = false
    /// The last `/prepare`: its `pid` (normalized by `AccessoryServer.timedWritePID`, so any uint64 fits) and expiry.
    var timedWrite: (pid: HAPJSON, expiry: ContinuousClock.Instant)?
    var lastActivity = ContinuousClock.now
    /// When bytes last arrived from the controller (`lastActivity` also counts what we wrote).
    var lastInbound = ContinuousClock.now
    var closeAfterResponse = false
    var isClosed = false

    init(transport: any TCPConnection, outbound: AsyncStream<Data>.Continuation) {
        id = transport.id
        self.transport = transport
        self.outbound = outbound
    }

    /// Verified, or about to be (pair-verify M4 queued).
    var isVerified: Bool { session != nil || pendingSession != nil }

    /// The next plaintext to parse: one complete request before pair-verify, one decrypted frame afterwards.
    /// nil = more bytes needed. Throws on oversized/garbled input (the connection must then be closed).
    func nextInput() throws -> Data? {
        if decryptor != nil { return try decryptor?.nextFrame() }
        guard let length = try PlaintextRequestFraming.firstRequestLength(in: plaintextBuffer) else { return nil }
        let request = Data(plaintextBuffer.prefix(length))
        plaintextBuffer = Data(plaintextBuffer.dropFirst(length))
        return request
    }
}

/// The connection whose pair-setup is in progress (only one at a time; others get Busy).
struct PairSetupOwner: Sendable, Equatable {
    var connectionID: UUID
    /// Last progress (M1 or M3).
    var since: ContinuousClock.Instant
}

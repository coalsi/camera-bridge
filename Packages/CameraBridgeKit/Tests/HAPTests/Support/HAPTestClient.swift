#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import Synchronization
@testable import HAP
import TestSupport

/// One HTTP response (or `EVENT/1.0` notification) received by `HAPTestClient`.
struct HAPTestResponse: Sendable {
    var version: String
    var status: Int
    var headers: HTTPHeaders
    var body: Data

    var isEvent: Bool { version == "EVENT/1.0" }

    func json() throws -> HAPJSON { try HAPJSON.parse(body) }
    func tlv() throws -> TLVReader { try TLVReader(body) }
}

/// `SRPClient` (not Sendable) behind a lock, so it can be built on a Dispatch queue.
final class SRPClientBox: Sendable {
    let publicKey: Data
    let proof: Data
    let sessionKey: Data
    private let client: Mutex<SRPClient>

    init(_ client: sending SRPClient) {
        publicKey = client.publicKey
        proof = client.proof
        sessionKey = client.sessionKey
        self.client = Mutex(client)
    }

    func verifyServerProof(_ proof: Data) -> Bool {
        client.withLock { $0.verifyServerProof(proof) }
    }
}

enum HAPTestClientError: Error, Equatable {
    case closed
    case timedOut
    case pairing(step: Int, error: UInt8?)
    case unexpected(String)
}

/// Minimal loopback HAP controller for the HAP tests (plan W1-1 item 15): pair-setup (SRP), pair-verify (X25519 +
/// Ed25519), encrypted requests and `EVENT/1.0` notifications. W2-2 moves a full controller into TestSupport.
actor HAPTestClient {
    struct Pairing: Sendable {
        var accessoryPairingID: String
        var accessoryLongTermPublicKey: Data
    }

    let controllerID: String
    let longTermKey: HAPLongTermKey

    private typealias Waiter = (id: UUID, continuation: CheckedContinuation<HAPTestResponse, any Error>)
    private let connection: any TCPConnection
    private var parser = HTTPResponseParser()
    private var waiting: [Waiter] = []
    private var eventBuffer: [HAPTestResponse] = []
    private var eventWaiters: [Waiter] = []
    private var cipherBuffer = Data()
    private var readKey: Data?
    private var writeKey: Data?
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0
    private var readTask: Task<Void, Never>?
    /// Responses that arrived while nobody waited (taken with `nextResponse`).
    private var responseBuffer: [HAPTestResponse] = []
    /// Keys that take effect after the next complete plaintext response (pipelined pair-verify M4).
    private var pendingReadKey: Data?
    private var plaintextBuffer = Data()
    /// Timeout timers of the pending waiters (cancelled as soon as the waiter is resumed).
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private(set) var isClosed = false
    /// Every message in arrival order ("R <status>" for responses, "E" for events).
    private(set) var arrivalLog: [String] = []
    /// Plaintext lengths of the encrypted frames received so far.
    private(set) var receivedFrameLengths: [Int] = []
    private(set) var pairing: Pairing?
    /// The pair-verify X25519 shared secret of this connection.
    private(set) var sharedSecret: Data?

    private init(connection: any TCPConnection, controllerID: String, longTermKey: HAPLongTermKey, pairing: Pairing?) {
        self.connection = connection
        self.controllerID = controllerID
        self.longTermKey = longTermKey
        self.pairing = pairing
    }

    static func connect(port: UInt16, controllerID: String = UUID().uuidString, longTermKey: HAPLongTermKey = HAPLongTermKey(),
                        pairing: Pairing? = nil) async throws -> HAPTestClient {
        let connection = try await PlatformNetworkTransport().connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        let client = HAPTestClient(connection: connection, controllerID: controllerID, longTermKey: longTermKey, pairing: pairing)
        await client.startReading()
        return client
    }

    /// A second connection with the same controller identity and pairing (not yet verified).
    func reconnect(port: UInt16) async throws -> HAPTestClient {
        try await HAPTestClient.connect(port: port, controllerID: controllerID, longTermKey: longTermKey, pairing: pairing)
    }

    func close() {
        connection.close()
    }

    // MARK: - Raw I/O

    private func startReading() {
        let connection = self.connection
        readTask = Task { [weak self] in
            while true {
                let data: Data?
                do {
                    data = try await connection.receive(maximumLength: 65_536)
                } catch {
                    data = nil
                }
                guard let self else { return }
                guard let data else {
                    await self.didClose()
                    return
                }
                await self.didReceive(data)
            }
        }
    }

    private func didClose() {
        isClosed = true
        let pending = waiting + eventWaiters
        waiting.removeAll()
        eventWaiters.removeAll()
        for waiter in pending { finish(waiter, .failure(HAPTestClientError.closed)) }
    }

    /// Resumes a waiter that was already removed from its queue and cancels its timeout timer.
    private func finish(_ waiter: Waiter, _ result: Result<HAPTestResponse, any Error>) {
        timeouts.removeValue(forKey: waiter.id)?.cancel()
        waiter.continuation.resume(with: result)
    }

    private func startTimeout(_ id: UUID, after timeout: Duration) {
        timeouts[id] = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self.fail(id, HAPTestClientError.timedOut)
        }
    }

    private func didReceive(_ data: Data) {
        if readKey == nil, let pendingReadKey {
            // Pipelined pair-verify: the plaintext M4 may share a read with the first encrypted frames.
            plaintextBuffer.append(data)
            guard let length = Self.firstMessageLength(in: plaintextBuffer) else { return }
            let message = Data(plaintextBuffer.prefix(length))
            let rest = Data(plaintextBuffer.dropFirst(length))
            plaintextBuffer = Data()
            process(message)
            readKey = pendingReadKey
            self.pendingReadKey = nil
            readCounter = 0
            if !rest.isEmpty { didReceive(rest) }
            return
        }
        var plaintext = data
        if let readKey {
            cipherBuffer.append(data)
            plaintext = Data()
            while cipherBuffer.count >= 2 {
                let start = cipherBuffer.startIndex
                let length = Int(cipherBuffer[start]) | Int(cipherBuffer[start + 1]) << 8
                guard cipherBuffer.count >= 2 + length + 16 else { break }
                let aad = Data(cipherBuffer[start..<(start + 2)])
                let sealed = Data(cipherBuffer[(start + 2)..<(start + 2 + length + 16)])
                cipherBuffer = Data(cipherBuffer[(start + 2 + length + 16)...])
                do {
                    plaintext.append(try HAPCrypto.chachaOpen(sealed, key: readKey, nonce: HAPCrypto.nonce(counter: readCounter), aad: aad))
                } catch {
                    connection.close()
                    didClose()
                    return
                }
                readCounter += 1
                receivedFrameLengths.append(length)
            }
        }
        process(plaintext)
    }

    /// Length of the first complete HTTP message (head + Content-Length body) in `buffer`; nil = incomplete.
    private static func firstMessageLength(in buffer: Data) -> Int? {
        guard let terminator = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<terminator.lowerBound], as: UTF8.self)
        var bodyLength = 0
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" { bodyLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        let total = terminator.upperBound - buffer.startIndex + bodyLength
        return buffer.count >= total ? total : nil
    }

    private func process(_ plaintext: Data) {
        let messages: [(head: HTTPResponseHead, body: Data)]
        do {
            messages = try parser.feed(plaintext)
        } catch {
            connection.close()
            didClose()
            return
        }
        for message in messages {
            let response = HAPTestResponse(version: message.head.version, status: message.head.status, headers: message.head.headers,
                                           body: message.body)
            if response.isEvent {
                arrivalLog.append("E")
                if eventWaiters.isEmpty {
                    eventBuffer.append(response)
                } else {
                    finish(eventWaiters.removeFirst(), .success(response))
                }
            } else {
                arrivalLog.append("R \(response.status)")
                if waiting.isEmpty {
                    responseBuffer.append(response)
                    continue
                }
                finish(waiting.removeFirst(), .success(response))
            }
        }
    }

    /// Sends raw bytes (encrypted if a session is established) without waiting for a response.
    func sendRaw(_ data: Data) async throws {
        guard let writeKey else {
            try await connection.send(data)
            return
        }
        var out = Data()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + 1024, data.endIndex)
            let chunk = data[offset..<end]
            var aad = Data()
            aad.append(UInt8(chunk.count & 0xFF))
            aad.append(UInt8(chunk.count >> 8))
            out.append(aad)
            out.append(try HAPCrypto.chachaSeal(Data(chunk), key: writeKey, nonce: HAPCrypto.nonce(counter: writeCounter), aad: aad))
            writeCounter += 1
            offset = end
        }
        try await connection.send(out)
    }

    /// Sends bytes exactly as given, bypassing encryption (for tamper tests).
    func sendUnencrypted(_ data: Data) async throws {
        try await connection.send(data)
    }

    func request(_ method: String, _ target: String, body: Data = Data(), contentType: String? = nil,
                 timeout: Duration = .seconds(20)) async throws -> HAPTestResponse {
        var headers = HTTPHeaders([("Host", "camerabridge.local")])
        if let contentType { headers.add("Content-Type", contentType) }
        if !body.isEmpty || method == "PUT" || method == "POST" { headers["Content-Length"] = String(body.count) }
        let bytes = HTTPSerializer.request(HTTPRequestHead(method: method, target: target, headers: headers), body: body)
        if isClosed { throw HAPTestClientError.closed }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append((id, continuation))
            startTimeout(id, after: timeout)
            Task {
                do {
                    try await self.sendRaw(bytes)
                } catch {
                    self.fail(id, error)
                }
            }
        }
    }

    private func fail(_ id: UUID, _ error: any Error) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            finish(waiting.remove(at: index), .failure(error))
        } else if let index = eventWaiters.firstIndex(where: { $0.id == id }) {
            finish(eventWaiters.remove(at: index), .failure(error))
        }
    }

    // MARK: - JSON helpers

    func getJSON(_ target: String) async throws -> (status: Int, json: HAPJSON?) {
        let response = try await request("GET", target)
        return (response.status, response.body.isEmpty ? nil : try response.json())
    }

    func putJSON(_ target: String, _ json: HAPJSON) async throws -> (status: Int, json: HAPJSON?) {
        let response = try await request("PUT", target, body: json.serialized(), contentType: "application/hap+json")
        return (response.status, response.body.isEmpty ? nil : try response.json())
    }

    func accessories() async throws -> HAPJSON {
        let (status, json) = try await getJSON("/accessories")
        guard status == 200, let json else { throw HAPTestClientError.unexpected("/accessories status \(status)") }
        return json
    }

    func writeCharacteristics(_ items: [HAPJSON], pid: HAPJSON? = nil) async throws -> (status: Int, json: HAPJSON?) {
        var body: [(String, HAPJSON)] = [("characteristics", .array(items))]
        if let pid { body.append(("pid", pid)) }
        return try await putJSON("/characteristics", .object(HAPJSONObject(body)))
    }

    func subscribe(aid: UInt64, iid: UInt64, _ enabled: Bool = true) async throws -> Int {
        try await writeCharacteristics([["aid": .int(Int64(aid)), "iid": .int(Int64(iid)), "ev": .bool(enabled)]]).status
    }

    // MARK: - Pairing

    /// Waits for the next response that no `request` is waiting for (buffered if it already arrived).
    func nextResponse(timeout: Duration = .seconds(5)) async throws -> HAPTestResponse {
        if !responseBuffer.isEmpty { return responseBuffer.removeFirst() }
        if isClosed { throw HAPTestClientError.closed }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append((id, continuation))
            startTimeout(id, after: timeout)
        }
    }

    /// One POST of a pairing TLV (`/pair-setup`, `/pair-verify`, `/pairings`); throws unless HTTP 200.
    func pairingRequest(_ path: String, _ builder: TLVBuilder) async throws -> TLVReader {
        let response = try await request("POST", path, body: builder.data, contentType: "application/pairing+tlv8")
        guard response.status == 200 else { throw HAPTestClientError.unexpected("\(path) HTTP \(response.status)") }
        return try response.tlv()
    }

    /// Full pair-setup M1–M6. `method` is what M1 carries (hap-controller sends 1). `pauseAfterM2`: wait this long
    /// before M3, as a controller does while the user types the setup code shown on the accessory.
    @discardableResult
    func pairSetup(code: String, method: UInt8 = 0, pauseAfterM2: Duration? = nil) async throws -> Pairing {
        let sessionKey = try await pairSetupThroughM4(code: code, method: method, pauseAfterM2: pauseAfterM2)
        let encryptionKey = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let controllerX = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Controller-Sign-Salt",
                                               info: "Pair-Setup-Controller-Sign-Info")
        let idData = Data(controllerID.utf8)
        let signature = try longTermKey.signature(for: controllerX + idData + longTermKey.publicKey)
        var sub = TLVBuilder()
        sub.add(0x01, idData)
        sub.add(0x03, longTermKey.publicKey)
        sub.add(0x0A, signature)
        var m5 = TLVBuilder()
        m5.add(0x06, uint8: 5)
        m5.add(0x05, try HAPCrypto.chachaSeal(sub.data, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PS-Msg05")))
        let m6 = try await pairingRequest("/pair-setup", m5)
        if let error = m6.uint8(0x07) { throw HAPTestClientError.pairing(step: 6, error: error) }
        guard m6.uint8(0x06) == 6, let encrypted = m6.data(0x05) else { throw HAPTestClientError.pairing(step: 6, error: nil) }
        let plaintext = try HAPCrypto.chachaOpen(encrypted, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PS-Msg06"))
        let accessory = try TLVReader(plaintext)
        guard let accessoryID = accessory.data(0x01), let accessoryLTPK = accessory.data(0x03), let accessorySignature = accessory.data(0x0A) else {
            throw HAPTestClientError.pairing(step: 6, error: nil)
        }
        let accessoryX = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt",
                                              info: "Pair-Setup-Accessory-Sign-Info")
        guard HAPLongTermKey.isValidSignature(accessorySignature, for: accessoryX + accessoryID + accessoryLTPK, publicKey: accessoryLTPK) else {
            throw HAPTestClientError.pairing(step: 6, error: nil)
        }
        let result = Pairing(accessoryPairingID: String(decoding: accessoryID, as: UTF8.self), accessoryLongTermPublicKey: accessoryLTPK)
        pairing = result
        return result
    }

    /// Pair-setup M1–M4 (the SRP exchange); returns the SRP session key, from which M5 is derived. Tests of M5
    /// itself send their own M5 afterwards.
    func pairSetupThroughM4(code: String, method: UInt8 = 0, pauseAfterM2: Duration? = nil) async throws -> Data {
        var m1 = TLVBuilder()
        m1.add(0x00, uint8: method)
        m1.add(0x06, uint8: 1)
        let m2 = try await pairingRequest("/pair-setup", m1)
        if let error = m2.uint8(0x07) { throw HAPTestClientError.pairing(step: 2, error: error) }
        guard m2.uint8(0x06) == 2, let salt = m2.data(0x02), let serverPublicKey = m2.data(0x03) else {
            throw HAPTestClientError.pairing(step: 2, error: nil)
        }
        // SRP math on a Dispatch queue: blocking the cooperative pool would delay other tests' event timing checks.
        let computed = await offloadComputation { () -> SRPClientBox? in
            guard let client = try? SRPClient(password: code, salt: salt, serverPublicKey: serverPublicKey) else { return nil }
            return SRPClientBox(client)
        }
        guard let srp = computed else { throw HAPTestClientError.pairing(step: 2, error: nil) }
        if let pauseAfterM2 { try await Task.sleep(for: pauseAfterM2) }

        var m3 = TLVBuilder()
        m3.add(0x06, uint8: 3)
        m3.add(0x03, srp.publicKey)
        m3.add(0x04, srp.proof)
        let m4 = try await pairingRequest("/pair-setup", m3)
        if let error = m4.uint8(0x07) { throw HAPTestClientError.pairing(step: 4, error: error) }
        guard m4.uint8(0x06) == 4, let serverProof = m4.data(0x04), srp.verifyServerProof(serverProof) else {
            throw HAPTestClientError.pairing(step: 4, error: nil)
        }
        return srp.sessionKey
    }

    /// Pair-verify M1–M4; afterwards every message on this connection is encrypted. `identity` verifies as another
    /// controller than this client's own (on the same connection).
    func pairVerify(as identity: (id: String, key: HAPLongTermKey)? = nil) async throws {
        let (shared, m3) = try await pairVerifyUpToM3(identity: identity)
        let m4 = try await pairingRequest("/pair-verify", m3)
        if let error = m4.uint8(0x07) { throw HAPTestClientError.pairing(step: 4, error: error) }
        guard m4.uint8(0x06) == 4 else { throw HAPTestClientError.pairing(step: 4, error: nil) }
        sharedSecret = shared
        writeKey = HAPCrypto.hkdfSHA512(inputKey: shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        readKey = HAPCrypto.hkdfSHA512(inputKey: shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        writeCounter = 0
        readCounter = 0
    }

    /// Pair-verify whose M3 goes out in the same TCP write as the next request, already encrypted with the new session
    /// keys (a controller that does not wait for M4). Returns the response to that request.
    func pairVerifyPipelining(_ method: String, _ target: String) async throws -> HAPTestResponse {
        let (shared, m3) = try await pairVerifyUpToM3(identity: nil)
        let m3Head = HTTPRequestHead(method: "POST", target: "/pair-verify",
                                     headers: HTTPHeaders([("Host", "camerabridge.local"), ("Content-Type", "application/pairing+tlv8"),
                                                           ("Content-Length", String(m3.data.count))]))
        let m3Bytes = HTTPSerializer.request(m3Head, body: m3.data)
        sharedSecret = shared
        pendingReadKey = HAPCrypto.hkdfSHA512(inputKey: shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        let key = HAPCrypto.hkdfSHA512(inputKey: shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        let request = HTTPSerializer.request(HTTPRequestHead(method: method, target: target, headers: HTTPHeaders([("Host", "camerabridge.local")])),
                                             body: Data())
        let length = Data([UInt8(request.count & 0xFF), UInt8(request.count >> 8)])
        let sealed = length + (try HAPCrypto.chachaSeal(request, key: key, nonce: HAPCrypto.nonce(counter: 0), aad: length))
        writeKey = key
        writeCounter = 1
        try await connection.send(m3Bytes + sealed)
        let m4 = try await nextResponse()
        guard m4.status == 200, try m4.tlv().uint8(0x06) == 4, try m4.tlv().uint8(0x07) == nil else {
            throw HAPTestClientError.pairing(step: 4, error: try? m4.tlv().uint8(0x07))
        }
        return try await nextResponse()
    }

    /// Pair-verify M1/M2 plus the M3 message: (shared secret, M3). Does not send M3 (tests may send it themselves).
    func pairVerifyUpToM3(identity: (id: String, key: HAPLongTermKey)? = nil) async throws -> (Data, TLVBuilder) {
        guard let pairing else { throw HAPTestClientError.unexpected("pair-verify without pairing") }
        let ephemeral = X25519KeyPair()
        var m1 = TLVBuilder()
        m1.add(0x06, uint8: 1)
        m1.add(0x03, ephemeral.publicKey)
        let m2 = try await pairingRequest("/pair-verify", m1)
        if let error = m2.uint8(0x07) { throw HAPTestClientError.pairing(step: 2, error: error) }
        guard m2.uint8(0x06) == 2, let accessoryPublicKey = m2.data(0x03), let encrypted = m2.data(0x05) else {
            throw HAPTestClientError.pairing(step: 2, error: nil)
        }
        let shared = try ephemeral.sharedSecret(with: accessoryPublicKey)
        let encryptionKey = HAPCrypto.hkdfSHA512(inputKey: shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let inner = try TLVReader(HAPCrypto.chachaOpen(encrypted, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PV-Msg02")))
        guard let accessoryID = inner.data(0x01), let accessorySignature = inner.data(0x0A),
              String(decoding: accessoryID, as: UTF8.self) == pairing.accessoryPairingID,
              HAPLongTermKey.isValidSignature(accessorySignature, for: accessoryPublicKey + accessoryID + ephemeral.publicKey,
                                              publicKey: pairing.accessoryLongTermPublicKey) else {
            throw HAPTestClientError.pairing(step: 2, error: nil)
        }
        let idData = Data((identity?.id ?? controllerID).utf8)
        let key = identity?.key ?? longTermKey
        var sub = TLVBuilder()
        sub.add(0x01, idData)
        sub.add(0x0A, try key.signature(for: ephemeral.publicKey + idData + accessoryPublicKey))
        var m3 = TLVBuilder()
        m3.add(0x06, uint8: 3)
        m3.add(0x05, try HAPCrypto.chachaSeal(sub.data, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PV-Msg03")))
        return (shared, m3)
    }

    /// `/pairings` request (admin operations). Returns the response TLV.
    func pairings(method: UInt8, identifier: String? = nil, publicKey: Data? = nil, permissions: UInt8? = nil) async throws -> TLVReader {
        var builder = TLVBuilder()
        builder.add(0x00, uint8: method)
        builder.add(0x06, uint8: 1)
        if let identifier { builder.add(0x01, Data(identifier.utf8)) }
        if let publicKey { builder.add(0x03, publicKey) }
        if let permissions { builder.add(0x0B, uint8: permissions) }
        return try await pairingRequest("/pairings", builder)
    }

    /// Waits for the next `EVENT/1.0` notification (buffered if it already arrived).
    func nextEvent(timeout: Duration = .seconds(5)) async throws -> HAPTestResponse {
        if !eventBuffer.isEmpty { return eventBuffer.removeFirst() }
        if isClosed { throw HAPTestClientError.closed }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            eventWaiters.append((id, continuation))
            startTimeout(id, after: timeout)
        }
    }

    /// Events received but not yet taken with `nextEvent`.
    var bufferedEventCount: Int { eventBuffer.count }

    /// Waits until the server closes the connection.
    func waitUntilClosed(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isClosed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isClosed
    }
}
#endif

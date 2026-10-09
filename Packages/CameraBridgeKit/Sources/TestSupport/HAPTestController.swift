// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// (Controller side of pair-setup / pair-verify / encrypted sessions as in test-utils/PairSetupClient.ts,
// PairVerifyClient.ts and HAPHTTPClient.ts; research brief §3.1, §3.2.)

import BridgeSupport
import Foundation
import HAP
import HAPCore
import Synchronization
#if os(macOS)
import PlatformApple
#endif

/// A reusable async HomeKit controller for tests and `cbctl`: pair-setup (SRP) and pair-verify, the encrypted HAP
/// session (≤ 1024-byte frames, per-direction counters), GET/PUT /characteristics (incl. timed and write-response
/// writes), subscriptions with an `EVENT/1.0` stream, `/resource` snapshots and `/pairings`. Requests and event waits
/// honour task cancellation (see `request`).
/// Camera helpers (SetupEndpoints, SelectedRTPStreamConfiguration, SetupDataStreamTransport + HDS, recording) are in
/// `HAPTestController+Camera.swift`.
///
/// One instance = one TCP connection. It never advertises anything; it connects by host and port over the injected
/// `NetworkTransport`. Secrets (setup code, keys, shared secret) are never logged.
public actor HAPTestController {
    /// Default `eventBufferLimit`: events kept for `nextEvent` that nobody has taken yet.
    public static let defaultEventBufferLimit = 1024

    public nonisolated let host: String
    public nonisolated let port: UInt16
    public nonisolated let identity: HAPControllerIdentity
    /// Our side of the TCP connection (the controller address a camera sends media to).
    public nonisolated let localAddress: String
    public nonisolated let isIPv6: Bool
    public nonisolated let transport: any NetworkTransport

    /// Known after pair-setup (or given to `connect` for a stored pairing).
    public private(set) var pairing: HAPAccessoryPairing?
    /// The pair-verify X25519 shared secret of this connection (HDS keys are derived from it).
    public private(set) var sharedSecret: Data?
    public private(set) var isClosed = false
    /// Default timeout of `request` and the helpers built on it.
    public var defaultTimeout: Duration = .seconds(15)
    /// Unclaimed events kept for `nextEvent` / `drainEvents` at most; beyond it the oldest are dropped (a controller
    /// that only reads `eventStream()` would otherwise keep every event). Change it with `setEventBufferLimit`.
    public private(set) var eventBufferLimit = HAPTestController.defaultEventBufferLimit
    /// Unclaimed events dropped because the buffer was full.
    public private(set) var droppedEventCount = 0

    private typealias ResponseWaiter = (id: UUID, continuation: CheckedContinuation<HAPControllerResponse, any Error>)
    private typealias EventWaiter = (id: UUID, filter: HAPCharacteristicID?, continuation: CheckedContinuation<HAPCharacteristicEvent, any Error>)

    private let connection: any TCPConnection
    private let log = Log(category: "HAPTestController")
    private let eventBroadcaster = AsyncBroadcaster<HAPCharacteristicEvent>(bufferingNewest: 1024)
    private var parser = HTTPResponseParser()
    private var responseWaiters: [ResponseWaiter] = []
    private var unclaimedResponses: [HAPControllerResponse] = []
    private var eventWaiters: [EventWaiter] = []
    private var bufferedEvents: [HAPCharacteristicEvent] = []
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var cipherBuffer = Data()
    private var readKey: Data?
    private var writeKey: Data?
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0
    private var readTask: Task<Void, Never>?
    /// Requests are sent one at a time (HAP is request/response per connection; events interleave).
    private var requestInFlight = false
    private var requestQueue: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    private init(host: String, port: UInt16, connection: any TCPConnection, transport: any NetworkTransport, identity: HAPControllerIdentity,
                 pairing: HAPAccessoryPairing?) {
        self.host = host
        self.port = port
        self.connection = connection
        self.transport = transport
        self.identity = identity
        self.pairing = pairing
        localAddress = connection.localAddress
        isIPv6 = connection.isIPv6
    }

    /// Opens the TCP connection (not yet verified). Pass the stored `pairing` to pair-verify without pair-setup.
    public static func connect(host: String, port: UInt16, transport: any NetworkTransport,
                               identity: HAPControllerIdentity = .generate(), pairing: HAPAccessoryPairing? = nil,
                               timeout: Duration = .seconds(10)) async throws -> HAPTestController {
        let connection = try await transport.connect(host: host, port: port, timeout: timeout)
        let controller = HAPTestController(host: host, port: port, connection: connection, transport: transport, identity: identity, pairing: pairing)
        await controller.startReading()
        return controller
    }

    /// A second connection with the same identity and pairing (not yet verified).
    public func reconnect(timeout: Duration = .seconds(10)) async throws -> HAPTestController {
        try await HAPTestController.connect(host: host, port: port, transport: transport, identity: identity, pairing: pairing, timeout: timeout)
    }

    /// Connects and pair-verifies with a stored pairing.
    public static func connectVerified(host: String, port: UInt16, transport: any NetworkTransport, identity: HAPControllerIdentity,
                                       pairing: HAPAccessoryPairing, timeout: Duration = .seconds(10)) async throws -> HAPTestController {
        let controller = try await connect(host: host, port: port, transport: transport, identity: identity, pairing: pairing, timeout: timeout)
        do {
            try await controller.pairVerify()
        } catch {
            await controller.close()
            throw error
        }
        return controller
    }

    public func close() {
        connection.close()
        didClose()
    }

    deinit {
        readTask?.cancel()
        connection.close()
        eventBroadcaster.finish()
    }

    // MARK: - Reading

    private func startReading() {
        let connection = self.connection
        readTask = Task { [weak self] in
            while !Task.isCancelled {
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
        guard !isClosed else { return }
        isClosed = true
        let responses = responseWaiters
        let events = eventWaiters
        responseWaiters.removeAll()
        eventWaiters.removeAll()
        for waiter in responses { resume(waiter.id, waiter.continuation, .failure(HAPControllerError.closed)) }
        for waiter in events { resume(waiter.id, waiter.continuation, .failure(HAPControllerError.closed)) }
        let queued = requestQueue
        requestQueue.removeAll()
        requestInFlight = false
        for waiter in queued { waiter.continuation.resume() }   // each then sees `isClosed`
        eventBroadcaster.finish()
    }

    private func didReceive(_ data: Data) {
        guard let readKey else {
            process(data)
            return
        }
        cipherBuffer.append(data)
        var plaintext = Data()
        while cipherBuffer.count >= 2 {
            let start = cipherBuffer.startIndex
            let length = Int(cipherBuffer[start]) | Int(cipherBuffer[start + 1]) << 8
            guard length <= 1024 else {
                log.warning("accessory sent an oversized frame (\(length) bytes); closing")
                close()
                return
            }
            guard cipherBuffer.count >= 2 + length + 16 else { break }
            let aad = Data(cipherBuffer[start..<(start + 2)])
            let sealed = Data(cipherBuffer[(start + 2)..<(start + 2 + length + 16)])
            cipherBuffer = Data(cipherBuffer[(start + 2 + length + 16)...])
            do {
                plaintext.append(try HAPCrypto.chachaOpen(sealed, key: readKey, nonce: HAPCrypto.nonce(counter: readCounter), aad: aad))
            } catch {
                log.warning("frame from the accessory failed to decrypt; closing")
                close()
                return
            }
            readCounter += 1
        }
        if !plaintext.isEmpty { process(plaintext) }
    }

    private func process(_ plaintext: Data) {
        let messages: [(head: HTTPResponseHead, body: Data)]
        do {
            messages = try parser.feed(plaintext)
        } catch {
            log.warning("malformed HTTP from the accessory; closing")
            close()
            return
        }
        for message in messages {
            let response = HAPControllerResponse(version: message.head.version, status: message.head.status, headers: message.head.headers,
                                                 body: message.body)
            if response.isEvent {
                handleEvent(response)
            } else if responseWaiters.isEmpty {
                unclaimedResponses.append(response)
            } else {
                let waiter = responseWaiters.removeFirst()
                resume(waiter.id, waiter.continuation, .success(response))
            }
        }
    }

    private func handleEvent(_ response: HAPControllerResponse) {
        guard let json = try? response.json(), let items = json["characteristics"]?.arrayValue else {
            log.warning("undecodable EVENT body ignored")
            return
        }
        for item in items {
            guard let aid = item["aid"]?.unsignedValue, let iid = item["iid"]?.unsignedValue else { continue }
            let event = HAPCharacteristicEvent(id: HAPCharacteristicID(aid: aid, iid: iid), value: item["value"] ?? .null)
            eventBroadcaster.yield(event)
            if let index = eventWaiters.firstIndex(where: { $0.filter == nil || $0.filter == event.id }) {
                let waiter = eventWaiters.remove(at: index)
                resume(waiter.id, waiter.continuation, .success(event))
            } else {
                bufferedEvents.append(event)
                trimBufferedEvents()
            }
        }
    }

    private func trimBufferedEvents() {
        let excess = bufferedEvents.count - eventBufferLimit
        guard excess > 0 else { return }
        bufferedEvents.removeFirst(excess)
        if droppedEventCount == 0 { log.warning("unclaimed events exceed \(eventBufferLimit); dropping the oldest") }
        droppedEventCount += excess
    }

    private func resume<T: Sendable>(_ id: UUID, _ continuation: CheckedContinuation<T, any Error>, _ result: Result<T, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        continuation.resume(with: result)
    }

    private func startTimeout(_ id: UUID, after timeout: Duration) {
        timeouts[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.expire(id)
        }
    }

    private func expire(_ id: UUID) {
        if let index = responseWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = responseWaiters.remove(at: index)
            resume(waiter.id, waiter.continuation, .failure(HAPControllerError.timedOut))
            // A late answer would be taken for the next request's: the connection is no longer usable.
            log.warning("request timed out; closing the connection")
            close()
        } else if let index = eventWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = eventWaiters.remove(at: index)
            resume(waiter.id, waiter.continuation, .failure(HAPControllerError.timedOut))
        }
    }

    // MARK: - Raw requests

    /// Sends bytes (encrypted once a session is verified) without waiting for anything.
    private func send(_ data: Data) async throws {
        guard let writeKey else {
            try await connection.send(data)
            return
        }
        var out = Data()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + 1024, data.endIndex)
            let chunk = Data(data[offset..<end])
            let aad = Data([UInt8(chunk.count & 0xFF), UInt8(chunk.count >> 8)])
            out.append(aad)
            out.append(try HAPCrypto.chachaSeal(chunk, key: writeKey, nonce: HAPCrypto.nonce(counter: writeCounter), aad: aad))
            writeCounter += 1
            offset = end
        }
        try await connection.send(out)
    }

    /// Waits for the request slot (FIFO). A caller cancelled while queued leaves the queue with `CancellationError`.
    private func acquireRequestSlot() async throws {
        try Task.checkCancellation()
        if !requestInFlight {
            requestInFlight = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
                requestQueue.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelSlotWait(id) }
        }
    }

    private func cancelSlotWait(_ id: UUID) {
        guard let index = requestQueue.firstIndex(where: { $0.id == id }) else { return }
        requestQueue.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseRequestSlot() {
        if requestQueue.isEmpty {
            requestInFlight = false
        } else {
            requestQueue.removeFirst().continuation.resume()
        }
    }

    /// One HTTP request; returns the response whatever its status. Requests on one controller are serialized.
    /// Cancellation: a request still waiting for its turn just leaves the queue; one already sent ends with
    /// `CancellationError` and closes the connection (like a timeout: its late answer would be taken for the next
    /// request's).
    public func request(_ method: String, _ target: String, body: Data = Data(), contentType: String? = nil,
                        timeout: Duration? = nil) async throws -> HAPControllerResponse {
        try await acquireRequestSlot()
        defer { releaseRequestSlot() }
        if isClosed { throw HAPControllerError.closed }
        try Task.checkCancellation()
        var headers = HTTPHeaders([("Host", "\(host):\(port)")])
        if let contentType { headers.add("Content-Type", contentType) }
        if !body.isEmpty || method == "PUT" || method == "POST" { headers["Content-Length"] = String(body.count) }
        let bytes = HTTPSerializer.request(HTTPRequestHead(method: method, target: target, version: "HTTP/1.1", headers: headers), body: body)
        let id = UUID()
        let deadline = timeout ?? defaultTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HAPControllerResponse, any Error>) in
                if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
                if !unclaimedResponses.isEmpty {
                    // A stray response (should not happen with serialized requests) would otherwise answer this request.
                    log.warning("discarding \(unclaimedResponses.count) unsolicited response(s)")
                    unclaimedResponses.removeAll()
                }
                responseWaiters.append((id, continuation))
                startTimeout(id, after: deadline)
                Task {
                    do {
                        try await self.send(bytes)
                    } catch {
                        self.failRequest(id, error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    private func cancelRequest(_ id: UUID) {
        guard let index = responseWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = responseWaiters.remove(at: index)
        resume(waiter.id, waiter.continuation, .failure(CancellationError()))
        log.warning("request cancelled while in flight; closing the connection")
        close()
    }

    private func failRequest(_ id: UUID, _ error: any Error) {
        guard let index = responseWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = responseWaiters.remove(at: index)
        resume(waiter.id, waiter.continuation, .failure(error))
    }

    /// POSTs a pairing TLV (`/pair-setup`, `/pair-verify`, `/pairings`); throws unless HTTP 200.
    private func pairingRequest(_ path: String, _ builder: TLVBuilder, step: Int) async throws -> TLVReader {
        let response = try await request("POST", path, body: builder.data, contentType: "application/pairing+tlv8")
        guard response.status == 200 else { throw HAPControllerError.httpStatus(response.status, hapStatus: response.hapStatus) }
        let reader = try response.tlv()
        if let error = reader.uint8(0x07) { throw HAPControllerError.pairing(step: step, error: error) }
        return reader
    }

    // MARK: - Pairing

    /// Pair-setup M1–M6 with the setup code ("12345678" or "123-45-678"). Stores and returns the accessory's pairing.
    @discardableResult
    public func pairSetup(setupCode: String) async throws -> HAPAccessoryPairing {
        guard let code = SetupCode(setupCode) else { throw HAPControllerError.invalidArgument("setup code must be 8 digits (XXX-XX-XXX)") }
        var m1 = TLVBuilder()
        m1.add(0x06, uint8: 1)
        m1.add(0x00, uint8: 0)
        let m2 = try await pairingRequest("/pair-setup", m1, step: 2)
        guard m2.uint8(0x06) == 2, let salt = m2.data(0x02), let serverPublicKey = m2.data(0x03) else {
            throw HAPControllerError.pairing(step: 2, error: nil)
        }
        // SRP math off the cooperative pool (3072-bit exponentiations take a while in Debug builds).
        let password = code.formatted
        let computed = await Self.offload { () -> SRPClientBox? in
            guard let client = try? SRPClient(password: password, salt: salt, serverPublicKey: serverPublicKey) else { return nil }
            return SRPClientBox(client)
        }
        guard let srp = computed else { throw HAPControllerError.pairing(step: 2, error: nil) }

        var m3 = TLVBuilder()
        m3.add(0x06, uint8: 3)
        m3.add(0x03, srp.publicKey)
        m3.add(0x04, srp.proof)
        let m4 = try await pairingRequest("/pair-setup", m3, step: 4)
        guard m4.uint8(0x06) == 4, let serverProof = m4.data(0x04), srp.verifyServerProof(serverProof) else {
            throw HAPControllerError.pairing(step: 4, error: nil)
        }

        let sessionKey = srp.sessionKey
        let encryptionKey = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let controllerX = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let key = try identity.key()
        let idData = Data(identity.pairingID.utf8)
        var sub = TLVBuilder()
        sub.add(0x01, idData)
        sub.add(0x03, key.publicKey)
        sub.add(0x0A, try key.signature(for: controllerX + idData + key.publicKey))
        var m5 = TLVBuilder()
        m5.add(0x06, uint8: 5)
        m5.add(0x05, try HAPCrypto.chachaSeal(sub.data, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PS-Msg05")))
        let m6 = try await pairingRequest("/pair-setup", m5, step: 6)
        guard m6.uint8(0x06) == 6, let encrypted = m6.data(0x05) else { throw HAPControllerError.pairing(step: 6, error: nil) }
        let accessory: TLVReader
        do {
            accessory = try TLVReader(HAPCrypto.chachaOpen(encrypted, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PS-Msg06")))
        } catch {
            throw HAPControllerError.pairing(step: 6, error: nil)
        }
        guard let accessoryID = accessory.data(0x01), let accessoryLTPK = accessory.data(0x03), let signature = accessory.data(0x0A) else {
            throw HAPControllerError.pairing(step: 6, error: nil)
        }
        let accessoryX = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        guard HAPLongTermKey.isValidSignature(signature, for: accessoryX + accessoryID + accessoryLTPK, publicKey: accessoryLTPK) else {
            throw HAPControllerError.pairing(step: 6, error: nil)
        }
        let result = HAPAccessoryPairing(accessoryPairingID: String(decoding: accessoryID, as: UTF8.self), accessoryLongTermPublicKey: accessoryLTPK)
        pairing = result
        return result
    }

    /// Pair-verify M1–M4; afterwards every message on this connection is encrypted.
    public func pairVerify() async throws {
        guard let pairing else { throw HAPControllerError.notPaired }
        let ephemeral = X25519KeyPair()
        var m1 = TLVBuilder()
        m1.add(0x06, uint8: 1)
        m1.add(0x03, ephemeral.publicKey)
        let m2 = try await pairingRequest("/pair-verify", m1, step: 2)
        guard m2.uint8(0x06) == 2, let accessoryPublicKey = m2.data(0x03), let encrypted = m2.data(0x05) else {
            throw HAPControllerError.pairing(step: 2, error: nil)
        }
        let shared: Data
        let inner: TLVReader
        let encryptionKey: Data
        do {
            shared = try ephemeral.sharedSecret(with: accessoryPublicKey)
            encryptionKey = HAPCrypto.hkdfSHA512(inputKey: shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            inner = try TLVReader(HAPCrypto.chachaOpen(encrypted, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PV-Msg02")))
        } catch {
            throw HAPControllerError.pairing(step: 2, error: nil)
        }
        guard let accessoryID = inner.data(0x01), let accessorySignature = inner.data(0x0A),
              String(decoding: accessoryID, as: UTF8.self) == pairing.accessoryPairingID,
              HAPLongTermKey.isValidSignature(accessorySignature, for: accessoryPublicKey + accessoryID + ephemeral.publicKey,
                                              publicKey: pairing.accessoryLongTermPublicKey) else {
            throw HAPControllerError.pairing(step: 2, error: nil)
        }
        let key = try identity.key()
        let idData = Data(identity.pairingID.utf8)
        var sub = TLVBuilder()
        sub.add(0x01, idData)
        sub.add(0x0A, try key.signature(for: ephemeral.publicKey + idData + accessoryPublicKey))
        var m3 = TLVBuilder()
        m3.add(0x06, uint8: 3)
        m3.add(0x05, try HAPCrypto.chachaSeal(sub.data, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PV-Msg03")))
        let m4 = try await pairingRequest("/pair-verify", m3, step: 4)
        guard m4.uint8(0x06) == 4 else { throw HAPControllerError.pairing(step: 4, error: nil) }
        sharedSecret = shared
        writeKey = HAPCrypto.hkdfSHA512(inputKey: shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        readKey = HAPCrypto.hkdfSHA512(inputKey: shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        writeCounter = 0
        readCounter = 0
    }

    public var isVerified: Bool { readKey != nil }

    /// `/pairings` List (admin only).
    public func listPairings() async throws -> [HAPPairingEntry] {
        var builder = TLVBuilder()
        builder.add(0x06, uint8: 1)
        builder.add(0x00, uint8: 5)
        let reader = try await pairingRequest("/pairings", builder, step: 2)
        var entries: [HAPPairingEntry] = []
        for group in TLV8.splitList(reader.items, separator: 0xFF) {
            let item = TLVReader(items: group)
            guard let identifier = item.data(0x01), let publicKey = item.data(0x03) else { continue }
            entries.append(HAPPairingEntry(identifier: String(decoding: identifier, as: UTF8.self), publicKey: publicKey,
                                           isAdmin: item.uint8(0x0B) == 1))
        }
        return entries
    }

    /// `/pairings` Add (admin only).
    public func addPairing(identifier: String, publicKey: Data, isAdmin: Bool) async throws {
        var builder = TLVBuilder()
        builder.add(0x06, uint8: 1)
        builder.add(0x00, uint8: 3)
        builder.add(0x01, Data(identifier.utf8))
        builder.add(0x03, publicKey)
        builder.add(0x0B, uint8: isAdmin ? 1 : 0)
        _ = try await pairingRequest("/pairings", builder, step: 2)
    }

    /// `/pairings` Remove (admin only; removing the last admin unpairs the accessory). Defaults to this controller.
    public func removePairing(identifier: String? = nil) async throws {
        var builder = TLVBuilder()
        builder.add(0x06, uint8: 1)
        builder.add(0x00, uint8: 4)
        builder.add(0x01, Data((identifier ?? identity.pairingID).utf8))
        _ = try await pairingRequest("/pairings", builder, step: 2)
    }

    // MARK: - Accessories and characteristics

    /// GET /accessories, parsed.
    public func accessories() async throws -> HAPAccessoryDatabase {
        let response = try await request("GET", "/accessories")
        guard response.status == 200 else { throw HAPControllerError.httpStatus(response.status, hapStatus: response.hapStatus) }
        return try HAPAccessoryDatabase(json: try response.json())
    }

    /// GET /characteristics?id=… (200 or 207; per-item statuses in the results).
    public func read(_ ids: [HAPCharacteristicID], meta: Bool = false, permissions: Bool = false, type: Bool = false,
                     events: Bool = false) async throws -> [HAPCharacteristicReadResult] {
        guard !ids.isEmpty else { return [] }
        var target = "/characteristics?id=" + ids.map(\.description).joined(separator: ",")
        if meta { target += "&meta=1" }
        if permissions { target += "&perms=1" }
        if type { target += "&type=1" }
        if events { target += "&ev=1" }
        let response = try await request("GET", target)
        guard response.status == 200 || response.status == 207 else {
            throw HAPControllerError.httpStatus(response.status, hapStatus: response.hapStatus)
        }
        guard let items = try response.json()["characteristics"]?.arrayValue else {
            throw HAPControllerError.malformedResponse("GET /characteristics: no characteristics")
        }
        return try items.map { item in
            guard let aid = item["aid"]?.unsignedValue, let iid = item["iid"]?.unsignedValue else {
                throw HAPControllerError.malformedResponse("GET /characteristics: item without aid/iid")
            }
            return HAPCharacteristicReadResult(id: HAPCharacteristicID(aid: aid, iid: iid), value: item["value"],
                                               status: item["status"]?.intValue.map { Int($0) } ?? 0, eventsEnabled: item["ev"]?.boolValue)
        }
    }

    /// The value of one characteristic; throws `characteristicStatus` for a per-item error.
    public func readValue(_ id: HAPCharacteristicID) async throws -> HAPJSON {
        guard let result = try await read([id]).first(where: { $0.id == id }) else {
            throw HAPControllerError.malformedResponse("GET /characteristics: \(id) missing")
        }
        guard result.status == 0 else { throw HAPControllerError.characteristicStatus(aid: id.aid, iid: id.iid, status: result.status) }
        return result.value ?? .null
    }

    /// The bytes of a tlv8/data characteristic.
    public func readData(_ id: HAPCharacteristicID) async throws -> Data {
        let value = try await readValue(id)
        guard let data = value.base64Data else { throw HAPControllerError.malformedResponse("\(id) is not base64 data") }
        return data
    }

    /// PUT /characteristics. `timedWriteTTL`: send a `/prepare` first and carry its `pid` (characteristics with `tw`).
    public func write(_ writes: [HAPCharacteristicWrite], timedWriteTTL: Duration? = nil) async throws -> [HAPCharacteristicWriteResult] {
        guard !writes.isEmpty else { return [] }
        var body: [(String, HAPJSON)] = [("characteristics", .array(writes.map(\.json)))]
        if let timedWriteTTL {
            let pid = Int64.random(in: 1...Int64(Int32.max))
            let ttl = max(1, Int64(timedWriteTTL.components.seconds * 1000) + timedWriteTTL.components.attoseconds / 1_000_000_000_000_000)
            let prepare = try await request("PUT", "/prepare", body: HAPJSON.object(HAPJSONObject([("ttl", .int(ttl)), ("pid", .int(pid))])).serialized(),
                                            contentType: "application/hap+json")
            guard prepare.status == 200, (try? prepare.json()["status"]?.intValue) == 0 else {
                throw HAPControllerError.httpStatus(prepare.status, hapStatus: prepare.hapStatus)
            }
            body.append(("pid", .int(pid)))
        }
        let response = try await request("PUT", "/characteristics", body: HAPJSON.object(HAPJSONObject(body)).serialized(),
                                         contentType: "application/hap+json")
        switch response.status {
        case 204:
            return writes.map { HAPCharacteristicWriteResult(id: $0.id, status: 0) }
        case 207, 200:
            guard let items = try response.json()["characteristics"]?.arrayValue else {
                throw HAPControllerError.malformedResponse("PUT /characteristics: no characteristics")
            }
            return try items.map { item in
                guard let aid = item["aid"]?.unsignedValue, let iid = item["iid"]?.unsignedValue else {
                    throw HAPControllerError.malformedResponse("PUT /characteristics: item without aid/iid")
                }
                return HAPCharacteristicWriteResult(id: HAPCharacteristicID(aid: aid, iid: iid), status: item["status"]?.intValue.map { Int($0) } ?? 0,
                                                    value: item["value"])
            }
        default:
            throw HAPControllerError.httpStatus(response.status, hapStatus: response.hapStatus)
        }
    }

    /// Writes one value; throws `characteristicStatus` unless the accessory reports status 0. Returns the
    /// write-response value when `wantsResponse`.
    @discardableResult
    public func writeValue(_ id: HAPCharacteristicID, _ value: HAPJSON, wantsResponse: Bool = false,
                           timedWriteTTL: Duration? = nil) async throws -> HAPJSON? {
        let results = try await write([HAPCharacteristicWrite(id: id, value: value, wantsResponse: wantsResponse)], timedWriteTTL: timedWriteTTL)
        guard let result = results.first(where: { $0.id == id }) else { throw HAPControllerError.malformedResponse("PUT /characteristics: \(id) missing") }
        guard result.status == 0 else { throw HAPControllerError.characteristicStatus(aid: id.aid, iid: id.iid, status: result.status) }
        return result.value
    }

    /// Writes a tlv8/data value (base64); returns the decoded write-response bytes when `wantsResponse`.
    @discardableResult
    public func writeData(_ id: HAPCharacteristicID, _ data: Data, wantsResponse: Bool = false) async throws -> Data? {
        let value = try await writeValue(id, .string(data.base64EncodedString()), wantsResponse: wantsResponse)
        guard wantsResponse else { return nil }
        guard let data = value?.base64Data else { throw HAPControllerError.malformedResponse("\(id): no write-response value") }
        return data
    }

    /// Enables (or disables) events; throws `characteristicStatus` for the first refused item.
    public func subscribe(_ ids: [HAPCharacteristicID], enabled: Bool = true) async throws {
        let results = try await write(ids.map { HAPCharacteristicWrite(id: $0, events: enabled) })
        if let refused = results.first(where: { $0.status != 0 }) {
            throw HAPControllerError.characteristicStatus(aid: refused.id.aid, iid: refused.id.iid, status: refused.status)
        }
    }

    public func unsubscribe(_ ids: [HAPCharacteristicID]) async throws {
        try await subscribe(ids, enabled: false)
    }

    /// The next event (optionally only for `id`), buffered if it already arrived. Events for other characteristics
    /// stay buffered. A cancelled caller gets `CancellationError` at once.
    public func nextEvent(for id: HAPCharacteristicID? = nil, timeout: Duration = .seconds(5)) async throws -> HAPCharacteristicEvent {
        if let index = bufferedEvents.firstIndex(where: { id == nil || $0.id == id }) {
            return bufferedEvents.remove(at: index)
        }
        if isClosed { throw HAPControllerError.closed }
        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
                eventWaiters.append((waiterID, id, continuation))
                startTimeout(waiterID, after: timeout)
            }
        } onCancel: {
            Task { await self.cancelEventWait(waiterID) }
        }
    }

    private func cancelEventWait(_ id: UUID) {
        guard let index = eventWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = eventWaiters.remove(at: index)
        resume(waiter.id, waiter.continuation, .failure(CancellationError()))
    }

    /// Sets `eventBufferLimit` (at least 1) and drops the oldest buffered events beyond it.
    public func setEventBufferLimit(_ limit: Int) {
        eventBufferLimit = max(1, limit)
        trimBufferedEvents()
    }

    /// Takes every buffered event (at most `eventBufferLimit`, oldest first).
    public func drainEvents() -> [HAPCharacteristicEvent] {
        defer { bufferedEvents.removeAll() }
        return bufferedEvents
    }

    /// Every event from now on (independent of `nextEvent`'s buffer). Finishes when the connection closes.
    public nonisolated func eventStream() -> AsyncStream<HAPCharacteristicEvent> {
        eventBroadcaster.subscribe()
    }

    // MARK: - Resource

    /// POST /resource snapshot; returns the JPEG bytes (HTTP 200) or throws `httpStatus` (e.g. 207 + HAP status).
    public func snapshot(width: Int, height: Int, aid: UInt64? = nil, reason: Int? = nil, timeout: Duration = .seconds(30)) async throws -> Data {
        var pairs: [(String, HAPJSON)] = [("resource-type", "image"), ("image-width", .int(Int64(width))), ("image-height", .int(Int64(height)))]
        if let aid { pairs.append(("aid", jsonUnsigned(aid))) }
        if let reason { pairs.append(("reason", .int(Int64(reason)))) }
        let response = try await request("POST", "/resource", body: HAPJSON.object(HAPJSONObject(pairs)).serialized(),
                                         contentType: "application/hap+json", timeout: timeout)
        guard response.status == 200 else { throw HAPControllerError.httpStatus(response.status, hapStatus: response.hapStatus) }
        return response.body
    }

    // MARK: - Helpers

    static func offload<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

#if os(macOS)
extension HAPTestController {
    /// `connect` over `AppleNetworkTransport` (tests on this Mac).
    public static func connect(host: String = "127.0.0.1", port: UInt16, identity: HAPControllerIdentity = .generate(),
                               pairing: HAPAccessoryPairing? = nil, timeout: Duration = .seconds(10)) async throws -> HAPTestController {
        try await connect(host: host, port: port, transport: AppleNetworkTransport(), identity: identity, pairing: pairing, timeout: timeout)
    }

    /// Connects, runs pair-setup with `setupCode` and pair-verifies (over `AppleNetworkTransport`).
    public static func paired(host: String = "127.0.0.1", port: UInt16, setupCode: String,
                              identity: HAPControllerIdentity = .generate()) async throws -> HAPTestController {
        let controller = try await connect(host: host, port: port, identity: identity)
        do {
            try await controller.pairSetup(setupCode: setupCode)
            try await controller.pairVerify()
        } catch {
            await controller.close()
            throw error
        }
        return controller
    }
}
#endif

/// `SRPClient` (not Sendable) behind a lock, built off the cooperative pool.
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

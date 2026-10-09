// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Pair-setup M1–M6, pair-verify M1–M4 and /pairings follow HAP-NodeJS HAPServer.ts (handlePairSetup*, handlePairVerify*,
// handlePairings) and Accessory.ts / model/AccessoryInfo.ts (add/remove/list pairing rules); constants from research
// brief §3.2.

import BridgeSupport
import Foundation
import HAPCore

extension AccessoryServer {
    // MARK: - Pair-setup

    func handlePairSetup(_ body: Data, connection: HAPConnection) async -> HAPResponse {
        let request: TLVReader
        do {
            request = try TLVReader(body)
        } catch {
            return .pairingError(state: 2, error: .unknown, status: 400)
        }
        guard let step = request.uint8(PairingTLV.state) else { return .pairingError(state: 2, error: .unknown, status: 400) }
        if !pairings.isEmpty {
            endPairSetup(connection)
            return .pairingError(state: 2, error: .unavailable)
        }
        if failedPairSetupAttempts > 100 {
            let remoteAddress = connection.transport.remoteAddress
            warnUnauthenticated("pair-setup", from: remoteAddress, "Pair-setup from \(remoteAddress) refused: too many failed attempts")
            endPairSetup(connection)
            return .pairingError(state: 2, error: .maxTries)
        }
        let owns = pairSetupOwner?.connectionID == connection.id
        switch (step, connection.pairSetup) {
        case (1, _):
            // One pair-setup at a time (each M1 costs a 3072-bit SRP key generation). A stalled one stops blocking
            // others after `pairSetupTimeout`; the same connection may restart its own.
            let now = ContinuousClock.now
            if let owner = pairSetupOwner, owner.connectionID != connection.id, connections[owner.connectionID] != nil,
               now - owner.since < timings.pairSetupTimeout {
                let remoteAddress = connection.transport.remoteAddress
                noteUnauthenticated("pair-setup-busy", from: remoteAddress,
                                    "Pair-setup from \(remoteAddress) refused: another pair-setup is in progress")
                return .pairingError(state: 2, error: .busy)
            }
            pairSetupOwner = PairSetupOwner(connectionID: connection.id, since: now)
            // M1: the Method value is ignored (hap-controller sends PairSetupWithAuth).
            return await pairSetupM1(connection)
        case (3, .awaitingM3(let srp)?) where owns:
            pairSetupOwner?.since = .now
            return await pairSetupM3(request, srp: srp, connection: connection)
        case (5, .awaitingM5(let srp)?) where owns:
            defer { endPairSetup(connection) }
            return pairSetupM5(request, srp: srp, connection: connection)
        default:
            endPairSetup(connection)
            return .pairingError(state: step &+ 1, error: .unknown, status: 400)
        }
    }

    /// Forgets `connection`'s pair-setup and frees the pair-setup slot if it held it.
    private func endPairSetup(_ connection: HAPConnection) {
        connection.pairSetup = nil
        if pairSetupOwner?.connectionID == connection.id { pairSetupOwner = nil }
    }

    private func pairSetupM1(_ connection: HAPConnection) async -> HAPResponse {
        let identity: HAPIdentity
        do {
            identity = try loadIdentity()
        } catch {
            endPairSetup(connection)
            return .pairingError(state: 2, error: .unknown)
        }
        let password = identity.setupCode.formatted
        let srp = await offloadComputation { SRPSession(password: password) }
        guard !connection.isClosed else { return .pairingError(state: 2, error: .unknown) }
        if pairSetupOwner?.connectionID == connection.id { pairSetupOwner?.since = .now }
        connection.pairSetup = .awaitingM3(srp)
        var response = TLVBuilder()
        response.add(PairingTLV.state, uint8: 2)
        response.add(PairingTLV.salt, srp.salt)
        response.add(PairingTLV.publicKey, srp.publicKey)
        return .tlv(200, response)
    }

    private func pairSetupM3(_ request: TLVReader, srp: SRPSession, connection: HAPConnection) async -> HAPResponse {
        connection.pairSetup = nil
        guard let clientPublicKey = request.data(PairingTLV.publicKey), let clientProof = request.data(PairingTLV.proof) else {
            endPairSetup(connection)
            return .pairingError(state: 4, error: .unknown)
        }
        let result = await offloadComputation { () -> Result<Data, SRPError> in
            do throws(SRPError) {
                return .success(try srp.verify(clientPublicKey: clientPublicKey, clientProof: clientProof))
            } catch {
                return .failure(error)
            }
        }
        do {
            let serverProof = try result.get()
            if pairSetupOwner?.connectionID == connection.id { pairSetupOwner?.since = .now }
            connection.pairSetup = .awaitingM5(srp)
            var response = TLVBuilder()
            response.add(PairingTLV.state, uint8: 4)
            response.add(PairingTLV.proof, serverProof)
            return .tlv(200, response)
        } catch {
            recordFailedPairSetupAttempt()
            log.warning("Pair-setup: wrong setup code from \(connection.transport.remoteAddress)")
            endPairSetup(connection)
            return .pairingError(state: 4, error: .authentication)
        }
    }

    private func pairSetupM5(_ request: TLVReader, srp: SRPSession, connection: HAPConnection) -> HAPResponse {
        connection.pairSetup = nil
        guard let sessionKey = srp.sessionKey, let encrypted = request.data(PairingTLV.encryptedData), encrypted.count >= 16,
              let identity = try? loadIdentity(), let longTermKey else {
            return .pairingError(state: 6, error: .authentication)
        }
        let encryptionKey = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        guard let plaintext = try? HAPCrypto.chachaOpen(encrypted, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PS-Msg05")) else {
            return .pairingError(state: 6, error: .authentication)
        }
        guard let inner = try? TLVReader(plaintext), let identifierData = inner.data(PairingTLV.identifier),
              let controllerLTPK = inner.data(PairingTLV.publicKey), let signature = inner.data(PairingTLV.signature),
              let controllerID = String(validating: identifierData, as: UTF8.self), !controllerID.isEmpty, controllerLTPK.count == 32 else {
            return .pairingError(state: 6, error: .unknown)
        }
        let controllerX = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        guard HAPLongTermKey.isValidSignature(signature, for: controllerX + identifierData + controllerLTPK, publicKey: controllerLTPK) else {
            log.warning("Pair-setup: invalid controller signature")
            return .pairingError(state: 6, error: .authentication)
        }

        let accessoryX = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let deviceIDData = Data(identity.deviceID.description.utf8)
        let accessoryLTPK = longTermKey.publicKey
        let sealed: Data
        do {
            let accessorySignature = try longTermKey.signature(for: accessoryX + deviceIDData + accessoryLTPK)
            var inner = TLVBuilder()
            inner.add(PairingTLV.identifier, deviceIDData)
            inner.add(PairingTLV.publicKey, accessoryLTPK)
            inner.add(PairingTLV.signature, accessorySignature)
            sealed = try HAPCrypto.chachaSeal(inner.data, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PS-Msg06"))
        } catch {
            return .pairingError(state: 6, error: .unknown)
        }

        // A pairing the accessory could not save would be gone after a relaunch while the controller keeps it.
        guard addAdminPairing(controllerID: controllerID, publicKey: controllerLTPK) else {
            return .pairingError(state: 6, error: .unknown)
        }

        var response = TLVBuilder()
        response.add(PairingTLV.state, uint8: 6)
        response.add(PairingTLV.encryptedData, sealed)
        return .tlv(200, response)
    }

    /// Stores `controllerID` as an admin pairing (pair-setup M6), reports `.paired` and refreshes the TXT record (`sf=0`).
    /// false: it could not be saved, and nothing changed (`savePairingChange`).
    @discardableResult
    func addAdminPairing(controllerID: String, publicKey: Data) -> Bool {
        var updated = state ?? HAPPersistentState()
        updated.pairings.removeAll { $0.identifier == controllerID }
        updated.pairings.append(Pairing(identifier: controllerID, publicKey: publicKey, isAdmin: true))
        guard savePairingChange(updated) else { return false }
        log.notice("\(accessory.info.name) paired with controller \(Self.loggable(controllerID: controllerID))")
        emit(.paired(controllerID: controllerID))
        scheduleAdvertisementUpdate()
        return true
    }

    // MARK: - Pair-verify

    func handlePairVerify(_ body: Data, connection: HAPConnection) -> HAPResponse {
        let request: TLVReader
        do {
            request = try TLVReader(body)
        } catch {
            return .pairingError(state: 2, error: .unknown, status: 400)
        }
        switch (request.uint8(PairingTLV.state), connection.pairVerify) {
        case (1, _):
            return pairVerifyM1(request, connection: connection)
        case (3, let stage?):
            return pairVerifyM3(request, stage: stage, connection: connection)
        case (let step?, _):
            connection.pairVerify = nil
            return .pairingError(state: step &+ 1, error: .unknown, status: 400)
        case (nil, _):
            return .pairingError(state: 2, error: .unknown, status: 400)
        }
    }

    private func pairVerifyM1(_ request: TLVReader, connection: HAPConnection) -> HAPResponse {
        guard let controllerPublicKey = request.data(PairingTLV.publicKey), controllerPublicKey.count == 32,
              let identity = try? loadIdentity(), let longTermKey else {
            return .pairingError(state: 2, error: .unknown)
        }
        let ephemeral = X25519KeyPair()
        do {
            let sharedSecret = try ephemeral.sharedSecret(with: controllerPublicKey)
            let deviceIDData = Data(identity.deviceID.description.utf8)
            let signature = try longTermKey.signature(for: ephemeral.publicKey + deviceIDData + controllerPublicKey)
            let encryptionKey = HAPCrypto.hkdfSHA512(inputKey: sharedSecret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            var inner = TLVBuilder()
            inner.add(PairingTLV.identifier, deviceIDData)
            inner.add(PairingTLV.signature, signature)
            let sealed = try HAPCrypto.chachaSeal(inner.data, key: encryptionKey, nonce: HAPCrypto.nonce(label: "PV-Msg02"))
            connection.pairVerify = HAPConnection.PairVerifyStage(accessoryPublicKey: ephemeral.publicKey, controllerPublicKey: controllerPublicKey,
                                                                  sharedSecret: sharedSecret, encryptionKey: encryptionKey)
            var response = TLVBuilder()
            response.add(PairingTLV.state, uint8: 2)
            response.add(PairingTLV.encryptedData, sealed)
            response.add(PairingTLV.publicKey, ephemeral.publicKey)
            return .tlv(200, response)
        } catch {
            return .pairingError(state: 2, error: .authentication)
        }
    }

    /// M3 of the pair-verify `stage` that M1 started on `connection` (used up whatever the outcome).
    private func pairVerifyM3(_ request: TLVReader, stage: HAPConnection.PairVerifyStage, connection: HAPConnection) -> HAPResponse {
        connection.pairVerify = nil
        guard let encrypted = request.data(PairingTLV.encryptedData), encrypted.count >= 16,
              let plaintext = try? HAPCrypto.chachaOpen(encrypted, key: stage.encryptionKey, nonce: HAPCrypto.nonce(label: "PV-Msg03")) else {
            return .pairingError(state: 4, error: .authentication)
        }
        guard let inner = try? TLVReader(plaintext), let identifierData = inner.data(PairingTLV.identifier),
              let signature = inner.data(PairingTLV.signature), let controllerID = String(validating: identifierData, as: UTF8.self) else {
            return .pairingError(state: 4, error: .unknown)
        }
        // The identifier is not authenticated yet (any peer can send M3): logged sanitized and rate-limited.
        let transport = connection.transport
        guard let pairing = pairings.first(where: { $0.identifier == controllerID }) else {
            warnUnauthenticated("pair-verify", from: transport.remoteAddress,
                                "Pair-verify from unknown controller \(Self.loggable(controllerID: controllerID)) (\(transport.remoteAddress))")
            return .pairingError(state: 4, error: .authentication)
        }
        guard HAPLongTermKey.isValidSignature(signature, for: stage.controllerPublicKey + identifierData + stage.accessoryPublicKey,
                                              publicKey: pairing.publicKey) else {
            warnUnauthenticated("pair-verify", from: transport.remoteAddress,
                                "Pair-verify: invalid signature for controller \(Self.loggable(controllerID: controllerID)) "
                                    + "(\(transport.remoteAddress))")
            return .pairingError(state: 4, error: .authentication)
        }
        let session = HAPSession(controllerID: controllerID, isAdmin: pairing.isAdmin, sharedSecret: stage.sharedSecret,
                                 localAddress: transport.localAddress, remoteAddress: transport.remoteAddress, isIPv6: transport.isIPv6,
                                 zone: transport.zone)
        connection.pendingSession = HAPConnection.PendingSession(
            session: session,
            readKey: HAPCrypto.hkdfSHA512(inputKey: stage.sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
            writeKey: HAPCrypto.hkdfSHA512(inputKey: stage.sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key"))
        var response = TLVBuilder()
        response.add(PairingTLV.state, uint8: 4)
        return .tlv(200, response)
    }

    // MARK: - /pairings

    func handlePairings(_ body: Data, connection: HAPConnection, session: HAPSession) -> HAPResponse {
        guard let request = try? TLVReader(body), let method = request.uint8(PairingTLV.method), request.uint8(PairingTLV.state) == 1 else {
            return .pairingError(state: 2, error: .unknown)
        }
        guard pairings.first(where: { $0.identifier == session.controllerID })?.isAdmin == true else {
            return .pairingError(state: 2, error: .authentication)
        }
        switch method {
        case 3: return addPairing(request)
        case 4: return removePairing(request, connection: connection)
        case 5: return listPairings()
        default: return .pairingError(state: 2, error: .unknown)
        }
    }

    private func addPairing(_ request: TLVReader) -> HAPResponse {
        guard let identifierData = request.data(PairingTLV.identifier), let identifier = String(validating: identifierData, as: UTF8.self),
              !identifier.isEmpty, let publicKey = request.data(PairingTLV.publicKey), publicKey.count == 32,
              let permissions = request.uint8(PairingTLV.permissions) else {
            return .pairingError(state: 2, error: .unknown)
        }
        var updated = state ?? HAPPersistentState()
        let isAdmin = permissions & 1 == 1
        if let index = updated.pairings.firstIndex(where: { $0.identifier == identifier }) {
            guard updated.pairings[index].publicKey == publicKey else { return .pairingError(state: 2, error: .unknown) }
            updated.pairings[index].isAdmin = isAdmin
        } else {
            updated.pairings.append(Pairing(identifier: identifier, publicKey: publicKey, isAdmin: isAdmin))
        }
        // Answered only once saved: a hub told it was added must still be paired after a relaunch.
        if updated.pairings != pairings, !savePairingChange(updated) { return .pairingError(state: 2, error: .unknown) }
        // The controller's open sessions get the new permissions at once (admin-only writes check the session's flag).
        for connection in connections.values where connection.session?.controllerID == identifier { connection.session?.setAdmin(isAdmin) }
        log.notice("Added pairing \(Self.loggable(controllerID: identifier)) (\(isAdmin ? "admin" : "user")) to \(accessory.info.name)")
        var response = TLVBuilder()
        response.add(PairingTLV.state, uint8: 2)
        return .tlv(200, response)
    }

    private func removePairing(_ request: TLVReader, connection initiator: HAPConnection) -> HAPResponse {
        guard let identifierData = request.data(PairingTLV.identifier), let identifier = String(validating: identifierData, as: UTF8.self) else {
            return .pairingError(state: 2, error: .unknown)
        }
        var updated = state ?? HAPPersistentState()
        var removed: Set<String> = []
        if updated.pairings.contains(where: { $0.identifier == identifier }) {
            removed.insert(identifier)
            updated.pairings.removeAll { $0.identifier == identifier }
        }
        if !updated.pairings.contains(where: \.isAdmin) {
            // Without an admin, every remaining pairing goes too (HAP-NodeJS AccessoryInfo.removePairedClient).
            removed.formUnion(updated.pairings.map(\.identifier))
            updated.pairings.removeAll()
        }
        // Answered only once saved: a removed pairing that came back after a relaunch would keep the accessory `sf=0`,
        // refusing pair-setup.
        if updated.pairings != pairings, !savePairingChange(updated) { return .pairingError(state: 2, error: .unknown) }
        for connection in Array(connections.values) {
            guard let controllerID = connection.session?.controllerID, removed.contains(controllerID) else { continue }
            if connection === initiator {
                connection.closeAfterResponse = true
            } else {
                closeConnection(connection, graceful: false)
            }
        }
        if !removed.isEmpty {
            let identifiers = removed.sorted().map { Self.loggable(controllerID: $0) }.joined(separator: ", ")
            log.notice("Removed pairing(s) \(identifiers) from \(accessory.info.name)")
        }
        if updated.pairings.isEmpty && !removed.isEmpty {
            emit(.unpaired)
            scheduleAdvertisementUpdate()
        }
        var response = TLVBuilder()
        response.add(PairingTLV.state, uint8: 2)
        return .tlv(200, response)
    }

    private func listPairings() -> HAPResponse {
        var response = TLVBuilder()
        response.add(PairingTLV.state, uint8: 2)
        for (index, pairing) in pairings.enumerated() {
            if index > 0 { response.addSeparator() }
            response.add(PairingTLV.identifier, string: pairing.identifier)
            response.add(PairingTLV.publicKey, pairing.publicKey)
            response.add(PairingTLV.permissions, uint8: pairing.isAdmin ? 1 : 0)
        }
        return .tlv(200, response)
    }
}

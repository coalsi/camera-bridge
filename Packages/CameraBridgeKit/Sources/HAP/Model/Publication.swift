// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Stable aid/iid assignment follows HAP-NodeJS model/IdentifierCache.ts and Accessory/Service `_assignIDs`; the
// configuration hash follows AccessoryInfo.checkForCurrentConfigurationNumberIncrement (canonical, value-free JSON).

import BridgeSupport
import Foundation
import HAPCore
import Synchronization

/// What the model reports to the server that published it.
enum PublicationSignal: Sendable {
    /// `sequence`: the characteristic's change sequence number (orders concurrent updates).
    case characteristicChanged(Characteristic, value: HAPValue, origin: UUID?, sequence: UInt64)
    case structureChanged
}

/// Binds an accessory tree to persisted identifiers while it is served. Assigns aids/iids synchronously (so a service
/// added at runtime has its iid immediately), looks characteristics up by (aid, iid) and forwards value and structure
/// changes to the server through `signals`.
final class Publication: Sendable {
    private struct Identifiers {
        var iids: [String: UInt64]
        var nextIID: UInt64
        var aids: [String: UInt64]
        var nextAID: UInt64
        var dirty = false

        mutating func iid(for key: String) -> UInt64 {
            if let existing = iids[key] { return existing }
            let assigned = nextIID
            nextIID += 1
            iids[key] = assigned
            dirty = true
            return assigned
        }

        mutating func aid(for key: String) -> UInt64 {
            if let existing = aids[key] { return existing }
            let assigned = nextAID
            nextAID += 1
            aids[key] = assigned
            dirty = true
            return assigned
        }
    }

    let root: Accessory
    private let identifiers: Mutex<Identifiers>
    private let signals: AsyncStream<PublicationSignal>.Continuation?
    private let bound = Mutex(true)

    /// Identifiers above this are treated as corrupt state and assigned anew (controllers read JSON numbers as doubles).
    static let maximumIdentifier: UInt64 = 1 << 53
    private static let log = Log(category: "hap")

    init(root: Accessory, state: HAPPersistentState, signals: AsyncStream<PublicationSignal>.Continuation? = nil) {
        self.root = root
        self.signals = signals
        let (iids, nextIID) = Self.sanitized(state.iids, next: state.nextIID)
        let (aids, nextAID) = Self.sanitized(state.aids, next: state.nextAID)
        identifiers = Mutex(Identifiers(iids: iids, nextIID: nextIID, aids: aids, nextAID: nextAID))
    }

    /// Drops out-of-range entries of a persisted identifier table and makes `next` exceed every kept value.
    private static func sanitized(_ table: [String: UInt64], next: UInt64) -> ([String: UInt64], UInt64) {
        let kept = table.filter { (2...maximumIdentifier).contains($0.value) }
        if kept.count != table.count { log.warning("Ignoring \(table.count - kept.count) out-of-range persisted HAP identifier(s)") }
        let floor = (kept.values.max() ?? 1) + 1
        let next = (2...maximumIdentifier).contains(next) ? max(next, floor) : floor
        return (kept, next)
    }

    // MARK: - Assignment

    /// Assigns aid/iid to every accessory, service and characteristic (existing keys keep their numbers).
    func assignIDs() {
        guard bound.withLock({ $0 }) else { return }
        identifiers.withLock { ids in
            assign(root, aid: 1, prefix: "", ids: &ids)
            // Two bridged accessories with the same stable key (e.g. sensors sharing a camera's serial number) must not
            // share an aid: later ones get `key#2`, `key#3`… in bridge order (`addBridgedAccessory` logs a warning).
            var usedKeys = Set<String>()
            for accessory in root.bridgedAccessories {
                let key = Self.unique(accessory.stableKey, in: &usedKeys)
                assign(accessory, aid: ids.aid(for: "aid|" + key), prefix: key + "|", ids: &ids)
            }
        }
    }

    private func assign(_ accessory: Accessory, aid: UInt64, prefix: String, ids: inout Identifiers) {
        accessory.bind(aid: aid, publication: self)
        var usedServiceKeys = Set<String>()
        for service in accessory.services {
            let serviceKey = Self.unique(prefix + service.type.uuid + (service.subtype.map { "/" + $0 } ?? ""), in: &usedServiceKeys)
            let isInformation = service.type.fullUUID == ServiceType.accessoryInformation.fullUUID && serviceKey == prefix + service.type.uuid
            service.bind(iid: isInformation ? 1 : ids.iid(for: serviceKey), publication: self)
            var usedCharacteristicKeys = Set<String>()
            for characteristic in service.characteristics {
                let key = Self.unique(serviceKey + "/" + characteristic.type.uuid, in: &usedCharacteristicKeys)
                characteristic.bind(aid: aid, iid: ids.iid(for: key), publication: self)
            }
        }
    }

    /// `key`, or `key#2`, `key#3`… when an identical service/characteristic key already occurs on the accessory.
    private static func unique(_ key: String, in used: inout Set<String>) -> String {
        var candidate = key
        var counter = 2
        while used.contains(candidate) {
            candidate = key + "#\(counter)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// Copies the identifier tables into `state` (for saving).
    func persistentIdentifiers(into state: HAPPersistentState) -> HAPPersistentState {
        var state = state
        identifiers.withLock { ids in
            state.iids = ids.iids
            state.nextIID = ids.nextIID
            state.aids = ids.aids
            state.nextAID = ids.nextAID
            ids.dirty = false
        }
        return state
    }

    var hasUnsavedIdentifiers: Bool { identifiers.withLock { $0.dirty } }

    /// Detaches the tree (breaks the model → publication references). Later changes are no longer reported.
    func unbind() {
        bound.withLock { $0 = false }
        root.unbind()
        signals?.finish()
    }

    // MARK: - Lookup

    /// The root followed by the bridged accessories.
    var accessories: [Accessory] { [root] + root.bridgedAccessories }

    func accessory(aid: UInt64) -> Accessory? {
        accessories.first { $0.aid == aid }
    }

    func characteristic(aid: UInt64, iid: UInt64) -> (accessory: Accessory, characteristic: Characteristic)? {
        guard let accessory = accessory(aid: aid) else { return nil }
        for service in accessory.services {
            if let match = service.characteristics.first(where: { $0.iid == iid }) { return (accessory, match) }
        }
        return nil
    }

    // MARK: - Signals from the model

    func characteristicDidChange(_ characteristic: Characteristic, value: HAPValue, origin: UUID?, sequence: UInt64) {
        signals?.yield(.characteristicChanged(characteristic, value: value, origin: origin, sequence: sequence))
    }

    func structureDidChange() {
        guard bound.withLock({ $0 }) else { return }
        assignIDs()
        signals?.yield(.structureChanged)
    }

    // MARK: - Configuration hash

    /// SHA-256 (hex) of the canonical value-free `/accessories` JSON: accessories by aid, services and characteristics
    /// by iid, sorted `perms`/`valid-values`/`linked`, sorted keys. When the accessory has characteristics whose *value* is
    /// configuration (`staticValueTypes`: the camera's supported stream and recording configurations), the hash is
    /// `<structure>.<values>`: a controller caches those values from `/accessories` and re-reads them only when `c#` moves
    /// (a hub that keeps a stale Supported*RecordingConfiguration never selects a new one, and recordings stop). An
    /// accessory without such characteristics has the plain structure hash it always had.
    func configurationHash() -> String {
        let accessories = self.accessories.sorted { $0.aid < $1.aid }.map { HAPJSONEncoding.accessory($0, includeValues: false, canonical: true) }
        let json: HAPJSON = .array(accessories)
        let structure = HAPCrypto.sha256(json.serialized(sortedKeys: true)).hexString
        guard let values = staticValueDigest() else { return structure }
        return structure + "." + values
    }

    /// Characteristics whose values are part of the configuration controllers cache (HAP-NodeJS bumps `c#` only for
    /// structure; its camera accessories never change these values at runtime, CameraBridge's do with the camera's picture
    /// size and recording options).
    static let staticValueTypes: Set<String> = [
        CharacteristicType.supportedVideoStreamConfiguration.uuid, CharacteristicType.supportedAudioStreamConfiguration.uuid,
        CharacteristicType.supportedRTPConfiguration.uuid, CharacteristicType.supportedCameraRecordingConfiguration.uuid,
        CharacteristicType.supportedVideoRecordingConfiguration.uuid, CharacteristicType.supportedAudioRecordingConfiguration.uuid,
        CharacteristicType.supportedDataStreamTransportConfiguration.uuid,
    ]

    /// SHA-256 (hex) over the `(aid, iid, value)` of every static-value characteristic, nil when there is none.
    private func staticValueDigest() -> String? {
        var input = Data()
        for accessory in accessories.sorted(by: { $0.aid < $1.aid }) {
            for service in accessory.services.sorted(by: { $0.iid < $1.iid }) {
                for characteristic in service.characteristics.sorted(by: { $0.iid < $1.iid })
                where Self.staticValueTypes.contains(characteristic.type.uuid) {
                    guard let data = characteristic.value.dataValue, !data.isEmpty else { continue }   // not populated: nothing to cache
                    input.append(Data("\(accessory.aid).\(characteristic.iid):\(data.base64EncodedString())\n".utf8))
                }
            }
        }
        return input.isEmpty ? nil : HAPCrypto.sha256(input).hexString
    }
}

/// The `c#` rule: bump (1…65535, wrapping to 1) when the configuration hash changes; the first hash is only recorded.
enum ConfigurationNumber {
    /// Returns true when `c#` changed.
    static func apply(hash: String, to state: inout HAPPersistentState) -> Bool {
        guard state.configHash != hash else { return false }
        let first = state.configHash.isEmpty
        state.configHash = hash
        if first { return false }
        state.configNumber = state.configNumber >= 65535 || state.configNumber == 0 ? 1 : state.configNumber + 1
        return true
    }

    /// Why `c#` moved from the stored hash `old` to `new`, for the log line: only the camera's supported stream or recording
    /// values (also: they were added to the hash by an update) or the structure.
    static func cause(from old: String, to new: String) -> String {
        let (oldStructure, oldValues) = parts(old)
        let (newStructure, newValues) = parts(new)
        guard oldStructure == newStructure else { return "the accessory's services or characteristics changed" }
        if oldValues == nil { return "its supported stream and recording values are part of the configuration now" }
        return "its supported video, audio or recording configuration changed" + (newValues == nil ? " (removed)" : "")
    }

    private static func parts(_ hash: String) -> (structure: Substring, values: Substring?) {
        guard let dot = hash.firstIndex(of: ".") else { return (hash[...], nil) }
        return (hash[..<dot], hash[hash.index(after: dot)...])
    }
}

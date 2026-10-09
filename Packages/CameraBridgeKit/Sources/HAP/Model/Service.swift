// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Service construction (required characteristics + Name from the display name) follows HAP-NodeJS Service.ts.

import Foundation
import Synchronization

public final class Service: Sendable {
    private final class WeakService: Sendable {
        weak let service: Service?
        init(_ service: Service) { self.service = service }
    }

    private struct State {
        var iid: UInt64 = 0
        var characteristics: [Characteristic]
        var isPrimary = false
        var isHidden = false
        var linked: [WeakService] = []
        var publication: Publication?
    }

    public let type: ServiceType
    public let subtype: String?
    private let state: Mutex<State>

    /// Creates required characteristics (+ Name if name given).
    public init(_ type: ServiceType, name: String? = nil, subtype: String? = nil) {
        self.type = type
        self.subtype = subtype
        var characteristics = type.required.map { Characteristic($0) }
        if let name {
            if let existing = characteristics.first(where: { $0.type.fullUUID == CharacteristicType.name.fullUUID }) {
                existing.update(.string(name))
            } else {
                characteristics.append(Characteristic(.name, value: .string(name)))
            }
        }
        state = Mutex(State(characteristics: characteristics))
    }

    public var iid: UInt64 { state.withLock { $0.iid } }

    public var characteristics: [Characteristic] { state.withLock { $0.characteristics } }

    public var isPrimary: Bool {
        get { state.withLock { $0.isPrimary } }
        set { change { $0.isPrimary = newValue } }
    }

    public var isHidden: Bool {
        get { state.withLock { $0.isHidden } }
        set { change { $0.isHidden = newValue } }
    }

    /// Linked services (held weakly: a link never keeps a removed service alive).
    public var linkedServices: [Service] { state.withLock { $0.linked.compactMap(\.service) } }

    /// Returns the existing characteristic or adds it.
    @discardableResult
    public func characteristic(_ type: CharacteristicType) -> Characteristic {
        var added = false
        let (characteristic, publication) = state.withLock { state -> (Characteristic, Publication?) in
            if let existing = state.characteristics.first(where: { $0.type.fullUUID == type.fullUUID }) { return (existing, state.publication) }
            let created = Characteristic(type)
            state.characteristics.append(created)
            added = true
            return (created, state.publication)
        }
        if added { publication?.structureDidChange() }
        return characteristic
    }

    public func existingCharacteristic(_ type: CharacteristicType) -> Characteristic? {
        state.withLock { $0.characteristics.first { $0.type.fullUUID == type.fullUUID } }
    }

    public func addLinkedService(_ service: Service) {
        change { state in
            guard !state.linked.contains(where: { $0.service === service }) else { return }
            state.linked.append(WeakService(service))
        }
    }

    // MARK: - Internal

    func bind(iid: UInt64, publication: Publication?) {
        state.withLock {
            $0.iid = iid
            $0.publication = publication
        }
    }

    func unbind() {
        let characteristics = state.withLock { state -> [Characteristic] in
            state.publication = nil
            return state.characteristics
        }
        for characteristic in characteristics { characteristic.unbind() }
    }

    private func change(_ body: (inout State) -> Void) {
        let publication = state.withLock { state -> Publication? in
            body(&state)
            return state.publication
        }
        publication?.structureDidChange()
    }
}

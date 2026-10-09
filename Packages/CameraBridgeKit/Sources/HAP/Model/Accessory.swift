// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Accessory structure (information service, bridged accessories, identify, resource requests) follows HAP-NodeJS
// Accessory.ts.

import BridgeSupport
import Foundation
import HAPCore
import Synchronization

public struct AccessoryInfo: Sendable, Codable, Hashable {
    public var name: String
    public var manufacturer: String
    public var model: String
    public var serialNumber: String
    public var firmwareRevision: String
    public var hardwareRevision: String?

    public init(name: String, manufacturer: String, model: String, serialNumber: String, firmwareRevision: String, hardwareRevision: String? = nil) {
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
    }
}

/// POST /resource body (`{"resource-type":"image","image-width","image-height","aid"?,"reason"?}`).
public struct HAPResourceRequest: Sendable {
    public var type: String
    public var width: Int
    public var height: Int
    public var aid: UInt64?
    public var reason: Int?

    public init(type: String, width: Int, height: Int, aid: UInt64? = nil, reason: Int? = nil) {
        self.type = type
        self.width = width
        self.height = height
        self.aid = aid
        self.reason = reason
    }
}

public final class Accessory: Sendable {
    typealias ResourceHandler = @Sendable (HAPResourceRequest, HAPRequestContext) async throws(HAPStatus) -> Data

    private struct State {
        var aid: UInt64
        var services: [Service]
        /// The ProtocolInformation service `init` added; left out of `services` while bridged.
        let protocolInformation: Service
        var bridged: [Accessory] = []
        var isBridged = false
        var reachable = true
        var identifyHandler: (@Sendable () -> Void)?
        var resourceHandler: ResourceHandler?
        var publication: Publication?
    }

    public let category: AccessoryCategory
    public let info: AccessoryInfo
    /// Key under which a bridged accessory's aid is persisted: `stableKey` if given, else the serial number (or name).
    public let stableKey: String
    private let state: Mutex<State>
    private static let log = Log(category: "hap")
    /// HomeKit limits (research brief §3.4): bridged accessories per bridge, services per accessory.
    static let maximumBridgedAccessories = 149
    static let maximumServices = 100

    /// Adds AccessoryInformation (iid 1) + ProtocolInformation (published only while the accessory is not bridged).
    public convenience init(info: AccessoryInfo, category: AccessoryCategory) {
        self.init(info: info, category: category, stableKey: info.serialNumber.isEmpty ? info.name : info.serialNumber)
    }

    /// `stableKey` identifies this accessory when it is bridged (e.g. `camera.<uuid>.<sensor>`); its aid is persisted under it.
    public init(info: AccessoryInfo, category: AccessoryCategory, stableKey: String) {
        self.category = category
        self.info = info
        self.stableKey = stableKey
        let information = Service(.accessoryInformation)
        let values: [(CharacteristicType, String)] = [(.manufacturer, info.manufacturer), (.model, info.model), (.name, info.name),
                                                     (.serialNumber, info.serialNumber), (.firmwareRevision, info.firmwareRevision)]
        for (type, value) in values { information.characteristic(type).update(.string(value)) }
        if let hardware = info.hardwareRevision { information.characteristic(.hardwareRevision).update(.string(hardware)) }
        let protocolInformation = Service(.protocolInformation)
        protocolInformation.characteristic(.version).update(.string("1.1.0"))
        state = Mutex(State(aid: 1, services: [information, protocolInformation], protocolInformation: protocolInformation))
        information.characteristic(.identify).onWrite { [weak self] _, _ async throws(HAPStatus) -> HAPValue? in
            self?.identify()
            return nil
        }
    }

    /// 1 when published directly; ≥ 2 when bridged.
    public var aid: UInt64 { state.withLock { $0.aid } }
    /// The services this accessory publishes, in order. A bridged accessory leaves out the ProtocolInformation service
    /// `init` added: like HAP-NodeJS (Accessory.ts `publish`), only the published accessory (aid 1) carries one.
    public var services: [Service] {
        state.withLock { state in
            state.isBridged ? state.services.filter { $0 !== state.protocolInformation } : state.services
        }
    }
    /// Non-empty only for bridges.
    public var bridgedAccessories: [Accessory] { state.withLock { $0.bridged } }
    public var informationService: Service { state.withLock { $0.services[0] } }

    @discardableResult
    public func addService(_ service: Service) -> Service {
        var count = 0
        change { state in
            guard !state.services.contains(where: { $0 === service }) else { return }
            state.services.append(service)
            let hidden = state.isBridged ? state.protocolInformation : nil
            count = state.services.count(where: { $0 !== hidden })
        }
        if count > Self.maximumServices {
            Self.log.warning("\(info.name) has \(count) services; HomeKit accepts at most \(Self.maximumServices) per accessory")
        }
        return service
    }

    /// Removes a service (the AccessoryInformation service cannot be removed).
    public func removeService(_ service: Service) {
        var removed = false
        change { state in
            guard let index = state.services.firstIndex(where: { $0 === service }), index > 0 else { return }
            state.services.remove(at: index)
            removed = true
        }
        if removed { service.unbind() }
    }

    /// aid assigned stably (persisted by `stableKey`: serial number by default). Accessories sharing a stable key get
    /// distinct aids in bridge order (a warning is logged; give each one its own `stableKey`).
    public func addBridgedAccessory(_ accessory: Accessory) {
        guard accessory !== self else { return }
        let protocolInformation = accessory.state.withLock { state -> Service in
            state.isBridged = true
            return state.protocolInformation
        }
        protocolInformation.unbind()   // no longer published (it may have been, as a standalone accessory)
        var added = false
        var count = 0
        var namesake: Accessory?
        change { state in
            guard !state.bridged.contains(where: { $0 === accessory }) else { return }
            namesake = state.bridged.first { $0.stableKey == accessory.stableKey }
            state.bridged.append(accessory)
            added = true
            count = state.bridged.count
        }
        guard added else { return }
        if let namesake {
            Self.log.warning("Bridged accessory \(accessory.info.name) has the same stable key as \(namesake.info.name); its aid is persisted "
                             + "under a derived key that depends on the bridge order")
        }
        if count > Self.maximumBridgedAccessories {
            Self.log.warning("\(info.name) has \(count) bridged accessories; HomeKit accepts at most \(Self.maximumBridgedAccessories)")
        }
    }

    public func removeBridgedAccessory(_ accessory: Accessory) {
        var removed = false
        change { state in
            guard let index = state.bridged.firstIndex(where: { $0 === accessory }) else { return }
            state.bridged.remove(at: index)
            removed = true
        }
        if removed {
            accessory.state.withLock { $0.isBridged = false }
            accessory.unbind()
        }
    }

    public func onIdentify(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.identifyHandler = handler }
    }

    public func onResourceRequest(_ handler: @escaping @Sendable (HAPResourceRequest, HAPRequestContext) async throws(HAPStatus) -> Data) {
        state.withLock { $0.resourceHandler = handler }
    }

    /// Bridged accessories only: while unreachable, reads and writes of its characteristics fail with -70402.
    public func setReachable(_ reachable: Bool) {
        state.withLock { $0.reachable = reachable }
    }

    // MARK: - Internal

    var isReachable: Bool { state.withLock { $0.reachable } }
    var isBridged: Bool { state.withLock { $0.isBridged } }
    var resourceHandler: ResourceHandler? { state.withLock { $0.resourceHandler } }

    func identify() {
        let handler = state.withLock { $0.identifyHandler }
        handler?()
    }

    func bind(aid: UInt64, publication: Publication?) {
        state.withLock {
            $0.aid = aid
            $0.publication = publication
        }
    }

    func unbind() {
        let (services, bridged) = state.withLock { state -> ([Service], [Accessory]) in
            state.publication = nil
            return (state.services, state.bridged)
        }
        for service in services { service.unbind() }
        for accessory in bridged { accessory.unbind() }
    }

    private func change(_ body: (inout State) -> Void) {
        let publication = state.withLock { state -> Publication? in
            body(&state)
            return state.publication
        }
        publication?.structureDidChange()
    }
}

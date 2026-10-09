import Foundation
import HAP

/// The parsed `/accessories` document: accessories → services → characteristics, with lookup by HAP type.
/// Types are compared in short form ("22" for `00000022-0000-1000-8000-0026BB765291`), case-insensitively.
public struct HAPAccessoryDatabase: Sendable {
    public struct CharacteristicInfo: Sendable {
        public var aid: UInt64
        public var iid: UInt64
        public var type: String
        public var permissions: [String]
        public var format: String?
        public var value: HAPJSON?
        public var json: HAPJSONObject

        public var id: HAPCharacteristicID { HAPCharacteristicID(aid: aid, iid: iid) }
        public func matches(_ type: CharacteristicType) -> Bool { HAPAccessoryDatabase.sameType(self.type, type.uuid) }
    }

    public struct ServiceInfo: Sendable {
        public var aid: UInt64
        public var iid: UInt64
        public var type: String
        public var isPrimary: Bool
        public var isHidden: Bool
        public var linked: [UInt64]
        public var characteristics: [CharacteristicInfo]

        public func matches(_ type: ServiceType) -> Bool { HAPAccessoryDatabase.sameType(self.type, type.uuid) }

        public func characteristic(_ type: CharacteristicType) -> CharacteristicInfo? {
            characteristics.first { $0.matches(type) }
        }
    }

    public struct AccessoryInfo: Sendable {
        public var aid: UInt64
        public var services: [ServiceInfo]

        public func services(_ type: ServiceType) -> [ServiceInfo] { services.filter { $0.matches(type) } }
        public func service(_ type: ServiceType) -> ServiceInfo? { services.first { $0.matches(type) } }
        public func service(iid: UInt64) -> ServiceInfo? { services.first { $0.iid == iid } }

        /// The first characteristic of `type`, optionally only inside services of `serviceType`.
        public func characteristic(_ type: CharacteristicType, in serviceType: ServiceType? = nil) -> CharacteristicInfo? {
            for service in services where serviceType.map({ service.matches($0) }) ?? true {
                if let found = service.characteristic(type) { return found }
            }
            return nil
        }

        /// Value of the AccessoryInformation characteristic `type` (e.g. `.name`, `.serialNumber`).
        public func information(_ type: CharacteristicType) -> String? {
            service(.accessoryInformation)?.characteristic(type)?.value?.stringValue
        }
    }

    public var accessories: [AccessoryInfo]
    public var json: HAPJSON

    public init(json: HAPJSON) throws {
        guard let list = json["accessories"]?.arrayValue else { throw HAPControllerError.malformedResponse("/accessories: no accessories") }
        var accessories: [AccessoryInfo] = []
        for accessoryJSON in list {
            guard let aid = accessoryJSON["aid"]?.unsignedValue, let servicesJSON = accessoryJSON["services"]?.arrayValue else {
                throw HAPControllerError.malformedResponse("/accessories: accessory without aid or services")
            }
            var services: [ServiceInfo] = []
            for serviceJSON in servicesJSON {
                guard let iid = serviceJSON["iid"]?.unsignedValue, let type = serviceJSON["type"]?.stringValue,
                      let characteristicsJSON = serviceJSON["characteristics"]?.arrayValue else {
                    throw HAPControllerError.malformedResponse("/accessories: service without iid, type or characteristics")
                }
                var characteristics: [CharacteristicInfo] = []
                for characteristicJSON in characteristicsJSON {
                    guard let object = characteristicJSON.objectValue, let iid = characteristicJSON["iid"]?.unsignedValue,
                          let type = characteristicJSON["type"]?.stringValue else {
                        throw HAPControllerError.malformedResponse("/accessories: characteristic without iid or type")
                    }
                    let permissions = characteristicJSON["perms"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    characteristics.append(CharacteristicInfo(aid: aid, iid: iid, type: type, permissions: permissions,
                                                              format: characteristicJSON["format"]?.stringValue,
                                                              value: characteristicJSON["value"], json: object))
                }
                services.append(ServiceInfo(aid: aid, iid: iid, type: type, isPrimary: serviceJSON["primary"]?.boolValue ?? false,
                                            isHidden: serviceJSON["hidden"]?.boolValue ?? false,
                                            linked: serviceJSON["linked"]?.arrayValue?.compactMap(\.unsignedValue) ?? [],
                                            characteristics: characteristics))
            }
            accessories.append(AccessoryInfo(aid: aid, services: services))
        }
        self.accessories = accessories
        self.json = json
    }

    public func accessory(aid: UInt64) -> AccessoryInfo? { accessories.first { $0.aid == aid } }

    /// Every characteristic of `type` on every accessory (e.g. all MotionDetected).
    public func characteristics(_ type: CharacteristicType) -> [CharacteristicInfo] {
        accessories.flatMap(\.services).flatMap(\.characteristics).filter { $0.matches(type) }
    }

    /// Every service of `type` on every accessory.
    public func services(_ type: ServiceType) -> [ServiceInfo] {
        accessories.flatMap(\.services).filter { $0.matches(type) }
    }

    /// The characteristic `type` inside the first service of `serviceType` on `aid` (default: the first accessory).
    public func characteristic(_ type: CharacteristicType, in serviceType: ServiceType, aid: UInt64? = nil) throws -> HAPCharacteristicID {
        let candidates = aid.map { aid in accessories.filter { $0.aid == aid } } ?? accessories
        for accessory in candidates {
            if let found = accessory.characteristic(type, in: serviceType) { return found.id }
        }
        throw HAPControllerError.notFound("\(type.name) in \(serviceType.name)")
    }

    /// "22", "0x22", "00000022-0000-1000-8000-0026BB765291" → "22"; other UUIDs uppercased.
    public static func shortType(_ type: String) -> String {
        let upper = type.uppercased()
        let suffix = "-0000-1000-8000-0026BB765291"
        if upper.hasSuffix(suffix), upper.count == 36 {
            let prefix = upper.prefix(8).drop { $0 == "0" }
            return prefix.isEmpty ? "0" : String(prefix)
        }
        let trimmed = upper.hasPrefix("0X") ? String(upper.dropFirst(2)) : upper
        let short = trimmed.drop { $0 == "0" }
        return short.isEmpty ? "0" : String(short)
    }

    static func sameType(_ lhs: String, _ rhs: String) -> Bool { shortType(lhs) == shortType(rhs) }
}

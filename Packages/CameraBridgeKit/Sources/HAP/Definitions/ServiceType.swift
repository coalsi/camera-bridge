import Foundation

public struct ServiceType: Sendable, Hashable {
    public let uuid: String
    public let name: String
    public let required: [CharacteristicType]
    public let optional: [CharacteristicType]

    public init(uuid: String, name: String, required: [CharacteristicType], optional: [CharacteristicType] = []) {
        self.uuid = uuid
        self.name = name
        self.required = required
        self.optional = optional
    }

    /// "00000085-0000-1000-8000-0026BB765291"
    public var fullUUID: String { hapFullUUID(uuid) }
}

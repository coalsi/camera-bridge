import Foundation

public struct CharacteristicType: Sendable, Hashable {
    /// Short form ("22") for Apple-defined types; full UUID otherwise.
    public let uuid: String
    public let name: String
    public let format: HAPFormat
    public let permissions: HAPPermissions
    public let unit: HAPUnit?
    public let minValue: Double?
    public let maxValue: Double?
    public let minStep: Double?
    public let validValues: [Int]?
    public let maxLength: Int?

    public init(uuid: String, name: String, format: HAPFormat, permissions: HAPPermissions, unit: HAPUnit? = nil,
                minValue: Double? = nil, maxValue: Double? = nil, minStep: Double? = nil, validValues: [Int]? = nil, maxLength: Int? = nil) {
        self.uuid = uuid
        self.name = name
        self.format = format
        self.permissions = permissions
        self.unit = unit
        self.minValue = minValue
        self.maxValue = maxValue
        self.minStep = minStep
        self.validValues = validValues
        self.maxLength = maxLength
    }

    /// "00000022-0000-1000-8000-0026BB765291"
    public var fullUUID: String { hapFullUUID(uuid) }
}

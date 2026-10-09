// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// The `/accessories` object layout follows HAP-NodeJS Accessory/Service/Characteristic `toHAP` and
// `internalHAPRepresentation`.

import Foundation

/// `/accessories` JSON for the model.
enum HAPJSONEncoding {
    /// `{"aid", "services":[…]}`. `values` supplies each characteristic's value (defaults to its stored value).
    static func accessory(_ accessory: Accessory, includeValues: Bool, canonical: Bool = false,
                          values: [ObjectIdentifier: HAPValue] = [:]) -> HAPJSON {
        var services = accessory.services
        if canonical { services.sort { $0.iid < $1.iid } }
        return ["aid": .unsigned(accessory.aid),
                "services": .array(services.map { service($0, includeValues: includeValues, canonical: canonical, values: values) })]
    }

    static func service(_ service: Service, includeValues: Bool, canonical: Bool = false, values: [ObjectIdentifier: HAPValue] = [:]) -> HAPJSON {
        var characteristics = service.characteristics
        if canonical { characteristics.sort { $0.iid < $1.iid } }
        var object = HAPJSONObject([("iid", .unsigned(service.iid)), ("type", .string(service.type.uuid))])
        object["characteristics"] = .array(characteristics.map {
            characteristic($0, includeValue: includeValues, canonical: canonical, value: values[ObjectIdentifier($0)])
        })
        if service.isPrimary { object["primary"] = .bool(true) }
        if service.isHidden { object["hidden"] = .bool(true) }
        var linked = service.linkedServices.map(\.iid).filter { $0 > 0 }
        if canonical { linked.sort() }
        if !linked.isEmpty { object["linked"] = .array(linked.map { .unsigned($0) }) }
        return .object(object)
    }

    /// One characteristic. Without "pr" the value is omitted; ProgrammableSwitchEvent's value is always null.
    static func characteristic(_ characteristic: Characteristic, includeValue: Bool, canonical: Bool = false, value: HAPValue? = nil) -> HAPJSON {
        let type = characteristic.type
        var perms = type.permissions.jsonStrings
        if canonical { perms.sort() }
        var object = HAPJSONObject([("iid", .unsigned(characteristic.iid)), ("type", .string(type.uuid)),
                                    ("perms", .array(perms.map { .string($0) })), ("format", .string(type.format.rawValue))])
        if includeValue, type.permissions.contains(.pairedRead) {
            object["value"] = characteristic.isEventOnly ? .null : characteristic.jsonValue(value ?? characteristic.value)
        }
        object["description"] = .string(type.name)
        metadata(characteristic, canonical: canonical, into: &object)
        return .object(object)
    }

    /// `unit`, `minValue`, `maxValue`, `minStep`, `maxLen`, `valid-values` (GET `meta=1` and `/accessories`).
    static func metadata(_ characteristic: Characteristic, canonical: Bool = false, into object: inout HAPJSONObject) {
        let type = characteristic.type
        if let unit = type.unit { object["unit"] = .string(unit.rawValue) }
        if let minimum = characteristic.effectiveMinValue { object["minValue"] = .double(minimum) }
        if let maximum = characteristic.effectiveMaxValue { object["maxValue"] = .double(maximum) }
        if let step = type.minStep { object["minStep"] = .double(step) }
        if let maxLength = type.maxLength { object["maxLen"] = .int(Int64(maxLength)) }
        if var valid = characteristic.effectiveValidValues {
            if canonical { valid.sort() }
            object["valid-values"] = .array(valid.map { .int(Int64($0)) })
        }
    }
}

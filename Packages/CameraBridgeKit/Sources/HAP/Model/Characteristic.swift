// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Default values, client-value validation and outgoing value formatting follow HAP-NodeJS Characteristic.ts
// (getDefaultValue, validateClientSuppliedValue, validateUserInput) and util/request-util.ts
// (formatOutgoingCharacteristicValue).

import BridgeSupport
import Foundation
import Synchronization

public struct ObserverToken: Sendable, Hashable {
    let id: UUID

    init() {
        id = UUID()
    }
}

public final class Characteristic: Sendable {
    typealias ReadHandler = @Sendable (HAPRequestContext?) async throws(HAPStatus) -> HAPValue
    typealias WriteHandler = @Sendable (HAPValue, HAPRequestContext) async throws(HAPStatus) -> HAPValue?
    typealias Observer = @Sendable (HAPValue, UUID?) -> Void

    private struct State {
        var value: HAPValue
        var iid: UInt64 = 0
        var aid: UInt64 = 0
        var validValuesOverride: [Int]?
        var minValueOverride: Double?
        var maxValueOverride: Double?
        var readHandler: ReadHandler?
        var writeHandler: WriteHandler?
        var observers: [(token: ObserverToken, observer: Observer)] = []
        var publication: Publication?
        /// Incremented by every stored value; orders change notifications.
        var sequence: UInt64 = 0
        /// Newest change the server turned into events.
        var dispatchedSequence: UInt64 = 0
    }

    public let type: CharacteristicType
    private let state: Mutex<State>
    private static let log = Log(category: "hap")

    /// Default value derived from format/min.
    public init(_ type: CharacteristicType, value: HAPValue? = nil) {
        self.type = type
        let initial = Self.defaultValue(for: type)
        state = Mutex(State(value: initial))
        // The default goes through the same clamping (a type's minValue may lie outside its format's range).
        if let normalized = normalize(value ?? initial) ?? normalize(initial) {
            state.withLock { $0.value = normalized }
        }
    }

    /// Assigned when the accessory is published.
    public var iid: UInt64 { state.withLock { $0.iid } }

    var hasReadHandler: Bool { state.withLock { $0.readHandler != nil } }

    /// aid of the accessory this characteristic belongs to (0 until published).
    var aid: UInt64 { state.withLock { $0.aid } }

    /// Sequence number of the most recently stored value.
    var changeSequence: UInt64 { state.withLock { $0.sequence } }

    /// Server side: false when a newer change of this characteristic was already turned into events (the change with
    /// `sequence` is stale), otherwise records it as the newest.
    func claimEventDispatch(_ sequence: UInt64) -> Bool {
        state.withLock { state in
            guard sequence > state.dispatchedSequence else { return false }
            state.dispatchedSequence = sequence
            return true
        }
    }

    public var value: HAPValue { state.withLock { $0.value } }

    public var validValuesOverride: [Int]? {
        get { state.withLock { $0.validValuesOverride } }
        set { structureChange { $0.validValuesOverride = newValue } }
    }

    public var minValueOverride: Double? {
        get { state.withLock { $0.minValueOverride } }
        set { structureChange { $0.minValueOverride = newValue } }
    }

    public var maxValueOverride: Double? {
        get { state.withLock { $0.maxValueOverride } }
        set { structureChange { $0.maxValueOverride = newValue } }
    }

    /// Updates the stored value and notifies subscribed controllers if it changed (always notifies for
    /// event-type characteristics: ProgrammableSwitchEvent). `origin` = session that caused it (not notified).
    ///
    /// Safe to call from any thread. Controllers always end with the newest value: when concurrent updates report
    /// their changes out of order, the server drops the older one. Observers run on the updating thread and may see
    /// concurrent updates out of order; read `value` for the current state.
    public func update(_ value: HAPValue, origin: UUID? = nil) {
        guard let normalized = normalize(value) else { return }
        let (changed, sequence) = store(normalized)
        if changed || isEventOnly { notify(normalized, origin: origin, sequence: sequence) }
    }

    /// Always notifies (stateless).
    public func sendEvent(_ value: HAPValue) {
        guard let normalized = normalize(value) else { return }
        let (_, sequence) = store(normalized)
        notify(normalized, origin: nil, sequence: sequence)
    }

    public func onRead(_ handler: @escaping @Sendable (HAPRequestContext?) async throws(HAPStatus) -> HAPValue) {
        state.withLock { $0.readHandler = handler }
    }

    /// Handler returns an optional write-response value (for "r":true writes, e.g. SetupDataStreamTransport).
    public func onWrite(_ handler: @escaping @Sendable (HAPValue, HAPRequestContext) async throws(HAPStatus) -> HAPValue?) {
        state.withLock { $0.writeHandler = handler }
    }

    public func addObserver(_ observer: @escaping @Sendable (HAPValue, UUID?) -> Void) -> ObserverToken {
        let token = ObserverToken()
        state.withLock { $0.observers.append((token, observer)) }
        return token
    }

    public func removeObserver(_ token: ObserverToken) {
        state.withLock { $0.observers.removeAll { $0.token == token } }
    }

    // MARK: - Internal: identity and publication

    /// ProgrammableSwitchEvent: reads return null and every update is an event.
    var isEventOnly: Bool { type.fullUUID == CharacteristicType.programmableSwitchEvent.fullUUID }

    /// Control points — writable tlv8 characteristics without events (SetupEndpoints, SelectedRTPStreamConfiguration,
    /// SetupDataStreamTransport) — carry one HAP session's request or response (SetupEndpoints: SRTP keys). A
    /// controller's write, a write response and a read handler's result are never stored, so `value` stays what the
    /// accessory set with `update`; the server asks their read handler on every `/accessories` (deviation from
    /// HAP-NodeJS, which stores them and serves them to every controller).
    var isControlPoint: Bool {
        let permissions = type.permissions
        return type.format == .tlv8 && permissions.contains(.pairedWrite) && !permissions.contains(.events)
    }

    /// Delivered at once instead of after the 250 ms coalescing window (HAP-NodeJS immediate-delivery list).
    var deliversImmediately: Bool {
        let uuid = type.fullUUID
        return uuid == CharacteristicType.programmableSwitchEvent.fullUUID || uuid == CharacteristicType.motionDetected.fullUUID
            || uuid == CharacteristicType.contactSensorState.fullUUID
    }

    func bind(aid: UInt64, iid: UInt64, publication: Publication?) {
        state.withLock {
            $0.aid = aid
            $0.iid = iid
            $0.publication = publication
        }
    }

    func unbind() {
        state.withLock { $0.publication = nil }
    }

    private func structureChange(_ body: (inout State) -> Void) {
        let publication = state.withLock { state -> Publication? in
            body(&state)
            return state.publication
        }
        publication?.structureDidChange()
    }

    /// Stores `value`: (whether it differs from the previous one, its sequence number).
    private func store(_ value: HAPValue) -> (changed: Bool, sequence: UInt64) {
        state.withLock { state in
            let changed = state.value != value
            state.value = value
            state.sequence += 1
            return (changed, state.sequence)
        }
    }

    private func notify(_ value: HAPValue, origin: UUID?, sequence: UInt64) {
        let (observers, publication) = state.withLock { ($0.observers.map(\.observer), $0.publication) }
        for observer in observers { observer(value, origin) }
        publication?.characteristicDidChange(self, value: value, origin: origin, sequence: sequence)
    }

    // MARK: - Internal: effective constraints

    var effectiveMinValue: Double? { state.withLock { $0.minValueOverride } ?? type.minValue }
    var effectiveMaxValue: Double? { state.withLock { $0.maxValueOverride } ?? type.maxValue }
    var effectiveValidValues: [Int]? { state.withLock { $0.validValuesOverride } ?? type.validValues }

    /// String `maxLen`: the type's value, else HAP's default of 64 (at most 256).
    var effectiveMaxLength: Int { min(type.maxLength ?? 64, 256) }

    /// Data/TLV8 limit (HAP-NodeJS `maxDataLen` default).
    static let maximumDataLength = 0x200000

    private var numericBounds: (min: Double?, max: Double?) {
        let format: (Double?, Double?) = switch type.format {
        case .uint8: (0, Double(UInt8.max))
        case .uint16: (0, Double(UInt16.max))
        case .uint32: (0, Double(UInt32.max))
        case .uint64: (0, Double(UInt64.max))
        case .int: (Double(Int32.min), Double(Int32.max))
        default: (nil, nil)
        }
        let lower = [effectiveMinValue, format.0].compactMap { $0 }.max()
        let upper = [effectiveMaxValue, format.1].compactMap { $0 }.min()
        return (lower, upper)
    }

    // MARK: - Internal: values

    static func defaultValue(for type: CharacteristicType) -> HAPValue {
        switch type.format {
        case .bool: return .bool(false)
        case .string: return .string("")
        case .tlv8, .data: return .data(Data())
        case .uint8, .uint16, .uint32, .uint64, .int, .float:
            let number: Double
            if let first = type.validValues?.first {
                number = Double(first)
            } else if let minimum = type.minValue, minimum > 0 || (type.maxValue.map { $0 < 0 } ?? false) {
                number = minimum
            } else {
                number = 0
            }
            switch type.format {
            case .float: return .float(number)
            case .int: return .int(Self.saturatingInt64(number))
            default: return .uint(Self.saturatingUInt64(number))
            }
        }
    }

    /// `number` (finite or not) converted without trapping: clamped to Int64's range, NaN → 0.
    static func saturatingInt64(_ number: Double) -> Int64 {
        guard !number.isNaN else { return 0 }
        if number >= 9_223_372_036_854_775_808.0 { return .max }   // 2^63
        if number <= -9_223_372_036_854_775_808.0 { return .min }
        return Int64(number)
    }

    /// `number` converted without trapping: clamped to UInt64's range (Double(UInt64.max) is 2^64), NaN → 0.
    static func saturatingUInt64(_ number: Double) -> UInt64 {
        guard !number.isNaN, number > 0 else { return 0 }
        if number >= 18_446_744_073_709_551_616.0 { return .max }   // 2^64
        return UInt64(number)
    }

    /// Coerces an API-supplied value into this format (clamping numbers, truncating strings). nil = unusable.
    func normalize(_ value: HAPValue) -> HAPValue? {
        if case .null = value { return .null }
        switch type.format {
        case .bool:
            if let bool = value.boolValue { return .bool(bool) }
        case .string:
            if let string = value.stringValue {
                let limit = effectiveMaxLength
                if string.count > limit {
                    Self.log.warning("Value for \(type.name) exceeds \(limit) characters; truncated")
                    return .string(String(string.prefix(limit)))
                }
                return .string(string)
            }
        case .tlv8, .data:
            if let data = value.dataValue { return .data(data) }
        case .float:
            if let number = Self.number(value), number.isFinite { return .float(clamp(number)) }
        case .int:
            if let number = Self.number(value), number.isFinite { return .int(Self.saturatingInt64(clamp(number).rounded())) }
        case .uint8, .uint16, .uint32, .uint64:
            if case .uint(let unsigned) = value, unsigned > UInt64(1 << 52), type.format == .uint64,
               effectiveMaxValue == nil, effectiveValidValues == nil { return .uint(unsigned) }
            if let number = Self.number(value), number.isFinite { return .uint(Self.saturatingUInt64(clamp(number).rounded())) }
        }
        Self.log.warning("Ignoring \(value) for \(type.name) (format \(type.format.rawValue))")
        return nil
    }

    /// Numbers, and bools as 1/0.
    private static func number(_ value: HAPValue) -> Double? {
        if case .bool(let bool) = value { return bool ? 1 : 0 }
        return value.doubleValue
    }

    private func clamp(_ number: Double) -> Double {
        let (lower, upper) = numericBounds
        var result = number
        if let lower, result < lower { result = lower }
        if let upper, result > upper { result = upper }
        return result
    }

    /// Validates a controller-supplied JSON value (PUT /characteristics) and converts it to this format.
    func validateIncoming(_ json: HAPJSON) throws(HAPStatus) -> HAPValue {
        switch type.format {
        case .bool:
            switch json {
            case .bool(let bool): return .bool(bool)
            case .int(let number) where number == 0 || number == 1: return .bool(number == 1)
            case .double(let number) where number == 0 || number == 1: return .bool(number == 1)
            default: throw .invalidValue
            }
        case .uint8, .uint16, .uint32, .uint64, .int, .float:
            let number: Double
            switch json {
            case .bool(let bool): number = bool ? 1 : 0
            case .int, .uint, .double:
                guard let value = json.doubleValue, value.isFinite else { throw .invalidValue }
                number = value
            default: throw .invalidValue
            }
            if type.format != .float, number.rounded() != number { throw .invalidValue }
            let (lower, upper) = numericBounds
            if let lower, number < lower { throw .invalidValue }
            if let upper, number > upper { throw .invalidValue }
            if let valid = effectiveValidValues, !valid.contains(where: { Double($0) == number }) { throw .invalidValue }
            switch type.format {
            case .float: return .float(number)
            case .int:
                guard let signed = Int64(exactly: number) else { throw .invalidValue }
                return .int(signed)
            default:
                // Exact integers as sent; `number` only for doubles (Double(UInt64.max) rounds up to 2^64, which passes
                // the bound above but does not fit).
                if case .uint(let unsigned) = json { return .uint(unsigned) }
                if case .int(let signed) = json, let unsigned = UInt64(exactly: signed) { return .uint(unsigned) }
                guard let unsigned = UInt64(exactly: number) else { throw .invalidValue }
                return .uint(unsigned)
            }
        case .string:
            guard case .string(let string) = json, string.count <= effectiveMaxLength else { throw .invalidValue }
            return .string(string)
        case .tlv8, .data:
            guard case .string(let text) = json, text.utf8.count <= Self.maximumDataLength * 4 / 3 + 4,
                  let data = Data(base64Encoded: text) else { throw .invalidValue }
            return .data(data)
        }
    }

    /// JSON form of a value: bools as 1/0, data as base64, floats rounded to `minStep`.
    func jsonValue(_ value: HAPValue) -> HAPJSON {
        switch value {
        case .null: return .null
        case .bool(let bool): return .int(bool ? 1 : 0)
        case .int(let number): return .int(number)
        case .uint(let number): return number <= UInt64(Int64.max) ? .int(Int64(number)) : .uint(number)
        case .string(let string): return .string(string)
        case .data(let data): return .string(data.base64EncodedString())
        case .float(let number):
            guard number.isFinite else { return .null }
            guard let step = type.minStep, step > 0, step < 1 else { return .double(number) }
            let base = effectiveMinValue ?? 0
            let inverse = 1 / step
            let stepped = ((number - base) * inverse).rounded() / inverse + base
            return .double((stepped * 10_000).rounded() / 10_000)
        }
    }

    // MARK: - Internal: request handling (timeouts are applied by the server)

    /// Read for GET /characteristics and /accessories. Stores (and publishes) a handler's value, except for control
    /// points (per session).
    func handleRead(context: HAPRequestContext?) async throws(HAPStatus) -> HAPValue {
        guard type.permissions.contains(.pairedRead) else { throw .writeOnly }
        if isEventOnly { return .null }
        guard let handler = state.withLock({ $0.readHandler }) else { return value }
        let result = try await handler(context)
        guard let normalized = normalize(result) else {
            Self.log.warning("Read handler for \(type.name) returned an unusable value")
            throw .serviceCommunicationFailure
        }
        if isControlPoint { return normalized }
        let (changed, sequence) = store(normalized)
        if changed { notify(normalized, origin: context?.session.id, sequence: sequence) }
        return normalized
    }

    /// Write for PUT /characteristics (value already validated). Returns the handler's write-response value. Stores
    /// the value (the write response for `wr`), except for control points (per session).
    func handleWrite(_ value: HAPValue, context: HAPRequestContext) async throws(HAPStatus) -> HAPValue? {
        let handler = state.withLock { $0.writeHandler }
        var response: HAPValue?
        if let handler { response = try await handler(value, context) }
        if isControlPoint { return response }
        var stored = value
        if let response, type.permissions.contains(.writeResponse), let normalized = normalize(response) { stored = normalized }
        let (changed, sequence) = store(stored)
        if changed || isEventOnly { notify(stored, origin: context.session.id, sequence: sequence) }
        return response
    }
}

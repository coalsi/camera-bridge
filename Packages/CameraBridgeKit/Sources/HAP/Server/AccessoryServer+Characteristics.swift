// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// /accessories, GET/PUT /characteristics, /prepare and /resource follow HAP-NodeJS HAPServer.ts (handleAccessories,
// handleCharacteristics, handlePrepareWrite, handleResource) and Accessory.ts (handleGetCharacteristics,
// handleCharacteristicRead, handleSetCharacteristics, handleCharacteristicWrite, handleResource).

import BridgeSupport
import Foundation
import HAPCore

extension AccessoryServer {
    // MARK: - /accessories

    func handleAccessories(context: HAPRequestContext) async -> HAPResponse {
        guard let publication else { return .status(503, .serviceCommunicationFailure) }
        publication.assignIDs()
        let accessories = publication.accessories
        // Like HAP-NodeJS, read handlers are contacted only if the previous /accessories was more than 5 s ago; otherwise
        // stored values are served. Control points are always asked: their value is per session (SetupEndpoints'
        // read-back carries SRTP keys) and never stored, so another controller's request or read-back cannot show.
        let now = ContinuousClock.now
        let contactHandlers = lastAccessoriesRead.map { now - $0 > .seconds(5) } ?? true
        lastAccessoriesRead = now
        var values: [ObjectIdentifier: HAPValue] = [:]
        let readable = accessories.filter(\.isReachable).flatMap(\.services).flatMap(\.characteristics)
            .filter { $0.hasReadHandler && (contactHandlers || $0.isControlPoint) }
        if !readable.isEmpty {
            let timings = self.timings, log = self.log
            values = await withTaskGroup(of: (ObjectIdentifier, HAPValue?).self) { group in
                for characteristic in readable {
                    group.addTask {
                        let value = try? await HandlerTimeout.run(warning: timings.handlerWarning, timeout: timings.handlerTimeout, log: log,
                                                                  description: "Read of \(characteristic.type.name)") { () async throws(HAPStatus) -> HAPValue in
                            try await characteristic.handleRead(context: context)
                        }
                        return (ObjectIdentifier(characteristic), value)
                    }
                }
                var collected: [ObjectIdentifier: HAPValue] = [:]
                for await (id, value) in group { if let value { collected[id] = value } }
                return collected
            }
        }
        let json: HAPJSON = ["accessories": .array(accessories.map { HAPJSONEncoding.accessory($0, includeValues: true, values: values) })]
        return .json(200, json)
    }

    // MARK: - GET /characteristics

    private static func consideredTrue(_ value: String?) -> Bool { value == "1" || value == "true" }

    /// Parses `id=1.9,2.14`. nil = malformed, including ids beyond Int64 (what PUT, events and JSON integers carry).
    private static func parseIDs(_ text: String?) -> [CharacteristicKey]? {
        guard let text, !text.isEmpty else { return nil }
        var keys: [CharacteristicKey] = []
        for entry in text.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                  let aid = Int64(parts[0]), let iid = Int64(parts[1]) else { return nil }
            keys.append(CharacteristicKey(aid: UInt64(aid), iid: UInt64(iid)))
        }
        return keys
    }

    func handleGetCharacteristics(_ head: HTTPRequestHead, connection: HAPConnection, context: HAPRequestContext) async -> HAPResponse {
        let query = head.queryItems
        let parameter: (String) -> String? = { name in query.first { $0.name == name }?.value }
        guard let keys = Self.parseIDs(parameter("id")) else { return .status(400, .invalidValue) }
        guard Set(keys).count == keys.count else { return .status(422, .invalidValue) }
        guard let publication else { return .status(503, .serviceCommunicationFailure) }
        let includeMeta = Self.consideredTrue(parameter("meta"))
        let includePerms = Self.consideredTrue(parameter("perms"))
        let includeType = Self.consideredTrue(parameter("type"))
        let includeEvents = Self.consideredTrue(parameter("ev"))

        enum Outcome: Sendable {
            case value(HAPValue)
            case failure(HAPStatus)
        }
        var targets: [Int: Characteristic] = [:]
        var outcomes: [Int: Outcome] = [:]
        for (index, key) in keys.enumerated() {
            guard let match = publication.characteristic(aid: key.aid, iid: key.iid) else {
                outcomes[index] = .failure(.resourceDoesNotExist)
                continue
            }
            let (accessory, characteristic) = match
            if !characteristic.type.permissions.contains(.pairedRead) {
                outcomes[index] = .failure(.writeOnly)
            } else if !accessory.isReachable {
                outcomes[index] = .failure(.serviceCommunicationFailure)
            } else {
                targets[index] = characteristic
            }
        }
        let timings = self.timings, log = self.log
        let reads = await withTaskGroup(of: (Int, Outcome).self) { group in
            for (index, characteristic) in targets {
                group.addTask {
                    do throws(HAPStatus) {
                        let value = try await HandlerTimeout.run(warning: timings.handlerWarning, timeout: timings.handlerTimeout, log: log,
                                                                 description: "Read of \(characteristic.type.name)") { () async throws(HAPStatus) -> HAPValue in
                            try await characteristic.handleRead(context: context)
                        }
                        return (index, .value(value))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [Int: Outcome] = [:]
            for await (index, outcome) in group { collected[index] = outcome }
            return collected
        }
        outcomes.merge(reads) { $1 }

        var anyError = false
        var items: [HAPJSONObject] = []
        for (index, key) in keys.enumerated() {
            var item = HAPJSONObject([("aid", .unsigned(key.aid)), ("iid", .unsigned(key.iid))])
            switch outcomes[index] ?? .failure(.serviceCommunicationFailure) {
            case .failure(let status):
                anyError = true
                item["status"] = .int(Int64(status.rawValue))
            case .value(let value):
                guard let characteristic = targets[index] else { continue }
                item["value"] = characteristic.isEventOnly ? .null : characteristic.jsonValue(value)
                if includeMeta {
                    item["format"] = .string(characteristic.type.format.rawValue)
                    HAPJSONEncoding.metadata(characteristic, into: &item)
                }
                if includePerms { item["perms"] = .array(characteristic.type.permissions.jsonStrings.map { .string($0) }) }
                if includeType { item["type"] = .string(characteristic.type.uuid) }
                if includeEvents { item["ev"] = .bool(connection.subscriptions.contains(key)) }
            }
            items.append(item)
        }
        if anyError {
            for index in items.indices where items[index]["status"] == nil { items[index]["status"] = .int(0) }
        }
        return .json(anyError ? 207 : 200, ["characteristics": .array(items.map { .object($0) })])
    }

    // MARK: - PUT /characteristics

    func handlePutCharacteristics(_ body: Data, connection: HAPConnection, context: HAPRequestContext) async -> HAPResponse {
        guard !body.isEmpty, let json = try? HAPJSON.parse(body), let entries = json["characteristics"]?.arrayValue else {
            return .status(400, .invalidValue)
        }
        var keys: [CharacteristicKey] = []
        for entry in entries {
            guard let aid = entry["aid"]?.intValue, let iid = entry["iid"]?.intValue, aid >= 0, iid >= 0 else { return .status(400, .invalidValue) }
            keys.append(CharacteristicKey(aid: UInt64(aid), iid: UInt64(iid)))
        }
        guard Set(keys).count == keys.count else { return .status(422, .invalidValue) }
        guard let publication else { return .status(503, .serviceCommunicationFailure) }

        // Timed writes: a `pid` must match an unexpired /prepare on this connection; it is consumed either way.
        var timedWriteAuthenticated = false
        var timedWriteRejected = false
        if let pidValue = json["pid"], !pidValue.isNull {
            if let pid = Self.timedWritePID(pidValue), let prepared = connection.timedWrite, prepared.pid == pid,
               ContinuousClock.now < prepared.expiry {
                timedWriteAuthenticated = true
            } else {
                timedWriteRejected = true
            }
            connection.timedWrite = nil
        }

        struct WriteJob: Sendable {
            var index: Int
            var characteristic: Characteristic
            var value: HAPValue
            var wantsResponse: Bool
        }
        var statuses: [Int: HAPStatus] = [:]
        var jobs: [WriteJob] = []
        for (index, entry) in entries.enumerated() {
            let key = keys[index]
            guard let match = publication.characteristic(aid: key.aid, iid: key.iid) else {
                statuses[index] = .resourceDoesNotExist
                continue
            }
            let (accessory, characteristic) = match
            if timedWriteRejected {
                statuses[index] = .invalidValue
                continue
            }
            let permissions = characteristic.type.permissions
            let events = entry["ev"].flatMap { $0.isNull ? nil : $0 }
            let value = entry["value"].flatMap { $0.isNull ? nil : $0 }
            guard events != nil || value != nil else {
                statuses[index] = .invalidValue
                continue
            }
            if let events {
                guard permissions.contains(.events) else {
                    statuses[index] = .notificationNotSupported
                    continue
                }
                guard let enable = events.boolValue ?? events.intValue.flatMap({ $0 == 0 || $0 == 1 ? $0 == 1 : nil }) else {
                    statuses[index] = .invalidValue
                    continue
                }
                if enable { connection.subscriptions.insert(key) } else { connection.subscriptions.remove(key) }
            }
            if let value {
                guard permissions.contains(.pairedWrite) else {
                    statuses[index] = .readOnly
                    continue
                }
                if permissions.contains(.timedWrite) && !timedWriteAuthenticated {
                    statuses[index] = .invalidValue
                    continue
                }
                guard accessory.isReachable else {
                    statuses[index] = .serviceCommunicationFailure
                    continue
                }
                do {
                    let validated = try characteristic.validateIncoming(value)
                    let wantsResponse = entry["r"]?.boolValue ?? (entry["r"]?.intValue == 1)
                    jobs.append(WriteJob(index: index, characteristic: characteristic, value: validated, wantsResponse: wantsResponse))
                } catch {
                    statuses[index] = error
                }
                continue
            }
            statuses[index] = .success
        }

        let timings = self.timings, log = self.log
        let results = await withTaskGroup(of: (Int, Result<HAPJSON?, HAPStatus>).self) { group in
            for job in jobs {
                group.addTask {
                    do throws(HAPStatus) {
                        let response = try await HandlerTimeout.run(warning: timings.handlerWarning, timeout: timings.handlerTimeout, log: log,
                                                                    description: "Write of \(job.characteristic.type.name)") { () async throws(HAPStatus) -> HAPValue? in
                            try await job.characteristic.handleWrite(job.value, context: context)
                        }
                        let json = job.wantsResponse ? response.map { job.characteristic.jsonValue($0) } : nil
                        return (job.index, .success(json))
                    } catch {
                        return (job.index, .failure(error))
                    }
                }
            }
            var collected: [Int: Result<HAPJSON?, HAPStatus>] = [:]
            for await (index, result) in group { collected[index] = result }
            return collected
        }

        var multiStatus = false
        var items: [HAPJSON] = []
        for (index, key) in keys.enumerated() {
            var item = HAPJSONObject([("aid", .unsigned(key.aid)), ("iid", .unsigned(key.iid))])
            var status = statuses[index] ?? .success
            if let result = results[index] {
                switch result {
                case .success(let response):
                    if let response {
                        item["value"] = response
                        multiStatus = true
                    }
                case .failure(let error):
                    status = error
                }
            }
            item["status"] = .int(Int64(status.rawValue))
            if status != .success { multiStatus = true }
            items.append(.object(item))
        }
        return multiStatus ? .json(207, ["characteristics": .array(items)]) : .noContent
    }

    // MARK: - PUT /prepare

    func handlePrepare(_ body: Data, connection: HAPConnection) -> HAPResponse {
        guard let json = try? HAPJSON.parse(body), let ttl = json["ttl"]?.intValue, ttl > 0, let pid = Self.timedWritePID(json["pid"]) else {
            return .status(400, .invalidValue)
        }
        connection.timedWrite = (pid, ContinuousClock.now + .milliseconds(ttl))
        return .json(200, ["status": 0])
    }

    /// A timed-write `pid` as a comparable JSON number: any non-zero integer, signed or unsigned up to 2^64-1 (JSON
    /// integers above Int64.max parse as `.uint`; other HAP implementations take a uint64, HAP-NodeJS compares the parsed
    /// number), also written as an integral double. `.int` when it fits, else `.uint`. nil = 0 or not an integer.
    static func timedWritePID(_ json: HAPJSON?) -> HAPJSON? {
        switch json {
        case .int(let value)?:
            return value != 0 ? .int(value) : nil
        case .uint(let value)?:
            return value != 0 ? .unsigned(value) : nil
        case .double(let value)?:
            guard value.isFinite, value.rounded() == value, value != 0 else { return nil }
            if let signed = Int64(exactly: value) { return .int(signed) }
            return UInt64(exactly: value).map { .unsigned($0) }
        default:
            return nil
        }
    }

    // MARK: - POST /resource

    func handleResource(_ body: Data, context: HAPRequestContext) async -> HAPResponse {
        guard let json = try? HAPJSON.parse(body), let type = json["resource-type"]?.stringValue else { return .status(400, .invalidValue) }
        guard type == "image" else { return .status(404, .resourceDoesNotExist) }
        guard let width = json["image-width"]?.intValue, let height = json["image-height"]?.intValue, width >= 0, height >= 0,
              width <= Int64(Int32.max), height <= Int64(Int32.max) else {
            return .status(400, .invalidValue)
        }
        let aid = json["aid"]?.intValue.flatMap { $0 >= 0 ? UInt64($0) : nil }
        let reason = json["reason"]?.intValue.flatMap { Int(exactly: $0) }
        let target: Accessory?
        if let aid { target = publication?.accessory(aid: aid) } else { target = accessory }
        guard let target, let handler = target.resourceHandler else { return .status(404, .resourceDoesNotExist) }
        let request = HAPResourceRequest(type: type, width: Int(width), height: Int(height), aid: aid, reason: reason)
        let timings = self.timings, log = self.log
        do throws(HAPStatus) {
            let image = try await HandlerTimeout.run(warning: timings.resourceWarning, timeout: timings.resourceTimeout, log: log,
                                                     description: "Snapshot") { () async throws(HAPStatus) -> Data in
                try await handler(request, context)
            }
            return HAPResponse(status: 200, headers: HTTPHeaders([("Content-Type", "image/jpeg")]), body: image)
        } catch {
            // HAP-NodeJS answers a failed snapshot with 207 and the status.
            return .status(207, error)
        }
    }
}

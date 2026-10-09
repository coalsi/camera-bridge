#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import Synchronization
import Testing
@testable import HAP

/// Plan W1-1 items 3 (/accessories), 9 (characteristic routes) and 10 (handlers, validation).
@Suite(.timeLimit(.minutes(1))) struct CharacteristicRequestTests {
    private func findCharacteristic(_ json: HAPJSON, iid: UInt64) -> HAPJSON? {
        for accessory in json["accessories"]?.arrayValue ?? [] {
            for service in accessory["services"]?.arrayValue ?? [] {
                for characteristic in service["characteristics"]?.arrayValue ?? [] where characteristic["iid"]?.intValue == Int64(iid) {
                    return characteristic
                }
            }
        }
        return nil
    }

    @Test func accessoriesJSONStructure() async throws {
        let hub = TestAccessories.sensorHub()
        hub.recording.addLinkedService(hub.motion)
        hub.recording.isPrimary = true
        hub.dataStream.isHidden = true
        hub.lightOn.update(.bool(true))
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let json = try await client.accessories()

        let accessories = try #require(json["accessories"]?.arrayValue)
        #expect(accessories.count == 1)
        #expect(accessories[0]["aid"] == 1)
        let services = try #require(accessories[0]["services"]?.arrayValue)
        #expect(services.first?["iid"] == 1)
        #expect(services.first?["type"] == "3E")
        #expect(services.map { $0["type"]?.stringValue ?? "" } == ["3E", "A2", "85", "49", "80", "121", "204", "129"])

        let recording = try #require(services.first { $0["type"] == "204" })
        #expect(recording["primary"] == .bool(true))
        #expect(recording["linked"] == .array([.int(Int64(hub.motion.iid))]))
        #expect(recording["hidden"] == nil)
        #expect(services.first { $0["type"] == "129" }?["hidden"] == .bool(true))
        #expect(services.first { $0["type"] == "85" }?["primary"] == nil)

        let identifyIID = try #require(hub.accessory.informationService.existingCharacteristic(.identify)).iid
        let identify = try #require(findCharacteristic(json, iid: identifyIID))
        #expect(identify["perms"] == ["pw"])
        #expect(identify["format"] == "bool")
        #expect(identify["value"] == nil)
        let pse = try #require(findCharacteristic(json, iid: hub.switchEvent.iid))
        #expect(pse["value"] == .null)
        #expect(pse["valid-values"] == [0, 1, 2])
        #expect(pse["minValue"] == 0 && pse["maxValue"] == 2 && pse["minStep"] == 1)
        let on = try #require(findCharacteristic(json, iid: hub.lightOn.iid))
        #expect(on["value"] == 1)
        #expect(on["type"] == "25")
        #expect(on["perms"] == ["pr", "pw", "ev"])
        let manufacturerIID = try #require(hub.accessory.informationService.existingCharacteristic(.manufacturer)).iid
        let manufacturer = try #require(findCharacteristic(json, iid: manufacturerIID))
        #expect(manufacturer["value"] == "CameraBridge")
        let setup = try #require(findCharacteristic(json, iid: hub.setupDataStream.iid))
        #expect(setup["format"] == "tlv8" && setup["value"] == "")
        #expect(setup["perms"] == ["pr", "pw", "wr"])
    }

    @Test func getCharacteristicsWithMetadata() async throws {
        let hub = TestAccessories.sensorHub()
        hub.motionDetected.update(.bool(true))
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let volumeLike = hub.lightOn
        let ids = "1.\(hub.motionDetected.iid),1.\(volumeLike.iid)"
        let plain = try await client.getJSON("/characteristics?id=\(ids)")
        #expect(plain.status == 200)
        #expect(plain.json == ["characteristics": [["aid": 1, "iid": .int(Int64(hub.motionDetected.iid)), "value": 1],
                                                   ["aid": 1, "iid": .int(Int64(volumeLike.iid)), "value": 0]]])

        _ = try await client.subscribe(aid: 1, iid: hub.motionDetected.iid)
        let full = try await client.getJSON("/characteristics?id=1.\(hub.motionDetected.iid)&meta=1&perms=1&type=1&ev=1")
        #expect(full.status == 200)
        let item = try #require(full.json?["characteristics"]?[0])
        #expect(item["format"] == "bool")
        #expect(item["perms"] == ["pr", "ev"])
        #expect(item["type"] == "22")
        #expect(item["ev"] == .bool(true))
        #expect(item["value"] == 1)

        let temperatureLux = try await client.getJSON("/characteristics?id=1.\(hub.contactState.iid)&meta=true")
        #expect(temperatureLux.json?["characteristics"]?[0]?["maxValue"] == 1)
    }

    @Test func getCharacteristicsErrors() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let motion = hub.motionDetected.iid
        let identify = try #require(hub.accessory.informationService.existingCharacteristic(.identify)).iid

        let partial = try await client.getJSON("/characteristics?id=1.\(motion),1.9999,1.\(identify),7.\(motion)")
        #expect(partial.status == 207)
        let items = try #require(partial.json?["characteristics"]?.arrayValue)
        #expect(items.count == 4)
        #expect(items[0] == ["aid": 1, "iid": .int(Int64(motion)), "value": 0, "status": 0])
        #expect(items[1] == ["aid": 1, "iid": 9999, "status": -70409])
        #expect(items[2] == ["aid": 1, "iid": .int(Int64(identify)), "status": -70405])
        #expect(items[3] == ["aid": 7, "iid": .int(Int64(motion)), "status": -70409])

        let duplicate = try await client.getJSON("/characteristics?id=1.\(motion),1.\(motion)")
        #expect(duplicate.status == 422)
        #expect(duplicate.json == ["status": -70410])
        for bad in ["/characteristics", "/characteristics?id=", "/characteristics?id=1", "/characteristics?id=a.b", "/characteristics?id=1.-2"] {
            let response = try await client.getJSON(bad)
            #expect(response.status == 400, "\(bad)")
            #expect(response.json == ["status": -70410])
        }
    }

    @Test func putCharacteristicsCoercesAndReports() async throws {
        let hub = TestAccessories.sensorHub()
        let written = Mutex<[HAPValue]>([])
        hub.lightOn.onWrite { value, _ async throws(HAPStatus) -> HAPValue? in
            written.withLock { $0.append(value) }
            return nil
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()

        #expect(try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)]).status == 204)
        #expect(try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: .bool(false))]).status == 204)
        #expect(written.withLock { $0 } == [.bool(true), .bool(false)])
        #expect(hub.lightOn.value == .bool(false))

        let mixed = try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 2), writeItem(1, hub.motionDetected, value: 1),
                                                          writeItem(1, hub.contactState, ev: true)])
        #expect(mixed.status == 207)
        let items = try #require(mixed.json?["characteristics"]?.arrayValue)
        #expect(items.contains(["aid": 1, "iid": .int(Int64(hub.lightOn.iid)), "status": -70410]))
        #expect(items.contains(["aid": 1, "iid": .int(Int64(hub.motionDetected.iid)), "status": -70404]))
        #expect(items.contains(["aid": 1, "iid": .int(Int64(hub.contactState.iid)), "status": 0]))

        let noSubscribe = try await client.writeCharacteristics([writeItem(1, try #require(hub.accessory.informationService.existingCharacteristic(.name)),
                                                                           ev: true)])
        #expect(noSubscribe.json?["characteristics"]?[0]?["status"] == -70406)
        let empty = try await client.writeCharacteristics([["aid": 1, "iid": .int(Int64(hub.lightOn.iid))]])
        #expect(empty.json?["characteristics"]?[0]?["status"] == -70410)
        let unknown = try await client.writeCharacteristics([["aid": 1, "iid": 4242, "value": 1]])
        #expect(unknown.json?["characteristics"]?[0]?["status"] == -70409)

        let duplicate = try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1), writeItem(1, hub.lightOn, value: 0)])
        #expect(duplicate.status == 422)
        let malformed = try await client.request("PUT", "/characteristics", body: Data("{".utf8))
        #expect(malformed.status == 400)
        #expect(try malformed.json() == ["status": -70410])
        #expect(try await client.request("PUT", "/characteristics").status == 400)
    }

    @Test func tlv8WriteWithWriteResponse() async throws {
        let hub = TestAccessories.sensorHub()
        let request = Mutex<Data?>(nil)
        hub.setupDataStream.onWrite { value, _ async throws(HAPStatus) -> HAPValue? in
            request.withLock { $0 = value.dataValue }
            return .data(Data([0x01, 0x01, 0x00, 0x02, 0x02, 0x10, 0x27]))
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let tlv = Data([0x01, 0x01, 0x00, 0x02, 0x01, 0x00])
        let response = try await client.writeCharacteristics([writeItem(1, hub.setupDataStream, value: .string(tlv.base64EncodedString()), r: true)])
        #expect(response.status == 207)
        #expect(request.withLock { $0 } == tlv)
        let item = try #require(response.json?["characteristics"]?[0])
        #expect(item["status"] == 0)
        #expect(item["value"] == .string(Data([0x01, 0x01, 0x00, 0x02, 0x02, 0x10, 0x27]).base64EncodedString()))

        // Without "r" the response value is not returned.
        let quiet = try await client.writeCharacteristics([writeItem(1, hub.setupDataStream, value: .string(tlv.base64EncodedString()))])
        #expect(quiet.status == 204)
        let invalid = try await client.writeCharacteristics([writeItem(1, hub.setupDataStream, value: "%%%")])
        #expect(invalid.json?["characteristics"]?[0]?["status"] == -70410)
    }

    @Test func timedWritesRequirePreparedPID() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let audio = hub.recordingAudioActive

        let unprepared = try await client.writeCharacteristics([writeItem(1, audio, value: 1)])
        #expect(unprepared.json?["characteristics"]?[0]?["status"] == -70410)
        let wrongPID = try await client.writeCharacteristics([writeItem(1, audio, value: 1)], pid: 99)
        #expect(wrongPID.json?["characteristics"]?[0]?["status"] == -70410)

        let prepare = try await client.putJSON("/prepare", ["ttl": 2500, "pid": 12_345])
        #expect(prepare.status == 200)
        #expect(prepare.json == ["status": 0])
        #expect(try await client.writeCharacteristics([writeItem(1, audio, value: 1)], pid: 12_345).status == 204)
        #expect(audio.value == .uint(1))
        // The pid is consumed.
        let reused = try await client.writeCharacteristics([writeItem(1, audio, value: 0)], pid: 12_345)
        #expect(reused.json?["characteristics"]?[0]?["status"] == -70410)

        // Expired ttl.
        #expect(try await client.putJSON("/prepare", ["ttl": 20, "pid": 777]).status == 200)
        try await Task.sleep(for: .milliseconds(80))
        let expired = try await client.writeCharacteristics([writeItem(1, audio, value: 0)], pid: 777)
        #expect(expired.json?["characteristics"]?[0]?["status"] == -70410)
        #expect(audio.value == .uint(1))

        #expect(try await client.putJSON("/prepare", ["ttl": 1000]).status == 400)
        #expect(try await client.request("GET", "/prepare").status == 400)
        // A prepared pid also works for characteristics without "tw".
        #expect(try await client.putJSON("/prepare", ["ttl": 2500, "pid": 5]).status == 200)
        #expect(try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)], pid: 5).status == 204)
    }

    /// A `pid` is any non-zero integer JSON number, including 2^63 … 2^64-1 (HAPJSON `.uint`): HAP-NodeJS compares the
    /// parsed number, other HAP implementations take a uint64. Regression: pids above Int64.max got 400 from /prepare and
    /// -70410 for the timed write.
    @Test func timedWritePIDsCoverTheUnsigned64BitRange() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let audio = hub.recordingAudioActive

        var expected: UInt64 = 0
        for pid: UInt64 in [UInt64(Int64.max), 1 << 63, 13_127_536_419_934_126_000, .max] {
            let prepare = try await client.putJSON("/prepare", ["ttl": 2500, "pid": .unsigned(pid)])
            #expect(prepare.status == 200, "pid \(pid)")
            #expect(prepare.json == ["status": 0], "pid \(pid)")
            expected ^= 1
            let write = try await client.writeCharacteristics([writeItem(1, audio, value: .int(Int64(expected)))], pid: .unsigned(pid))
            #expect(write.status == 204, "pid \(pid): \(String(describing: write.json))")
            #expect(audio.value == .uint(expected), "pid \(pid)")
        }
        // The raw decimal text a controller sends, not only what HAPJSON serializes.
        let raw = Data(#"{"ttl":2500,"pid":18446744073709551615}"#.utf8)
        #expect(try await client.request("PUT", "/prepare", body: raw, contentType: "application/hap+json").status == 200)
        let rawWrite = Data(#"{"characteristics":[{"aid":1,"iid":\#(audio.iid),"value":0}],"pid":18446744073709551615}"#.utf8)
        #expect(try await client.request("PUT", "/characteristics", body: rawWrite, contentType: "application/hap+json").status == 204)
        #expect(audio.value == .uint(0))

        // A pid matches only itself.
        #expect(try await client.putJSON("/prepare", ["ttl": 2500, "pid": .uint(1 << 63)]).status == 200)
        let neighbour = try await client.writeCharacteristics([writeItem(1, audio, value: 1)], pid: .int(Int64.max))
        #expect(neighbour.json?["characteristics"]?[0]?["status"] == -70410)
        #expect(try await client.putJSON("/prepare", ["ttl": 2500, "pid": .uint(.max)]).status == 200)
        let below = try await client.writeCharacteristics([writeItem(1, audio, value: 1)], pid: .uint(.max - 1))
        #expect(below.json?["characteristics"]?[0]?["status"] == -70410)
        #expect(audio.value == .uint(0))
        // An integral double is the same number.
        #expect(try await client.putJSON("/prepare", ["ttl": 2500, "pid": 4096.0]).status == 200)
        #expect(try await client.writeCharacteristics([writeItem(1, audio, value: 1)], pid: 4096).status == 204)

        // 0 and non-integers stay invalid.
        for invalid: HAPJSON in [0, 0.0, 1.5, 1e300, "5", .bool(true), .null, [1]] {
            #expect(try await client.putJSON("/prepare", ["ttl": 2500, "pid": invalid]).status == 400, "pid \(invalid)")
        }
        let fractional = try await client.writeCharacteristics([writeItem(1, audio, value: 0)], pid: 4096.5)
        #expect(fractional.json?["characteristics"]?[0]?["status"] == -70410)
        #expect(audio.value == .uint(1))
    }

    /// Control points (writable tlv8 without events: SetupEndpoints, SelectedRTPStreamConfiguration,
    /// SetupDataStreamTransport) carry one session's request/response, e.g. SetupEndpoints' SRTP keys. `/accessories`
    /// must never show one controller what another wrote or read back, also within 5 s of the previous `/accessories`
    /// (where other characteristics are served from their stored values). Regression: controller B saw A's request
    /// and read-back, SRTP keys included.
    @Test func accessoriesNeverServeAnotherSessionsControlPointValues() async throws {
        let hub = TestAccessories.sensorHub()
        let stream = hub.accessory.addService(Service(.cameraRTPStreamManagement))
        let setupEndpoints = stream.characteristic(.setupEndpoints)
        let idle = Data([0x02, 0x01, 0x02])
        setupEndpoints.update(.data(idle))
        let readBacks = Mutex<[UUID: Data]>([:])
        let handlerReads = Mutex(0)
        setupEndpoints.onRead { context async throws(HAPStatus) -> HAPValue in
            handlerReads.withLock { $0 += 1 }
            guard let id = context?.session.id else { return .data(idle) }
            return .data(readBacks.withLock { $0[id] } ?? idle)
        }
        setupEndpoints.onWrite { value, context async throws(HAPStatus) -> HAPValue? in
            readBacks.withLock { $0[context.session.id] = Data("READBACK-KEY-".utf8) + (value.dataValue ?? Data()) }
            return nil
        }
        hub.setupDataStream.onWrite { _, _ async throws(HAPStatus) -> HAPValue? in
            .data(Data("ACCESSORY-SALT-OF-A".utf8))
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let a = try await running.pairedClient()
        let b = try await running.pairedClient()

        func value(_ json: HAPJSON, _ characteristic: Characteristic) -> Data? {
            findCharacteristic(json, iid: characteristic.iid)?["value"]?.stringValue.flatMap { Data(base64Encoded: $0) }
        }

        // B's first /accessories contacts the handlers; everything after this is within the 5 s window.
        #expect(value(try await b.accessories(), setupEndpoints) == idle)
        let request = Data("SRTP-MASTER-KEY-OF-A".utf8)
        #expect(try await a.writeCharacteristics([writeItem(1, setupEndpoints, value: .string(request.base64EncodedString()))]).status == 204)
        let dataStreamWrite = try await a.writeCharacteristics([writeItem(1, hub.setupDataStream, value: .string(Data([1, 1, 0]).base64EncodedString()),
                                                                         r: true)])
        #expect(dataStreamWrite.status == 207)

        let afterWrite = try await b.accessories()
        #expect(value(afterWrite, setupEndpoints) == idle, "B saw A's SetupEndpoints request")
        #expect(value(afterWrite, hub.setupDataStream) == Data(), "B saw A's SetupDataStreamTransport response")

        // A reads its read-back; B still gets its own.
        let readBack = Data("READBACK-KEY-".utf8) + request
        let own = try await a.getJSON("/characteristics?id=1.\(setupEndpoints.iid)")
        #expect(own.json?["characteristics"]?[0]?["value"] == .string(readBack.base64EncodedString()))
        let afterRead = try await b.accessories()
        #expect(value(afterRead, setupEndpoints) == idle, "B saw A's SetupEndpoints read-back")
        // A's own /accessories (also within the window) shows A's read-back, as GET /characteristics does.
        #expect(value(try await a.accessories(), setupEndpoints) == readBack)

        // Neither the request nor the read-back became the stored value; the accessory's own value stays.
        #expect(setupEndpoints.value == .data(idle))
        #expect(hub.setupDataStream.value == .data(Data()))
        #expect(handlerReads.withLock { $0 } >= 4)
    }

    @Test func resourceRequestsReachTheHandler() async throws {
        let hub = TestAccessories.sensorHub()
        let seen = Mutex<HAPResourceRequest?>(nil)
        hub.accessory.onResourceRequest { request, context async throws(HAPStatus) -> Data in
            seen.withLock { $0 = request }
            if request.width == 1 { throw .resourceBusy }
            return Data([0xFF, 0xD8, 0xFF, 0xD9])
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let body: HAPJSON = ["resource-type": "image", "image-width": 640, "image-height": 360, "reason": 1]
        let response = try await client.request("POST", "/resource", body: body.serialized(), contentType: "application/hap+json")
        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "image/jpeg")
        #expect(response.body == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let request = try #require(seen.withLock { $0 })
        #expect(request.type == "image" && request.width == 640 && request.height == 360 && request.reason == 1 && request.aid == nil)

        let failing = try await client.request("POST", "/resource",
                                               body: hapJSON(["resource-type": "image", "image-width": 1, "image-height": 1]).serialized())
        #expect(failing.status == 207)
        #expect(try failing.json() == ["status": -70403])
        let otherType = try await client.request("POST", "/resource", body: hapJSON(["resource-type": "video"]).serialized())
        #expect(otherType.status == 404)
        let missingAccessory = try await client.request("POST", "/resource",
                                                        body: hapJSON(["resource-type": "image", "image-width": 1, "image-height": 1, "aid": 9]).serialized())
        #expect(missingAccessory.status == 404)
        #expect(try await client.request("POST", "/resource", body: Data("nope".utf8)).status == 400)
    }

    @Test func resourceWithoutHandlerIs404() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let response = try await client.request("POST", "/resource",
                                                body: hapJSON(["resource-type": "image", "image-width": 64, "image-height": 64]).serialized())
        #expect(response.status == 404)
        #expect(try response.json() == ["status": -70409])
    }

    @Test func handlerTimeoutsAndErrors() async throws {
        let hub = TestAccessories.sensorHub()
        hub.lightOn.onRead { _ async throws(HAPStatus) -> HAPValue in
            try? await Task.sleep(for: .seconds(30))
            return .bool(true)
        }
        hub.lightOn.onWrite { _, _ async throws(HAPStatus) -> HAPValue? in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        hub.contactState.onRead { _ async throws(HAPStatus) -> HAPValue in throw .resourceBusy }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()

        let started = ContinuousClock.now
        let read = try await client.getJSON("/characteristics?id=1.\(hub.lightOn.iid),1.\(hub.motionDetected.iid),1.\(hub.contactState.iid)")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(read.status == 207)
        let items = try #require(read.json?["characteristics"]?.arrayValue)
        #expect(items.contains(["aid": 1, "iid": .int(Int64(hub.lightOn.iid)), "status": -70408]))
        #expect(items.contains(["aid": 1, "iid": .int(Int64(hub.motionDetected.iid)), "value": 0, "status": 0]))
        #expect(items.contains(["aid": 1, "iid": .int(Int64(hub.contactState.iid)), "status": -70403]))

        let write = try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)])
        #expect(write.json?["characteristics"]?[0]?["status"] == -70408)
        // The connection still works after timeouts.
        #expect(try await client.request("GET", "/accessories").status == 200)
    }

    @Test func invalidValuesAreRejected() async throws {
        let hub = TestAccessories.sensorHub()
        let volume = hub.doorbell.characteristic(.volume)
        let name = hub.light.characteristic(.configuredName)
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        for (characteristic, value) in [(volume, HAPJSON.int(101)), (volume, .int(-1)), (volume, .string("5")), (volume, .double(1.5)),
                                        (name, .string(String(repeating: "n", count: 65))), (name, .int(3)), (hub.lightOn, .int(3))] {
            let result = try await client.writeCharacteristics([writeItem(1, characteristic, value: value)])
            #expect(result.json?["characteristics"]?[0]?["status"] == -70410, "\(characteristic.type.name) \(value)")
        }
        #expect(try await client.writeCharacteristics([writeItem(1, volume, value: 55)]).status == 204)
        #expect(volume.value == .uint(55))
        #expect(try await client.writeCharacteristics([writeItem(1, name, value: "Porch")]).status == 204)
        #expect(name.value == .string("Porch"))
    }
}
#endif

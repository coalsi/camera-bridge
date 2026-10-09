import Foundation
import HAPCore
import Testing
@testable import HAP

/// Plan W1-1 item 1: every service/characteristic of research brief §3.4 with UUID, format, perms and constraints.
@Suite struct DefinitionsTests {
    @Test func characteristicUUIDsMatchBrief() {
        let expected: [(CharacteristicType, String)] = [
            (.identify, "14"), (.manufacturer, "20"), (.model, "21"), (.name, "23"), (.serialNumber, "30"),
            (.firmwareRevision, "52"), (.hardwareRevision, "53"), (.configuredName, "E3"), (.version, "37"),
            (.supportedVideoStreamConfiguration, "114"), (.supportedAudioStreamConfiguration, "115"), (.supportedRTPConfiguration, "116"),
            (.selectedRTPStreamConfiguration, "117"), (.setupEndpoints, "118"), (.streamingStatus, "120"), (.active, "B0"),
            (.supportedCameraRecordingConfiguration, "205"), (.supportedVideoRecordingConfiguration, "206"),
            (.supportedAudioRecordingConfiguration, "207"), (.selectedCameraRecordingConfiguration, "209"), (.recordingAudioActive, "226"),
            (.eventSnapshotsActive, "223"), (.homeKitCameraActive, "21B"), (.cameraOperatingModeIndicator, "21D"), (.manuallyDisabled, "227"),
            (.nightVision, "11B"), (.periodicSnapshotsActive, "225"), (.thirdPartyCameraActive, "21C"), (.diagonalFieldOfView, "224"),
            (.videoAnalysisActive, "229"), (.supportedDataStreamTransportConfiguration, "130"), (.setupDataStreamTransport, "131"),
            (.mute, "11A"), (.volume, "119"), (.programmableSwitchEvent, "73"), (.motionDetected, "22"), (.occupancyDetected, "71"),
            (.currentAmbientLightLevel, "6B"), (.currentTemperature, "11"), (.currentRelativeHumidity, "10"), (.contactSensorState, "6A"),
            (.on, "25"), (.statusActive, "75"), (.statusFault, "77"), (.statusTampered, "7A"), (.statusLowBattery, "79"),
            (.batteryLevel, "68"), (.chargingState, "8F"),
        ]
        for (type, uuid) in expected {
            #expect(type.uuid == uuid, "\(type.name)")
        }
        #expect(Set(expected.map(\.1)).count == expected.count)
    }

    @Test func serviceUUIDsMatchBrief() {
        let expected: [(ServiceType, String)] = [
            (.accessoryInformation, "3E"), (.protocolInformation, "A2"), (.cameraRTPStreamManagement, "110"),
            (.cameraRecordingManagement, "204"), (.cameraOperatingMode, "21A"), (.dataStreamTransportManagement, "129"),
            (.microphone, "112"), (.speaker, "113"), (.doorbell, "121"), (.statelessProgrammableSwitch, "89"), (.motionSensor, "85"),
            (.occupancySensor, "86"), (.lightSensor, "84"), (.temperatureSensor, "8A"), (.humiditySensor, "82"), (.contactSensor, "80"),
            (.battery, "96"), (.switch, "49"),
        ]
        for (type, uuid) in expected {
            #expect(type.uuid == uuid, "\(type.name)")
        }
    }

    @Test func constraintsFromPlan() {
        let pse = CharacteristicType.programmableSwitchEvent
        #expect(pse.format == .uint8 && pse.validValues == [0, 1, 2] && pse.permissions == [.pairedRead, .events])
        let motion = CharacteristicType.motionDetected
        #expect(motion.format == .bool && motion.permissions == [.pairedRead, .events])
        let setupDataStream = CharacteristicType.setupDataStreamTransport
        #expect(setupDataStream.format == .tlv8 && setupDataStream.permissions == [.pairedRead, .pairedWrite, .writeResponse])
        let selected = CharacteristicType.selectedCameraRecordingConfiguration
        #expect(selected.format == .tlv8 && selected.permissions == [.pairedRead, .pairedWrite, .events])
        let audio = CharacteristicType.recordingAudioActive
        #expect(audio.format == .uint8 && audio.permissions == [.pairedRead, .pairedWrite, .events, .timedWrite])
        let lux = CharacteristicType.currentAmbientLightLevel
        #expect(lux.format == .float && lux.minValue == 0.0001 && lux.maxValue == 100_000 && lux.unit == .lux)
        let temperature = CharacteristicType.currentTemperature
        #expect(temperature.minValue == -270 && temperature.maxValue == 100 && temperature.minStep == 0.1 && temperature.unit == .celsius)
        #expect(CharacteristicType.identify.permissions == [.pairedWrite])
        #expect(CharacteristicType.nightVision.permissions.contains(.timedWrite))
        #expect(CharacteristicType.cameraOperatingModeIndicator.permissions.contains(.timedWrite))
        #expect(CharacteristicType.volume.unit == .percentage && CharacteristicType.volume.maxValue == 100)
    }

    @Test func serviceRequiredCharacteristics() {
        #expect(ServiceType.accessoryInformation.required.map(\.uuid) == ["14", "20", "21", "23", "30", "52"])
        #expect(ServiceType.accessoryInformation.optional.contains(.hardwareRevision))
        #expect(ServiceType.motionSensor.required == [.motionDetected])
        #expect(ServiceType.motionSensor.optional.contains(.statusActive))
        #expect(ServiceType.dataStreamTransportManagement.required.map(\.uuid) == ["131", "130", "37"])
        #expect(ServiceType.cameraRTPStreamManagement.required.count == 6)
        #expect(ServiceType.doorbell.required == [.programmableSwitchEvent])
    }

    /// Plan W1-1 item 1 test: JSON of a MotionSensor service matches the expected structure.
    @Test func motionSensorServiceJSON() throws {
        let accessory = Accessory(info: AccessoryInfo(name: "Cam", manufacturer: "M", model: "X", serialNumber: "1", firmwareRevision: "1.0"),
                                  category: .sensor)
        let service = accessory.addService(Service(.motionSensor, name: "Motion"))
        service.characteristic(.statusActive).update(.bool(true))
        let publication = Publication(root: accessory, state: HAPPersistentState())
        publication.assignIDs()
        defer { publication.unbind() }

        let motion = service.characteristic(.motionDetected)
        let name = service.characteristic(.name)
        let active = service.characteristic(.statusActive)
        let json = HAPJSONEncoding.service(service, includeValues: true)
        let expected: HAPJSON = [
            "iid": .int(Int64(service.iid)),
            "type": "85",
            "characteristics": [
                ["iid": .int(Int64(motion.iid)), "type": "22", "perms": ["pr", "ev"], "format": "bool", "value": 0,
                 "description": "Motion Detected"],
                ["iid": .int(Int64(name.iid)), "type": "23", "perms": ["pr"], "format": "string", "value": "Motion",
                 "description": "Name", "maxLen": 64],
                ["iid": .int(Int64(active.iid)), "type": "75", "perms": ["pr", "ev"], "format": "bool", "value": 1,
                 "description": "Status Active"],
            ],
        ]
        #expect(json == expected)
        #expect(Set([service.iid, motion.iid, name.iid, active.iid]).count == 4)
        #expect(service.iid >= 2)
    }
}

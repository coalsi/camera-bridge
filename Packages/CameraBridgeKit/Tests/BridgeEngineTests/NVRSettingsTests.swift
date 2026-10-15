import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// The NVR's configuration fields, their defaults and tolerant decoding.
@Suite struct NVRSettingsTests {
    @Test func defaults() {
        let camera = NVRFixtures.camera()
        #expect(!camera.nvrEnabled && !camera.nvrRecordSound)
        let settings = BridgeSettings()
        #expect(settings.nvrFolder == nil && settings.nvrKeepDays == 7 && settings.nvrMaxSizeGB == 500)
        #expect(BridgeSettings.nvrKeepDaysRange == 1...365 && BridgeSettings.nvrMaxSizeGBRange == 10...100_000)
    }

    @Test func oldCameraConfigurationDecodesWithRecordingOff() throws {
        var camera = NVRFixtures.camera(name: "Porch")
        camera.nvrEnabled = true
        let old = try NVRFixtures.json(of: camera, removing: ["nvrEnabled", "nvrRecordSound"])
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: old)
        #expect(decoded.name == "Porch" && !decoded.nvrEnabled && !decoded.nvrRecordSound)
    }

    @Test func cameraFieldsRoundTrip() throws {
        var camera = NVRFixtures.camera()
        camera.nvrEnabled = true
        camera.nvrRecordSound = true
        let data = try JSONEncoder().encode(camera)
        #expect(String(decoding: data, as: UTF8.self).contains("\"nvrEnabled\":true"))
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: data) == camera)
        let wrongKind = try NVRFixtures.json(of: camera, setting: ["nvrEnabled": "yes", "nvrRecordSound": true])
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: wrongKind)
        #expect(!decoded.nvrEnabled && decoded.nvrRecordSound, "an unreadable value takes its default; the others stay")
    }

    @Test func oldSettingsDecodeWithTheNVRDefaults() throws {
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"webhookPort":21091,"keepMacAwake":true}"#.utf8))
        #expect(settings.webhookPort == 21_091 && settings.keepMacAwake)
        #expect(settings.nvrFolder == nil && settings.nvrKeepDays == 7 && settings.nvrMaxSizeGB == 500)
    }

    @Test func settingsRoundTrip() throws {
        var settings = BridgeSettings()
        settings.nvrFolder = "/Volumes/Recordings/Camera Bridge"
        settings.nvrKeepDays = 14
        settings.nvrMaxSizeGB = 2_000
        #expect(try JSONDecoder().decode(BridgeSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let none = String(decoding: try JSONEncoder().encode(BridgeSettings()), as: UTF8.self)
        #expect(!none.contains("nvrFolder"), "no folder, no key")
    }

    @Test func settingsThisBuildCannotAcceptTakeTheirDefaults() throws {
        let json = #"{"webhookPort":21092,"nvrFolder":"relative/path","nvrKeepDays":0,"nvrMaxSizeGB":5}"#
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(json.utf8))
        #expect(settings.webhookPort == 21_092, "the readable keys stay")
        #expect(settings.nvrFolder == nil && settings.nvrKeepDays == 7 && settings.nvrMaxSizeGB == 500)
        let edges = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"nvrKeepDays":365,"nvrMaxSizeGB":100000}"#.utf8))
        #expect(edges.nvrKeepDays == 365 && edges.nvrMaxSizeGB == 100_000)
        let over = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"nvrKeepDays":366,"nvrMaxSizeGB":100001}"#.utf8))
        #expect(over.nvrKeepDays == 7 && over.nvrMaxSizeGB == 500)
    }

    @Test func folderPaths() {
        for good in ["/", "/Volumes/Recordings", "/var/lib/camera-bridge/recordings", "/Users/me/Movies/Camera Bridge", "/a/b..c/d"] {
            #expect(BridgeSettings.isValidNVRFolder(good), "\(good)")
        }
        for bad in ["", "relative", "~/Movies", "/a/../b", "/a/b/..", "/a\u{0}b", "/a\nb", "/a\u{7F}b", "/" + String(repeating: "x", count: 1_024)] {
            #expect(!BridgeSettings.isValidNVRFolder(bad), "\(bad.debugDescription.prefix(40))")
        }
    }

    @Test func theEnvironmentCarriesNoArchivePolicyUnlessTheHostGivesOne() {
        var environment = BridgeEnvironment.inert(directory: URL(filePath: "/tmp/x"))
        #expect(environment.archivePolicy == nil)
        environment.archivePolicy = ArchivePlatformPolicy(space: { _ in nil }, isSystemVolume: { _ in false }, systemFloor: { $0 / 10 }, directoryNaming: .cameraID)
        #expect(environment.archivePolicy?.directoryNaming == .cameraID && environment.archivePolicy?.space(URL(filePath: "/")) == nil)
        #expect(BridgeEnvironment(dataDirectory: URL(filePath: "/tmp/y"), platform: environment.platform, codecs: environment.codecs).archivePolicy == nil)
    }

    @Test func theDemoCameraKeyframeIntervalFollowsTheEnvironmentOnlyBetween1And120Seconds() {
        let environment = BridgeEnvironment.inert(directory: URL(filePath: "/tmp/x"))
        #expect(environment.demoKeyframeSeconds == nil, "the default is the engine's own 2 s")
        let base = DemoStream(width: 1920, height: 1080, fps: 30, keyframeInterval: .seconds(2))
        #expect(base.withKeyframeSeconds(nil) == base)
        #expect(base.withKeyframeSeconds(12).keyframeInterval == .seconds(12) && base.withKeyframeSeconds(12).width == 1920)
        #expect(base.withKeyframeSeconds(1).keyframeInterval == .seconds(1) && base.withKeyframeSeconds(120).keyframeInterval == .seconds(120))
        for refused in [0, 0.5, 120.5, 1_000, -3, Double.nan, Double.infinity] { #expect(base.withKeyframeSeconds(refused) == base, "\(refused)") }
        #expect(BridgeEnvironment(dataDirectory: URL(filePath: "/tmp/y"), platform: environment.platform, codecs: environment.codecs, demoKeyframeSeconds: 30).demoKeyframeSeconds == 30)
    }
}

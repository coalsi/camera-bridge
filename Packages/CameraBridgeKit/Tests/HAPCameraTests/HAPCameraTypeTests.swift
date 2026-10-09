import Foundation
import Testing
@testable import HAPCamera

@Suite struct HAPCameraTypeTests {
    @Test func sampleRates() {
        #expect(StreamingSampleRate.allHertz == [8_000, 16_000, 24_000])
        #expect([RecordingSampleRate.khz8, .khz16, .khz24, .khz32, .khz44_1, .khz48].map(\.hertz) == [8_000, 16_000, 24_000, 32_000, 44_100, 48_000])
        #expect(RecordingSampleRate.khz32.rawValue == 3)
    }

    @Test func triggersAndDefaults() {
        #expect(RecordingEventTrigger.motion == 1 && RecordingEventTrigger.doorbell == 2)
        let recording = CameraRecordingOptions(resolutions: [VideoResolution(1920, 1080, 30)])
        #expect(recording.prebufferLengthMs == 4000 && recording.fragmentLengthMs == 4000 && recording.audioSampleRates == [.khz32])
        let streaming = CameraStreamingOptions(resolutions: [VideoResolution(1280, 720, 30)], twoWayAudio: true)
        #expect(streaming.audioCodecs.count == 1 && streaming.audioCodecs[0].codec == .opus && streaming.cryptoSuites == [.aesCm128HmacSha1_80])
    }

    @Test func recordingConfigurationCodable() throws {
        let config = CameraRecordingConfiguration(prebufferLengthMs: 4000, eventTriggers: RecordingEventTrigger.motion, fragmentLengthMs: 4000,
                                                  videoProfile: .main, videoLevel: .level4_0, videoBitrateKbps: 2000, iFrameIntervalMs: 4000,
                                                  resolution: VideoResolution(1920, 1080, 30), audioCodec: .aacLC, audioChannels: 1,
                                                  audioSampleRate: .khz32, audioMaxBitrateKbps: 24)
        #expect(try JSONDecoder().decode(CameraRecordingConfiguration.self, from: JSONEncoder().encode(config)) == config)
    }
}

private extension StreamingSampleRate {
    static var allHertz: [Int] { [StreamingSampleRate.khz8, .khz16, .khz24].map(\.hertz) }
}

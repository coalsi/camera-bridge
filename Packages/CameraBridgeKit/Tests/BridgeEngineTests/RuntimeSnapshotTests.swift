import TestSupport
@testable import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import Synchronization
import Testing
@testable import BridgeEngine
#if canImport(Darwin)
import PlatformApple
#endif

/// Snapshots (plan W3-1 item 4, integration brief §5.4): camera API first, 10 s cache for periodic requests, never for
/// event requests (which still reuse the JPEG of a keyframe they already decoded), 8 s budget.
@Suite(.timeLimit(.minutes(1))) struct RuntimeSnapshotTests {
    static let log = Log(category: "SnapshotTest")

    /// A fake camera API + codecs; time moves only when the test says so.
    final class Fixture: Sendable {
        let apiCalls = Box(0)
        let resizes = Box<[(Int?, Int?)]>([])
        let keyframeJPEGs = Box(0)
        let apiAnswer: Box<Result<Data?, TransportError>>
        let apiDelay: Box<Duration>
        let clock = Box(ContinuousClock.now)

        init(api: Result<Data?, TransportError> = .success(Data([0xFF, 0xD8, 1])), delay: Duration = .zero) {
            apiAnswer = Box(api)
            apiDelay = Box(delay)
        }

        func provider(hub: MediaHub = MediaHub(), api: Bool = true, timing: SnapshotProvider.Timing = SnapshotProvider.Timing()) -> SnapshotProvider {
            let answer: SnapshotProvider.CameraSnapshot = { @Sendable [self] in
                apiCalls.update { $0 += 1 }
                try await Task.sleep(for: apiDelay.value)
                return try apiAnswer.value.get()
            }
            let camera: SnapshotProvider.CameraSnapshot? = api ? answer : nil
            return SnapshotProvider(cameraSnapshot: camera, resize: { [self] jpeg, width, height in
                resizes.update { $0.append((width, height)) }
                return jpeg + Data([0xAA])
            }, keyframeJPEG: { [self] _, _, _ in
                keyframeJPEGs.update { $0 += 1 }
                return Data([0xFF, 0xD8, 0x4B])
            }, hub: hub, timing: timing, log: RuntimeSnapshotTests.log, now: { [self] in clock.value })
        }

        func advance(_ duration: Duration) { clock.update { $0 += duration } }
    }

    static func keyframe() -> EncodedVideoFrame {
        EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: []), nalUnits: [Data([0x65, 1])], isKeyframe: true,
                          pts: MediaTime(value: 0, timescale: 90_000), wallClock: Date())
    }

    @Test func cameraAPIFirstResizedToTheRequest() async throws {
        let fixture = Fixture()
        let provider = fixture.provider()
        let jpeg = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .periodic))
        #expect(jpeg == Data([0xFF, 0xD8, 1, 0xAA]))
        #expect(fixture.apiCalls.value == 1 && fixture.keyframeJPEGs.value == 0)
        #expect(fixture.resizes.value.count == 1 && fixture.resizes.value[0] == (640, 360))
    }

    @Test func periodicRequestsUseTheTenSecondCacheEventsNever() async throws {
        let fixture = Fixture()
        let provider = fixture.provider()
        _ = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .periodic))
        fixture.advance(.seconds(9))
        _ = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .periodic))
        _ = try await provider.snapshot(SnapshotRequest(width: 640, height: 360))
        #expect(fixture.apiCalls.value == 1)
        _ = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(fixture.apiCalls.value == 2, "event snapshots are never served from the cache")
        // Another size is not the cached picture.
        _ = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic))
        #expect(fixture.apiCalls.value == 3)
        fixture.advance(.seconds(11))
        _ = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic))
        #expect(fixture.apiCalls.value == 4, "the cache expires after 10 s")
    }

    @Test func fallsBackToTheLastKeyframeAndSkipsAFailingAPI() async throws {
        let fixture = Fixture(api: .failure(.timedOut))
        let hub = MediaHub()
        await hub.ingest(.video(Self.keyframe()))
        let provider = fixture.provider(hub: hub)
        #expect(try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event)) == Data([0xFF, 0xD8, 0x4B]))
        #expect(fixture.apiCalls.value == 1 && fixture.keyframeJPEGs.value == 1)
        _ = try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        #expect(fixture.apiCalls.value == 1, "a failing API is skipped for 30 s")
        fixture.advance(.seconds(31))
        _ = try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        #expect(fixture.apiCalls.value == 2)
    }

    /// Review finding (W4 round 4): a camera API that rejected the credentials was asked again 30 s later, like any other
    /// failure. Every request is a login (Hikvision Digest, Reolink `Login`, ONVIF WS-Security), and Home asks for a
    /// snapshot every 10 s while a tile is visible: about two failed logins a minute, which locks a Hikvision account
    /// (5–7 illegal logins) for 30 minutes, RTSP included, even after the password is corrected. Rejected credentials
    /// wait `unauthorizedRetry` (10 min) like the ingest, the event channels and the stream-address probe; the keyframe
    /// stands in meanwhile.
    @Test func rejectedCredentialsSkipTheCameraAPIForTheUnauthorizedWait() async throws {
        let calls = Box(0)
        let clock = Box(ContinuousClock.now)
        let hub = MediaHub()
        await hub.ingest(.video(Self.keyframe()))
        let rejecting: SnapshotProvider.CameraSnapshot = {
            calls.update { $0 += 1 }
            throw CameraAdapterError.unauthorized
        }
        let provider = SnapshotProvider(cameraSnapshot: rejecting, resize: { jpeg, _, _ in jpeg }, keyframeJPEG: { _, _, _ in Data([0xFF, 0xD8, 0x4B]) },
                                        hub: hub, log: Self.log, now: { clock.value })
        for _ in 0..<60 {   // 10 minutes of a visible tile, event snapshots (never cached)
            #expect(try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event)) == Data([0xFF, 0xD8, 0x4B]))
            clock.update { $0 += .seconds(10) }
        }
        #expect(calls.value == 1, "\(calls.value) failed logins in 10 minutes")
        _ = try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        #expect(calls.value == 2, "asked again once the wait is over")

        // Other failures keep the short skip.
        let transient = Fixture(api: .failure(.timedOut))
        let other = transient.provider(hub: hub)
        _ = try await other.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        transient.advance(.seconds(31))
        _ = try await other.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        #expect(transient.apiCalls.value == 2)
    }

    @Test func unsupportedAPIIsNotAskedAgain() async throws {
        let fixture = Fixture(api: .success(nil))
        let hub = MediaHub()
        await hub.ingest(.video(Self.keyframe()))
        let provider = fixture.provider(hub: hub)
        _ = try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        _ = try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        #expect(fixture.apiCalls.value == 1 && fixture.keyframeJPEGs.value == 1, "the same keyframe is not decoded twice")
    }

    @Test(.timeLimit(.minutes(1))) func aSlowCameraAPIFallsBackWithinTheBudget() async throws {
        let fixture = Fixture(delay: .seconds(30))
        let hub = MediaHub()
        await hub.ingest(.video(Self.keyframe()))
        var timing = SnapshotProvider.Timing()
        timing.cameraAPITimeout = .milliseconds(200)
        timing.budget = .seconds(2)
        let provider = fixture.provider(hub: hub, timing: timing)
        let started = ContinuousClock.now
        #expect(try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event)) == Data([0xFF, 0xD8, 0x4B]))
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test(.timeLimit(.minutes(1))) func noPictureFailsWithinTheBudgetAndAKeyframeArrivingInTimeIsUsed() async throws {
        let fixture = Fixture()
        var timing = SnapshotProvider.Timing()
        timing.budget = .milliseconds(500)
        let empty = fixture.provider(hub: MediaHub(), api: false, timing: timing)
        let started = ContinuousClock.now
        await #expect(throws: DeadlineExceeded.self) { _ = try await empty.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event)) }
        #expect(ContinuousClock.now - started < .seconds(2))

        let hub = MediaHub()
        timing.budget = .seconds(5)
        let waiting = fixture.provider(hub: hub, api: false, timing: timing)
        let request = Task { try await waiting.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event)) }
        #expect(await eventually { await hub.subscriberCount == 1 })
        await hub.ingest(.video(Self.keyframe()))
        #expect(try await request.value == Data([0xFF, 0xD8, 0x4B]))
    }

    #if canImport(Darwin)
    @Test(.timeLimit(.minutes(1))) func realKeyframeBecomesAJPEGOfTheRequestedSize() async throws {
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, audio: nil))
        #expect(await feeder.waitUntilReady())
        let provider = SnapshotProvider(cameraSnapshot: nil, codecs: AppleMediaCodecs(), hub: feeder.hub, log: Self.log)
        let jpeg = try await provider.snapshot(SnapshotRequest(width: 320, height: 180, reason: .event))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        let (width, height) = try jpegSize(jpeg)
        #expect(width <= 320 && height <= 180 && width >= 300)
        await feeder.stop()
    }
    #endif

    /// Collects what a private `LogRouter` logs.
    final class CapturingSink: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
    }

    /// Review finding (W4): a camera snapshot that failed in transport logged the URLError verbatim at info level — its
    /// failing URL carries the Reolink session token (or a Foscam-style `pwd=` in an ONVIF snapshot URI).
    @Test func aFailingCameraSnapshotNeverLogsItsURL() async throws {
        let router = LogRouter()
        let sink = CapturingSink()
        router.addSink(sink)
        let log = Log(category: "Camera", router: router)
        let url = "http://192.0.2.10/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=a1b2&token=S3CRETTOKEN0123&pwd=FOSCAMPW77"
        let failing: SnapshotProvider.CameraSnapshot = {
            throw URLError(.networkConnectionLost, userInfo: ["NSErrorFailingURLStringKey": url, NSURLErrorFailingURLErrorKey: URL(string: url) as Any])
        }
        let hub = MediaHub()
        await hub.ingest(.video(Self.keyframe()))
        let provider = SnapshotProvider(cameraSnapshot: failing, resize: { jpeg, _, _ in jpeg }, keyframeJPEG: { _, _, _ in Data([0xFF, 0xD8, 2]) },
                                        hub: hub, log: log)
        let jpeg = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(jpeg == Data([0xFF, 0xD8, 2]), "the keyframe stands in")
        let messages = sink.entries.value.map(\.message)
        #expect(messages.contains { $0.hasPrefix("Camera snapshot failed") })
        #expect(!messages.contains { $0.contains("S3CRETTOKEN0123") || $0.contains("FOSCAMPW77") }, "\(messages)")
        // The summary is BridgeSupport's `URLFreeErrors.describe` (every case is tested in BridgeSupportTests).
        #expect(messages.contains { $0.contains("(URLError \(URLError.Code.networkConnectionLost.rawValue))") }, "\(messages)")
    }
}

/// Width and height from a JPEG's SOF marker.
func jpegSize(_ jpeg: Data) throws -> (Int, Int) {
    let bytes = [UInt8](jpeg)
    var index = 2
    while index + 9 < bytes.count {
        guard bytes[index] == 0xFF else { index += 1; continue }
        let marker = bytes[index + 1]
        let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
        if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
            return (Int(bytes[index + 7]) << 8 | Int(bytes[index + 8]), Int(bytes[index + 5]) << 8 | Int(bytes[index + 6]))
        }
        index += 2 + length
    }
    throw SnapshotProvider.Failure.noPicture
}

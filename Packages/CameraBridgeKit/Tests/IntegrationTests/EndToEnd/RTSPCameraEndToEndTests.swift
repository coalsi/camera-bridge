#if os(macOS)
import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import MediaCore
import RTP
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine
@testable import PlatformApple

extension EndToEndTests {
    /// Plan W3-2 scenarios 5–6: a camera behind `RTSPTestServer` (Digest authentication with qop=auth, H.264 1280×720@25 with 1 s
    /// GOPs, PCMU 8 kHz audio; an ONVIF audio backchannel for two-way audio) bridged by the engine and used like a hub
    /// uses it: live view, HKSV recording, a camera that drops its connections, and talking through the camera.
    @Suite struct RTSPCamera {
        static let username = "admin"
        static let password = "s3cret"
        static let pcmu = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)

        /// `source`: the camera's picture and sound (default: H.264 1280×720@25, 1 s GOPs, PCMU 8 kHz).
        static func startServer(backchannel: Bool, source: (any MediaSource)? = nil) async throws -> RTSPTestServer {
            var configuration = RTSPTestServer.Configuration()
            configuration.credentials = HTTPCredentials(username: username, password: password)
            configuration.authentication = .digestWithQop   // qop=auth, as Hikvision and Reolink answer
            configuration.audio = pcmu
            if backchannel { configuration.backchannel = pcmu }
            let source = source ?? AppleMediaCodecs().makeSyntheticSource(displayName: "RTSP camera", width: 1280, height: 720, fps: 25,
                                                                          keyframeInterval: .seconds(1), audio: .pcmu, audioSampleRate: 8_000)
            let server = RTSPTestServer(source: source, transport: AppleNetworkTransport(), configuration: configuration)
            try await server.start()
            return server
        }

        static func requests(_ server: RTSPTestServer, _ method: String) -> [RTSPTestServer.RecordedRequest] {
            server.requests.filter { $0.method == method }
        }

        // MARK: Scenario 5 — RTSP camera: live, recording, reconnect

        @MainActor @Test(.timeLimit(.minutes(3)))
        func digestRTSPCameraStreamsRecordsAndResumesAfterTheCameraDropsItsConnections() async throws {
            let server = try await Self.startServer(backchannel: false)
            let fixture = try await EndToEndEngine()
            let engine = fixture.engine
            var camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp,
                                             endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: Int(server.port)), username: Self.username)
            camera.mainStreamURL = server.url
            try await engine.addCamera(camera, password: Self.password)
            await engine.start()
            _ = try await fixture.waitUntilServing(camera.id)
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.videoSummary?.hasPrefix("H.264 1280×720") == true },
                    "\(String(describing: fixture.status(camera.id)?.videoSummary))")

            // Digest: the camera challenged, the engine answered for its user (the password itself never travels).
            let describes = Self.requests(server, "DESCRIBE")
            #expect(describes.contains { request in
                guard let answer = request.headers["Authorization"], answer.hasPrefix("Digest ") else { return false }
                return answer.contains("username=\"admin\"") && answer.contains("qop=auth") && answer.contains("nc=") && answer.contains("cnonce=")
            }, "no Digest (qop=auth) answer among \(describes.map { $0.headers["Authorization"] ?? "-" })")
            #expect(!server.requests.contains { request in request.headers.contains { $0.1.contains(Self.password) } }, "the password was sent in clear")

            let controller = try await fixture.pair(camera.id)
            let ids = try await controller.cameraIDs()

            // Live view at 720p: the camera's H.264 passes through, its PCMU becomes Opus.
            let live = try await controller.startLiveStream(ids.streams[0])
            let receiver = live.receiver
            // The pictures that arrive after the camera's drop (set below), kept for decoding.
            let dropTime = Box<ContinuousClock.Instant?>(nil)
            let afterDrop = Task {
                var frames: [ReceivedVideoFrame] = []
                for await frame in receiver.videoFrames {
                    guard let dropped = dropTime.value, frame.receivedAt > dropped else { continue }
                    frames.append(frame)
                    if frames.count >= 100 { break }
                }
                return frames
            }
            #expect(await receiver.waitFor(timeout: .seconds(2)) { $0.keyframes >= 1 }, "no keyframe within 2 s")
            let flowing = await receiver.waitFor(timeout: .seconds(5)) { $0.videoFrames >= 50 && $0.audioFrames >= 50 }
            let flowStatistics = await receiver.statistics
            #expect(flowing, "\(flowStatistics)")

            // HKSV recording with audio (PCMU → AAC-LC 32 kHz), kept open across the camera's reconnect.
            let recordingIDs = try #require(ids.recording)
            let supported = try await controller.supportedRecordingConfiguration(recordingIDs)
            try await controller.selectRecordingConfiguration(recordingIDs, try .preferred(camera: supported.camera, video: supported.video,
                                                                                          audio: supported.audio))
            try await controller.enableRecording(ids, audio: true)
            let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
            #expect(try await dataStream.openRecording(streamID: 1).isAccepted)
            let packets = Box(0)
            let recording = Task {
                try await dataStream.receiveRecording(streamID: 1, maximumFragments: 6, eventTimeout: .seconds(20)) { _ in packets.update { $0 += 1 } }
            }
            #expect(await eventually(timeout: .seconds(20)) { packets.value >= 3 }, "init + 2 fragments before the drop")

            // The camera drops every connection (a reboot): the engine reconnects by itself.
            let plays = Self.requests(server, "PLAY").count
            let dropped = ContinuousClock.now
            dropTime.update { $0 = dropped }
            server.dropConnections()
            #expect(await eventually(timeout: .seconds(15)) { Self.requests(server, "PLAY").count > plays }, "the engine did not reconnect")
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.connection == .online })

            // The live view goes on in the same session: a keyframe and seconds of pictures and sound after the drop.
            #expect(await eventually(timeout: .seconds(15)) {
                let after = await receiver.frameRecords.filter { $0.receivedAt > dropped }
                return after.contains(where: \.isKeyframe) && after.count >= 50
            }, "the live view did not resume")
            let audioAfterDrop = await receiver.statistics.audioFrames
            #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.audioFrames >= audioAfterDrop + 25 }, "the live audio did not resume")
            #expect(await receiver.statistics.byes == 0, "the live session ended")
            // …and what comes after the reconnect decodes: the camera's 720p passed through, parameter sets resent.
            _ = await eventually(timeout: .seconds(10)) { await receiver.frameRecords.filter { $0.receivedAt > dropped }.count >= 100 }
            afterDrop.cancel()   // ends the collection with what arrived (no-op once it has 100 pictures)
            let resumed = await afterDrop.value
            let sizes = try await decodeLiveFrames(resumed)
            #expect(sizes.count >= 50 && sizes.allSatisfy { $0.width == 1280 && $0.height == 720 },
                    "\(sizes.count) of \(resumed.count) pictures after the drop decoded")

            // The recording goes on too: whole IDR-first fragments after the reconnect, one continuous timeline.
            let capture = try await recording.value
            #expect(capture.fragments.count >= 6 && capture.closeReason == nil && !capture.endOfStream,
                    "\(capture.fragments.count) fragments, close \(String(describing: capture.closeReason))")
            #expect(capture.arrivalTimes.filter { $0 > dropped }.count >= 3, "fragments after the drop")
            let (initialization, fragments) = try checkRecording(capture, audio: true)
            let video = try #require(initialization.video)
            #expect(video.width == 1280 && video.height == 720)
            let file = fixture.directory.appending(path: "rtsp-recording.mp4")
            try capture.mp4.write(to: file)
            let report = try await decodeWithAVFoundation(file)
            #expect(report.videoReaderCompleted && report.audioReaderCompleted && report.audioTrackCount == 1)
            #expect(report.decodedVideoFrames == fragments.compactMap { $0.run(track: video.id)?.sampleCount }.reduce(0, +))
            #expect(report.decodedAudioSamples > 0)
            #expect(report.audioPeak > 1_000, "the camera's tone is recorded (peak \(report.audioPeak))")

            try await dataStream.closeRecording(streamID: 1)
            try await live.stop()
            await dataStream.close()
            await controller.close()
            await fixture.tearDown()
            await server.stop()
        }

        /// Review finding (W4 round 3): the Camera Audio toggle (a privacy setting: the camera's microphone in Home and in
        /// recordings) was never run with a camera that has audio; removing it from the engine, the live path and the
        /// recording path passed every suite. Off, live view carries no camera sound and recordings carry silence.
        @MainActor @Test(.timeLimit(.minutes(2)))
        func cameraAudioOffKeepsTheCamerasSoundOutOfLiveViewAndRecordings() async throws {
            let server = try await Self.startServer(backchannel: false)
            let fixture = try await EndToEndEngine()
            let engine = fixture.engine
            var camera = CameraConfiguration(name: "Nursery", kind: .camera, vendor: .rtsp,
                                             endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: Int(server.port)), username: Self.username)
            camera.mainStreamURL = server.url
            camera.audioEnabled = false
            try await engine.addCamera(camera, password: Self.password)
            await engine.start()
            _ = try await fixture.waitUntilServing(camera.id)
            let controller = try await fixture.pair(camera.id)
            let ids = try await controller.cameraIDs()

            let live = try await controller.startLiveStream(ids.streams[0])
            let receiver = live.receiver
            #expect(await receiver.waitFor(timeout: .seconds(10)) { $0.videoFrames >= 50 })
            #expect(await receiver.statistics.audioFrames == 0, "the camera's sound reached the live view")

            let recordingIDs = try #require(ids.recording)
            let supported = try await controller.supportedRecordingConfiguration(recordingIDs)
            try await controller.selectRecordingConfiguration(recordingIDs, try .preferred(camera: supported.camera, video: supported.video,
                                                                                          audio: supported.audio))
            try await controller.enableRecording(ids, audio: true)
            let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
            #expect(try await dataStream.openRecording(streamID: 1).isAccepted)
            let capture = try await dataStream.receiveRecording(streamID: 1, maximumFragments: 3, eventTimeout: .seconds(20)) { _ in }
            _ = try checkRecording(capture, audio: true)
            let file = fixture.directory.appending(path: "camera-audio-off.mp4")
            try capture.mp4.write(to: file)
            let report = try await decodeWithAVFoundation(file)
            #expect(report.audioTrackCount == 1 && report.decodedAudioSamples > 0, "RecordingAudioActive: an audio track")
            #expect(report.audioPeak < 100, "the recording carries the camera's sound (peak \(report.audioPeak))")

            try await dataStream.closeRecording(streamID: 1)
            try await live.stop()
            await dataStream.close()
            await controller.close()
            await fixture.tearDown()
            await server.stop()
        }

        // MARK: H.265 camera

        /// Review finding (W4 round 4): every end-to-end camera was H.264, and no test ran real H.265 from RTSP to a decoder.
        /// Most 4K Hikvision and Reolink main streams are H.265, yet a regression that affected only H.265 input passed every
        /// suite: the RTSP H.265 depacketizer (sprop-vps/sps/pps, AP, FU), the H.265 format and parameter sets reaching the
        /// hub, the transcoders and the snapshot decoder, or MediaFit's transcode routing. This camera serves real H.265
        /// over RTSP (VideoToolbox, 1280×720@25, 1 s GOPs) with PCMU 8 kHz audio. The engine reads it as H.265, and the hub
        /// gets H.264 everywhere: a snapshot from an H.265 keyframe, a 720p live view, and an HKSV recording of an init
        /// segment and 2 fragments, all of which decode.
        @MainActor @Test(.enabled(if: HEVCCameraSource.encoderAvailable, "no HEVC encoder on this Mac"), .timeLimit(.minutes(2)))
        func hevcCameraReachesTheHubAsH264InSnapshotsLiveViewAndRecordings() async throws {
            let source = HEVCCameraSource(width: 1280, height: 720, fps: 25, keyframeInterval: .seconds(1), audio: Self.pcmu)
            let server = try await Self.startServer(backchannel: false, source: source)
            let fixture = try await EndToEndEngine()
            let engine = fixture.engine
            var camera = CameraConfiguration(name: "Driveway", kind: .camera, vendor: .rtsp,
                                             endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: Int(server.port)), username: Self.username)
            camera.mainStreamURL = server.url
            try await engine.addCamera(camera, password: Self.password)
            await engine.start()
            _ = try await fixture.waitUntilServing(camera.id)
            // The RTSP leg: the camera announced H.265 (sprop-vps/sps/pps) and the engine's ingest reports 720p H.265. That the
            // pictures were whole (AP parameter sets, FU slices) shows below: everything the hub gets is decoded from them.
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.videoSummary?.hasPrefix("H.265 1280×720") == true },
                    "\(String(describing: fixture.status(camera.id)?.videoSummary))")
            #expect(source.sentKeyframes > 0 && server.sentVideoFrameCount > 0, "the camera sent no H.265")
            let controller = try await fixture.pair(camera.id)
            let ids = try await controller.cameraIDs()

            // The Home tile: a generic RTSP camera has no snapshot API, so the hub's last H.265 keyframe is decoded to JPEG.
            let snapshot = try await controller.snapshot(width: 640, height: 360)
            let snapshotSize = try jpegSize(snapshot)
            #expect(snapshotSize.width == 640 && snapshotSize.height == 360, "snapshot \(snapshotSize.width)×\(snapshotSize.height)")

            // Live view at 720p: H.265 cannot pass through, so it is transcoded to H.264 that decodes at the requested size.
            let live = try await controller.startLiveStream(ids.streams[0])
            let receiver = live.receiver
            let collected = Task {
                var frames: [ReceivedVideoFrame] = []
                for await frame in receiver.videoFrames {
                    frames.append(frame)
                    if frames.count >= 75 { break }
                }
                return frames
            }
            #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.keyframes >= 1 }, "no keyframe within 5 s")
            let flowing = await receiver.waitFor(timeout: .seconds(10)) { $0.videoFrames >= 75 && $0.audioFrames >= 50 }
            let statistics = await receiver.statistics
            #expect(flowing, "\(statistics)")
            #expect(statistics.incompleteVideoFrames == 0 && statistics.malformedPackets == 0, "\(statistics)")
            collected.cancel()   // ends the collection with what arrived (no-op once it has 75 pictures)
            let received = await collected.value
            #expect(received.first?.isKeyframe == true, "the live view does not open with an H.264 IDR")
            #expect(received.filter(\.isKeyframe).allSatisfy { $0.sps != nil && $0.pps != nil }, "an H.264 keyframe without SPS/PPS")
            let sizes = try await decodeLiveFrames(received)
            #expect(sizes.count >= 50 && sizes.allSatisfy { $0.width == 1280 && $0.height == 720 },
                    "\(sizes.count) of \(received.count) live pictures decoded as H.264, sizes \(Set(sizes.map { "\($0.width)×\($0.height)" }))")

            // HKSV recording: H.265 is transcoded to the selected H.264 (avc1), PCMU to AAC-LC 32 kHz.
            let recordingIDs = try #require(ids.recording)
            let supported = try await controller.supportedRecordingConfiguration(recordingIDs)
            let selection = try ControllerTLV.SelectedCameraRecordingConfiguration.preferred(camera: supported.camera, video: supported.video,
                                                                                            audio: supported.audio)
            try await controller.selectRecordingConfiguration(recordingIDs, selection)
            try await controller.enableRecording(ids, audio: true)
            let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
            #expect(try await dataStream.openRecording(streamID: 1).isAccepted)
            let capture = try await dataStream.receiveRecording(streamID: 1, maximumFragments: 2, eventTimeout: .seconds(20))
            #expect(capture.fragments.count >= 2 && capture.closeReason == nil && !capture.endOfStream,
                    "\(capture.fragments.count) fragments, close \(String(describing: capture.closeReason))")
            let (initialization, fragments) = try checkRecording(capture, audio: true)
            let video = try #require(initialization.video)
            #expect(video.width == selection.resolution.width && video.height == selection.resolution.height,
                    "recorded \(video.width)×\(video.height) for \(selection.resolution)")
            #expect(video.avcProfile == 77, "profile \(String(describing: video.avcProfile))")
            let videoSamples = fragments.compactMap { $0.run(track: video.id)?.sampleCount }.reduce(0, +)
            let file = fixture.directory.appending(path: "hevc-camera-recording.mp4")
            try capture.mp4.write(to: file)
            let report = try await decodeWithAVFoundation(file)
            #expect(report.videoTrackCount == 1 && report.audioTrackCount == 1)
            #expect(report.videoReaderCompleted && report.audioReaderCompleted)
            #expect(videoSamples >= 50 && report.decodedVideoFrames == videoSamples, "decoded \(report.decodedVideoFrames) of \(videoSamples) frames")
            #expect(report.decodedAudioSamples > 0 && report.audioPeak > 1_000, "the camera's tone is recorded (peak \(report.audioPeak))")

            try await dataStream.closeRecording(streamID: 1)
            try await live.stop()
            await dataStream.close()
            await controller.close()
            await fixture.tearDown()
            await server.stop()
        }

        // MARK: Scenario 6 — two-way audio

        /// The ONVIF talkback sink sets up only the camera's backchannel track: talking does not pull a second
        /// main stream from the camera (one more RTSP session, full bitrate) only to drop it.
        @Test(.timeLimit(.minutes(1)))
        func talkbackSessionSetsUpOnlyTheBackchannel() async throws {
            let server = try await Self.startServer(backchannel: true)
            let driver = CameraDrivers.make(vendor: .onvif, endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: Int(server.port)),
                                            credentials: HTTPCredentials(username: Self.username, password: Self.password),
                                            mainStreamURL: server.url, subStreamURL: nil, transport: AppleNetworkTransport())
            let sink = try #require(driver.makeTalkbackSink())
            try await sink.open()
            #expect(sink.inputFormat == Self.pcmu)
            for index in 0..<20 {
                let frame = EncodedAudioFrame(format: Self.pcmu, data: Data(repeating: 0x7F, count: 160),
                                              pts: MediaTime(value: Int64(index * 160), timescale: 8_000), sampleCount: 160, wallClock: Date())
                try await sink.send(frame)
            }
            #expect(await eventually(timeout: .seconds(5)) { server.backchannelPackets.count >= 20 }, "\(server.backchannelPackets.count) backchannel packets")
            try await Task.sleep(for: .milliseconds(500))   // 12 frames at 25 fps, if video were playing
            let setups = Self.requests(server, "SETUP").map(\.uri)
            #expect(setups.count == 1 && setups.first?.hasSuffix("trackID=2") == true, "SETUP \(setups)")
            #expect(server.sentVideoFrameCount == 0, "the camera sent \(server.sentVideoFrameCount) video frames to the talkback session")
            await sink.close()
            #expect(await eventually(timeout: .seconds(5)) { !Self.requests(server, "TEARDOWN").isEmpty }, "the talkback session is torn down")
            await server.stop()
        }

        @MainActor @Test(.timeLimit(.minutes(1)))
        func twoWayAudioReachesTheCameraBackchannelAsPCMU() async throws {
            let server = try await Self.startServer(backchannel: true)
            let web = try await NotFoundHTTPServer(transport: AppleNetworkTransport())
            let fixture = try await EndToEndEngine()
            let engine = fixture.engine
            // An ONVIF camera with a configured stream URL; its SOAP endpoints answer 404 (no events, no snapshots).
            var camera = CameraConfiguration(name: "Gate", kind: .camera, vendor: .onvif,
                                             endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(web.port), rtspPort: Int(server.port)),
                                             username: Self.username)
            camera.mainStreamURL = server.url
            camera.twoWayAudio = true
            camera.motionSource = .webhook
            try await engine.addCamera(camera, password: Self.password)
            await engine.start()
            _ = try await fixture.waitUntilServing(camera.id)

            let controller = try await fixture.pair(camera.id)
            let accessory = try #require(try await controller.accessories().accessory(aid: 1))
            #expect(accessory.service(.speaker) != nil && accessory.service(.microphone) != nil, "two-way audio offered")
            let ids = try await controller.cameraIDs()
            let live = try await controller.startLiveStream(ids.streams[0])
            let receiver = live.receiver
            #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.audioFrames >= 10 }, "no camera audio")

            // The controller talks: it sends the camera's own sound (a 440 Hz tone, as Opus 24 kHz) back as return audio.
            let echo = Task {
                var sent = 0
                for await frame in receiver.audioFrames {
                    do { try await receiver.sendReturnAudio(frame.payload, samples: 480) } catch { break }
                    sent += 1
                    if sent >= 200 { break }
                }
                return sent
            }

            // The camera hears it on its ONVIF backchannel, as PCMU 8 kHz.
            #expect(await eventually(timeout: .seconds(10)) { server.backchannelPackets.count >= 100 }, "\(server.backchannelPackets.count) backchannel packets")
            echo.cancel()
            let sent = await echo.value
            #expect(sent >= 100)
            #expect(Self.requests(server, "DESCRIBE").contains { $0.headers["Require"]?.contains("www.onvif.org/ver20/backchannel") == true },
                    "the talkback session asked for the backchannel")
            let backchannel = server.backchannelPackets
            #expect(backchannel.allSatisfy { $0.payloadType == 0 && !$0.payload.isEmpty }, "payload types \(Set(backchannel.map(\.payloadType)))")
            let steps = zip(backchannel, backchannel.dropFirst()).map { Int(Int32(bitPattern: $1.timestamp &- $0.timestamp)) }
            #expect(zip(steps, backchannel).allSatisfy { $0 == $1.payload.count }, "RTP timestamps advance by the samples sent (8 kHz)")
            // What arrives is the tone: loud enough and about 440 Hz (zero crossings), not silence or noise.
            let samples = G711.decodeMuLaw(backchannel.reduce(into: Data()) { $0.append($1.payload) }).dropFirst(800).map(Double.init)
            #expect(samples.count >= 4_000)
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Double(max(1, samples.count))).squareRoot()
            let crossings = zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
            let frequency = Double(crossings) / 2 / (Double(samples.count) / 8_000)
            #expect(rms > 1_000, "backchannel RMS \(rms)")
            #expect((400...480).contains(frequency), "backchannel tone at \(frequency) Hz")

            // Ending the live view closes the talkback session.
            let teardowns = Self.requests(server, "TEARDOWN").count
            try await live.stop()
            #expect(await eventually(timeout: .seconds(5)) { Self.requests(server, "TEARDOWN").count > teardowns }, "no TEARDOWN of the backchannel session")

            await controller.close()
            await fixture.tearDown()
            await server.stop()
            web.stop()
        }
    }
}

/// A camera whose stream is H.265, as most 4K Hikvision and Reolink main streams are: `TestPattern` pictures encoded
/// in real time by VideoToolbox's HEVC encoder (Main, no frame reordering, [VPS, SPS, PPS] in the format, an IRAP picture
/// first and then every `keyframeInterval`), with an optional 440 Hz tone in G.711 (PCMU / PCMA). Video PTS are on the
/// 90 kHz clock and audio PTS on the sample clock, both from 0; wall clocks follow real time. `samples()` ends the
/// session it replaces.
final class HEVCCameraSource: MediaSource {
    /// Whether this Mac can encode HEVC (checked once; the tests that need it are skipped, not passed, without it).
    static let encoderAvailable: Bool = (try? AppleVideoEncoder(settings: VideoEncoderSettings(width: 640, height: 360, fps: 25, bitrateKbps: 1_000),
                                                                codec: .hevc)).map { encoder in encoder.invalidate(); return true } ?? false

    let displayName = "H.265 camera"
    let width: Int
    let height: Int
    let fps: Int
    let keyframeInterval: Duration
    let audio: AudioFormat?
    private let session = Mutex<Task<Void, Never>?>(nil)
    private let keyframes = Box(0)

    /// `audio`: PCMU or PCMA (nil: no sound).
    init(width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioFormat?) {
        self.width = width
        self.height = height
        self.fps = fps
        self.keyframeInterval = keyframeInterval
        self.audio = audio
    }

    /// H.265 keyframes produced so far (every session).
    var sentKeyframes: Int { keyframes.value }

    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        await stop()
        let settings = VideoEncoderSettings(width: width, height: height, fps: fps, bitrateKbps: 2_000, level: .auto, keyframeInterval: keyframeInterval)
        let encoder = try AppleVideoEncoder(settings: settings, codec: .hevc)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self, bufferingPolicy: .bufferingNewest(512))
        let (width, height, fps, audio, keyframes) = (width, height, fps, audio, keyframes)
        let task = Task.detached(priority: .userInitiated) {
            do {
                let pattern = TestPattern(width: width, height: height)
                let clock = ContinuousClock()
                let start = clock.now
                let startDate = Date()
                var audioSamples = 0
                var index = 0
                while true {
                    try await clock.sleep(until: start + .seconds(Double(index) / Double(fps)))
                    let picture = try pattern.makeFrame(index: index, pts: MediaTime(value: Int64(index) * 90_000 / Int64(fps), timescale: 90_000))
                    for frame in try await encoder.encode(picture, wallClock: startDate.addingTimeInterval(Double(index) / Double(fps)),
                                                          forceKeyframe: index == 0) {
                        guard frame.format.codec == .hevc, frame.format.parameterSets.count == 3 else {
                            throw MediaCodecError.unsupported("the HEVC encoder produced \(frame.format.codec) with \(frame.format.parameterSets.count) parameter sets")
                        }
                        if frame.isKeyframe { keyframes.update { $0 += 1 } }
                        continuation.yield(.video(frame))
                    }
                    if let audio {
                        // The tone up to the next picture's time.
                        let target = (index + 1) * audio.sampleRate / fps
                        let pcm = (audioSamples..<target).map { Int16(3_000 * sin(2 * Double.pi * 440 * Double($0) / Double(audio.sampleRate))) }
                        if !pcm.isEmpty {
                            let data = audio.codec == .pcma ? G711.encodeALaw(pcm) : G711.encodeMuLaw(pcm)
                            continuation.yield(.audio(EncodedAudioFrame(format: audio, data: data,
                                                                        pts: MediaTime(value: Int64(audioSamples), timescale: Int32(audio.sampleRate)),
                                                                        sampleCount: pcm.count,
                                                                        wallClock: startDate.addingTimeInterval(Double(audioSamples) / Double(audio.sampleRate)))))
                        }
                        audioSamples = target
                    }
                    index += 1
                }
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            encoder.invalidate()
        }
        continuation.onTermination = { _ in task.cancel() }
        session.withLock { $0 = task }
        return stream
    }

    func stop() async {
        let task = session.withLock { current -> Task<Void, Never>? in
            defer { current = nil }
            return current
        }
        task?.cancel()
        await task?.value
    }
}
#endif

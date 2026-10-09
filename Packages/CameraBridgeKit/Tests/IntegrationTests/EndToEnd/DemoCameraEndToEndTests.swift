#if os(macOS)
import BridgeSupport
@testable import CameraAdapters
import Foundation
import HAP
import MediaCore
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

extension EndToEndTests {
    /// Plan W3-2 scenarios 1–4 on the built-in demo camera (1920×1080@30, 2 s GOP, AAC-LC 32 kHz; smaller where the
    /// picture does not matter), driven from outside like a Home hub: pairing and the accessory database, motion
    /// events, live view over SRTP, HKSV recording over HDS, and a video doorbell.
    @Suite struct DemoCamera {
        // MARK: Scenario 1 — pair, read the accessory, motion

        @MainActor @Test(.timeLimit(.minutes(1)))
        func pairsReadsTheAccessoryAndReportsMotion() async throws {
            try await pairReadAndReportMotion()
        }

        /// Review finding (W4): the demo camera turns motion on by itself 10 s after its event channel opens, and a
        /// slow run (TSan, a loaded machine) can take that long to pair. Scenario 1 must not race that timer: here it has
        /// already fired when the controller first reads MotionDetected.
        @MainActor @Test(.timeLimit(.minutes(1)))
        func reportsMotionEvenAfterTheDemoTimerHasFired() async throws {
            let driver = EagerDemoMotionDriver()
            var tuning = EngineTuning.smallDemo
            tuning.driverFactory = { _, _, _ in driver }
            try await pairReadAndReportMotion(tuning: tuning) {
                #expect(await eventually(timeout: .seconds(5)) { driver.motionFired.value }, "the demo timer did not fire")
            }
        }

        /// Scenario 1 on `tuning`; `beforeFirstRead` runs once the controller is paired, before it reads MotionDetected.
        @MainActor
        private func pairReadAndReportMotion(tuning: EngineTuning = .standard, beforeFirstRead: @MainActor () async -> Void = {}) async throws {
            let advertiser = RecordingAdvertiser()
            let fixture = try await EndToEndEngine(tuning: tuning, advertiser: advertiser)
            let engine = fixture.engine
            var camera = EndToEndEngine.demoCamera(name: "Driveway")
            camera.motionSource = .webhook      // no demo timer motion: only the test button below
            try await engine.addCamera(camera, password: nil)
            await engine.start()
            #expect(engine.state == .running)
            let status = try await fixture.waitUntilServing(camera.id)
            let port = try #require(status.hapPort)
            #expect(!status.isPaired)

            // The QR code and the (recorded, never announced) Bonjour record both say "IP camera" (category 17), unpaired.
            let payload = try SetupURIPayload(status.setupURI)
            #expect(payload.category == 17 && payload.supportsIP)
            #expect(payload.setupCode == status.setupCode.filter(\.isNumber))
            #expect(await eventually(timeout: .seconds(5)) { advertiser.txtHistory(port: port).last?["ci"] == "17" })
            let txt = try #require(advertiser.txtHistory(port: port).last)
            #expect(txt["sf"] == "1" && txt["pv"] == "1.1" && txt["s#"] == "1", "TXT \(txt.keys.sorted())")
            #expect(txt["md"] != nil && txt["id"] != nil && txt["c#"] != nil && txt["sh"] != nil && txt["ff"] != nil)
            #expect(advertiser.history.value.first { $0.port == port }?.type == "_hap._tcp")

            let controller = try await fixture.pair(camera.id)
            let database = try await controller.accessories()
            #expect(database.accessories.count == 1)
            let accessory = try #require(database.accessory(aid: 1))
            #expect(accessory.information(.name) == "Driveway")
            #expect(accessory.information(.manufacturer)?.isEmpty == false)
            #expect(accessory.services(.cameraRTPStreamManagement).count == 2)
            for type in [ServiceType.accessoryInformation, .microphone, .cameraRecordingManagement, .cameraOperatingMode, .dataStreamTransportManagement,
                         .motionSensor] {
                #expect(accessory.service(type) != nil, "missing \(type.name)")
            }
            #expect(accessory.service(.doorbell) == nil && accessory.service(.speaker) == nil, "a camera without two-way audio")
            let recording = try #require(accessory.service(.cameraRecordingManagement))
            let motionService = try #require(accessory.service(.motionSensor))
            let dataStream = try #require(accessory.service(.dataStreamTransportManagement))
            #expect(recording.linked.contains(motionService.iid), "MotionSensor linked to CameraRecordingManagement: \(recording.linked)")
            #expect(recording.linked.contains(dataStream.iid), "DataStreamTransportManagement linked: \(recording.linked)")
            let motion = try #require(motionService.characteristic(.motionDetected))
            #expect(Set(motion.permissions).isSuperset(of: ["pr", "ev"]) && motion.format == "bool", "\(motion.permissions) \(String(describing: motion.format))")
            await beforeFirstRead()
            #expect(try await controller.readValue(motion.id).hapBool == false)

            // Paired: the record says so (sf 0) and so does the engine.
            #expect(await eventually(timeout: .seconds(5)) { advertiser.statusFlags(port: port).last == "0" }, "sf: \(advertiser.statusFlags(port: port))")
            #expect(await eventually(timeout: .seconds(5)) { fixture.status(camera.id)?.isPaired == true })

            // The app's test button: motion reaches the subscribed controller as an EVENT.
            try await controller.subscribe([motion.id])
            await engine.triggerTestMotion(cameraID: camera.id)
            let event = try await controller.nextEvent(for: motion.id, timeout: .seconds(2))
            #expect(event.value.hapBool == true)
            #expect(try await controller.readValue(motion.id).hapBool == true)
            #expect(await eventually(timeout: .seconds(5)) { fixture.status(camera.id)?.motionActive == true && fixture.status(camera.id)?.lastEvent == "Motion" })

            await controller.close()
            await fixture.tearDown()
        }

        // MARK: Scenario 2 — live view

        @MainActor @Test(.timeLimit(.minutes(1)))
        func liveViewStreamsVideoAndOpusAudioThenClosesItsSockets() async throws {
            let fixture = try await EndToEndEngine()
            let engine = fixture.engine
            let camera = EndToEndEngine.demoCamera(name: "Garden")
            try await engine.addCamera(camera, password: nil)
            await engine.start()
            let controller = try await fixture.pair(camera.id)
            let ids = try await controller.cameraIDs()
            let stream = try #require(ids.streams.first)
            let supported = try await controller.supportedStreamingConfiguration(stream)
            #expect(supported.video.codecs.first?.resolutions.contains(ControllerTLV.Resolution(1280, 720, 30)) == true)
            #expect(supported.audio.codecs.contains { $0.codec == 3 && $0.sampleRates.contains(2) }, "Opus 24 kHz offered")
            #expect(supported.rtp.cryptoSuites.contains(0), "AES_CM_128_HMAC_SHA1_80 offered")
            #expect(try await controller.streamingStatus(stream) == .available)

            // 1280×720@30 Main 4.0 at 2 Mbit/s, Opus 24 kHz in 20 ms packets, receiver reports every 0.5 s.
            let options = LiveStreamOptions()
            let started = ContinuousClock.now
            let live = try await controller.startLiveStream(stream, options: options)
            let receiver = live.receiver
            let videoFrames = Task {
                var frames: [ReceivedVideoFrame] = []
                for await frame in receiver.videoFrames {
                    frames.append(frame)
                    if frames.count >= 60 { break }
                }
                return frames
            }
            let audioFrames = Task {
                var frames: [ReceivedAudioFrame] = []
                for await frame in receiver.audioFrames {
                    frames.append(frame)
                    if frames.count >= 100 { break }
                }
                return frames
            }

            // A keyframe within 2 s of the start command.
            #expect(await receiver.waitFor(timeout: .seconds(2)) { $0.keyframes >= 1 }, "no keyframe within 2 s")
            let firstKeyframe = try #require(await receiver.firstKeyframeAt)
            #expect(firstKeyframe - started <= .seconds(2), "first keyframe after \(firstKeyframe - started)")

            // The first picture is the camera's latest keyframe; continuous video follows from the camera's next keyframe,
            // at most a GOP (2 s on the demo camera) later.
            #expect(await receiver.waitFor(timeout: .seconds(3)) { $0.videoFrames >= 2 }, "no video after the first keyframe")
            let flowing = try #require(await receiver.frameRecords.dropFirst().first)
            #expect(flowing.receivedAt - firstKeyframe <= .milliseconds(2_300), "video froze \(flowing.receivedAt - firstKeyframe) after the first picture")

            // Then ≥ 5 s of video at ≥ 20 fps.
            try await Task.sleep(until: flowing.receivedAt + .milliseconds(5_300))
            let records = await receiver.frameRecords.filter(\.isComplete)
            let window = records.filter { $0.receivedAt >= flowing.receivedAt && $0.receivedAt <= flowing.receivedAt + .seconds(5) }
            #expect(window.count >= 100, "\(window.count) frames arrived in 5 s")
            if let first = window.first, let last = window.last {
                let span = Double(Int32(bitPattern: last.rtpTimestamp &- first.rtpTimestamp)) / 90_000
                let rate = Double(window.count - 1) / span
                #expect(span >= 4.8 && rate >= 20, "\(window.count) frames over \(span) s of media time: \(rate) fps")
            }
            if let first = records.first, let last = records.last {
                // Media time keeps pace with arrival from the first frame on (receivers anchor playout on it).
                let span = Double(Int32(bitPattern: last.rtpTimestamp &- first.rtpTimestamp)) / 90_000
                let arrival = Double((last.receivedAt - first.receivedAt) / .milliseconds(1)) / 1_000
                #expect(abs(span - arrival) < 0.3, "\(span) s of media time arrived in \(arrival) s")
            }
            let statistics = await receiver.statistics
            #expect(statistics.incompleteVideoFrames == 0 && statistics.sequenceGaps == 0, "\(statistics)")
            #expect(statistics.authenticationFailures == 0 && statistics.unexpectedSSRCPackets == 0 && statistics.malformedPackets == 0, "\(statistics)")
            #expect(statistics.largestVideoDatagram <= Int(options.maxMTU ?? 1378), "datagram of \(statistics.largestVideoDatagram) bytes")
            #expect(statistics.audioFrames >= 200, "\(statistics.audioFrames) Opus packets in ~5.3 s")
            #expect(statistics.otherAudioPackets == 0)
            // RTCP both ways: the accessory's sender reports, our receiver reports (the keepalive).
            #expect(statistics.videoSenderReports >= 2 && statistics.audioSenderReports >= 1, "\(statistics)")
            #expect(statistics.receiverReportsSent >= 10)
            #expect(await eventually(timeout: .seconds(3)) { fixture.status(camera.id)?.liveViewers == 1 })
            #expect(try await controller.streamingStatus(stream) == .inUse)
            // The Home tile's snapshot (/resource) during the view: a JPEG of the requested size.
            let snapshot = try await controller.snapshot(width: 640, height: 360)
            let snapshotSize = try jpegSize(snapshot)
            #expect(snapshotSize.width == 640 && snapshotSize.height == 360, "snapshot \(snapshotSize.width)×\(snapshotSize.height)")

            // The picture decodes (VideoToolbox) at the requested size: the 1080p camera was scaled for this view. The stream
            // opens with a keyframe, and every keyframe carries SPS and PPS (a receiver can start at any of them).
            let received = await videoFrames.value
            #expect(received.first?.isKeyframe == true)
            #expect(received.filter(\.isKeyframe).allSatisfy { $0.sps != nil && $0.pps != nil }, "a keyframe without SPS/PPS")
            let sizes = try await decodeLiveFrames(received)
            #expect(sizes.count >= 30, "\(sizes.count) pictures decoded")
            #expect(sizes.allSatisfy { $0.width == 1280 && $0.height == 720 }, "decoded sizes \(Set(sizes.map { "\($0.width)×\($0.height)" }))")
            // Opus per HAP: payload type and SSRC as negotiated, RTP clock = the 24 kHz sample rate (480 ticks a packet).
            let audio = await audioFrames.value
            #expect(audio.count >= 100)
            #expect(audio.allSatisfy { $0.payloadType == 110 && $0.ssrc == live.endpoints.audioSSRC && !$0.payload.isEmpty })
            let steps = zip(audio, audio.dropFirst()).filter { $1.sequenceNumber == $0.sequenceNumber &+ 1 }
                .map { Int32(bitPattern: $1.rtpTimestamp &- $0.rtpTimestamp) }
            #expect(!steps.isEmpty && steps.allSatisfy { $0 == 480 }, "Opus timestamp steps \(Set(steps))")

            // End: SR + BYE on both streams, no more media, the accessory's sockets closed, the stream available again.
            try await live.stop(keepReceiver: true)
            #expect(await receiver.waitFor(timeout: .seconds(3)) { $0.byes >= 2 }, "BYE on video and audio")
            let accessory = try #require(live.endpoints.accessory)
            #expect(await eventually(timeout: .seconds(5)) { udpPortIsFree(accessory.videoPort) && udpPortIsFree(accessory.audioPort) },
                    "the accessory still holds UDP \(accessory.videoPort)/\(accessory.audioPort)")
            let packets = await receiver.statistics.videoPackets + receiver.statistics.audioPackets
            try await Task.sleep(for: .milliseconds(500))
            #expect(await receiver.statistics.videoPackets + receiver.statistics.audioPackets == packets, "media after the end command")
            #expect(await eventually(timeout: .seconds(5)) { fixture.status(camera.id)?.liveViewers == 0 })
            #expect(try await controller.streamingStatus(stream) == .available)
            await receiver.stop()
            await controller.close()
            await fixture.tearDown()
        }

        /// The receiver reports are what keeps a live view alive: without them the accessory ends the session after its
        /// controller timeout (shortened from 30 s to 3 s here) and frees the stream service.
        @MainActor @Test(.timeLimit(.minutes(1)))
        func receiverReportsKeepALiveViewAndTheirAbsenceEndsIt() async throws {
            var tuning = EngineTuning.smallDemo
            tuning.liveControllerTimeout = .seconds(3)
            let fixture = try await EndToEndEngine(tuning: tuning)
            let camera = EndToEndEngine.demoCamera(name: "Patio")
            try await fixture.engine.addCamera(camera, password: nil)
            await fixture.engine.start()
            let controller = try await fixture.pair(camera.id)
            let ids = try await controller.cameraIDs()
            #expect(ids.streams.count == 2)

            let started = ContinuousClock.now
            let kept = try await controller.startLiveStream(ids.streams[0])
            let silent = try await controller.startLiveStream(ids.streams[1], options: LiveStreamOptions(keepaliveInterval: nil))
            #expect(await kept.receiver.waitFor(timeout: .seconds(3)) { $0.keyframes >= 1 })
            #expect(await silent.receiver.waitFor(timeout: .seconds(3)) { $0.keyframes >= 1 })

            // No RTCP from the controller: SR + BYE after the timeout, then nothing; the service is available again.
            #expect(await silent.receiver.waitFor(timeout: .seconds(8)) { $0.byes >= 1 }, "the silent session was not ended")
            #expect(ContinuousClock.now - started >= .seconds(3), "ended before the controller timeout")
            #expect(await eventually(timeout: .seconds(5)) { (try? await controller.streamingStatus(ids.streams[1])) == .available })
            let silentPackets = await silent.receiver.statistics.videoPackets
            try await Task.sleep(for: .milliseconds(500))
            #expect(await silent.receiver.statistics.videoPackets == silentPackets)

            // Receiver reports every 0.5 s: the other session runs on, well past the timeout.
            try await Task.sleep(until: started + .seconds(7))
            let keptStatistics = await kept.receiver.statistics
            #expect(keptStatistics.byes == 0)
            #expect(await kept.receiver.lastMediaAt.map { ContinuousClock.now - $0 < .milliseconds(500) } == true, "the kept session stalled")
            #expect(try await controller.streamingStatus(ids.streams[0]) == .inUse)
            #expect(fixture.status(camera.id)?.liveViewers == 1)

            try await kept.stop()
            await silent.receiver.stop()
            await controller.close()
            await fixture.tearDown()
        }

        // MARK: Scenario 3 — HKSV recording

        @MainActor @Test(.timeLimit(.minutes(3)))
        func hksvRecordingDeliversIDRStartedFragmentsWithAndWithoutAudio() async throws {
            let fixture = try await EndToEndEngine()
            let engine = fixture.engine
            let camera = EndToEndEngine.demoCamera(name: "Backyard")
            try await engine.addCamera(camera, password: nil)
            await engine.start()
            _ = try await fixture.waitUntilServing(camera.id)
            let online = ContinuousClock.now
            let controller = try await fixture.pair(camera.id)
            let ids = try await controller.cameraIDs()
            let recordingIDs = try #require(ids.recording)

            // What the accessory offers: fragmented MP4 with a 4 s prebuffer and 4 s fragments, H.264 1080p/720p, AAC-LC 32 kHz.
            let supported = try await controller.supportedRecordingConfiguration(recordingIDs)
            #expect(supported.camera.prebufferLengthMs == 4_000)
            #expect(supported.camera.containers.first?.fragmentLengthMs == 4_000)
            #expect(supported.camera.eventTriggers & 0x01 != 0, "motion trigger")
            let codec = try #require(supported.video.codecs.first)
            #expect(codec.resolutions.contains(ControllerTLV.Resolution(1920, 1080, 30)) && codec.resolutions.contains(ControllerTLV.Resolution(1280, 720, 30)))
            #expect(codec.profiles.contains(1) && codec.levels.contains(2), "Main / 4.0 offered")
            #expect(supported.audio.codecs.first?.codec == 0 && supported.audio.codecs.first?.sampleRates.contains(3) == true, "AAC-LC 32 kHz offered")

            // A hub's selection (integration brief §5.1): 1920×1080 Main 4.0, 2000 kbit/s, IDR every 4 s, AAC-LC 32 kHz.
            let selection = try ControllerTLV.SelectedCameraRecordingConfiguration.preferred(camera: supported.camera, video: supported.video,
                                                                                            audio: supported.audio)
            #expect(selection.resolution == ControllerTLV.Resolution(1920, 1080, 30) && selection.videoProfile == 1 && selection.videoLevel == 2)
            #expect(selection.videoBitrateKbps == 2_000 && selection.container.fragmentLengthMs == 4_000 && selection.iFrameIntervalMs == 4_000)
            try await controller.selectRecordingConfiguration(recordingIDs, selection)
            #expect(try ControllerTLV.SelectedCameraRecordingConfiguration.decode(try await controller.readData(recordingIDs.selectedConfiguration)) == selection)
            try await controller.enableRecording(ids, audio: true)
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.recordingEnabled == true })

            // Motion → the hub opens a recording; the 4 s prebuffer has filled by then.
            try await Task.sleep(until: online + .seconds(5))
            let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
            let opened = ContinuousClock.now
            #expect(try await dataStream.openRecording(streamID: 1).isAccepted)
            let capture = try await dataStream.receiveRecording(streamID: 1, maximumFragments: 3, eventTimeout: .seconds(15))
            #expect(capture.fragments.count >= 3 && capture.closeReason == nil && !capture.endOfStream,
                    "\(capture.fragments.count) fragments, close \(String(describing: capture.closeReason))")
            let (initialization, fragments) = try checkRecording(capture, audio: true)
            let video = try #require(initialization.video)
            #expect(video.width == 1920 && video.height == 1080, "recorded \(video.width)×\(video.height)")
            #expect(video.avcProfile == 77 && (video.avcLevel ?? 255) <= 40,
                    "profile \(String(describing: video.avcProfile)) level \(String(describing: video.avcLevel))")
            // The prebuffer comes first and at once (paced, not real time).
            #expect(capture.arrivalTimes.count >= 2 && capture.arrivalTimes[1] - opened < .seconds(2), "first fragment after \(capture.arrivalTimes.dropFirst().first.map { $0 - opened } ?? .zero)")
            // Review finding (W4): and it spans the 4 s prebuffer, less at most one 2 s GOP where the replay starts.
            let immediate = zip(capture.arrivalTimes.dropFirst(), fragments).filter { $0.0 - opened < .milliseconds(1_200) }
            let prebuffered = Double(immediate.compactMap { $0.1.run(track: video.id)?.totalDuration }.reduce(0, +)) / 90_000
            #expect(prebuffered >= 2.0, "\(prebuffered) s of video arrived within 1.2 s of the open")
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.recordingNow == true })

            // AVFoundation decodes init + fragments as one file: every frame, audio covering the video.
            let videoSeconds = Double(fragments.compactMap { $0.run(track: video.id)?.totalDuration }.reduce(0, +)) / 90_000
            let videoSamples = fragments.compactMap { $0.run(track: video.id)?.sampleCount }.reduce(0, +)
            let file = fixture.directory.appending(path: "recording-with-audio.mp4")
            try capture.mp4.write(to: file)
            let report = try await decodeWithAVFoundation(file)
            #expect(report.videoTrackCount == 1 && report.audioTrackCount == 1)
            #expect(report.videoReaderCompleted && report.audioReaderCompleted)
            #expect(report.decodedVideoFrames == videoSamples, "decoded \(report.decodedVideoFrames) of \(videoSamples) frames")
            #expect(abs(report.duration - videoSeconds) < 0.5, "duration \(report.duration) s for \(videoSeconds) s of video")
            let audioSeconds = Double(report.decodedAudioSamples) / 32_000
            #expect(abs(audioSeconds - videoSeconds) < 0.5, "\(audioSeconds) s of audio for \(videoSeconds) s of video")
            try await dataStream.closeRecording(streamID: 1)
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.recordingNow == false })

            // RecordingAudioActive off: the next recording has no audio track at all.
            let audioActive = try #require(recordingIDs.recordingAudioActive)
            try await controller.writeValue(audioActive, .int(0), timedWriteTTL: .seconds(5))
            #expect(try await dataStream.openRecording(streamID: 2).isAccepted)
            let silentCapture = try await dataStream.receiveRecording(streamID: 2, maximumFragments: 2, eventTimeout: .seconds(15))
            #expect(silentCapture.fragments.count >= 2)
            let silent = try checkRecording(silentCapture, audio: false)
            let silentFile = fixture.directory.appending(path: "recording-without-audio.mp4")
            try silentCapture.mp4.write(to: silentFile)
            let silentReport = try await decodeWithAVFoundation(silentFile)
            #expect(silentReport.audioTrackCount == 0 && silentReport.videoReaderCompleted)
            #expect(silentReport.decodedVideoFrames == silent.fragments.compactMap { $0.run(track: video.id)?.sampleCount }.reduce(0, +))
            try await dataStream.closeRecording(streamID: 2)
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.recordingNow == false })

            await dataStream.close()
            await controller.close()
            await fixture.tearDown()
        }

        // MARK: Scenario 4 — video doorbell

        @MainActor @Test(.timeLimit(.minutes(1)))
        func doorbellRingsFromTheCameraButtonAndTheWebhook() async throws {
            let button = DoorbellButtonDriver()
            var tuning = EngineTuning.smallDemo
            tuning.driverFactory = { _, _, _ in button }
            let fixture = try await EndToEndEngine(tuning: tuning) { $0.webhookEnabled = true }
            let engine = fixture.engine
            var camera = EndToEndEngine.demoCamera(name: "Front Door", kind: .doorbell)
            camera.motionHoldSeconds = 1
            try await engine.addCamera(camera, password: nil)
            await engine.start()
            let status = try await fixture.waitUntilServing(camera.id)
            #expect(try SetupURIPayload(status.setupURI).category == 18, "video doorbell category")

            let controller = try await fixture.pair(camera.id)
            let accessory = try #require(try await controller.accessories().accessory(aid: 1))
            let doorbell = try #require(accessory.service(.doorbell))
            #expect(doorbell.isPrimary)
            let switchEvent = try #require(doorbell.characteristic(.programmableSwitchEvent))
            #expect(Set(switchEvent.permissions) == ["pr", "ev"] && switchEvent.format == "uint8", "\(switchEvent.permissions)")
            let ids = try await controller.cameraIDs()
            let ring = try #require(ids.programmableSwitchEvent)
            let motion = try #require(ids.motionDetected)
            let supported = try await controller.supportedRecordingConfiguration(try #require(ids.recording))
            #expect(supported.camera.eventTriggers == 0x03, "motion + doorbell triggers, got \(supported.camera.eventTriggers)")
            try await controller.subscribe([ring, motion])

            // The doorbell's own button (camera event channel) → ringDoorbell: ProgrammableSwitchEvent 0 and a motion pulse.
            let pressed = ContinuousClock.now
            button.press()
            #expect(try await controller.nextEvent(for: ring, timeout: .seconds(2)).value == .int(0))
            #expect(try await controller.nextEvent(for: motion, timeout: .seconds(2)).value.hapBool == true)
            #expect(await eventually(timeout: .seconds(3)) { fixture.status(camera.id)?.lastEvent == "Doorbell ring" })
            // A second press within 3 s is the same visitor.
            button.press()
            await #expect(throws: (any Error).self) { _ = try await controller.nextEvent(for: ring, timeout: .milliseconds(800)) }
            // The motion pulse ends after the camera's hold (1 s here).
            #expect(try await controller.nextEvent(for: motion, timeout: .seconds(4)).value.hapBool == false)

            // A doorbell without an event channel of its own rings through the webhook.
            try await Task.sleep(until: pressed + .milliseconds(3_300))
            let port = try #require(await engine.webhook?.boundPort)
            var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/cameras/\(camera.id.uuidString)/doorbell")))
            request.httpMethod = "POST"
            request.setValue("Bearer \(engine.settings.webhookToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 204)
            #expect(try await controller.nextEvent(for: ring, timeout: .seconds(2)).value == .int(0))
            #expect(try await controller.nextEvent(for: motion, timeout: .seconds(2)).value.hapBool == true)

            await controller.close()
            await fixture.tearDown()
        }
    }
}

/// The built-in demo driver with its motion timer firing as soon as the event channel opens (the default waits 10 s)
/// and holding motion for a minute; `motionFired` turns true once the timer has turned motion on.
final class EagerDemoMotionDriver: CameraDriver {
    let vendor: CameraVendor = .demo
    let motionFired = Box(false)
    private let demo = DemoCameraDriver(firstMotionAfter: .zero, period: .seconds(120), duration: .seconds(60))

    func probe() async throws -> CameraProbeResult { try await demo.probe() }

    func makeEventSource() -> (any CameraEventSource)? {
        let fired = motionFired
        return demo.makeEventSource().map { source in
            ObservedEventSource(source) { event in
                if event == .motion(true) { fired.update { $0 = true } }
            }
        }
    }

    func snapshot() async throws -> Data? { try await demo.snapshot() }
    func makeTalkbackSink() -> (any TalkbackSink)? { demo.makeTalkbackSink() }
}

/// Passes another source's events through, showing each to `observe` first.
final class ObservedEventSource: CameraEventSource {
    private let source: any CameraEventSource
    private let observe: @Sendable (CameraEvent) -> Void

    init(_ source: any CameraEventSource, observe: @escaping @Sendable (CameraEvent) -> Void) {
        self.source = source
        self.observe = observe
    }

    func events() -> AsyncStream<CameraEvent> {
        let upstream = source.events()
        let observe = observe
        let (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self)
        let relay = Task {
            for await event in upstream {
                observe(event)
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }

    func stop() async { await source.stop() }
}

/// A video doorbell's driver whose event channel reports the presses a test makes (`press()`); otherwise a demo camera.
final class DoorbellButtonDriver: CameraDriver {
    let vendor: CameraVendor = .demo
    private let source = ButtonEventSource()

    func press() { source.press() }

    func probe() async throws -> CameraProbeResult {
        CameraProbeResult(vendor: .demo, manufacturer: "CameraBridge", model: "Demo Doorbell", serialNumber: "DEMO-BELL", firmware: "1.0",
                          capabilities: CameraCapabilities(events: [.motion, .doorbell], isDoorbell: true))
    }

    func makeEventSource() -> (any CameraEventSource)? { source }
    func snapshot() async throws -> Data? { nil }
    func makeTalkbackSink() -> (any TalkbackSink)? { nil }
}

/// Connected at once; `press()` emits `.doorbellPressed` on every open stream.
final class ButtonEventSource: CameraEventSource {
    private let continuations = Mutex<[AsyncStream<CameraEvent>.Continuation]>([])

    func events() -> AsyncStream<CameraEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self)
        continuation.yield(.eventChannel(connected: true))
        continuations.withLock { $0.append(continuation) }
        return stream
    }

    func press() {
        for continuation in continuations.withLock({ $0 }) { continuation.yield(.doorbellPressed) }
    }

    func stop() async {
        let finished = continuations.withLock { list in
            defer { list.removeAll() }
            return list
        }
        for continuation in finished { continuation.finish() }
    }
}
#endif

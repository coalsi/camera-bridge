#if os(macOS)
import BridgeSupport
import Foundation
import HAP
import RTP
import Testing
import TestSupport
@testable import BridgeEngine

extension EndToEndTests {
    /// Plan W3-2 scenario 7 (opt-in: `CB_NODE_ORACLE=1`, Node 24 and `npm ci` in `Interop/node`): hap-controller
    /// 0.10.2 — an independent HAP implementation — pairs with an engine camera (pair-setup with both methods,
    /// pair-verify, list pairings, `/accessories`, every readable characteristic, MotionDetected events, unsubscribe,
    /// remove pairing, refused pair-verify afterwards) through `Interop/node/pair-oracle.mjs`. The engine advertises
    /// through a recording advertiser only (loopback, never Bonjour); the oracle connects by address and port.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["CB_NODE_ORACLE"] == "1", "set CB_NODE_ORACLE=1 (Node 24, `npm ci` in Interop/node)"))
    struct NodeOracle {
        @MainActor @Test(.timeLimit(.minutes(3)))
        func hapControllerPairsReadsReceivesMotionAndUnpairs() async throws {
            let node = try #require(ExternalTool.node, "node not found; set CB_NODE")
            let interop = ExternalTool.repositoryRoot.appending(path: "Interop/node", directoryHint: .isDirectory)
            let script = interop.appending(path: "pair-oracle.mjs")
            try #require(FileManager.default.fileExists(atPath: script.path(percentEncoded: false)), "no \(script.path(percentEncoded: false))")
            try #require(FileManager.default.fileExists(atPath: interop.appending(path: "node_modules/hap-controller").path(percentEncoded: false)),
                         "run `npm ci` in Interop/node")

            let advertiser = RecordingAdvertiser()
            let fixture = try await EndToEndEngine(advertiser: advertiser)
            let engine = fixture.engine
            var camera = EndToEndEngine.demoCamera(name: "Oracle Camera")
            camera.motionHoldSeconds = 1        // each test pulse ends a second later: one event up, one down
            camera.motionSource = .webhook      // no demo timer motion: only the pulses below
            try await engine.addCamera(camera, password: nil)
            await engine.start()
            let status = try await fixture.waitUntilServing(camera.id)
            let port = try #require(status.hapPort)
            #expect(await eventually(timeout: .seconds(5)) { advertiser.statusFlags(port: port) == ["1"] })

            // Motion pulses every 2 s while the oracle watches MotionDetected.
            let pulses = Task { @MainActor in
                while !Task.isCancelled {
                    await engine.triggerTestMotion(cameraID: camera.id)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            defer { pulses.cancel() }

            for method in ["0", "1"] {
                let result = try await RunningTool.run(node, [script.path(percentEncoded: false), "127.0.0.1", String(port), status.setupCode,
                                                              "--seconds", "6", "--min-events", "2", "--method", method],
                                                       currentDirectory: interop, timeout: .seconds(90))
                #expect(result.status == 0 && !result.timedOut, "pair-oracle --method \(method) exited \(result.status)\n\(result.output)\n\(result.stderr)")
                let summary = try #require(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any], "no JSON summary: \(result.stderr)")
                #expect(summary["ok"] as? Bool == true, "failed step \(summary["failedStep"] ?? "?"): \(summary["error"] ?? "?")")
                let steps = (summary["steps"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                #expect(steps == ["pairSetup", "pairVerify", "listPairings", "getAccessories", "readCharacteristics", "subscribeMotion", "events",
                                  "unsubscribeMotion", "removePairing", "verifyRemoved"], "steps \(steps)")
                let events = summary["events"] as? [[String: Any]] ?? []
                #expect(events.count >= 2 && events.contains { $0["value"] as? Bool == true }, "events \(events)")
                let reads = summary["reads"] as? [String: Any]
                #expect(reads?["failed"] as? Int == 0, "reads \(String(describing: reads))")
                #expect((summary["accessories"] as? [String: Any])?["count"] as? Int == 1)
                #expect((summary["cleanup"] as? [String: Any])?["needed"] as? Bool == false)
                // The oracle never prints the setup code.
                #expect(!result.output.contains(status.setupCode) && !result.stderr.contains(status.setupCode))

                // Unpaired again: the camera is ready for the next controller.
                #expect(await eventually(timeout: .seconds(5)) { fixture.status(camera.id)?.isPaired == false })
            }
            // The record followed: unpaired → paired → … → unpaired. (TXT updates are debounced by 1 s, so the second run's
            // pair-setup, under a second after the first run's removal, may fold into the paired state already announced.)
            #expect(await eventually(timeout: .seconds(5)) {
                let flags = advertiser.statusFlags(port: port)
                return flags.count >= 3 && flags.prefix(2) == ["1", "0"] && flags.last == "1"
            }, "sf history \(advertiser.statusFlags(port: port))")

            pulses.cancel()
            await fixture.tearDown()
        }
    }

    /// Plan W3-2 scenario 8 (opt-in: `CB_FFMPEG_ORACLE=1`, Homebrew ffmpeg/ffprobe or `CB_FFMPEG`/`CB_FFPROBE`): ffprobe
    /// and ffmpeg — independent demuxers/decoders — read an HKSV recording made by the engine, and ffmpeg receives a
    /// live view as a controller would (SRTP from an SDP with `a=crypto`), decoding video and Opus audio.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["CB_FFMPEG_ORACLE"] == "1", "set CB_FFMPEG_ORACLE=1 (Homebrew ffmpeg/ffprobe)"))
    struct FFmpegOracle {
        @MainActor @Test(.timeLimit(.minutes(3)))
        func ffprobeAndFFmpegReadTheRecording() async throws {
            let ffprobe = try #require(ExternalTool.ffprobe, "ffprobe not found; set CB_FFPROBE")
            let ffmpeg = try #require(ExternalTool.ffmpeg, "ffmpeg not found; set CB_FFMPEG")
            let fixture = try await EndToEndEngine()
            let engine = fixture.engine
            let camera = EndToEndEngine.demoCamera(name: "Probe Camera")
            try await engine.addCamera(camera, password: nil)
            await engine.start()
            _ = try await fixture.waitUntilServing(camera.id)
            let online = ContinuousClock.now
            let controller = try await fixture.pair(camera.id)
            let ids = try await controller.cameraIDs()
            let recordingIDs = try #require(ids.recording)
            let supported = try await controller.supportedRecordingConfiguration(recordingIDs)
            try await controller.selectRecordingConfiguration(recordingIDs, try .preferred(camera: supported.camera, video: supported.video,
                                                                                          audio: supported.audio))
            try await controller.enableRecording(ids, audio: true)
            try await Task.sleep(until: online + .seconds(5))
            let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
            #expect(try await dataStream.openRecording(streamID: 1).isAccepted)
            let capture = try await dataStream.receiveRecording(streamID: 1, maximumFragments: 3, eventTimeout: .seconds(15))
            try await dataStream.closeRecording(streamID: 1)
            let (initialization, fragments) = try checkRecording(capture, audio: true)
            let video = try #require(initialization.video)
            let videoSamples = fragments.compactMap { $0.run(track: video.id)?.sampleCount }.reduce(0, +)
            let file = fixture.directory.appending(path: "hksv.mp4")
            try capture.mp4.write(to: file)
            let path = file.path(percentEncoded: false)

            // ffprobe: the streams a hub expects.
            let streams = try await RunningTool.run(ffprobe, ["-v", "error", "-show_entries",
                                                              "stream=codec_name,codec_type,profile,level,width,height,sample_rate,channels,codec_tag_string",
                                                              "-of", "json", path], timeout: .seconds(30))
            #expect(streams.status == 0 && streams.stderr.isEmpty, "ffprobe: \(streams.stderr)")
            let list = (try JSONSerialization.jsonObject(with: streams.stdout) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
            let videoStream = try #require(list.first { $0["codec_type"] as? String == "video" }, "\(list)")
            let audioStream = try #require(list.first { $0["codec_type"] as? String == "audio" }, "\(list)")
            #expect(videoStream["codec_name"] as? String == "h264" && videoStream["codec_tag_string"] as? String == "avc1")
            #expect(videoStream["profile"] as? String == "Main" && (videoStream["level"] as? Int ?? 99) <= 40, "\(videoStream)")
            #expect(videoStream["width"] as? Int == 1920 && videoStream["height"] as? Int == 1080)
            #expect(audioStream["codec_name"] as? String == "aac" && audioStream["profile"] as? String == "LC", "\(audioStream)")
            #expect(audioStream["sample_rate"] as? String == "32000" && audioStream["channels"] as? Int == 1, "\(audioStream)")

            // ffprobe: every video sample is a packet, and its demuxer's keyframes (from the trun sample flags, read its own
            // way) are exactly the IDR samples of the bitstream: the first of every fragment, any later IDR, nothing else.
            let packets = try await RunningTool.run(ffprobe, ["-v", "error", "-select_streams", "v", "-show_entries", "packet=flags", "-of", "csv=p=0", path],
                                                    timeout: .seconds(30))
            #expect(packets.status == 0 && packets.stderr.isEmpty, "ffprobe: \(packets.stderr)")
            let flags = packets.output.split(whereSeparator: \.isNewline).map(String.init)
            let expectedKeyframes = try ExpectedKeyframes(fragments: fragments, video: video)
            #expect(expectedKeyframes.keyframes.count == videoSamples && expectedKeyframes.fragmentStarts.count == fragments.count)
            let mismatches = keyframeMismatches(ffprobeFlags: flags, expected: expectedKeyframes)
            #expect(mismatches.isEmpty, "\(mismatches.count) keyframe mismatches:\n\(mismatches.prefix(12).joined(separator: "\n"))")

            // ffmpeg decodes all of it (video and audio) without a single error.
            let decode = try await RunningTool.run(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-i", path, "-f", "null", "-"],
                                                   timeout: .seconds(60))
            #expect(decode.status == 0 && decode.stderr.isEmpty, "ffmpeg decode: \(decode.stderr)")

            await dataStream.close()
            await controller.close()
            await fixture.tearDown()
        }

        @MainActor @Test(.timeLimit(.minutes(1)))
        func ffmpegDecodesTheLiveViewFromAnSDP() async throws {
            let ffmpeg = try #require(ExternalTool.ffmpeg, "ffmpeg not found; set CB_FFMPEG")
            let fixture = try await EndToEndEngine()
            let engine = fixture.engine
            let camera = EndToEndEngine.demoCamera(name: "Live Camera")
            try await engine.addCamera(camera, password: nil)
            await engine.start()
            let controller = try await fixture.pair(camera.id)
            let ids = try await controller.cameraIDs()
            let stream = try #require(ids.streams.first)

            // ffmpeg is the controller's media endpoint: it binds the ports the SetupEndpoints request names.
            let videoPort = try freeUDPPortPair()
            var audioPort = try freeUDPPortPair()
            while audioPort == videoPort { audioPort = try freeUDPPortPair() }
            let videoKeys = ControllerTLV.SRTPKeys.random(), audioKeys = ControllerTLV.SRTPKeys.random()
            let sdp = fixture.directory.appending(path: "live.sdp")
            try Data("""
                v=0
                o=- 0 0 IN IP4 127.0.0.1
                s=CameraBridge live view
                c=IN IP4 127.0.0.1
                t=0 0
                m=video \(videoPort) RTP/SAVP 99
                a=rtpmap:99 H264/90000
                a=fmtp:99 packetization-mode=1
                a=rtcp-mux
                a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\((videoKeys.masterKey + videoKeys.masterSalt).base64EncodedString())
                m=audio \(audioPort) RTP/SAVP 110
                a=rtpmap:110 opus/24000/2
                a=rtcp-mux
                a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\((audioKeys.masterKey + audioKeys.masterSalt).base64EncodedString())

                """.utf8).write(to: sdp)
            let decoder = try RunningTool.start(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "warning", "-xerror",
                                                         "-protocol_whitelist", "file,udp,rtp,srtp,crypto", "-analyzeduration", "2000000",
                                                         "-i", sdp.path(percentEncoded: false), "-t", "6", "-map", "0:v", "-map", "0:a", "-f", "framecrc", "-"])
            defer { if decoder.process.isRunning { decoder.process.terminate() } }
            #expect(await eventually(timeout: .seconds(10)) { !udpPortIsFree(videoPort) && !udpPortIsFree(audioPort) }, "ffmpeg did not bind its ports")

            let sessionID = UUID()
            let endpoints = try await controller.setupEndpoints(stream, ControllerTLV.SetupEndpointsRequest(
                sessionID: sessionID, controller: ControllerTLV.Address(isIPv6: false, ip: "127.0.0.1", videoPort: videoPort, audioPort: audioPort),
                video: videoKeys, audio: audioKeys))
            #expect(endpoints.isSuccess && endpoints.video == videoKeys && endpoints.audio == audioKeys)
            let video = ControllerTLV.SelectedVideo(resolution: ControllerTLV.Resolution(1280, 720, 30), ssrc: UInt32.random(in: 1...UInt32.max))
            let audio = ControllerTLV.SelectedAudio(ssrc: UInt32.random(in: 1...UInt32.max))
            try await controller.selectStream(stream, ControllerTLV.SelectedRTPStreamConfiguration(sessionID: sessionID, command: .start, video: video,
                                                                                                   audio: audio))

            let result = await decoder.finish(timeout: .seconds(25))
            try await controller.selectStream(stream, ControllerTLV.SelectedRTPStreamConfiguration(sessionID: sessionID, command: .end))
            let lines = result.output.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
            let videoFrames = lines.filter { $0.hasPrefix("0,") }.count
            let audioFrames = lines.filter { $0.hasPrefix("1,") }.count
            #expect(!result.timedOut && result.status == 0, "ffmpeg exit \(result.status): \(result.stderr)")
            #expect(videoFrames >= 100, "decoded \(videoFrames) video frames in 6 s; \(result.stderr)")
            #expect(audioFrames >= 150, "decoded \(audioFrames) Opus frames in 6 s; \(result.stderr)")
            #expect(!result.stderr.contains("HMAC") && !result.stderr.contains("SRTP"), "ffmpeg rejected packets: \(result.stderr)")

            await controller.close()
            await fixture.tearDown()
        }
    }
}
#endif

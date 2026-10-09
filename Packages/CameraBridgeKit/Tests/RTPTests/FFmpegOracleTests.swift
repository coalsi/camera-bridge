import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import RTP

/// Independent oracle (opt-in: `CB_FFMPEG_ORACLE=1 swift test --filter FFmpegOracleTests`, needs an `ffmpeg` binary —
/// `CB_FFMPEG`, else Homebrew / system paths). ffmpeg encodes a test pattern to H.264 (Annex B with AUDs), which is
/// fed through `LiveStreamSession` over loopback; a second ffmpeg reads an SDP with
/// `a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:<key‖salt>` and decodes 3 s of our SRTP output to a null muxer.
/// Passes when ffmpeg exits 0 with `-xerror` (any decode error is fatal) after decoding at least 80 frames, without
/// logging an SRTP authentication failure.
@Suite(.timeLimit(.minutes(1)), .loopback, .enabled(if: ProcessInfo.processInfo.environment["CB_FFMPEG_ORACLE"] == "1", "set CB_FFMPEG_ORACLE=1 to run"))
struct FFmpegOracleTests {
    static var ffmpeg: URL? {
        let candidates = [ProcessInfo.processInfo.environment["CB_FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    @Test func ffmpegDecodesOurSRTPVideo() async throws {
        let ffmpeg = try #require(Self.ffmpeg, "ffmpeg not found; set CB_FFMPEG")
        let directory = try TemporaryDirectory(prefix: "cb-ffmpeg-oracle")
        defer { directory.remove() }

        // 1. Source: 5 s of 640×360@30 H.264 with access unit delimiters, split into access units.
        let elementary = directory.file("source.h264")
        let encoded = try await Self.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                                                  "-t", "5", "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-g", "30", "-bf", "0",
                                                  "-b:v", "1M", "-bsf:v", "h264_metadata=aud=insert", "-f", "h264", elementary.path], timeout: .seconds(30))
        #expect(encoded.status == 0, "encoder: \(encoded.stderr)")
        let frames = try Self.accessUnits(Data(contentsOf: elementary))
        #expect(frames.count >= 140 && frames.first?.isKeyframe == true)

        // 2. Receiver: ffmpeg bound to 127.0.0.1 on a free even/odd port pair (it may bind RTP+1 for RTCP).
        let port = try Self.freePortPair()
        let key = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        let salt = Data((0..<14).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 1) })
        let sdp = directory.file("stream.sdp")
        try Data("""
            v=0
            o=- 0 0 IN IP4 127.0.0.1
            s=CameraBridge oracle
            c=IN IP4 127.0.0.1
            t=0 0
            m=video \(port) RTP/SAVP 99
            a=rtpmap:99 H264/90000
            a=fmtp:99 packetization-mode=1
            a=rtcp-mux
            a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\((key + salt).base64EncodedString())

            """.utf8).write(to: sdp)
        let decoder = try Self.start(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "warning", "-xerror", "-protocol_whitelist", "file,udp,rtp,srtp,crypto",
                                              "-localaddr", "127.0.0.1", "-analyzeduration", "1000000", "-i", sdp.path, "-t", "3", "-f", "framecrc", "-"])
        defer { if decoder.process.isRunning { decoder.process.terminate() } }
        #expect(await eventually(timeout: .seconds(10)) { Self.isBound(port) }, "ffmpeg did not bind \(port)")

        // 3. Sender: our session, paced in real time, until ffmpeg exits.
        let videoSocket = try UDPSocket.bind(host: "127.0.0.1")
        let session = LiveStreamSession(controller: SocketAddress(host: "127.0.0.1", port: 0), videoPort: port, audioPort: port + 1, videoSocket: videoSocket,
                                        audioSocket: nil, video: LiveVideoParameters(payloadType: 99, ssrc: 0x5EED_CAFE, srtpKey: key, srtpSalt: salt),
                                        audio: nil)
        await session.start(video: Frames.stream(frames, interval: .milliseconds(33), finish: false), audio: nil)
        let exited = await eventually(timeout: .seconds(20)) { !decoder.process.isRunning }
        await session.stop()
        if !exited { decoder.process.terminate() }
        decoder.process.waitUntilExit()
        let stdout = await decoder.stdout.value
        let stderr = String(decoding: await decoder.stderr.value, as: UTF8.self)
        let decodedFrames = String(decoding: stdout, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }.count
        #expect(exited, "ffmpeg did not finish: \(stderr)")
        #expect(decoder.process.terminationStatus == 0, "ffmpeg exit \(decoder.process.terminationStatus): \(stderr)")
        #expect(decodedFrames >= 80, "decoded \(decodedFrames) frames; \(stderr)")
        #expect(!stderr.contains("HMAC mismatch") && !stderr.contains("SRTP"), "ffmpeg rejected packets: \(stderr)")
    }

    // MARK: Helpers

    /// Groups Annex B NAL units into access units at each AUD; SPS/PPS go to the format, AUDs are dropped.
    static func accessUnits(_ annexB: Data) throws -> [EncodedVideoFrame] {
        var frames: [EncodedVideoFrame] = []
        var sps = Data(), pps = Data()
        var current: [Data] = []
        func flush() {
            guard !current.isEmpty else { return }
            let keyframe = current.contains { NALUnits.h264Type($0) == 5 }
            let format = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [sps, pps])
            frames.append(EncodedVideoFrame(format: format, nalUnits: current, isKeyframe: keyframe,
                                            pts: MediaTime(value: Int64(frames.count) * 3_000, timescale: 90_000), wallClock: Date()))
            current = []
        }
        for nal in NALUnits.splitAnnexB(annexB) {
            switch NALUnits.h264Type(nal) {
            case 9: flush()
            case 7: sps = nal
            case 8: pps = nal
            default: current.append(nal)
            }
        }
        flush()
        return frames
    }

    static func freePortPair() throws -> UInt16 {
        for _ in 0..<50 {
            let probe = try UDPSocket.bind(host: "127.0.0.1")
            let port = probe.localPort & ~1
            probe.close()
            guard port > 1024, port < 65_534 else { continue }
            guard let rtp = try? UDPSocket.bind(host: "127.0.0.1", port: port) else { continue }
            guard let rtcp = try? UDPSocket.bind(host: "127.0.0.1", port: port + 1) else { rtp.close(); continue }
            rtp.close()
            rtcp.close()
            return port
        }
        throw UDPSocketError.invalidAddress("no free port pair")
    }

    /// True once another socket holds `port` (our probe bind fails).
    static func isBound(_ port: UInt16) -> Bool {
        guard let probe = try? UDPSocket.bind(host: "127.0.0.1", port: port) else { return true }
        probe.close()
        return false
    }

    struct Running: Sendable {
        let process: Process
        let stdout: Task<Data, Never>
        let stderr: Task<Data, Never>
    }

    static func start(_ executable: URL, _ arguments: [String]) throws -> Running {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdoutHandle = out.fileHandleForReading, stderrHandle = err.fileHandleForReading
        return Running(process: process, stdout: Task.detached { stdoutHandle.readDataToEndOfFile() },
                       stderr: Task.detached { stderrHandle.readDataToEndOfFile() })
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: Duration) async throws -> (status: Int32, stderr: String) {
        let running = try start(executable, arguments)
        if !(await eventually(timeout: timeout) { !running.process.isRunning }) { running.process.terminate() }
        running.process.waitUntilExit()
        _ = await running.stdout.value
        return (running.process.terminationStatus, String(decoding: await running.stderr.value, as: UTF8.self))
    }
}

import BridgeSupport
import Foundation
import MediaCore
import RTSP
import TestSupport
import Testing
@testable import CameraAdapters

func audioFrame(_ byte: UInt8, format: AudioFormat = RTSPBackchannelTalkbackSink.defaultFormat, count: Int = 160) -> EncodedAudioFrame {
    EncodedAudioFrame(format: format, data: Data(repeating: byte, count: count), pts: MediaTime(value: Int64(byte) * 160, timescale: 8000),
                      sampleCount: count, wallClock: Date())
}

/// ONVIF RTSP audio backchannel (ONVIF and Reolink talkback) against a fake RTSP session.
@Suite(.timeLimit(.minutes(1))) struct RTSPBackchannelTalkbackTests {
    private let credentials = HTTPCredentials(username: "admin", password: "secret")
    private let url = URL(string: "rtsp://192.0.2.10:554/Preview_01_main")!
    private let pcma = AudioFormat(codec: .pcma, sampleRate: 8000, channels: 1)

    @Test func opensSendsFramesAndCloses() async throws {
        let session = FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: pcma))
        let rtsp = FakeRTSPFactory(session)
        let sink = RTSPBackchannelTalkbackSink(credentials: credentials, factory: rtsp.factory) { [url] in
            URL(string: url.absoluteString.replacingOccurrences(of: "rtsp://", with: "rtsp://admin:secret@"))!
        }
        #expect(sink.inputFormat == RTSPBackchannelTalkbackSink.defaultFormat)
        try await sink.open()
        #expect(sink.inputFormat == pcma, "the SDP's backchannel format")
        let configuration = try #require(rtsp.configurations.value.first)
        #expect(configuration.requestBackchannel)
        #expect(configuration.url == url, "credentials never travel in the URL")
        #expect(configuration.credentials == credentials)
        #expect(session.calls.value == ["connect", "play"])
        for byte in [UInt8(1), 2, 3] { try await sink.send(audioFrame(byte, format: pcma)) }
        #expect(session.sent.value == [Data(repeating: 1, count: 160), Data(repeating: 2, count: 160), Data(repeating: 3, count: 160)])
        await sink.close()
        #expect(session.calls.value == ["connect", "play", "close"])
        await #expect(throws: (any Error).self) { try await sink.send(audioFrame(4)) }
        #expect(session.sent.value.count == 3)
    }

    @Test func cameraWithoutBackchannelIsUnsupportedAndClosed() async throws {
        let session = FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: nil))
        let sink = RTSPBackchannelTalkbackSink(credentials: credentials, factory: FakeRTSPFactory(session).factory) { [url] in url }
        await #expect(throws: CameraAdapterError.unsupported("the camera offers no ONVIF audio backchannel")) { try await sink.open() }
        #expect(session.calls.value == ["connect", "close"])
        await #expect(throws: (any Error).self) { try await sink.send(audioFrame(1)) }
    }

    @Test func aStalledSendTimesOutAndClosesTheSession() async throws {
        let session = FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: pcma), stallSends: true)
        let sink = RTSPBackchannelTalkbackSink(credentials: credentials, factory: FakeRTSPFactory(session).factory,
                                               sendTimeout: .milliseconds(200)) { [url] in url }
        try await sink.open()
        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) { try await sink.send(audioFrame(1, format: pcma)) }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(session.closed.value)
        await #expect(throws: CameraAdapterError.unsupported("talkback is not open")) { try await sink.send(audioFrame(2, format: pcma)) }
    }

    /// The talkback session sets up only the backchannel: no second main stream is pulled from the camera and thrown away.
    @Test func talkbackSessionIsBackchannelOnly() async throws {
        let session = FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: pcma))
        let rtsp = FakeRTSPFactory(session)
        let sink = RTSPBackchannelTalkbackSink(credentials: credentials, factory: rtsp.factory) { [url] in url }
        try await sink.open()
        let configurations = rtsp.configurations.value
        #expect(configurations.count == 1)
        #expect(configurations.first?.backchannelOnly == true, "no camera video or audio is set up for talkback")
        #expect(configurations.first?.requestBackchannel == true)
        #expect(session.calls.value == ["connect", "play"], "PLAY starts the backchannel")
        try await sink.send(audioFrame(1, format: pcma))
        #expect(session.sent.value.count == 1)
        await sink.close()
    }

    /// A camera that refuses a session without its media tracks gets the full session (backchannel plus media).
    @Test func aCameraThatRefusesABackchannelOnlySessionGetsAFullOne() async throws {
        let rtsp = FakeRTSPFactory { [pcma] configuration in
            configuration.backchannelOnly
                ? FakeRTSPSession(info: nil, error: RTSPError.badStatus(455))
                : FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: pcma))
        }
        let sink = RTSPBackchannelTalkbackSink(credentials: credentials, factory: rtsp.factory) { [url] in url }
        try await sink.open()
        #expect(rtsp.configurations.value.map(\.backchannelOnly) == [true, false])
        #expect(rtsp.configurations.value.allSatisfy { $0.requestBackchannel })
        let sessions = rtsp.sessions.value
        #expect(sessions.first?.calls.value == ["connect", "close"])
        #expect(sessions.last?.calls.value == ["connect", "play"])
        #expect(sink.inputFormat == pcma)
        try await sink.send(audioFrame(2, format: pcma))
        #expect(sessions.last?.sent.value.count == 1)
        await sink.close()
        #expect(sessions.allSatisfy { $0.closed.value })
    }

    @Test func rejectedCredentialsAreNotRetriedWithAFullSession() async throws {
        let rtsp = FakeRTSPFactory { FakeRTSPSession(info: nil, error: RTSPError.unauthorized) }
        let sink = RTSPBackchannelTalkbackSink(credentials: credentials, factory: rtsp.factory) { [url] in url }
        await #expect(throws: RTSPError.unauthorized) { try await sink.open() }
        #expect(rtsp.configurations.value.count == 1)
    }

    /// The timer closes the session, which fails the stalled send with `.closed` before the timer itself finishes:
    /// the caller still learns that the send timed out.
    @Test func aStalledSendTimesOutEvenWhenClosingFailsItFirst() async throws {
        let session = FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: pcma), stallSends: true, closeDelay: .milliseconds(200))
        let sink = RTSPBackchannelTalkbackSink(credentials: credentials, factory: FakeRTSPFactory(session).factory,
                                               sendTimeout: .milliseconds(100)) { [url] in url }
        try await sink.open()
        await #expect(throws: TransportError.timedOut) { try await sink.send(audioFrame(1, format: pcma)) }
        #expect(session.closed.value)
    }

    @Test func concurrentOpensLeaveNoSessionOpen() async throws {
        let rtsp = FakeRTSPFactory { FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: RTSPBackchannelTalkbackSink.defaultFormat)) }
        let sink = RTSPBackchannelTalkbackSink(credentials: credentials, factory: rtsp.factory) { [url] in url }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try? await sink.open() } }
        }
        await sink.close()
        let sessions = rtsp.sessions.value
        #expect(sessions.count == 4)
        #expect(sessions.allSatisfy { $0.closed.value }, "every session is closed (replaced ones included)")
    }
}

#if os(macOS) || os(Linux)
/// Reolink and ONVIF drivers hand out backchannel sinks according to the probe.
@Suite(.timeLimit(.minutes(1))) struct DriverTalkbackTests {
    /// A fresh session per RTSP connection (the probe closes its own).
    private func backchannel(_ offers: Bool) -> FakeRTSPFactory {
        FakeRTSPFactory { FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: offers ? RTSPBackchannelTalkbackSink.defaultFormat : nil)) }
    }

    private func reolink(_ camera: MockReolinkCamera, _ rtsp: FakeRTSPFactory) -> ReolinkDriver {
        ReolinkDriver(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "secret"), mainStreamURL: nil,
                      subStreamURL: nil, transport: UnusedTransport(), rtspFactory: rtsp.factory)
    }

    @Test func reolinkTalkbackIsNilAfterANegativeProbe() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let driver = reolink(camera, backchannel(false))
        #expect(driver.makeTalkbackSink() != nil)   // unknown before probing: the sink checks the SDP on open
        let result = try await driver.probe()
        #expect(!result.capabilities.twoWayAudio)
        #expect(driver.makeTalkbackSink() == nil)
    }

    @Test func reolinkTalkbackUsesTheProbedBackchannel() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let rtsp = backchannel(true)
        let driver = reolink(camera, rtsp)
        let result = try await driver.probe()
        #expect(result.capabilities.twoWayAudio)
        let sink = try #require(driver.makeTalkbackSink())
        try await sink.open()
        try await sink.send(audioFrame(7))
        await sink.close()
        let configuration = try #require(rtsp.configurations.value.last)
        #expect(configuration.url == result.mainStream?.url)
        #expect(configuration.requestBackchannel)
        #expect(rtsp.session.sent.value == [Data(repeating: 7, count: 160)])
        #expect(rtsp.session.calls.value == ["connect", "play", "close"])
        #expect(rtsp.sessions.value.count == 2, "the probe's session, then the sink's")
    }

    @Test func onvifTalkbackUsesTheProbedMainStream() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let rtsp = backchannel(true)
        let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                 transport: UnusedTransport(), rtspFactory: rtsp.factory)
        let result = try await driver.probe()
        let sink = try #require(driver.makeTalkbackSink())
        try await sink.open()
        try await sink.send(audioFrame(9))
        await sink.close()
        let configuration = try #require(rtsp.configurations.value.last)
        #expect(configuration.url == result.mainStream?.url)
        #expect(configuration.credentials == credentials)
        #expect(rtsp.session.sent.value == [Data(repeating: 9, count: 160)])
    }
}

/// A transport whose connection answers the audio upload's head with 200, then never reads audio again.
final class StallingUploadTransport: NetworkTransport {
    final class Connection: TCPConnection {
        let id = UUID()
        let localAddress = "127.0.0.1"
        let remoteAddress = "127.0.0.1"
        let isIPv6 = false
        let sends = Box(0)
        let closed = Box(false)
        private let answered = Box(false)
        /// `close()` blocks this long after the stalled send has already failed with `.closed` (a socket can report
        /// the two in either order).
        private let closeDelay: TimeInterval

        init(closeDelay: TimeInterval = 0) { self.closeDelay = closeDelay }

        func receive(maximumLength: Int) async throws -> Data? {
            if !answered.value {
                answered.set(true)
                return Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
            }
            while !closed.value { try? await Task.sleep(for: .milliseconds(5)) }
            throw TransportError.closed
        }

        func send(_ data: Data) async throws {
            if closed.value { throw TransportError.closed }
            let count = sends.update { $0 += 1; return $0 }
            guard count > 1 else { return }   // the request head goes through
            while !closed.value { try? await Task.sleep(for: .milliseconds(5)) }   // ignores cancellation, like a socket
            throw TransportError.closed
        }

        func close() {
            closed.set(true)
            if closeDelay > 0 { Thread.sleep(forTimeInterval: closeDelay) }
        }
    }

    let connection: Connection

    init(closeDelay: TimeInterval = 0) { connection = Connection(closeDelay: closeDelay) }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener { throw TransportError.addressInUse }
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection { connection }
}
#endif

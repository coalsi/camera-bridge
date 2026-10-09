import BridgeSupport
import Foundation
import MediaCore
import Testing
@testable import CameraAdapters

/// Numbers from a buggy or hostile device must never trap (the bridge serves every camera from one process).
@Suite struct HostileNumberTests {
    @Test func jsonStringOfHugeIntegralNumbersDoesNotTrap() throws {
        for text in ["1e300", "-1e19", "9223372036854775808", "-9223372036854775809", "1e19", "1.7976931348623157e308"] {
            let json = try JSONValue.parse(Data(#"[{"cmd":\#(text)}]"#.utf8))
            let string = try #require(json[0]?["cmd"]?.string, "\(text)")
            #expect(Double(string) == Double(text), "\(text) → \(string)")
        }
        #expect(JSONValue.number(42).string == "42")
        #expect(JSONValue.number(-7).string == "-7")
        #expect(JSONValue.number(1.5).string == "1.5")
        #expect(JSONValue.number(9_007_199_254_740_991).string == "9007199254740991")
        #expect(JSONValue.number(.infinity).string != nil)
        #expect(JSONValue.number(.nan).string != nil)
        #expect(JSONValue.number(1e300).int == nil)
    }

    @Test func sampleRatesAreFiniteAndPlausible() {
        #expect(CameraNumbers.sampleRate("8") == 8000)
        #expect(CameraNumbers.sampleRate("16.0") == 16000)
        #expect(CameraNumbers.sampleRate("44.1") == 44100)
        #expect(CameraNumbers.sampleRate("48000") == 48000)
        for bad in ["nan", "NaN", "inf", "-inf", "1e300", "-8", "0", "0.0001", "9e18", "", "abc", "1e7"] {
            #expect(CameraNumbers.sampleRate(bad) == nil, "\(bad)")
        }
        #expect(CameraNumbers.sampleRate(nil) == nil)
    }

    @Test func dimensionsAndFrameRatesAreClamped() {
        #expect(CameraNumbers.dimension("1920") == 1920)
        #expect(CameraNumbers.dimension(" 1080 ") == 1080)
        for bad in ["9223372036854775807", "99999999999999999999", "0", "-5", "16385", "1e3", "x"] {
            #expect(CameraNumbers.dimension(bad) == nil, "\(bad)")
        }
        #expect(CameraNumbers.dimension(Int.max) == nil)
        #expect(CameraNumbers.dimension(640) == 640)
        #expect(CameraNumbers.frameRate(25) == 25)
        #expect(CameraNumbers.frameRate(.nan) == nil)
        #expect(CameraNumbers.frameRate(.infinity) == nil)
        #expect(CameraNumbers.frameRate(-1) == nil)
        #expect(CameraNumbers.frameRate(1e300) == nil)
    }

    @Test func hikvisionChannelsWithHostileNumbers() throws {
        for (rate, expected) in [("nan", nil), ("inf", nil), ("1e300", nil), ("-8", nil), ("16", 16000), ("44.1", 44100)] as [(String, Int?)] {
            let xml = """
            <StreamingChannelList xmlns="http://www.hikvision.com/ver20/XMLSchema"><StreamingChannel><id>101</id>\
            <Video><videoCodecType>H.264</videoCodecType><videoResolutionWidth>9223372036854775807</videoResolutionWidth>\
            <videoResolutionHeight>-5</videoResolutionHeight><maxFrameRate>1e309</maxFrameRate></Video>\
            <Audio><enabled>true</enabled><audioCompressionType>AAC</audioCompressionType><audioSamplingRate>\(rate)</audioSamplingRate></Audio>\
            </StreamingChannel></StreamingChannelList>
            """
            let channels = HikvisionXML.streamingChannels(try XMLTree.parse(Data(xml.utf8)))
            let channel = try #require(channels.first)
            #expect(channel.audioSampleRate == expected, "\(rate)")
            #expect(channel.width == nil && channel.height == nil && channel.fps == nil)
        }
    }

    @Test func onvifProfilesWithHostileNumbers() throws {
        let xml = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" \
        xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body><trt:GetProfilesResponse>\
        <trt:Profiles token="big"><tt:Name>big</tt:Name><tt:VideoEncoderConfiguration><tt:Encoding>H264</tt:Encoding>\
        <tt:Resolution><tt:Width>9223372036854775807</tt:Width><tt:Height>9223372036854775807</tt:Height></tt:Resolution>\
        <tt:RateControl><tt:FrameRateLimit>nan</tt:FrameRateLimit></tt:RateControl></tt:VideoEncoderConfiguration>\
        <tt:AudioEncoderConfiguration><tt:Encoding>AAC</tt:Encoding><tt:SampleRate>nan</tt:SampleRate></tt:AudioEncoderConfiguration></trt:Profiles>\
        <trt:Profiles token="inf"><tt:Name>inf</tt:Name><tt:VideoEncoderConfiguration><tt:Encoding>H264</tt:Encoding>\
        <tt:Resolution><tt:Width>640</tt:Width><tt:Height>480</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration>\
        <tt:AudioEncoderConfiguration><tt:Encoding>G711</tt:Encoding><tt:SampleRate>1e300</tt:SampleRate></tt:AudioEncoderConfiguration></trt:Profiles>\
        <trt:Profiles token="ok"><tt:Name>ok</tt:Name><tt:VideoEncoderConfiguration><tt:Encoding>H264</tt:Encoding>\
        <tt:Resolution><tt:Width>1920</tt:Width><tt:Height>1080</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration>\
        <tt:AudioEncoderConfiguration><tt:Encoding>AAC</tt:Encoding><tt:SampleRate>16</tt:SampleRate></tt:AudioEncoderConfiguration></trt:Profiles>\
        </trt:GetProfilesResponse></s:Body></s:Envelope>
        """
        let profiles = ONVIFClient.parseProfiles(try XMLTree.parse(Data(xml.utf8)))
        #expect(profiles.map(\.token) == ["big", "inf", "ok"])
        #expect(profiles[0].width == nil && profiles[0].height == nil && profiles[0].frameRate == nil && profiles[0].audioSampleRate == nil)
        #expect(profiles[1].audioSampleRate == nil)
        #expect(profiles[2].audioSampleRate == 16000)
        let (main, sub) = ONVIFDriver.selectProfiles(profiles)
        #expect(main?.token == "ok" && sub?.token == "inf")
    }

    @Test func profileSelectionNeverOverflows() {
        func profile(_ token: String, _ width: Int?, _ height: Int?) -> ONVIFProfile {
            ONVIFProfile(token: token, name: token, videoEncoding: "H264", width: width, height: height, frameRate: nil, audioEncoding: nil,
                         audioSampleRate: nil)
        }
        let huge = profile("huge", Int.max, Int.max)
        #expect(huge.pixelCount == Int.max)
        let (main, sub) = ONVIFDriver.selectProfiles([profile("small", 640, 480), huge, profile("none", nil, nil)])
        #expect(main?.token == "huge" && sub?.token == "small")
    }

    @Test func onvifSystemDateRejectsAbsurdComponents() throws {
        func response(year: String, month: String = "9") throws -> XMLTree {
            try XMLTree.parse(Data("""
            <tds:GetSystemDateAndTimeResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">\
            <tds:SystemDateAndTime><tt:UTCDateTime><tt:Time><tt:Hour>12</tt:Hour><tt:Minute>0</tt:Minute><tt:Second>0</tt:Second></tt:Time>\
            <tt:Date><tt:Year>\(year)</tt:Year><tt:Month>\(month)</tt:Month><tt:Day>30</tt:Day></tt:Date></tt:UTCDateTime>\
            </tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>
            """.utf8))
        }
        #expect(ONVIFClient.parseSystemDate(try response(year: "2026")) == Date(timeIntervalSince1970: 1_790_769_600))
        #expect(ONVIFClient.parseSystemDate(try response(year: "1970", month: "1")) != nil)
        #expect(ONVIFClient.parseSystemDate(try response(year: "9223372036854775807")) == nil)
        #expect(ONVIFClient.parseSystemDate(try response(year: "2026", month: "99")) == nil)
        #expect(ONVIFClient.parseSystemDate(try response(year: "-5")) == nil)
    }
}

#if os(macOS)
@Suite(.timeLimit(.minutes(1))) struct HostileDeviceTests {
    @Test func reolinkDetectionSurvivesHugeNumbers() async throws {
        let server = try await MockHTTPServer.start { request in
            request.path == "/api.cgi" ? .json(#"[{"cmd":1e300,"code":1e19,"error":{"rspCode":-1e300}}]"#) : .status(404)
        }
        defer { server.stop() }
        #expect(await CameraDrivers.isReolink(endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)), timeout: .seconds(4)))
    }

    @Test func reolinkLoginWithHugeTokenNumbersDoesNotTrap() async throws {
        let server = try await MockHTTPServer.start { _ in
            .json(#"[{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":1e300,"name":1e300}}}]"#)
        }
        defer { server.stop() }
        let api = ReolinkAPI(endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)),
                             credentials: HTTPCredentials(username: "admin", password: "x"))
        _ = try? await api.login()
    }

    /// A close-delimited body that only ends after `megabytes` MiB (spaces: neither JSON nor XML can end early).
    private static func endlessBody(megabytes: Int = 64) -> MockResponse {
        .stream(status: 200, headers: [("Content-Type", "application/octet-stream")]) { writer in
            let chunk = Data(repeating: 0x20, count: 1 << 20)
            for _ in 0..<megabytes {
                guard await writer.write(chunk) else { return }
            }
        }
    }

    /// Review finding (W4 BridgeSupport): Reolink's 1 Hz event poll buffered a camera's whole answer, so an endless body
    /// grew the bridge's memory without bound. It now fails once the answer passes the client's body limit.
    @Test func reolinkCommandWithAnEndlessBodyFailsAtTheBodyLimit() async throws {
        let server = try await MockHTTPServer.start { request in
            if request.query("cmd") == "Login" {
                return .json(#"[{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":3600,"name":"t0k"}}}]"#)
            }
            return Self.endlessBody()
        }
        defer { server.stop() }
        let api = ReolinkAPI(endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)),
                             credentials: HTTPCredentials(username: "admin", password: "x"))
        await #expect(throws: HTTPClientError.bodyTooLarge(limit: AuthenticatingHTTPClient.defaultMaximumBodySize)) {
            _ = try await api.command("GetMdState", param: .object(["channel": .number(0)]))
        }
    }

    /// Same for the ONVIF PullMessages long poll (whose answer was then parsed whole by `XMLTree`).
    @Test func onvifLongPollWithAnEndlessBodyFailsAtTheBodyLimit() async throws {
        let server = try await MockHTTPServer.start { _ in Self.endlessBody() }
        defer { server.stop() }
        let client = ONVIFClient(deviceServiceURL: server.baseURL.appending(path: "onvif/device_service"), credentials: nil)
        await #expect(throws: HTTPClientError.bodyTooLarge(limit: AuthenticatingHTTPClient.defaultMaximumBodySize)) {
            _ = try await client.call(server.baseURL.appending(path: "onvif/Events"), body: "<tev:PullMessages/>", authenticated: false, longPoll: true)
        }
    }
}
#endif

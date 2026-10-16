#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// A Tapo C325WB answers ONVIF with three profiles: H.264 main (`stream1`), H.264 sub (`stream2`) and a JPEG one at the sub stream's size or
/// smaller (its snapshots). The streams step (and Optimize, which plans the same way) must plan and write only the H.264/H.265 profiles the
/// bridge streams, never the JPEG one. A loopback fake, never a real camera.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CameraSetupJPEGProfileTests {
    final class FakeTapo: Sendable {
        struct Encoder: Sendable {
            var encoding: String
            var width: Int
            var height: Int
            var fps: Int
            var bitrate: Int
            var gov: Int?
        }

        let port: UInt16
        /// Token → encoder configuration: main and sub H.264, the JPEG profile the smallest.
        let encoders = Box<[String: Encoder]>([
            "000": Encoder(encoding: "H264", width: 2560, height: 1440, fps: 15, bitrate: 2048, gov: 30),
            "001": Encoder(encoding: "H264", width: 640, height: 360, fps: 15, bitrate: 512, gov: 60),
            "002": Encoder(encoding: "JPEG", width: 320, height: 180, fps: 1, bitrate: 512, gov: nil),
        ])
        let timeZone = Box("UTC0")
        /// Configuration tokens of every `SetVideoEncoderConfiguration`, in order.
        let encoderWrites = Box<[String]>([])
        private let listener: any TCPListener
        private let task = Mutex<Task<Void, Never>?>(nil)

        init() async throws {
            listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
            port = listener.port
            let task = Task { [self] in
                for await connection in listener.connections { Task { await serve(connection) } }
            }
            self.task.withLock { $0 = task }
        }

        func stop() {
            listener.close()
            task.withLock { $0?.cancel() }
        }

        private func serve(_ connection: any TCPConnection) async {
            var parser = HTTPRequestParser(maxBodySize: 1 << 20)
            defer { connection.close() }
            while true {
                guard let data = try? await connection.receive(maximumLength: 65_536), let requests = try? parser.feed(data) else { return }
                for (_, body) in requests {
                    let (status, text) = answer(String(decoding: body, as: UTF8.self))
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders([("Content-Type", "application/soap+xml; charset=utf-8")]),
                                                       body: Data(text.utf8))
                    guard (try? await connection.send(wire)) != nil else { return }
                }
            }
        }

        private func envelope(_ body: String) -> (Int, String) {
            (200, "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" "
                + "xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tt=\"http://www.onvif.org/ver10/schema\"><s:Body>\(body)</s:Body></s:Envelope>")
        }

        private func fault() -> (Int, String) {
            (400, "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:ter=\"http://www.onvif.org/ver10/error\"><s:Body><s:Fault>"
                + "<s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:ActionNotSupported</s:Value></s:Subcode></s:Code>"
                + "<s:Reason><s:Text xml:lang=\"en\">not supported</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>")
        }

        private func configuration(_ token: String, _ e: Encoder, element: String) -> String {
            let gov = e.gov.map { "<tt:H264><tt:GovLength>\($0)</tt:GovLength><tt:H264Profile>Main</tt:H264Profile></tt:H264>" } ?? ""
            return "<\(element) token=\"\(token)\"><tt:Name>enc\(token)</tt:Name><tt:UseCount>1</tt:UseCount><tt:Encoding>\(e.encoding)</tt:Encoding>"
                + "<tt:Resolution><tt:Width>\(e.width)</tt:Width><tt:Height>\(e.height)</tt:Height></tt:Resolution><tt:Quality>4</tt:Quality>"
                + "<tt:RateControl><tt:FrameRateLimit>\(e.fps)</tt:FrameRateLimit><tt:EncodingInterval>1</tt:EncodingInterval>"
                + "<tt:BitrateLimit>\(e.bitrate)</tt:BitrateLimit></tt:RateControl>\(gov)</\(element)>"
        }

        /// The SOAP body's first element's local name.
        static func action(_ body: String) -> String? {
            guard let range = body.range(of: "Body>") else { return nil }
            return body[range.upperBound...].firstMatch(of: /<(?:[A-Za-z0-9]+:)?([A-Za-z0-9]+)/).map { String($0.output.1) }
        }

        /// The text of the first `<prefix:name>` element.
        static func text(_ name: String, _ body: String) -> String? {
            guard let open = body.firstMatch(of: try! Regex("<(?:[A-Za-z0-9]+:)?\(name)>")),
                  let close = body[open.range.upperBound...].range(of: "</") else { return nil }
            return String(body[open.range.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        private func answer(_ body: String) -> (Int, String) {
            guard let action = Self.action(body) else { return (400, "") }
            let encoders = self.encoders.value.sorted { $0.key < $1.key }
            switch action {
            case "GetSystemDateAndTime":
                return envelope("<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>NTP</tt:DateTimeType>"
                    + "<tt:DaylightSavings>false</tt:DaylightSavings><tt:TimeZone><tt:TZ>\(timeZone.value)</tt:TZ></tt:TimeZone></tds:SystemDateAndTime>"
                    + "</tds:GetSystemDateAndTimeResponse>")
            case "SetSystemDateAndTime":
                if let zone = Self.text("TZ", body) { timeZone.set(zone) }
                return envelope("<tds:SetSystemDateAndTimeResponse/>")
            case "GetDeviceInformation":
                return envelope("<tds:GetDeviceInformationResponse><tds:Manufacturer>tp-link</tds:Manufacturer><tds:Model>C325WB</tds:Model>"
                    + "<tds:FirmwareVersion>1.0</tds:FirmwareVersion><tds:SerialNumber>1</tds:SerialNumber><tds:HardwareId>1</tds:HardwareId></tds:GetDeviceInformationResponse>")
            case "GetProfiles":
                let profiles = encoders.map { token, e in
                    "<trt:Profiles token=\"\(token)\"><tt:Name>p\(token)</tt:Name>\(configuration(token, e, element: "tt:VideoEncoderConfiguration"))</trt:Profiles>"
                }.joined()
                return envelope("<trt:GetProfilesResponse>\(profiles)</trt:GetProfilesResponse>")
            case "GetStreamUri":
                let token = Self.text("ProfileToken", body) ?? ""
                let path = ["000": "/stream1", "001": "/stream2"][token] ?? "/jpeg"
                return envelope("<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://127.0.0.1:554\(path)</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>")
            case "GetVideoEncoderConfigurations":
                let all = encoders.map { configuration($0.key, $0.value, element: "trt:Configurations") }.joined()
                return envelope("<trt:GetVideoEncoderConfigurationsResponse>\(all)</trt:GetVideoEncoderConfigurationsResponse>")
            case "SetVideoEncoderConfiguration":
                let token = body.firstMatch(of: /Configuration token="([^"]*)"/).map { String($0.output.1) } ?? ""
                encoderWrites.update { $0.append(token) }
                if let gov = Self.text("GovLength", body).flatMap({ Int($0) }) { self.encoders.update { $0[token]?.gov = gov } }
                if let fps = Self.text("FrameRateLimit", body).flatMap({ Int($0) }) { self.encoders.update { $0[token]?.fps = fps } }
                return envelope("<trt:SetVideoEncoderConfigurationResponse/>")
            default:
                return fault()
            }
        }
    }

    @Test func theJPEGProfileIsNeverPlannedOrWritten() async throws {
        let fixture = try await EngineFixture()
        let camera = try await FakeTapo()
        defer { camera.stop(); fixture.directory.remove() }
        var configuration = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif,
                                                endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.port), onvifPort: Int(camera.port)),
                                                username: "admin")
        configuration.mainStreamURL = URL(string: "rtsp://127.0.0.1:554/stream1")
        configuration.subStreamURL = URL(string: "rtsp://127.0.0.1:554/stream2")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: "pa55")

        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let streams = try #require(preview.steps.first { $0.id == .streams })
        #expect(streams.status == .willChange)
        #expect(streams.changes == [CameraSetupChange(label: "Sub stream", now: "H.264, 640×360, 15 fps, 512 kbit/s, keyframe every 4 s",
                                                      after: "H.264, 640×360, 15 fps, 512 kbit/s, keyframe every 2 s")])
        #expect(!streams.changes.contains { $0.now.contains("JPEG") || $0.after.contains("JPEG") })

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.steps.first { $0.id == .streams }?.status == .done)
        #expect(camera.encoderWrites.value.allSatisfy { $0 == "001" } && !camera.encoderWrites.value.isEmpty, "only the H.264 sub stream is written")
        #expect(camera.encoders.value["002"]?.fps == 1, "the JPEG profile is untouched")
        #expect(stored(fixture, configuration.id)?.setupBackup?.streams?.subEncoder?.token == "001")

        // Optimize plans the same way.
        _ = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        camera.encoderWrites.set([])
        _ = try await fixture.engine.optimizeForHomeKit(cameraID: configuration.id)
        #expect(!camera.encoderWrites.value.contains("002"))
    }

    @Test func aCameraWhoseOnlySmallProfileIsJPEGHasNoSubStreamToChange() {
        let main = CameraVideoEncoderSettings(token: "000", name: "", encoding: "H264", resolution: .init(width: 1920, height: 1080), frameRate: 15,
                                              bitrate: 3000, iFrameInterval: 30)
        let jpeg = CameraVideoEncoderSettings(token: "002", name: "", encoding: "JPEG", resolution: .init(width: 640, height: 360), frameRate: 1,
                                              bitrate: 512)
        let mjpeg = CameraVideoEncoderSettings(token: "", name: "", encoding: "MJPEG", resolution: .init(width: 640, height: 360), frameRate: 1)
        #expect(BridgeEngine.plannedEncoderFixes(main: main, mainProfile: nil, sub: jpeg, subProfile: nil, mainHasBFrames: false).isEmpty)
        #expect(BridgeEngine.plannedEncoderFixes(main: jpeg, mainProfile: nil, sub: mjpeg, subProfile: nil, mainHasBFrames: false).isEmpty)
        #expect(CameraSettingsService.isStreamCodec("H.265") && CameraSettingsService.isStreamCodec("hevc") && !CameraSettingsService.isStreamCodec("JPEG"))
    }

    private func stored(_ fixture: EngineFixture, _ id: UUID) -> CameraConfiguration? { fixture.engine.configurations.first { $0.id == id } }
}
#endif

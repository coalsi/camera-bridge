import BridgeEngine
import CameraAdapters
import Foundation
import Testing

@Suite struct WebhookSettingsTests {
    @Test func tokensAre32RandomHexDigits() {
        let a = WebhookSettings.generateToken(), b = WebhookSettings.generateToken()
        #expect(a.count == 32 && a.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
        #expect(a != b)
    }

    @Test func portValidation() {
        var settings = BridgeSettings()   // sensors bridge 21099, cameras from 21100
        settings.webhookPort = 21_090
        #expect(WebhookSettings.validatePort("21090", settings: settings, cameraPorts: []) == .valid(21_090))
        #expect(WebhookSettings.validatePort(" 8080 ", settings: settings, cameraPorts: []) == .valid(8_080))
        #expect(WebhookSettings.validatePort("80", settings: settings, cameraPorts: []) == .invalid("Use a port from 1024 to 65535."))
        #expect(WebhookSettings.validatePort("70000", settings: settings, cameraPorts: []) == .invalid("Use a port from 1024 to 65535."))
        #expect(WebhookSettings.validatePort("abc", settings: settings, cameraPorts: []) == .invalid("Use a port from 1024 to 65535."))
        #expect(WebhookSettings.validatePort("21099", settings: settings, cameraPorts: [])
                == .invalid("Port 21099 is used by the sensors bridge."))
        #expect(WebhookSettings.validatePort("21102", settings: settings, cameraPorts: [21_100, 21_101, 21_102])
                == .invalid("Port 21102 is used by a camera."))
    }

    @Test func exampleRequestNeverContainsTheToken() {
        var settings = BridgeSettings()
        settings.webhookPort = 21_090
        let id = UUID(uuidString: "CB000000-0000-4000-8000-000000000001")!
        let url = WebhookSettings.exampleURL(host: "studio-mac.local", port: settings.webhookPort, cameraID: id, event: "motion")
        #expect(url == "http://studio-mac.local:21090/cameras/CB000000-0000-4000-8000-000000000001/motion")
        let command = WebhookSettings.exampleCommand(host: "studio-mac.local", settings: settings, cameraID: id, event: "doorbell")
        #expect(command.contains("Authorization: Bearer $CAMERABRIDGE_TOKEN"))
        #expect(!command.contains(settings.webhookToken))
        #expect(command.hasPrefix("curl -X POST"))
    }

    /// Review finding (W4 round 2): a camera's ID and URLs appeared only while its motion source was Webhook (and then
    /// only `/motion`), so a doorbell that rings through the webhook (every Hikvision doorbell) couldn't be set up.
    @Test func everyCameraListsItsWebhookURLs() {
        let id = UUID(uuidString: "CB000000-0000-4000-8000-000000000001")!
        let base = "http://studio-mac.local:21090/cameras/CB000000-0000-4000-8000-000000000001/"
        let camera = WebhookSettings.cameraURLs(host: "studio-mac.local", port: 21_090, cameraID: id, kind: .camera)
        #expect(camera.map(\.event) == ["motion", "motion/stop", "person", "vehicle", "animal", "package"])
        #expect(camera.allSatisfy { $0.url == base + $0.event })
        let doorbell = WebhookSettings.cameraURLs(host: "studio-mac.local", port: 21_090, cameraID: id, kind: .doorbell)
        #expect(doorbell.map(\.event) == ["doorbell", "motion", "motion/stop", "person", "vehicle", "animal", "package"])
        #expect(doorbell.first?.url == base + "doorbell")
    }

    /// The Settings example names no particular camera: a stable placeholder (it was the first camera's ID, or a new
    /// random UUID at every redraw without cameras).
    @Test func theSettingsExampleUsesAPlaceholderForTheCamera() {
        let settings = BridgeSettings()
        let command = WebhookSettings.exampleCommand(host: "studio-mac.local", settings: settings, cameraID: nil, event: "motion")
        #expect(command.hasSuffix(":\(settings.webhookPort)/cameras/<camera ID>/motion"))
        #expect(command == WebhookSettings.exampleCommand(host: "studio-mac.local", settings: settings, cameraID: nil, event: "motion"))
    }

    /// Example URLs use the kernel host name: no DNS or mDNS lookup (`ProcessInfo.hostName` blocks on reverse DNS for
    /// seconds). The bound is loose so a loaded machine can't flake it; `gethostname` takes microseconds.
    @Test func localHostNameIsImmediateAndBonjourShaped() {
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = WebhookSettings.currentHostName() }
        #expect(elapsed < .seconds(1))
        #expect(!WebhookSettings.localHostName.isEmpty && !WebhookSettings.localHostName.contains(" "))
        #expect(WebhookSettings.bonjourHostName("Studio-Mac") == "Studio-Mac.local")
        #expect(WebhookSettings.bonjourHostName("studio-mac.local") == "studio-mac.local")
        #expect(WebhookSettings.bonjourHostName("mac.lan") == "mac.lan")
        #expect(WebhookSettings.bonjourHostName("") == "localhost")
    }

    /// Review finding (W4 round 4): a webhook that isn't listening showed only in Settings › Webhook, while camera pages
    /// kept listing their URLs. A camera page says so next to them, most plainly for cameras whose rings or motion come
    /// only through the webhook (every Hikvision doorbell rings through it).
    @Test func cameraPagesSayWhenTheWebhookIsntListening() {
        let problem = "The webhook cannot listen on port 21090 (another app uses the port)."
        var hikvisionDoorbell = CameraConfiguration(name: "Porch", kind: .doorbell, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.21"),
                                                    username: "admin")
        hikvisionDoorbell.capabilities = CameraCapabilities(events: [.motion])   // no button of its own
        #expect(WebhookSettings.dependsOnWebhook(hikvisionDoorbell))
        #expect(WebhookSettings.cameraNotice(problem: problem, for: hikvisionDoorbell)
                == "\(problem) This doorbell rings only through the webhook, so its rings are lost until it listens.")

        var reolinkDoorbell = hikvisionDoorbell
        reolinkDoorbell.capabilities = CameraCapabilities(events: [.motion, .doorbell], isDoorbell: true)
        #expect(!WebhookSettings.dependsOnWebhook(reolinkDoorbell))
        #expect(WebhookSettings.cameraNotice(problem: problem, for: reolinkDoorbell) == "\(problem) Events sent to these URLs are lost until it listens.")

        var yard = CameraConfiguration(name: "Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.24"), username: "")
        yard.motionSource = .webhook
        #expect(WebhookSettings.dependsOnWebhook(yard))
        #expect(WebhookSettings.cameraNotice(problem: problem, for: yard).contains("motion comes from the webhook"))
    }

    @Test func maskedTokenKeepsOnlyTheLastFourDigits() {
        #expect(WebhookSettings.masked("5f1c0d9e7a3b42c68e0f1a2b3c4d5e6f") == "••••••••••••••••••••••••••••5e6f")
        #expect(WebhookSettings.masked("abc") == "•••")
    }
}

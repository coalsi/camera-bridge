import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import RTSP

// The Add Camera page's rules: the Mac app's wizard (`AddCameraWizardModel`) as a stateless service. The page sends everything it
// has collected with each request; the server validates it, checks the camera, and builds the configuration to add.

/// A request the page can fix: the sentence says what is wrong, `field` which input it belongs to.
struct SetupProblem: Error {
    var message: String
    var field: String?
}

/// What the page sends to `/probe` and `/cameras`.
struct SetupRequest: Decodable {
    var type: String
    var host: String?
    var httpPort: Int?
    var rtspPort: Int?
    var onvifPort: Int?
    var useHTTPS: Bool?
    var username: String?
    var password: String?
    var apiKey: String?
    var mainStreamURL: String?
    var subStreamURL: String?
    /// A cloud camera's go2rtc source.
    var source: String?
    var unifiCameraID: String?
    var unifiCameraName: String?
    var nestSession: String?
    var nestDeviceID: String?
    // Choices of the later pages (add only).
    var name: String?
    var kind: CameraKind?
    var motionSource: MotionSource?
    var motionSensitivity: Double?
    var motionHoldSeconds: Int?
    var sensors: SensorOptions?
    var audioEnabled: Bool?
    var twoWayAudio: Bool?
}

/// The Nest sign-in the server holds between "connect" and "add" (the refresh token never goes to the browser).
struct NestSignIn: Sendable {
    var projectID: String
    var clientID: String
    var clientSecret: String
    var refreshToken: String
    var cameras: [NestDeviceAccess.Camera]
    var created: Date
}

/// A checked request: where the camera is, what it is called, and what the engine is asked.
struct PreparedCamera {
    var spec: CameraTypeSpec
    var vendor: CameraVendor?
    var endpoint: CameraEndpoint
    var username: String
    var password: String
    var mainStreamURL: URL?
    var subStreamURL: URL?
    var integration: IntegrationSettings?
    /// What goes to the secret store as the camera's password: the cloud source, the console's API key, or the camera's password.
    var secret: String?
    var source: Go2RTCSource?
}

enum CameraSetup {
    static let rtspOverTLSUnsupported = "Camera Bridge can’t use RTSP over TLS (rtsps://) yet. Enter the camera’s plain rtsp:// URL; many cameras offer both."

    // MARK: Validation

    /// Checks `request` as the wizard's Connect page does and resolves the type, address, streams and secrets.
    static func prepare(_ request: SetupRequest, helperInstalled: Bool, nest: NestSignIn?) throws -> PreparedCamera {
        guard let spec = CameraTypeCatalog.spec(id: request.type) else { throw SetupProblem(message: "Choose a camera type.", field: "type") }
        var username = (request.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var password = request.password ?? ""
        var useHTTPS = request.useHTTPS ?? spec.defaultUseHTTPS
        var httpPort = request.httpPort ?? spec.defaultHTTPPort
        var rtspPort = request.rtspPort ?? spec.defaultRTSPPort
        let onvifPort = request.onvifPort
        let vendor = spec.cameraVendor

        switch spec.id {
        case "demo":
            return PreparedCamera(spec: spec, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "", password: "",
                                  mainStreamURL: nil, subStreamURL: nil, integration: nil, secret: nil, source: nil)

        case "rtspURL":
            var main = (request.mainStreamURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var sub = (request.subStreamURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard streamURL(main) != nil else {
                throw SetupProblem(message: isRTSPOverTLS(main) ? rtspOverTLSUnsupported : "Enter the main stream URL, starting with rtsp://.",
                                   field: "mainStreamURL")
            }
            if !sub.isEmpty, streamURL(sub) == nil {
                throw SetupProblem(message: isRTSPOverTLS(sub) ? rtspOverTLSUnsupported : "The sub stream URL must start with rtsp://.", field: "subStreamURL")
            }
            moveCredentials(from: &main, username: &username, password: &password)
            moveCredentials(from: &sub, username: &username, password: &password)
            guard let mainURL = streamURL(main), let host = mainURL.host(percentEncoded: false) else {
                throw SetupProblem(message: "Enter the main stream URL, starting with rtsp://.", field: "mainStreamURL")
            }
            return PreparedCamera(spec: spec, vendor: .rtsp, endpoint: CameraEndpoint(host: host, rtspPort: mainURL.port ?? defaultRTSPPort(mainURL.scheme)),
                                  username: username, password: password, mainStreamURL: mainURL.removingUserInfo,
                                  subStreamURL: sub.isEmpty ? nil : streamURL(sub)?.removingUserInfo, integration: nil,
                                  secret: password.isEmpty ? nil : password, source: nil)

        case "wyzeRTSP":
            guard let input = HostInput(request.host ?? "") else {
                throw SetupProblem(message: "Enter the camera’s IP address, like 192.0.2.20.", field: "host")
            }
            if username.isEmpty { username = input.user ?? "" }
            if password.isEmpty { password = input.password ?? "" }
            if username.isEmpty { throw SetupProblem(message: "Enter the RTSP user name you created in the Wyze app.", field: "username") }
            if password.isEmpty { throw SetupProblem(message: "Enter the RTSP password you created in the Wyze app.", field: "password") }
            let host = input.host.contains(":") ? "[\(input.host)]" : input.host
            guard let url = URL(string: "rtsp://\(host):554\(CameraTypeCatalog.wyzePaths[0])") else {
                throw SetupProblem(message: "Enter the camera’s IP address, like 192.0.2.20.", field: "host")
            }
            return PreparedCamera(spec: spec, vendor: .rtsp, endpoint: CameraEndpoint(host: input.host, rtspPort: 554), username: username,
                                  password: password, mainStreamURL: url, subStreamURL: nil, integration: nil, secret: password, source: nil)

        case "unifiProtect":
            guard let input = HostInput(request.host ?? "") else {
                throw SetupProblem(message: "Enter the console’s address, like 192.0.2.1.", field: "host")
            }
            let key = (request.apiKey ?? password).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { throw SetupProblem(message: "Paste the API key from UniFi Protect.", field: "apiKey") }
            if input.scheme == "http" { useHTTPS = false } else if input.scheme == "https" { useHTTPS = true }
            if let port = input.port { httpPort = port }
            guard (1...65_535).contains(httpPort) else { throw SetupProblem(message: "Ports must be between 1 and 65535.", field: "httpPort") }
            guard let id = request.unifiCameraID, !id.isEmpty else { throw SetupProblem(message: "Choose a camera.", field: "unifiCamera") }
            if !helperInstalled { throw SetupProblem(message: helperMissing, field: nil) }
            var details = [IntegrationSettings.Key.protectCameraID: id]
            if let name = request.unifiCameraName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                details[IntegrationSettings.Key.deviceName] = String(name.prefix(100))
            }
            return PreparedCamera(spec: spec, vendor: .unifi, endpoint: CameraEndpoint(host: input.host, httpPort: httpPort, rtspPort: 7441, useHTTPS: useHTTPS),
                                  username: "", password: "", mainStreamURL: nil, subStreamURL: nil,
                                  integration: IntegrationSettings(service: .unifiProtect, details: details), secret: key, source: nil)

        case "googleNest":
            if !helperInstalled { throw SetupProblem(message: helperMissing, field: nil) }
            guard let nest, let id = request.nestDeviceID, let camera = nest.cameras.first(where: { $0.deviceID == id }) else {
                throw SetupProblem(message: "Sign in to Google and choose a camera.", field: "nest")
            }
            let source: Go2RTCSource
            do {
                source = try Go2RTCSource.nest(clientID: nest.clientID, clientSecret: nest.clientSecret, refreshToken: nest.refreshToken,
                                               projectID: nest.projectID, deviceID: id, protocols: camera.protocolName)
            } catch {
                throw SetupProblem(message: "The Google sign-in details can’t be used. Start again.", field: "nest")
            }
            return PreparedCamera(spec: spec, vendor: .go2rtc, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "", password: "", mainStreamURL: nil,
                                  subStreamURL: nil, integration: IntegrationSettings(service: .nest, details: [IntegrationSettings.Key.deviceName: camera.name]),
                                  secret: source.url, source: source)

        case "ring", "wyzeCloud", "tuya", "otherCloud":
            if !helperInstalled { throw SetupProblem(message: helperMissing, field: nil) }
            let source: Go2RTCSource
            do {
                source = try Go2RTCSource(parsing: request.source ?? "")
            } catch let invalid as Go2RTCSource.Invalid {
                throw SetupProblem(message: invalid.reason, field: "source")
            } catch {
                throw SetupProblem(message: "The source address can’t be used.", field: "source")
            }
            let service = spec.service ?? source.service
            return PreparedCamera(spec: spec, vendor: .go2rtc, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "", password: "", mainStreamURL: nil,
                                  subStreamURL: nil, integration: IntegrationSettings(service: service == .other ? source.service : service),
                                  secret: source.url, source: source)

        default:
            // Hikvision, Reolink, ONVIF, Tapo, Amcrest / Dahua, DoorBird and detection by address.
            guard let input = HostInput(request.host ?? "") else {
                throw SetupProblem(message: "Enter the camera’s address.", field: "host")
            }
            // The scheme first: switching HTTPS moves a default port (80 ↔ 443), and a port the address names wins over it.
            if input.scheme == "https" || input.scheme == "http" {
                let secure = input.scheme == "https"
                if secure != useHTTPS {
                    useHTTPS = secure
                    if secure, httpPort == 80 { httpPort = 443 } else if !secure, httpPort == 443 { httpPort = 80 }
                }
            }
            if let port = input.port {
                switch input.scheme {
                case "rtsp": rtspPort = port
                case "rtsps": break
                default: httpPort = port
                }
            }
            if username.isEmpty { username = input.user ?? "" }
            if password.isEmpty { password = input.password ?? "" }
            if username.isEmpty { throw SetupProblem(message: "Enter the camera’s user name.", field: "username") }
            for (port, field) in [(httpPort, "httpPort"), (rtspPort, "rtspPort"), (onvifPort ?? 80, "onvifPort")] where !(1...65_535).contains(port) {
                throw SetupProblem(message: "Ports must be between 1 and 65535.", field: field)
            }
            return PreparedCamera(spec: spec, vendor: vendor, endpoint: CameraEndpoint(host: input.host, httpPort: httpPort, rtspPort: rtspPort,
                                                                                       onvifPort: onvifPort, useHTTPS: useHTTPS),
                                  username: username, password: password, mainStreamURL: nil, subStreamURL: nil, integration: nil,
                                  secret: password.isEmpty ? nil : password, source: nil)
        }
    }

    static let helperMissing = "This copy of Camera Bridge OS doesn’t include the streaming helper (go2rtc), which this camera type needs."

    // MARK: Probing

    /// The check the page's Check the Camera step makes: the engine's probe for the prepared camera.
    static func probe(_ camera: PreparedCamera, backend: any BridgeBackend) async throws -> CameraProbeResult {
        switch camera.spec.id {
        case "unifiProtect", "googleNest", "ring", "wyzeCloud", "tuya", "otherCloud":
            guard let vendor = camera.vendor, let integration = camera.integration, let secret = camera.secret else {
                throw SetupProblem(message: "The camera’s details are incomplete.", field: nil)
            }
            return try await backend.probeIntegration(vendor: vendor, integration: integration, endpoint: camera.endpoint, username: "", secret: secret)
        case "wyzeRTSP":
            // Wyze’s official RTSP lives at /stream0 on some firmware and /live on others.
            var lastError: (any Error)?
            for path in CameraTypeCatalog.wyzePaths {
                guard let url = URL(string: "rtsp://\(camera.endpoint.host.contains(":") ? "[\(camera.endpoint.host)]" : camera.endpoint.host):554\(path)") else { break }
                do {
                    return try await backend.probeCamera(vendor: .rtsp, endpoint: camera.endpoint, username: camera.username, password: camera.password,
                                                         mainStreamURL: url, subStreamURL: nil)
                } catch {
                    lastError = error
                    if Task.isCancelled || isCredentialFailure(error) { break }
                }
            }
            throw lastError ?? CameraAdapterError.unsupported("no stream address")
        default:
            return try await backend.probeCamera(vendor: camera.vendor, endpoint: camera.endpoint, username: camera.spec.id == "demo" ? "" : camera.username,
                                                 password: camera.spec.id == "demo" ? "" : camera.password, mainStreamURL: camera.mainStreamURL,
                                                 subStreamURL: camera.subStreamURL)
        }
    }

    static func isCredentialFailure(_ error: any Error) -> Bool {
        if case RTSPError.unauthorized = error { return true }
        if case CameraAdapterError.unauthorized = error { return true }
        return false
    }

    // MARK: Building

    /// The configuration to add after a successful `probe`, with the wizard's defaults where the page chose nothing.
    static func makeConfiguration(prepared: PreparedCamera, result: CameraProbeResult, request: SetupRequest, id: UUID = UUID()) throws -> CameraConfiguration {
        let defaults = Defaults(result: result, discoveredName: nil)
        let name = (request.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SetupProblem(message: "Give the camera a name.", field: "name") }
        var endpoint = prepared.endpoint
        if endpoint.onvifPort == nil, result.vendor == .onvif { endpoint.onvifPort = result.onvifPort }   // found by the probe
        let keepsUserName = prepared.spec.id != "demo" && prepared.vendor != .go2rtc && prepared.vendor != .unifi
        var config = CameraConfiguration(id: id, name: String(name.prefix(60)), kind: request.kind ?? defaults.kind, vendor: result.vendor, endpoint: endpoint,
                                         username: keepsUserName ? prepared.username : "")
        let keepsStreamAddresses = prepared.vendor != .go2rtc && prepared.vendor != .unifi
        config.mainStreamURL = keepsStreamAddresses ? (result.mainStream?.url ?? prepared.mainStreamURL)?.removingUserInfo : nil
        config.subStreamURL = keepsStreamAddresses ? (result.subStream?.url ?? prepared.subStreamURL)?.removingUserInfo : nil
        config.integration = prepared.integration
        let sources = availableMotionSources(result.capabilities)
        let wanted = request.motionSource ?? defaults.motionSource
        config.motionSource = sources.contains(wanted) ? wanted : .softMotion
        config.motionSensitivity = min(max(request.motionSensitivity ?? 0.5, 0), 1)
        config.motionHoldSeconds = min(max(request.motionHoldSeconds ?? 20, 1), 3_600)
        config.sensors = SensorCatalog.filtered(request.sensors ?? SensorOptions(), by: result.capabilities, motionSource: config.motionSource)
        config.audioEnabled = request.audioEnabled ?? defaults.audioEnabled
        config.twoWayAudio = (request.twoWayAudio ?? defaults.twoWayAudio) && result.capabilities.twoWayAudio
        config.manufacturer = result.manufacturer
        config.model = result.model
        config.serialNumber = result.serialNumber
        config.firmware = result.firmware
        config.capabilities = result.capabilities
        return config
    }

    /// What the wizard fills in after a probe.
    struct Defaults {
        var name: String
        var kind: CameraKind
        var motionSource: MotionSource
        var audioEnabled: Bool
        var twoWayAudio: Bool

        init(result: CameraProbeResult, discoveredName: String?) {
            name = discoveredName ?? (result.model.isEmpty ? "Camera" : result.model)
            kind = result.capabilities.isDoorbell ? .doorbell : .camera
            motionSource = CameraSetup.availableMotionSources(result.capabilities).first ?? .softMotion
            audioEnabled = result.mainStream.map { $0.audioCodec != nil } ?? true
            twoWayAudio = result.capabilities.twoWayAudio
        }
    }

    /// Camera events only when the camera reports motion; built-in detection and the webhook always.
    static func availableMotionSources(_ capabilities: CameraCapabilities?) -> [MotionSource] {
        let hasMotionEvents = capabilities?.events.contains(.motion) ?? false
        return MotionSource.allCases.filter { $0 != .cameraEvents || hasMotionEvents }
    }

    /// The configured camera that already shows the camera about to be added (the wizard's "already added" warning).
    static func alreadyAdded(_ candidate: CameraConfiguration, in configurations: [CameraConfiguration]) -> CameraConfiguration? {
        guard candidate.vendor != .demo else { return nil }
        return configurations.first { existing in
            guard existing.vendor != .demo, existing.id != candidate.id else { return false }
            let serial = candidate.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if !serial.isEmpty, existing.serialNumber == serial { return true }
            if candidate.vendor == .rtsp || existing.vendor == .rtsp {
                return candidate.mainStreamURL != nil && candidate.mainStreamURL?.removingUserInfo == existing.mainStreamURL?.removingUserInfo
            }
            if [CameraVendor.go2rtc, .unifi].contains(candidate.vendor) || [CameraVendor.go2rtc, .unifi].contains(existing.vendor) { return false }
            return existing.endpoint.host.caseInsensitiveCompare(candidate.endpoint.host) == .orderedSame
                && existing.endpoint.httpPort == candidate.endpoint.httpPort && existing.endpoint.rtspPort == candidate.endpoint.rtspPort
        }
    }

    // MARK: Stream URLs

    static func defaultRTSPPort(_ scheme: String?) -> Int {
        scheme?.lowercased() == "rtsps" ? 322 : 554
    }

    static func isRTSPOverTLS(_ text: String) -> Bool {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() == "rtsps"
    }

    /// An `rtsp://` URL with a host, or nil (also for `rtsps://`).
    static func streamURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "rtsp",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return url
    }

    /// User info pasted into a stream URL moves to the credential fields.
    private static func moveCredentials(from text: inout String, username: inout String, password: inout String) {
        guard let components = URLComponents(string: text), components.user != nil || components.password != nil, let url = URL(string: text) else { return }
        if username.isEmpty, let user = components.user, !user.isEmpty { username = user.removingPercentEncoding ?? user }
        if password.isEmpty, let secret = components.password { password = secret.removingPercentEncoding ?? secret }
        text = url.removingUserInfo.absoluteString
    }
}

// MARK: - Sensors

/// Optional sensors a camera can publish on the sensors bridge. Offered only when the camera reports the matching event, or
/// (detections) when the webhook is the camera's motion source and can report them.
enum SensorCatalog {
    struct Sensor: Encodable {
        var id: String
        var title: String
        var homeAccessory: String
        var fromWebhook: Bool
    }

    nonisolated(unsafe) static let all: [(id: String, event: CameraEventKind, title: String, accessory: String, path: WritableKeyPath<SensorOptions, Bool>)] = [
        ("person", .person, "Person Detection", "Occupancy sensor (stays on for 60 seconds)", \.person),
        ("vehicle", .vehicle, "Vehicle Detection", "Occupancy sensor (stays on for 60 seconds)", \.vehicle),
        ("animal", .animal, "Animal Detection", "Occupancy sensor (stays on for 60 seconds)", \.animal),
        ("package", .package, "Package Detection", "Occupancy sensor (stays on for 60 seconds)", \.package),
        ("dayNight", .dayNight, "Day and Night", "Light sensor (night reads 1 lux, day 1000 lux)", \.dayNight),
        ("digitalInputs", .digitalInput, "Alarm Inputs", "Contact sensor", \.digitalInputs),
        ("temperature", .temperature, "Temperature", "Temperature sensor", \.temperature),
        ("humidity", .humidity, "Humidity", "Humidity sensor", \.humidity),
    ]

    static let webhookKinds: Set<String> = ["person", "vehicle", "animal", "package"]

    /// The sensors `capabilities` offer, plus the webhook's detections when `motionSource` is the webhook.
    static func available(in capabilities: CameraCapabilities?, motionSource: MotionSource) -> [Sensor] {
        let events = capabilities?.events ?? []
        return all.compactMap { entry in
            let fromCamera = events.contains(entry.event)
            let fromWebhook = motionSource == .webhook && webhookKinds.contains(entry.id)
            guard fromCamera || fromWebhook else { return nil }
            return Sensor(id: entry.id, title: entry.title, homeAccessory: entry.accessory, fromWebhook: !fromCamera && fromWebhook)
        }
    }

    /// `options` with every sensor the camera (or its webhook) can't provide turned off.
    static func filtered(_ options: SensorOptions, by capabilities: CameraCapabilities?, motionSource: MotionSource) -> SensorOptions {
        let offered = Set(available(in: capabilities, motionSource: motionSource).map(\.id))
        var result = SensorOptions()
        for entry in all where offered.contains(entry.id) { result[keyPath: entry.path] = options[keyPath: entry.path] }
        return result
    }
}

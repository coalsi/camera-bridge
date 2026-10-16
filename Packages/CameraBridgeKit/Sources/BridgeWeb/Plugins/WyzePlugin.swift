import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

/// The Wyze plugin: the Wyze account (its session kept in the `SecretStore` as `plugin.wyze`, never the password), the account's cameras
/// with where each one is on the local network now and how it can be added, and a background sync every six hours that keeps the session
/// alive and moves an added camera to its new address when the camera's address changes.
///
/// How a camera is added (best first): its own RTSP (Wyze Cam v4 4.52.17+, v3 4.36.16.5654+, Pan v3 4.50.16.5654+, switched on in the Wyze
/// app), else the local Wyze connection through go2rtc (TUTK cameras with DTLS firmware), else not at all (Gwell models, cloud-only ones).
actor WyzePlugin {
    static let id = "wyze"
    static let syncInterval: Duration = .seconds(6 * 3600)
    /// A session's access token lasts about two days; it is refreshed once it is older than this.
    static let refreshAfter: TimeInterval = 24 * 3600
    static let verificationLifetime: TimeInterval = 600

    /// One camera of the account as the page shows it.
    struct CameraRow: Sendable, Encodable {
        var mac: String
        var name: String
        var model: String
        var modelName: String
        var firmware: String
        var online: Bool
        /// The camera's address on the local network now (nil: not found).
        var address: String?
        /// `on` (port 554 answers), `off` (the firmware has RTSP but it is not switched on), `unsupported` (no RTSP firmware).
        var rtsp: String
        /// Ways this camera can be added now: `rtsp`, `local`.
        var ways: [String]
        /// Why it cannot be added, or what to do first (nil when it can).
        var note: String?
        /// The bridge camera already made from it.
        var cameraID: String?
    }

    enum SignInAnswer: Sendable {
        case signedIn
        case verification(id: String, kinds: [WyzeVerification.Kind])
    }

    struct PluginProblem: Error, CustomStringConvertible {
        var description: String
    }

    private let backend: any BridgeBackend
    private let cloud: WyzeCloud
    private let log = Log(category: "wyze")
    private var session: WyzeSession?
    private var loaded = false
    private var devices: [WyzeDevice] = []
    private var addresses: [String: String] = [:]
    private var rtspOn: [String: Bool] = [:]
    private var verifications: [String: (WyzeVerification, Date)] = [:]
    private var syncTask: Task<Void, Never>?
    /// The sync under way: callers that come while it runs wait for the same one.
    private var running: Task<[WyzeDevice], any Error>?

    init(backend: any BridgeBackend, cloud: WyzeCloud = WyzeCloud()) {
        self.backend = backend
        self.cloud = cloud
    }

    // MARK: State

    private func loadSession() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? await backend.pluginSecret(id: Self.id) else { return }
        session = try? JSONDecoder().decode(WyzeSession.self, from: data)
    }

    private func store(_ next: WyzeSession?) async throws {
        session = next
        try await backend.setPluginSecret(id: Self.id, next.map { try JSONEncoder().encode($0) })
    }

    private func setState(_ change: @escaping @Sendable (inout PluginState) -> Void) async {
        try? await backend.updateSettings { settings in
            var state = settings.plugins[WyzePlugin.id] ?? PluginState()
            change(&state)
            settings.plugins[WyzePlugin.id] = state
        }
    }

    func signedIn() async -> Bool {
        await loadSession()
        return session != nil
    }

    // MARK: Signing in

    func signIn(email: String, password: String, keys: WyzeAPIKeys) async throws -> SignInAnswer {
        let answer = try await cloud.signIn(email: email, password: password, keys: keys)
        switch answer {
        case .signedIn(let next):
            try await finishSignIn(next)
            return .signedIn
        case .needsVerification(let verification):
            let id = Secrets.randomToken()
            let now = Date()
            verifications = verifications.filter { now.timeIntervalSince($0.value.1) < Self.verificationLifetime }
            verifications[id] = (verification, now)
            return .verification(id: id, kinds: verification.kinds)
        }
    }

    private func pendingVerification(_ id: String) throws -> WyzeVerification {
        guard let (verification, created) = verifications[id], Date().timeIntervalSince(created) < Self.verificationLifetime else {
            throw PluginProblem(description: "The sign-in took too long. Start again.")
        }
        return verification
    }

    func sendCode(verificationID: String, kind: WyzeVerification.Kind) async throws {
        let updated = try await cloud.sendCode(try pendingVerification(verificationID), kind: kind)
        verifications[verificationID] = (updated, Date())
    }

    func verify(verificationID: String, kind: WyzeVerification.Kind, code: String) async throws {
        let next = try await cloud.verify(try pendingVerification(verificationID), kind: kind, code: code)
        verifications[verificationID] = nil
        try await finishSignIn(next)
    }

    private func finishSignIn(_ next: WyzeSession) async throws {
        try await store(next)
        loaded = true
        let email = next.email
        await setState { state in
            state.enabled = true
            state.account = email
            state.lastError = nil
        }
        log.notice("signed in to the Wyze account")
        registerHelpers()
        // The camera list and finding the cameras on the network take a moment: the page gets its answer now and asks for the list.
        Task { _ = try? await self.sync() }
        startSync()
    }

    func signOut() async throws {
        syncTask?.cancel()
        syncTask = nil
        try await store(nil)
        devices = []
        addresses = [:]
        rtspOn = [:]
        await setState { state in
            state.account = nil
            state.lastSync = nil
            state.lastError = nil
        }
        log.notice("signed out of the Wyze account")
    }

    // MARK: Helpers

    /// Gives the Wyze helper programs (`WyzeHelpers`: the Pan v4's cloud video, Gwell models) their credentials, fresh for each start.
    private func registerHelpers() {
        WyzeHelpers.setProvider { [weak self] request in
            guard let self else { throw PluginProblem(description: "The Wyze plugin isn’t running.") }
            return try await self.helperEnvironment(request)
        }
    }

    func helperEnvironment(_ request: WyzeHelpers.Request) async throws -> [String: String] {
        await loadSession()
        guard var current = session else { throw PluginProblem(description: "The Wyze plugin isn’t signed in. Open Plugins, Wyze, and sign in.") }
        if current.phoneID == nil {
            current.phoneID = UUID().uuidString.lowercased()
            try await store(current)
        }
        if Date().timeIntervalSince(current.obtained) > Self.refreshAfter {
            current = try await cloud.refresh(current)
            try await store(current)
        }
        // Exactly as Wyze's cloud names the camera (a Gwell or cloud camera's ID isn't always hex).
        let mac = request.mac.trimmingCharacters(in: .whitespaces)
        switch request.kind {
        case .cloud:
            return ["CB_LAKE_ACCESS_TOKEN": current.accessToken, "CB_LAKE_PHONE_ID": current.phoneID ?? "", "CB_LAKE_DEVICE_MAC": mac,
                    "CB_LAKE_DEVICE_MODEL": request.model, "CB_LAKE_USER_ID": current.userID ?? "", "CB_LAKE_QUALITY": "hd"]
        case .gwell:
            let access = try await cloud.gwellAccess(current, mac: mac)
            var environment = ["CB_GWELL_DEVICE_ID": mac, "CB_GWELL_ACCESS_ID": access.accessID, "CB_GWELL_ACCESS_TOKEN": access.accessToken]
            if let address = addresses[mac] { environment["CB_GWELL_LAN_IP"] = address }
            return environment
        }
    }

    // MARK: Cameras

    /// The account's cameras as the page shows them, refreshed from Wyze when `refresh` (or when none are known yet).
    func cameras(refresh: Bool) async throws -> [CameraRow] {
        await loadSession()
        guard session != nil else { throw PluginProblem(description: "Sign in to your Wyze account first.") }
        if refresh || devices.isEmpty { try await sync() }
        return await rows()
    }

    func device(mac: String) -> WyzeDevice? {
        devices.first { Self.sameMAC($0.mac, mac) }
    }

    func address(mac: String) -> String? {
        addresses[Self.normalized(mac)]
    }

    private func rows() async -> [CameraRow] {
        let overview = await backend.overview()
        let added = Dictionary(overview.configurations.compactMap { config -> (String, String)? in
            guard config.integration?.service == .wyze, let mac = config.integration?.details[IntegrationSettings.Key.wyzeMAC] else { return nil }
            return (Self.normalized(mac), config.id.uuidString)
        }, uniquingKeysWith: { first, _ in first })
        let helper = overview.streamingHelperInstalled
        return devices.map { device in
            let key = Self.normalized(device.mac)
            let address = addresses[key]
            let hasRTSPFirmware = device.connection == .rtspAndLocal || device.connection == .rtspOnly
            let rtsp = !hasRTSPFirmware ? "unsupported" : (rtspOn[key] == true ? "on" : "off")
            var ways: [String] = []
            if rtsp == "on", address != nil { ways.append("rtsp") }
            let localCapable = (device.connection == .rtspAndLocal || device.connection == .localOnly) && device.p2pID != nil && device.enr != nil
            if localCapable, helper, address != nil { ways.append("local") }
            // The cloud and Gwell helper programs (`wyze-lake`, `wyze-gwell`) are offered only where this copy includes them.
            if device.connection == .cloud, device.online, helper, WyzeHelpers.isInstalled(.cloud) { ways.append("cloud") }
            if device.connection == .gwell, device.online, helper, WyzeHelpers.isInstalled(.gwell) { ways.append("gwell") }
            var note: String?
            if (device.connection == .cloud && !WyzeHelpers.isInstalled(.cloud)) || (device.connection == .gwell && !WyzeHelpers.isInstalled(.gwell)) {
                note = "This model doesn’t work with Camera Bridge yet: its video only comes through Wyze’s own connection, which Camera Bridge can’t read yet. A Wyze Cam v4, Cam v3 or Pan v3 works over RTSP."
            } else if device.connection == .cloud {
                note = device.online ? "Experimental: this model’s video only comes through Wyze’s cloud. It needs the internet for every view, is unofficial, and may stop when Wyze changes it."
                    : "Wyze says this camera is offline."
            } else if device.connection == .gwell {
                note = device.online ? "Unofficial Gwell connection: a Wyze cloud handshake each time, then video over your network. Not yet tried on a real camera of this kind."
                    : "Wyze says this camera is offline."
            } else if device.connection == .unsupported {
                note = "This model doesn’t work with Camera Bridge yet (it uses a connection Camera Bridge can’t read)."
            } else if !device.online {
                note = "Wyze says this camera is offline."
            } else if address == nil {
                note = "Camera Bridge can’t find this camera on its network. Check that it is on the same network as the bridge."
            } else if rtsp == "off" {
                note = "Turn on RTSP in the Wyze app (the camera’s settings, Advanced, RTSP) for the best connection."
                    + (ways.contains("local") ? " Until then it can use the local Wyze connection." : "")
            } else if ways.isEmpty, localCapable, !helper {
                note = "This copy of Camera Bridge OS doesn’t include the streaming helper (go2rtc) the local Wyze connection needs."
            } else if ways.isEmpty {
                note = "Update the camera’s firmware in the Wyze app, then turn on RTSP."
            }
            return CameraRow(mac: device.mac, name: device.nickname, model: device.productModel, modelName: device.modelName, firmware: device.firmware,
                             online: device.online, address: address, rtsp: rtsp, ways: ways, note: note, cameraID: added[key])
        }
    }

    // MARK: Sync

    /// Refreshes the session when it is old, lists the account's cameras, and finds where each one is on the local network.
    @discardableResult
    private func sync() async throws -> [WyzeDevice] {
        if let running { return try await running.value }
        let task = Task { try await self.syncNow() }
        running = task
        defer { running = nil }
        return try await task.value
    }

    private func syncNow() async throws -> [WyzeDevice] {
        guard var current = session else { return [] }
        do {
            if Date().timeIntervalSince(current.obtained) > Self.refreshAfter {
                current = try await cloud.refresh(current)
                try await store(current)
            }
            let listed: [WyzeDevice]
            do {
                listed = try await cloud.devices(current)
            } catch WyzeError.accessTokenExpired {
                current = try await cloud.refresh(current)
                try await store(current)
                listed = try await cloud.devices(current)
            }
            devices = listed
            await locate()
            await setState { state in
                state.lastSync = Date()
                state.lastError = nil
            }
            return listed
        } catch WyzeError.signInExpired {
            try? await store(nil)
            await setState { state in
                state.lastError = "Wyze signed Camera Bridge out. Sign in again."
            }
            throw PluginProblem(description: "Wyze signed Camera Bridge out. Sign in again.")
        } catch {
            let words = (error as? WyzeError)?.description ?? "Wyze didn’t answer."
            await setState { state in state.lastError = words }
            throw error
        }
    }

    /// Where each camera is now: its MAC in the system's neighbour table; failing that the address Wyze reports is tried, and failing that
    /// the local subnets are swept once so the table learns every host.
    private func locate() async {
        var table = NeighborTable.read() ?? ""
        // Only the cameras the bridge can connect to are looked for (a model it can't read has nothing to find).
        let wanted = devices.filter { $0.connection != .unsupported }
        var missing = wanted.filter { NeighborTable.ipv4(forMAC: $0.mac, in: table) == nil }
        if !missing.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for device in missing {
                    guard let ip = device.ip else { continue }
                    group.addTask { [backend] in _ = await backend.portAnswer(host: ip, port: 554, timeout: .milliseconds(800)) }
                }
            }
            table = NeighborTable.read() ?? table
            missing = wanted.filter { NeighborTable.ipv4(forMAC: $0.mac, in: table) == nil }
        }
        if !missing.isEmpty, NeighborTable.read() != nil {
            await sweep()
            table = NeighborTable.read() ?? table
        }
        var found: [String: String] = [:]
        for device in devices {
            // No neighbour table (not Linux): trust what Wyze reports.
            if let ip = NeighborTable.read() == nil ? device.ip : NeighborTable.ipv4(forMAC: device.mac, in: table) {
                found[Self.normalized(device.mac)] = ip
            }
        }
        addresses = found
        var rtsp: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            for device in devices where device.connection == .rtspAndLocal || device.connection == .rtspOnly {
                let key = Self.normalized(device.mac)
                guard let ip = found[key] else { continue }
                group.addTask { [backend] in (key, await backend.portAnswer(host: ip, port: 554, timeout: .milliseconds(1500)) == .answers) }
            }
            for await (key, on) in group { rtsp[key] = on }
        }
        rtspOn = rtsp
    }

    /// Touches every host of the bridge's own private IPv4 subnets (a /24 around each address) so the kernel learns their MAC addresses.
    private func sweep() async {
        let hosts = LocalSubnets.sweepTargets(addresses: await backend.localIPv4Addresses())
        guard !hosts.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for host in hosts {
                if running >= 64 { _ = await group.next(); running -= 1 }
                group.addTask { [backend] in _ = await backend.portAnswer(host: host, port: 554, timeout: .milliseconds(400)) }
                running += 1
            }
        }
    }

    /// Every six hours while signed in: keeps the session alive, and moves added Wyze cameras to their new address.
    func startSync() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: WyzePlugin.syncInterval)
                guard let self, !Task.isCancelled else { return }
                await self.backgroundSync()
            }
        }
    }

    func start() async {
        registerHelpers()
        await loadSession()
        guard session != nil else { return }
        startSync()
        await backgroundSync()
    }

    private func backgroundSync() async {
        guard (try? await sync()) != nil else { return }
        await followAddresses()
    }

    /// An added camera whose address changed is updated: an RTSP camera's address and stream addresses, a local one's go2rtc source.
    private func followAddresses() async {
        let overview = await backend.overview()
        for config in overview.configurations where config.integration?.service == .wyze {
            guard let mac = config.integration?.details[IntegrationSettings.Key.wyzeMAC], let device = device(mac: mac),
                  let address = addresses[Self.normalized(mac)] else { continue }
            var next = config
            var password: String?
            switch config.integration?.details[IntegrationSettings.Key.wyzeWay] {
            case "rtsp":
                guard config.endpoint.host != address else { continue }
                next.endpoint.host = address
                next.mainStreamURL = Self.rtspURL(host: address, path: "/stream0")
                next.subStreamURL = Self.rtspURL(host: address, path: "/stream1")
            case "local":
                guard let source = try? Go2RTCSource.wyze(device, host: address, hd: true) else { continue }
                password = source.url
            default:
                continue
            }
            do {
                try await backend.updateCamera(next, password: password)
                log.notice("a Wyze camera moved to a new address; updated")
            } catch {
                log.warning("updating a moved Wyze camera failed: \(ErrorText.logDescription(error))")
            }
        }
    }

    static func rtspURL(host: String, path: String) -> URL? {
        URL(string: "rtsp://\(host.contains(":") ? "[\(host)]" : host):554\(path)")
    }

    static func normalized(_ mac: String) -> String {
        mac.uppercased().filter { $0.isHexDigit }
    }

    static func sameMAC(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }
}

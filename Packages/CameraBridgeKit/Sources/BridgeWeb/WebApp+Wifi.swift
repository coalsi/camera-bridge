import BridgeSupport
import Foundation

// Wi-Fi: the System page's card (signed in) and the setup hotspot's page (setup.html, open while the box has no other network). The work is
// the system's (`SystemControlling`); this checks the input and, on the setup page, asks for the administrator password once there is one.

extension WebApp {
    /// A phone's captive-portal check (any name) on the setup hotspot: the setup page.
    static func captiveRedirect(to hotspot: SetupHotspot) -> HTTPResponse {
        let target = "http://\(hotspot.address)/setup.html"
        var response = HTTPResponse.text("Set up Camera Bridge: \(target)\n", status: 302, contentType: "text/plain; charset=utf-8")
        response.headers["Location"] = target
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    // MARK: Signed in

    func systemWifi() async -> HTTPResponse {
        .json(await system.wifi())
    }

    func systemWifiScan() async throws -> HTTPResponse {
        struct Networks: Encodable { var networks: [WifiNetwork] }
        do {
            return .json(Networks(networks: try await system.scanWifi()))
        } catch {
            throw systemFailure(error)
        }
    }

    private struct WifiRequest: Decodable {
        var ssid: String?
        var password: String?
        /// The setup page only: the administrator password, once the box has one.
        var adminPassword: String?
    }

    private func wifiInput(_ body: WifiRequest) throws -> (ssid: String, password: String) {
        guard let ssid = body.ssid, !ssid.isEmpty, ssid.utf8.count <= 32 else { throw APIError.badRequest("Choose the network to join.", field: "ssid") }
        let password = body.password ?? ""
        guard password.isEmpty || (8...63).contains(password.count) else {
            throw APIError.badRequest("A Wi-Fi password has 8 to 63 characters.", field: "password")
        }
        return (ssid, password)
    }

    func systemWifiJoin(_ ctx: RequestContext) async throws -> HTTPResponse {
        let input = try wifiInput(try decode(WifiRequest.self, from: ctx))
        do {
            log.notice("joining a Wi-Fi network was requested from the web interface")
            try await system.joinWifi(ssid: input.ssid, password: input.password, restart: true)
        } catch {
            throw systemFailure(error)
        }
        return .empty(202)
    }

    func systemWifiForget(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(WifiRequest.self, from: ctx)
        guard let ssid = body.ssid, !ssid.isEmpty else { throw APIError.badRequest("Choose the network to forget.", field: "ssid") }
        do {
            try await system.forgetWifi(ssid: ssid)
        } catch {
            throw systemFailure(error)
        }
        return .empty(204)
    }

    // MARK: The setup hotspot

    private struct SetupWifi: Encodable {
        var hotspot: SetupHotspot
        var networks: [WifiNetwork]
        var saved: [String]
        var lastError: String?
        /// The box already has an administrator password: the setup page asks for it.
        var needsAdminPassword: Bool
        var bridgeName: String?
    }

    private func requireHotspot() throws -> SetupHotspot {
        guard let hotspot = system.setupHotspot() else {
            throw APIError(status: 409, code: "not_in_setup", message: "The bridge is already on a network. Open http://camera-bridge.local on that network.")
        }
        return hotspot
    }

    func setupWifi() async throws -> HTTPResponse {
        let hotspot = try requireHotspot()
        let report = await system.wifi()
        return .json(SetupWifi(hotspot: hotspot, networks: report.networks, saved: report.saved, lastError: report.lastError,
                               needsAdminPassword: await auth.isConfigured, bridgeName: await auth.bridgeName))
    }

    func setupWifiJoin(_ ctx: RequestContext) async throws -> HTTPResponse {
        _ = try requireHotspot()
        let body = try decode(WifiRequest.self, from: ctx)
        let input = try wifiInput(body)
        if await auth.isConfigured {
            // Anyone near the box can join an open hotspot: once the box is set up, changing its network needs its password.
            let address = ctx.request.remoteAddress
            if let wait = await auth.loginDelay(address: address) { throw tooManyAttempts(wait) }
            guard await auth.verify(body.adminPassword ?? "") else {
                await auth.recordLogin(address: address, success: false)
                throw APIError(status: 401, code: "wrong_password", message: "That isn’t the bridge’s administrator password.", field: "adminPassword")
            }
            await auth.recordLogin(address: address, success: true)
        }
        do {
            log.notice("joining a Wi-Fi network was requested from the setup hotspot")
            try await system.joinWifi(ssid: input.ssid, password: input.password, restart: true)
        } catch {
            throw systemFailure(error)
        }
        return .empty(202)
    }
}

import BridgeEngine
import CameraAdapters
import Foundation

// Plugins (`Plugins/`): `GET plugins` lists them with their state, `PATCH plugins/:id` switches one on or off, and each has its own routes.
// The Wyze plugin's: `GET plugins/wyze` (state and cameras, `?refresh=1` asks Wyze again), `POST plugins/wyze/sign-in`
// {email, password, keyID, apiKey} → {signedIn: true} or {verification, kinds}, `POST plugins/wyze/send-code` {verification, kind},
// `POST plugins/wyze/verify` {verification, kind, code}, `POST plugins/wyze/sign-out`. The password is used for the sign-in only.
extension WebApp {
    private struct PluginItem: Encodable {
        var id: String
        var name: String
        var summary: String
        var needs: String
        var caution: String?
        var needsInternet: Bool
        var internetNote: String?
        var enabled: Bool
        var account: String?
        var lastSync: Date?
        var lastError: String?
    }

    func plugins() async throws -> HTTPResponse {
        let states = await backend.overview().settings.plugins
        let items = PluginCatalog.all.map { plugin in
            let state = states[plugin.id] ?? PluginState()
            return PluginItem(id: plugin.id, name: plugin.name, summary: plugin.summary, needs: plugin.needs, caution: plugin.caution,
                              needsInternet: plugin.needsInternet, internetNote: plugin.internetNote, enabled: state.enabled,
                              account: state.account, lastSync: state.lastSync, lastError: state.lastError)
        }
        return .json(["plugins": items])
    }

    private struct PluginPatch: Decodable { var enabled: Bool }

    func patchPlugin(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = ctx.params["id"] ?? ""
        guard PluginCatalog.descriptor(id: id) != nil else { throw APIError.notFound("There is no plugin with this name.") }
        let body = try decode(PluginPatch.self, from: ctx)
        try await backend.updateSettings { settings in
            var state = settings.plugins[id] ?? PluginState()
            state.enabled = body.enabled
            settings.plugins[id] = state
        }
        if id == EufyPlugin.id { await eufy.setEnabled(body.enabled) }
        return try await plugins()
    }

    // MARK: Wyze

    private struct WyzeState: Encodable {
        var enabled: Bool
        var signedIn: Bool
        var account: String?
        var lastSync: Date?
        var lastError: String?
        var streamingHelperInstalled: Bool
        var cameras: [WyzePlugin.CameraRow]
    }

    func wyzeState(_ ctx: RequestContext) async throws -> HTTPResponse {
        let overview = await backend.overview()
        let state = overview.settings.plugins[WyzePlugin.id] ?? PluginState()
        let signedIn = await wyze.signedIn()
        var cameras: [WyzePlugin.CameraRow] = []
        var problem: String?
        if signedIn {
            do {
                cameras = try await wyze.cameras(refresh: ctx.request.queryValue("refresh") == "1")
            } catch {
                problem = Self.wyzeWords(error)
            }
        }
        let fresh = await backend.overview().settings.plugins[WyzePlugin.id] ?? state
        return .json(WyzeState(enabled: fresh.enabled, signedIn: await wyze.signedIn(), account: fresh.account, lastSync: fresh.lastSync,
                               lastError: problem ?? fresh.lastError, streamingHelperInstalled: overview.streamingHelperInstalled, cameras: cameras))
    }

    private struct WyzeSignInBody: Decodable {
        var email: String
        var password: String
        var keyID: String
        var apiKey: String
    }

    private struct WyzeSignInAnswer: Encodable {
        var signedIn: Bool
        var verification: String?
        var kinds: [String]?
    }

    func wyzeSignIn(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(WyzeSignInBody.self, from: ctx)
        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyID = body.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = body.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.count <= 254 else { throw APIError.badRequest("Enter the email address of your Wyze account.", field: "email") }
        guard !body.password.isEmpty, body.password.count <= 256 else { throw APIError.badRequest("Enter your Wyze password.", field: "password") }
        guard !keyID.isEmpty, keyID.count <= 128 else { throw APIError.badRequest("Paste the Key ID from Wyze’s developer console.", field: "keyID") }
        guard !apiKey.isEmpty, apiKey.count <= 256 else { throw APIError.badRequest("Paste the API Key from Wyze’s developer console.", field: "apiKey") }
        do {
            switch try await wyze.signIn(email: email, password: body.password, keys: WyzeAPIKeys(keyID: keyID, apiKey: apiKey)) {
            case .signedIn:
                return .json(WyzeSignInAnswer(signedIn: true))
            case .verification(let id, let kinds):
                return .json(WyzeSignInAnswer(signedIn: false, verification: id, kinds: kinds.map(\.rawValue)))
            }
        } catch {
            throw APIError(status: 422, code: "wyze_sign_in_failed", message: Self.wyzeWords(error))
        }
    }

    private struct WyzeCodeBody: Decodable {
        var verification: String
        var kind: String
        var code: String?
    }

    func wyzeSendCode(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(WyzeCodeBody.self, from: ctx)
        guard let kind = WyzeVerification.Kind(rawValue: body.kind) else { throw APIError.badRequest("Choose how to get the code.", field: "kind") }
        do {
            try await wyze.sendCode(verificationID: body.verification, kind: kind)
            return .json(["sent": true])
        } catch {
            throw APIError(status: 422, code: "wyze_sign_in_failed", message: Self.wyzeWords(error))
        }
    }

    func wyzeVerify(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(WyzeCodeBody.self, from: ctx)
        guard let kind = WyzeVerification.Kind(rawValue: body.kind) else { throw APIError.badRequest("Choose how to get the code.", field: "kind") }
        let code = (body.code ?? "").filter { !$0.isWhitespace }
        guard (4...10).contains(code.count) else { throw APIError.badRequest("Enter the code Wyze sent you.", field: "code") }
        do {
            try await wyze.verify(verificationID: body.verification, kind: kind, code: code)
            return .json(WyzeSignInAnswer(signedIn: true))
        } catch {
            throw APIError(status: 422, code: "wyze_sign_in_failed", message: Self.wyzeWords(error))
        }
    }

    func wyzeSignOut() async throws -> HTTPResponse {
        try await wyze.signOut()
        return .json(["signedIn": false])
    }

    /// The camera the Add Camera page chose from the Wyze plugin, with its address now.
    func wyzePick(mac: String?) async throws -> WyzePick? {
        guard let mac, !mac.isEmpty else { return nil }
        guard let device = await wyze.device(mac: mac) else {
            throw SetupProblem(message: "Camera Bridge doesn’t know this Wyze camera. Open the Wyze plugin and refresh the list.", field: "wyze")
        }
        return WyzePick(device: device, address: await wyze.address(mac: mac))
    }

    static func wyzeWords(_ error: any Error) -> String {
        if let wyze = error as? WyzeError { return wyze.description }
        if let problem = error as? WyzePlugin.PluginProblem { return problem.description }
        return ErrorText.describe(error)
    }
}

/// A Wyze camera chosen on the Add Camera page (`CameraSetup.prepare`).
struct WyzePick: Sendable {
    var device: WyzeDevice
    /// Where it is on the local network now (nil: not found; the RTSP and local connections need it, the cloud one does not).
    var address: String?

    /// The address, or the sentence that says it is missing.
    func requireAddress() throws -> String {
        guard let address else {
            throw SetupProblem(message: "Camera Bridge can’t find this camera on its network. Check that it is on the same network as the bridge.", field: "wyze")
        }
        return address
    }
}

// The eufy plugin's routes: `GET plugins/eufy` (the helper's status and, signed in, the account's cameras), `POST plugins/eufy/sign-in`
// {email, password, country}, `POST plugins/eufy/captcha` {id, answer}, `POST plugins/eufy/verify` {code}, `POST plugins/eufy/sign-out`. Each
// step answers the helper's status (`state`: signedIn, needsCaptcha with `captcha`, needsCode, error with `error`). The password is passed to
// the helper for the sign-in and kept nowhere.
extension WebApp {
    private struct EufyStateAnswer: Encodable {
        var enabled: Bool
        var installed: Bool
        var status: EufyPlugin.Status
        var lastSync: Date?
        var lastError: String?
        var cameras: [EufyPlugin.CameraRow]
    }

    func eufyState() async throws -> HTTPResponse {
        let overview = await backend.overview()
        let state = overview.settings.plugins[EufyPlugin.id] ?? PluginState()
        let installed = await eufy.isInstalled()
        var status = EufyPlugin.Status.unavailable
        var problem: String?
        var cameras: [EufyPlugin.CameraRow] = []
        if state.enabled, installed {
            do {
                status = try await eufy.status()
                if status.state == "signedIn" {
                    cameras = try await eufy.rows(installed: installed, helperInstalled: overview.streamingHelperInstalled)
                }
            } catch {
                problem = Self.eufyWords(error)
            }
        }
        let fresh = await backend.overview().settings.plugins[EufyPlugin.id] ?? state
        return .json(EufyStateAnswer(enabled: fresh.enabled, installed: installed, status: status, lastSync: fresh.lastSync,
                                     lastError: problem ?? fresh.lastError, cameras: cameras))
    }

    private struct EufySignInBody: Decodable {
        var email: String
        var password: String
        var country: String?
    }

    func eufySignIn(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(EufySignInBody.self, from: ctx)
        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.count <= 254 else { throw APIError.badRequest("Enter the email address of your eufy account.", field: "email") }
        guard !body.password.isEmpty, body.password.count <= 256 else { throw APIError.badRequest("Enter your eufy password.", field: "password") }
        let country = (body.country ?? "US").uppercased().filter(\.isLetter)
        guard country.count == 2 else { throw APIError.badRequest("Choose the country of your eufy account.", field: "country") }
        guard await eufy.isInstalled() else {
            throw APIError(status: 422, code: "eufy_unavailable", message: "This copy of Camera Bridge OS doesn’t include the eufy helper.")
        }
        do {
            return .json(try await eufy.signIn(email: email, password: body.password, country: country))
        } catch {
            throw APIError(status: 422, code: "eufy_sign_in_failed", message: Self.eufyWords(error))
        }
    }

    private struct EufyCaptchaBody: Decodable {
        var id: String
        var answer: String
    }

    func eufyCaptcha(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(EufyCaptchaBody.self, from: ctx)
        let answer = body.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 32 else { throw APIError.badRequest("Type the characters in the picture.", field: "answer") }
        do {
            return .json(try await eufy.answerCaptcha(id: body.id, answer: answer))
        } catch {
            throw APIError(status: 422, code: "eufy_sign_in_failed", message: Self.eufyWords(error))
        }
    }

    private struct EufyCodeBody: Decodable { var code: String }

    func eufyVerify(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(EufyCodeBody.self, from: ctx)
        let code = body.code.filter { !$0.isWhitespace }
        guard (4...10).contains(code.count) else { throw APIError.badRequest("Enter the code eufy emailed you.", field: "code") }
        do {
            return .json(try await eufy.verify(code: code))
        } catch {
            throw APIError(status: 422, code: "eufy_sign_in_failed", message: Self.eufyWords(error))
        }
    }

    func eufySignOut() async throws -> HTTPResponse {
        do {
            return .json(try await eufy.signOut())
        } catch {
            throw APIError(status: 422, code: "eufy_failed", message: Self.eufyWords(error))
        }
    }

    /// The camera the Add Camera page chose from the eufy plugin.
    func eufyPick(serial: String?) async throws -> EufyPlugin.Device? {
        guard let serial, !serial.isEmpty else { return nil }
        guard let device = await eufy.device(serial: serial) else {
            throw SetupProblem(message: "Camera Bridge doesn’t know this eufy camera. Open the eufy plugin and check that you are signed in.", field: "eufy")
        }
        return device
    }

    static func eufyWords(_ error: any Error) -> String {
        if let problem = error as? EufyPlugin.PluginProblem { return problem.description }
        if let problem = error as? IntegrationError { return problem.message }
        return ErrorText.describe(error)
    }
}

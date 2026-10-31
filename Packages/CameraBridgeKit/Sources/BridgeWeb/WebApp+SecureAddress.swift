import Foundation

// The secure address (`SecureAddress/`): `GET system/secure-address` (the report: the switch, host, url, renewal date, problem, redirect, last
// self-test), `POST system/secure-address/enabled` {enabled} (the switch: off, the box calls nobody for it), `POST system/secure-address/redirect`
// {enabled}, `POST system/secure-address/check` (the DNS rebind self-test) and `POST system/secure-address/retry` (try for the certificate now).
extension WebApp {
    private struct SwitchBody: Decodable { var enabled: Bool }

    func secureAddressRedirect(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(SwitchBody.self, from: ctx)
        await secureAddress.setRedirect(body.enabled)
        return .json(await secureAddress.report())
    }

    func secureAddressEnabled(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(SwitchBody.self, from: ctx)
        await secureAddress.setEnabled(body.enabled)
        return .json(await secureAddress.report())
    }
}

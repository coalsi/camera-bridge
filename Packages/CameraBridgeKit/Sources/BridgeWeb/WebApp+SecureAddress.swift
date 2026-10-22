import Foundation

// The secure address (`SecureAddress/`): `GET system/secure-address` (the report: host, url, renewal date, problem, redirect, last self-test),
// `POST system/secure-address/redirect` {enabled}, `POST system/secure-address/check` (the DNS rebind self-test) and
// `POST system/secure-address/retry` (try for the certificate now).
extension WebApp {
    private struct RedirectBody: Decodable { var enabled: Bool }

    func secureAddressRedirect(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(RedirectBody.self, from: ctx)
        await secureAddress.setRedirect(body.enabled)
        return .json(await secureAddress.report())
    }
}

import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension RawHTTPStream {
    /// Opens the event stream at `target` (path and query, sent as given): on a raw connection for plain HTTP; for HTTPS (not possible
    /// on a raw connection) through URLSession, which may hold a `multipart/x-mixed-replace` part back until the next one.
    static func openEventStream(endpoint: CameraEndpoint, target: String, credentials: HTTPCredentials?, transport: any NetworkTransport,
                                readTimeout: Duration) async throws -> Opened {
        if !endpoint.useHTTPS {
            do {
                return try await open(transport: transport, host: endpoint.urlHost, port: endpoint.httpPort, target: target, credentials: credentials)
            } catch let error as CameraAdapterError {
                throw error
            } catch {
                throw CameraHTTP.sanitized(error)
            }
        }
        guard let url = URL(string: "https://\(endpoint.urlHost):\(endpoint.httpPort)\(target)") else {
            throw CameraAdapterError.invalidResponse("invalid camera address")
        }
        let client = AuthenticatingHTTPClient(credentials: credentials, timeout: readTimeout)
        do {
            let (response, body) = try await client.stream(for: URLRequest(url: url))
            var headers = HTTPHeaders()
            for (name, value) in response.allHeaderFields { headers.add("\(name)", "\(value)") }
            return Opened(status: response.statusCode, headers: headers, body: body, close: { client.invalidate() })
        } catch {
            client.invalidate()
            throw CameraHTTP.sanitized(error)
        }
    }
}

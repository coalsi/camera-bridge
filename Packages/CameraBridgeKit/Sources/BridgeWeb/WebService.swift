import BridgeSupport
import Foundation

/// The web interface running: an `HTTPServer` on the platform's transport in front of a `WebApp`. The daemon starts one next to the
/// engine; tests start one on a loopback socket.
public final class WebService: Sendable {
    public let app: WebApp
    private let server: HTTPServer

    public init(configuration: WebConfiguration, backend: any BridgeBackend, system: any SystemControlling, logs: LogFeed, transport: any NetworkTransport) {
        let app = WebApp(configuration: configuration, backend: backend, system: system, logs: logs)
        self.app = app
        server = HTTPServer(port: configuration.port, loopbackOnly: configuration.loopbackOnly, transport: transport, limits: configuration.limits) { request in
            await app.handle(request)
        }
    }

    /// Starts listening and returns the port. Once it listens the bridge is announced to Apple TVs (`WebConfiguration.viewerAdvertiser`), without
    /// the start waiting for it.
    @discardableResult
    public func start() async throws -> UInt16 {
        app.startEvents()
        do {
            let port = try await server.start()
            app.startAnnouncing(port: port)
            return port
        } catch {
            app.stopEvents()
            throw error
        }
    }

    /// Stops announcing first, then the rest: an Apple TV stops finding the bridge before it stops answering.
    public func stop() async {
        await app.stopAnnouncing()
        app.stopEvents()
        await server.stop()
    }

    public var boundPort: UInt16? {
        get async { await server.boundPort }
    }
}

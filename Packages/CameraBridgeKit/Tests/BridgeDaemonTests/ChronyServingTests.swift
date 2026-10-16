import Foundation
import Testing
@testable import BridgeDaemon

/// The daemon offers "Time from the bridge" in the camera setup only where chrony serves the local network: the OS image's own
/// configuration does, a client-only one does not.
@Suite struct ChronyServingTests {
    private static let imageConfiguration = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // Packages/CameraBridgeKit
        .deletingLastPathComponent().deletingLastPathComponent()                             // the repository
        .appending(path: "linux/os/mkosi.extra/etc/chrony/chrony.conf")

    @Test @MainActor func theImagesChronyServesTime() throws {
        let text = try String(contentsOf: Self.imageConfiguration, encoding: .utf8)
        #expect(Daemon.servesTime(chronyConfiguration: text))
    }

    @Test @MainActor func aClientOnlyConfigurationDoesNot() {
        #expect(!Daemon.servesTime(chronyConfiguration: "pool 2.debian.pool.ntp.org iburst\nport 0\n"))
        #expect(!Daemon.servesTime(chronyConfiguration: "allow 192.168.0.0/16\nport 0\n"), "port 0 turns the server off")
        #expect(!Daemon.servesTime(chronyConfiguration: "# allow 10.0.0.0/8\npool x\n"), "a comment is not an allow line")
        #expect(!Daemon.servesTime(chronyConfiguration: ""))
        #expect(Daemon.servesTime(chronyConfiguration: "allow 10.0.0.0/8\n"))
    }
}

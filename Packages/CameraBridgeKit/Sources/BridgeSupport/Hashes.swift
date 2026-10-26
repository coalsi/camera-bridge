import Crypto
import Foundation

/// Hashes from swift-crypto for modules that may not import Crypto themselves (contracts' dependency graph), so no
/// module carries a hand-written one (`PortabilityTests.noDuplicatedCryptoOrPrivateFileWriters`).
package enum Hashes {
    /// SHA-1 (FIPS 180-4). For protocols that fix it, such as the ONVIF WS-UsernameToken PasswordDigest; not for new
    /// security designs.
    package static func sha1(_ data: Data) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: data))
    }

    /// SHA-256 (FIPS 180-4), such as CameraAdapters' in-memory fingerprint of the credentials an IPCamera Web camera refused.
    package static func sha256(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    /// SHA-256 of data that arrives in pieces (a file read a chunk at a time): the NVR's check that a recording moved to the archive drive is
    /// the same as the one it came from. A local of one function (swift-crypto's `SHA256` is not `Sendable` on Linux).
    package struct StreamingSHA256 {
        private var hasher = SHA256()

        package init() {}

        package mutating func update(_ data: Data) { hasher.update(data: data) }

        package func finalize() -> [UInt8] { Array(hasher.finalize()) }
    }
}

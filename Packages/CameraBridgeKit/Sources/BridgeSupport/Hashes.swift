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
}

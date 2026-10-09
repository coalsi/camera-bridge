#if os(Linux)
import BridgeSupport
import Crypto
import Foundation
import Synchronization

/// `SecretStore` as encrypted files: each account is one file `<directory>/secrets/<SHA-256 of the account>.enc` holding
/// `version (1 byte) || AES-256-GCM combined box (nonce || ciphertext || tag)`, sealed with the account name as
/// authenticated data (a file copied over another account's fails to open). The 256-bit key is random, created on first
/// use, and lives in `<directory>/secrets/master.key` (mode 0600; Camera Bridge OS creates the same file, 32 random bytes, at
/// its first boot, and the store creates it itself when it is missing). A key at the old place, `<directory>/secrets.key`, is
/// moved there. Files are written atomically (0600 temporary file, then moved).
///
/// The key sits next to the data it protects, so this guards against a copied config file, a backup or a log bundle, not
/// against someone who can read the whole data partition; the OS image can seal the key file to the TPM on top of this.
public final class FileSecretStore: SecretStore {
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// `secrets/master.key` is not a 32-byte key (it is never replaced: that would orphan every stored secret).
        case invalidKeyFile
        /// The item cannot be opened with the key (damaged, or sealed with another key).
        case undecryptable(String)

        public var description: String {
            switch self {
            case .invalidKeyFile: "the secret store key file is damaged"
            case .undecryptable(let account): "the stored secret for \"\(account)\" cannot be decrypted"
            }
        }
    }

    static let keyFileName = "master.key"
    /// Where the key lived before the OS image defined `secrets/master.key`.
    static let legacyKeyFileName = "secrets.key"
    static let itemsDirectoryName = "secrets"
    static let version: UInt8 = 1

    private let directory: URL
    private let key = Mutex<SymmetricKey?>(nil)

    /// `directory`: the data directory; the key file and the `secrets` folder live in it.
    public init(directory: URL) {
        self.directory = directory
    }

    var keyURL: URL { itemsDirectory.appending(path: Self.keyFileName, directoryHint: .notDirectory) }
    var legacyKeyURL: URL { directory.appending(path: Self.legacyKeyFileName, directoryHint: .notDirectory) }
    var itemsDirectory: URL { directory.appending(path: Self.itemsDirectoryName, directoryHint: .isDirectory) }

    func itemURL(account: String) -> URL {
        let name = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return itemsDirectory.appending(path: name + ".enc", directoryHint: .notDirectory)
    }

    public func read(account: String) throws -> Data? {
        let url = itemURL(account: account)
        guard PrivateFiles.exists(url) else { return nil }
        let stored = try Data(contentsOf: url)
        guard stored.count >= 1 + 12 + 16, stored[stored.startIndex] == Self.version else { throw Failure.undecryptable(account) }
        do {
            let box = try AES.GCM.SealedBox(combined: stored.dropFirst())
            return try AES.GCM.open(box, using: try loadKey(create: false), authenticating: Data(account.utf8))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.undecryptable(account)
        }
    }

    public func write(_ data: Data?, account: String) throws {
        let url = itemURL(account: account)
        guard let data else {
            if PrivateFiles.exists(url) { try FileManager.default.removeItem(at: url) }
            return
        }
        let box = try AES.GCM.seal(data, using: try loadKey(create: true), authenticating: Data(account.utf8))
        guard let combined = box.combined else { throw Failure.undecryptable(account) }
        try PrivateFiles.prepareDirectory(itemsDirectory)
        try PrivateFiles.write(Data([Self.version]) + combined, to: url)
    }

    /// The key from `secrets/master.key`; created (random, 0600) when `create` and there is none yet. A key left at the old
    /// place (`secrets.key`) is moved to the new one first, so secrets written by an earlier version still open.
    private func loadKey(create: Bool) throws -> SymmetricKey {
        try key.withLock { cached in
            if let cached { return cached }
            try migrateLegacyKey()
            if PrivateFiles.exists(keyURL) {
                let raw = try Data(contentsOf: keyURL)
                guard raw.count == 32 else { throw Failure.invalidKeyFile }
                let loaded = SymmetricKey(data: raw)
                cached = loaded
                return loaded
            }
            guard create else { throw Failure.undecryptable("(no key)") }
            let fresh = SymmetricKey(size: .bits256)
            try PrivateFiles.prepareDirectory(itemsDirectory)
            try PrivateFiles.write(fresh.withUnsafeBytes { Data($0) }, to: keyURL)
            cached = fresh
            return fresh
        }
    }

    /// Moves `<directory>/secrets.key` to `secrets/master.key` when only the old one exists (an existing `master.key`, for
    /// example the image's, always wins and the old file is left alone). The bytes are copied first, so a crash in between
    /// leaves at worst both files.
    private func migrateLegacyKey() throws {
        guard !PrivateFiles.exists(keyURL), PrivateFiles.exists(legacyKeyURL) else { return }
        let raw = try Data(contentsOf: legacyKeyURL)
        guard raw.count == 32 else { return }   // damaged: leave it for the operator; a new key must not hide it
        try PrivateFiles.prepareDirectory(itemsDirectory)
        try PrivateFiles.write(raw, to: keyURL)
        try? FileManager.default.removeItem(at: legacyKeyURL)
    }
}
#endif

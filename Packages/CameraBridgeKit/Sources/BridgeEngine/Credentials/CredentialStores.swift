import BridgeSupport
import Foundation
import HAP

/// Camera passwords on top of the platform `SecretStore` (Keychain in the app, in-memory in tests).
/// Accounts are `camera.<UUID>`; HAP identities use `hap.<UUID>` through `FileHAPStore` (`HAPStorage`).
/// Passwords never go to `config.json`, logs or URLs.
public struct CredentialStore: Sendable {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public func password(for cameraID: UUID) throws -> String? {
        guard let data = try secrets.read(account: Self.account(for: cameraID)) else { return nil }
        guard let password = String(data: data, encoding: .utf8) else { throw CredentialStoreError.undecodablePassword }
        return password
    }

    /// nil deletes the stored password.
    public func setPassword(_ password: String?, for cameraID: UUID) throws {
        try secrets.write(password.map { Data($0.utf8) }, account: Self.account(for: cameraID))
    }

    /// The camera's username with its stored password (empty when none is stored); nil when the camera has neither
    /// (demo camera, open RTSP stream).
    public func credentials(for camera: CameraConfiguration) throws -> HTTPCredentials? {
        let password = try password(for: camera.id)
        if camera.username.isEmpty && password == nil { return nil }
        return HTTPCredentials(username: camera.username, password: password ?? "")
    }

    /// Removes everything secret the engine keeps for a camera: its password, the cloud sign-in its setup kept, and its HAP identity and
    /// pairing state (`HAPStorage.removeAll`). Used when the camera is removed. Each is tried even when one before it failed, so only
    /// what could not be deleted stays; the first failure is thrown.
    public func forgetCamera(_ cameraID: UUID, dataDirectory: URL) throws {
        var failure: (any Error)?
        do { try setPassword(nil, for: cameraID) } catch { failure = error }
        do { try setSetupCloudAuthcode(nil, for: cameraID) } catch { failure = failure ?? error }
        do { try HAPStorage.removeAll(for: cameraID, dataDirectory: dataDirectory, secrets: secrets) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    /// `camera.<UUID>`.
    public static func account(for cameraID: UUID) -> String {
        "camera.\(cameraID.uuidString)"
    }

    /// The sign-in value of the maker's cloud that "Set up for Camera Bridge" turned off on a camera that speaks the IP camera web API
    /// (`CameraFeatureBackup.cloudAuthcode`, which is never encoded with the configuration): kept while the setup's backup holds the
    /// cloud, to give it back with "Restore original settings".
    func setupCloudAuthcode(for cameraID: UUID) throws -> String? {
        try secrets.read(account: Self.setupCloudAccount(for: cameraID)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// nil deletes it.
    func setSetupCloudAuthcode(_ value: String?, for cameraID: UUID) throws {
        try secrets.write(value.map { Data($0.utf8) }, account: Self.setupCloudAccount(for: cameraID))
    }

    /// `camera.<UUID>.setup-cloud`.
    static func setupCloudAccount(for cameraID: UUID) -> String {
        "\(account(for: cameraID)).setup-cloud"
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    /// The stored item is not UTF-8 text.
    case undecodablePassword
}

/// Where HAP identities (device ID, setup code, Ed25519 long-term key — in the `SecretStore`) and pairing state
/// (`state.json`, 0600, in a 0700 directory) live: `hap.<UUID>` + `<data>/hap/<UUID>/` per camera,
/// `hap.sensors-bridge` + `<data>/hap/sensors-bridge/` for the sensors bridge.
public enum HAPStorage {
    public static let sensorsBridgeAccount = "hap.sensors-bridge"

    /// `hap.<UUID>`.
    public static func account(for cameraID: UUID) -> String {
        "hap.\(cameraID.uuidString)"
    }

    /// `<dataDirectory>/hap/<UUID>/`.
    public static func directory(for cameraID: UUID, in dataDirectory: URL) -> URL {
        root(in: dataDirectory).appending(path: cameraID.uuidString, directoryHint: .isDirectory)
    }

    /// `<dataDirectory>/hap/sensors-bridge/`.
    public static func sensorsBridgeDirectory(in dataDirectory: URL) -> URL {
        root(in: dataDirectory).appending(path: "sensors-bridge", directoryHint: .isDirectory)
    }

    public static func store(for cameraID: UUID, dataDirectory: URL, secrets: any SecretStore) -> FileHAPStore {
        FileHAPStore(directory: directory(for: cameraID, in: dataDirectory), secretStore: secrets, account: account(for: cameraID))
    }

    public static func sensorsBridgeStore(dataDirectory: URL, secrets: any SecretStore) -> FileHAPStore {
        FileHAPStore(directory: sensorsBridgeDirectory(in: dataDirectory), secretStore: secrets, account: sensorsBridgeAccount)
    }

    /// Deletes the camera's HAP identity and its state directory (no error when neither exists).
    public static func removeAll(for cameraID: UUID, dataDirectory: URL, secrets: any SecretStore) throws {
        try store(for: cameraID, dataDirectory: dataDirectory, secrets: secrets).deleteAll()
        let directory = directory(for: cameraID, in: dataDirectory)
        if PrivateFiles.exists(directory) { try FileManager.default.removeItem(at: directory) }
    }

    private static func root(in dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "hap", directoryHint: .isDirectory)
    }
}

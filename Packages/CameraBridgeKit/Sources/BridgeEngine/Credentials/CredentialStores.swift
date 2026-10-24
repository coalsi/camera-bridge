import BridgeSupport
import Foundation
import HAP

/// Camera passwords on top of the platform `SecretStore` (Keychain in the app, in-memory in tests).
/// Accounts are `camera.<UUID>`, and `camera.<UUID>.stream-urls` for the credentials a camera takes in its stream URLs' query or path
/// (`StreamURLCredentials`); HAP identities use `hap.<UUID>` through `FileHAPStore` (`HAPStorage`).
/// Passwords never go to `config.json`, logs or URLs; those credentials only to the RTSP request line.
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

    /// The credentials in `camera`'s stream URLs (`StreamURLCredentials`), for the addresses it still has: a stored URL whose
    /// address without credentials is no longer the camera's main or sub stream URL is left out. `.none` when nothing is stored.
    public func streamCredentials(for camera: CameraConfiguration) throws -> StreamURLCredentials {
        let stored = try storedStreamURLs(for: camera.id)
        func current(_ url: URL?, _ configured: URL?) -> URL? {
            guard let url, let configured,
                  url.removingStreamCredentials.absoluteString == configured.removingStreamCredentials.absoluteString else { return nil }
            return url
        }
        return StreamURLCredentials(main: current(stored.main, camera.mainStreamURL), sub: current(stored.sub, camera.subStreamURL))
    }

    /// `camera` as `config.json` keeps it: its stream URLs without user info and without the credentials in their query and path,
    /// which this keeps in the secret store first. A stream URL that carries credentials replaces what is stored for that stream; one
    /// without keeps what is stored when its address is the stored one's (the address shown, saved again), else that is deleted (a new
    /// address never gets them). Nothing is written when nothing changes; the item is deleted when no stream has credentials left.
    /// Throws when the secret store cannot take the credentials of a URL that carries them (nothing to save then: they are still only in
    /// `camera`); a secret store that cannot be read or written while no URL carries any is no error (all it can leave behind is a stored
    /// URL whose address the camera no longer has, which `streamCredentials(for:)` never returns).
    public func storeStreamCredentials(of camera: CameraConfiguration) throws -> CameraConfiguration {
        func next(_ url: URL?, _ old: URL?) -> URL? {
            guard let url else { return nil }
            if url.hasStreamCredentials { return url.removingUserInfo }
            guard let old, old.removingStreamCredentials.absoluteString == url.removingStreamCredentials.absoluteString else { return nil }
            return old
        }
        let carriesCredentials = camera.mainStreamURL?.hasStreamCredentials == true || camera.subStreamURL?.hasStreamCredentials == true
        do {
            let stored = try storedStreamURLs(for: camera.id)
            let kept = StreamURLCredentials(main: next(camera.mainStreamURL, stored.main), sub: next(camera.subStreamURL, stored.sub))
            if kept != stored { try writeStreamURLs(kept, for: camera.id) }
        } catch {
            if carriesCredentials { throw error }
        }
        var saved = camera
        saved.mainStreamURL = camera.mainStreamURL?.removingStreamCredentials
        saved.subStreamURL = camera.subStreamURL?.removingStreamCredentials
        return saved
    }

    /// Deletes the camera's stream URL credentials (an added camera whose configuration could not be saved).
    func forgetStreamCredentials(for cameraID: UUID) throws {
        try writeStreamURLs(.none, for: cameraID)
    }

    /// `camera.<UUID>.stream-urls`: `{"main": "<URL>", "sub": "<URL>"}`, each the stream URL with its credentials.
    public static func streamURLsAccount(for cameraID: UUID) -> String {
        "\(account(for: cameraID)).stream-urls"
    }

    private struct StoredStreamURLs: Codable {
        var main: String?
        var sub: String?
    }

    /// What is stored, whatever addresses the camera has now; an item that is not this JSON counts as none.
    private func storedStreamURLs(for cameraID: UUID) throws -> StreamURLCredentials {
        guard let data = try secrets.read(account: Self.streamURLsAccount(for: cameraID)),
              let stored = try? JSONDecoder().decode(StoredStreamURLs.self, from: data) else { return .none }
        return StreamURLCredentials(main: stored.main.flatMap(URL.init(string:)), sub: stored.sub.flatMap(URL.init(string:)))
    }

    private func writeStreamURLs(_ urls: StreamURLCredentials, for cameraID: UUID) throws {
        let data = try urls.isEmpty ? nil : JSONEncoder().encode(StoredStreamURLs(main: urls.main?.absoluteString, sub: urls.sub?.absoluteString))
        try secrets.write(data, account: Self.streamURLsAccount(for: cameraID))
    }

    /// Removes everything secret the engine keeps for a camera: its password, the credentials of its stream URLs, the cloud sign-in its
    /// setup kept, and its HAP identity and pairing state (`HAPStorage.removeAll`). Used when the camera is removed. Each is tried even
    /// when one before it failed, so only what could not be deleted stays; the first failure is thrown.
    ///
    /// `keepingHomePairing`: the camera's Apple Home identity and pairings are kept for 30 days instead (`RemovedHAPIdentities.keep`, with
    /// the camera's serial number and MAC when known), so the same camera added again keeps its place in Home; nothing of them is deleted,
    /// even when keeping them fails (they then stay where they were, and the failure is thrown).
    public func forgetCamera(_ cameraID: UUID, dataDirectory: URL, keepingHomePairing: Bool = false, serialNumber: String? = nil,
                             mac: String? = nil, now: Date = Date()) throws {
        var failure: (any Error)?
        do { try setPassword(nil, for: cameraID) } catch { failure = error }
        do { try forgetStreamCredentials(for: cameraID) } catch { failure = failure ?? error }
        do { try setSetupCloudAuthcode(nil, for: cameraID) } catch { failure = failure ?? error }
        do {
            if keepingHomePairing {
                try RemovedHAPIdentities.keep(cameraID: cameraID, serialNumber: serialNumber, mac: mac, dataDirectory: dataDirectory, secrets: secrets, now: now)
            } else {
                try HAPStorage.removeAll(for: cameraID, dataDirectory: dataDirectory, secrets: secrets)
            }
        } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    /// The Apple Home identity and pairings of the same camera removed less than 30 days ago, given to `cameraID` (being added) when it has
    /// none yet (`RemovedHAPIdentities.restore`); nil when there is none.
    public func restoreHomePairing(for cameraID: UUID, serialNumber: String?, mac: String? = nil, dataDirectory: URL,
                                   now: Date = Date()) throws -> RemovedHAPIdentity? {
        try RemovedHAPIdentities.restore(cameraID: cameraID, serialNumber: serialNumber, mac: mac, dataDirectory: dataDirectory, secrets: secrets, now: now)
    }

    /// Deletes the removed cameras' Apple Home pairings kept 30 days or longer (`RemovedHAPIdentities.sweep`); the number deleted.
    @discardableResult
    public func sweepRemovedHomePairings(dataDirectory: URL, now: Date = Date()) -> Int {
        RemovedHAPIdentities.sweep(dataDirectory: dataDirectory, secrets: secrets, now: now)
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

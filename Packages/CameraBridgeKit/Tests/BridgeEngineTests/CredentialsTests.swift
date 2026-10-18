import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import TestSupport
import Testing
@testable import BridgeEngine

@Suite(.timeLimit(.minutes(1))) struct CredentialsTests {
    @Test func httpCredentialsCombineTheUsernameWithTheStoredPassword() throws {
        let store = CredentialStore(secrets: InMemorySecretStore())
        var camera = CameraConfiguration(name: "Driveway", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.1"),
                                         username: "admin")
        #expect(CredentialStore.account(for: camera.id) == "camera.\(camera.id.uuidString)")
        #expect(try store.credentials(for: camera) == HTTPCredentials(username: "admin", password: ""))
        try store.setPassword("s3cret", for: camera.id)
        #expect(try store.credentials(for: camera) == HTTPCredentials(username: "admin", password: "s3cret"))
        camera.username = ""
        #expect(try store.credentials(for: camera) == HTTPCredentials(username: "", password: "s3cret"))
        try store.setPassword(nil, for: camera.id)
        #expect(try store.credentials(for: camera) == nil, "no username and no password: the camera needs none (demo, open RTSP)")
    }

    @Test func aStoredItemThatIsNotTextIsReportedNotReturned() throws {
        let secrets = InMemorySecretStore()
        let store = CredentialStore(secrets: secrets)
        let camera = CameraConfiguration(name: "Driveway", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.1"),
                                         username: "admin")
        try secrets.write(Data([0xFF, 0xFE, 0xC3]), account: CredentialStore.account(for: camera.id))
        #expect(throws: CredentialStoreError.undecodablePassword) { _ = try store.password(for: camera.id) }
        #expect(throws: CredentialStoreError.undecodablePassword) { _ = try store.credentials(for: camera) }
        try store.setPassword("fixed", for: camera.id)
        #expect(try store.password(for: camera.id) == "fixed")
    }

    @Test func hapIdentitiesLiveUnderPerCameraAccountsAndDirectories() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let camera = UUID()
        #expect(HAPStorage.account(for: camera) == "hap.\(camera.uuidString)")
        #expect(HAPStorage.directory(for: camera, in: directory.url) == directory.url.appending(path: "hap/\(camera.uuidString)", directoryHint: .isDirectory))
        #expect(HAPStorage.sensorsBridgeAccount == "hap.sensors-bridge")
        #expect(HAPStorage.sensorsBridgeDirectory(in: directory.url) == directory.url.appending(path: "hap/sensors-bridge", directoryHint: .isDirectory))

        let store = HAPStorage.store(for: camera, dataDirectory: directory.url, secrets: secrets)
        let identity = HAPIdentity.generate()
        try store.saveIdentity(identity)
        try store.saveState(HAPPersistentState())
        #expect(try secrets.read(account: "hap.\(camera.uuidString)") != nil)
        let stateFile = HAPStorage.directory(for: camera, in: directory.url).appending(path: "state.json")
        #expect(try posixPermissions(of: stateFile) == 0o600)
        #expect(try posixPermissions(of: HAPStorage.directory(for: camera, in: directory.url)) == 0o700)
        #expect(try HAPStorage.store(for: camera, dataDirectory: directory.url, secrets: secrets).loadIdentity()?.deviceID == identity.deviceID)

        let bridge = HAPStorage.sensorsBridgeStore(dataDirectory: directory.url, secrets: secrets)
        try bridge.saveIdentity(HAPIdentity.generate())
        #expect(try secrets.read(account: "hap.sensors-bridge") != nil)

        try HAPStorage.removeAll(for: camera, dataDirectory: directory.url, secrets: secrets)
        #expect(try secrets.read(account: "hap.\(camera.uuidString)") == nil)
        #expect(!FileManager.default.fileExists(atPath: HAPStorage.directory(for: camera, in: directory.url).path(percentEncoded: false)))
        #expect(try secrets.read(account: "hap.sensors-bridge") != nil, "other identities are untouched")
        try HAPStorage.removeAll(for: camera, dataDirectory: directory.url, secrets: secrets)   // idempotent
    }

    @Test func forgettingACameraRemovesItsPasswordAndHAPIdentity() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let credentials = CredentialStore(secrets: secrets)
        let camera = UUID(), other = UUID()
        try credentials.setPassword("a", for: camera)
        try credentials.setPassword("b", for: other)
        try HAPStorage.store(for: camera, dataDirectory: directory.url, secrets: secrets).saveIdentity(HAPIdentity.generate())
        try credentials.forgetCamera(camera, dataDirectory: directory.url)
        #expect(try credentials.password(for: camera) == nil)
        #expect(try secrets.read(account: HAPStorage.account(for: camera)) == nil)
        #expect(try credentials.password(for: other) == "b")
    }

    /// The password cannot be deleted (a locked Keychain item, say): the cloud's kept sign-in and the HAP identity are deleted anyway, and
    /// the failure is still reported.
    @Test func forgettingACameraDeletesTheRestWhenThePasswordCannotBeDeleted() throws {
        final class StuckPassword: SecretStore {
            struct DeleteRefused: Error {}
            let base = InMemorySecretStore()
            let account: String
            init(_ account: String) { self.account = account }
            func read(account: String) throws -> Data? { try base.read(account: account) }
            func write(_ data: Data?, account: String) throws {
                if data == nil, account == self.account { throw DeleteRefused() }
                try base.write(data, account: account)
            }
        }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let camera = UUID()
        let secrets = StuckPassword(CredentialStore.account(for: camera))
        let credentials = CredentialStore(secrets: secrets)
        try credentials.setPassword("a", for: camera)
        try credentials.setSetupCloudAuthcode("kept", for: camera)
        try HAPStorage.store(for: camera, dataDirectory: directory.url, secrets: secrets).saveIdentity(HAPIdentity.generate())

        #expect(throws: StuckPassword.DeleteRefused.self) { try credentials.forgetCamera(camera, dataDirectory: directory.url) }
        #expect(try credentials.setupCloudAuthcode(for: camera) == nil, "the cloud's sign-in is deleted anyway")
        #expect(try secrets.read(account: HAPStorage.account(for: camera)) == nil, "and the HAP identity")
        #expect(try credentials.password(for: camera) == "a", "only what could not be deleted stays")
    }

    // MARK: Credentials in the stream URLs' query

    static let streamPassword = "S3cretPW-7781"
    static let streamHash = "c0ffee00c0ffee00c0ffee00c0ffee00"

    static func cameraWithQueryCredentials() -> CameraConfiguration {
        var camera = CameraConfiguration(name: "Garden PTZ", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.41"),
                                         username: "admin")
        camera.mainStreamURL = URL(string: "rtsp://192.0.2.41:554/stream0?user=admin&password=\(streamPassword)&channel=1")
        camera.subStreamURL = URL(string: "rtsp://192.0.2.41:554/stream1?hash=\(streamHash)")
        return camera
    }

    @Test func queryCredentialsOfTheStreamURLsMoveToTheSecretStore() throws {
        let secrets = InMemorySecretStore()
        let store = CredentialStore(secrets: secrets)
        let camera = Self.cameraWithQueryCredentials()
        let saved = try store.storeStreamCredentials(of: camera)
        #expect(saved.mainStreamURL?.absoluteString == "rtsp://192.0.2.41:554/stream0?channel=1")
        #expect(saved.subStreamURL?.absoluteString == "rtsp://192.0.2.41:554/stream1")
        #expect(CredentialStore.streamURLsAccount(for: camera.id) == "camera.\(camera.id.uuidString).stream-urls")
        let stored = StreamURLCredentials(main: camera.mainStreamURL, sub: camera.subStreamURL)
        #expect(try store.streamCredentials(for: saved) == stored)
        #expect(try store.credentials(for: saved) == HTTPCredentials(username: "admin", password: ""), "the login is not changed by them")

        // Saved again with the same addresses (an edit that left them alone): they stay.
        #expect(try store.storeStreamCredentials(of: saved) == saved)
        #expect(try store.streamCredentials(for: saved) == stored)

        // A changed address loses its own; the other stream keeps its.
        var moved = saved
        moved.mainStreamURL = URL(string: "rtsp://192.0.2.41:554/stream0?channel=2")
        #expect(try store.storeStreamCredentials(of: moved) == moved)
        #expect(try store.streamCredentials(for: moved) == StreamURLCredentials(main: nil, sub: camera.subStreamURL))
        #expect(try store.streamCredentials(for: saved).main == nil, "never given to the old address again")

        // New credentials typed into an address replace the stored ones; none left deletes the item.
        var typed = moved
        typed.mainStreamURL = URL(string: "rtsp://192.0.2.41:554/stream0?channel=2&pwd=new")
        let retyped = try store.storeStreamCredentials(of: typed)
        #expect(retyped.mainStreamURL?.absoluteString == "rtsp://192.0.2.41:554/stream0?channel=2")
        #expect(try store.streamCredentials(for: retyped).main == typed.mainStreamURL)
        var plain = retyped
        plain.mainStreamURL = nil
        plain.subStreamURL = nil
        _ = try store.storeStreamCredentials(of: plain)
        #expect(try secrets.read(account: CredentialStore.streamURLsAccount(for: camera.id)) == nil)
    }

    @Test func aCameraWithoutQueryCredentialsTouchesNothing() throws {
        let secrets = InMemorySecretStore()
        let store = CredentialStore(secrets: secrets)
        var camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.42"), username: "")
        camera.mainStreamURL = URL(string: "rtsp://viewer:pw@192.0.2.42/live?channel=1")
        let saved = try store.storeStreamCredentials(of: camera)
        #expect(saved.mainStreamURL?.absoluteString == "rtsp://192.0.2.42/live?channel=1", "user info goes, as before")
        #expect(try store.streamCredentials(for: saved) == .none)
        #expect(try secrets.read(account: CredentialStore.streamURLsAccount(for: camera.id)) == nil)
        #expect(try store.credentials(for: saved) == nil, "still no login for an open stream")
    }

    @Test func forgettingACameraDeletesItsStreamCredentials() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let credentials = CredentialStore(secrets: secrets)
        let camera = try credentials.storeStreamCredentials(of: Self.cameraWithQueryCredentials())
        #expect(try credentials.streamCredentials(for: camera).isEmpty == false)
        try credentials.forgetCamera(camera.id, dataDirectory: directory.url)
        #expect(try secrets.read(account: CredentialStore.streamURLsAccount(for: camera.id)) == nil)
    }
}

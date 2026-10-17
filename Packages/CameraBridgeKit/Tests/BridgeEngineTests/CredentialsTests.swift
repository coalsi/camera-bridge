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
}

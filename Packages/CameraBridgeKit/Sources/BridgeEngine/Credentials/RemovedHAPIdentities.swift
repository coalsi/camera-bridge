import BridgeSupport
import Foundation
import HAP

/// What is noted beside a removed camera's kept Apple Home identity (`removed.json`): when it was removed, and what tells the same
/// camera again (its serial number and MAC, when known).
public struct RemovedHAPIdentity: Sendable, Codable, Equatable {
    public var cameraID: UUID
    public var removedAt: Date
    public var serialNumber: String?
    public var mac: String?

    public init(cameraID: UUID, removedAt: Date, serialNumber: String? = nil, mac: String? = nil) {
        self.cameraID = cameraID
        self.removedAt = removedAt
        self.serialNumber = serialNumber
        self.mac = mac
    }

    /// Whether a camera with `id`, `serialNumber` and `mac` is this one: the same id, serial number or MAC (any case, a MAC with dashes or
    /// colons), and no known value that differs (a different serial number, or a different MAC, is another camera whatever else matches).
    public func isSameCamera(id: UUID, serialNumber: String?, mac: String?) -> Bool {
        let serials = (Self.normalizedSerial(self.serialNumber), Self.normalizedSerial(serialNumber))
        let macs = (Self.normalizedMAC(self.mac), Self.normalizedMAC(mac))
        if let a = serials.0, let b = serials.1, a != b { return false }
        if let a = macs.0, let b = macs.1, a != b { return false }
        if cameraID == id { return true }
        if let a = serials.0, a == serials.1 { return true }
        if let a = macs.0, a == macs.1 { return true }
        return false
    }

    static func normalizedSerial(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return value.isEmpty ? nil : value
    }

    static func normalizedMAC(_ text: String?) -> String? {
        let value = (text ?? "").lowercased().filter(\.isHexDigit)
        return value.count == 12 && value != "000000000000" ? value : nil
    }
}

/// A removed camera's Apple Home pairing, kept for `keptFor` (30 days) so the same camera added again comes back in Home as the accessory
/// it was: removing moves `<data>/hap/<id>/` (its pairings) to `<data>/hap-removed/<id>/` with a note (`removed.json`), and its identity
/// (device ID, setup code, long-term keys) from the secret store's `hap.<id>` to `hap-removed.<id>`; nothing is deleted. Adding the same
/// camera (`RemovedHAPIdentity.isSameCamera`) within that time moves them back under the new camera's id. `sweep` deletes the entries older
/// than that (daily, from the engine).
public enum RemovedHAPIdentities {
    public static let keptFor: TimeInterval = 30 * 86_400
    static let noteName = "removed.json"
    private static let log = Log(category: "hap")

    /// `<data>/hap-removed/`.
    static func root(in dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "hap-removed", directoryHint: .isDirectory)
    }

    static func directory(for cameraID: UUID, in dataDirectory: URL) -> URL {
        root(in: dataDirectory).appending(path: cameraID.uuidString, directoryHint: .isDirectory)
    }

    /// `hap-removed.<UUID>`.
    static func account(for cameraID: UUID) -> String { "hap-removed.\(cameraID.uuidString)" }

    /// Keeps the removed camera's identity and pairings (`HAPStorage`'s) with a note of `now` and what tells the camera again. Nothing to
    /// keep (no identity, no state): nothing is written. An older entry of the same id is replaced.
    public static func keep(cameraID: UUID, serialNumber: String?, mac: String?, dataDirectory: URL, secrets: any SecretStore,
                            now: Date = Date()) throws {
        let source = HAPStorage.directory(for: cameraID, in: dataDirectory)
        let identity = try secrets.read(account: HAPStorage.account(for: cameraID))
        guard identity != nil || PrivateFiles.exists(source) else { return }
        let target = directory(for: cameraID, in: dataDirectory)
        try PrivateFiles.prepareDirectory(root(in: dataDirectory))
        if PrivateFiles.exists(target) { try FileManager.default.removeItem(at: target) }
        if let identity { try secrets.write(identity, account: account(for: cameraID)) }
        if PrivateFiles.exists(source) {
            try FileManager.default.moveItem(at: source, to: target)
        } else {
            try PrivateFiles.prepareDirectory(target)
        }
        let note = RemovedHAPIdentity(cameraID: cameraID, removedAt: now, serialNumber: RemovedHAPIdentity.normalizedSerial(serialNumber),
                                      mac: RemovedHAPIdentity.normalizedMAC(mac))
        try PrivateFiles.write(try encoder.encode(note), to: target.appending(path: noteName, directoryHint: .notDirectory))
        // The originals are now kept: the store forgets them (and its in-process copy of the identity).
        try HAPStorage.store(for: cameraID, dataDirectory: dataDirectory, secrets: secrets).deleteAll()
    }

    /// The kept entries, newest first (an entry whose note can't be read is left out).
    static func entries(in dataDirectory: URL) -> [RemovedHAPIdentity] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root(in: dataDirectory).path(percentEncoded: false))) ?? []
        return names.compactMap { name -> RemovedHAPIdentity? in
            guard let id = UUID(uuidString: name),
                  let data = try? Data(contentsOf: directory(for: id, in: dataDirectory).appending(path: noteName, directoryHint: .notDirectory)),
                  let note = try? decoder.decode(RemovedHAPIdentity.self, from: data), note.cameraID == id else { return nil }
            return note
        }.sorted { $0.removedAt > $1.removedAt }
    }

    /// Gives the camera being added (`cameraID`, with its serial number and MAC when known) the identity and pairings of the same camera
    /// removed less than `keptFor` ago, when it has none of its own yet: the entry is moved to `HAPStorage`'s places under `cameraID`. The
    /// entry of the same id wins, then the newest that matches. nil when none matches (the camera gets a new identity as before).
    @discardableResult
    public static func restore(cameraID: UUID, serialNumber: String?, mac: String?, dataDirectory: URL, secrets: any SecretStore,
                               now: Date = Date()) throws -> RemovedHAPIdentity? {
        let destination = HAPStorage.directory(for: cameraID, in: dataDirectory)
        guard try secrets.read(account: HAPStorage.account(for: cameraID)) == nil, !PrivateFiles.exists(destination) else { return nil }
        let fresh = entries(in: dataDirectory).filter { now.timeIntervalSince($0.removedAt) < keptFor && $0.removedAt <= now.addingTimeInterval(60) }
        let matching = fresh.filter { $0.isSameCamera(id: cameraID, serialNumber: serialNumber, mac: mac) }
        guard let entry = matching.first(where: { $0.cameraID == cameraID }) ?? matching.first else { return nil }
        let source = directory(for: entry.cameraID, in: dataDirectory)
        if let identity = try secrets.read(account: account(for: entry.cameraID)) {
            try secrets.write(identity, account: HAPStorage.account(for: cameraID))
        }
        let note = source.appending(path: noteName, directoryHint: .notDirectory)
        if PrivateFiles.exists(note) { try FileManager.default.removeItem(at: note) }
        try PrivateFiles.prepareDirectory(HAPStorage.directory(for: cameraID, in: dataDirectory).deletingLastPathComponent())
        try FileManager.default.moveItem(at: source, to: destination)
        try secrets.write(nil, account: account(for: entry.cameraID))
        return entry
    }

    /// Deletes the entries removed `keptFor` ago or longer (their pairings and identity), and any entry whose note can't be read and whose
    /// folder is that old. The number deleted.
    @discardableResult
    public static func sweep(dataDirectory: URL, secrets: any SecretStore, now: Date = Date()) -> Int {
        let rootURL = root(in: dataDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path(percentEncoded: false))) ?? []
        var deleted = 0
        for name in names {
            guard let id = UUID(uuidString: name) else { continue }
            let folder = directory(for: id, in: dataDirectory)
            let removedAt: Date? = (try? Data(contentsOf: folder.appending(path: noteName, directoryHint: .notDirectory)))
                .flatMap { try? decoder.decode(RemovedHAPIdentity.self, from: $0) }?.removedAt
                ?? (try? FileManager.default.attributesOfItem(atPath: folder.path(percentEncoded: false)))?[.modificationDate] as? Date
            guard let removedAt, now.timeIntervalSince(removedAt) >= keptFor else { continue }
            do {
                try secrets.write(nil, account: account(for: id))
                try FileManager.default.removeItem(at: folder)
                deleted += 1
            } catch {
                log.warning("A removed camera's kept Apple Home pairing could not be deleted: \(error)")
            }
        }
        return deleted
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import BridgeSupport
import Foundation

/// An own-pattern mp4 whose sidecar is missing, stale or untrusted: the scanner can rebuild its index.
struct RepairCandidate: Hashable, Sendable {
    var camera: UUID
    var segment: String
    /// When the mp4 was last written.
    var modified: Date
}

/// What rebuilding an index found (`IndexScanner`).
enum IndexScanOutcome: Equatable, Sendable {
    /// `wholeSize` is the size the index is for: where the last whole fragment ends (`fileSize` is larger when the file ends in a torn
    /// fragment, which repair cuts off), or the file's whole size when it is damaged in the middle.
    case indexed(CBIndexFile, wholeSize: UInt64, fileSize: UInt64)
    /// Nothing to index: the file has an init segment but not one whole fragment.
    case empty
    /// Not a file this recorder wrote, or too damaged to say anything about.
    case unusable(String)
}

/// Reads an archive folder into catalog files (Mac spec 4.1, 4.4, 4.5): every camera directory that holds a `camera.json`, its date directories
/// and the own-pattern mp4 files in them, each with the header and rollups of its sidecar (one small read per file; the fragment tables are read
/// when a lookup needs them). Blocking disk work: the store runs it on its control queue.
///
/// What is never listed, counted or deleted: symbolic links; directories and files that do not match the layout (`ArchiveLayout`); camera
/// directories without a readable `camera.json`; files whose sidecar is for another camera. A file with a missing, stale or untrusted sidecar is
/// returned in `needsRepair`, not in `files`.
enum CatalogLoader {
    struct Scan: Sendable {
        var files: [CatalogFile] = []
        var needsRepair: [RepairCandidate] = []
        /// Camera directories that could not be listed (a drive that failed halfway).
        var unreadableDirectories = 0
    }

    /// The camera a directory belongs to: `{"id": "<uuid>", "name": "<name>"}`.
    struct Manifest: Codable, Equatable, Sendable {
        var id: String
        var name: String
    }

    static func manifest(in directory: URL) -> Manifest? {
        let file = directory.appending(path: ArchiveConstants.cameraManifestName, directoryHint: .notDirectory)
        guard attributes(file)?.type == .typeRegular, let data = try? Data(contentsOf: file), data.count <= 65_536,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), UUID(uuidString: manifest.id) != nil else { return nil }
        return manifest
    }

    /// One entry of a directory listing with the attributes the scan needs, read with the listing (one pass, no call per file).
    struct Entry {
        var url: URL
        var name: String
        var isDirectory: Bool
        var isRegularFile: Bool
        var isSymbolicLink: Bool
        var size: UInt64
        var modified: Date
    }

    private static let listingKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    /// The entries of `directory`, sorted by name; nil when it cannot be listed. A symbolic link reports as one (and as neither a directory nor
    /// a regular file): it is never followed.
    static func entries(in directory: URL) -> [Entry]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: listingKeys, options: []) else { return nil }
        return urls.compactMap { url -> Entry? in
            guard let values = try? url.resourceValues(forKeys: Set(listingKeys)) else { return nil }
            let link = values.isSymbolicLink ?? false
            return Entry(url: url, name: url.lastPathComponent, isDirectory: !link && (values.isDirectory ?? false),
                         isRegularFile: !link && (values.isRegularFile ?? false), isSymbolicLink: link, size: UInt64(max(0, values.fileSize ?? 0)),
                         modified: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.name < $1.name }
    }

    static func scan(root: URL, isCancelled: () -> Bool = { false }) -> Scan {
        var scan = Scan()
        guard let cameras = entries(in: root) else {
            scan.unreadableDirectories += 1
            return scan
        }
        for camera in cameras where camera.isDirectory && !camera.name.hasPrefix(".") {
            if isCancelled() { return scan }
            guard let manifest = manifest(in: camera.url), let cameraID = UUID(uuidString: manifest.id) else { continue }
            guard let dates = entries(in: camera.url) else {
                scan.unreadableDirectories += 1
                continue
            }
            for date in dates where date.isDirectory && ArchiveLayout.isDateDirectoryName(date.name) {
                guard let files = entries(in: date.url) else { continue }
                let byName = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                for mp4 in files where mp4.isRegularFile && mp4.name.hasSuffix(".mp4") {
                    let base = String(mp4.name.dropLast(4))
                    guard ArchiveLayout.isOwnFileBaseName(base) else { continue }
                    let segment = ArchiveLayout.segment(cameraDirectory: camera.name, dateDirectory: date.name, baseName: base)
                    let sidecar = byName[base + "." + ArchiveConstants.indexExtension]
                    if sidecar?.isSymbolicLink == true { continue }   // never read, never replaced through a link
                    if let sidecar, sidecar.isRegularFile,
                       let file = load(segment: segment, sidecar: sidecar.url, sidecarSize: sidecar.size, camera: cameraID, mp4Size: mp4.size) {
                        scan.files.append(file)
                    } else {
                        scan.needsRepair.append(RepairCandidate(camera: cameraID, segment: segment, modified: mp4.modified))
                    }
                }
            }
        }
        return scan
    }

    /// The catalog file for `segment` from the header and rollups of its sidecar; nil unless the sidecar is trustworthy at this level: magic,
    /// version 1, a size that is exactly `64 + rollups x 12 + records x 40`, the same camera, and an `mp4Size` equal to the mp4's. (Each record
    /// is checked when the table is read: `CBIndexFile.decode`.)
    static func load(segment: String, sidecar: URL, sidecarSize: UInt64, camera: UUID, mp4Size: UInt64) -> CatalogFile? {
        guard sidecarSize >= UInt64(CBIndexFormat.headerLength), let handle = try? FileHandle(forReadingFrom: sidecar) else { return nil }
        defer { try? handle.close() }
        // The header and the rollups of a file of up to 80 minutes in one read.
        guard let head = try? handle.read(upToCount: Int(min(sidecarSize, 1_024))), head.count >= CBIndexFormat.headerLength else { return nil }
        var reader = ByteReader(head)
        guard let magic = try? reader.readBytes(4), magic == Data(CBIndexFormat.magic), let version = try? reader.readUInt16BE(),
              version == CBIndexFormat.version, let flags = try? reader.readUInt16BE(), let uuid = try? reader.readBytes(16),
              let startWallMs = try? reader.readUInt64BE(), let endWallMs = try? reader.readUInt64BE(), let size = try? reader.readUInt64BE(),
              let initLength = try? reader.readUInt32BE(), let count = try? reader.readUInt32BE(),
              let rollupCount = try? reader.readUInt16BE(), (try? reader.skip(6)) != nil else { return nil }
        let bytes = [UInt8](uuid)
        let fileCamera = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10],
                                     bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let start = Int64(bitPattern: startWallMs), end = Int64(bitPattern: endWallMs)
        guard Int(count) <= CBIndexFormat.maximumRecords, Int(rollupCount) <= CBIndexFormat.maximumRollups,
              sidecarSize == UInt64(CBIndexFile.byteCount(rollups: Int(rollupCount), fragments: Int(count))),
              size == mp4Size, fileCamera == camera, end >= start, UInt64(initLength) <= size else { return nil }
        let rollupBytes = Int(rollupCount) * CBIndexFormat.rollupLength
        var body = Data(head.dropFirst(CBIndexFormat.headerLength).prefix(rollupBytes))
        if body.count < rollupBytes {   // more rollups than the first read held
            guard let more = try? handle.read(upToCount: rollupBytes - body.count), body.count + more.count == rollupBytes else { return nil }
            body.append(more)
        }
        var rollups: [CBIndexRollup] = []
        rollups.reserveCapacity(Int(rollupCount))
        var rollupReader = ByteReader(body)
        for _ in 0..<rollupCount {
            guard let nonKey = try? rollupReader.readUInt32BE(), let peak = try? rollupReader.readUInt32BE(),
                  let covered = try? rollupReader.readUInt16BE(), (try? rollupReader.skip(2)) != nil else { return nil }
            rollups.append(CBIndexRollup(nonKeyBytes: nonKey, peakRate: peak, coveredMs: covered))
        }
        return CatalogFile(camera: camera, segment: segment, startMs: start, endMs: end, initLength: initLength, flags: flags, mp4Bytes: mp4Size,
                           sidecarBytes: sidecarSize, fragmentCount: Int(count), rollups: rollups, isOpen: false)
    }

    // MARK: Attributes (lstat: a symbolic link reports as one and is never followed)

    struct Attributes {
        var type: FileAttributeType
        var size: UInt64
        var modified: Date
    }

    static func attributes(_ url: URL) -> Attributes? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let type = values[.type] as? FileAttributeType else { return nil }
        let size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        return Attributes(type: type, size: size, modified: values[.modificationDate] as? Date ?? .distantPast)
    }

    static func isSymbolicLink(_ url: URL) -> Bool { attributes(url)?.type == .typeSymbolicLink }
}

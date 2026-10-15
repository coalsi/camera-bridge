import Foundation

/// Names and creates one camera's folders under the recordings folder (Mac spec 4.1): `<root>/<camera directory>/<yyyy-MM-dd>/<HH-mm-ss>.mp4`.
/// Only the camera directory and the date directory are created, one level each: the recordings folder itself is never created, so an unplugged
/// `/Volumes/X` cannot fill the startup disk. The camera directory holds `camera.json` (`{"id": …, "name": …}`), which maps it to the camera.
struct ArchiveCameraDirectory: Sendable {
    /// What a camera whose name sanitizes to nothing is called.
    static let fallbackName = "Camera"
    static let manifestLimit = 4_096
    static let maximumNameScalars = 60

    var naming: ArchivePlatformPolicy.DirectoryNaming
    var cameraID: UUID
    var cameraName: String
    var fileSystem: any RecorderFileSystem

    /// A folder name made from a camera name: control characters (NUL and DEL included), `/`, `\` and `:` become `-`; leading and trailing
    /// whitespace, leading dots and trailing dots and spaces are removed; the result has at most 60 Unicode scalars; nothing left (or only a dot)
    /// is "Camera".
    static func sanitize(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\" || scalar == ":" {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        var result = trimmed(String(scalars))
        if result.unicodeScalars.count > maximumNameScalars {
            var cut = String.UnicodeScalarView()
            cut.append(contentsOf: result.unicodeScalars.prefix(maximumNameScalars))
            result = trimmed(String(cut))
        }
        return result.isEmpty ? fallbackName : result
    }

    private static func trimmed(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }
        while let first = scalars.first, isSpace(first) || first == "." { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) || last == "." { scalars.removeLast() }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars)
        return String(result)
    }

    /// "2026-10-10", in `timeZone`.
    static func dateDirectoryName(_ date: Date, timeZone: TimeZone) -> String {
        let parts = components(date, timeZone)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "13-24-05", in `timeZone`.
    static func fileBaseName(_ date: Date, timeZone: TimeZone) -> String {
        let parts = components(date, timeZone)
        return String(format: "%02d-%02d-%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func components(_ date: Date, _ timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    // MARK: Camera directory

    private struct Manifest: Codable {
        var id: String
        var name: String
    }

    private func manifestData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Manifest(id: cameraID.uuidString, name: cameraName))
    }

    private func manifestID(of directory: URL) -> String? {
        fileSystem.read(directory.appending(path: ArchiveConstants.cameraManifestName, directoryHint: .notDirectory), limit: Self.manifestLimit)
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }?.id
    }

    /// Writes `camera.json` unless it already says the same.
    private func writeManifest(in directory: URL) throws {
        let url = directory.appending(path: ArchiveConstants.cameraManifestName, directoryHint: .notDirectory)
        let data = try manifestData()
        if fileSystem.read(url, limit: Self.manifestLimit) == data { return }
        try fileSystem.write(data, to: url)
    }

    /// The name of this camera's directory under `root`, created (with its `camera.json`) when it does not exist yet.
    /// - `.cameraID`: the camera's UUID in upper case.
    /// - `.cameraName`: the directory whose `camera.json` carries this camera's id (a rename never moves it); else the sanitized name, with
    ///   " (2)", " (3)" … when that name is taken by anything else (an empty directory is adopted).
    /// Throws `RecorderFailure.folderMissing` when `root` is not a directory.
    func resolve(root: URL) throws -> String {
        guard fileSystem.directoryExists(root) else { throw RecorderFailure.folderMissing }
        switch naming {
        case .cameraID:
            let name = cameraID.uuidString
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            if !fileSystem.directoryExists(directory) { try fileSystem.createDirectory(directory) }
            try writeManifest(in: directory)
            return name
        case .cameraName:
            for entry in try fileSystem.names(in: root) {
                let directory = root.appending(path: entry, directoryHint: .isDirectory)
                guard fileSystem.directoryExists(directory), manifestID(of: directory) == cameraID.uuidString else { continue }
                try writeManifest(in: directory)
                return entry
            }
            let base = Self.sanitize(cameraName)
            for number in 1...999 {
                let name = number == 1 ? base : "\(base) (\(number))"
                let directory = root.appending(path: name, directoryHint: .isDirectory)
                if fileSystem.itemExists(directory) {
                    guard fileSystem.directoryExists(directory), (try? fileSystem.names(in: directory))?.isEmpty == true else { continue }
                } else {
                    try fileSystem.createDirectory(directory)
                }
                try writeManifest(in: directory)
                return name
            }
            throw RecorderFailure.nameTaken
        }
    }

    // MARK: Files

    /// A new file for a recording that starts at `anchor`: the date directory is created when needed, the base name is `HH-mm-ss` (local time),
    /// `-2`, `-3` … when that second already has a file (or a sidecar). The mp4 is created, mode 0600, and returned open.
    struct NewFile {
        var segment: String
        var mp4: URL
        var index: URL
        var handle: any RecorderFileHandle
    }

    func createFile(root: URL, directory: String, anchor: Date, timeZone: TimeZone) throws -> NewFile {
        let dateName = Self.dateDirectoryName(anchor, timeZone: timeZone)
        let dateDirectory = root.appending(path: directory, directoryHint: .isDirectory).appending(path: dateName, directoryHint: .isDirectory)
        if !fileSystem.directoryExists(dateDirectory) { try fileSystem.createDirectory(dateDirectory) }
        let base = Self.fileBaseName(anchor, timeZone: timeZone)
        for number in 1...999 {
            let name = number == 1 ? base : "\(base)-\(number)"
            let mp4 = dateDirectory.appending(path: "\(name).\(ArchiveConstants.mediaExtension)", directoryHint: .notDirectory)
            let index = dateDirectory.appending(path: "\(name).\(ArchiveConstants.indexExtension)", directoryHint: .notDirectory)
            guard !fileSystem.itemExists(mp4), !fileSystem.itemExists(index) else { continue }
            let handle: any RecorderFileHandle
            do {
                handle = try fileSystem.createFile(mp4)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue                                                      // taken between the check and the create
            }
            return NewFile(segment: ArchiveLayout.segment(cameraDirectory: directory, dateDirectory: dateName, baseName: name), mp4: mp4, index: index, handle: handle)
        }
        throw RecorderFailure.nameTaken
    }
}

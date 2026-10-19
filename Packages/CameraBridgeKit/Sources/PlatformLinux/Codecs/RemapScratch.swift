import Foundation
import MediaCore

/// The picture correction as one transcoder's ffmpeg applies it: the four map images it reads (`-i`, in this order: luma x, luma y,
/// chroma x, chroma y) and the size of the picture they warp (the picture fitted inside the output, before any bars).
struct RemapStage: Equatable, Sendable {
    var xMap: String
    var yMap: String
    var chromaXMap: String
    var chromaYMap: String
    var width: Int
    var height: Int
}

/// Why a map could not be put in place: the path and the system's reason (`errno`).
struct RemapScratchError: Error, LocalizedError, CustomStringConvertible {
    var path: String
    var code: Int32

    var description: String { "\(path) could not be replaced: \(String(cString: strerror(code))) (errno \(code))" }
    var errorDescription: String? { description }
}

/// A private scratch directory holding the correction's maps (`x.pgm`, `y.pgm`, `cx.pgm`, `cy.pgm`), which ffmpeg reads once when a
/// child starts. Each map is replaced atomically, and only when it would change: the x maps when the size changes (they hold the
/// columns alone), the y maps when the correction or the size changes (a 1920 × 852 set is about 16 MB), and any map that is no
/// longer there (a temporary-files cleaner may remove the files or the directory).
final class RemapScratch: @unchecked Sendable {
    let directory: URL
    let xMap: URL
    let yMap: URL
    let chromaXMap: URL
    let chromaYMap: URL
    private let lock = NSLock()

    /// What the files hold: the size for the x maps, the correction and size for the y maps (nil: unknown, written next time).
    private struct Written: Equatable {
        var correction: PictureCorrection?
        var width: Int
        var height: Int
    }
    private var columns: Written?
    private var rows: Written?

    init(parent: URL?) throws {
        let base = parent ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("camera-bridge-remap-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        xMap = directory.appendingPathComponent("x.pgm")
        yMap = directory.appendingPathComponent("y.pgm")
        chromaXMap = directory.appendingPathComponent("cx.pgm")
        chromaYMap = directory.appendingPathComponent("cy.pgm")
    }

    deinit { remove() }

    /// The maps for `correction` on a `width × height` picture, writing those the files do not already hold.
    func stage(for correction: PictureCorrection, width: Int, height: Int) throws -> RemapStage {
        lock.lock()
        defer { lock.unlock() }
        let stage = RemapStage(xMap: xMap.path, yMap: yMap.path, chromaXMap: chromaXMap.path, chromaYMap: chromaYMap.path, width: width, height: height)
        let size = Written(correction: nil, width: width, height: height)
        let corrected = Written(correction: correction, width: width, height: height)
        let columnsCurrent = columns == size && exists(xMap) && exists(chromaXMap)
        let rowsCurrent = rows == corrected && exists(yMap) && exists(chromaYMap)
        if columnsCurrent && rowsCurrent { return stage }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let maps = correction.remapMaps(width: width, height: height)
        if !columnsCurrent {
            columns = nil
            try replace(xMap, with: maps.x)
            try replace(chromaXMap, with: maps.chromaX)
            columns = size
        }
        if !rowsCurrent {
            rows = nil
            try replace(yMap, with: maps.y)
            try replace(chromaYMap, with: maps.chromaY)
            rows = corrected
        }
        return stage
    }

    private func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    private func replace(_ file: URL, with data: Data) throws {
        let temporary = directory.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".tmp")
        try data.write(to: temporary)
        // rename(2) replaces the destination atomically.
        guard rename(temporary.path, file.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw RemapScratchError(path: file.path, code: code)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

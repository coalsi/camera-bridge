import AppKit
import CoreImage
import CoreVideo
import SwiftUI
import UniformTypeIdentifiers

/// Saves the picture on screen as a JPEG: the displayed frame (no second decode: the display layer hands it back), a save
/// panel starting in Downloads.
@MainActor
enum SnapshotSaver {
    /// JPEG data (quality 0.9) of a decoded picture.
    static func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace else { return nil }
        return CIContext().jpegRepresentation(of: image, colorSpace: colorSpace,
                                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
    }

    /// JPEG data of an image the app already holds (the last snapshot), for a viewer that has no live picture yet.
    static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// Asks where to save and writes the file. Returns the saved location, nil when the person cancelled; throws when the file
    /// could not be written.
    static func save(_ data: Data, suggestedName: String) async throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        }
        guard response == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }
}

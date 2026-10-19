import Foundation
import Testing

@Suite struct ClipDestinationsTests {
    @Test func aPanelWithoutAFolderToStartInOpensInDownloads() throws {
        let downloads = try #require(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        #expect(PanelClipDestinations.startFolder(nil) == downloads, "the first time, and when the last folder is gone: Downloads, never the recordings folder")
        let folder = URL(filePath: "/Users/Shared/Clips", directoryHint: .isDirectory)
        #expect(PanelClipDestinations.startFolder(folder) == folder, "otherwise the folder of the last clip")
    }
}

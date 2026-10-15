import Foundation

// The NVR's public facade beyond what BridgeEngine.swift declares (`archive`, `nvrStorage`, `setNVR`, and the hook points that call
// `nvr`). Task T00 owns this file; the store and the recorders live in BridgeEngine/NVR/.

extension BridgeEngine {
    /// Checks that `url` can hold recordings (see `ArchiveFolderCheck`) with this engine's platform policy. The probe runs off the main
    /// actor; this only hops to read the environment. Callers ask before they save a folder (`updateSettings`).
    public func inspectArchiveFolder(_ url: URL) async throws -> ArchiveFolderReport {
        try await ArchiveFolderCheck.inspect(url, policy: environment.archivePolicy, dataDirectory: environment.dataDirectory)
    }
}

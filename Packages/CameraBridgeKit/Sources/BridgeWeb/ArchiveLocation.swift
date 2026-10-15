import Foundation

/// A place the web interface offers for recordings. `id` is what the page sends back (`PATCH /api/v1/nvr/storage { location }`); the browser
/// never sends a path. `path` is the folder on the bridge (shown to the person, never accepted from the network). BridgeDaemon builds the list.
public struct ArchiveLocation: Sendable, Equatable {
    public var id: String
    public var label: String
    public var path: String

    public init(id: String, label: String, path: String) {
        self.id = id
        self.label = label
        self.path = path
    }
}

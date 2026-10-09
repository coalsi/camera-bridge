import Foundation
import Synchronization
import TestSupport

/// Reads `Tests/CameraAdaptersTests/Fixtures/<name>` (no SwiftPM resources; path relative to this file).
func fixture(_ name: String) throws -> Data {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: directory.appending(path: "Fixtures").appending(path: name))
}

func fixtureText(_ name: String) throws -> String {
    String(decoding: try fixture(name), as: UTF8.self)
}

/// Consumes a stream in the background and records every element, so tests can wait for conditions.
final class Recorder<Element: Sendable>: Sendable {
    private let storage = Box<[Element]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<Element>) {
        let handle = Task { [storage] in
            for await element in stream { storage.update { $0.append(element) } }
        }
        task.withLock { $0 = handle }
    }

    var values: [Element] { storage.value }

    /// Polls until `condition` holds or `timeout` elapses; returns whether it held.
    @discardableResult
    func wait(timeout: Duration = .seconds(5), until condition: ([Element]) -> Bool) async -> Bool {
        await eventually(timeout: timeout) { condition(values) }
    }

    func cancel() { task.withLock { $0?.cancel() } }
}

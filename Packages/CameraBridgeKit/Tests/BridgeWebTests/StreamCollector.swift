import Foundation
import Synchronization
import TestSupport
@testable import BridgeWeb

/// Runs a streaming answer's body and collects what it writes.
final class StreamCollector: Sendable {
    let response: HTTPResponse
    private let chunks = Box<[String]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)
    let finished = Box(false)

    init(_ response: HTTPResponse) {
        self.response = response
        guard case .stream(let body) = response.body else { return }
        let chunks = chunks, finished = finished
        let sink = ResponseStream { data in chunks.update { $0.append(String(decoding: data, as: UTF8.self)) } }
        let task = Task {
            try? await body(sink)
            finished.set(true)
        }
        self.task.withLock { $0 = task }
    }

    var text: String { chunks.value.joined() }

    /// Waits until `predicate` holds for the text written so far.
    func wait(timeout: Duration = .seconds(5), _ predicate: (String) -> Bool) async -> Bool {
        await eventually(timeout: timeout) { predicate(text) }
    }

    /// The `data:` payloads of the events named `name`, parsed.
    func events(_ name: String) -> [[String: Any]] {
        text.components(separatedBy: "\n\n").compactMap { block -> [String: Any]? in
            let lines = block.split(separator: "\n").map(String.init)
            guard lines.contains("event: \(name)"), let data = lines.first(where: { $0.hasPrefix("data: ") }) else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(data.dropFirst(6).utf8))) as? [String: Any]
        }
    }

    func stop() {
        task.withLock { $0?.cancel() }
    }
}

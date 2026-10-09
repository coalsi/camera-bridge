#if os(macOS)
import Dispatch

/// Runs a codec object's blocking work (a synchronous VideoToolbox decode, encode or CompleteFrames call takes
/// milliseconds) on the object's own serial queue, so async callers never hold a Swift-concurrency cooperative
/// thread while VideoToolbox works. Calls run in submission order.
struct CodecWorkQueue: Sendable {
    private let queue: DispatchQueue

    /// `qos`: `.userInitiated` for a stream's own codecs; `.utility` for a check that must never compete with them.
    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func run<Output: Sendable>(_ work: @escaping @Sendable () throws -> Output) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
#endif

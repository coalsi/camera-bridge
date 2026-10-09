import Foundation

// Helper processes: a bundled program (go2rtc) that the app starts, watches and stops. Portable modules reach the OS only
// through these protocols (contracts: portability rule); PlatformApple implements them on macOS with `Process`, a Linux
// edition will bring its own.

/// What to start.
public struct HelperLaunchSpec: Sendable, Equatable {
    /// The program, an absolute file URL (`HelperLaunching.locate`).
    public var executable: URL
    public var arguments: [String]
    /// Added to the helper's environment (which otherwise holds nothing of the app's: no secrets leak into it by accident).
    public var environment: [String: String]
    public var workingDirectory: URL?
    /// A file the launcher keeps the helper's process ID in while it runs, so a copy left behind by a crashed app is found
    /// and ended before the next start (`HelperLaunching.endStaleProcess`). nil: none.
    public var pidFile: URL?

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:], workingDirectory: URL? = nil, pidFile: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.pidFile = pidFile
    }
}

/// How a helper ended.
public struct HelperExit: Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable { case exited, signaled }

    public var status: Int32
    public var reason: Reason

    public init(status: Int32, reason: Reason = .exited) {
        self.status = status
        self.reason = reason
    }

    public var description: String {
        switch reason {
        case .exited: "exit status \(status)"
        case .signaled: "signal \(status)"
        }
    }
}

/// One running helper. Output is the helper's standard output and error, line by line.
public protocol HelperProcess: AnyObject, Sendable {
    var processID: Int32? { get }
    /// Its output lines (UTF-8, newline stripped, long lines cut). Single consumer; finishes when the helper ended and its
    /// output is drained.
    var output: AsyncStream<String> { get }
    /// Returns once the helper ended (immediately when it already did). May be called any number of times.
    func waitUntilExit() async -> HelperExit
    /// Asks it to end (SIGTERM). Idempotent.
    func terminate()
    /// Ends it now (SIGKILL). Idempotent.
    func kill()
}

public enum HelperLaunchError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The platform cannot run helpers (or this one is not installed).
    case unavailable(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .unavailable(let message), .launchFailed(let message): message
        }
    }
}

public protocol HelperLaunching: Sendable {
    /// Where the helper called `name` is installed (the app bundle's Helpers folder, or a development override); nil when it
    /// is not there.
    func locate(_ name: String) -> URL?
    func launch(_ spec: HelperLaunchSpec) throws -> any HelperProcess
    /// Ends a helper that an earlier run of the app left behind, using the process ID in `pidFile` (only when that process is
    /// still `executable`), and removes the file. Returns whether one was ended. Never throws.
    @discardableResult
    func endStaleProcess(pidFile: URL, executable: URL) -> Bool
}

/// Runs nothing: platforms (and tests) without helpers. `locate` finds nothing.
public final class NullHelperLauncher: HelperLaunching {
    public init() {}

    public func locate(_ name: String) -> URL? { nil }

    public func launch(_ spec: HelperLaunchSpec) throws -> any HelperProcess {
        throw HelperLaunchError.unavailable("helper programs are not available on this platform")
    }

    public func endStaleProcess(pidFile: URL, executable: URL) -> Bool { false }
}

/// Cuts a helper's output line to a length fit for a log.
public enum HelperOutput {
    public static let maximumLineLength = 2_000

    public static func clipped(_ line: String) -> String {
        line.count > maximumLineLength ? String(line.prefix(maximumLineLength)) + "…" : line
    }

    /// Splits a byte stream into lines, keeping the unfinished tail between calls (`feed`). Invalid UTF-8 is replaced.
    public struct LineSplitter: Sendable {
        private var pending = Data()
        private let limit: Int

        public init(limit: Int = 64 * 1024) {
            self.limit = limit
        }

        public mutating func feed(_ data: Data) -> [String] {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                var line = pending[pending.startIndex..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                lines.append(HelperOutput.clipped(String(decoding: line, as: UTF8.self)))
                pending = Data(pending[pending.index(after: newline)...])
            }
            if pending.count > limit {   // a helper that never ends a line must not grow this without bound
                lines.append(HelperOutput.clipped(String(decoding: pending, as: UTF8.self)))
                pending = Data()
            }
            return lines
        }

        /// The unfinished last line, when the stream ended.
        public mutating func finish() -> String? {
            defer { pending = Data() }
            return pending.isEmpty ? nil : HelperOutput.clipped(String(decoding: pending, as: UTF8.self))
        }
    }
}

import BridgeEngine
import BridgeSupport
import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Facts about the machine for the diagnostics report.
enum HostInfo {
    /// "Debian GNU/Linux 13 (trixie)" from `/etc/os-release`, else what Foundation says.
    static func operatingSystemName() -> String {
        #if os(Linux)
        if let text = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
                return line.dropFirst("PRETTY_NAME=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
        }
        #endif
        return ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// The board or machine model ("Raspberry Pi 5 Model B", "N100 mini PC"), "unknown" when the system does not say.
    static func hardwareModel() -> String {
        #if os(Linux)
        for path in ["/sys/firmware/devicetree/base/model", "/sys/devices/virtual/dmi/id/product_name", "/sys/devices/virtual/dmi/id/board_name"] {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let model = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0\n ")).trimmingCharacters(in: .whitespacesAndNewlines)
                if !model.isEmpty { return model }
            }
        }
        return "unknown"
        #else
        return "development Mac"
        #endif
    }
}

/// Signals the daemon reacts to, as a stream. SIGTERM and SIGINT end the daemon; SIGHUP and SIGPIPE are ignored.
final class SignalWatcher: @unchecked Sendable {
    let signals: AsyncStream<Int32>
    private var sources: [any DispatchSourceSignal] = []

    init(_ handled: [Int32] = [SIGTERM, SIGINT]) {
        var created: [any DispatchSourceSignal] = []
        var continuation: AsyncStream<Int32>.Continuation!
        signals = AsyncStream { continuation = $0 }
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        for number in handled {
            signal(number, SIG_IGN)   // the dispatch source sees the signal; the default action must not run
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            let sink = continuation!
            source.setEventHandler { sink.yield(number) }
            source.resume()
            created.append(source)
        }
        sources = created
    }

    deinit {
        for source in sources { source.cancel() }
    }
}

/// `camerabridged`'s whole life: parse, start, tell systemd, wait for a signal, stop.
public enum DaemonMain {
    /// Returns the process exit status: 0 after a requested stop, 1 when it could not start, 2 for a bad command line.
    @MainActor
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        let options: DaemonOptions
        do {
            options = try DaemonOptions.parse(arguments: arguments, environment: environment)
        } catch {
            Console.error("camerabridged: \(error)")
            return 2
        }
        if options.showHelp {
            Console.print(DaemonOptions.usage)
            return 0
        }
        if options.showVersion {
            Console.print("\(DaemonInfo.product) \(DaemonInfo.version) (\(DaemonInfo.build(environment: environment)))")
            return 0
        }

        let watcher = SignalWatcher()
        let daemon = Daemon(options: options, environment: environment)
        let port: UInt16
        do {
            port = try await daemon.start()
        } catch {
            Console.error("camerabridged: \(error)")
            SystemD.notify("STATUS=\(error)\nERRNO=1", environment: environment)
            await daemon.stop()
            return 1
        }
        SystemD.notify("READY=1\nSTATUS=Running; the web interface is on port \(port)", environment: environment)
        let watchdog = watchdogTask(daemon: daemon, environment: environment)

        var received: Int32 = 0
        for await signal in watcher.signals {
            if received != 0 {
                Console.error("camerabridged: stopping right now")
                exit(1)
            }
            received = signal
            Console.print("camerabridged: \(signal == SIGINT ? "interrupted" : "terminated"), shutting down")
            break
        }
        SystemD.notify("STOPPING=1\nSTATUS=Shutting down", environment: environment)
        watchdog?.cancel()
        // A second signal while stopping ends the process at once.
        let impatient = Task.detached {
            for await _ in watcher.signals { exit(1) }
        }
        await daemon.stop()
        impatient.cancel()
        return 0
    }

    /// Tells systemd the daemon is alive while it is healthy (`WatchdogSec=`); nothing when there is no watchdog.
    @MainActor
    private static func watchdogTask(daemon: Daemon, environment: [String: String]) -> Task<Void, Never>? {
        guard let interval = SystemD.watchdogInterval(environment: environment) else { return nil }
        return Task { @MainActor in
            while !Task.isCancelled {
                if await daemon.isHealthy() { SystemD.notify("WATCHDOG=1", environment: environment) }
                try? await Task.sleep(for: interval)
            }
        }
    }
}

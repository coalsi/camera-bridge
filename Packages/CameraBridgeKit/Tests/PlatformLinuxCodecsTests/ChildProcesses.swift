import Foundation

/// Looks at this test process's own children with `ps` (macOS and Linux): how many run a command containing some text, kill
/// them, and which ones are zombies.
enum ChildProcesses {
    struct Entry {
        var pid: Int32
        var parent: Int32
        var state: String
        var command: String
    }

    static func list() -> [Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-ww", "-o", "pid=,ppid=,stat=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let me = getpid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard columns.count >= 3, let pid = Int32(columns[0]), let parent = Int32(columns[1]), parent == me else { return nil }
            return Entry(pid: pid, parent: parent, state: String(columns[2]), command: columns.count > 3 ? String(columns[3]) : "")
        }
    }

    static func count(commandContaining text: String) -> Int {
        list().filter { $0.command.contains(text) && !$0.state.hasPrefix("Z") }.count
    }

    /// SIGKILLs the live children whose command contains `text`; returns how many.
    @discardableResult
    static func kill(commandContaining text: String) -> Int {
        let targets = list().filter { $0.command.contains(text) && !$0.state.hasPrefix("Z") }
        for target in targets { _ = Foundation.kill(target.pid, SIGKILL) }
        return targets.count
    }

    /// Zombie children (ended, not reaped), optionally only those whose command contains `text`.
    static func zombies(commandContaining text: String? = nil) -> [String] {
        list().filter { $0.state.hasPrefix("Z") && (text.map($0.command.contains) ?? true) }.map { "\($0.pid) \($0.state) \($0.command)" }
    }
}

// hangshim-selftest: proves that hangshim really stops the file calls Camera Bridge makes (Foundation's FileManager and FileHandle), before
// a hung-volume test relies on it. A test that passes because the shim silently intercepted nothing is worse than no test.
//
//   cc -O2 -Wall -dynamiclib -o hangshim.dylib hangshim.c                                      (Linux: see hangshim.c)
//   swiftc -O -o hangshim-selftest hangshim-selftest.swift
//   CB_HANG_ROOT=$ROOT CB_HANG_FLAG=$FLAG CB_HANG_LOG=$LOG DYLD_INSERT_LIBRARIES=$PWD/hangshim.dylib ./hangshim-selftest $ROOT $FLAG
//
// It makes ROOT, starts one thread per operation (create directory, create and write a file, fsync, read it back, file exists, volume
// space), creates the flag file, and checks that every thread stops making progress and that a thread working OUTSIDE ROOT does not;
// then removes the flag and checks that every thread goes on. Exit status 0 only if all of that held.
import Foundation

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { print("usage: hangshim-selftest ROOT FLAG"); exit(2) }
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
let flag = arguments[2]
let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(getpid())", isDirectory: true)
let fileManager = FileManager.default
try? fileManager.removeItem(atPath: flag)
try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)

let names = ["createDirectory", "writeFile", "synchronize", "readFile", "fileExists", "volumeSpace", "outsideRoot"]
let counters = Dictionary(uniqueKeysWithValues: names.map { ($0, Counter()) })
let stopAll = Counter()   // bumped once to stop the threads

func spawn(_ name: String, _ body: @escaping @Sendable (Int) throws -> Void) {
    let counter = counters[name]!
    Thread.detachNewThread {
        var i = 0
        while stopAll.count == 0 {
            do { try body(i) } catch { /* an error is still progress: the call returned */ }
            counter.bump()
            i += 1
            usleep(2_000)
        }
    }
}

let data = Data(repeating: 0x5a, count: 4096)
let writePath = root.appendingPathComponent("w.bin").path
let readPath = root.appendingPathComponent("r.bin").path
_ = fileManager.createFile(atPath: readPath, contents: data)
let syncHandle = try { () throws -> FileHandle in
    _ = fileManager.createFile(atPath: root.appendingPathComponent("s.bin").path, contents: nil)
    return try FileHandle(forWritingTo: root.appendingPathComponent("s.bin"))
}()

spawn("createDirectory") { i in try fileManager.createDirectory(at: root.appendingPathComponent("d\(i % 50)", isDirectory: true), withIntermediateDirectories: false) }
spawn("writeFile") { _ in try data.write(to: URL(fileURLWithPath: writePath)) }
spawn("synchronize") { _ in try syncHandle.write(contentsOf: data); try syncHandle.synchronize() }
spawn("readFile") { _ in let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: readPath)); defer { try? h.close() }; _ = try h.read(upToCount: 1024) }
spawn("fileExists") { _ in _ = fileManager.fileExists(atPath: readPath) }
spawn("volumeSpace") { _ in _ = try fileManager.attributesOfFileSystem(forPath: root.path) }
spawn("outsideRoot") { i in try data.write(to: outside.appendingPathComponent("o\(i % 5).bin")) }

func snapshot() -> [String: Int] { Dictionary(uniqueKeysWithValues: names.map { ($0, counters[$0]!.count) }) }
func wait(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

wait(1.0)
let running = snapshot()
var failures: [String] = []
for name in names where running[name]! < 5 { failures.append("\(name) made no progress before the flag (\(running[name]!) calls)") }

_ = fileManager.createFile(atPath: flag, contents: Data())
wait(1.0)                       // let calls already past the gate finish
let hungStart = snapshot()
wait(2.0)
let hungEnd = snapshot()
var stalled: [String] = [], progressed: [String] = []
for name in names {
    if hungEnd[name]! - hungStart[name]! <= 1 { stalled.append(name) } else { progressed.append(name) }
}
for name in names where name != "outsideRoot" && !stalled.contains(name) { failures.append("\(name) was NOT stopped by the shim (\(hungEnd[name]! - hungStart[name]!) calls in 2 s)") }
if stalled.contains("outsideRoot") { failures.append("outsideRoot was stopped: the shim hung a path outside ROOT") }

try fileManager.removeItem(atPath: flag)
wait(1.5)
let resumed = snapshot()
for name in names where name != "outsideRoot" && resumed[name]! - hungEnd[name]! < 3 { failures.append("\(name) did not resume after the flag was removed") }

stopAll.bump()
wait(0.3)
try? fileManager.removeItem(at: outside)
print("stalled while hung:   \(stalled.sorted().joined(separator: ", "))")
print("progressed while hung: \(progressed.sorted().joined(separator: ", "))")
if failures.isEmpty {
    print("SELFTEST PASS")
    exit(0)
}
for failure in failures { print("SELFTEST FAIL: \(failure)") }
exit(1)

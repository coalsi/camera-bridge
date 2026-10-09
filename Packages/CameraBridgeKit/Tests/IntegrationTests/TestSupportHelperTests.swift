import Foundation
import TestSupport
import Testing

/// TestSupport's `Box`, `eventually` and `TemporaryDirectory`, the one copy every test target uses
/// (PortabilityTests.SharedTestHelperTests keeps them from being redefined). The copies they replace took sync or
/// async, `@Sendable` or plain conditions; the shared ones accept all of those. The in-memory transport
/// (`FakeNetworkTransport`) is covered by HAPCameraTests' `FakeTransportTests` and the HDS tests that run over it.
@Suite(.timeLimit(.minutes(1))) struct TestSupportHelperTests {
    @Test func temporaryDirectoryIsCreatedUniqueListedAndRemoved() throws {
        let first = try TemporaryDirectory(prefix: "cb-helper")
        let second = try TemporaryDirectory(prefix: "cb-helper")
        defer {
            first.remove()
            second.remove()
        }
        #expect(first.url != second.url)
        #expect(first.url.lastPathComponent.hasPrefix("cb-helper-"))
        #expect(first.url.path(percentEncoded: false).hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false)))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: first.url.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(first.contents() == [])

        try Data("b".utf8).write(to: first.file("b.txt"))
        try Data("a".utf8).write(to: first.file("a.txt"))
        #expect(first.file("a.txt").deletingLastPathComponent().lastPathComponent == first.url.lastPathComponent)
        #expect(first.contents() == ["a.txt", "b.txt"])

        first.remove()
        #expect(!FileManager.default.fileExists(atPath: first.url.path(percentEncoded: false)))
        #expect(first.contents() == [])
        first.remove()   // already gone: no error
        #expect(FileManager.default.fileExists(atPath: second.url.path(percentEncoded: false)))

        let made = try TestSupportModule.makeTemporaryDirectory(prefix: "cb-helper")
        defer { try? FileManager.default.removeItem(at: made) }
        #expect(made.lastPathComponent.hasPrefix("cb-helper-"))
        #expect(FileManager.default.fileExists(atPath: made.path(percentEncoded: false)))
    }

    @Test func boxReadsSetsAndUpdatesUnderItsLock() async {
        let box = Box(0)
        #expect(box.value == 0)
        box.set(5)
        #expect(box.update { value -> Int in value += 1; return value * 10 } == 60)
        #expect(box.value == 6)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { box.update { $0 += 1 } } }
        }
        #expect(box.value == 106)
    }

    @Test func eventuallyReturnsOnceTheConditionHolds() async {
        let box = Box(false)
        let started = ContinuousClock.now
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            box.set(true)
        }
        #expect(await eventually { box.value })
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func eventuallyGivesUpAfterTheTimeout() async {
        let polls = Box(0)
        let started = ContinuousClock.now
        let held = await eventually(timeout: .milliseconds(100)) {
            polls.update { $0 += 1 }
            return false
        }
        let elapsed = ContinuousClock.now - started
        #expect(!held)
        #expect(elapsed >= .milliseconds(100) && elapsed < .seconds(2))
        // Polled during the wait and once more at the deadline.
        #expect(polls.value >= 2)
    }

    @Test func eventuallyPollsAtTheGivenInterval() async {
        let polls = Box(0)
        _ = await eventually(timeout: .milliseconds(200), every: .milliseconds(50)) {
            polls.update { $0 += 1 }
            return false
        }
        // About 4 polls in the wait plus the final check; at the 10 ms default it would be about 20.
        #expect((2...6).contains(polls.value), "\(polls.value) polls in 200 ms at 50 ms")
    }

    @Test func eventuallyTakesSyncAsyncAndNonSendableConditions() async {
        let actor = Counter()
        var localPolls = 0   // non-Sendable state: the condition is neither escaping nor `@Sendable`
        #expect(await eventually { localPolls += 1; return localPolls >= 3 })
        #expect(await eventually { await actor.increment() >= 3 })
        let sendable: @Sendable () -> Bool = { true }
        #expect(await eventually(sendable))
    }

    @MainActor @Test func eventuallyReadsTheCallersActorState() async {
        let model = MainActorModel()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            model.isReady = true
        }
        #expect(await eventually {
            MainActor.assertIsolated()
            return model.isReady
        })
    }
}

@MainActor private final class MainActorModel {
    var isReady = false
}

private actor Counter {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

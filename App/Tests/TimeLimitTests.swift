import Foundation
import Testing

/// Quit stops the engine for at most `AppModel.terminationTimeLimit`, even when the engine ignores cancellation.
@Suite(.timeLimit(.minutes(1))) struct TimeLimitTests {
    /// A task group would wait for the stuck operation (it only opens after `run` returns), so this would never finish.
    @Test func returnsAtTheDeadlineWhenTheOperationIgnoresCancellation() async {
        let gate = Gate()
        let finishedWork = Gate()
        let sawCancellation = Box(false)
        let inTime = await TimeLimit.run(.milliseconds(50)) {
            await gate.wait()
            sawCancellation.value = Task.isCancelled
            finishedWork.open()
        }
        #expect(!inTime)
        gate.open()
        await finishedWork.wait()
        #expect(sawCancellation.value)   // the late operation was asked to stop
    }

    @Test func returnsAsSoonAsTheOperationFinishes() async {
        let clock = ContinuousClock()
        let ran = Box(false)
        var inTime = false
        let elapsed = await clock.measure {
            inTime = await TimeLimit.run(.seconds(30)) { ran.value = true }
        }
        #expect(inTime && ran.value)
        #expect(elapsed < .seconds(10))
    }

    @Test func quitWaitsAtMostFiveSeconds() {
        #expect(AppModel.terminationTimeLimit == .seconds(5))
    }
}

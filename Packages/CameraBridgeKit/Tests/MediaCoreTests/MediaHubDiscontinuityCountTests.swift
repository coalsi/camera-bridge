import Foundation
import Testing
@testable import MediaCore

@Suite struct MediaHubDiscontinuityCountTests {
    @Test func countsEveryDiscontinuityAndIsReadableWithoutAwaiting() async {
        let hub = MediaHub()
        #expect(hub.discontinuityCount == 0)
        await hub.discontinuity()
        await hub.discontinuity()
        #expect(hub.discontinuityCount == 2)
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { hub.discontinuityCount } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(counts.allSatisfy { $0 == 2 })
    }
}

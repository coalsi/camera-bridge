#if os(Linux)
import Testing
@testable import PlatformLinux

@Suite struct LinuxPlatformTests {
    @Test func moduleLoads() {
        #expect(String(describing: LinuxPlatform.self) == "LinuxPlatform")
    }
}
#endif

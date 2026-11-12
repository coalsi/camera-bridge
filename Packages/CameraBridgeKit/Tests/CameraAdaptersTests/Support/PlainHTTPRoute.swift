// Loopback cameras use the platform transport (Network.framework on macOS, POSIX sockets on Linux).
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing

/// Runs a test with plain `http://` requests on `PlainHTTP` where that is what the daemon does — on Linux — and on a Mac with
/// `CB_TEST_PLAIN_HTTP=1` (BridgeSupportTests' trait of the same name, for the camera suites that need it).
///
/// A suite needs it when its camera closes a connection without answering a request (`MockResponse.drop`, as a camera restarting its
/// network does) after it answered one on that connection. Without it, on Linux, URLSession sends that request again on a new connection
/// (libcurl does when a kept-alive connection closes before any answer), but swift-corelibs-foundation cannot rewind a request's body
/// (`httpBody`) and tells libcurl it did: libcurl 8.5.0 (Ubuntu 24.04's, in the image CI tests with) then sends the request without its
/// body and waits for an answer until the client's timeout (10 s), and libcurl from 8.7.0 on (Ubuntu 26.04's 8.18.0, Debian 13's 8.14.1)
/// fails it at once. The daemon sends no plain-HTTP request through URLSession (`AuthenticatingHTTPClient.routePlainHTTP(through:)`).
struct PlainHTTPRouteTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    /// Whether this run sends plain HTTP through `PlainHTTP`.
    static var isOn: Bool {
        #if os(Linux)
        true
        #else
        ProcessInfo.processInfo.environment["CB_TEST_PLAIN_HTTP"] == "1"
        #endif
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard Self.isOn, testCase != nil else { return try await function() }
        try await AuthenticatingHTTPClient.$plainHTTPRoute.withValue(PlatformNetworkTransport()) { try await function() }
    }
}

extension Trait where Self == PlainHTTPRouteTrait {
    /// The daemon's route for plain HTTP on Linux (and on a Mac with `CB_TEST_PLAIN_HTTP=1`).
    static var plainHTTPRoute: Self { Self() }
}
#endif

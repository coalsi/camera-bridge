import BridgeSupport
import Foundation
import Testing

/// Review finding (W4 BridgeSupport): "the URL without `user:password@`" (what keeps camera passwords out of config.json,
/// StreamInfo and RTSP request lines) existed as copies in CameraAdapters, BridgeEngine, RTSP and the app. BridgeSupport
/// now has the one copy, `URL.removingUserInfo`.
@Suite struct URLUserInfoTests {
    @Test(arguments: [
        ("rtsp://admin:s3cr3t@10.0.0.2:554/Streaming/Channels/101", "rtsp://10.0.0.2:554/Streaming/Channels/101"),
        ("rtsp://admin@cam/x", "rtsp://cam/x"),
        ("rtsp://:s3cr3t@cam/x", "rtsp://cam/x"),
        ("rtsp://@cam/x", "rtsp://cam/x"),
        ("rtsp://ad%40min:p%3Aw%20d@cam:554/x?y=1#z", "rtsp://cam:554/x?y=1#z"),
        ("rtsp://u:p@[fe80::1%25en0]:554/s", "rtsp://[fe80::1%25en0]:554/s"),
        ("http://u:p@cam", "http://cam"),
        ("rtsps://u:p%20q@cam:322/a%20b/c?d=%25zz", "rtsps://cam:322/a%20b/c?d=%25zz"),
    ])
    func removesUserAndPassword(_ input: String, _ expected: String) throws {
        let url = try #require(URL(string: input))
        let stripped = url.removingUserInfo
        #expect(stripped.absoluteString == expected)
        #expect(stripped.user == nil && stripped.password == nil)
    }

    @Test func keepsURLsWithoutUserInfoAsTheyAre() throws {
        for text in ["rtsp://cam:554/user=admin&password=x", "http://192.168.1.10/snapshot.cgi;pwd=x", "rtsp://[::1]:8554/s?a=b", "file:///tmp/x"] {
            let url = try #require(URL(string: text))
            #expect(url.removingUserInfo == url, "\(text)")
        }
    }
}

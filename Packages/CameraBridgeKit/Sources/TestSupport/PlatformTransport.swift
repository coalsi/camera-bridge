#if os(macOS)
import PlatformApple
#elseif os(Linux)
import PlatformLinux
#endif

#if os(macOS)
/// The real loopback transport of the platform the tests run on (Network.framework).
public typealias PlatformNetworkTransport = AppleNetworkTransport
#elseif os(Linux)
/// The real loopback transport of the platform the tests run on (POSIX sockets).
public typealias PlatformNetworkTransport = LinuxNetworkTransport
#endif

#if os(macOS) || os(Linux)
/// The platform's real helper launcher (go2rtc tests): `Process`-based on both.
public typealias PlatformHelperLauncher = ProcessHelperLauncher
#endif

/// The loopback interface's name on this platform (`lo0` on macOS, `lo` on Linux).
public var loopbackInterfaceName: String {
    #if os(Linux)
    "lo"
    #else
    "lo0"
    #endif
}

#if os(macOS)
/// The platform's real codecs (VideoToolbox / AudioToolbox / ImageIO).
public typealias PlatformMediaCodecs = AppleMediaCodecs
#elseif os(Linux)
/// The platform's codecs. Until the ffmpeg-based `LinuxMediaCodecs` (PlatformLinux/Codecs) is wired in this is the placeholder
/// that throws `MediaCodecError.unsupported`: tests that need real encoding or decoding are not enabled on Linux yet.
public typealias PlatformMediaCodecs = UnavailableMediaCodecs
#endif

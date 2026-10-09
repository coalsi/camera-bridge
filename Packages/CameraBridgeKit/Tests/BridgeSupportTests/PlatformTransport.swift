#if os(macOS)
import PlatformApple
typealias PlatformNetworkTransport = AppleNetworkTransport
#elseif os(Linux)
import PlatformLinux
typealias PlatformNetworkTransport = LinuxNetworkTransport
#endif

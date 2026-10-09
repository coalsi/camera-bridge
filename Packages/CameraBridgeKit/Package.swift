// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
/// AES-CTR for SRTP where CommonCrypto is unavailable (contracts: portability rule).
let cryptoExtrasOnLinux: Target.Dependency = .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: [.linux]))
/// The macOS implementations of the platform protocols. Every other module is portable (contracts: portability rule).
let platformApple: Target.Dependency = .target(name: "PlatformApple", condition: .when(platforms: [.macOS]))

/// The Linux implementations of the platform protocols (empty module on macOS). BridgeEngine and TestSupport reach it only on Linux.
let platformLinux: Target.Dependency = .target(name: "PlatformLinux", condition: .when(platforms: [.linux]))

/// Module dependency graph: docs/superpowers/plans/2026-09-30-camerabridge-contracts.md
/// (enforced for imports by Tests/PortabilityTests).
let package = Package(
    name: "CameraBridgeKit",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "BridgeSupport", targets: ["BridgeSupport"]),
        .library(name: "HAPCore", targets: ["HAPCore"]),
        .library(name: "HAP", targets: ["HAP"]),
        .library(name: "HDS", targets: ["HDS"]),
        .library(name: "HAPCamera", targets: ["HAPCamera"]),
        .library(name: "MediaCore", targets: ["MediaCore"]),
        .library(name: "FMP4", targets: ["FMP4"]),
        .library(name: "RTP", targets: ["RTP"]),
        .library(name: "RTSP", targets: ["RTSP"]),
        .library(name: "CameraAdapters", targets: ["CameraAdapters"]),
        .library(name: "PlatformApple", targets: ["PlatformApple"]),
        .library(name: "PlatformLinux", targets: ["PlatformLinux"]),
        .library(name: "BridgeEngine", targets: ["BridgeEngine"]),
        .library(name: "BridgeWeb", targets: ["BridgeWeb"]),
        .library(name: "BridgeDaemon", targets: ["BridgeDaemon"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "cbctl", targets: ["cbctl"]),
        .executable(name: "camerabridged", targets: ["camerabridged"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "BridgeSupport", dependencies: [crypto], exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "HAPCore", dependencies: ["BridgeSupport", .product(name: "BigInt", package: "BigInt"), crypto],
                exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "HAP", dependencies: ["HAPCore", "BridgeSupport"], exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "HDS", dependencies: ["HAP", "HAPCore", "BridgeSupport"], exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "HAPCamera", dependencies: ["HAP", "HDS", "HAPCore", "BridgeSupport"], exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "MediaCore", dependencies: ["BridgeSupport"], exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "FMP4", dependencies: ["MediaCore"], exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "RTP", dependencies: ["MediaCore", "BridgeSupport", crypto, cryptoExtrasOnLinux], exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "RTSP", dependencies: ["RTP", "MediaCore", "BridgeSupport"], exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "CameraAdapters", dependencies: ["RTSP", "RTP", "MediaCore", "BridgeSupport"], exclude: ["README.md"], swiftSettings: swift6),
        // macOS only: Network, dnssd, Security, IOKit, CoreMedia, CoreVideo, VideoToolbox, AudioToolbox, Accelerate, CoreImage, CoreGraphics, CoreText, ImageIO.
        .target(name: "PlatformApple", dependencies: ["BridgeSupport", "MediaCore"], exclude: ["README.md"], swiftSettings: swift6),
        // Linux: the dns_sd API (libavahi-compat-libdnssd) as a C module; PlatformLinux imports it on Linux only.
        .systemLibrary(name: "CDNSSD", path: "Sources/CDNSSD", pkgConfig: "avahi-compat-libdns_sd",
                       providers: [.apt(["libavahi-compat-libdnssd-dev"])]),
        // Linux services: POSIX sockets + Dispatch, dns_sd, netlink, flock, encrypted file secrets, Foundation.Process. Codecs/ drives ffmpeg child
        // processes (portable Swift; it builds on macOS too, so its logic is unit-tested there).
        .target(name: "PlatformLinux",
                dependencies: ["BridgeSupport", "MediaCore", crypto, .target(name: "CDNSSD", condition: .when(platforms: [.linux]))],
                exclude: ["README.md", "Codecs/README.md"], swiftSettings: swift6),
        .target(name: "BridgeEngine",
                dependencies: ["BridgeSupport", "HAPCore", "HAP", "HDS", "HAPCamera", "MediaCore", "FMP4", "RTP", "RTSP", "CameraAdapters",
                               platformApple, platformLinux],
                exclude: ["README.md"], swiftSettings: swift6),
        // The web interface of Camera Bridge OS: an HTTP/1.1 server over the injected `NetworkTransport`, the JSON API, sessions.
        .target(name: "BridgeWeb", dependencies: ["BridgeEngine", "CameraAdapters", "RTSP", "MediaCore", "BridgeSupport", crypto],
                exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "TestSupport", dependencies: ["HAPCore", "HAP", "HDS", "RTP", "RTSP", "MediaCore", "FMP4", "BridgeSupport", platformApple, platformLinux],
                exclude: ["README.md"], swiftSettings: swift6),
        .executableTarget(name: "cbctl", dependencies: ["TestSupport", "BridgeSupport"], exclude: ["README.md"], swiftSettings: swift6),
        // The Camera Bridge OS daemon: the engine and its web interface in one process. The logic is a library (testable); the
        // executable is its `main`.
        .target(name: "BridgeDaemon", dependencies: ["BridgeWeb", "BridgeEngine", "CameraAdapters", "BridgeSupport", platformLinux],
                exclude: ["README.md"], swiftSettings: swift6),
        .executableTarget(name: "camerabridged", dependencies: ["BridgeDaemon"], exclude: ["README.md"], swiftSettings: swift6),

        // Every test target may use PlatformApple (real transport / codecs on macOS) — always through `platformApple` / `platformLinux`, and
        // test code using it or an Apple-only framework sits inside `#if os(macOS)` / `#if canImport(<framework>)`
        // (PortabilityTests). Fixtures are read via #filePath. Test targets share `Box`, `eventually`, `TemporaryDirectory`
        // and the in-memory `FakeNetworkTransport` from TestSupport (test-only, so the module graph is unaffected);
        // BridgeSupportTests keeps private copies to stay below it.
        .testTarget(name: "BridgeSupportTests", dependencies: ["BridgeSupport", crypto, platformApple, platformLinux], swiftSettings: swift6),
        .testTarget(name: "HAPCoreTests", dependencies: ["HAPCore", "BridgeSupport", .product(name: "BigInt", package: "BigInt"), platformApple, platformLinux],
                    exclude: ["Fixtures"], swiftSettings: swift6),
        .testTarget(name: "HAPTests", dependencies: ["HAP", "HAPCore", "BridgeSupport", "TestSupport", platformApple, platformLinux], swiftSettings: swift6),
        .testTarget(name: "HDSTests", dependencies: ["HDS", "HAP", "HAPCore", "BridgeSupport", "TestSupport", platformApple, platformLinux],
                    exclude: ["Fixtures"], swiftSettings: swift6),
        .testTarget(name: "HAPCameraTests", dependencies: ["HAPCamera", "HDS", "HAP", "HAPCore", "BridgeSupport", "TestSupport", platformApple, platformLinux],
                    exclude: ["Fixtures"], swiftSettings: swift6),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore", "BridgeSupport", platformApple, platformLinux], swiftSettings: swift6),
        .testTarget(name: "FMP4Tests", dependencies: ["FMP4", "MediaCore", "BridgeSupport", platformApple, platformLinux], swiftSettings: swift6),
        .testTarget(name: "RTPTests", dependencies: ["RTP", "MediaCore", "BridgeSupport", "TestSupport", platformApple, platformLinux], swiftSettings: swift6),
        .testTarget(name: "RTSPTests", dependencies: ["RTSP", "RTP", "FMP4", "MediaCore", "BridgeSupport", "TestSupport", platformApple, platformLinux], swiftSettings: swift6),
        .testTarget(name: "CameraAdaptersTests", dependencies: ["CameraAdapters", "RTSP", "RTP", "MediaCore", "BridgeSupport", "TestSupport", platformApple, platformLinux],
                    exclude: ["Fixtures"], swiftSettings: swift6),
        .testTarget(name: "PlatformLinuxTests", dependencies: [platformLinux, "BridgeSupport", "MediaCore", "TestSupport", crypto], swiftSettings: swift6),
        .testTarget(name: "PlatformAppleTests", dependencies: [platformApple, "BridgeSupport", "MediaCore", "TestSupport"], swiftSettings: swift6),
        .testTarget(name: "PlatformLinuxCodecsTests", dependencies: ["PlatformLinux", "BridgeSupport", "MediaCore", platformApple], swiftSettings: swift6),
        .testTarget(name: "BridgeEngineTests", dependencies: ["BridgeEngine", "CameraAdapters", "HAP", "BridgeSupport", "MediaCore", "TestSupport", platformApple, platformLinux],
                    swiftSettings: swift6),
        .testTarget(name: "BridgeWebTests", dependencies: ["BridgeWeb", "BridgeEngine", "CameraAdapters", "RTSP", "MediaCore", "BridgeSupport", "TestSupport", crypto, platformApple],
                    swiftSettings: swift6),
        .testTarget(name: "BridgeDaemonTests", dependencies: ["BridgeDaemon", "BridgeWeb", "BridgeEngine", "CameraAdapters", "BridgeSupport", "TestSupport", platformApple],
                    swiftSettings: swift6),
        .testTarget(name: "IntegrationTests",
                    dependencies: ["BridgeEngine", "TestSupport", "BridgeSupport", "HAPCore", "HAP", "HDS", "HAPCamera", "MediaCore",
                                   "FMP4", "RTP", "RTSP", "CameraAdapters", platformApple, platformLinux],
                    swiftSettings: swift6),
        // Scans Sources/ for Apple-only imports in portable modules and for dependency-graph violations, and Sources/ +
        // Tests/ for leftover contract scaffolding (no module deps).
        .testTarget(name: "PortabilityTests", swiftSettings: swift6),
    ]
)

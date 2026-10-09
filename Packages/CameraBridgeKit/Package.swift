// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
/// AES-CTR for SRTP where CommonCrypto is unavailable (contracts: portability rule).
let cryptoExtrasOnLinux: Target.Dependency = .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: [.linux]))
/// The macOS implementations of the platform protocols. Every other module is portable (contracts: portability rule).
let platformApple: Target.Dependency = .target(name: "PlatformApple", condition: .when(platforms: [.macOS]))

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
        .library(name: "BridgeEngine", targets: ["BridgeEngine"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "cbctl", targets: ["cbctl"]),
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
        .target(name: "BridgeEngine",
                dependencies: ["BridgeSupport", "HAPCore", "HAP", "HDS", "HAPCamera", "MediaCore", "FMP4", "RTP", "RTSP", "CameraAdapters",
                               platformApple],
                exclude: ["README.md"], swiftSettings: swift6),
        .target(name: "TestSupport", dependencies: ["HAPCore", "HAP", "HDS", "RTP", "RTSP", "MediaCore", "FMP4", "BridgeSupport", platformApple],
                exclude: ["README.md"], swiftSettings: swift6),
        .executableTarget(name: "cbctl", dependencies: ["TestSupport", "BridgeSupport"], exclude: ["README.md"], swiftSettings: swift6),

        // Every test target may use PlatformApple (real transport / codecs on macOS) — always through `platformApple`, and
        // test code using it or an Apple-only framework sits inside `#if os(macOS)` / `#if canImport(<framework>)`
        // (PortabilityTests). Fixtures are read via #filePath. Test targets share `Box`, `eventually`, `TemporaryDirectory`
        // and the in-memory `FakeNetworkTransport` from TestSupport (test-only, so the module graph is unaffected);
        // BridgeSupportTests keeps private copies to stay below it.
        .testTarget(name: "BridgeSupportTests", dependencies: ["BridgeSupport", crypto, platformApple], swiftSettings: swift6),
        .testTarget(name: "HAPCoreTests", dependencies: ["HAPCore", "BridgeSupport", .product(name: "BigInt", package: "BigInt"), platformApple],
                    exclude: ["Fixtures"], swiftSettings: swift6),
        .testTarget(name: "HAPTests", dependencies: ["HAP", "HAPCore", "BridgeSupport", "TestSupport", platformApple], swiftSettings: swift6),
        .testTarget(name: "HDSTests", dependencies: ["HDS", "HAP", "HAPCore", "BridgeSupport", "TestSupport", platformApple],
                    exclude: ["Fixtures"], swiftSettings: swift6),
        .testTarget(name: "HAPCameraTests", dependencies: ["HAPCamera", "HDS", "HAP", "HAPCore", "BridgeSupport", "TestSupport", platformApple],
                    exclude: ["Fixtures"], swiftSettings: swift6),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore", "BridgeSupport", platformApple], swiftSettings: swift6),
        .testTarget(name: "FMP4Tests", dependencies: ["FMP4", "MediaCore", "BridgeSupport", platformApple], swiftSettings: swift6),
        .testTarget(name: "RTPTests", dependencies: ["RTP", "MediaCore", "BridgeSupport", "TestSupport", platformApple], swiftSettings: swift6),
        .testTarget(name: "RTSPTests", dependencies: ["RTSP", "RTP", "FMP4", "MediaCore", "BridgeSupport", "TestSupport", platformApple], swiftSettings: swift6),
        .testTarget(name: "CameraAdaptersTests", dependencies: ["CameraAdapters", "RTSP", "RTP", "MediaCore", "BridgeSupport", "TestSupport", platformApple],
                    exclude: ["Fixtures"], swiftSettings: swift6),
        .testTarget(name: "PlatformAppleTests", dependencies: [platformApple, "BridgeSupport", "MediaCore", "TestSupport"], swiftSettings: swift6),
        .testTarget(name: "BridgeEngineTests", dependencies: ["BridgeEngine", "CameraAdapters", "HAP", "BridgeSupport", "MediaCore", "TestSupport", platformApple],
                    swiftSettings: swift6),
        .testTarget(name: "IntegrationTests",
                    dependencies: ["BridgeEngine", "TestSupport", "BridgeSupport", "HAPCore", "HAP", "HDS", "HAPCamera", "MediaCore",
                                   "FMP4", "RTP", "RTSP", "CameraAdapters", platformApple],
                    swiftSettings: swift6),
        // Scans Sources/ for Apple-only imports in portable modules and for dependency-graph violations, and Sources/ +
        // Tests/ for leftover contract scaffolding (no module deps).
        .testTarget(name: "PortabilityTests", swiftSettings: swift6),
    ]
)

// swift-tools-version: 6.1
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let millerReleaseVersion = try! String(
    contentsOf: packageRoot.appendingPathComponent("Packaging/Miller.version"),
    encoding: .utf8
).trimmingCharacters(in: .whitespacesAndNewlines)
precondition(
    millerReleaseVersion == "0.1.2",
    "Miller release version must be 0.1.2"
)
let wakewordLockedRoot = packageRoot
    .appendingPathComponent(".build/vendor/wakeword/locked").path
let wakewordInputsAvailable = FileManager.default.fileExists(
    atPath: "\(wakewordLockedRoot)/lib/libsherpa-onnx.a"
) && FileManager.default.fileExists(
    atPath: "\(wakewordLockedRoot)/lib/libonnxruntime.a"
)

let wakewordCXXSettings: [CXXSetting] = wakewordInputsAvailable
    ? [.unsafeFlags(["-I", "\(wakewordLockedRoot)/include"])]
    : [.define("MILLER_WAKEWORD_INPUTS_UNAVAILABLE")]
let wakewordLinkerSettings: [LinkerSetting] = wakewordInputsAvailable ? [
    .unsafeFlags([
        "\(wakewordLockedRoot)/lib/libsherpa-onnx.a",
        "\(wakewordLockedRoot)/lib/libonnxruntime.a",
    ]),
    .linkedLibrary("c++"),
] : [.linkedLibrary("c++")]

let package = Package(
    name: "Miller",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MillerCore", targets: ["MillerCore"]),
        .library(name: "MillerStorage", targets: ["MillerStorage"]),
        .library(name: "MillerGateway", targets: ["MillerGateway"]),
        .library(name: "MillerLive", targets: ["MillerLive"]),
        .library(name: "MillerLiveAudio", targets: ["MillerLiveAudio"]),
        .library(name: "MillerRemoteBridge", targets: ["MillerRemoteBridge"]),
        .library(name: "MillerCapabilities", targets: ["MillerCapabilities"]),
        .library(name: "MillerWake", targets: ["MillerWake"]),
        .executable(name: "MillerApp", targets: ["MillerApp"]),
        .executable(
            name: "MillerCapabilityBridge",
            targets: ["MillerCapabilityBridge"]
        ),
        .executable(
            name: "MillerTask18RouteHarness",
            targets: ["MillerTask18RouteHarness"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/tim-osterhus/miller-avatar.git",
            exact: "0.1.0-alpha.6"
        ),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "MillerCore"),
        .target(
            name: "MillerStorage",
            dependencies: ["MillerCore", "CSQLite"]
        ),
        .target(
            name: "MillerGateway",
            dependencies: ["MillerCore"]
        ),
        .target(name: "MillerLive", dependencies: ["MillerCore"]),
        .target(
            name: "MillerCapabilities",
            dependencies: [
                "MillerCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .target(
            name: "MillerLiveAudio",
            dependencies: ["MillerLive"],
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .target(
            name: "MillerRemoteBridge",
            dependencies: ["MillerLiveAudio"]
        ),
        .target(
            name: "MillerWakeBridge",
            path: "Sources/MillerWakeBridge",
            publicHeadersPath: "include",
            cxxSettings: wakewordCXXSettings,
            linkerSettings: wakewordLinkerSettings
        ),
        .target(name: "MillerWake", dependencies: ["MillerWakeBridge"]),
        .executableTarget(
            name: "MillerCapabilityBridge",
            dependencies: [
                "MillerCore",
                "MillerCapabilities",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "MillerTask18RouteHarness",
            dependencies: ["MillerCapabilities", "MillerCore"]
        ),
        .executableTarget(
            name: "MillerApp",
            dependencies: [
                "MillerCore", "MillerStorage", "MillerGateway", "MillerLive",
                "MillerLiveAudio", "MillerRemoteBridge", "MillerCapabilities", "MillerWake",
                .product(name: "MillerAvatarCore", package: "miller-avatar"),
                .product(name: "MillerAvatarHost", package: "miller-avatar"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .define("MILLER_RELEASE_BUILD", .when(configuration: .release))
            ],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .testTarget(
            name: "MillerCoreTests",
            dependencies: ["MillerCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MillerStorageTests",
            dependencies: ["MillerStorage"]
        ),
        .testTarget(
            name: "MillerGatewayTests",
            dependencies: ["MillerGateway", "MillerCore"]
        ),
        .testTarget(
            name: "MillerLiveTests",
            dependencies: ["MillerLive", "MillerCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MillerLiveAudioTests",
            dependencies: ["MillerLiveAudio", "MillerLive"]
        ),
        .testTarget(
            name: "MillerRemoteBridgeTests",
            dependencies: ["MillerRemoteBridge", "MillerLiveAudio"]
        ),
        .testTarget(name: "MillerWakeTests", dependencies: ["MillerWake"]),
        .testTarget(
            name: "MillerCapabilitiesTests",
            dependencies: [
                "MillerCapabilities",
                "MillerCapabilityBridge",
                "MillerCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MillerAppTests",
            dependencies: [
                "MillerApp", "MillerCore", "MillerStorage",
                "MillerCapabilities", "MillerGateway", "MillerLive",
                "MillerLiveAudio", "MillerRemoteBridge",
            ]
        ),
    ]
)

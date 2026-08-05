// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Miller",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MillerCore", targets: ["MillerCore"]),
        .library(name: "MillerStorage", targets: ["MillerStorage"]),
        .library(name: "MillerGateway", targets: ["MillerGateway"]),
        .library(name: "MillerLive", targets: ["MillerLive"]),
        .library(name: "MillerLiveAudio", targets: ["MillerLiveAudio"]),
        .library(name: "MillerCapabilities", targets: ["MillerCapabilities"]),
        .executable(name: "MillerApp", targets: ["MillerApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
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
        .target(name: "MillerLive"),
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
        .executableTarget(
            name: "MillerApp",
            dependencies: [
                "MillerCore", "MillerStorage", "MillerGateway", "MillerLive",
                "MillerLiveAudio",
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .define("MILLER_RELEASE_BUILD", .when(configuration: .release))
            ],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .testTarget(name: "MillerCoreTests", dependencies: ["MillerCore"]),
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
            dependencies: ["MillerLive"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MillerLiveAudioTests",
            dependencies: ["MillerLiveAudio", "MillerLive"]
        ),
        .testTarget(
            name: "MillerCapabilitiesTests",
            dependencies: ["MillerCapabilities", "MillerCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MillerAppTests",
            dependencies: ["MillerApp", "MillerCore", "MillerStorage"]
        ),
    ]
)

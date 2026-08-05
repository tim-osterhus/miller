import Foundation
import Testing

@Suite
struct ReleasePackagingPolicyTests {
    private let officialSDKURL = "https://github.com/modelcontextprotocol/swift-sdk.git"

    @Test
    func officialMCPDependencyIsPinnedExactly() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        #expect(manifest.contains("url: \"\(officialSDKURL)\""))
        #expect(manifest.contains("exact: \"0.12.1\""))
    }

    @Test
    func officialMCPDependencyIsLockedToVersionedRevision() throws {
        let lockURL = repositoryRoot.appendingPathComponent("Package.resolved")
        let lockData = try Data(contentsOf: lockURL)
        let lock = try JSONDecoder().decode(PackageLock.self, from: lockData)
        let sdkPins = lock.pins.filter { $0.identity == "swift-sdk" }

        #expect(sdkPins.count == 1)
        let sdk = try #require(sdkPins.first)
        #expect(sdk.location == officialSDKURL)
        #expect(sdk.state.version == "0.12.1")
        #expect(sdk.state.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil)
    }

    @Test
    func productionInventoryExcludesForbiddenInputsAndExperimentalAPIs() throws {
        let productionRoots = ["Sources", "Gateway/src", "Packaging", "scripts"]
        let forbiddenPathFragments = ["voiceink", "codex-rs", "rust-toolchain"]
        let forbiddenFileNames = ["cargo", "cargo.toml", "cargo.lock", "rustc"]
        let forbiddenSourceExtensions = ["rs"]
        let forbiddenPackagePatterns = [
            "voiceink",
            "codex-rs",
            "(^|[^a-z0-9])cargo([^a-z0-9]|$)",
            "(^|[^a-z0-9])rust([^a-z0-9]|$)",
        ]
        let experimentalAPITerms = ["dynamicTools", "item/tool/call"]
        let packageInventories = [
            "Package.swift",
            "Package.resolved",
            "Gateway/package.json",
            "Gateway/package-lock.json",
            "Packaging/Miller.spdx.json",
        ]

        for relativeRoot in productionRoots {
            let root = repositoryRoot.appendingPathComponent(relativeRoot)
            for file in try regularFiles(beneath: root) {
                let relativePath = file.path.replacingOccurrences(
                    of: repositoryRoot.path + "/",
                    with: ""
                )
                let components = relativePath.lowercased().split(separator: "/").map(String.init)
                let fileName = try #require(components.last)
                #expect(
                    components.allSatisfy { component in
                        forbiddenPathFragments.allSatisfy { !component.contains($0) }
                    } && !forbiddenFileNames.contains(fileName),
                    "Forbidden production path: \(relativePath)"
                )
                #expect(
                    !forbiddenSourceExtensions.contains(file.pathExtension.lowercased()),
                    "Forbidden production source: \(relativePath)"
                )

                guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
                    continue
                }
                for term in experimentalAPITerms {
                    #expect(
                        !contents.contains(term),
                        "Experimental App Server API in production file: \(relativePath)"
                    )
                }
            }
        }

        for relativePath in packageInventories {
            let inventoryURL = repositoryRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: inventoryURL.path) else {
                continue
            }
            let contents = try String(contentsOf: inventoryURL, encoding: .utf8).lowercased()
            for pattern in forbiddenPackagePatterns {
                #expect(
                    contents.range(of: pattern, options: .regularExpression) == nil,
                    "Forbidden package entry in \(relativePath): \(pattern)"
                )
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func regularFiles(beneath root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        )
        return try enumerator.compactMap { element in
            let url = try #require(element as? URL)
            let values = try url.resourceValues(forKeys: Set(keys))
            return values.isRegularFile == true && values.isSymbolicLink != true ? url : nil
        }
    }
}

private struct PackageLock: Decodable {
    let pins: [PackagePin]
}

private struct PackagePin: Decodable {
    let identity: String
    let location: String
    let state: PackagePinState
}

private struct PackagePinState: Decodable {
    let revision: String
    let version: String?
}

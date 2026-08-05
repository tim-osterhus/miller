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

        #expect(ReleasePackagingPolicy.hasApprovedSDKDeclaration(in: manifest))
    }

    @Test
    func officialMCPDependencyIsLockedToVersionedRevision() throws {
        let lockURL = repositoryRoot.appendingPathComponent("Package.resolved")
        let lockData = try Data(contentsOf: lockURL)
        let lock = try JSONDecoder().decode(PackageLock.self, from: lockData)

        #expect(ReleasePackagingPolicy.hasApprovedSDKLock(lock))
    }

    @Test
    func manifestMatcherRejectsUnboundURLAndVersionDecoys() {
        let approved = """
            dependencies: [
                .package(
                    url: "https://github.com/modelcontextprotocol/swift-sdk.git",
                    exact: "0.12.1"
                ),
            ]
            """
        let unboundDecoy = """
            // https://github.com/modelcontextprotocol/swift-sdk.git
            .package(url: "https://example.invalid/not-mcp.git", exact: "0.12.1")
            """
        let wrongRequirement = """
            .package(
                url: "https://github.com/modelcontextprotocol/swift-sdk.git",
                from: "0.12.1"
            )
            """

        #expect(ReleasePackagingPolicy.hasApprovedSDKDeclaration(in: approved))
        #expect(!ReleasePackagingPolicy.hasApprovedSDKDeclaration(in: unboundDecoy))
        #expect(!ReleasePackagingPolicy.hasApprovedSDKDeclaration(in: wrongRequirement))
    }

    @Test
    func manifestMatcherIgnoresCommentedApprovedDeclarations() {
        let blockCommentDecoy = """
            /*
            .package(
                url: "https://github.com/modelcontextprotocol/swift-sdk.git",
                exact: "0.12.1"
            )
            */
            .package(
                url: "https://github.com/modelcontextprotocol/swift-sdk.git",
                from: "0.12.1"
            )
            """
        let lineCommentDecoy = """
            // .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
            .package(url: "https://example.invalid/not-mcp.git", exact: "0.12.1")
            """

        #expect(!ReleasePackagingPolicy.hasApprovedSDKDeclaration(in: blockCommentDecoy))
        #expect(!ReleasePackagingPolicy.hasApprovedSDKDeclaration(in: lineCommentDecoy))
    }

    @Test
    func lockMatcherRejectsAnUnapprovedRevision() {
        let approved = PackageLock(pins: [
            PackagePin(
                identity: "swift-sdk",
                location: officialSDKURL,
                state: PackagePinState(
                    revision: "a0ae212ebf6eab5f754c3129608bc5557637e605",
                    version: "0.12.1"
                )
            ),
        ])
        let unexpectedRevision = PackageLock(pins: [
            PackagePin(
                identity: "swift-sdk",
                location: officialSDKURL,
                state: PackagePinState(
                    revision: "0000000000000000000000000000000000000000",
                    version: "0.12.1"
                )
            ),
        ])

        #expect(ReleasePackagingPolicy.hasApprovedSDKLock(approved))
        #expect(!ReleasePackagingPolicy.hasApprovedSDKLock(unexpectedRevision))
    }

    @Test
    func productionInventoryRequiresEveryExpectedRootAndInventory() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.removeItem(
            at: fixture.appendingPathComponent("Package.resolved")
        )
        try FileManager.default.removeItem(
            at: fixture.appendingPathComponent("Gateway/src")
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.contains("Missing production root: Gateway/src"))
        #expect(violations.contains("Missing package inventory: Package.resolved"))
    }

    @Test
    func productionInventoryRejectsRootHiddenAndScriptedRustInputs() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try write("", to: fixture.appendingPathComponent("Cargo.toml"))
        try write(
            "// hidden Rust source",
            to: fixture.appendingPathComponent("Sources/.generated/bridge.rs")
        )
        try write(
            "#!/bin/sh\ncargo build\n/usr/bin/rustc main.rs\n",
            to: fixture.appendingPathComponent("scripts/build.sh")
        )
        try write(
            "let unsupportedMethod = \"dynamicTools\"; execute(unsupportedMethod)\n"
                + "let endpoint = \"item/tool/call\"\n",
            to: fixture.appendingPathComponent("Gateway/src/app-server.swift")
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.contains { $0.contains("Cargo.toml") })
        #expect(violations.contains { $0.contains("Sources/.generated/bridge.rs") })
        #expect(
            violations.contains { $0.contains("scripts/build.sh") && $0.contains("cargo") },
            "\(violations)"
        )
        #expect(
            violations.contains { $0.contains("scripts/build.sh") && $0.contains("rustc") },
            "\(violations)"
        )
        #expect(violations.contains { $0.contains("dynamicTools") })
        #expect(violations.contains { $0.contains("item/tool/call") })
    }

    @Test
    func scriptFailureSuffixDoesNotMaskCargoInvocation() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try write(
            "#!/bin/sh\ncargo build || exit 1\n"
                + "rustc main.rs || forbidden_result=1\n",
            to: fixture.appendingPathComponent("scripts/build.sh")
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.contains { $0.contains("Forbidden cargo invocation") })
        #expect(violations.contains { $0.contains("Forbidden rustc invocation") })
    }

    @Test
    func nestedCargoDirectoryIsRejected() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try write(
            "[build]",
            to: fixture.appendingPathComponent("Sources/vendor/.cargo/config.toml")
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.contains { $0.contains("Sources/vendor/.cargo") })
    }

    @Test
    func voiceInkContentUseIsRejected() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try write(
            "forbidden_result = VoiceInk.Recorder()\n",
            to: fixture.appendingPathComponent("Sources/Recorder.swift")
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.contains { $0.contains("VoiceInk") })
    }

    @Test
    func productionInventoryAllowsNarrowVerificationAssertions() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try write(
            """
            #!/bin/sh
            forbidden_api="dynamicTools" # reject experimental API
            refused_endpoint="item/tool/call"
            find Sources -type f \\( -name cargo -o -name rustc -o -iname '*codex-rs*' \\)
            find Sources -type f -iname '*VoiceInk*'
            """,
            to: fixture.appendingPathComponent("scripts/verify.sh")
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.isEmpty)
    }

    @Test
    func productionInventoryExcludesForbiddenInputsAndExperimentalAPIs() throws {
        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: repositoryRoot
        )

        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makePolicyFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-release-policy-\(UUID().uuidString)")
        for relativePath in ["Sources", "Gateway/src", "Packaging", "scripts"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(relativePath),
                withIntermediateDirectories: true
            )
        }
        for relativePath in [
            "Package.swift",
            "Package.resolved",
            "Gateway/package.json",
            "Gateway/package-lock.json",
            "Packaging/Miller.spdx.json",
        ] {
            try write("{}", to: root.appendingPathComponent(relativePath))
        }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
}

private enum ReleasePackagingPolicy {
    static let officialSDKURL = "https://github.com/modelcontextprotocol/swift-sdk.git"
    static let approvedSDKVersion = "0.12.1"
    static let approvedSDKRevision = "a0ae212ebf6eab5f754c3129608bc5557637e605"

    private static let productionRoots = ["Sources", "Gateway/src", "Packaging", "scripts"]
    private static let packageInventories = [
        "Package.swift",
        "Package.resolved",
        "Gateway/package.json",
        "Gateway/package-lock.json",
        "Packaging/Miller.spdx.json",
    ]
    private static let forbiddenRootEntries = [
        ".cargo",
        "Cargo.lock",
        "Cargo.toml",
        "rust-toolchain",
        "rust-toolchain.toml",
    ]
    private static let forbiddenPathFragments = ["voiceink", "codex-rs", "rust-toolchain"]
    private static let forbiddenPathComponents = [".cargo"]
    private static let forbiddenFileNames = [".cargo", "cargo", "cargo.lock", "cargo.toml", "rustc"]
    private static let forbiddenPackagePatterns = [
        "voiceink",
        "codex-rs",
        "(^|[^a-z0-9])cargo([^a-z0-9]|$)",
        "(^|[^a-z0-9])rust([^a-z0-9]|$)",
    ]
    private static let experimentalAPITerms = ["dynamicTools", "item/tool/call"]
    private static let rustCommands = ["cargo", "rustc"]

    static func hasApprovedSDKDeclaration(in manifest: String) -> Bool {
        let activeManifest = removingSwiftComments(from: manifest)
        let escapedURL = NSRegularExpression.escapedPattern(for: officialSDKURL)
        let escapedVersion = NSRegularExpression.escapedPattern(for: approvedSDKVersion)
        let pattern = #"\.package\s*\(\s*url\s*:\s*""#
            + escapedURL
            + #""\s*,\s*exact\s*:\s*""#
            + escapedVersion
            + #""\s*,?\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        return expression.numberOfMatches(
            in: activeManifest,
            range: NSRange(activeManifest.startIndex..., in: activeManifest)
        ) == 1
    }

    static func hasApprovedSDKLock(_ lock: PackageLock) -> Bool {
        let pins = lock.pins.filter { $0.identity == "swift-sdk" }
        return pins.count == 1
            && pins[0].location == officialSDKURL
            && pins[0].state.version == approvedSDKVersion
            && pins[0].state.revision == approvedSDKRevision
    }

    static func inventoryViolations(repositoryRoot: URL) throws -> [String] {
        var violations: [String] = []
        let fileManager = FileManager.default
        let root = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL

        for relativePath in productionRoots {
            let url = root.appendingPathComponent(relativePath)
            if !isDirectory(url) {
                violations.append("Missing production root: \(relativePath)")
            }
        }
        for relativePath in packageInventories {
            let url = root.appendingPathComponent(relativePath)
            if !isRegularFile(url) {
                violations.append("Missing package inventory: \(relativePath)")
            }
        }
        for relativePath in forbiddenRootEntries {
            if fileManager.fileExists(
                atPath: root.appendingPathComponent(relativePath).path
            ) {
                violations.append("Forbidden root build input: \(relativePath)")
            }
        }

        let rootEntries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in rootEntries where url.pathExtension.lowercased() == "rs" {
            violations.append("Forbidden Rust source: \(url.lastPathComponent)")
        }

        for relativeRoot in productionRoots {
            let productionRoot = root.appendingPathComponent(relativeRoot)
            guard isDirectory(productionRoot) else { continue }
            for entry in try entries(beneath: productionRoot) {
                let relativePath = relativePath(for: entry, repositoryRoot: root)
                let values = try entry.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                violations.append(contentsOf: pathViolations(
                    for: entry,
                    relativePath: relativePath
                ))
                if values.isSymbolicLink == true {
                    violations.append("Symlinked production entry: \(relativePath)")
                    continue
                }
                guard values.isRegularFile == true else { continue }

                guard let contents = try? String(contentsOf: entry, encoding: .utf8) else {
                    continue
                }
                violations.append(contentsOf: contentViolations(
                    in: contents,
                    relativePath: relativePath
                ))
            }
        }

        for relativePath in packageInventories {
            let url = root.appendingPathComponent(relativePath)
            guard isRegularFile(url) else { continue }
            let contents = try String(contentsOf: url, encoding: .utf8).lowercased()
            for pattern in forbiddenPackagePatterns
            where contents.range(of: pattern, options: .regularExpression) != nil {
                violations.append("Forbidden package entry in \(relativePath): \(pattern)")
            }
        }

        return violations.sorted()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func entries(beneath root: URL) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        )
        return enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
    }

    private static func relativePath(for url: URL, repositoryRoot: URL) -> String {
        let rootPath = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let entryPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard entryPath.hasPrefix(rootPath) else { return entryPath }
        return String(entryPath.dropFirst(rootPath.count))
    }

    private static func pathViolations(for url: URL, relativePath: String) -> [String] {
        let components = relativePath.lowercased().split(separator: "/").map(String.init)
        let fileName = components.last ?? ""
        var violations: [String] = []
        if components.contains(where: { component in
            forbiddenPathFragments.contains { component.contains($0) }
        }) || components.contains(where: { forbiddenPathComponents.contains($0) })
            || forbiddenFileNames.contains(fileName) {
            violations.append("Forbidden production path: \(relativePath)")
        }
        if url.pathExtension.lowercased() == "rs" {
            violations.append("Forbidden Rust source: \(relativePath)")
        }
        return violations
    }

    private static func contentViolations(
        in contents: String,
        relativePath: String
    ) -> [String] {
        var violations: [String] = []
        for (offset, line) in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        ).enumerated() {
            let text = String(line)
            let lowercased = text.lowercased()
            if lowercased.contains("voiceink"),
                !isExplicitAssertion(of: "voiceink", in: lowercased) {
                violations.append(
                    "Forbidden VoiceInk reference in \(relativePath):\(offset + 1)"
                )
            }
            for term in experimentalAPITerms where text.contains(term)
                && !isExplicitAssertion(of: term.lowercased(), in: lowercased) {
                violations.append(
                    "Experimental API \(term) in \(relativePath):\(offset + 1)"
                )
            }
            guard relativePath.hasPrefix("scripts/") else { continue }
            for command in rustCommands where invokes(command, in: lowercased) {
                violations.append(
                    "Forbidden \(command) invocation in \(relativePath):\(offset + 1)"
                )
            }
        }
        return violations
    }

    private static func isExplicitAssertion(of forbiddenTerm: String, in line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let escapedTerm = NSRegularExpression.escapedPattern(for: forbiddenTerm)
        let patterns = [
            #"^(?:forbidden|refused|rejected|denied)_[a-z0-9_]*\s*=\s*["']"#
                + escapedTerm + #"["']\s*(?:#.*)?$"#,
            #"^find\s+.*(?:-name|-iname)\s+["'][^"']*"#
                + escapedTerm + #"[^"']*["']\s*$"#,
            #"^(?://|#)\s*(?:deny|forbid|must not|refus|reject).*"#
                + escapedTerm,
        ]
        return patterns.contains {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func removingSwiftComments(from source: String) -> String {
        var result = ""
        var index = source.startIndex
        var inString = false
        var isEscaped = false
        var inLineComment = false
        var blockCommentDepth = 0

        while index < source.endIndex {
            let character = source[index]
            if inLineComment {
                result.append(character.isNewline ? character : " ")
                if character.isNewline { inLineComment = false }
                index = source.index(after: index)
                continue
            }
            if blockCommentDepth > 0 {
                if source[index...].hasPrefix("/*") {
                    blockCommentDepth += 1
                    result.append("  ")
                    index = source.index(index, offsetBy: 2)
                } else if source[index...].hasPrefix("*/") {
                    blockCommentDepth -= 1
                    result.append("  ")
                    index = source.index(index, offsetBy: 2)
                } else {
                    result.append(character.isNewline ? character : " ")
                    index = source.index(after: index)
                }
                continue
            }
            if inString {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }
            if source[index...].hasPrefix("//") {
                inLineComment = true
                result.append("  ")
                index = source.index(index, offsetBy: 2)
            } else if source[index...].hasPrefix("/*") {
                blockCommentDepth = 1
                result.append("  ")
                index = source.index(index, offsetBy: 2)
            } else {
                result.append(character)
                if character == "\"" { inString = true }
                index = source.index(after: index)
            }
        }
        return result
    }

    private static func invokes(_ command: String, in line: String) -> Bool {
        let wrappers = #"(?:(?:env|sudo|xcrun|command)\s+)*"#
        let executable = #"(?:\S*/)?"# + command + #"(?:\s|$)"#
        let patterns = [
            #"^\s*(?:(?:if|while|until)\s+|!\s+)?"# + wrappers + executable,
            #"(?:&&|\|\||;|\|)\s*"# + wrappers + executable,
            #"\$\(\s*"# + wrappers + executable,
            #"`\s*"# + wrappers + executable,
        ]
        return patterns.contains {
            line.range(of: $0, options: .regularExpression) != nil
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

import Foundation
import Testing

@Suite
struct ReleasePackagingPolicyTests {
    private let officialSDKURL = "https://github.com/modelcontextprotocol/swift-sdk.git"
    private let releaseVersion = "0.1.2"

    @Test
    func oneReleaseVersionFeedsPackageAndCurrentReleaseArtifacts() throws {
        let version = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packaging/Miller.version"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(version == releaseVersion)

        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let plist = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packaging/Info.plist"),
            encoding: .utf8
        )
        let inventory = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/release-inventory.mjs"),
            encoding: .utf8
        )
        let verifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-release-package.sh"),
            encoding: .utf8
        )

        #expect(manifest.contains("Packaging/Miller.version"))
        #expect(plist.contains("<string>\(releaseVersion)</string>"))
        #expect(inventory.contains("release: releaseVersion"))
        #expect(inventory.contains("application_version: releaseVersion"))
        #expect(verifier.contains("const releaseVersion = process.argv[4]"))
        #expect(verifier.contains("inventory.release, releaseVersion"))
    }

    @Test
    func officialMCPDependencyIsPinnedExactly() throws {
        let dump = try semanticPackageDump()

        #expect(ReleasePackagingPolicy.hasApprovedSDKDeclaration(in: dump))
    }

    @Test
    func officialMCPDependencyIsLockedToVersionedRevision() throws {
        let lockURL = repositoryRoot.appendingPathComponent("Package.resolved")
        let lockData = try Data(contentsOf: lockURL)
        let lock = try JSONDecoder().decode(PackageLock.self, from: lockData)

        #expect(ReleasePackagingPolicy.hasApprovedSDKLock(lock))
    }

    @Test
    func officialMillerAvatarDependencyIsPinnedExactlyAndOnlyHostProductsLinkToMillerApp() throws {
        let dump = try semanticPackageDump()

        #expect(ReleasePackagingPolicy.hasApprovedAvatarDeclaration(in: dump))
        #expect(ReleasePackagingPolicy.hasOnlyAvatarProductsInMillerApp(in: dump))
    }

    @Test
    func officialMillerAvatarDependencyIsLockedToTheReviewedTagRevision() throws {
        let lockURL = repositoryRoot.appendingPathComponent("Package.resolved")
        let lockData = try Data(contentsOf: lockURL)
        let lock = try JSONDecoder().decode(PackageLock.self, from: lockData)

        #expect(ReleasePackagingPolicy.hasApprovedAvatarLock(lock))
    }

    @Test
    func avatarResourcePackagingIsClosedToTheFiveWebFiles() throws {
        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/package-dev-app.sh"),
            encoding: .utf8
        )
        let inventoryScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/release-inventory.mjs"),
            encoding: .utf8
        )
        let verifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-release-package.sh"),
            encoding: .utf8
        )
        let requiredPaths = [
            "Web/app.js",
            "Web/bundle-manifest.json",
            "Web/bundle-metafile.json",
            "Web/index.html",
            "Web/styles.css",
        ]

        #expect(packageScript.contains("MillerAvatar_MillerAvatarHost.bundle"))
        #expect(packageScript.contains("MillerAvatarApp") == false)
        for path in requiredPaths {
            #expect(packageScript.contains(path), "missing package assertion: \(path)")
            #expect(inventoryScript.contains(path), "missing inventory assertion: \(path)")
            #expect(verifier.contains(path), "missing release assertion: \(path)")
        }
        #expect(packageScript.contains("*.vrm"))
        #expect(packageScript.contains("*.vrma"))
        #expect(verifier.contains("*.vrm"))
        #expect(verifier.contains("*.vrma"))
    }

    @Test
    func avatarPackagingContractsPinTaggedWebAndLegalPayloads() throws {
        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/package-dev-app.sh"),
            encoding: .utf8
        )
        let inventoryScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/release-inventory.mjs"),
            encoding: .utf8
        )
        let verifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-release-package.sh"),
            encoding: .utf8
        )
        let provenanceVerifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-provenance.sh"),
            encoding: .utf8
        )
        let contracts = [packageScript, inventoryScript, verifier, provenanceVerifier]
        for required in [
            "miller-avatar-NOTICE.txt",
            "Contents/Resources/Legal/THIRD_PARTY_NOTICES.md",
            "3bf4701ddf53ddc2f54de43d8a86aaf74e988fd913844866b9e4239dfb07c50b",
            "37addfbef220c47fb1cd752fbc51a3f5f68f0b1b5694032a47ef5f474016ca2f",
            "134c871abd0c8b80d029dc67cece05050a2778d7a3dc28d0dcecfea4c8248c28",
            "2efb0201ab0877fdf4d9a7414b937de601d76f19409957c582b0e0839f6891a0",
            "99d30351f5616d95f49794ff07190354fe85608da3a7a801ef688ab36e84c0c7",
            "2f2f955c5e611edd9f52e8178519150768304396cca65fc1777fa46e646b6db6",
            "5f7aced6cebbfe95873ea2c6ad40634d5994c9d18a1e6a247a3e609ec0736478",
            "3164ff84bd29e3dd67896b21094049596ecf02c9ea76a3546cab3fd51304a4ff",
            "Mapbox Earcut 3.0.1",
            "Copyright © 2016 Mapbox",
            "Permission to use, copy, modify",
        ] {
            #expect(
                contracts.contains { $0.contains(required) },
                "missing Avatar closure contract: \(required)"
            )
        }
    }

    @Test
    func avatarDisabledLinkContractDoesNotAccessProfilesOrActivateRenderer() throws {
        let dump = try semanticPackageDump()
        #expect(ReleasePackagingPolicy.hasOnlyAvatarProductsInMillerApp(in: dump))

        let sourceRoot = repositoryRoot.appendingPathComponent("Sources/MillerApp")
        let sourceFiles = try #require(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            )?.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
        )
        let forbiddenActivationTerms = [
            "import MillerAvatarCore",
            "import MillerAvatarHost",
            "MillerAvatarHost",
            "AvatarProfileStore",
            "AvatarSurfaceController",
            "WebKitAvatarRendererDriver",
            "loadModel",
            "activateRenderer",
        ]
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            for term in forbiddenActivationTerms {
                #expect(
                    source.contains(term) == false,
                    "Avatar-disabled MillerApp source activates \(term): \(sourceFile.path)"
                )
            }
        }
    }

    @Test
    func sbomDeclaresTheCapabilityBridgeAsAContainedComponent() throws {
        let data = try Data(contentsOf: repositoryRoot.appending(
            path: "Packaging/Miller.spdx.json"
        ))
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let packages = try #require(document["packages"] as? [[String: Any]])
        #expect(packages.contains { package in
            package["name"] as? String == "MillerCapabilityBridge"
                && package["SPDXID"] as? String
                    == "SPDXRef-Package-MillerCapabilityBridge"
        })
        let relationships = try #require(
            document["relationships"] as? [[String: Any]]
        )
        #expect(relationships.contains { relationship in
            relationship["spdxElementId"] as? String == "SPDXRef-Package-Miller"
                && relationship["relationshipType"] as? String == "CONTAINS"
                && relationship["relatedSpdxElement"] as? String
                    == "SPDXRef-Package-MillerCapabilityBridge"
        })
    }

    @Test
    func sbomDeclaresEmittedMapboxEarcutAsAnISCAvatarDependency() throws {
        let data = try Data(contentsOf: repositoryRoot.appending(
            path: "Packaging/Miller.spdx.json"
        ))
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let packages = try #require(document["packages"] as? [[String: Any]])
        let earcut = try #require(packages.first { package in
            package["name"] as? String == "Mapbox Earcut"
        })
        #expect(earcut["SPDXID"] as? String == "SPDXRef-Package-MapboxEarcut")
        #expect(earcut["versionInfo"] as? String == "3.0.1")
        #expect(earcut["licenseConcluded"] as? String == "ISC")
        #expect(earcut["licenseDeclared"] as? String == "ISC")
        #expect(
            earcut["packageFileName"] as? String
                == "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/app.js"
        )
        let relationships = try #require(
            document["relationships"] as? [[String: Any]]
        )
        #expect(relationships.contains { relationship in
            relationship["spdxElementId"] as? String
                == "SPDXRef-Package-MillerAvatar"
                && relationship["relationshipType"] as? String == "DEPENDS_ON"
                && relationship["relatedSpdxElement"] as? String
                    == "SPDXRef-Package-MapboxEarcut"
        })
    }

    @Test
    func semanticManifestAuthorityIgnoresRawStringDecoys() throws {
        let dump = try semanticPackageDump("""
            {
              "rawStringDecoy": ".package(url: \\\"\(ReleasePackagingPolicy.officialAvatarURL)\\\", exact: \\\"0.1.0-alpha.1\\\") .product(name: \\\"MillerAvatarHost\\\", package: \\\"miller-avatar\\\")",
              "dependencies": [{
                "sourceControl": [{
                  "location": {"remote": [{"urlString": "https://example.invalid/not-avatar.git"}]},
                  "requirement": {"from": ["0.1.0-alpha.1"]}
                }]
              }],
              "targets": [{
                "name": "MillerApp",
                "dependencies": [{"product": ["MillerAvatarCore", "miller-avatar", null, null]}]
              }]
            }
            """)

        #expect(!ReleasePackagingPolicy.hasApprovedAvatarDeclaration(in: dump))
        #expect(!ReleasePackagingPolicy.hasOnlyAvatarProductsInMillerApp(in: dump))
    }

    @Test
    func provenanceManifestAuthorityUsesSwiftPackageDumpJSON() throws {
        let verifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-provenance.sh"),
            encoding: .utf8
        )
        #expect(verifier.contains("dump-package"))
        #expect(verifier.contains("--package-path"))
        #expect(verifier.contains("sourceControl"))
        #expect(verifier.contains("requirement?.exact"))
        #expect(verifier.contains("MillerAvatarApp"))
        #expect(verifier.contains("--ignored"))
        #expect(verifier.contains("removingSwiftComments") == false)
        #expect(verifier.contains("avatarDeclarationPattern") == false)
    }

    @Test
    func semanticAvatarDataRejectsDuplicateCoreAndMissingHost() throws {
        let duplicateCore = try semanticPackageDump("""
            {
              "dependencies": [],
              "targets": [{
                "name": "MillerApp",
                "dependencies": [
                  {"product": ["MillerAvatarCore", "miller-avatar", null, null]},
                  {"product": ["MillerAvatarCore", "miller-avatar", null, null]},
                  {"product": ["MillerAvatarHost", "miller-avatar", null, null]}
                ]
              }]
            }
            """)
        let missingHost = try semanticPackageDump("""
            {
              "dependencies": [],
              "targets": [{
                "name": "MillerApp",
                "dependencies": [
                  {"product": ["MillerAvatarCore", "miller-avatar", null, null]}
                ]
              }]
            }
            """)

        #expect(!ReleasePackagingPolicy.hasOnlyAvatarProductsInMillerApp(in: duplicateCore))
        #expect(!ReleasePackagingPolicy.hasOnlyAvatarProductsInMillerApp(in: missingHost))
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
    func codexRSContentReferenceIsRejected() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try write(
            "let executable = \"/opt/codex-rs/codex\"\n",
            to: fixture.appendingPathComponent("Sources/CodexBridge.swift")
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.contains { $0.contains("codex-rs") })
    }

    @Test
    func programmaticRustToolInvocationsAreRejected() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try write(
            "spawn(\"cargo\", [\"build\"])\nspawn(\"/usr/bin/rustc\", [\"main.rs\"])\n",
            to: fixture.appendingPathComponent("Gateway/src/build.mjs")
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.contains { $0.contains("cargo") })
        #expect(violations.contains { $0.contains("rustc") })
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
            forbidden_runtime="codex-rs"
            rejected_builder="cargo"
            test -z "$(find Sources \\( \\
              -type f \\( -name cargo -o -name rustc \\) -o \\
              -iname '*codex-rs*' \\
            \\) -print -quit)"
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

    @Test
    func productionInventoryRejectsClipboardAndPrivateTranscriptSelectionAuthority() throws {
        let fixture = try makePolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try write(
            """
            let pasteboard = NSPasteboard.generalPasteboard
            let monitor = ClipboardMonitor()
            let fixture = "transcript fixture"
            let export = private transcript export
            """,
            to: fixture.appendingPathComponent(
                "Sources/MillerApp/Presentation/SelectableTranscriptSurface.swift"
            )
        )

        let violations = try ReleasePackagingPolicy.inventoryViolations(
            repositoryRoot: fixture
        )

        #expect(violations.contains { $0.contains("NSPasteboard") })
        #expect(violations.contains { $0.contains("generalPasteboard") })
        #expect(violations.contains { $0.contains("ClipboardMonitor") })
        #expect(violations.contains { $0.contains("transcript fixture") })
        #expect(violations.contains { $0.contains("private transcript export") })
    }

    @Test
    func applicationAndSBOMDeclareTheVerifiedWakeRuntimeComponents() throws {
        let plist = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packaging/Info.plist"),
            encoding: .utf8
        )
        #expect(plist.contains("<string>0.1.2</string>"))

        let data = try Data(contentsOf: repositoryRoot.appending(
            path: "Packaging/Miller.spdx.json"
        ))
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let packages = try #require(document["packages"] as? [[String: Any]])
        let packageNames: [String] = packages.compactMap { package -> String? in
            guard let name = package["name"] as? String,
                  let version = package["versionInfo"] as? String else { return nil }
            return "\(name)@\(version)"
        }
        #expect(packageNames.sorted() == [
            "@miller/pi-mvp-overlay@0.82.0-a3",
            "MCP Swift SDK@0.12.1",
            "Miller Avatar@0.1.0-alpha.1",
            "Miller@0.1.2",
            "MillerCapabilityBridge@0.1.2",
            "MillerCapabilities@0.1.2",
            "Node.js@22.22.0",
            "ONNX Runtime@1.24.4",
            "Sherpa-ONNX@1.13.2",
            "Three.js@0.180.0",
            "@pixiv/three-vrm@3.5.5",
            "@pixiv/three-vrm-animation@3.5.5",
            "Mapbox Earcut@3.0.1",
            "Miller wake model assets@pinned",
            "openai@6.26.0",
            "partial-json@0.1.7",
        ].sorted())
        #expect(packageNames.contains("Sherpa-ONNX@1.13.2"))
        #expect(packageNames.contains("ONNX Runtime@1.24.4"))
        #expect(packageNames.contains("Miller wake model assets@pinned"))
    }

    @Test
    func releasePackagingHasNoFakePayloadAndNeverBootstrapsWakeInputs() throws {
        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/package-dev-app.sh"
            ),
            encoding: .utf8
        )
        let releaseScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/package-release-app.sh"
            ),
            encoding: .utf8
        )
        #expect(packageScript.contains("fake-helper") == false)
        #expect(packageScript.contains("bootstrap-wakeword-dependencies.sh") == false)
        #expect(releaseScript.contains("bootstrap-wakeword-dependencies.sh") == false)
        #expect(packageScript.contains("MillerWakeBridge") == true)
    }

    @Test
    func releaseProvenanceNamesAdHocSigningWithoutCallingBundleUnsigned() throws {
        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/package-dev-app.sh"
            ),
            encoding: .utf8
        )

        #expect(
            packageScript.contains(
                "This release candidate is not Developer ID-signed and is not notarized."
            )
        )
        #expect(packageScript.contains("This unsigned release candidate") == false)
        #expect(packageScript.contains("Signing status: ad-hoc structural verification only."))
    }

    @Test
    func headlessQualificationDeclaresTheDeterministicMatrixAndSafeMarker() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/run-headless-release-qualification.sh"
            ),
            encoding: .utf8
        )
        for required in [
            "MILLER_V0_1_2_READY_HUMAN_NOT_RUN",
            "HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN",
            "MillerCapabilitiesTests",
            "MillerLiveTests",
            "MillerAppTests",
            "MillerStorageTests",
            "fake Pi provider",
            "read-only MCP fixture",
            "state-changing approval",
            "unsupported tool model",
            "selectable transcript composition",
            "post-cleanup retained bytes",
        ] {
            #expect(script.contains(required), "missing headless contract: \(required)")
        }
        #expect(script.contains("MILLER_V0_1_1_RELEASE_APPROVED") == false)
        #expect(script.contains("bootstrap-wakeword-dependencies.sh") == false)
    }

    @Test
    func qualificationDocumentsKeepHeadlessResultAndRecordOwnerApproval() throws {
        let reportURL = repositoryRoot.appendingPathComponent(
            "docs/qualification/v0.1.2-headless-report.md"
        )
        let report = FileManager.default.fileExists(atPath: reportURL.path)
            ? try String(contentsOf: reportURL, encoding: .utf8)
            : nil
        let protocolDocument = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "docs/qualification/v0.1.2-human-protocol.md"
        ), encoding: .utf8)
        if let report {
            #expect(report.contains("HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN"))
            #expect(report.contains("MILLER_V0_1_2_READY_HUMAN_NOT_RUN"))
            #expect(report.contains("MILLER_V0_1_2_RELEASE_APPROVED") == false)
        }
        #expect(protocolDocument.contains("HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN"))
        #expect(protocolDocument.contains("MILLER_V0_1_2_RELEASE_APPROVED"))
        #expect(protocolDocument.contains("RELEASE_APPROVED_WITH_ACCEPTED_DEFERRALS"))
        #expect(protocolDocument.contains("DEFERRED_BY_OWNER"))
        #expect(protocolDocument.contains("External Codex readiness/timeout plus one typed turn"))
        #expect(protocolDocument.contains("Overlay/full-window selection and Command-C"))
        #expect(protocolDocument.contains("GPT-Live speech/transcript/interrupt/end/second session/cleanup"))
        #expect(protocolDocument.contains("Default/custom wake phrase"))
        #expect(protocolDocument.contains("Typed fallback with wake disabled and Live unavailable"))
        #expect(protocolDocument.contains("Reset/removal/relaunch with no lingering helper or microphone owner"))
        #expect(protocolDocument.contains("transcript body") == false)
        #expect(protocolDocument.contains("private path") == false)
        #expect(protocolDocument.contains("OAuth value") == false)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func semanticPackageDump() throws -> [String: Any] {
        // These are the semantic fields emitted by
        // `swift package dump-package --package-path REPO`; the focused tests
        // keep only the fields consumed by the release policy.
        try semanticPackageDump("""
            {
              "dependencies": [
                {
                  "sourceControl": [{
                    "location": {"remote": [{"urlString": "\(ReleasePackagingPolicy.officialSDKURL)"}]},
                    "requirement": {"exact": ["0.12.1"]}
                  }]
                },
                {
                  "sourceControl": [{
                    "location": {"remote": [{"urlString": "\(ReleasePackagingPolicy.officialAvatarURL)"}]},
                    "requirement": {"exact": ["0.1.0-alpha.1"]}
                  }]
                }
              ],
              "targets": [
                {
                  "name": "MillerApp",
                  "dependencies": [
                    {"product": ["MillerAvatarCore", "miller-avatar", null, null]},
                    {"product": ["MillerAvatarHost", "miller-avatar", null, null]}
                  ]
                }
              ]
            }
            """)
    }

    private func semanticPackageDump(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
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
            "Packaging/Miller.version",
        ] {
            try write(relativePath == "Packaging/Miller.version" ? "0.1.2\n" : "{}", to: root.appendingPathComponent(relativePath))
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
    static let officialAvatarURL = "https://github.com/tim-osterhus/miller-avatar.git"
    static let approvedAvatarVersion = "0.1.0-alpha.1"
    static let approvedAvatarRevision = "4f48f55bfeb1fd1f805143bdfadf61ddff541b15"

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
    private static let forbiddenRuntimeTerms = ["codex-rs", "cargo", "rustc"]
    private static let experimentalAPITerms = ["dynamicTools", "item/tool/call"]
    private static let rustCommands = ["cargo", "rustc"]
    private static let forbiddenSelectionTerms = [
        ("nspasteboard", "NSPasteboard"),
        ("generalpasteboard", "generalPasteboard"),
        ("clipboardmonitor", "ClipboardMonitor"),
        ("clipboard monitor", "clipboard monitor"),
        ("transcript fixture", "transcript fixture"),
        ("private transcript export", "private transcript export"),
    ]

    static func hasApprovedSDKDeclaration(in dump: [String: Any]) -> Bool {
        approvedRemoteDependency(
            in: dump,
            url: officialSDKURL,
            version: approvedSDKVersion
        )
    }

    static func hasApprovedSDKLock(_ lock: PackageLock) -> Bool {
        let pins = lock.pins.filter { $0.identity == "swift-sdk" }
        return pins.count == 1
            && pins[0].location == officialSDKURL
            && pins[0].state.version == approvedSDKVersion
            && pins[0].state.revision == approvedSDKRevision
    }

    static func hasApprovedAvatarDeclaration(in dump: [String: Any]) -> Bool {
        approvedRemoteDependency(
            in: dump,
            url: officialAvatarURL,
            version: approvedAvatarVersion
        )
    }

    static func hasApprovedAvatarLock(_ lock: PackageLock) -> Bool {
        let pins = lock.pins.filter { $0.identity == "miller-avatar" }
        return pins.count == 1
            && pins[0].location == officialAvatarURL
            && pins[0].state.version == approvedAvatarVersion
            && pins[0].state.revision == approvedAvatarRevision
    }

    static func hasOnlyAvatarProductsInMillerApp(in dump: [String: Any]) -> Bool {
        let expectedProductNames: Set<String> = ["MillerAvatarCore", "MillerAvatarHost"]
        guard let targets = dump["targets"] as? [[String: Any]],
              !targets.contains(where: { $0["name"] as? String == "MillerAvatarApp" }),
              let millerApp = targets.first(where: { $0["name"] as? String == "MillerApp" }),
              let dependencies = millerApp["dependencies"] as? [[String: Any]] else {
            return false
        }

        var appProducts: [String] = []
        for dependency in dependencies {
            guard let product = dependency["product"] as? [Any],
                  product.count >= 2,
                  let name = product[0] as? String,
                  let package = product[1] as? String else {
                continue
            }
            if package == "miller-avatar" {
                appProducts.append(name)
            }
        }
        guard appProducts.count == expectedProductNames.count,
              Set(appProducts) == expectedProductNames else {
            return false
        }

        let allProductNames = targets
            .flatMap { $0["dependencies"] as? [[String: Any]] ?? [] }
            .compactMap { dependency -> String? in
                guard let product = dependency["product"] as? [Any] else { return nil }
                return product.first as? String
            }
        return !allProductNames.contains("MillerAvatarApp")
    }

    private static func approvedRemoteDependency(
        in dump: [String: Any],
        url: String,
        version: String
    ) -> Bool {
        let matches = (dump["dependencies"] as? [[String: Any]] ?? [])
            .flatMap { $0["sourceControl"] as? [[String: Any]] ?? [] }
            .filter { dependency in
                guard let location = dependency["location"] as? [String: Any],
                      let remotes = location["remote"] as? [[String: Any]],
                      let requirement = dependency["requirement"] as? [String: Any],
                      let exact = requirement["exact"] as? [String] else {
                    return false
                }
                return remotes.count == 1
                    && remotes[0]["urlString"] as? String == url
                    && exact == [version]
            }
        return matches.count == 1
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
        for line in logicalLines(
            in: contents,
            joiningShellContinuations: relativePath.hasPrefix("scripts/")
        ) {
            let text = line.text
            let lowercased = text.lowercased()
            if lowercased.contains("voiceink"),
                !isExplicitAssertion(of: "voiceink", in: lowercased) {
                violations.append(
                    "Forbidden VoiceInk reference in \(relativePath):\(line.number)"
                )
            }
            for term in forbiddenRuntimeTerms
            where containsForbiddenRuntimeTerm(term, in: lowercased)
                && !isExplicitAssertion(of: term, in: lowercased) {
                violations.append(
                    "Forbidden production content \(term) in \(relativePath):\(line.number)"
                )
            }
            for term in experimentalAPITerms where text.contains(term)
                && !isExplicitAssertion(of: term.lowercased(), in: lowercased) {
                violations.append(
                    "Experimental API \(term) in \(relativePath):\(line.number)"
                )
            }
            for (term, label) in forbiddenSelectionTerms
            where lowercased.contains(term) {
                violations.append(
                    "Forbidden selection authority \(label) in \(relativePath):\(line.number)"
                )
            }
            guard relativePath.hasPrefix("scripts/") else { continue }
            for command in rustCommands where invokes(command, in: lowercased) {
                violations.append(
                    "Forbidden \(command) invocation in \(relativePath):\(line.number)"
                )
            }
        }
        return violations
    }

    private static func logicalLines(
        in contents: String,
        joiningShellContinuations: Bool
    ) -> [(number: Int, text: String)] {
        let physicalLines = contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        ).map(String.init)
        guard joiningShellContinuations else {
            return physicalLines.enumerated().map { ($0.offset + 1, $0.element) }
        }

        var result: [(number: Int, text: String)] = []
        var text = ""
        var firstLineNumber = 1
        for (offset, physicalLine) in physicalLines.enumerated() {
            let trimmed = physicalLine.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { firstLineNumber = offset + 1 }
            if trimmed.hasSuffix("\\") {
                text += trimmed.dropLast() + " "
            } else {
                text += trimmed
                result.append((firstLineNumber, text))
                text = ""
            }
        }
        if !text.isEmpty {
            result.append((firstLineNumber, text))
        }
        return result
    }

    private static func containsForbiddenRuntimeTerm(_ term: String, in line: String) -> Bool {
        if term == "codex-rs" {
            return line.contains(term)
        }
        let escapedTerm = NSRegularExpression.escapedPattern(for: term)
        let pattern = "(^|[^a-z0-9])" + escapedTerm + "([^a-z0-9]|$)"
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isExplicitAssertion(of forbiddenTerm: String, in line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let escapedTerm = NSRegularExpression.escapedPattern(for: forbiddenTerm)
        let findBody = #"(?!.*(?:;|&&|\|\||`|\$\()).*(?:-name|-iname)\s+(?:["'][^"']*"#
            + escapedTerm + #"[^"']*["']|[^\s;|&]*"#
            + escapedTerm + #"[^\s;|&]*)(?:\s|$).*"#
        let patterns = [
            #"^(?:forbidden|refused|rejected|denied)_[a-z0-9_]*\s*=\s*["']"#
                + escapedTerm + #"["']\s*(?:#.*)?$"#,
            #"^find\s+"# + findBody + #"$"#,
            #"^test\s+-z\s+"\$\(find\s+"# + findBody + #"\)"\s*$"#,
            #"^(?://|#)\s*(?:deny|forbid|must not|refus|reject).*"#
                + escapedTerm,
        ]
        return patterns.contains {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }
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

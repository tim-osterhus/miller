@testable import MillerLive
import Foundation
import MillerCore
import Testing

@Suite(.serialized)
struct CodexTypedReasoningGatewayTests {
    @Test
    func nextTurnSweepsOnlyValidatedStalePrivateSkillRoots() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "miller-typed-sweep-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let stale = parent.appending(path: "portable-skills-stale")
        let unrelated = parent.appending(path: "ordinary")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data("private".utf8).write(to: stale.appending(path: "SKILL.md"))
        let factory = TypedClientFactory(mode: "typed-normal")
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: parent.path
        )

        let events = try await collect(try await gateway.start(request(
            context: [], userText: "hello"
        )))

        #expect(events.last == .completed)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func unsafeStaleSkillRootFailsClosedWithOwnerVisibleStatus() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "miller-typed-sweep-\(UUID().uuidString)"
        )
        let outside = FileManager.default.temporaryDirectory.appending(
            path: "miller-typed-outside-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: parent.appending(path: "portable-skills-stale"),
            withDestinationURL: outside
        )
        let factory = TypedClientFactory(mode: "typed-normal")
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: parent.path
        )

        let events = try await collect(try await gateway.start(request(
            context: [], userText: "hello"
        )))

        #expect(events == [
            .accepted,
            .status(.portableSkillCleanupPending),
            .failed(
                code: "cleanup_pending",
                message: "Private skill cleanup is pending."
            ),
        ])
        #expect(factory.createdRoots.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func activeTurnCleanupFailureReplacesNormalStopWithTerminalFailure() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "miller-typed-cleanup-\(UUID().uuidString)"
        )
        let outside = FileManager.default.temporaryDirectory.appending(
            path: "miller-typed-outside-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        let marker = parent.appending(path: "turn.txt")
        let factory = TypedClientFactory(
            mode: "typed-portable-skill-wait", extraArguments: [marker.path]
        )
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: parent.path
        )
        let attachment = try PortableSkillAttachment(skills: [.init(
            id: "skill", pluginID: nil, name: "Weather", description: "Private",
            markdown: "Use this private instruction.", sourceHash: "hash", enabled: true
        )])
        let value = request(
            context: [], userText: "wait", portableSkillAttachment: attachment
        )
        let stream = try await gateway.start(value)
        let collector = Task { try await collect(stream) }
        try await waitUntil {
            FileManager.default.fileExists(atPath: marker.path)
                && factory.latestClient?.hasActiveTypedTurn == true
        }
        let materialized = try #require(
            try FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("portable-skills-") }
        )
        try FileManager.default.removeItem(at: materialized)
        try FileManager.default.createSymbolicLink(
            at: materialized, withDestinationURL: outside
        )

        await gateway.cancel(.init(
            turnID: value.turnID, targetGeneration: value.generation
        ))
        let events = try await collector.value

        #expect(events.contains(.status(.portableSkillCleanupPending)))
        #expect(events.last == .failed(
            code: "cleanup_pending",
            message: "Private skill cleanup is pending."
        ))
        #expect(!events.contains(.stopped))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func streamsEphemeralTurnFromBoundedMillerContextAndCleansProcess() async throws {
        let factory = TypedClientFactory(mode: "typed-normal")
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() },
            credential: { credential },
            model: { "gpt-5.6-terra" },
            cwd: repository.path
        )

        let events = try await collect(try await gateway.start(request(
            context: [
                .init(role: .user, text: "older question"),
                .init(role: .assistant, text: "older answer"),
            ],
            userText: "new question"
        )))

        #expect(events == [
            .accepted,
            .textDelta(ordinal: 0, text: "hel"),
            .textDelta(ordinal: 1, text: "lo"),
            .completed,
        ])
        #expect(factory.createdRoots.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func acceptsTurnStartedBeforeTurnStartResponse() async throws {
        let factory = TypedClientFactory(mode: "typed-turn-notification-first")
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        let events = try await collect(try await gateway.start(request(
            context: [], userText: "hello"
        )))
        #expect(events.last == .completed)
        #expect(factory.createdRoots.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func rejectsDuplicateTurnAdmissionAuthority() async throws {
        for mode in [
            "typed-turn-duplicate-response-same",
            "typed-turn-duplicate-response-different",
            "typed-turn-duplicate-notification-same",
            "typed-turn-duplicate-notification-different",
        ] {
            let factory = TypedClientFactory(mode: mode)
            let gateway = CodexTypedReasoningGateway(
                makeClient: { try factory.makeClient() }, credential: { credential },
                model: { "gpt-5.6-terra" }, cwd: repository.path,
                timeout: .milliseconds(500)
            )
            await #expect(throws: CodexTypedProtocolError.invalidSequence) {
                _ = try await collect(try await gateway.start(request(
                    context: [], userText: "hello"
                )))
            }
        }
    }

    @Test
    func acceptsThreadStartedBeforeThreadStartResponse() async throws {
        let factory = TypedClientFactory(mode: "typed-thread-notification-first")
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        let events = try await collect(try await gateway.start(request(
            context: [], userText: "hello"
        )))
        #expect(events.last == .completed)
    }

    @Test
    func newGatewayReconstructsFromMillerContextWithoutResumingProviderThread() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/typed-context-\(UUID().uuidString.lowercased()).jsonl"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        for invocation in 0..<2 {
            let factory = TypedClientFactory(mode: "typed-record", extraArguments: [marker.path])
            let gateway = CodexTypedReasoningGateway(
                makeClient: { try factory.makeClient() }, credential: { credential },
                model: { "gpt-5.6-terra" }, cwd: repository.path
            )
            _ = try await collect(try await gateway.start(request(
                context: [.init(role: .assistant, text: "durable-\(invocation)")],
                userText: "question-\(invocation)"
            )))
        }
        let records = try String(contentsOf: marker, encoding: .utf8)
        let requests = try records.split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(requests.filter { $0["method"] as? String == "thread/start" }.count == 2)
        #expect(!requests.contains { $0["method"] as? String == "thread/resume" })
        #expect(records.contains("durable-0"))
        #expect(records.contains("durable-1"))
    }

    @Test
    func cancellationInterruptsActiveTurnAndCleansProcess() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/typed-interrupt-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let factory = TypedClientFactory(mode: "typed-wait", extraArguments: [marker.path])
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        let value = request(context: [], userText: "wait")
        let stream = try await gateway.start(value)
        let collector = Task { try await collect(stream) }
        do {
            try await waitUntil {
                (try? String(contentsOf: marker, encoding: .utf8)) == "turn-started\n"
                    && factory.latestClient?.hasActiveTypedTurn == true
            }
        } catch {
            Issue.record("typed turn never became active")
            throw error
        }
        await gateway.cancel(.init(
            turnID: value.turnID, targetGeneration: value.generation
        ))
        let events = try await collector.value
        #expect(events.last == .stopped)
        #expect(try String(contentsOf: marker, encoding: .utf8).contains("interrupt"))
        #expect(factory.createdRoots.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func cancellationDuringThreadAdmissionTerminatesAndCleansProcess() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/typed-startup-cancel-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let factory = TypedClientFactory(
            mode: "typed-startup-wait", extraArguments: [marker.path]
        )
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        let value = request(context: [], userText: "wait")
        let collector = Task { try await collect(try await gateway.start(value)) }
        try await waitUntil {
            (try? String(contentsOf: marker, encoding: .utf8)) == "thread-start-pending\n"
        }
        await gateway.cancel(.init(
            turnID: value.turnID, targetGeneration: value.generation
        ))
        _ = try? await collector.value
        try await waitUntil {
            factory.createdRoots.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            }
        }
    }

    @Test
    func cancellationDuringCredentialAdmissionPreventsHelperStartup() async throws {
        let credentialGate = SuspendedTypedCredential()
        let factory = TypedClientFactory(mode: "typed-normal")
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() },
            credential: { await credentialGate.load() },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        let value = request(context: [], userText: "cancel before admission")
        let start = Task { try await gateway.start(value) }
        try await waitUntilAsync { await credentialGate.entered }
        await gateway.cancel(.init(
            turnID: value.turnID, targetGeneration: value.generation
        ))
        await credentialGate.release(credential)
        await #expect(throws: CancellationError.self) { _ = try await start.value }
        #expect(factory.createdRoots.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func refreshesTypedExternalCredentialAndCompletesTurn() async throws {
        let factory = TypedClientFactory(mode: "typed-refresh")
        let gateway = CodexTypedReasoningGateway(
            makeClient: {
                try factory.makeClient(refreshProvider: { accountID in
                    #expect(accountID == "account-1")
                    return .init(
                        accessToken: Data("replacement-token".utf8),
                        accountID: accountID,
                        planType: "plus"
                    )
                })
            },
            credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        let events = try await collect(try await gateway.start(request(
            context: [], userText: "refresh"
        )))
        #expect(events.contains(.textDelta(ordinal: 0, text: "refreshed")))
        #expect(events.last == .completed)
    }

    @Test
    func rejectsStaleAndOversizeProviderSequencesWithoutLeakingSensitiveItems() async throws {
        for mode in ["typed-stale", "typed-hidden-only"] {
            let factory = TypedClientFactory(mode: mode)
            let gateway = CodexTypedReasoningGateway(
                makeClient: { try factory.makeClient() }, credential: { credential },
                model: { "gpt-5.6-terra" }, cwd: repository.path
            )
            if mode == "typed-hidden-only" {
                let events = try await collect(try await gateway.start(request(
                    context: [], userText: "hello"
                )))
                #expect(events == [.accepted, .completed])
            } else {
                await #expect(throws: (any Error).self) {
                    _ = try await collect(try await gateway.start(request(
                        context: [], userText: "hello"
                    )))
                }
            }
            #expect(factory.createdRoots.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            })
        }
    }

    @Test
    func transportsLegitimateBurstsAndPreservesSemanticItemLimit() async throws {
        let burst = TypedClientFactory(mode: "typed-burst")
        let burstGateway = CodexTypedReasoningGateway(
            makeClient: { try burst.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        let burstEvents = try await collect(try await burstGateway.start(request(
            context: [], userText: "burst"
        )))
        #expect(burstEvents.filter {
            if case .textDelta = $0 { return true }
            return false
        }.count == 64)
        #expect(burstEvents.last == .completed)

        let overflow = TypedClientFactory(mode: "typed-too-many")
        let overflowGateway = CodexTypedReasoningGateway(
            makeClient: { try overflow.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        await #expect(throws: CodexTypedProtocolError.tooManyItems) {
            _ = try await collect(try await overflowGateway.start(request(
                context: [], userText: "overflow"
            )))
        }
    }

    @Test
    func rejectsWrongReturnedThreadAuthorityBeforeTurnInput() async throws {
        for mode in [
            "typed-authority-missing-profile",
            "typed-authority-wrong-profile",
            "typed-authority-writable",
            "typed-authority-network",
            "typed-authority-wrong-root",
            "typed-authority-wrong-cwd",
            "typed-authority-persistent",
        ] {
            let marker = repository.appendingPathComponent(
                ".artifacts/\(mode)-\(UUID().uuidString.lowercased()).jsonl"
            )
            defer { try? FileManager.default.removeItem(at: marker) }
            let factory = TypedClientFactory(mode: mode, extraArguments: [marker.path])
            let gateway = CodexTypedReasoningGateway(
                makeClient: { try factory.makeClient() }, credential: { credential },
                model: { "gpt-5.6-terra" }, cwd: repository.path
            )
            await #expect(throws: CodexTypedProtocolError.invalidField) {
                _ = try await collect(try await gateway.start(request(
                    context: [], userText: "must not be sent"
                )))
            }
            let methods = try String(contentsOf: marker, encoding: .utf8)
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
                    return (value as? [String: Any])?["method"] as? String
                }
            #expect(methods.contains("thread/start"))
            #expect(!methods.contains("turn/start"))
        }
    }

    @Test
    func projectsOnlyOpaqueProviderManagedCapabilityActivity() async throws {
        let factory = TypedClientFactory(mode: "typed-capabilities")
        let gateway = CodexTypedReasoningGateway(
            makeClient: { try factory.makeClient() }, credential: { credential },
            model: { "gpt-5.6-terra" }, cwd: repository.path
        )
        let events = try await collect(try await gateway.start(request(
            context: [], userText: "capabilities"
        )))
        let lifecycle = events.compactMap { event -> CapabilityLifecycleEvent? in
            guard case .capabilityLifecycle(let value) = event else { return nil }
            return value
        }
        #expect(lifecycle.count == 6)
        #expect(lifecycle.allSatisfy {
            $0.summary.text.hasPrefix("Opaque Codex ")
                && $0.policy.requiresApproval
                && $0.policy.reason == "provider_approval_required"
        })
        #expect(lifecycle.filter { $0.state == .terminal }.allSatisfy {
            $0.outcome == .succeeded
        })
    }

    @Test
    func boundsUnsupportedApprovalRequestUntilCapabilityHandlingIsAdded() async throws {
        for mode in ["typed-approval", "typed-permissions-approval"] {
            let factory = TypedClientFactory(mode: mode)
            let gateway = CodexTypedReasoningGateway(
                makeClient: { try factory.makeClient() }, credential: { credential },
                model: { "gpt-5.6-terra" }, cwd: repository.path
            )
            let events = try await collect(try await gateway.start(request(
                context: [], userText: "approval"
            )))
            #expect(events == [
                .accepted,
                .failed(
                    code: "provider_unavailable",
                    message: "The reasoning provider is unavailable."
                ),
            ])
            #expect(factory.createdRoots.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            })
        }
    }

    @Test
    func protocolReadinessDependsOnObservedFeaturesNotVersionText() async throws {
        for mode in ["typed-probe-old-version", "typed-probe-new-version"] {
            let client = try TypedClientFactory(mode: mode).makeClient()
            let result = try await client.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
            #expect(result.supportsOrdinaryTurns)
            #expect(result.supportsApps)
            #expect(result.supportsMCPStatus)
            #expect(result.supportsSkills)
            #expect(CodexTypedReadiness.minimumTestedRelease == "0.146.0")
        }
        let unsupported = try TypedClientFactory(mode: "typed-probe-missing").makeClient()
        await #expect(throws: CodexTypedProtocolError.featureUnavailable) {
            _ = try await unsupported.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }
        let noStreaming = try TypedClientFactory(mode: "typed-probe-no-stream").makeClient()
        await #expect(throws: CodexTypedProtocolError.featureUnavailable) {
            _ = try await noStreaming.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }
        let failedAfterStreaming = try TypedClientFactory(
            mode: "typed-probe-failed-terminal"
        ).makeClient()
        await #expect(throws: CodexTypedProtocolError.providerFailed) {
            _ = try await failedAfterStreaming.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }
        let interruptedAfterStreaming = try TypedClientFactory(
            mode: "typed-probe-interrupted-terminal"
        ).makeClient()
        await #expect(throws: CodexTypedProtocolError.providerFailed) {
            _ = try await interruptedAfterStreaming.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }
        let postAdmissionError = try TypedClientFactory(
            mode: "typed-probe-post-admission-error"
        ).makeClient()
        await #expect(throws: CodexTypedProtocolError.providerFailed) {
            _ = try await postAdmissionError.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }
        let failedThread = try TypedClientFactory(mode: "typed-thread-failure").makeClient()
        await #expect(throws: CodexTypedProtocolError.providerFailed) {
            _ = try await failedThread.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }

        let marker = repository.appendingPathComponent(
            ".artifacts/typed-probe-model-\(UUID().uuidString.lowercased()).jsonl"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let selectedModel = "custom-selected-model"
        let recording = try TypedClientFactory(
            mode: "typed-probe-record", extraArguments: [marker.path]
        ).makeClient()
        _ = try await recording.probeTypedFeatures(
            credential: credential,
            model: selectedModel,
            cwd: repository.path,
            timeout: .seconds(2)
        )
        let requests = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n")
            .map { try #require(
                JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            ) }
        let threadStart = try #require(requests.first {
            $0["method"] as? String == "thread/start"
        })
        let threadParams = try #require(threadStart["params"] as? [String: Any])
        #expect(threadParams["model"] as? String == selectedModel)
    }

    @Test
    func readinessPreservesAuthProcessAndProtocolFailureCategories() async throws {
        let refreshUnavailable = try TypedClientFactory(
            mode: "typed-probe-refresh-unavailable"
        ).makeClient()
        await #expect(throws: CodexAppServerClientError.refreshUnavailable) {
            _ = try await refreshUnavailable.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }

        let refreshRejected = try TypedClientFactory(
            mode: "typed-probe-refresh-rejected"
        ).makeClient(refreshProvider: { accountID in
            .init(
                accessToken: credential.accessToken,
                accountID: accountID,
                planType: credential.planType
            )
        })
        await #expect(throws: CodexAppServerClientError.credentialRejected) {
            _ = try await refreshRejected.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }

        let malformed = try TypedClientFactory(mode: "typed-probe-malformed").makeClient()
        await #expect(throws: CodexTypedProtocolError.malformedJSON) {
            _ = try await malformed.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }

        let unavailable = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try .init(
                executableURL: URL(fileURLWithPath: "/private/tmp/miller-no-codex"),
                arguments: ["app-server"],
                temporaryParentURL: repository.appendingPathComponent(".artifacts")
            ))
        )
        await #expect(throws: LiveProcessError.executableMissing) {
            _ = try await unavailable.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }
    }

    @Test
    func localReadinessStopsAfterAuthenticationWithoutStartingAModelTurn() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/typed-readiness-record-\(UUID().uuidString.lowercased()).jsonl"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let client = try TypedClientFactory(
            mode: "typed-readiness-record", extraArguments: [marker.path]
        ).makeClient()

        let result = try await client.probeTypedReadiness(
            credential: credential, timeout: .seconds(2)
        )

        #expect(result.state == .ready)
        #expect(result.executableVerified)
        #expect(result.appServerInitialized)
        #expect(result.authenticated)
        let methods = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line -> String? in
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                return (object as? [String: Any])?["method"] as? String
            }
        #expect(methods == ["initialize", "initialized", "account/login/start"])
        #expect(!methods.contains("thread/start"))
        #expect(!methods.contains("turn/start"))
    }

    @Test
    func readinessCannotReturnReadyWhenPrivateRootCleanupIsPending() async throws {
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/readiness-cleanup-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent, withIntermediateDirectories: true
        )
        defer {
            _ = chmod(temporaryParent.path, 0o700)
            try? FileManager.default.removeItem(at: temporaryParent)
        }
        let revokeParent = OneShotParentPermissionRevoker(parent: temporaryParent)
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, "typed-readiness-record"],
            temporaryParentURL: temporaryParent,
            terminationGrace: .milliseconds(20),
            cleanupPendingDelay: .milliseconds(20),
            cleanupDeadline: .milliseconds(100),
            spawnedProcessVerifier: { _ in try revokeParent.revoke() }
        ))
        let client = CodexAppServerClient(process: process)
        let callback = CleanupPendingRecorder()

        let started = ContinuousClock.now
        let result = try await client.probeTypedReadiness(
            credential: credential,
            timeout: .seconds(2),
            onCleanupPending: { await callback.report() }
        )

        #expect(started.duration(to: ContinuousClock.now) < .seconds(1))
        #expect(result.state == .cleanupPending)
        #expect(result.ownerFacingStatus == "Codex cleanup pending")
        #expect(!result.isReady)
        #expect(process.cleanupPending)
        #expect(FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
        try await waitUntilAsync { await callback.calls == 1 }

        let blockedReuse = try await client.probeTypedReadiness(
            credential: credential, timeout: .seconds(2)
        )
        #expect(blockedReuse.state == .cleanupPending)
        #expect(blockedReuse.ownerFacingStatus == "Codex cleanup pending")

        #expect(chmod(temporaryParent.path, 0o700) == 0)
        #expect(await process.stop() == .completed)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))

        let recovered = try await client.probeTypedReadiness(
            credential: credential, timeout: .seconds(2)
        )
        #expect(recovered.state == .ready)
    }

    @Test
    func readinessKeepsExecutableCredentialAndProtocolStatesDistinct() async throws {
        let missing = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try .init(
                executableURL: URL(fileURLWithPath: "/private/tmp/miller-no-codex"),
                arguments: ["app-server"],
                temporaryParentURL: repository.appendingPathComponent(".artifacts")
            ))
        )
        let missingResult = try await missing.probeTypedReadiness(
            credential: credential, timeout: .seconds(2)
        )
        #expect(missingResult.state == .executableMissing)
        #expect(!missingResult.executableVerified)

        let rejected = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try .init(
                executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
                arguments: [fixture.path, "typed-readiness-record"],
                temporaryParentURL: repository.appendingPathComponent(".artifacts"),
                spawnedProcessVerifier: { _ in throw LiveProcessError.processUnavailable }
            ))
        )
        let rejectedResult = try await rejected.probeTypedReadiness(
            credential: credential, timeout: .seconds(2)
        )
        #expect(rejectedResult.state == .executableRejected)
        #expect(!rejectedResult.executableVerified)

        let invalidCredential = try TypedClientFactory(
            mode: "typed-readiness-record"
        ).makeClient()
        let localCredentialResult = try await invalidCredential.probeTypedReadiness(
            credential: .init(accessToken: Data(), accountID: "", planType: nil),
            timeout: .seconds(2)
        )
        #expect(localCredentialResult.state == .localCredentialUnavailable)
        #expect(localCredentialResult.executableVerified)
        #expect(localCredentialResult.appServerInitialized)
        #expect(!localCredentialResult.authenticated)

        let authRequired = try TypedClientFactory(
            mode: "typed-readiness-login-error"
        ).makeClient()
        let authRequiredResult = try await authRequired.probeTypedReadiness(
            credential: credential, timeout: .seconds(2)
        )
        #expect(authRequiredResult.state == .authenticationRequired)
        #expect(authRequiredResult.executableVerified)
        #expect(authRequiredResult.appServerInitialized)
        #expect(!authRequiredResult.authenticated)

        let initializationFailure = try TypedClientFactory(
            mode: "typed-readiness-initialize-error"
        ).makeClient()
        let initializationResult = try await initializationFailure.probeTypedReadiness(
            credential: credential, timeout: .seconds(2)
        )
        #expect(initializationResult.state == .appServerUnavailable)
        #expect(initializationResult.executableVerified)
        #expect(!initializationResult.appServerInitialized)

        let unsupported = try TypedClientFactory(
            mode: "typed-readiness-malformed"
        ).makeClient()
        let unsupportedResult = try await unsupported.probeTypedReadiness(
            credential: credential, timeout: .seconds(2)
        )
        #expect(unsupportedResult.state == .unsupportedProtocol)
        #expect(unsupportedResult.executableVerified)
        #expect(!unsupportedResult.appServerInitialized)

        for mode in [
            "typed-readiness-initialize-empty",
            "typed-readiness-initialize-wrong",
        ] {
            let malformedInitialize = try TypedClientFactory(mode: mode).makeClient()
            let result = try await malformedInitialize.probeTypedReadiness(
                credential: credential, timeout: .seconds(2)
            )
            #expect(result.state == .unsupportedProtocol)
            #expect(result.executableVerified)
            #expect(!result.appServerInitialized)
        }

        for mode in [
            "typed-readiness-login-empty",
            "typed-readiness-login-wrong",
        ] {
            let malformedLogin = try TypedClientFactory(mode: mode).makeClient()
            let result = try await malformedLogin.probeTypedReadiness(
                credential: credential, timeout: .seconds(2)
            )
            #expect(result.state == .unsupportedProtocol)
            #expect(result.executableVerified)
            #expect(result.appServerInitialized)
            #expect(!result.authenticated)
        }
    }

    @Test
    func optionalRemoteProbeTimesOutExplicitlyAndDoesNotPoisonTheNextTypedUse() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/typed-probe-slow-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let factory = TypedClientFactory(
            mode: "typed-probe-slow-once", extraArguments: [marker.path]
        )
        let client = try factory.makeClient()

        let result = try await client.probeTypedRemote(
            credential: credential,
            model: "gpt-5.6-terra",
            cwd: repository.path,
            timeout: .milliseconds(200)
        )

        #expect(result.state == .remoteProbeTimedOut)
        #expect(result.ownerFacingStatus == "Readiness probe timed out")
        #expect(result.executableVerified)
        #expect(result.appServerInitialized)
        #expect(result.authenticated)
        #expect(!factory.latestProcessIsRunning)
        #expect(!FileManager.default.fileExists(atPath: factory.latestRoot.path))

        var messages: [CodexTypedMessage] = []
        for try await message in client.typedEvents(
            requestID: "after-timeout",
            credential: credential,
            model: "gpt-5.6-terra",
            cwd: repository.path,
            context: [],
            userText: "ordinary use",
            timeout: .seconds(2)
        ) {
            messages.append(message)
        }
        #expect(messages.contains {
            if case .turnCompleted(_, _, .completed) = $0 { true } else { false }
        })
    }

    @Test
    func optionalRemoteProbePreservesSuccessfulInitializationWhenProviderFails() async throws {
        let client = try TypedClientFactory(
            mode: "typed-probe-post-admission-error"
        ).makeClient()

        let result = try await client.probeTypedRemote(
            credential: credential,
            model: "gpt-5.6-terra",
            cwd: repository.path,
            timeout: .seconds(2)
        )

        #expect(result.state == .providerUnavailable)
        #expect(result.executableVerified)
        #expect(result.appServerInitialized)
        #expect(result.authenticated)
    }

    @Test
    func cancellingOptionalRemoteProbeTerminatesItsChildAndCleansItsRoot() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/typed-probe-cancel-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let factory = TypedClientFactory(
            mode: "typed-probe-slow", extraArguments: [marker.path]
        )
        let client = try factory.makeClient()
        let task = Task {
            try await client.probeTypedRemote(
                credential: credential,
                model: "gpt-5.6-terra",
                cwd: repository.path,
                timeout: .seconds(30)
            )
        }
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }

        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await waitUntil { !factory.latestProcessIsRunning }
        #expect(!FileManager.default.fileExists(atPath: factory.latestRoot.path))
    }

    @Test
    func remoteProbeAdmissionRejectsConcurrentTypedUseWithoutSharingItsProcess() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/typed-probe-admission-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let factory = TypedClientFactory(
            mode: "typed-probe-slow", extraArguments: [marker.path]
        )
        let client = try factory.makeClient()
        let probe = Task {
            try await client.probeTypedRemote(
                credential: credential,
                model: "gpt-5.6-terra",
                cwd: repository.path,
                timeout: .seconds(2)
            )
        }
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }

        do {
            for try await _ in client.typedEvents(
                requestID: "concurrent-typed",
                credential: credential,
                model: "gpt-5.6-terra",
                cwd: repository.path,
                context: [],
                userText: "must not share the probe"
            ) {
                Issue.record("typed use unexpectedly reached the shared process")
            }
            Issue.record("concurrent typed use unexpectedly succeeded")
        } catch let error as CodexAppServerClientError {
            #expect(error == .sessionAlreadyActive)
        }
        _ = try await probe.value
        #expect(!factory.latestProcessIsRunning)
        #expect(!FileManager.default.fileExists(atPath: factory.latestRoot.path))
    }

    @Test
    func remoteProbeCannotReturnReadyAfterItsCeilingAndStillCleansUp() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/typed-probe-late-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let factory = TypedClientFactory(
            mode: "typed-probe-late", extraArguments: [marker.path]
        )
        let client = try factory.makeClient()

        let result = try await client.probeTypedRemote(
            credential: credential,
            model: "gpt-5.6-terra",
            cwd: repository.path,
            timeout: .milliseconds(100)
        )

        #expect(result.state == .remoteProbeTimedOut)
        #expect(result.ownerFacingStatus == "Readiness probe timed out")
        #expect(!factory.latestProcessIsRunning)
        #expect(!FileManager.default.fileExists(atPath: factory.latestRoot.path))
    }

    @Test
    func optionalRemoteProbeReportsSuccessfulReadiness() async throws {
        let client = try TypedClientFactory(mode: "typed-probe-new-version").makeClient()

        let result = try await client.probeTypedRemote(
            credential: credential,
            model: "gpt-5.6-terra",
            cwd: repository.path,
            timeout: .seconds(2)
        )

        #expect(result.state == .ready)
        #expect(result.isReady)
        #expect(result.supportsOrdinaryTurns)
        #expect(result.supportsApps)
        #expect(result.supportsMCPStatus)
        #expect(result.supportsSkills)
    }

    @Test
    func mcpBridgeConfigurationUsesProductionConfigAndSecretFreeArguments() throws {
        let token = Data(repeating: 7, count: 32).base64EncodedString()
        let configuration = try CodexMCPBridgeConfiguration(
            executableURL: URL(fileURLWithPath: "/Applications/Miller.app/Contents/Helpers/MillerCapabilityBridge"),
            socketPath: "/private/tmp/miller/capability.sock",
            sessionToken: token,
            providerProfileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            trustedParentPath: "/private/tmp/miller"
        )
        let arguments = configuration.appServerArguments()
        let joined = arguments.joined(separator: " ")
        #expect(joined.contains("mcp_servers.miller-capability-bridge"))
        #expect(joined.contains("env_vars"))
        #expect(joined.contains("required=true"))
        #expect(!joined.contains(token))
        #expect(!joined.contains("dynamicTools"))
        #expect(!joined.contains("item/tool/call"))
        #expect(configuration.additionalEnvironment["MILLER_CAPABILITY_RPC_TOKEN"] == token)
        #expect(throws: LiveProcessError.invalidConfiguration) {
            try CodexMCPBridgeConfiguration(
                executableURL: configuration.executableURL,
                socketPath: "/private/tmp/miller/capability.sock",
                sessionToken: "not-a-session-token",
                providerProfileID: UUID(),
                trustedParentPath: "/private/tmp/miller"
            )
        }
    }

    @Test
    func processAdditionalEnvironmentIsBoundedAndCannotOverrideBaseline() throws {
        #expect(throws: LiveProcessError.invalidConfiguration) {
            try processConfiguration(additionalEnvironment: ["HOME": "/tmp/override"])
        }
        #expect(throws: LiveProcessError.invalidConfiguration) {
            try processConfiguration(additionalEnvironment: [String(repeating: "X", count: 129): "x"])
        }
        #expect(throws: LiveProcessError.invalidConfiguration) {
            try processConfiguration(additionalEnvironment: ["1INVALID": "x"])
        }
        let configuration = try processConfiguration(additionalEnvironment: [
            "MILLER_CAPABILITY_RPC_TOKEN": Data(repeating: 7, count: 32).base64EncodedString(),
        ])
        #expect(configuration.environment["MILLER_CAPABILITY_RPC_TOKEN"] != nil)
        #expect(configuration.environment["HOME"] == configuration.temporaryRootURL.path)
    }

    private func request(
        context: [ReasoningMessage], userText: String,
        portableSkillAttachment: PortableSkillAttachment? = nil
    ) -> ReasoningRequest {
        .init(
            conversationID: .init(), turnID: .init(), generation: 1,
            context: context, userText: userText,
            portableSkillAttachment: portableSkillAttachment
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<ReasoningEvent, Error>
    ) async throws -> [ReasoningEvent] {
        var events: [ReasoningEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func processConfiguration(
        additionalEnvironment: [String: String]
    ) throws -> CodexAppServerProcess.Configuration {
        try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, "typed-normal"],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            additionalEnvironment: additionalEnvironment
        )
    }

    private var fixture: URL {
        Bundle.module.url(
            forResource: "fake-codex-app-server", withExtension: "mjs",
            subdirectory: "Fixtures"
        )!
    }

    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try !predicate() {
            guard ContinuousClock.now < deadline else { throw LiveProcessError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntilAsync(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !predicate() {
            guard ContinuousClock.now < deadline else { throw LiveProcessError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var credential: CodexOAuthCredential {
        .init(accessToken: Data("token".utf8), accountID: "account-1", planType: "plus")
    }
}

private actor SuspendedTypedCredential {
    private var continuation: CheckedContinuation<CodexOAuthCredential, Never>?
    private(set) var entered = false

    func load() async -> CodexOAuthCredential {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ credential: CodexOAuthCredential) {
        continuation?.resume(returning: credential)
        continuation = nil
    }
}

private actor CleanupPendingRecorder {
    private(set) var calls = 0

    func report() { calls += 1 }
}

private final class OneShotParentPermissionRevoker: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private var revoked = false

    init(parent: URL) { self.parent = parent }

    func revoke() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { return }
        guard chmod(parent.path, 0o500) == 0 else {
            throw LiveProcessError.processUnavailable
        }
        revoked = true
    }
}

private final class TypedClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let mode: String
    private let extraArguments: [String]
    private var roots: [URL] = []
    private var clients: [CodexAppServerClient] = []
    private var processes: [CodexAppServerProcess] = []

    init(mode: String, extraArguments: [String] = []) {
        self.mode = mode
        self.extraArguments = extraArguments
    }

    var createdRoots: [URL] {
        lock.lock(); defer { lock.unlock() }
        return roots
    }

    var latestClient: CodexAppServerClient? {
        lock.lock(); defer { lock.unlock() }
        return clients.last
    }

    var latestProcessIsRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return processes.last?.isRunning == true
    }

    var latestRoot: URL {
        lock.lock(); defer { lock.unlock() }
        return roots.last!
    }

    func makeClient(
        refreshProvider: CodexCredentialRefreshProvider? = nil
    ) throws -> CodexAppServerClient {
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, mode] + extraArguments,
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let client = CodexAppServerClient(
            process: process,
            refreshProvider: refreshProvider
        )
        lock.lock()
        roots.append(process.temporaryRootURL)
        clients.append(client)
        processes.append(process)
        lock.unlock()
        return client
    }

    private var fixture: URL {
        Bundle.module.url(
            forResource: "fake-codex-app-server", withExtension: "mjs",
            subdirectory: "Fixtures"
        )!
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

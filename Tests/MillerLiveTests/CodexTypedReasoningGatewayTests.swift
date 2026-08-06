@testable import MillerLive
import Foundation
import MillerCore
import Testing

@Suite(.serialized)
struct CodexTypedReasoningGatewayTests {
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
        for mode in ["typed-stale", "typed-too-many", "typed-hidden-only"] {
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
        await #expect(throws: CodexTypedProtocolError.featureUnavailable) {
            _ = try await failedAfterStreaming.probeTypedFeatures(
                credential: credential, model: "gpt-5.6-terra",
                cwd: repository.path, timeout: .seconds(2)
            )
        }
        let failedThread = try TypedClientFactory(mode: "typed-thread-failure").makeClient()
        await #expect(throws: CodexTypedProtocolError.featureUnavailable) {
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
        context: [ReasoningMessage], userText: String
    ) -> ReasoningRequest {
        .init(
            conversationID: .init(), turnID: .init(), generation: 1,
            context: context, userText: userText
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

private final class TypedClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let mode: String
    private let extraArguments: [String]
    private var roots: [URL] = []
    private var clients: [CodexAppServerClient] = []

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

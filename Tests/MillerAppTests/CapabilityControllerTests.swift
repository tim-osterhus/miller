import Foundation
import MillerCapabilities
import MillerCore
import MillerGateway
@testable import MillerLive
@testable import MillerStorage
import Testing
@testable import MillerApp

@Suite(.serialized)
@MainActor
struct CapabilityControllerTests {
    @Test @MainActor
    func concurrentStartsShareOneStartupAttempt() async {
        let loading = SuspendedRuntimeConfigurationProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loading.load() }
        )

        let first = Task { await controller.start() }
        #expect(await waitForConfigurationRequest(loading))
        let second = Task { await controller.start() }
        await yieldForScheduling()

        #expect(await loading.requestCount == 1)
        await loading.resolveAllAndFuture(with: .init(servers: [], toolPolicies: [:]))
        await first.value
        await second.value
        #expect(await controller.diagnosticsSnapshot().controllerState == "Ready")
    }

    @Test @MainActor
    func suspendedStartupRejectsSettingsMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-start-settings-fence-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let loading = SuspendedRuntimeConfigurationProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loading.load() },
            settingsRepository: repository
        )

        let startup = Task { await controller.start() }
        #expect(await waitForConfigurationRequest(loading))
        let mutation = Task { @MainActor () -> (any Error)? in
            do {
                try await controller.setServerPolicyFromSettings(
                    .fullyTrusted, serverID: server.id
                )
                return nil
            } catch {
                return error
            }
        }
        await yieldForScheduling()

        #expect(await loading.requestCount == 1)
        await loading.resolveAllAndFuture(with: .init(servers: [], toolPolicies: [:]))
        await startup.value
        #expect(await mutation.value as? CapabilityControllerError == .settingsBusy)
        #expect(try await repository.server(id: server.id)?.defaultPolicy
            == .askBeforeChanges)
    }

    @Test @MainActor
    func suspendedStartupRejectsManagedResetWithoutInvokingDeletion() async {
        let loading = SuspendedRuntimeConfigurationProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loading.load() }
        )
        let deletion = AsyncCompletionProbe()

        let startup = Task { await controller.start() }
        #expect(await waitForConfigurationRequest(loading))
        let result = await controller.performManagedReset {
            await deletion.markComplete()
            return .init(roots: [])
        }

        #expect(result.failures.map(\.root) == ["capabilities.runtime_idle"])
        #expect(!(await deletion.isComplete))
        await loading.resolveAll(with: .init(servers: [], toolPolicies: [:]))
        await startup.value
    }

    @Test @MainActor
    func shutdownWaitsForSuspendedStartupAndPreventsPublication() async {
        let loading = SuspendedRuntimeConfigurationProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loading.load() }
        )
        let shutdownCompletion = AsyncCompletionProbe()

        let startup = Task { await controller.start() }
        #expect(await waitForConfigurationRequest(loading))
        let shutdown = Task {
            await controller.shutdown()
            await shutdownCompletion.markComplete()
        }
        await yieldForScheduling()

        #expect(!(await shutdownCompletion.isComplete))
        await loading.resolveAll(with: .init(servers: [], toolPolicies: [:]))
        await startup.value
        await shutdown.value
        #expect(await shutdownCompletion.isComplete)
        #expect(await controller.diagnosticsSnapshot().broker == nil)
    }

    @Test(arguments: StartupCandidateOutcome.allCases) @MainActor
    func shutdownMakesSuspendedStartupCandidateStaleWithoutTouchingNextBroker(
        outcome: StartupCandidateOutcome
    ) async throws {
        let profileID = UUID()
        let tool = MCPDiscoveredTool(
            name: "ping", displayName: "Ping", summary: "Ping",
            inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            readOnlyHint: true
        )
        let first = SuspendedStartupSessionProbe(serverID: "startup")
        let second = CapabilitySessionProbe(serverID: "startup", tool: tool)
        let factory = StartupSessionFactoryProbe(first: first, second: second)
        let configuration = try MCPServerConfiguration(
            id: "startup", displayName: "Startup",
            transport: .stdio(executable: "/usr/bin/true", arguments: []),
            enabled: true, providerProfileIDs: [profileID]
        )
        let controller = CapabilityController(
            loadConfiguration: {
                .init(servers: [configuration], toolPolicies: [:])
            },
            sessionFactory: { _ in try await factory.make() }
        )

        let startup = Task { await controller.start() }
        #expect(await waitForStartupSessionRequest(first))
        let shutdown = Task { await controller.shutdown() }
        await yieldForScheduling()

        await first.resolve(outcome, tool: tool)
        await startup.value
        await shutdown.value

        #expect(await first.disconnectCount == 1)
        #expect(await controller.diagnosticsSnapshot().broker == nil)

        await controller.start()
        #expect(await factory.requestCount == 2)
        #expect(await second.disconnectCount == 0)
        #expect(await controller.diagnosticsSnapshot().broker?.state == .ready)
        await controller.shutdown()
    }

    @Test
    func diagnosticsExposeBoundedSanitizedStartupFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-startup-diagnostics-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let loader = FailFirstCapabilityConfigurationLoad()
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            settingsRepository: repository
        )

        await controller.start()
        let failed = await controller.diagnosticsSnapshot()
        #expect(failed.sanitizedLastFailure == "capability_startup_failed")
        #expect(failed.sanitizedLastFailure?.utf8.count ?? 0 <= 64)

        try await controller.reloadLocalConfiguration()
        let recovered = await controller.diagnosticsSnapshot()
        #expect(recovered.controllerState == "Ready")
        #expect(recovered.sanitizedLastFailure == nil)
    }

    @Test
    func diagnosticsExposeSanitizedBrokerAndAdapterFailures() async throws {
        let profileID = UUID()
        let session = FailingCapabilitySessionProbe(serverID: "broken")
        let controller = CapabilityController(
            loadConfiguration: {
                .init(servers: [try MCPServerConfiguration(
                    id: "broken", displayName: "Broken",
                    transport: .stdio(executable: "/usr/bin/true", arguments: []),
                    enabled: true, providerProfileIDs: [profileID]
                )], toolPolicies: [:])
            },
            sessionFactory: { _ in session }
        )

        await controller.start()
        let brokerFailure = await controller.diagnosticsSnapshot()
        #expect(brokerFailure.sanitizedLastFailure == "capability_broker_failed")

        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-adapter-failure-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let adapterController = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            trustedParent: parent
        )
        let adapterFailure = await adapterController.diagnosticsSnapshot()
        #expect(adapterFailure.sanitizedLastFailure == "capability_adapter_failed")

        let lease = CapabilityRPCRuntime.managedRoot(in: parent)
            .appending(path: CapabilityRPCRuntime.processLeaseName)
        try FileManager.default.createDirectory(
            at: lease.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: lease)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: lease.path
        )
        let adapterRecovered = await adapterController.diagnosticsSnapshot()
        #expect(adapterRecovered.adapterProcessState == .leasePIDAliveUnverified)
        #expect(adapterRecovered.sanitizedLastFailure == nil)

        let failedLoader = FailFirstCapabilityConfigurationLoad()
        let startupAndAdapterController = CapabilityController(
            loadConfiguration: { try await failedLoader.load() },
            trustedParent: FileManager.default.temporaryDirectory.appendingPathComponent(
                "miller-adapter-precedence-\(UUID().uuidString)", isDirectory: true
            )
        )
        await startupAndAdapterController.start()
        #expect(await startupAndAdapterController.diagnosticsSnapshot()
            .sanitizedLastFailure == "capability_startup_failed")
    }

    @Test(arguments: MCPSettingsFailurePhase.allCases)
    func connectionTestFailureReplacesOlderDiagnosticAndRecoveryClearsIt(
        phase: MCPSettingsFailurePhase
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-connection-diagnostics-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(
            policy: .askBeforeChanges, enabled: false
        )
        try await repository.saveServer(server)
        let loader = FailFirstCapabilityConfigurationLoad()
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            sessionFactory: { _ in
                switch phase {
                case .makeSession:
                    throw MCPClientSessionError.connectionClosed
                case .listTools:
                    return FailingCapabilitySessionProbe(serverID: server.id)
                case .descriptorValidation:
                    return CapabilitySessionProbe(
                        serverID: server.id,
                        tool: .init(
                            name: "Invalid Tool", displayName: "Invalid",
                            summary: "Invalid", inputSchemaJSON: Data("{}".utf8),
                            readOnlyHint: true
                        )
                    )
                }
            },
            settingsRepository: repository
        )
        await controller.start()
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure
            == "capability_startup_failed")

        do {
            _ = try await controller.testAndEnableServer(
                serverID: server.id,
                compatibleProviderProfileIDs: [UUID()]
            )
            Issue.record("Connection test unexpectedly succeeded")
        } catch {}

        let failed = await controller.diagnosticsSnapshot()
        #expect(failed.sanitizedLastFailure == phase.expectedDiagnosticCode)
        #expect(failed.sanitizedLastFailure?.utf8.count ?? 0 <= 64)
        try await controller.reloadLocalConfiguration()
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure == nil)
    }

    @Test
    func saveAndRemovePreflightFailuresReplaceOlderDiagnosticAndRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-preflight-diagnostics-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let loader = FailFirstCapabilityConfigurationLoad()
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            settingsRepository: repository
        )
        await controller.start()
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure
            == "capability_startup_failed")
        var draft = MCPServerEditorDraft.newStdio
        draft.id = server.id
        draft.displayName = server.displayName
        draft.executable = "/usr/bin/true"
        draft.createdAt = server.createdAt

        await #expect(throws: CapabilityControllerError.serverIdentityMismatch) {
            try await controller.saveServerSettings(try draft.validated(
                mode: .edit(originalID: "different-server")
            ))
        }
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure
            == "capability_settings_failed")
        try await controller.reloadLocalConfiguration()
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure == nil)

        await #expect(throws: CapabilityStorageError.serverNotFound) {
            try await controller.removeServerFromSettings(serverID: "missing")
        }
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure
            == "capability_settings_failed")
        try await controller.reloadLocalConfiguration()
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure == nil)
    }

    @Test
    func beginAuditFailurePreventsToolExecution() async throws {
        let audit = CapabilityAuditProbe(beginFailures: 1)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )

        do {
            _ = try await fixture.controller.execute(
                callID: CapabilityCallID(),
                capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: .typed(
                    conversationID: ConversationID(),
                    turnID: TurnID(),
                    generation: 1
                ),
                route: .typedPi
            )
            Issue.record("Tool execution continued without a durable begin audit")
        } catch let error as CapabilityControllerError {
            #expect(error == .auditUnavailable)
        }

        #expect(await audit.beginAttempts == 1)
        #expect(await fixture.session.calls == 0)
        #expect(await audit.beginRows == 0)
        #expect(await audit.terminalRows == 0)
    }

    @Test
    func transientTerminalAuditFailureIsRetriedWithoutDuplicateRow() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 1)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )

        _ = try await fixture.controller.execute(
            callID: CapabilityCallID(),
            capabilityID: fixture.capabilityID,
            argumentsJSON: Data("{}".utf8),
            providerProfileID: fixture.profileID,
            association: .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            route: .typedPi
        )

        #expect(await audit.terminalAttempts == 2)
        #expect(await audit.terminalRows == 1)
        #expect(fixture.controller.activityRows.count == 1)
    }

    @Test
    func persistentTerminalAuditFailureFencesLaterExecutionUntilRecovery() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 2)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )

        await #expect(throws: CapabilityControllerError.auditUnavailable) {
            _ = try await fixture.controller.execute(
                callID: CapabilityCallID(),
                capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: .typed(
                    conversationID: ConversationID(),
                    turnID: TurnID(),
                    generation: 1
                ),
                route: .typedPi
            )
        }
        #expect(await fixture.session.calls == 1)
        #expect(await audit.terminalRows == 0)

        await audit.setTerminalFailures(0)
        _ = try await fixture.controller.execute(
            callID: CapabilityCallID(),
            capabilityID: fixture.capabilityID,
            argumentsJSON: Data("{}".utf8),
            providerProfileID: fixture.profileID,
            association: .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 2
            ),
            route: .typedPi
        )

        #expect(await fixture.session.calls == 2)
        #expect(await audit.terminalRows == 2)
        #expect(fixture.controller.activityRows.count == 2)
    }

    @Test
    func preBrokerArgumentRejectionStillClosesItsDurableAudit() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)

        await #expect(throws: CapabilityBrokerError.invalidArguments) {
            _ = try await fixture.controller.execute(
                callID: CapabilityCallID(),
                capabilityID: fixture.capabilityID,
                argumentsJSON: Data("[]".utf8),
                providerProfileID: fixture.profileID,
                association: .typed(
                    conversationID: ConversationID(),
                    turnID: TurnID(),
                    generation: 1
                ),
                route: .typedPi
            )
        }

        #expect(await fixture.audit.beginRows == 1)
        #expect(await fixture.audit.terminalRows == 1)
        #expect(fixture.controller.activityRows.last?.status == "Failed")
        _ = try await fixture.controller.execute(
            callID: CapabilityCallID(),
            capabilityID: fixture.capabilityID,
            argumentsJSON: Data("{}".utf8),
            providerProfileID: fixture.profileID,
            association: .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 2
            ),
            route: .typedPi
        )
        #expect(await fixture.audit.terminalRows == 2)
    }

    @Test
    func shutdownRetriesFailedPiTerminalBeforeRestart() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 2)
        let first = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await #expect(throws: CapabilityControllerError.auditUnavailable) {
            _ = try await first.controller.execute(
                callID: CapabilityCallID(),
                capabilityID: first.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: first.profileID,
                association: .typed(
                    conversationID: ConversationID(),
                    turnID: TurnID(),
                    generation: 1
                ),
                route: .typedPi
            )
        }
        #expect(await audit.openAudits().count == 1)

        await first.controller.shutdown()
        let restarted = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await restarted.controller.start()

        #expect(await audit.openAudits().isEmpty)
        #expect(await audit.outcomes == [.succeeded])
        #expect(await audit.terminalRows == 1)
    }

    @Test
    func shutdownRetriesFailedLocalRPCTerminalBeforeRestart() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 2)
        let trustedParent = try makeTrustedParent()
        let bridgeBox = CapabilityBridgeSessionBox(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let first = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            trustedParent: trustedParent,
            bridgeBox: bridgeBox,
            audit: audit
        )
        let request = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "Use local capability"
        )
        _ = try await first.controller.prepareRequest(
            request,
            providerProfileID: first.profileID,
            kind: .codexOAuth
        )
        let response = try await bridgeClient(bridgeBox).call(
            callID: CapabilityCallID(),
            capabilityID: first.capabilityID,
            argumentsJSON: Data("{}".utf8)
        )
        guard case .failed(_, let code) = response else {
            Issue.record("Expected RPC to report its fenced audit failure")
            await first.controller.shutdown()
            try? FileManager.default.removeItem(at: trustedParent)
            return
        }
        #expect(code == "call_failed")
        #expect(await audit.openAudits().count == 1)

        await first.controller.shutdown()
        let restarted = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await restarted.controller.start()

        #expect(await audit.openAudits().isEmpty)
        #expect(await audit.outcomes == [.succeeded])
        #expect(await audit.terminalRows == 1)
        try? FileManager.default.removeItem(at: trustedParent)
    }

    @Test
    func shutdownRetriesIndependentPendingTerminalsAfterOneFailure() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 4)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            sessionDelay: .milliseconds(25),
            audit: audit
        )
        let conversationID = ConversationID()

        async let first = #expect(throws: CapabilityControllerError.auditUnavailable) {
            _ = try await fixture.controller.execute(
                callID: CapabilityCallID(),
                capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: .typed(
                    conversationID: conversationID,
                    turnID: TurnID(),
                    generation: 1
                ),
                route: .typedPi
            )
        }
        async let second = #expect(throws: CapabilityControllerError.auditUnavailable) {
            _ = try await fixture.controller.execute(
                callID: CapabilityCallID(),
                capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: .typed(
                    conversationID: conversationID,
                    turnID: TurnID(),
                    generation: 2
                ),
                route: .typedPi
            )
        }
        _ = await (first, second)
        #expect(await audit.openAudits().count == 2)

        await audit.setTerminalFailures(1)
        await fixture.controller.shutdown()

        #expect(await audit.openAudits().count == 1)
        #expect(await audit.outcomes == [.succeeded])

        await audit.setTerminalFailures(0)
        await fixture.controller.shutdown()
        #expect(await audit.openAudits().isEmpty)
        #expect(await audit.outcomes == [.succeeded, .succeeded])
    }

    @Test
    func routesTypedPiThroughTheBroker() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()

        let result = try await fixture.controller.execute(
            callID: CapabilityCallID(),
            capabilityID: fixture.capabilityID,
            argumentsJSON: Data(#"{"value":"safe"}"#.utf8),
            providerProfileID: fixture.profileID,
            association: .typed(
                conversationID: ConversationID(), turnID: TurnID(), generation: 7
            ),
            route: .typedPi
        )

        #expect(result.isError == false)
        #expect(await fixture.session.calls == 1)
        #expect(await fixture.audit.terminalRows == 1)
    }

    @Test(arguments: [false, true])
    func routesTypedCodexAndGPTLiveThroughTheAuthenticatedBridge(
        isLiveVoice: Bool
    ) async throws {
        let trustedParent = URL(
            filePath: "/private/tmp/mcc-\(UUID().uuidString.prefix(8))",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: trustedParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let bridgeBox = CapabilityBridgeSessionBox(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            trustedParent: trustedParent,
            bridgeBox: bridgeBox
        )
        await fixture.controller.start()
        if isLiveVoice {
            let preparation = try await fixture.controller.prepareLiveVoice(
                providerProfileID: fixture.profileID
            )
            try fixture.controller.admitVoiceAssociation(
                sessionID: UUID(),
                preparation: preparation
            )
        } else {
            let request = ReasoningRequest(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 2,
                context: [],
                userText: "Use a configured tool."
            )
            _ = try await fixture.controller.prepareRequest(
                request,
                providerProfileID: fixture.profileID,
                kind: .codexOAuth
            )
        }

        let bridge = try #require(try bridgeBox.configuration())
        let socketPath = try #require(
            bridge.additionalEnvironment[CapabilityRPCEnvironment.socketPath]
        )
        let tokenValue = try #require(
            bridge.additionalEnvironment[CapabilityRPCEnvironment.sessionToken]
        )
        let client = CapabilityRPCClient(
            socketURL: URL(fileURLWithPath: socketPath),
            token: try CapabilityRPCSessionToken(environmentValue: tokenValue)
        )
        let response = try await client.call(
            callID: CapabilityCallID(),
            capabilityID: fixture.capabilityID,
            argumentsJSON: Data(#"{"value":"safe"}"#.utf8)
        )

        guard case .result(_, _, let isError) = response else {
            Issue.record("Expected one broker result through the bridge")
            await fixture.controller.shutdown()
            try? FileManager.default.removeItem(at: trustedParent)
            return
        }
        #expect(isError == false)
        #expect(await fixture.session.calls == 1)
        #expect(await fixture.audit.terminalRows == 1)
        await fixture.controller.shutdown()
        try? FileManager.default.removeItem(at: trustedParent)
    }

    @Test
    func rotatesBridgeAuthorityBeforeAdmittingTheNextTypedTurn() async throws {
        let trustedParent = try makeTrustedParent()
        let bridgeBox = CapabilityBridgeSessionBox(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            trustedParent: trustedParent,
            bridgeBox: bridgeBox
        )
        let first = ReasoningRequest(
            conversationID: ConversationID(), turnID: TurnID(), generation: 1,
            context: [], userText: "First turn"
        )
        _ = try await fixture.controller.prepareRequest(
            first, providerProfileID: fixture.profileID, kind: .codexOAuth
        )
        let staleClient = try bridgeClient(bridgeBox)
        await fixture.controller.finishTypedAssociation(
            turnID: first.turnID, generation: first.generation
        )
        let second = ReasoningRequest(
            conversationID: first.conversationID, turnID: TurnID(), generation: 2,
            context: [], userText: "Second turn"
        )
        _ = try await fixture.controller.prepareRequest(
            second, providerProfileID: fixture.profileID, kind: .codexOAuth
        )

        do {
            _ = try await staleClient.send(
                .list(providerProfileID: fixture.profileID)
            )
            Issue.record("Stale bridge authority was accepted")
        } catch let error as CapabilityRPCError {
            #expect(error == .authenticationFailed || error == .peerDisconnected)
        } catch {
            Issue.record("Unexpected stale-authority error: \(error)")
        }
        let currentResponse = try await bridgeClient(bridgeBox).send(
            .list(providerProfileID: fixture.profileID)
        )
        guard case .catalog(let catalog) = currentResponse else {
            Issue.record("Expected current bridge authority to remain usable")
            await fixture.controller.shutdown()
            try? FileManager.default.removeItem(at: trustedParent)
            return
        }
        #expect(catalog.count == 1)
        await fixture.controller.shutdown()
        try? FileManager.default.removeItem(at: trustedParent)
    }

    @Test
    func interruptCancelsRunningVoiceRPCAndDiscardsItsLateResult() async throws {
        let trustedParent = try makeTrustedParent()
        let bridgeBox = CapabilityBridgeSessionBox(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            trustedParent: trustedParent,
            bridgeBox: bridgeBox,
            sessionDelay: .milliseconds(100)
        )
        let preparation = try await fixture.controller.prepareLiveVoice(
            providerProfileID: fixture.profileID
        )
        try fixture.controller.admitVoiceAssociation(
            sessionID: UUID(),
            preparation: preparation
        )
        let callID = CapabilityCallID()
        let call = Task {
            try await bridgeClient(bridgeBox).call(
                callID: callID,
                capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8)
            )
        }
        try await waitForSessionCalls(1, fixture.session)

        fixture.controller.declinePendingApprovals(for: .interrupt)
        let response = try await call.value

        #expect(response == .failed(callID, code: "cancelled"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(fixture.controller.activityRows.last?.status != "Succeeded")
        await fixture.controller.shutdown()
        try? FileManager.default.removeItem(at: trustedParent)
    }

    @Test
    func readOnlyAutomaticExecutesDeclaredReadOnlyWithoutPrompt() async throws {
        let fixture = try makeFixture(
            policy: .readOnlyAutomatic, readOnly: true
        )
        await fixture.controller.start()

        _ = try await fixture.controller.execute(
            callID: CapabilityCallID(), capabilityID: fixture.capabilityID,
            argumentsJSON: Data("{}".utf8),
            providerProfileID: fixture.profileID,
            association: .typed(
                conversationID: ConversationID(), turnID: TurnID(), generation: 1
            ), route: .typedPi
        )

        #expect(fixture.controller.pendingApproval == nil)
        #expect(await fixture.session.calls == 1)
    }

    @Test
    func stateChangingCallPromptsAndAllowsOnlyOnce() async throws {
        let fixture = try makeFixture(
            policy: .askBeforeChanges, readOnly: false
        )
        await fixture.controller.start()
        let task = Task { @MainActor in
            try await fixture.controller.execute(
                callID: CapabilityCallID(), capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: .typed(
                    conversationID: ConversationID(), turnID: TurnID(), generation: 2
                ), route: .typedCodex
            )
        }

        let approval = try await waitForApproval(fixture.controller)
        #expect(approval.origin == "Miller MCP")
        #expect(approval.server == "Notes")
        #expect(approval.tool == "Replace note")
        #expect(approval.intent == "Replace one note.")
        #expect(approval.policy == .askBeforeChanges)
        fixture.controller.resolveApproval(.allowOnce)
        _ = try await task.value

        #expect(await fixture.session.calls == 1)
        #expect(await fixture.audit.decisions == [.allowOnce])
    }

    @Test
    func fullyTrustedAndPerToolOverrideExecuteWithoutPrompt() async throws {
        for override in [CapabilityPolicy.fullyTrusted, nil] {
            let fixture = try makeFixture(
                policy: .askBeforeChanges,
                readOnly: false,
                toolOverride: override,
                serverPolicyWhenNoOverride: .fullyTrusted
            )
            await fixture.controller.start()
            _ = try await fixture.controller.execute(
                callID: CapabilityCallID(), capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: .typed(
                    conversationID: ConversationID(), turnID: TurnID(), generation: 3
                ), route: .typedPi
            )
            #expect(fixture.controller.pendingApproval == nil)
            #expect(await fixture.session.calls == 1)
        }
    }

    @Test
    func providerMandatoryApprovalCannotBeSelfApprovedByVoice() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let providerCapability = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        )
        let request = try providerApprovalRequest(
            capabilityID: providerCapability
        )
        let task = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(
                request,
                association: .voice(sessionID: UUID(), generation: 9)
            )
        }

        let approval = try await waitForApproval(fixture.controller)
        #expect(approval.origin == "Provider")
        #expect(approval.requiresVisualConfirmation)
        #expect(fixture.controller.liveVoiceConfirmationMessage
            == "Confirmation required")
        #expect(fixture.controller.acceptSpokenApproval(callID: request.callID) == false)
        fixture.controller.resolveApproval(.allowOnce)
        #expect(await task.value == .allowOnce)
    }

    @Test
    func liveApprovalAnnouncesOnceAndKeepsExecutionPausedUntilVisualDecision() async throws {
        let announcements = CapabilityAnnouncementProbe()
        let fixture = try makeFixture(
            policy: .askBeforeChanges,
            readOnly: false,
            confirmationAnnouncer: { announcements.record($0) }
        )
        let association = CapabilityAssociation.voice(
            sessionID: UUID(),
            generation: 1
        )
        let allowed = Task { @MainActor in
            try await fixture.controller.execute(
                callID: CapabilityCallID(),
                capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: association,
                route: .gptLive
            )
        }
        _ = try await waitForApproval(fixture.controller)

        #expect(announcements.messages == ["Confirmation required"])
        #expect(await fixture.session.calls == 0)
        fixture.controller.resolveApproval(.allowOnce)
        _ = try await allowed.value
        #expect(await fixture.session.calls == 1)

        let declined = Task { @MainActor in
            try await fixture.controller.execute(
                callID: CapabilityCallID(),
                capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: association,
                route: .gptLive
            )
        }
        _ = try await waitForApproval(fixture.controller)
        #expect(announcements.messages == [
            "Confirmation required",
            "Confirmation required",
        ])
        fixture.controller.resolveApproval(.decline)
        await #expect(throws: CapabilityBrokerError.declined) {
            try await declined.value
        }
        #expect(await fixture.session.calls == 1)
        #expect(fixture.controller.acceptSpokenApproval(
            callID: CapabilityCallID()
        ) == false)
    }

    @Test
    func providerApprovalWithoutAcceptCannotBeAllowedByTheUI() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let request = try providerApprovalRequest(capabilityID: try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        ))
        let approval = CodexProviderApproval(
            responseID: .string("decline-only"),
            itemID: "decline-item",
            approvalID: nil,
            threadID: "decline-thread",
            turnID: "decline-turn",
            kind: .commandExecution,
            request: request,
            availableDecisions: ["decline", "cancel"],
            toolUserInputQuestionID: nil
        )
        let task = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(approval)
        }

        let presentation = try await waitForApproval(fixture.controller)
        #expect(presentation.canAllowOnce == false)
        fixture.controller.resolveApproval(.allowOnce)

        #expect(await task.value == .decline)
        #expect(await fixture.audit.decisions == [.decline])
        #expect(fixture.controller.activityRows.last?.status == "Declined")
    }

    @Test
    func providerAllowFailsClosedWhenAuditBeginCannotPersist() async throws {
        let audit = CapabilityAuditProbe(beginFailures: 1)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        let requestEnvelope = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "Use the provider tool"
        )
        _ = try await fixture.controller.prepareRequest(
            requestEnvelope,
            providerProfileID: fixture.profileID,
            kind: .codexOAuth
        )
        let callbacks = fixture.controller.capturedProviderCallbacks()
        let request = try providerApprovalRequest(capabilityID: try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        ))
        let approval = CodexProviderApproval(
            responseID: .string("fail-closed"),
            itemID: "fail-closed-item",
            approvalID: nil,
            threadID: "fail-closed-thread",
            turnID: "fail-closed-turn",
            kind: .commandExecution,
            request: request,
            availableDecisions: ["accept", "decline"],
            toolUserInputQuestionID: nil
        )
        let decision = Task {
            await callbacks.approvalDetails(approval)
        }
        _ = try await waitForApproval(fixture.controller)
        fixture.controller.resolveApproval(.allowOnce)

        #expect(await decision.value == .decline)
        #expect(await audit.beginAttempts == 2)
        #expect(await audit.beginRows == 1)
        #expect(await audit.decisions == [.decline])
        await fixture.controller.finishTypedAssociation(
            turnID: requestEnvelope.turnID,
            generation: requestEnvelope.generation
        )
    }

    @Test
    func providerApprovalUpgradeFailureRecoversATruthfulDecline() async throws {
        let audit = CapabilityAuditProbe(requireApprovalFailures: 2)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        let requestEnvelope = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "Use the provider tool"
        )
        _ = try await fixture.controller.prepareRequest(
            requestEnvelope,
            providerProfileID: fixture.profileID,
            kind: .codexOAuth
        )
        let callbacks = fixture.controller.capturedProviderCallbacks()
        let capabilityID = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        )
        let started = CodexCapabilityActivity(
            threadID: "approval-upgrade-thread",
            turnID: "approval-upgrade-turn",
            itemID: "approval-upgrade-item",
            capabilityID: capabilityID,
            phase: .started,
            outcome: nil,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )
        await callbacks.activity(started)
        let approval = CodexProviderApproval(
            responseID: .string("approval-upgrade-response"),
            itemID: started.itemID,
            approvalID: nil,
            threadID: started.threadID,
            turnID: started.turnID!,
            kind: .commandExecution,
            request: try providerApprovalRequest(capabilityID: capabilityID),
            availableDecisions: ["accept", "decline"],
            toolUserInputQuestionID: nil
        )

        #expect(await callbacks.approvalDetails(approval) == .decline)
        #expect(fixture.controller.pendingApproval == nil)
        #expect(await audit.requireApprovalAttempts == 2)
        #expect(await audit.approvalRequests == [false])
        #expect(await audit.terminalRows == 0)
        await callbacks.activity(CodexCapabilityActivity(
            threadID: started.threadID,
            turnID: started.turnID,
            itemID: started.itemID,
            capabilityID: capabilityID,
            phase: .terminal,
            outcome: .failed,
            summary: started.summary,
            visibility: .opaqueProviderActivity
        ))

        await fixture.controller.shutdown()

        #expect(await audit.requireApprovalAttempts == 3)
        #expect(await audit.approvalRequests == [true])
        #expect(await audit.decisions == [.decline])
        #expect(await audit.outcomes == [.declined])
        #expect(await audit.openAudits().isEmpty)
    }

    @Test
    func providerCallbacksCapturedForAnOldTurnCannotAttachToANewTurn() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        let first = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "First turn"
        )
        _ = try await fixture.controller.prepareRequest(
            first,
            providerProfileID: fixture.profileID,
            kind: .codexOAuth
        )
        let staleCallbacks = fixture.controller.capturedProviderCallbacks()
        await fixture.controller.cancelTypedAssociation(
            turnID: first.turnID,
            generation: first.generation
        )
        let second = ReasoningRequest(
            conversationID: first.conversationID,
            turnID: TurnID(),
            generation: 2,
            context: [],
            userText: "Second turn"
        )
        _ = try await fixture.controller.prepareRequest(
            second,
            providerProfileID: fixture.profileID,
            kind: .codexOAuth
        )
        let request = try providerApprovalRequest(capabilityID: try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        ))
        let approval = CodexProviderApproval(
            responseID: .string("stale"),
            itemID: "stale-item",
            approvalID: nil,
            threadID: "stale-thread",
            turnID: "stale-turn",
            kind: .commandExecution,
            request: request,
            availableDecisions: ["accept", "decline"],
            toolUserInputQuestionID: nil
        )
        let callback = Task {
            await staleCallbacks.approvalDetails(approval)
        }
        try await Task.sleep(for: .milliseconds(20))
        let staleWasPresented = fixture.controller.pendingApproval != nil
        if staleWasPresented { fixture.controller.resolveApproval(.decline) }

        #expect(await callback.value == .decline)
        #expect(staleWasPresented == false)
        await fixture.controller.finishTypedAssociation(
            turnID: second.turnID,
            generation: second.generation
        )
    }

    @Test(arguments: [false, true])
    func shutdownRejectsPreviouslyCapturedProviderCallbacks(
        isVoice: Bool
    ) async throws {
        let authorityBox = CapabilityProviderCallbackAuthorityBox()
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            providerCallbackAuthorityBox: authorityBox
        )
        if isVoice {
            let preparation = try await fixture.controller.prepareLiveVoice(
                providerProfileID: fixture.profileID
            )
            try fixture.controller.admitVoiceAssociation(
                sessionID: UUID(),
                preparation: preparation
            )
        } else {
            _ = try await fixture.controller.prepareRequest(
                ReasoningRequest(
                    conversationID: ConversationID(),
                    turnID: TurnID(),
                    generation: 1,
                    context: [],
                    userText: "Typed provider turn"
                ),
                providerProfileID: fixture.profileID,
                kind: .codexOAuth
            )
        }
        let callbacks = fixture.controller.capturedProviderCallbacks()
        #expect(authorityBox.current() != nil)

        await fixture.controller.shutdown()
        #expect(authorityBox.current() == nil)

        let capabilityID = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "web-search"
        )
        await callbacks.activity(CodexCapabilityActivity(
            threadID: "shutdown-activity-\(isVoice)",
            turnID: "shutdown-turn-\(isVoice)",
            itemID: "shutdown-item-\(isVoice)",
            capabilityID: capabilityID,
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        ))
        let approval = try providerApproval(
            id: "shutdown-approval-\(isVoice)",
            capabilityID: capabilityID
        )
        let callback = Task {
            await callbacks.approvalDetails(approval)
        }
        try await Task.sleep(for: .milliseconds(20))
        let wasPresented = fixture.controller.pendingApproval != nil
        if wasPresented { fixture.controller.resolveApproval(.decline) }

        #expect(await callback.value == .decline)
        #expect(wasPresented == false)
        #expect(await fixture.audit.beginRows == 0)
    }

    @Test
    func suspendedProviderApprovalResumesAsDeclinedAfterTurnCancellation() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        let first = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "First turn"
        )
        _ = try await fixture.controller.prepareRequest(
            first,
            providerProfileID: fixture.profileID,
            kind: .codexOAuth
        )
        let callbacks = fixture.controller.capturedProviderCallbacks()
        let request = try providerApprovalRequest(capabilityID: try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        ))
        let approval = CodexProviderApproval(
            responseID: .string("suspended"),
            itemID: "suspended-item",
            approvalID: nil,
            threadID: "suspended-thread",
            turnID: "suspended-turn",
            kind: .commandExecution,
            request: request,
            availableDecisions: ["accept", "decline"],
            toolUserInputQuestionID: nil
        )
        let decision = Task {
            await callbacks.approvalDetails(approval)
        }
        _ = try await waitForApproval(fixture.controller)

        await fixture.controller.cancelTypedAssociation(
            turnID: first.turnID,
            generation: first.generation
        )
        let second = ReasoningRequest(
            conversationID: first.conversationID,
            turnID: TurnID(),
            generation: 2,
            context: [],
            userText: "Second turn"
        )
        _ = try await fixture.controller.prepareRequest(
            second,
            providerProfileID: fixture.profileID,
            kind: .codexOAuth
        )

        #expect(await decision.value == .decline)
        #expect(fixture.controller.pendingApproval == nil)
        await fixture.controller.finishTypedAssociation(
            turnID: second.turnID,
            generation: second.generation
        )
    }

    @Test
    func liveProviderCallbacksAuditOnlyTheAdmittedVoiceSession() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        let firstPreparation = try await fixture.controller.prepareLiveVoice(
            providerProfileID: fixture.profileID
        )
        let callbacks = fixture.controller.capturedProviderCallbacks()
        let sessionID = UUID()
        try fixture.controller.admitVoiceAssociation(
            sessionID: sessionID,
            preparation: firstPreparation
        )
        let activity = CodexCapabilityActivity(
            threadID: "voice-thread",
            turnID: "voice-turn",
            itemID: "voice-item",
            capabilityID: try CapabilityID(
                source: .providerNative,
                serverID: "codex",
                toolName: "web-search"
            ),
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )

        await callbacks.activity(activity)
        #expect(await fixture.audit.records.map(\.voiceSessionID) == [sessionID])
        await fixture.controller.finishLiveVoice()

        let secondPreparation = try await fixture.controller.prepareLiveVoice(
            providerProfileID: fixture.profileID
        )
        try fixture.controller.admitVoiceAssociation(
            sessionID: UUID(),
            preparation: secondPreparation
        )
        await callbacks.activity(activity)
        #expect(await fixture.audit.beginRows == 1)
        await fixture.controller.finishLiveVoice()
    }

    @Test
    func controllerReconcilesProviderProjectionAfterProfileChanges() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        let profile = try ProviderProfile(
            id: fixture.profileID,
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            isSelected: true
        )
        let providerCapability = try CapabilityID(
            source: .codexAccount,
            serverID: "gmail",
            toolName: "search"
        )
        let providerDescriptor = try CapabilityDescriptor(
            id: providerCapability,
            source: .codexAccount,
            serverID: "gmail",
            toolName: "search",
            displayName: "Search Gmail",
            summary: "Search connected mail.",
            inputSchemaJSON: Data("{}".utf8),
            readOnlyHint: true,
            providerProfileIDs: [fixture.profileID],
            isAvailable: true,
            visibility: .providerManaged
        )
        let projection = ProviderProjectionProbe(
            profile: profile,
            snapshot: try CapabilityCatalogSnapshot([providerDescriptor])
        )
        fixture.controller.configureProviderProjection(.init(
            selectedProfile: { await projection.selectedProfile() },
            inventory: { profile, local in
                await projection.inventory(profile: profile, local: local)
            }
        ))

        await fixture.controller.reconcileProviderProjection()
        let initial = await fixture.controller.catalog(
            providerProfileID: fixture.profileID
        )
        let request = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "Do not refresh unchanged provider inventory"
        )
        _ = try await fixture.controller.prepareRequest(
            request,
            providerProfileID: fixture.profileID,
            kind: .codexOAuth
        )
        await fixture.controller.finishTypedAssociation(
            turnID: request.turnID,
            generation: request.generation
        )
        await projection.setProfile(nil)
        await fixture.controller.reconcileProviderProjection()
        let removed = await fixture.controller.catalog(
            providerProfileID: fixture.profileID
        )

        #expect(initial.descriptors.contains { $0.id == providerCapability })
        #expect(!removed.descriptors.contains { $0.id == providerCapability })
        #expect(await projection.inventoryCalls == 1)
        #expect(await projection.localSources == [[.millerMCP]])
    }

    @Test(arguments: [
        CapabilityApprovalTermination.close,
        .interrupt,
        .timeout,
    ])
    func closeInterruptAndTimeoutDecline(
        termination: CapabilityApprovalTermination
    ) async throws {
        let fixture = try makeFixture(
            policy: .askBeforeChanges,
            readOnly: false,
            approvalTimeout: .milliseconds(20)
        )
        await fixture.controller.start()
        let request = try providerApprovalRequest(
            capabilityID: fixture.capabilityID
        )
        let task = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(
                request,
                association: .voice(sessionID: UUID(), generation: 4)
            )
        }
        _ = try await waitForApproval(fixture.controller)

        switch termination {
        case .close: fixture.controller.declinePendingApprovals(for: .close)
        case .interrupt: fixture.controller.declinePendingApprovals(for: .interrupt)
        case .timeout: try await Task.sleep(for: .milliseconds(40))
        }

        #expect(await task.value == .decline)
        #expect(fixture.controller.pendingApproval == nil)
    }

    @Test
    func closeDeclinesEveryConcurrentApprovalWithoutPromotingAStalePrompt() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let first = try providerApprovalRequest(capabilityID: fixture.capabilityID)
        let second = try providerApprovalRequest(capabilityID: fixture.capabilityID)
        let firstTask = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(
                first,
                association: .voice(sessionID: UUID(), generation: 1)
            )
        }
        let secondTask = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(
                second,
                association: .voice(sessionID: UUID(), generation: 1)
            )
        }
        try await waitForApprovalCount(2, fixture.controller)

        fixture.controller.declinePendingApprovals(for: .close)

        #expect(await firstTask.value == .decline)
        #expect(await secondTask.value == .decline)
        #expect(fixture.controller.pendingApprovalCount == 0)
        #expect(fixture.controller.pendingApproval == nil)
    }

    @Test
    func closingApprovalSurfacePreservesLaterProviderCallbacks() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        let request = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "Use provider capabilities"
        )
        _ = try await fixture.controller.prepareRequest(
            request,
            providerProfileID: fixture.profileID,
            kind: .codexOAuth
        )
        let callbacks = fixture.controller.capturedProviderCallbacks()
        let capabilityID = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        )
        let dismissedApproval = try providerApproval(
            id: "dismissed-surface",
            capabilityID: capabilityID
        )
        let dismissedDecision = Task {
            await callbacks.approvalDetails(dismissedApproval)
        }
        _ = try await waitForApproval(fixture.controller)

        fixture.controller.declinePendingApprovals(for: .close)
        #expect(await dismissedDecision.value == .decline)

        let activity = CodexCapabilityActivity(
            threadID: "after-dismiss-thread",
            turnID: "after-dismiss-turn",
            itemID: "after-dismiss-item",
            capabilityID: capabilityID,
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )
        await callbacks.activity(activity)

        let laterApproval = try providerApproval(
            id: "after-dismiss-approval",
            capabilityID: capabilityID
        )
        let laterDecision = Task {
            await callbacks.approvalDetails(laterApproval)
        }
        _ = try await waitForApproval(fixture.controller)
        fixture.controller.resolveApproval(.allowOnce)
        #expect(await laterDecision.value == .allowOnce)
        await callbacks.activity(CodexCapabilityActivity(
            threadID: laterApproval.threadID,
            turnID: laterApproval.turnID,
            itemID: laterApproval.itemID,
            capabilityID: capabilityID,
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        ))

        #expect(await fixture.audit.outcomes == [
            .declined, .succeeded, .succeeded,
        ])
        await fixture.controller.finishTypedAssociation(
            turnID: request.turnID,
            generation: request.generation
        )
    }

    @Test
    func cancellingAQueuedApprovalRemovesItBeforePresentation() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let first = try providerApprovalRequest(capabilityID: fixture.capabilityID)
        let second = try providerApprovalRequest(capabilityID: fixture.capabilityID)
        let firstTask = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(
                first,
                association: .voice(sessionID: UUID(), generation: 1)
            )
        }
        let secondTask = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(
                second,
                association: .voice(sessionID: UUID(), generation: 1)
            )
        }
        try await waitForApprovalCount(2, fixture.controller)

        secondTask.cancel()
        #expect(await secondTask.value == .decline)
        #expect(fixture.controller.pendingApprovalCount == 1)
        fixture.controller.resolveApproval(.allowOnce)
        #expect(await firstTask.value == .allowOnce)
        #expect(fixture.controller.pendingApproval == nil)
    }

    @Test
    func closingConversationWindowDeclinesItsVisibleApproval() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let request = try providerApprovalRequest(capabilityID: fixture.capabilityID)
        let task = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(
                request,
                association: .typed(
                    conversationID: ConversationID(),
                    turnID: TurnID(),
                    generation: 1
                )
            )
        }
        _ = try await waitForApproval(fixture.controller)
        let model = AppPresentationModel(
            dependencies: emptyHostDependencies(),
            capabilityController: fixture.controller
        )
        let windowController = ConversationWindowController(model: model)
        let window = windowController.window!

        #expect(windowController.windowShouldClose(window) == false)
        #expect(await task.value == .decline)
        #expect(fixture.controller.pendingApproval == nil)
    }

    @Test
    func staleGenerationIsDeclinedBeforeBrokerExecution() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let conversationID = ConversationID()
        let turnID = TurnID()
        try fixture.controller.admitTypedAssociation(
            .typed(conversationID: conversationID, turnID: turnID, generation: 12),
            providerProfileID: fixture.profileID
        )
        await fixture.controller.cancelTypedAssociation(
            turnID: turnID,
            generation: 12
        )

        await #expect(throws: CapabilityControllerError.staleGeneration) {
            try await fixture.controller.execute(
                callID: CapabilityCallID(), capabilityID: fixture.capabilityID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.profileID,
                association: .typed(
                    conversationID: conversationID, turnID: turnID, generation: 12
                ), route: .typedPi
            )
        }
        #expect(await fixture.session.calls == 0)
        #expect(await fixture.audit.terminalRows == 0)
    }

    @Test
    func terminalLifecyclePersistsAndPresentsExactlyOnce() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let callID = CapabilityCallID()
        let association = CapabilityAssociation.typed(
            conversationID: ConversationID(), turnID: TurnID(), generation: 5
        )

        _ = try await fixture.controller.execute(
            callID: callID, capabilityID: fixture.capabilityID,
            argumentsJSON: Data(#"{"secret":"must-not-appear"}"#.utf8),
            providerProfileID: fixture.profileID,
            association: association, route: .typedPi
        )

        #expect(await fixture.audit.beginRows == 1)
        #expect(await fixture.audit.terminalRows == 1)
        #expect(fixture.controller.activityRows.count == 1)
        #expect(fixture.controller.activityRows[0].status == "Succeeded")
        #expect(!fixture.controller.activityRows[0].displayText.contains("secret"))
        #expect(!fixture.controller.activityRows[0].displayText.contains("safe"))
    }

    @Test
    func opaqueProviderTerminalActivityAuditsExactlyOnceWithoutInventedApproval() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let activity = CodexCapabilityActivity(
            threadID: "thread-1",
            turnID: "turn-1",
            itemID: "item-1",
            capabilityID: try CapabilityID(
                source: .providerNative,
                serverID: "codex",
                toolName: "web-search"
            ),
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )

        await fixture.controller.recordProviderActivity(activity)
        await fixture.controller.recordProviderActivity(activity)

        #expect(await fixture.audit.beginRows == 1)
        #expect(await fixture.audit.terminalRows == 1)
        #expect(await fixture.audit.approvalRequests == [false])
        #expect(fixture.controller.activityRows.count == 1)
    }

    @Test
    func millerSystemProviderApprovalUsesExactOriginLabel() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let capabilityID = MillerSystemCapability.screenObserve.capabilityID
        let descriptor = try CapabilityDescriptor(
            id: capabilityID,
            source: .millerSystem,
            serverID: "system",
            toolName: "screen_observe",
            displayName: "Observe screen",
            summary: "Observe the active window.",
            inputSchemaJSON: Data("{}".utf8),
            readOnlyHint: true,
            providerProfileIDs: [fixture.profileID],
            isAvailable: true,
            visibility: .providerManaged
        )
        fixture.controller.replaceProviderCatalog(
            try CapabilityCatalogSnapshot([descriptor])
        )
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )

        let request = try providerApprovalRequest(capabilityID: capabilityID)
        let approval = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(request)
        }
        let presentation = try await waitForApproval(fixture.controller)

        #expect(presentation.origin == "Miller system")
        fixture.controller.resolveApproval(.decline)
        #expect(await approval.value == .decline)
    }

    @Test
    func providerTerminalAuditFailureRemainsFencedUntilRecovery() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 1)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await fixture.controller.start()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let activity = CodexCapabilityActivity(
            threadID: "failed-audit-thread",
            turnID: "failed-audit-turn",
            itemID: "failed-audit-item",
            capabilityID: try CapabilityID(
                source: .providerNative,
                serverID: "codex",
                toolName: "web-search"
            ),
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )

        await fixture.controller.recordProviderActivity(activity)
        #expect(await audit.terminalRows == 0)

        _ = try await fixture.controller.execute(
            callID: CapabilityCallID(),
            capabilityID: fixture.capabilityID,
            argumentsJSON: Data("{}".utf8),
            providerProfileID: fixture.profileID,
            association: .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 2
            ),
            route: .typedPi
        )

        #expect(await audit.terminalRows == 2)
        #expect(fixture.controller.activityRows.count == 2)
    }

    @Test
    func providerAuditRetainsTheFirstSeenStartTimestamp() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let capabilityID = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "web-search"
        )
        let started = CodexCapabilityActivity(
            threadID: "timing-thread",
            turnID: "timing-turn",
            itemID: "timing-item",
            capabilityID: capabilityID,
            phase: .started,
            outcome: nil,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )
        await fixture.controller.recordProviderActivity(started)
        try await Task.sleep(for: .milliseconds(20))
        await fixture.controller.recordProviderActivity(CodexCapabilityActivity(
            threadID: started.threadID,
            turnID: started.turnID,
            itemID: started.itemID,
            capabilityID: capabilityID,
            phase: .terminal,
            outcome: .succeeded,
            summary: started.summary,
            visibility: .opaqueProviderActivity
        ))

        let startedAt = try #require(await fixture.audit.records.first?.startedAt)
        let terminalObservedAt = try #require(
            await fixture.audit.terminalObservedAt.first
        )
        #expect(startedAt < terminalObservedAt)
    }

    @Test
    func providerStartedActivityPersistsBeginBeforeTerminal() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        await fixture.controller.recordProviderActivity(CodexCapabilityActivity(
            threadID: "durable-start-thread",
            turnID: "durable-start-turn",
            itemID: "durable-start-item",
            capabilityID: try CapabilityID(
                source: .providerNative,
                serverID: "codex",
                toolName: "web-search"
            ),
            phase: .started,
            outcome: nil,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        ))

        #expect(await fixture.audit.beginRows == 1)
        #expect(await fixture.audit.terminalRows == 0)
    }

    @Test
    func restartCancelsDurableProviderStartWithoutATerminalEvent() async throws {
        let audit = CapabilityAuditProbe()
        let first = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await first.controller.start()
        try first.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: first.profileID
        )
        await first.controller.recordProviderActivity(CodexCapabilityActivity(
            threadID: "crashed-provider-thread",
            turnID: "crashed-provider-turn",
            itemID: "crashed-provider-item",
            capabilityID: try CapabilityID(
                source: .providerNative,
                serverID: "codex",
                toolName: "web-search"
            ),
            phase: .started,
            outcome: nil,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        ))
        #expect(await audit.openAudits().count == 1)

        let restarted = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await restarted.controller.start()

        #expect(await audit.openAudits().isEmpty)
        #expect(await audit.outcomes == [.cancelled])
        #expect(await audit.terminalRows == 1)
    }

    @Test
    func providerMandatoryApprovalCorrelatesWithItsOpaqueTerminalActivity() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let conversationID = ConversationID()
        let turnID = TurnID()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: conversationID,
                turnID: turnID,
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let capabilityID = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        )
        let started = CodexCapabilityActivity(
            threadID: "thread-approved",
            turnID: "turn-approved",
            itemID: "item-approved",
            capabilityID: capabilityID,
            phase: .started,
            outcome: nil,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )
        await fixture.controller.recordProviderActivity(started)
        let request = try providerApprovalRequest(capabilityID: capabilityID)
        let approval = CodexProviderApproval(
            responseID: .string("approval-response"),
            itemID: started.itemID,
            approvalID: nil,
            threadID: started.threadID,
            turnID: started.turnID!,
            kind: .commandExecution,
            request: request,
            availableDecisions: ["accept", "decline"],
            toolUserInputQuestionID: nil
        )
        let decision = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(approval)
        }
        _ = try await waitForApproval(fixture.controller)
        fixture.controller.resolveApproval(.allowOnce)
        #expect(await decision.value == .allowOnce)
        let terminal = CodexCapabilityActivity(
            threadID: started.threadID,
            turnID: started.turnID,
            itemID: started.itemID,
            capabilityID: capabilityID,
            phase: .terminal,
            outcome: .succeeded,
            summary: started.summary,
            visibility: .opaqueProviderActivity
        )

        await fixture.controller.recordProviderActivity(terminal)

        #expect(await fixture.audit.beginRows == 1)
        #expect(await fixture.audit.terminalRows == 1)
        #expect(await fixture.audit.approvalRequests == [true])
        #expect(await fixture.audit.decisions == [.allowOnce])
        #expect(fixture.controller.activityRows.last?.status == "Succeeded")
    }

    @Test
    func providerTerminalAuditFailureFencesLaterProviderApproval() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 2)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await fixture.controller.start()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let capabilityID = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "web-search"
        )
        let activity = CodexCapabilityActivity(
            threadID: "audit-fence-thread",
            turnID: "audit-fence-turn",
            itemID: "audit-fence-item",
            capabilityID: capabilityID,
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )
        await fixture.controller.recordProviderActivity(activity)
        #expect(await audit.terminalRows == 0)

        let laterApproval = CodexProviderApproval(
            responseID: .string("later-approval-response"),
            itemID: "later-approval-item",
            approvalID: nil,
            threadID: "later-approval-thread",
            turnID: "later-approval-turn",
            kind: .commandExecution,
            request: try providerApprovalRequest(capabilityID: capabilityID),
            availableDecisions: ["accept", "decline"],
            toolUserInputQuestionID: nil
        )

        #expect(
            await fixture.controller.resolveProviderApproval(laterApproval)
                == .decline
        )
        #expect(fixture.controller.pendingApproval == nil)
        #expect(await audit.beginRows == 1)
        #expect(await audit.terminalRows == 0)
    }

    @Test
    func associationEndRetriesObservedProviderSuccessWithoutCancellingIt() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 1)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await fixture.controller.start()
        let turnID = TurnID()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: turnID,
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let terminal = CodexCapabilityActivity(
            threadID: "truthful-terminal-thread",
            turnID: "truthful-terminal-turn",
            itemID: "truthful-terminal-item",
            capabilityID: try CapabilityID(
                source: .providerNative,
                serverID: "codex",
                toolName: "web-search"
            ),
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )

        await fixture.controller.recordProviderActivity(terminal)
        #expect(await audit.terminalRows == 0)
        await fixture.controller.finishTypedAssociation(
            turnID: turnID,
            generation: 1
        )

        #expect(await audit.terminalRows == 1)
        #expect(await audit.outcomes == [.succeeded])
        #expect(fixture.controller.activityRows.map(\.status) == ["Succeeded"])
    }

    @Test
    func recoveredProviderTerminalAuditIgnoresLateDuplicateActivity() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 1)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await fixture.controller.start()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: TurnID(),
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let capabilityID = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "web-search"
        )
        let failedTerminal = CodexCapabilityActivity(
            threadID: "recovered-thread",
            turnID: "recovered-turn",
            itemID: "recovered-item",
            capabilityID: capabilityID,
            phase: .terminal,
            outcome: .succeeded,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        )
        await fixture.controller.recordProviderActivity(failedTerminal)
        await audit.setTerminalFailures(0)

        let firstApprovalRequest = try providerApproval(
            id: "after-recovery",
            capabilityID: capabilityID
        )
        let firstApproval = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(firstApprovalRequest)
        }
        _ = try await waitForApproval(fixture.controller)
        fixture.controller.resolveApproval(.decline)
        #expect(await firstApproval.value == .decline)
        let beginAttemptsAfterRecovery = await audit.beginAttempts

        await fixture.controller.recordProviderActivity(failedTerminal)
        #expect(await audit.beginAttempts == beginAttemptsAfterRecovery)

        let secondApprovalRequest = try providerApproval(
            id: "after-duplicate",
            capabilityID: capabilityID
        )
        let secondApproval = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(secondApprovalRequest)
        }
        _ = try await waitForApproval(fixture.controller)
        fixture.controller.resolveApproval(.decline)
        #expect(await secondApproval.value == .decline)
    }

    @Test
    func sessionEndCancelsAndTerminalizesUnfinishedProviderActivity() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let turnID = TurnID()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: turnID,
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        await fixture.controller.recordProviderActivity(CodexCapabilityActivity(
            threadID: "thread-unfinished",
            turnID: "turn-unfinished",
            itemID: "item-unfinished",
            capabilityID: try CapabilityID(
                source: .providerNative,
                serverID: "codex",
                toolName: "web-search"
            ),
            phase: .started,
            outcome: nil,
            summary: try CapabilitySummary(text: "Provider details unavailable"),
            visibility: .opaqueProviderActivity
        ))

        await fixture.controller.finishTypedAssociation(
            turnID: turnID,
            generation: 1
        )

        #expect(await fixture.audit.beginRows == 1)
        #expect(await fixture.audit.terminalRows == 1)
        #expect(fixture.controller.activityRows.last?.status == "Cancelled")
    }

    @Test
    func sessionEndTerminalizesApprovedProviderActivityWithItsDecision() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let turnID = TurnID()
        try fixture.controller.admitTypedAssociation(
            .typed(
                conversationID: ConversationID(),
                turnID: turnID,
                generation: 1
            ),
            providerProfileID: fixture.profileID
        )
        let capabilityID = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "file-change"
        )
        let request = try providerApprovalRequest(capabilityID: capabilityID)
        let approval = CodexProviderApproval(
            responseID: .string("close-response"),
            itemID: "close-item",
            approvalID: nil,
            threadID: "close-thread",
            turnID: "close-turn",
            kind: .fileChange,
            request: request,
            availableDecisions: ["accept", "decline"],
            toolUserInputQuestionID: nil
        )
        let decision = Task { @MainActor in
            await fixture.controller.resolveProviderApproval(approval)
        }
        _ = try await waitForApproval(fixture.controller)
        fixture.controller.resolveApproval(.allowOnce)
        #expect(await decision.value == .allowOnce)

        await fixture.controller.finishTypedAssociation(
            turnID: turnID,
            generation: 1
        )

        #expect(await fixture.audit.approvalRequests == [true])
        #expect(await fixture.audit.decisions == [.allowOnce])
        #expect(await fixture.audit.terminalRows == 1)
        #expect(fixture.controller.activityRows.last?.status == "Cancelled")
    }

    @Test
    func brokerApprovalEventsAreNotRehandledByTheGatewayWrapper() async throws {
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            approvalTimeout: .milliseconds(10)
        )
        let providerCapability = try CapabilityID(
            source: .providerNative,
            serverID: "codex",
            toolName: "command-execution"
        )
        let approval = try providerApprovalRequest(
            capabilityID: providerCapability
        )
        let base = ApprovalEchoGateway(approval: approval)
        let profile = try ProviderProfile(
            id: fixture.profileID,
            kind: .openAICompatible,
            label: "Compatible",
            baseURL: "https://api.deepseek.com",
            model: "test-model",
            isSelected: true
        )
        let gateway = CapabilityReasoningGateway(
            base: base,
            selectedProfile: { profile },
            controller: fixture.controller
        )
        let request = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "Use a tool."
        )

        let events = try await gateway.start(request)
        var eventCount = 0
        for try await _ in events { eventCount += 1 }

        #expect(eventCount == 2)
        #expect(fixture.controller.pendingApproval == nil)
        #expect(await base.resolveCalls == 0)
    }

    @Test
    func settingsSnapshotIsBoundedAndSeparatesCodexAppsFromMillerTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-capability-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("miller.sqlite3").path
        let repository = try SQLiteCapabilityRepository(path: path)
        let profileID = UUID()
        let server = CapabilityServerRecord(
            id: "notes", displayName: "Notes", transport: .stdio,
            command: "/usr/bin/true", endpoint: nil, arguments: [], enabled: false,
            defaultPolicy: .askBeforeChanges, staleState: .current,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        try await repository.saveServer(server)
        let secretReference = UUID()
        try await repository.saveSecretBinding(.init(
            id: UUID(),
            serverID: "notes",
            kind: .environment,
            name: "NOTES_TOKEN",
            credentialReference: secretReference
        ))
        let local = try CapabilityDescriptor(
            id: CapabilityID(source: .millerMCP, serverID: "notes", toolName: "lookup"),
            source: .millerMCP, serverID: "notes", toolName: "lookup",
            displayName: "Lookup", summary: "private provider payload must not project",
            inputSchemaJSON: Data(#"{"secretSchema":"must not project"}"#.utf8),
            readOnlyHint: true, providerProfileIDs: [profileID], isAvailable: true
        )
        try await repository.reconcileCatalog(serverID: "notes", descriptors: [local])
        try await repository.setPolicyOverride(.fullyTrusted, toolID: local.id)
        let controller = CapabilityController(
            loadConfiguration: {
                .init(
                    servers: [try MCPServerConfiguration(
                        id: "notes", displayName: "Notes",
                        transport: .stdio(executable: "/usr/bin/true", arguments: []),
                        enabled: false
                    )],
                    toolPolicies: [local.id: .fullyTrusted]
                )
            },
            settingsRepository: repository
        )
        let codex = try CapabilityDescriptor(
            id: CapabilityID(source: .codexAccount, serverID: "gmail", toolName: "search"),
            source: .codexAccount, serverID: "gmail", toolName: "search",
            displayName: "Search mail", summary: "raw provider details",
            inputSchemaJSON: Data(#"{"raw":"provider payload"}"#.utf8),
            readOnlyHint: true, providerProfileIDs: [profileID], isAvailable: true,
            visibility: .providerManaged
        )
        controller.replaceProviderCatalog(try .init([codex]))

        let snapshot = try await controller.settingsSnapshot(
            providerNames: [profileID: "Codex"]
        )

        #expect(snapshot.codexApps.map(\.id) == ["gmail"])
        #expect(snapshot.codexApps[0].availabilityLabel == "Codex only")
        #expect(snapshot.servers[0].secretBindings.map(\.credentialReference) == [
            secretReference,
        ])
        #expect(snapshot.servers[0].tools[0].policyOverride == .fullyTrusted)
        let toolFields = Set(Mirror(reflecting: snapshot.servers[0].tools[0]).children.compactMap(\.label))
        #expect(!toolFields.contains("summary"))
        #expect(!toolFields.contains("inputSchemaJSON"))
    }

    @Test
    func controlledSettingsReloadRetainsOverrideOnStaleCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-capability-reload-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let server = CapabilityServerRecord(
            id: "notes", displayName: "Notes", transport: .stdio,
            command: "/usr/bin/true", endpoint: nil, arguments: [], enabled: false,
            defaultPolicy: .askBeforeChanges, staleState: .current,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        try await repository.saveServer(server)
        let descriptor = try CapabilityDescriptor(
            id: CapabilityID(source: .millerMCP, serverID: "notes", toolName: "lookup"),
            source: .millerMCP, serverID: "notes", toolName: "lookup",
            displayName: "Lookup", summary: "Lookup",
            inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            readOnlyHint: true, providerProfileIDs: [], isAvailable: true
        )
        try await repository.reconcileCatalog(serverID: "notes", descriptors: [descriptor])
        try await repository.setPolicyOverride(.fullyTrusted, toolID: descriptor.id)
        let controller = CapabilityController(
            loadConfiguration: {
                .init(
                    servers: [try MCPServerConfiguration(
                        id: "notes", displayName: "Notes",
                        transport: .stdio(executable: "/usr/bin/true", arguments: []),
                        enabled: false
                    )],
                    toolPolicies: [descriptor.id: .fullyTrusted]
                )
            },
            settingsRepository: repository
        )

        try await controller.reloadLocalConfiguration()
        let snapshot = try await controller.settingsSnapshot(providerNames: [:])

        #expect(snapshot.servers[0].tools[0].staleState == .stale)
        #expect(snapshot.servers[0].tools[0].policyOverride == .fullyTrusted)
    }

    @Test
    func activeTurnRejectsEverySettingsWriteAndRetainsBrokerPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-busy-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let profileID = UUID()
        let session = CapabilitySessionProbe(
            serverID: server.id,
            tool: .init(
                name: "change", displayName: "Change", summary: "Change state",
                inputSchemaJSON: Data("{}".utf8), readOnlyHint: false
            )
        )
        let controller = CapabilityController(
            loadConfiguration: {
                .init(
                    servers: [try MCPServerConfiguration(
                        id: server.id, displayName: server.displayName,
                        transport: .stdio(executable: "/usr/bin/true", arguments: []),
                        enabled: true, defaultPolicy: .askBeforeChanges,
                        providerProfileIDs: [profileID]
                    )],
                    toolPolicies: [:]
                )
            },
            sessionFactory: { _ in session },
            approvalTimeout: .milliseconds(10),
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )
        await controller.start()
        let association = CapabilityAssociation.typed(
            conversationID: ConversationID(), turnID: TurnID(), generation: 1
        )
        try controller.admitTypedAssociation(association, providerProfileID: profileID)

        await #expect(throws: CapabilityControllerError.settingsBusy) {
            try await controller.setServerPolicyFromSettings(
                .fullyTrusted, serverID: server.id
            )
        }

        #expect(try await repository.server(id: server.id)?.defaultPolicy == .askBeforeChanges)
        let capabilityID = try CapabilityID(
            source: .millerMCP, serverID: server.id, toolName: "change"
        )
        await #expect(throws: CapabilityBrokerError.declined) {
            _ = try await controller.execute(
                callID: CapabilityCallID(), capabilityID: capabilityID,
                argumentsJSON: Data("{}".utf8), providerProfileID: profileID,
                association: association, route: .typedPi
            )
        }
        #expect(await session.calls == 0)
    }

    @Test
    func suspendedTypedPreparationReservesAuthorityAgainstSettingsMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-typed-preparation-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let profileID = UUID()
        try await SQLiteConversationRepository(path: databasePath).saveProviderProfile(
            try ProviderProfile(
                id: profileID, kind: .codexOAuth, label: "Codex",
                baseURL: nil, model: "gpt-5.6-terra", isSelected: true
            )
        )
        let skill = portableSkillRecord(id: "typed-authority")
        try await repository.saveSkill(skill)
        try await repository.setSkillEnabled(
            true, skillID: skill.id, providerProfileID: profileID
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let loading = SuspendedRuntimeConfigurationProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loading.load() },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )
        let request = ReasoningRequest(
            conversationID: ConversationID(), turnID: TurnID(), generation: 1,
            context: [], userText: "Prepare"
        )
        let preparation = Task { @MainActor in
            try await controller.prepareRequest(
                request, providerProfileID: profileID, kind: .codexOAuth
            )
        }
        #expect(await waitForConfigurationRequest(loading))
        let mutation = Task { @MainActor () -> (any Error)? in
            do {
                try await controller.setServerPolicyFromSettings(
                    .fullyTrusted, serverID: server.id
                )
                return nil
            } catch {
                return error
            }
        }
        let skillDisable = Task { @MainActor () -> (any Error)? in
            do {
                try await controller.setPortableSkillEnabledFromSettings(
                    false, skillID: skill.id, providerProfileID: profileID
                )
                return nil
            } catch { return error }
        }
        let skillDelete = Task { @MainActor () -> (any Error)? in
            do {
                try await controller.deletePortableSkillFromSettings(id: skill.id)
                return nil
            } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(30))

        #expect(await loading.requestCount == 1)
        await loading.resolveAll(with: .init(servers: [], toolPolicies: [:]))
        let prepared = try await preparation.value
        #expect(await mutation.value as? CapabilityControllerError == .settingsBusy)
        #expect(await skillDisable.value as? CapabilityControllerError == .settingsBusy)
        #expect(await skillDelete.value as? CapabilityControllerError == .settingsBusy)
        #expect(prepared.portableSkillAttachment?.skills.map(\.id) == [skill.id])
        await #expect(throws: CapabilityControllerError.settingsBusy) {
            try await controller.setServerPolicyFromSettings(
                .fullyTrusted, serverID: server.id
            )
        }
    }

    @Test
    func suspendedVoicePreparationReservesAuthorityUntilSessionAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-voice-preparation-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let profileID = UUID()
        try await SQLiteConversationRepository(path: databasePath).saveProviderProfile(
            try ProviderProfile(
                id: profileID, kind: .codexOAuth, label: "Codex",
                baseURL: nil, model: "gpt-5.6-terra", isSelected: true
            )
        )
        let skill = portableSkillRecord(id: "voice-authority")
        try await repository.saveSkill(skill)
        try await repository.setSkillEnabled(
            true, skillID: skill.id, providerProfileID: profileID
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let loading = SuspendedRuntimeConfigurationProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loading.load() },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )
        let preparation = Task { @MainActor in
            try await controller.prepareLiveVoice(providerProfileID: profileID)
        }
        #expect(await waitForConfigurationRequest(loading))
        let mutation = Task { @MainActor () -> (any Error)? in
            do {
                try await controller.setServerPolicyFromSettings(
                    .fullyTrusted, serverID: server.id
                )
                return nil
            } catch {
                return error
            }
        }
        let skillDisable = Task { @MainActor () -> (any Error)? in
            do {
                try await controller.setPortableSkillEnabledFromSettings(
                    false, skillID: skill.id, providerProfileID: profileID
                )
                return nil
            } catch { return error }
        }
        let skillDelete = Task { @MainActor () -> (any Error)? in
            do {
                try await controller.deletePortableSkillFromSettings(id: skill.id)
                return nil
            } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(30))

        #expect(await loading.requestCount == 1)
        await loading.resolveAll(with: .init(servers: [], toolPolicies: [:]))
        let voicePreparation = try await preparation.value
        #expect(await mutation.value as? CapabilityControllerError == .settingsBusy)
        #expect(await skillDisable.value as? CapabilityControllerError == .settingsBusy)
        #expect(await skillDelete.value as? CapabilityControllerError == .settingsBusy)
        #expect(try await controller.selectedSkillAttachment(
            providerProfileID: profileID
        )?.skills.map(\.id) == [skill.id])
        try controller.admitVoiceAssociation(
            sessionID: UUID(),
            preparation: voicePreparation
        )
        await #expect(throws: CapabilityControllerError.settingsBusy) {
            try await controller.setServerPolicyFromSettings(
                .fullyTrusted, serverID: server.id
            )
        }
    }

    @Test
    func cancelledSuspendedPreparationReleasesItsReservation() async throws {
        let loading = SuspendedRuntimeConfigurationProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loading.load() }
        )
        let firstRequest = ReasoningRequest(
            conversationID: ConversationID(), turnID: TurnID(), generation: 1,
            context: [], userText: "First"
        )
        let firstPreparation = Task { @MainActor in
            try await controller.prepareRequest(
                firstRequest, providerProfileID: UUID(), kind: .codexOAuth
            )
        }
        #expect(await waitForConfigurationRequest(loading))
        firstPreparation.cancel()
        await loading.resolveAll(with: .init(servers: [], toolPolicies: [:]))
        await #expect(throws: CancellationError.self) {
            _ = try await firstPreparation.value
        }

        let secondRequest = ReasoningRequest(
            conversationID: ConversationID(), turnID: TurnID(), generation: 2,
            context: [], userText: "Second"
        )
        let secondPreparation = Task { @MainActor in
            try await controller.prepareRequest(
                secondRequest, providerProfileID: UUID(), kind: .codexOAuth
            )
        }
        _ = try await secondPreparation.value
        await controller.finishTypedAssociation(
            turnID: secondRequest.turnID,
            generation: secondRequest.generation
        )
    }

    @Test
    func successfulPolicyMutationKeepsSQLiteAndBrokerAuthorityInAgreement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-success-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let profileID = UUID()
        let session = CapabilitySessionProbe(
            serverID: server.id,
            tool: .init(
                name: "change", displayName: "Change", summary: "Change state",
                inputSchemaJSON: Data("{}".utf8), readOnlyHint: false
            )
        )
        let controller = CapabilityController(
            loadConfiguration: {
                guard let record = try await repository.server(id: server.id)
                else { throw CapabilityControllerError.unavailable }
                return .init(
                    servers: [try MCPServerConfiguration(
                        id: record.id, displayName: record.displayName,
                        transport: .stdio(executable: "/usr/bin/true", arguments: []),
                        enabled: true, defaultPolicy: record.defaultPolicy,
                        providerProfileIDs: [profileID]
                    )],
                    toolPolicies: [:]
                )
            },
            sessionFactory: { _ in session },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )

        try await controller.setServerPolicyFromSettings(
            .fullyTrusted, serverID: server.id
        )

        #expect(try await repository.server(id: server.id)?.defaultPolicy == .fullyTrusted)
        #expect(try await controller.settingsSnapshot(providerNames: [:])
            .servers[0].server.defaultPolicy == .fullyTrusted)
        let association = CapabilityAssociation.typed(
            conversationID: ConversationID(), turnID: TurnID(), generation: 1
        )
        try controller.admitTypedAssociation(association, providerProfileID: profileID)
        _ = try await controller.execute(
            callID: CapabilityCallID(),
            capabilityID: CapabilityID(
                source: .millerMCP, serverID: server.id, toolName: "change"
            ),
            argumentsJSON: Data("{}".utf8), providerProfileID: profileID,
            association: association, route: .typedPi
        )
        #expect(await session.calls == 1)
    }

    @Test
    func secretRemovalDeletesSQLiteAndKeychainAndCompensatesDeleteFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-secrets-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let reference = UUID()
        let binding = CapabilitySecretBinding(
            id: UUID(), serverID: server.id, kind: .environment,
            name: "TOKEN", credentialReference: reference
        )
        try await repository.saveSecretBinding(binding)
        let secrets = CapabilitySettingsSecretProbe(values: [reference: "old"])
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository,
            settingsSecrets: secrets.dependencies
        )
        var draft = MCPServerEditorDraft.newStdio
        draft.id = server.id
        draft.displayName = server.displayName
        draft.executable = "/usr/bin/true"
        draft.createdAt = server.createdAt

        try await controller.saveServerSettings(try draft.validated(
            mode: .edit(originalID: server.id)
        ))

        #expect(try await repository.secretBindings(serverID: server.id).isEmpty)
        #expect(await secrets.value(reference) == nil)

        try await repository.saveSecretBinding(binding)
        await secrets.setValue("old", for: reference)
        await secrets.failNextDelete()
        await #expect(throws: CapabilitySettingsMutationError.secretMutationFailed) {
            try await controller.saveServerSettings(try draft.validated(
                mode: .edit(originalID: server.id)
            ))
        }
        #expect(try await repository.secretBindings(serverID: server.id) == [binding])
        #expect(await secrets.value(reference) == "old")
    }

    @Test
    func keychainRecoveryAttemptsEveryCapturedReferenceAfterOneRestoreFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-secret-recovery-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("miller.sqlite3").path
        let seed = try SQLiteCapabilityRepository(path: path)
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await seed.saveServer(server)
        let firstReference = UUID()
        let secondReference = UUID()
        let firstBinding = CapabilitySecretBinding(
            id: UUID(), serverID: server.id, kind: .environment,
            name: "FIRST_TOKEN", credentialReference: firstReference
        )
        let secondBinding = CapabilitySecretBinding(
            id: UUID(), serverID: server.id, kind: .environment,
            name: "SECOND_TOKEN", credentialReference: secondReference
        )
        try await seed.saveSecretBinding(firstBinding)
        try await seed.saveSecretBinding(secondBinding)
        let secrets = CapabilitySettingsSecretProbe(
            values: [firstReference: "old-first", secondReference: "old-second"],
            failFirstOldStore: true
        )
        let loader = FailFirstCapabilityConfigurationLoad()
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            settingsRepository: seed,
            settingsSecrets: secrets.dependencies
        )
        var draft = MCPServerEditorDraft.newStdio
        draft.id = server.id
        draft.displayName = server.displayName
        draft.executable = "/usr/bin/true"
        draft.createdAt = server.createdAt
        draft.secrets = [
            .init(
                id: firstBinding.id, kind: .environment,
                name: firstBinding.name, value: "new-first",
                existingReference: firstReference
            ),
            .init(
                id: secondBinding.id, kind: .environment,
                name: secondBinding.name, value: "new-second",
                existingReference: secondReference
            ),
            .init(kind: .environment, name: "THIRD_TOKEN", value: "new-third"),
        ]
        let validated = try draft.validated(mode: .edit(originalID: server.id))
        let thirdReference = try #require(
            validated.secrets.first(where: { $0.name == "THIRD_TOKEN" })?
                .credentialReference
        )

        await #expect(throws: CapabilitySettingsMutationError.recoveryFailed) {
            try await controller.saveServerSettings(validated)
        }

        #expect(await secrets.attemptedStore(firstReference, value: "old-first"))
        #expect(await secrets.attemptedStore(secondReference, value: "old-second"))
        #expect(await secrets.attemptedDelete(thirdReference))
        #expect(await secrets.value(thirdReference) == nil)
        let firstValue = await secrets.value(firstReference)
        let secondValue = await secrets.value(secondReference)
        let restoredOldValues = [firstValue, secondValue]
            .compactMap { $0 }.filter { $0.hasPrefix("old-") }
        #expect(restoredOldValues.count == 1)
    }

    @Test
    func createAndMaterialEditRequireSuccessfulQualificationBeforeEnablement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-qualification-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let profiles = try SQLiteConversationRepository(path: databasePath)
        let profile = try ProviderProfile(
            kind: .openAICompatible, label: "Compatible",
            baseURL: "https://example.com", model: "model"
        )
        try await profiles.saveProviderProfile(profile)
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let controller = CapabilityController(
            loadConfiguration: {
                try await settingsRuntimeConfiguration(repository: repository)
            },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "new-server"
        draft.displayName = "New Server"
        draft.executable = "/usr/bin/true"
        draft.enabled = true

        try await controller.saveServerSettings(try draft.validated(mode: .create))
        let created = try #require(await repository.server(id: draft.id))
        #expect(!created.enabled)
        #expect(created.staleState == .stale)
        #expect(try await repository.enabledProviderProfileIDs(serverID: draft.id).isEmpty)

        let enabled = CapabilityServerRecord(
            id: created.id, displayName: created.displayName,
            transport: created.transport, command: created.command,
            endpoint: created.endpoint, arguments: [], enabled: true,
            defaultPolicy: created.defaultPolicy, staleState: .current,
            createdAt: created.createdAt, updatedAt: Date()
        )
        try await repository.replaceServerConfiguration(
            server: enabled, secretBindings: [],
            enabledProviderProfileIDs: [profile.id]
        )
        draft.argumentsJSON = #"["--changed"]"#
        draft.enabled = true
        try await controller.saveServerSettings(try draft.validated(
            mode: .edit(originalID: draft.id)
        ))
        let edited = try #require(await repository.server(id: draft.id))
        #expect(!edited.enabled)
        #expect(edited.staleState == .stale)
        #expect(try await repository.enabledProviderProfileIDs(serverID: draft.id).isEmpty)
    }

    @Test
    func settingsEditCannotEnableButCanExplicitlyDisableServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-one-way-enable-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let disabled = settingsControllerServer(
            policy: .askBeforeChanges, enabled: false
        )
        try await repository.saveServer(disabled)
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )
        var draft = MCPServerEditorDraft.newStdio
        draft.id = disabled.id
        draft.displayName = disabled.displayName
        draft.executable = "/usr/bin/true"
        draft.enabled = true
        draft.createdAt = disabled.createdAt

        try await controller.saveServerSettings(try draft.validated(
            mode: .edit(originalID: disabled.id)
        ))
        #expect(try await repository.server(id: disabled.id)?.enabled == false)

        let enabled = CapabilityServerRecord(
            id: disabled.id, displayName: disabled.displayName,
            transport: disabled.transport, command: disabled.command,
            endpoint: disabled.endpoint, arguments: disabled.arguments,
            enabled: true, defaultPolicy: disabled.defaultPolicy,
            staleState: .current, createdAt: disabled.createdAt,
            updatedAt: Date()
        )
        try await repository.replaceServerConfiguration(
            server: enabled, secretBindings: [], enabledProviderProfileIDs: []
        )
        draft.enabled = false

        try await controller.saveServerSettings(try draft.validated(
            mode: .edit(originalID: disabled.id)
        ))
        let explicitlyDisabled = try #require(
            await repository.server(id: disabled.id)
        )
        #expect(!explicitlyDisabled.enabled)
        #expect(explicitlyDisabled.staleState == .stale)
    }

    @Test
    func providerEnablementRequiresQualifiedCurrentServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-provider-qualification-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let profiles = try SQLiteConversationRepository(path: databasePath)
        let profile = try ProviderProfile(
            kind: .openAICompatible, label: "Compatible",
            baseURL: "https://example.com", model: "model"
        )
        try await profiles.saveProviderProfile(profile)
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let disabled = settingsControllerServer(
            policy: .askBeforeChanges, enabled: false
        )
        try await repository.saveServer(disabled)
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )

        await #expect(throws: CapabilityControllerError.serverQualificationRequired) {
            try await controller.setProviderEnabledFromSettings(
                true, serverID: disabled.id, providerProfileID: profile.id
            )
        }
        let stale = CapabilityServerRecord(
            id: disabled.id, displayName: disabled.displayName,
            transport: disabled.transport, command: disabled.command,
            endpoint: disabled.endpoint, arguments: disabled.arguments,
            enabled: true, defaultPolicy: disabled.defaultPolicy,
            staleState: .stale, createdAt: disabled.createdAt,
            updatedAt: Date()
        )
        try await repository.replaceServerConfiguration(
            server: stale, secretBindings: [], enabledProviderProfileIDs: []
        )
        await #expect(throws: CapabilityControllerError.serverQualificationRequired) {
            try await controller.setProviderEnabledFromSettings(
                true, serverID: disabled.id, providerProfileID: profile.id
            )
        }
        let current = CapabilityServerRecord(
            id: stale.id, displayName: stale.displayName,
            transport: stale.transport, command: stale.command,
            endpoint: stale.endpoint, arguments: stale.arguments,
            enabled: true, defaultPolicy: stale.defaultPolicy,
            staleState: .current, createdAt: stale.createdAt,
            updatedAt: Date()
        )
        try await repository.replaceServerConfiguration(
            server: current, secretBindings: [], enabledProviderProfileIDs: []
        )

        try await controller.setProviderEnabledFromSettings(
            true, serverID: current.id, providerProfileID: profile.id
        )

        #expect(try await repository.enabledProviderProfileIDs(
            serverID: current.id
        ) == [profile.id])
    }

    @Test
    func pendingPluginServerCannotConnectOrEnableAProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-plugin-review-fence-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("miller.sqlite3").path
        let profiles = try SQLiteConversationRepository(path: path)
        let profile = try ProviderProfile(
            kind: .openAICompatible, label: "Compatible",
            baseURL: "https://example.com", model: "model"
        )
        try await profiles.saveProviderProfile(profile)
        let repository = try SQLiteCapabilityRepository(path: path)
        let now = Date(timeIntervalSince1970: 100)
        let plugin = PluginPackageRecord(
            id: "review.example", version: nil,
            sourceHash: String(repeating: "a", count: 64),
            supportedComponentSummary: "Review required", enabled: false,
            createdAt: now, updatedAt: now
        )
        let component = PluginMCPComponentRecord(
            pluginID: plugin.id, componentID: "remote",
            projectedServerID: "plugin-review-example-remote",
            transport: .streamableHTTP, absoluteCommand: nil,
            endpoint: "https://example.test/mcp", arguments: [],
            relativeExecutablePath: nil, unresolvedSecretNames: [],
            reviewState: .pending, createdAt: now, updatedAt: now
        )
        try await repository.importPluginSnapshot(
            plugin: plugin, skills: [], mcpComponents: [component], apps: []
        )
        let factory = CapabilitySessionFactoryInvocationProbe()
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            sessionFactory: { _ in
                await factory.record()
                return CapabilitySessionProbe(
                    serverID: component.projectedServerID,
                    tool: .init(
                        name: "lookup", displayName: "Lookup", summary: "Lookup",
                        inputSchemaJSON: Data("{}".utf8), readOnlyHint: true
                    )
                )
            },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )

        await #expect(throws: CapabilityStorageError.pluginReviewRequired) {
            try await controller.testAndEnableServer(
                serverID: component.projectedServerID,
                compatibleProviderProfileIDs: [profile.id]
            )
        }
        await #expect(throws: CapabilityStorageError.pluginReviewRequired) {
            try await controller.setProviderEnabledFromSettings(
                true, serverID: component.projectedServerID,
                providerProfileID: profile.id
            )
        }
        #expect(await factory.count == 0)
        let snapshot = try await controller.settingsSnapshot(providerNames: [:])
        #expect(snapshot.pluginMCPComponents == [component])
    }

    @Test
    func pluginDeletionRemovesOnlyOwnedAggregateAndKeychainReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-plugin-delete-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let now = Date(timeIntervalSince1970: 100)
        let plugin = PluginPackageRecord(
            id: "delete.example", version: nil,
            sourceHash: String(repeating: "a", count: 64),
            supportedComponentSummary: "Review required", enabled: false,
            createdAt: now, updatedAt: now
        )
        let component = PluginMCPComponentRecord(
            pluginID: plugin.id, componentID: "owned",
            projectedServerID: "plugin-delete-example-owned",
            transport: .stdio, absoluteCommand: "/usr/bin/true", endpoint: nil,
            arguments: [], relativeExecutablePath: nil,
            unresolvedSecretNames: ["TOKEN"], reviewState: .pending,
            createdAt: now, updatedAt: now
        )
        try await repository.importPluginSnapshot(
            plugin: plugin, skills: [], mcpComponents: [component], apps: [
                .init(pluginID: plugin.id, appID: "mail", name: "Mail"),
            ]
        )
        let owned = try #require(
            await repository.server(id: component.projectedServerID)
        )
        let reference = UUID()
        try await repository.approvePluginMCPComponent(
            server: owned,
            secretBindings: [.init(
                id: UUID(), serverID: owned.id, kind: .environment,
                name: "TOKEN", credentialReference: reference
            )]
        )
        let unrelated = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(unrelated)
        let secrets = CapabilitySettingsSecretProbe(values: [reference: "secret"])
        let controller = CapabilityController(
            loadConfiguration: {
                try await settingsRuntimeConfiguration(repository: repository)
            },
            settingsRepository: repository,
            settingsSecrets: secrets.dependencies
        )

        try await controller.deletePluginFromSettings(id: plugin.id)

        #expect(await secrets.value(reference) == nil)
        #expect(try await repository.plugins().isEmpty)
        #expect(try await repository.server(id: owned.id) == nil)
        #expect(try await repository.server(id: unrelated.id) != nil)
        #expect(try await repository.pluginApps(pluginID: plugin.id).isEmpty)
    }

    @Test
    func pluginDeletionRestoreFailureLeavesRuntimeUnavailableAndAggregateIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-plugin-delete-recovery-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let now = Date(timeIntervalSince1970: 100)
        let plugin = PluginPackageRecord(
            id: "delete-recovery", version: nil,
            sourceHash: String(repeating: "d", count: 64),
            supportedComponentSummary: "Review required", enabled: false,
            createdAt: now, updatedAt: now
        )
        let components = ["one", "two"].map { id in
            PluginMCPComponentRecord(
                pluginID: plugin.id, componentID: id,
                projectedServerID: "plugin-delete-recovery-\(id)",
                transport: .stdio, absoluteCommand: "/usr/bin/true", endpoint: nil,
                arguments: [], relativeExecutablePath: nil,
                unresolvedSecretNames: ["TOKEN_\(id.uppercased())"],
                reviewState: .pending, createdAt: now, updatedAt: now
            )
        }
        try await repository.importPluginSnapshot(
            plugin: plugin, skills: [], mcpComponents: components, apps: []
        )
        var references: [UUID] = []
        for component in components {
            let server = try #require(
                await repository.server(id: component.projectedServerID)
            )
            let reference = UUID()
            references.append(reference)
            try await repository.approvePluginMCPComponent(
                server: server,
                secretBindings: [.init(
                    id: UUID(), serverID: server.id, kind: .environment,
                    name: component.unresolvedSecretNames[0],
                    credentialReference: reference
                )]
            )
        }
        let secrets = CapabilitySettingsSecretProbe(
            values: Dictionary(uniqueKeysWithValues: references.enumerated().map {
                ($0.element, "old-\($0.offset)")
            }),
            failFirstOldStore: true
        )
        await secrets.failNextDelete()
        let controller = CapabilityController(
            loadConfiguration: {
                try await settingsRuntimeConfiguration(repository: repository)
            },
            settingsRepository: repository,
            settingsSecrets: secrets.dependencies
        )

        await #expect(throws: CapabilitySettingsMutationError.recoveryFailed) {
            try await controller.deletePluginFromSettings(id: plugin.id)
        }

        #expect(try await repository.plugins() == [plugin])
        for (index, reference) in references.enumerated() {
            #expect(await secrets.attemptedStore(reference, value: "old-\(index)"))
        }
        #expect(await controller.diagnosticsSnapshot().controllerState == "Unavailable")
    }

    @Test
    func failedRuntimeReloadRestoresPendingPluginReviewAndSecretFence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-plugin-review-recovery-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let now = Date(timeIntervalSince1970: 100)
        let plugin = PluginPackageRecord(
            id: "review-recovery", version: nil,
            sourceHash: String(repeating: "e", count: 64),
            supportedComponentSummary: "Review required", enabled: false,
            createdAt: now, updatedAt: now
        )
        let component = PluginMCPComponentRecord(
            pluginID: plugin.id, componentID: "worker",
            projectedServerID: "plugin-review-recovery-worker",
            transport: .stdio, absoluteCommand: "/usr/bin/true", endpoint: nil,
            arguments: [], relativeExecutablePath: nil,
            unresolvedSecretNames: ["TOKEN"], reviewState: .pending,
            createdAt: now, updatedAt: now
        )
        try await repository.importPluginSnapshot(
            plugin: plugin, skills: [], mcpComponents: [component], apps: []
        )
        let oldServer = try #require(
            await repository.server(id: component.projectedServerID)
        )
        let loader = FailFirstCapabilityConfigurationLoad()
        let secrets = CapabilitySettingsSecretProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            settingsRepository: repository,
            settingsSecrets: secrets.dependencies
        )
        var draft = MCPServerEditorDraft.newStdio
        draft.id = oldServer.id
        draft.displayName = oldServer.displayName
        draft.executable = "/usr/bin/true"
        draft.createdAt = oldServer.createdAt
        draft.secrets = [.init(
            kind: .environment, name: "TOKEN", value: "new-secret"
        )]
        let validated = try draft.validated(
            mode: .edit(originalID: oldServer.id)
        )
        let reference = try #require(validated.secrets.first?.credentialReference)

        await #expect(throws: CapabilityControllerError.unavailable) {
            try await controller.saveServerSettings(validated)
        }

        #expect(try await repository.server(id: oldServer.id) == oldServer)
        #expect(try await repository.secretBindings(serverID: oldServer.id).isEmpty)
        #expect(try await repository.isPluginServerApproved(oldServer.id) == false)
        #expect(await secrets.value(reference) == nil)
    }

    @Test
    func longValidPluginIdentitiesImportWithoutPoisoningRuntimeConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-plugin-long-identity-\(UUID().uuidString)", isDirectory: true
        )
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent(".codex-plugin"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = String(repeating: "p.", count: 48)
        let componentID = String(repeating: "c.", count: 48)
        try JSONSerialization.data(
            withJSONObject: ["id": pluginID], options: [.sortedKeys]
        ).write(to: bundle.appendingPathComponent(".codex-plugin/plugin.json"))
        try JSONSerialization.data(withJSONObject: [
            "mcpServers": [
                componentID: ["command": "/usr/bin/true", "cwd": "."],
            ],
        ], options: [.sortedKeys]).write(to: bundle.appendingPathComponent(".mcp.json"))
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let controller = CapabilityController(
            loadConfiguration: {
                try await settingsRuntimeConfiguration(repository: repository)
            },
            settingsRepository: repository
        )

        try await controller.importPluginFromSettings(at: bundle)
        let snapshot = try await controller.settingsSnapshot(providerNames: [:])
        let server = try #require(snapshot.servers.first?.server)
        let plugin = try #require(snapshot.plugins.first)
        #expect(server.id.utf8.count <= 96)
        #expect(!server.id.contains("."))
        #expect(server.displayName.utf8.count <= 128)
        #expect(plugin.supportedComponentSummary.contains(
            "Working-directory metadata was not imported; verify command paths manually."
        ))

        await controller.start()
        #expect(await controller.diagnosticsSnapshot().controllerState == "Ready")
        await controller.shutdown()
    }

    @Test
    func missingServerAndToolWritesFailBeforeRollbackAndKeepRuntimeHealthy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-preflight-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository
        )

        await #expect(throws: CapabilityStorageError.serverNotFound) {
            try await controller.setProviderEnabledFromSettings(
                false, serverID: "missing", providerProfileID: UUID()
            )
        }
        await #expect(throws: CapabilityStorageError.toolNotFound) {
            try await controller.setToolPolicyFromSettings(
                .fullyTrusted,
                toolID: CapabilityID(
                    source: .millerMCP,
                    serverID: server.id,
                    toolName: "missing"
                )
            )
        }
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure
            == "capability_settings_failed")

        await controller.start()
        #expect(await controller.diagnosticsSnapshot().controllerState == "Ready")
    }

    @Test
    func uncommittedPolicyWriteFailureDoesNotAttemptRollbackOrPoisonRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-uncommitted-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("miller.sqlite3").path
        let seed = try SQLiteCapabilityRepository(path: path)
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await seed.saveServer(server)
        await seed.close()
        let failing = try SQLiteCapabilityRepository(
            path: path,
            simulatedWriteFailure: .storageFull
        )
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: failing
        )

        await #expect(throws: SQLiteError.storageFull) {
            try await controller.setServerPolicyFromSettings(
                .fullyTrusted, serverID: server.id
            )
        }
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure
            == "capability_settings_failed")

        await controller.start()
        #expect(await controller.diagnosticsSnapshot().controllerState == "Ready")
    }

    @Test
    func uncommittedSaveWriteRestoresSecretsAndPreservesHealthyRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-save-uncommitted-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("miller.sqlite3").path
        let seed = try SQLiteCapabilityRepository(path: path)
        await seed.close()
        let failing = try SQLiteCapabilityRepository(
            path: path, simulatedWriteFailure: .storageFull
        )
        let secrets = CapabilitySettingsSecretProbe()
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: failing,
            settingsSecrets: secrets.dependencies
        )
        await controller.start()
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "new-server"
        draft.displayName = "New Server"
        draft.executable = "/usr/bin/true"
        draft.secrets = [
            .init(kind: .environment, name: "TOKEN", value: "new-secret"),
        ]
        let validated = try draft.validated(mode: .create)
        let reference = try #require(validated.secrets.first?.credentialReference)

        await #expect(throws: SQLiteError.storageFull) {
            try await controller.saveServerSettings(validated)
        }

        #expect(await secrets.attemptedDelete(reference))
        #expect(await secrets.value(reference) == nil)
        let diagnostics = await controller.diagnosticsSnapshot()
        #expect(diagnostics.controllerState == "Ready")
        #expect(diagnostics.sanitizedLastFailure == "capability_settings_failed")
        try await controller.reloadLocalConfiguration()
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure == nil)
    }

    @Test
    func uncommittedRemovalRestoresEverySecretAndPreservesHealthyRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-remove-uncommitted-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("miller.sqlite3").path
        let seed = try SQLiteCapabilityRepository(path: path)
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await seed.saveServer(server)
        let firstReference = UUID()
        let secondReference = UUID()
        try await seed.saveSecretBinding(.init(
            id: UUID(), serverID: server.id, kind: .environment,
            name: "FIRST_TOKEN", credentialReference: firstReference
        ))
        try await seed.saveSecretBinding(.init(
            id: UUID(), serverID: server.id, kind: .environment,
            name: "SECOND_TOKEN", credentialReference: secondReference
        ))
        await seed.close()
        let failing = try SQLiteCapabilityRepository(
            path: path, simulatedWriteFailure: .storageFull
        )
        let secrets = CapabilitySettingsSecretProbe(values: [
            firstReference: "old-first", secondReference: "old-second",
        ])
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: failing,
            settingsSecrets: secrets.dependencies
        )
        await controller.start()

        await #expect(throws: SQLiteError.storageFull) {
            try await controller.removeServerFromSettings(serverID: server.id)
        }

        #expect(await secrets.attemptedStore(firstReference, value: "old-first"))
        #expect(await secrets.attemptedStore(secondReference, value: "old-second"))
        #expect(await secrets.value(firstReference) == "old-first")
        #expect(await secrets.value(secondReference) == "old-second")
        let diagnostics = await controller.diagnosticsSnapshot()
        #expect(diagnostics.controllerState == "Ready")
        #expect(diagnostics.sanitizedLastFailure == "capability_settings_failed")
        try await controller.reloadLocalConfiguration()
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure == nil)
    }

    @Test
    func uncommittedActivationFailurePreservesOriginalErrorAndHealthyRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-activation-uncommitted-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("miller.sqlite3").path
        let seed = try SQLiteCapabilityRepository(path: path)
        let server = settingsControllerServer(
            policy: .askBeforeChanges, enabled: false
        )
        try await seed.saveServer(server)
        await seed.close()
        let failing = try SQLiteCapabilityRepository(
            path: path, simulatedWriteFailure: .storageFull
        )
        let session = CapabilitySessionProbe(
            serverID: server.id,
            tool: .init(
                name: "lookup", displayName: "Lookup", summary: "Lookup",
                inputSchemaJSON: Data("{}".utf8), readOnlyHint: true
            )
        )
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            sessionFactory: { _ in session }, settingsRepository: failing
        )
        await controller.start()

        await #expect(throws: SQLiteError.storageFull) {
            try await controller.testAndEnableServer(
                serverID: server.id,
                compatibleProviderProfileIDs: [UUID()]
            )
        }

        let diagnostics = await controller.diagnosticsSnapshot()
        #expect(diagnostics.controllerState == "Ready")
        #expect(diagnostics.sanitizedLastFailure == "capability_settings_failed")
        try await controller.reloadLocalConfiguration()
        #expect(await controller.diagnosticsSnapshot().sanitizedLastFailure == nil)
    }

    @Test
    func databaseCompensationFailureStillRestoresEveryCapturedSecret() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-independent-secret-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let firstReference = UUID()
        let secondReference = UUID()
        let firstBinding = CapabilitySecretBinding(
            id: UUID(), serverID: server.id, kind: .environment,
            name: "FIRST_TOKEN", credentialReference: firstReference
        )
        let secondBinding = CapabilitySecretBinding(
            id: UUID(), serverID: server.id, kind: .environment,
            name: "SECOND_TOKEN", credentialReference: secondReference
        )
        try await repository.saveSecretBinding(firstBinding)
        try await repository.saveSecretBinding(secondBinding)
        let secrets = CapabilitySettingsSecretProbe(values: [
            firstReference: "old-first", secondReference: "old-second",
        ])
        let loader = CloseRepositoryThenFailConfigurationLoad(repository: repository)
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            settingsRepository: repository,
            settingsSecrets: secrets.dependencies
        )
        var draft = MCPServerEditorDraft.newStdio
        draft.id = server.id
        draft.displayName = server.displayName
        draft.executable = "/usr/bin/true"
        draft.createdAt = server.createdAt
        draft.secrets = [
            .init(
                id: firstBinding.id, kind: .environment,
                name: firstBinding.name, value: "new-first",
                existingReference: firstReference
            ),
            .init(
                id: secondBinding.id, kind: .environment,
                name: secondBinding.name, value: "new-second",
                existingReference: secondReference
            ),
            .init(kind: .environment, name: "THIRD_TOKEN", value: "new-third"),
        ]
        let validated = try draft.validated(mode: .edit(originalID: server.id))
        let thirdReference = try #require(
            validated.secrets.first(where: { $0.name == "THIRD_TOKEN" })?
                .credentialReference
        )

        await #expect(throws: CapabilitySettingsMutationError.recoveryFailed) {
            try await controller.saveServerSettings(validated)
        }

        #expect(await secrets.attemptedStore(firstReference, value: "old-first"))
        #expect(await secrets.attemptedStore(secondReference, value: "old-second"))
        #expect(await secrets.attemptedDelete(thirdReference))
        #expect(await secrets.value(firstReference) == "old-first")
        #expect(await secrets.value(secondReference) == "old-second")
        #expect(await secrets.value(thirdReference) == nil)
    }

    @Test
    func connectionActivationRejectsEmptyCompatibleProviderSetAndKeepsServerDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-empty-providers-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(
            policy: .askBeforeChanges, enabled: false
        )
        try await repository.saveServer(server)
        let session = CapabilitySessionProbe(
            serverID: server.id,
            tool: .init(
                name: "lookup", displayName: "Lookup", summary: "Lookup",
                inputSchemaJSON: Data("{}".utf8), readOnlyHint: true
            )
        )
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            sessionFactory: { _ in session },
            settingsRepository: repository
        )

        await #expect(throws: CapabilityControllerError.providerMismatch) {
            try await controller.testAndEnableServer(
                serverID: server.id,
                compatibleProviderProfileIDs: []
            )
        }

        #expect(try await repository.server(id: server.id)?.enabled == false)
        #expect(try await repository.enabledProviderProfileIDs(
            serverID: server.id
        ).isEmpty)
        #expect(try await repository.catalog(serverID: server.id).isEmpty)
    }

    @Test
    func createCollisionAndEditIdentityMismatchFailBeforeSecretWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-identity-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let secrets = CapabilitySettingsSecretProbe()
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository,
            settingsSecrets: secrets.dependencies
        )
        var draft = MCPServerEditorDraft.newStdio
        draft.id = server.id
        draft.displayName = "Collision"
        draft.executable = "/usr/bin/true"
        draft.secrets = [
            .init(kind: .environment, name: "TOKEN", value: "private"),
        ]
        await #expect(throws: CapabilityControllerError.serverAlreadyExists) {
            try await controller.saveServerSettings(try draft.validated(mode: .create))
        }
        draft.id = "other"
        await #expect(throws: CapabilityControllerError.serverIdentityMismatch) {
            try await controller.saveServerSettings(try draft.validated(
                mode: .edit(originalID: server.id)
            ))
        }
        #expect(await secrets.mutationCount == 0)
        #expect(try await repository.server(id: "other") == nil)
    }

    @Test
    func failedRemovalReloadRestoresCatalogOverridesProvidersAndSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-remove-rollback-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("miller.sqlite3").path
        let profiles = try SQLiteConversationRepository(path: path)
        let profile = try ProviderProfile(
            kind: .openAICompatible, label: "Compatible",
            baseURL: "https://example.com", model: "model"
        )
        try await profiles.saveProviderProfile(profile)
        let repository = try SQLiteCapabilityRepository(path: path)
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.replaceServerConfiguration(
            server: server, secretBindings: [],
            enabledProviderProfileIDs: [profile.id]
        )
        let reference = UUID()
        let binding = CapabilitySecretBinding(
            id: UUID(), serverID: server.id, kind: .environment,
            name: "TOKEN", credentialReference: reference
        )
        try await repository.saveSecretBinding(binding)
        let descriptor = try CapabilityDescriptor(
            id: CapabilityID(
                source: .millerMCP, serverID: server.id, toolName: "lookup"
            ),
            source: .millerMCP, serverID: server.id, toolName: "lookup",
            displayName: "Lookup", summary: "Lookup",
            inputSchemaJSON: Data("{}".utf8), readOnlyHint: true,
            providerProfileIDs: [profile.id], isAvailable: true
        )
        try await repository.reconcileCatalog(
            serverID: server.id, descriptors: [descriptor]
        )
        try await repository.setPolicyOverride(
            .fullyTrusted, toolID: descriptor.id
        )
        let originalServer = try #require(await repository.server(id: server.id))
        let originalCatalog = try await repository.catalog(serverID: server.id)
        let secrets = CapabilitySettingsSecretProbe(values: [reference: "old"])
        let loader = FailFirstCapabilityConfigurationLoad()
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            settingsRepository: repository,
            settingsSecrets: secrets.dependencies
        )

        await #expect(throws: CapabilityControllerError.unavailable) {
            try await controller.removeServerFromSettings(serverID: server.id)
        }

        #expect(try await repository.server(id: server.id) == originalServer)
        #expect(try await repository.secretBindings(serverID: server.id) == [binding])
        #expect(try await repository.enabledProviderProfileIDs(serverID: server.id) == [profile.id])
        #expect(try await repository.catalog(serverID: server.id) == originalCatalog)
        #expect(await secrets.value(reference) == "old")
    }

    @Test
    func successfulConnectionTestEnablesServerAndCompatibleProviders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-connect-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let profiles = try SQLiteConversationRepository(path: databasePath)
        let profile = try ProviderProfile(
            kind: .openAICompatible, label: "Compatible",
            baseURL: "https://example.com", model: "model"
        )
        try await profiles.saveProviderProfile(profile)
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let server = settingsControllerServer(
            policy: .askBeforeChanges, enabled: false
        )
        try await repository.saveServer(server)
        let session = CapabilitySessionProbe(
            serverID: server.id,
            tool: .init(
                name: "lookup", displayName: "Lookup", summary: "Lookup",
                inputSchemaJSON: Data("{}".utf8), readOnlyHint: true
            )
        )
        let controller = CapabilityController(
            loadConfiguration: {
                try await settingsRuntimeConfiguration(repository: repository)
            },
            sessionFactory: { _ in session },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )

        let count = try await controller.testAndEnableServer(
            serverID: server.id,
            compatibleProviderProfileIDs: [profile.id]
        )

        #expect(count == 1)
        #expect(try await repository.server(id: server.id)?.enabled == true)
        #expect(try await repository.enabledProviderProfileIDs(serverID: server.id) == [profile.id])
        #expect(try await repository.catalog(serverID: server.id).count == 1)
    }

    @Test
    func failedConnectionActivationReloadRestoresEntirePreviousAggregate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-connect-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let profiles = try SQLiteConversationRepository(path: databasePath)
        let previousProfile = try ProviderProfile(
            kind: .openAICompatible, label: "Previous",
            baseURL: "https://previous.example.com", model: "model"
        )
        let replacementProfile = try ProviderProfile(
            kind: .openAICompatible, label: "Replacement",
            baseURL: "https://replacement.example.com", model: "model"
        )
        try await profiles.saveProviderProfile(previousProfile)
        try await profiles.saveProviderProfile(replacementProfile)
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let server = settingsControllerServer(
            policy: .askBeforeChanges, enabled: false
        )
        try await repository.replaceServerConfiguration(
            server: server, secretBindings: [],
            enabledProviderProfileIDs: [previousProfile.id]
        )
        let oldDescriptor = try CapabilityDescriptor(
            id: CapabilityID(
                source: .millerMCP, serverID: server.id, toolName: "old_lookup"
            ),
            source: .millerMCP, serverID: server.id, toolName: "old_lookup",
            displayName: "Old Lookup", summary: "Previous catalog",
            inputSchemaJSON: Data("{}".utf8), readOnlyHint: true,
            providerProfileIDs: [previousProfile.id], isAvailable: true
        )
        try await repository.reconcileCatalog(
            serverID: server.id, descriptors: [oldDescriptor]
        )
        try await repository.setPolicyOverride(
            .fullyTrusted, toolID: oldDescriptor.id
        )
        let originalServer = try #require(await repository.server(id: server.id))
        let originalCatalog = try await repository.catalog(serverID: server.id)
        let session = CapabilitySessionProbe(
            serverID: server.id,
            tool: .init(
                name: "new_lookup", displayName: "New Lookup",
                summary: "Replacement catalog",
                inputSchemaJSON: Data("{}".utf8), readOnlyHint: false
            )
        )
        let loader = FailFirstCapabilityConfigurationLoad()
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            sessionFactory: { _ in session },
            settingsRepository: repository,
            settingsSecrets: .unavailable
        )

        await #expect(throws: CapabilityControllerError.unavailable) {
            try await controller.testAndEnableServer(
                serverID: server.id,
                compatibleProviderProfileIDs: [replacementProfile.id]
            )
        }

        #expect(try await repository.server(id: server.id) == originalServer)
        #expect(try await repository.enabledProviderProfileIDs(serverID: server.id)
            == [previousProfile.id])
        #expect(try await repository.catalog(serverID: server.id) == originalCatalog)
    }

    @Test
    func auditDeletionRejectsActiveAssociationThenSucceedsWhenIdle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-audit-delete-authority-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let conversations = try SQLiteConversationRepository(path: databasePath)
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        try await repository.saveServer(
            settingsControllerServer(policy: .askBeforeChanges)
        )
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository
        )
        let conversationID = ConversationID()
        let turnID = TurnID()
        try await conversations.accept(
            conversationID: conversationID, turnID: turnID,
            userText: "audit deletion", inputMode: .text, generation: 1
        )
        let auditID = CapabilityCallID()
        try await repository.beginAudit(.init(
            id: auditID, conversationID: conversationID, turnID: turnID,
            voiceSessionID: nil, source: .millerMCP,
            serverID: "settings", toolName: "lookup",
            startedAt: Date(), terminalAt: nil,
            effectivePolicy: .askBeforeChanges,
            approvalRequested: false, approvalDecision: nil,
            terminalOutcome: nil, summary: nil, visibility: .complete
        ))
        try await repository.terminalizeAudit(
            id: auditID, outcome: .succeeded, approvalDecision: nil
        )
        let association = CapabilityAssociation.typed(
            conversationID: conversationID, turnID: turnID, generation: 1
        )
        try controller.admitTypedAssociation(association, providerProfileID: UUID())
        await #expect(throws: CapabilityControllerError.settingsBusy) {
            try await controller.deleteCapabilityAuditsFromSettings()
        }
        await controller.finishTypedAssociation(turnID: turnID, generation: 1)
        try await controller.deleteCapabilityAuditsFromSettings()
        #expect(try await repository.audits().isEmpty)
    }

    @Test @MainActor
    func managedResetOwnsTheAuthoritativeRepositoryAndFencesAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-reset-fence-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("miller.sqlite3").path
        let migrationRepository = try SQLiteConversationRepository(path: databasePath)
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let controller = CapabilityController(
            loadConfiguration: {
                try await settingsRuntimeConfiguration(repository: repository)
            },
            settingsRepository: repository
        )
        let resetProbe = SuspendedCapabilityDatabaseResetProbe(
            path: databasePath, migrationRepository: migrationRepository
        )

        let reset = Task {
            await controller.performManagedReset { await resetProbe.perform() }
        }
        #expect(await resetProbe.waitUntilRequested())
        #expect(controller.settingsBusy)
        await #expect(throws: CapabilityControllerError.settingsBusy) {
            try await controller.reloadLocalConfiguration()
        }
        await #expect(throws: CapabilityControllerError.settingsBusy) {
            _ = try await controller.prepareLiveVoice(providerProfileID: UUID())
        }
        let shutdownCompletion = AsyncCompletionProbe()
        let shutdown = Task {
            await controller.shutdown()
            await shutdownCompletion.markComplete()
        }
        await Task.yield()
        #expect(!(await shutdownCompletion.isComplete))

        await resetProbe.resume()
        let resetResult = await reset.value
        await shutdown.value

        #expect(resetResult.failures.isEmpty)
        #expect(try await repository.server(id: server.id) == nil)
        #expect(await shutdownCompletion.isComplete)
        #expect(!controller.settingsBusy)
    }

    @Test
    func managedResetRejectsActiveRuntimeWithoutInvokingDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-reset-active-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository
        )
        let turnID = TurnID()
        try controller.admitTypedAssociation(
            .typed(conversationID: ConversationID(), turnID: turnID, generation: 1),
            providerProfileID: UUID()
        )
        let operation = AsyncCompletionProbe()

        let result = await controller.performManagedReset {
            await operation.markComplete()
            return .init(roots: [])
        }

        #expect(result.failures.map(\.root) == ["capabilities.runtime_idle"])
        #expect(!(await operation.isComplete))
        await controller.finishTypedAssociation(turnID: turnID, generation: 1)
    }

    @Test @MainActor
    func shutdownWaitsForSuspendedSettingsReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-settings-shutdown-fence-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(
            path: root.appendingPathComponent("miller.sqlite3").path
        )
        let server = settingsControllerServer(policy: .askBeforeChanges)
        try await repository.saveServer(server)
        let loader = SuspendedRuntimeConfigurationProbe()
        let controller = CapabilityController(
            loadConfiguration: { try await loader.load() },
            settingsRepository: repository
        )
        var draft = MCPServerEditorDraft.newStdio
        draft.id = server.id
        draft.displayName = "Edited"
        draft.executable = "/usr/bin/true"
        draft.enabled = true
        draft.createdAt = server.createdAt
        let save = Task {
            try await controller.saveServerSettings(try draft.validated(
                mode: .edit(originalID: server.id)
            ))
        }
        #expect(await waitForConfigurationRequest(loader))
        let completion = AsyncCompletionProbe()
        let shutdown = Task {
            await controller.shutdown()
            await completion.markComplete()
        }
        await Task.yield()
        #expect(controller.settingsBusy)
        #expect(!(await completion.isComplete))
        await loader.resolveAll(with: .init(servers: [], toolPolicies: [:]))
        try await save.value
        await shutdown.value
        #expect(await completion.isComplete)
        #expect(!controller.settingsBusy)
    }

    @Test
    func diagnosticsReportStartupFailureInsteadOfInventingReadiness() async {
        let controller = CapabilityController(
            loadConfiguration: { throw CapabilityControllerError.unavailable }
        )

        await controller.start()
        let snapshot = await controller.diagnosticsSnapshot()

        #expect(snapshot.controllerState == "Unavailable")
        #expect(snapshot.broker == nil)
        #expect(!snapshot.bridgeRPCServerRunning)
        #expect(snapshot.adapterProcessState == .unavailable)
    }

    @Test
    func diagnosticsNeverLabelsAnUnverifiedReachableLeaseAsRunning() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-adapter-diagnostics-\(UUID().uuidString)", isDirectory: true
        )
        let root = CapabilityRPCRuntime.managedRoot(in: parent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let lease = root.appending(path: CapabilityRPCRuntime.processLeaseName)
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: lease)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: lease.path
        )
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            trustedParent: parent
        )

        let snapshot = await controller.diagnosticsSnapshot()

        #expect(snapshot.adapterProcessState == .leasePIDAliveUnverified)
        #expect(snapshot.adapterProcessState.diagnosticsLabel != "Running")
    }

    @Test
    func diagnosticsDoNotClaimStoppedWithoutAReachableLeasePID() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-adapter-no-lease-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            trustedParent: parent
        )

        let snapshot = await controller.diagnosticsSnapshot()

        #expect(snapshot.adapterProcessState == .noReachableLeasePID)
        #expect(snapshot.adapterProcessState.diagnosticsLabel == "No reachable lease PID")
    }
}

private func portableSkillRecord(id: String) -> PortableSkillRecord {
    PortableSkillRecord(
        id: id, pluginID: nil, name: id, description: "Authority proof",
        markdownSnapshot: "Use the admitted snapshot.",
        sourceHash: String(repeating: "a", count: 64), enabled: false,
        createdAt: .distantPast, updatedAt: .distantPast
    )
}

private func settingsControllerServer(
    policy: CapabilityPolicy,
    enabled: Bool = true
) -> CapabilityServerRecord {
    .init(
        id: "settings", displayName: "Settings", transport: .stdio,
        command: "/usr/bin/true", endpoint: nil, arguments: [],
        enabled: enabled, defaultPolicy: policy, staleState: .current,
        createdAt: .distantPast, updatedAt: .distantPast
    )
}

private func settingsRuntimeConfiguration(
    repository: SQLiteCapabilityRepository
) async throws -> CapabilityRuntimeConfiguration {
    let servers = try await repository.servers()
    var configurations: [MCPServerConfiguration] = []
    var policies: [CapabilityID: CapabilityPolicy] = [:]
    for server in servers {
        let transport: MCPServerTransport
        switch server.transport {
        case .stdio:
            guard let command = server.command else {
                throw CapabilityControllerError.unavailable
            }
            transport = .stdio(executable: command, arguments: server.arguments)
        case .streamableHTTP:
            guard let endpoint = server.endpoint.flatMap(URL.init(string:)) else {
                throw CapabilityControllerError.unavailable
            }
            transport = .http(endpoint: endpoint)
        }
        configurations.append(try MCPServerConfiguration(
            id: server.id, displayName: server.displayName, transport: transport,
            enabled: server.enabled, defaultPolicy: server.defaultPolicy,
            providerProfileIDs: Set(
                try await repository.enabledProviderProfileIDs(serverID: server.id)
            )
        ))
        for tool in try await repository.catalog(serverID: server.id) {
            if let policy = tool.policyOverride {
                policies[tool.descriptor.id] = policy
            }
        }
    }
    return .init(servers: configurations, toolPolicies: policies)
}

private enum CapabilitySettingsSecretProbeError: Error {
    case injected
}

private actor CapabilitySettingsSecretProbe {
    private var values: [UUID: String]
    private var shouldFailDelete = false
    private var shouldFailFirstOldStore: Bool
    private var storeAttempts: [(UUID, String)] = []
    private var deleteAttempts: [UUID] = []
    private(set) var mutationCount = 0

    init(
        values: [UUID: String] = [:],
        failFirstOldStore: Bool = false
    ) {
        self.values = values
        shouldFailFirstOldStore = failFirstOldStore
    }

    nonisolated var dependencies: CapabilitySettingsSecretDependencies {
        .init(
            load: { [self] reference in await value(reference) },
            store: { [self] reference, value in
                try await storeValue(value, for: reference)
            },
            delete: { [self] reference in try await deleteValue(reference) }
        )
    }

    func value(_ reference: UUID) -> String? { values[reference] }

    func setValue(_ value: String, for reference: UUID) {
        mutationCount += 1
        values[reference] = value
    }

    func attemptedStore(_ reference: UUID, value: String) -> Bool {
        storeAttempts.contains { $0.0 == reference && $0.1 == value }
    }

    func attemptedDelete(_ reference: UUID) -> Bool {
        deleteAttempts.contains(reference)
    }

    func failNextDelete() { shouldFailDelete = true }

    private func storeValue(_ value: String, for reference: UUID) throws {
        mutationCount += 1
        storeAttempts.append((reference, value))
        if shouldFailFirstOldStore, value.hasPrefix("old-") {
            shouldFailFirstOldStore = false
            throw CapabilitySettingsSecretProbeError.injected
        }
        values[reference] = value
    }

    private func deleteValue(_ reference: UUID) throws {
        mutationCount += 1
        deleteAttempts.append(reference)
        if shouldFailDelete {
            shouldFailDelete = false
            throw CapabilitySettingsSecretProbeError.injected
        }
        values[reference] = nil
    }
}

private actor SuspendedRuntimeConfigurationProbe {
    private var continuations: [
        CheckedContinuation<CapabilityRuntimeConfiguration, any Error>
    ] = []
    private(set) var requestCount = 0
    private var futureConfiguration: CapabilityRuntimeConfiguration?

    func load() async throws -> CapabilityRuntimeConfiguration {
        requestCount += 1
        if let futureConfiguration { return futureConfiguration }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolveAll(with configuration: CapabilityRuntimeConfiguration) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: configuration)
        }
    }

    func resolveAllAndFuture(with configuration: CapabilityRuntimeConfiguration) {
        futureConfiguration = configuration
        resolveAll(with: configuration)
    }
}

enum StartupCandidateOutcome: CaseIterable, Sendable {
    case success
    case failure
}

enum MCPSettingsFailurePhase: CaseIterable, Sendable {
    case makeSession
    case listTools
    case descriptorValidation

    var expectedDiagnosticCode: String {
        switch self {
        case .makeSession: "capability_connection_failed"
        case .listTools: "capability_discovery_failed"
        case .descriptorValidation: "capability_catalog_failed"
        }
    }
}

private actor SuspendedStartupSessionProbe: MCPClientSessionProtocol {
    nonisolated let serverID: String
    private var continuation: CheckedContinuation<
        [MCPDiscoveredTool], any Error
    >?
    private(set) var requestCount = 0
    private(set) var disconnectCount = 0

    init(serverID: String) {
        self.serverID = serverID
    }

    func listTools() async throws -> [MCPDiscoveredTool] {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func callTool(
        name _: String,
        argumentsJSON _: Data
    ) throws -> MCPToolCallResult {
        throw MCPClientSessionError.connectionClosed
    }

    func disconnect() {
        disconnectCount += 1
    }

    func resolve(
        _ outcome: StartupCandidateOutcome,
        tool: MCPDiscoveredTool
    ) {
        switch outcome {
        case .success:
            continuation?.resume(returning: [tool])
        case .failure:
            continuation?.resume(throwing: MCPClientSessionError.connectionClosed)
        }
        continuation = nil
    }
}

private actor StartupSessionFactoryProbe {
    private let first: SuspendedStartupSessionProbe
    private let second: CapabilitySessionProbe
    private(set) var requestCount = 0

    init(
        first: SuspendedStartupSessionProbe,
        second: CapabilitySessionProbe
    ) {
        self.first = first
        self.second = second
    }

    func make() throws -> any MCPClientSessionProtocol {
        requestCount += 1
        switch requestCount {
        case 1: return first
        case 2: return second
        default: throw MCPClientSessionError.connectionClosed
        }
    }
}

private actor FailFirstCapabilityConfigurationLoad {
    private var calls = 0

    func load() throws -> CapabilityRuntimeConfiguration {
        calls += 1
        if calls == 1 { throw CapabilityControllerError.unavailable }
        return .init(servers: [], toolPolicies: [:])
    }
}

private actor CloseRepositoryThenFailConfigurationLoad {
    private let repository: SQLiteCapabilityRepository

    init(repository: SQLiteCapabilityRepository) {
        self.repository = repository
    }

    func load() async throws -> CapabilityRuntimeConfiguration {
        await repository.close()
        throw CapabilityControllerError.unavailable
    }
}

private actor AsyncCompletionProbe {
    private(set) var isComplete = false
    func markComplete() { isComplete = true }
}

private actor SuspendedCapabilityDatabaseResetProbe {
    private let path: String
    private let migrationRepository: SQLiteConversationRepository
    private var continuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    init(path: String, migrationRepository: SQLiteConversationRepository) {
        self.path = path
        self.migrationRepository = migrationRepository
    }

    func perform() async -> ResetResult {
        requestCount += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
        await migrationRepository.close()
        for candidate in [path, path + "-wal", path + "-shm"] {
            try? FileManager.default.removeItem(atPath: candidate)
        }
        do {
            try await migrationRepository.reopen()
            return .init(roots: [
                .init(root: "sqlite.primary.reopen", succeeded: true),
            ])
        } catch {
            return .init(roots: [
                .init(root: "sqlite.primary.reopen", succeeded: false),
            ])
        }
    }

    func waitUntilRequested() async -> Bool {
        if requestCount == 0 {
            await withCheckedContinuation { continuation in
                if requestCount > 0 {
                    continuation.resume()
                } else {
                    requestWaiters.append(continuation)
                }
            }
        }
        return true
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private func waitForConfigurationRequest(
    _ probe: SuspendedRuntimeConfigurationProbe,
    minimum: Int = 1
) async -> Bool {
    for _ in 0..<10_000 {
        if await probe.requestCount >= minimum { return true }
        await Task.yield()
    }
    return false
}

private func waitForStartupSessionRequest(
    _ probe: SuspendedStartupSessionProbe
) async -> Bool {
    for _ in 0..<10_000 {
        if await probe.requestCount > 0 { return true }
        await Task.yield()
    }
    return false
}

private func yieldForScheduling() async {
    for _ in 0..<100 { await Task.yield() }
}

private struct ControllerFixture {
    let controller: CapabilityController
    let profileID: UUID
    let capabilityID: CapabilityID
    let session: CapabilitySessionProbe
    let audit: CapabilityAuditProbe
}

@MainActor
private func makeFixture(
    policy: CapabilityPolicy,
    readOnly: Bool,
    toolOverride: CapabilityPolicy? = nil,
    serverPolicyWhenNoOverride: CapabilityPolicy? = nil,
    approvalTimeout: Duration = .seconds(1),
    trustedParent: URL? = nil,
    bridgeBox: CapabilityBridgeSessionBox? = nil,
    providerCallbackAuthorityBox: CapabilityProviderCallbackAuthorityBox? = nil,
    sessionDelay: Duration? = nil,
    audit suppliedAudit: CapabilityAuditProbe? = nil,
    confirmationAnnouncer: @escaping @MainActor @Sendable (String) -> Void = {
        _ in
    }
) throws -> ControllerFixture {
    let profileID = UUID()
    let capabilityID = try CapabilityID(
        source: .millerMCP, serverID: "notes", toolName: "replace_note"
    )
    let session = CapabilitySessionProbe(
        serverID: "notes",
        tool: MCPDiscoveredTool(
            name: "replace_note", displayName: "Replace note",
            summary: "Replace one note.", inputSchemaJSON: Data("{}".utf8),
            readOnlyHint: readOnly
        ),
        delay: sessionDelay
    )
    let configuration = try MCPServerConfiguration(
        id: "notes", displayName: "Notes",
        transport: .stdio(executable: "/usr/bin/true", arguments: []),
        enabled: true,
        defaultPolicy: serverPolicyWhenNoOverride ?? policy,
        providerProfileIDs: [profileID]
    )
    let audit = suppliedAudit ?? CapabilityAuditProbe()
    let controller = CapabilityController(
        loadConfiguration: {
            CapabilityRuntimeConfiguration(
                servers: [configuration],
                toolPolicies: toolOverride.map { [capabilityID: $0] } ?? [:]
            )
        },
        sessionFactory: { _ in session },
        persistence: audit.dependencies(),
        approvalTimeout: approvalTimeout,
        trustedParent: trustedParent,
        bridgeBox: bridgeBox,
        providerCallbackAuthorityBox: providerCallbackAuthorityBox,
        confirmationAnnouncer: confirmationAnnouncer
    )
    return ControllerFixture(
        controller: controller, profileID: profileID,
        capabilityID: capabilityID, session: session, audit: audit
    )
}

private func providerApprovalRequest(
    capabilityID: CapabilityID
) throws -> CapabilityApprovalRequest {
    let policy = try JSONDecoder().decode(
        EffectiveCapabilityPolicy.self,
        from: Data(
            #"{"value":"fully_trusted","requiresApproval":true,"reason":"provider_approval_required"}"#.utf8
        )
    )
    return try CapabilityApprovalRequest(
        callID: CapabilityCallID(), capabilityID: capabilityID,
        summary: CapabilitySummary(text: "Provider confirmation required"),
        policy: policy
    )
}

private func providerApproval(
    id: String,
    capabilityID: CapabilityID
) throws -> CodexProviderApproval {
    CodexProviderApproval(
        responseID: .string("\(id)-response"),
        itemID: "\(id)-item",
        approvalID: nil,
        threadID: "\(id)-thread",
        turnID: "\(id)-turn",
        kind: .commandExecution,
        request: try providerApprovalRequest(capabilityID: capabilityID),
        availableDecisions: ["accept", "decline"],
        toolUserInputQuestionID: nil
    )
}

@MainActor
private func waitForApproval(
    _ controller: CapabilityController
) async throws -> CapabilityApprovalPresentation {
    for _ in 0..<100 {
        if let value = controller.pendingApproval { return value }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CapabilityControllerTestError.missingApproval
}

@MainActor
private func waitForApprovalCount(
    _ count: Int,
    _ controller: CapabilityController
) async throws {
    for _ in 0..<100 {
        if controller.pendingApprovalCount == count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CapabilityControllerTestError.missingApproval
}

private func makeTrustedParent() throws -> URL {
    let url = URL(
        filePath: "/private/tmp/mcc-\(UUID().uuidString.prefix(8))",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func bridgeClient(
    _ box: CapabilityBridgeSessionBox
) throws -> CapabilityRPCClient {
    let bridge = try #require(try box.configuration())
    let socketPath = try #require(
        bridge.additionalEnvironment[CapabilityRPCEnvironment.socketPath]
    )
    let tokenValue = try #require(
        bridge.additionalEnvironment[CapabilityRPCEnvironment.sessionToken]
    )
    return CapabilityRPCClient(
        socketURL: URL(fileURLWithPath: socketPath),
        token: try CapabilityRPCSessionToken(environmentValue: tokenValue)
    )
}

private func waitForSessionCalls(
    _ count: Int,
    _ session: CapabilitySessionProbe
) async throws {
    for _ in 0..<100 {
        if await session.calls == count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CapabilityControllerTestError.missingApproval
}

private enum CapabilityControllerTestError: Error { case missingApproval }

private actor CapabilitySessionFactoryInvocationProbe {
    private(set) var count = 0

    func record() { count += 1 }
}

private final class CapabilityAnnouncementProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        values.append(message)
    }
}

private func emptyHostDependencies() -> HostDependencies {
    HostDependencies(
        submit: { _, _ in TurnID() },
        stop: {},
        loadTurn: { _ in nil },
        loadConversations: { [] },
        loadTurns: { _ in [] },
        archive: { _ in },
        unarchive: { _ in },
        delete: { _ in }
    )
}

private actor CapabilitySessionProbe: MCPClientSessionProtocol {
    nonisolated let serverID: String
    private let tool: MCPDiscoveredTool
    private let delay: Duration?
    private(set) var calls = 0
    private(set) var disconnectCount = 0

    init(serverID: String, tool: MCPDiscoveredTool, delay: Duration? = nil) {
        self.serverID = serverID
        self.tool = tool
        self.delay = delay
    }

    func listTools() -> [MCPDiscoveredTool] { [tool] }

    func callTool(
        name: String, argumentsJSON: Data
    ) async -> MCPToolCallResult {
        calls += 1
        if let delay {
            do { try await Task.sleep(for: delay) } catch {}
        }
        return MCPToolCallResult(
            contentJSON: Data(#"{"content":[{"type":"text","text":"safe"}]}"#.utf8),
            isError: false
        )
    }

    func disconnect() { disconnectCount += 1 }
}

private actor FailingCapabilitySessionProbe: MCPClientSessionProtocol {
    nonisolated let serverID: String

    init(serverID: String) {
        self.serverID = serverID
    }

    func listTools() throws -> [MCPDiscoveredTool] {
        throw MCPClientSessionError.connectionClosed
    }

    func callTool(
        name _: String,
        argumentsJSON _: Data
    ) throws -> MCPToolCallResult {
        throw MCPClientSessionError.connectionClosed
    }

    func disconnect() {}
}

private actor CapabilityAuditProbe {
    private(set) var beginRows = 0
    private(set) var terminalRows = 0
    private(set) var decisions: [CapabilityApprovalDecision] = []
    private(set) var approvalRequests: [Bool] = []
    private(set) var records: [CapabilityAuditRecord] = []
    private(set) var terminalObservedAt: [Date] = []
    private(set) var outcomes: [CapabilityTerminalOutcome] = []
    private(set) var beginAttempts = 0
    private(set) var requireApprovalAttempts = 0
    private(set) var terminalAttempts = 0
    private var beginFailures: Int
    private var requireApprovalFailures: Int
    private var terminalFailures: Int
    private var durableRows: [CapabilityCallID: CapabilityAuditRecord] = [:]

    init(
        beginFailures: Int = 0,
        requireApprovalFailures: Int = 0,
        terminalFailures: Int = 0
    ) {
        self.beginFailures = beginFailures
        self.requireApprovalFailures = requireApprovalFailures
        self.terminalFailures = terminalFailures
    }

    func setTerminalFailures(_ count: Int) {
        terminalFailures = count
    }

    nonisolated func dependencies() -> CapabilityPersistenceDependencies {
        CapabilityPersistenceDependencies(
            loadOpenAudits: { [self] in await openAudits() },
            beginAudit: { [self] record in try await recordBegin(record) },
            requireApproval: { [self] id, policy in
                try await requireApproval(id, policy: policy)
            },
            terminalizeAudit: { [self] id, outcome, decision in
                try await recordTerminal(
                    id,
                    outcome: outcome,
                    decision: decision
                )
            }
        )
    }

    func openAudits() -> [CapabilityAuditRecord] {
        durableRows.values.filter { $0.terminalOutcome == nil }
    }

    private func recordBegin(_ record: CapabilityAuditRecord) throws {
        beginAttempts += 1
        if beginFailures > 0 {
            beginFailures -= 1
            throw CapabilityAuditProbeError.persistenceUnavailable
        }
        if let existing = durableRows[record.id] {
            guard existing == record else {
                throw CapabilityAuditProbeError.invalidAudit
            }
            return
        }
        beginRows += 1
        durableRows[record.id] = record
        records.append(record)
        approvalRequests.append(record.approvalRequested)
    }

    private func requireApproval(
        _ id: CapabilityCallID,
        policy: CapabilityPolicy
    ) throws {
        requireApprovalAttempts += 1
        if requireApprovalFailures > 0 {
            requireApprovalFailures -= 1
            throw CapabilityAuditProbeError.persistenceUnavailable
        }
        guard let record = durableRows[id],
              record.terminalOutcome == nil
        else { throw CapabilityAuditProbeError.invalidAudit }
        if record.approvalRequested {
            guard record.effectivePolicy == policy
            else { throw CapabilityAuditProbeError.invalidAudit }
            return
        }
        let updated = CapabilityAuditRecord(
            id: record.id,
            conversationID: record.conversationID,
            turnID: record.turnID,
            voiceSessionID: record.voiceSessionID,
            source: record.source,
            serverID: record.serverID,
            toolName: record.toolName,
            startedAt: record.startedAt,
            terminalAt: nil,
            effectivePolicy: policy,
            approvalRequested: true,
            approvalDecision: nil,
            terminalOutcome: nil,
            summary: record.summary,
            visibility: record.visibility
        )
        durableRows[id] = updated
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = updated
        }
        if let index = records.firstIndex(where: { $0.id == id }) {
            approvalRequests[index] = true
        }
    }

    private func recordTerminal(
        _ id: CapabilityCallID,
        outcome: CapabilityTerminalOutcome,
        decision: CapabilityApprovalDecision?
    ) throws {
        terminalAttempts += 1
        if terminalFailures > 0 {
            terminalFailures -= 1
            throw CapabilityAuditProbeError.persistenceUnavailable
        }
        guard let record = durableRows[id] else {
            throw CapabilityAuditProbeError.invalidAudit
        }
        if let existing = record.terminalOutcome {
            guard existing == outcome,
                  record.approvalDecision == decision
            else { throw CapabilityAuditProbeError.invalidAudit }
            return
        }
        let terminal = CapabilityAuditRecord(
            id: record.id,
            conversationID: record.conversationID,
            turnID: record.turnID,
            voiceSessionID: record.voiceSessionID,
            source: record.source,
            serverID: record.serverID,
            toolName: record.toolName,
            startedAt: record.startedAt,
            terminalAt: Date(),
            effectivePolicy: record.effectivePolicy,
            approvalRequested: record.approvalRequested,
            approvalDecision: decision,
            terminalOutcome: outcome,
            summary: record.summary,
            visibility: record.visibility
        )
        durableRows[id] = terminal
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = terminal
        }
        terminalRows += 1
        outcomes.append(outcome)
        terminalObservedAt.append(Date())
        if let decision { decisions.append(decision) }
    }
}

private actor ProviderProjectionProbe {
    private var profile: ProviderProfile?
    private let snapshot: CapabilityCatalogSnapshot
    private(set) var inventoryCalls = 0
    private(set) var localSources: [[CapabilitySource]] = []

    init(profile: ProviderProfile?, snapshot: CapabilityCatalogSnapshot) {
        self.profile = profile
        self.snapshot = snapshot
    }

    func selectedProfile() -> ProviderProfile? { profile }

    func setProfile(_ profile: ProviderProfile?) {
        self.profile = profile
    }

    func inventory(
        profile _: ProviderProfile,
        local: [CapabilityDescriptor]
    ) -> CapabilityCatalogSnapshot {
        inventoryCalls += 1
        localSources.append(local.map(\.source))
        return snapshot
    }
}

private enum CapabilityAuditProbeError: Error {
    case persistenceUnavailable
    case invalidAudit
}

private actor ApprovalEchoGateway: ReasoningGateway {
    let approval: CapabilityApprovalRequest
    private(set) var resolveCalls = 0

    init(approval: CapabilityApprovalRequest) {
        self.approval = approval
    }

    func start(
        _ request: ReasoningRequest
    ) -> AsyncThrowingStream<ReasoningEvent, Error> {
        let approval = approval
        return AsyncThrowingStream { continuation in
            continuation.yield(.capabilityApprovalRequested(approval))
            continuation.yield(.completed)
            continuation.finish()
        }
    }

    func cancel(_ cancellation: ReasoningCancellation) {}

    func resolveApproval(
        callID: CapabilityCallID,
        decision: CapabilityApprovalDecision
    ) {
        resolveCalls += 1
    }
}

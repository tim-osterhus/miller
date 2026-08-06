import Foundation
import MillerCapabilities
import MillerCore
import MillerGateway
@testable import MillerLive
import MillerStorage
import Testing
@testable import MillerApp

@Suite(.serialized)
@MainActor
struct CapabilityControllerTests {
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
            try await fixture.controller.prepareLiveVoice(
                providerProfileID: fixture.profileID
            )
            fixture.controller.admitVoiceAssociation(sessionID: UUID())
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
        try await fixture.controller.prepareLiveVoice(
            providerProfileID: fixture.profileID
        )
        fixture.controller.admitVoiceAssociation(sessionID: UUID())
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
        fixture.controller.admitTypedAssociation(
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
        try await fixture.controller.prepareLiveVoice(
            providerProfileID: fixture.profileID
        )
        let callbacks = fixture.controller.capturedProviderCallbacks()
        let sessionID = UUID()
        fixture.controller.admitVoiceAssociation(sessionID: sessionID)
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

        try await fixture.controller.prepareLiveVoice(
            providerProfileID: fixture.profileID
        )
        fixture.controller.admitVoiceAssociation(sessionID: UUID())
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
        fixture.controller.admitTypedAssociation(
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
        fixture.controller.admitTypedAssociation(
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
    func providerTerminalAuditFailureRemainsFencedUntilRecovery() async throws {
        let audit = CapabilityAuditProbe(terminalFailures: 1)
        let fixture = try makeFixture(
            policy: .fullyTrusted,
            readOnly: false,
            audit: audit
        )
        await fixture.controller.start()
        fixture.controller.admitTypedAssociation(
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
        fixture.controller.admitTypedAssociation(
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
    func providerMandatoryApprovalCorrelatesWithItsOpaqueTerminalActivity() async throws {
        let fixture = try makeFixture(policy: .fullyTrusted, readOnly: false)
        await fixture.controller.start()
        let conversationID = ConversationID()
        let turnID = TurnID()
        fixture.controller.admitTypedAssociation(
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
        fixture.controller.admitTypedAssociation(
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
        fixture.controller.admitTypedAssociation(
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
        fixture.controller.admitTypedAssociation(
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
        fixture.controller.admitTypedAssociation(
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
        fixture.controller.admitTypedAssociation(
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
    private(set) var terminalAttempts = 0
    private var beginFailures: Int
    private var terminalFailures: Int

    init(beginFailures: Int = 0, terminalFailures: Int = 0) {
        self.beginFailures = beginFailures
        self.terminalFailures = terminalFailures
    }

    func setTerminalFailures(_ count: Int) {
        terminalFailures = count
    }

    nonisolated func dependencies() -> CapabilityPersistenceDependencies {
        CapabilityPersistenceDependencies(
            beginAudit: { [self] record in try await recordBegin(record) },
            terminalizeAudit: { [self] _, outcome, decision in
                try await recordTerminal(outcome, decision: decision)
            }
        )
    }

    private func recordBegin(_ record: CapabilityAuditRecord) throws {
        beginAttempts += 1
        if beginFailures > 0 {
            beginFailures -= 1
            throw CapabilityAuditProbeError.persistenceUnavailable
        }
        beginRows += 1
        records.append(record)
        approvalRequests.append(record.approvalRequested)
    }

    private func recordTerminal(
        _ outcome: CapabilityTerminalOutcome,
        decision: CapabilityApprovalDecision?
    ) throws {
        terminalAttempts += 1
        if terminalFailures > 0 {
            terminalFailures -= 1
            throw CapabilityAuditProbeError.persistenceUnavailable
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

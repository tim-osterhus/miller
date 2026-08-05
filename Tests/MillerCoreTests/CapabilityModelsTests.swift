import Foundation
@testable import MillerCore
import Testing

@Suite
struct CapabilityModelsTests {
    @Test
    func identifiersNormalizeToLowercaseComponents() throws {
        let id = try CapabilityID(
            source: .millerMCP,
            serverID: " Calendar_Server ",
            toolName: " LIST-EVENTS "
        )

        #expect(id.rawValue == "miller_mcp/calendar_server/list-events")
        #expect(id.description == id.rawValue)
        #expect(try CapabilityID(rawValue: " CODEX_ACCOUNT / MAIL / SEARCH ") == idForCodex())
    }

    @Test
    func identifiersRejectMalformedOrNonASCIIComponents() {
        #expect(throws: CapabilityContractError.invalidCapabilityID) {
            try CapabilityID(rawValue: "miller_mcp/calendar")
        }
        #expect(throws: CapabilityContractError.invalidCapabilityID) {
            try CapabilityID(rawValue: "miller_mcp/cal endar/list")
        }
        #expect(throws: CapabilityContractError.invalidCapabilityID) {
            try CapabilityID(rawValue: "miller_mcp/calendár/list")
        }
        #expect(throws: CapabilityContractError.invalidCapabilityID) {
            try CapabilityID(rawValue: "unknown/calendar/list")
        }
        #expect(throws: CapabilityContractError.invalidCapabilityID) {
            try CapabilityID(rawValue: "miller_mcp/Kelvin/list")
        }
    }

    @Test
    func identifiersEnforceTheUTF8ByteBound() throws {
        let exact = "miller_mcp/s/" + String(repeating: "t", count: 179)
        let oversized = exact + "t"

        #expect(exact.utf8.count == 192)
        #expect(try CapabilityID(rawValue: exact).rawValue == exact)
        #expect(throws: CapabilityContractError.capabilityIDTooLarge) {
            try CapabilityID(rawValue: oversized)
        }
    }

    @Test
    func decodingCannotBypassIdentifierValidation() throws {
        let valid = try CapabilityID(rawValue: "provider_native/search/query")
        let encoded = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(CapabilityID.self, from: encoded) == valid)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CapabilityID.self,
                from: Data("\"provider_native/search/💥\"".utf8)
            )
        }
    }

    @Test
    func sourceValuesAndProviderAvailabilityRemainExplicit() throws {
        #expect(CapabilitySource.codexAccount.rawValue == "codex_account")
        #expect(CapabilitySource.millerMCP.rawValue == "miller_mcp")
        #expect(CapabilitySource.providerNative.rawValue == "provider_native")

        let enabledProvider = UUID()
        let otherProvider = UUID()
        let available = try descriptor(
            providerProfileIDs: [enabledProvider],
            isAvailable: true
        )
        let unavailable = try descriptor(
            providerProfileIDs: [enabledProvider],
            isAvailable: false
        )

        #expect(available.isAvailable(to: enabledProvider))
        #expect(!available.isAvailable(to: otherProvider))
        #expect(!unavailable.isAvailable(to: enabledProvider))
    }

    @Test
    func descriptorIdentityMustMatchItsNormalizedIDTriple() throws {
        let id = try CapabilityID(rawValue: "miller_mcp/calendar/list")
        let matching = try CapabilityDescriptor(
            id: id,
            source: .millerMCP,
            serverID: " Calendar ",
            toolName: " LIST ",
            displayName: "List events",
            summary: "Lists calendar events",
            inputSchemaJSON: Data("{}".utf8),
            readOnlyHint: true,
            providerProfileIDs: [],
            isAvailable: true
        )

        #expect(matching.serverID == "calendar")
        #expect(matching.toolName == "list")
        #expect(
            throws: CapabilityContractError.capabilityDescriptorIdentityMismatch
        ) {
            try CapabilityDescriptor(
                id: id,
                source: .providerNative,
                serverID: "calendar",
                toolName: "list",
                displayName: "List events",
                summary: "Lists calendar events",
                inputSchemaJSON: Data("{}".utf8),
                readOnlyHint: true,
                providerProfileIDs: [],
                isAvailable: true
            )
        }
        #expect(
            throws: CapabilityContractError.capabilityDescriptorIdentityMismatch
        ) {
            try CapabilityDescriptor(
                id: id,
                source: .millerMCP,
                serverID: "calendar",
                toolName: "create",
                displayName: "Create event",
                summary: "Creates a calendar event",
                inputSchemaJSON: Data("{}".utf8),
                readOnlyHint: false,
                providerProfileIDs: [],
                isAvailable: true
            )
        }
    }

    @Test
    func descriptorDecodingCannotBypassIdentityValidation() throws {
        let valid = try descriptor()
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
                as? [String: Any]
        )
        object["toolName"] = "create"

        #expect(
            throws: CapabilityContractError.capabilityDescriptorIdentityMismatch
        ) {
            try JSONDecoder().decode(
                CapabilityDescriptor.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test
    func catalogSnapshotEnforcesItsDescriptorLimit() throws {
        let value = try descriptor()
        let exact = Array(repeating: value, count: 2_048)

        #expect(try CapabilityCatalogSnapshot(exact).descriptors.count == 2_048)
        #expect(throws: CapabilityContractError.catalogTooLarge) {
            try CapabilityCatalogSnapshot(exact + [value])
        }
    }

    @Test
    func voiceHistoryAttachmentEnforcesItsUTF8ByteLimit() throws {
        let exact = String(repeating: "💬", count: 8_192)
        #expect(exact.utf8.count == 32 * 1_024)
        #expect(try VoiceHistoryAttachment(text: exact).text == exact)

        #expect(throws: CapabilityContractError.voiceHistoryAttachmentTooLarge) {
            try VoiceHistoryAttachment(text: exact + "x")
        }
    }

    @Test
    func reasoningRequestDefaultsToNoCapabilitiesOrHistory() {
        let request = ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "hello"
        )

        #expect(request.capabilityCatalog.descriptors.isEmpty)
        #expect(request.voiceHistoryAttachment == nil)
    }

    @Test
    func lifecycleAndApprovalEventsCarryOnlySanitizedContracts() throws {
        let callID = CapabilityCallID()
        let capabilityID = try CapabilityID(rawValue: "miller_mcp/calendar/create")
        let summary = try CapabilitySummary(
            text: String(repeating: "s", count: 1_024)
        )
        let policy = approvalPolicy()
        let lifecycle = try CapabilityLifecycleEvent(
            callID: callID,
            capabilityID: capabilityID,
            summary: summary,
            state: .awaitingApproval,
            outcome: nil,
            policy: policy
        )
        let approval = try CapabilityApprovalRequest(
            callID: callID,
            capabilityID: capabilityID,
            summary: summary,
            policy: policy
        )

        #expect(ReasoningEvent.capabilityLifecycle(lifecycle) == .capabilityLifecycle(lifecycle))
        #expect(
            ReasoningEvent.capabilityApprovalRequested(approval)
                == .capabilityApprovalRequested(approval)
        )
        #expect(CapabilityApprovalDecision.allCases == [.allowOnce, .decline])
        #expect(throws: CapabilityContractError.capabilitySummaryTooLarge) {
            try CapabilitySummary(text: String(repeating: "s", count: 1_025))
        }
    }

    @Test
    func effectivePolicyDecodingRejectsContradictoryReasonState() {
        let contradictory = Data(
            """
            {
              "value": "fully_trusted",
              "requiresApproval": true,
              "reason": "fully_trusted"
            }
            """.utf8
        )

        #expect(
            throws: CapabilityContractError.invalidEffectiveCapabilityPolicy
        ) {
            try JSONDecoder().decode(
                EffectiveCapabilityPolicy.self,
                from: contradictory
            )
        }
    }

    @Test
    func effectivePolicyExposesABoundedStringReason() {
        let reason: String = approvalPolicy().reason
        #expect(reason == "owner_approval_required")
    }

    @Test(arguments: [
        "custom_policy_reason",
        String(repeating: "x", count: 65),
    ])
    func effectivePolicyDecodingRejectsUnrecognizedOrOversizedReasons(
        reason: String
    ) throws {
        let object: [String: Any] = [
            "value": "ask_before_changes",
            "requiresApproval": true,
            "reason": reason,
        ]

        #expect(
            throws: CapabilityContractError.invalidEffectiveCapabilityPolicy
        ) {
            try JSONDecoder().decode(
                EffectiveCapabilityPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test
    func lifecycleConstructorEnforcesStateOutcomeAndApprovalInvariants() throws {
        let callID = CapabilityCallID()
        let capabilityID = try CapabilityID(rawValue: "miller_mcp/calendar/create")
        let summary = try CapabilitySummary(text: "Creates an event")

        #expect(throws: CapabilityContractError.invalidCapabilityLifecycle) {
            try CapabilityLifecycleEvent(
                callID: callID,
                capabilityID: capabilityID,
                summary: summary,
                state: .terminal,
                outcome: nil,
                policy: automaticPolicy()
            )
        }
        #expect(throws: CapabilityContractError.invalidCapabilityLifecycle) {
            try CapabilityLifecycleEvent(
                callID: callID,
                capabilityID: capabilityID,
                summary: summary,
                state: .running,
                outcome: .succeeded,
                policy: automaticPolicy()
            )
        }
        #expect(throws: CapabilityContractError.approvalNotRequired) {
            try CapabilityLifecycleEvent(
                callID: callID,
                capabilityID: capabilityID,
                summary: summary,
                state: .awaitingApproval,
                outcome: nil,
                policy: automaticPolicy()
            )
        }
    }

    @Test
    func lifecycleDecodingCannotBypassStateOutcomeValidation() throws {
        let terminal = try CapabilityLifecycleEvent(
            callID: CapabilityCallID(),
            capabilityID: CapabilityID(rawValue: "miller_mcp/calendar/create"),
            summary: CapabilitySummary(text: "Created an event"),
            state: .terminal,
            outcome: .succeeded,
            policy: automaticPolicy()
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(terminal))
                as? [String: Any]
        )
        object.removeValue(forKey: "outcome")

        #expect(throws: CapabilityContractError.invalidCapabilityLifecycle) {
            try JSONDecoder().decode(
                CapabilityLifecycleEvent.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test
    func approvalRequestsRequireAnApprovalPolicyDuringConstructionAndDecoding() throws {
        let request = try CapabilityApprovalRequest(
            callID: CapabilityCallID(),
            capabilityID: CapabilityID(rawValue: "miller_mcp/calendar/create"),
            summary: CapabilitySummary(text: "Creates an event"),
            policy: approvalPolicy()
        )

        #expect(throws: CapabilityContractError.approvalNotRequired) {
            try CapabilityApprovalRequest(
                callID: request.callID,
                capabilityID: request.capabilityID,
                summary: request.summary,
                policy: automaticPolicy()
            )
        }

        var requestObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        requestObject["policy"] = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(automaticPolicy()))
                as? [String: Any]
        )
        #expect(throws: CapabilityContractError.approvalNotRequired) {
            try JSONDecoder().decode(
                CapabilityApprovalRequest.self,
                from: JSONSerialization.data(withJSONObject: requestObject)
            )
        }
    }

    @Test
    func unsupportedGatewaysDeclineApprovalResolutionExplicitly() async {
        let gateway = UnsupportedApprovalGateway()

        await #expect(throws: ReasoningGatewayError.approvalUnsupported) {
            try await gateway.resolveApproval(
                callID: CapabilityCallID(),
                decision: .allowOnce
            )
        }
    }
}

private func idForCodex() throws -> CapabilityID {
    try CapabilityID(rawValue: "codex_account/mail/search")
}

private func descriptor(
    providerProfileIDs: Set<UUID> = [],
    isAvailable: Bool = true
) throws -> CapabilityDescriptor {
    try CapabilityDescriptor(
        id: try CapabilityID(rawValue: "miller_mcp/calendar/list"),
        source: .millerMCP,
        serverID: "calendar",
        toolName: "list",
        displayName: "List events",
        summary: "Lists calendar events",
        inputSchemaJSON: Data("{}".utf8),
        readOnlyHint: true,
        providerProfileIDs: providerProfileIDs,
        isAvailable: isAvailable
    )
}

private func approvalPolicy() -> EffectiveCapabilityPolicy {
    CapabilityPolicyResolver().resolve(
        serverPolicy: .askBeforeChanges,
        readOnlyHint: false
    ).effectivePolicy
}

private func automaticPolicy() -> EffectiveCapabilityPolicy {
    CapabilityPolicyResolver().resolve(
        serverPolicy: .fullyTrusted,
        readOnlyHint: false
    ).effectivePolicy
}

private actor UnsupportedApprovalGateway: ReasoningGateway {
    func start(
        _: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancel(_: ReasoningCancellation) async {}
}

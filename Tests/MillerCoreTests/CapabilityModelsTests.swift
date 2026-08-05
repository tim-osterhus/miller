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
        let policy = EffectiveCapabilityPolicy(
            value: .askBeforeChanges,
            requiresApproval: true,
            reason: "owner_approval_required"
        )
        let lifecycle = CapabilityLifecycleEvent(
            callID: callID,
            capabilityID: capabilityID,
            summary: summary,
            state: .awaitingApproval,
            outcome: nil,
            policy: policy
        )
        let approval = CapabilityApprovalRequest(
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
    CapabilityDescriptor(
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

private actor UnsupportedApprovalGateway: ReasoningGateway {
    func start(
        _: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancel(_: ReasoningCancellation) async {}
}

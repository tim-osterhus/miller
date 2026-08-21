import MillerCore
import SwiftUI
import Testing
@testable import MillerApp

@Suite
@MainActor
struct CapabilityApprovalPresentationTests {
    @Test
    func approvalSurfaceContainsOnlyTransientDecisionsAndBoundedFields() throws {
        let presentation = CapabilityApprovalPresentation(
            callID: CapabilityCallID(),
            origin: String(repeating: "o", count: 800),
            server: String(repeating: "s", count: 800),
            tool: String(repeating: "t", count: 800),
            intent: String(repeating: "i", count: 2_000),
            policy: .askBeforeChanges,
            requiresVisualConfirmation: true
        )

        #expect(presentation.origin.utf8.count <= 128)
        #expect(presentation.server.utf8.count <= 128)
        #expect(presentation.tool.utf8.count <= 256)
        #expect(presentation.intent.utf8.count <= 1_024)
        #expect(CapabilityApprovalView.availableDecisions(for: presentation) == [
            .allowOnce, .decline,
        ])
    }

    @Test
    func providerRefusalWithoutAcceptDoesNotPresentAnAllowAction() {
        let presentation = CapabilityApprovalPresentation(
            callID: CapabilityCallID(),
            origin: "Provider",
            server: "Codex",
            tool: "Command execution",
            intent: "Provider confirmation required",
            policy: .askBeforeChanges,
            requiresVisualConfirmation: true,
            canAllowOnce: false
        )

        #expect(CapabilityApprovalView.availableDecisions(for: presentation) == [
            .decline,
        ])
    }

    @Test
    func uncertainActivityRowsUseExactStatusLabel() {
        let row = CapabilityActivityRow(
            callID: CapabilityCallID(),
            origin: "Miller MCP",
            server: "Mail",
            tool: "Send",
            outcome: .uncertain
        )

        #expect(row.status == "Uncertain")
    }

    @Test(arguments: CapabilityTerminalOutcome.allCasesForPresentation)
    func activityRowsExposeOnlySanitizedFixedOutcomes(
        outcome: CapabilityTerminalOutcome
    ) {
        let row = CapabilityActivityRow(
            callID: CapabilityCallID(),
            origin: "Miller MCP",
            server: "Mail",
            tool: "Send",
            outcome: outcome
        )

        #expect(["Succeeded", "Failed", "Declined", "Cancelled", "Timed out", "Uncertain"]
            .contains(row.status))
        #expect(!row.displayText.contains("argument"))
        #expect(!row.displayText.contains("result"))
        #expect(row.displayText.utf8.count <= 640)
    }
}

private extension CapabilityTerminalOutcome {
    static let allCasesForPresentation: [Self] = [
        .succeeded, .failed, .declined, .cancelled, .timedOut, .uncertain,
    ]
}

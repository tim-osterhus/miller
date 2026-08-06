import MillerCore
import SwiftUI

struct CapabilityApprovalView: View {
    static func availableDecisions(
        for presentation: CapabilityApprovalPresentation
    ) -> [CapabilityApprovalDecision] {
        presentation.canAllowOnce ? [.allowOnce, .decline] : [.decline]
    }

    let presentation: CapabilityApprovalPresentation
    let resolve: (CapabilityApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirmation required")
                .font(.headline)
            LabeledContent("Origin", value: presentation.origin)
            LabeledContent("Server", value: presentation.server)
            LabeledContent("Tool", value: presentation.tool)
            Text(presentation.intent)
                .foregroundStyle(.secondary)
            Text("Effective policy: \(presentation.policy.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Decline", role: .cancel) { resolve(.decline) }
                Spacer()
                if presentation.canAllowOnce {
                    Button("Allow once") { resolve(.allowOnce) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI

struct ToolsIntegrationsSettingsTab: View {
    let section = SettingsSection.toolsIntegrations

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                GroupBox("Tools & Integrations") {
                    Text("Tool and integration controls will appear here when configured.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
    }
}

import SwiftUI

struct DiagnosticsSettingsTab: View {
    let section = SettingsSection.diagnostics
    @ObservedObject var model: AppPresentationModel
    @State private var keychainResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                GroupBox("Component probes") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Typed conversation") { Text("Ready") }
                        LabeledContent("Live voice") { Text(model.voiceStatusText) }
                        LabeledContent("Avatar") { Text("Unavailable") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Keychain qualification") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Run Keychain probe") {
                            do {
                                try KeychainProbe().run()
                                keychainResult = "Probe succeeded and cleaned up"
                            } catch {
                                keychainResult = "Probe failed"
                            }
                        }
                        if let keychainResult {
                            Text(keychainResult)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
    }
}

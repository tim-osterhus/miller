import SwiftUI

struct PrivacyDataSettingsTab: View {
    let section = SettingsSection.privacyData
    @ObservedObject var model: AppPresentationModel
    @State private var resetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                GroupBox("Reset") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Reset Miller…", role: .destructive) {
                            resetConfirmation = true
                        }
                        .disabled(model.isActiveOperation)
                        ForEach(Array(model.resetResults.enumerated()), id: \.offset) { _, result in
                            LabeledContent(result.root) {
                                Text(result.succeeded ? "Removed" : "Failed")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
        .confirmationDialog(
            "Reset Miller local data and credentials?",
            isPresented: $resetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Miller", role: .destructive) {
                Task { await model.resetMiller() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Miller will stop its helper and remove its managed database, "
                    + "cache, and Keychain items. This does not claim secure erasure."
            )
        }
    }
}

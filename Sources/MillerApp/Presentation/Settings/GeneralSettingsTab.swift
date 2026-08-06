import SwiftUI

struct GeneralSettingsTab: View {
    let section = SettingsSection.general
    @ObservedObject var model: AppPresentationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                GroupBox("Activation") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(
                            "Global shortcut",
                            selection: Binding(
                                get: { model.selectedShortcut },
                                set: { model.selectShortcut($0) }
                            )
                        ) {
                            ForEach(GlobalShortcut.allCases) { shortcut in
                                Text(shortcut.displayName).tag(shortcut)
                            }
                        }
                        LabeledContent("Status") {
                            Text(model.shortcutAvailable ? "Ready" : "Unavailable")
                        }
                        if !model.shortcutAvailable {
                            Text("Open Miller remains available from the menu bar.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Readiness") {
                    LabeledContent("Miller") {
                        Text(model.shortcutAvailable ? "Ready" : "Shortcut unavailable")
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

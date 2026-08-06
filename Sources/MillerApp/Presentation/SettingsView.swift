import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppPresentationModel
    @AppStorage(SettingsSelectionPreferences.key)
    private var selectedSectionRawValue = SettingsSection.general.rawValue

    var body: some View {
        TabView(selection: selectedSection) {
            ForEach(SettingsSection.allCases) { section in
                tabContent(for: section)
                    .tabItem {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .tag(section)
            }
        }
        .padding()
        .frame(
            minWidth: SettingsLayout.minimumWidth,
            minHeight: SettingsLayout.minimumHeight
        )
        .accessibilityLabel(AccessibilityLabel.settings)
        .onKeyPress { key in
            guard
                key.key == .tab,
                key.modifiers.contains(.control)
            else {
                return .ignored
            }
            selectedSection.wrappedValue = selectedSection.wrappedValue.moving(
                key.modifiers.contains(.shift) ? .backward : .forward
            )
            return .handled
        }
    }

    private var selectedSection: Binding<SettingsSection> {
        Binding(
            get: { SettingsSection(rawValue: selectedSectionRawValue) ?? .general },
            set: { selectedSectionRawValue = $0.rawValue }
        )
    }

    @ViewBuilder
    private func tabContent(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsTab(model: model)
        case .providers:
            ProvidersSettingsTab(model: model)
        case .voice:
            VoiceSettingsTab(model: model)
        case .toolsIntegrations:
            ToolsIntegrationsSettingsTab()
        case .privacyData:
            PrivacyDataSettingsTab(model: model)
        case .diagnostics:
            DiagnosticsSettingsTab(model: model)
        }
    }
}

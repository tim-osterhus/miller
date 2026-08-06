import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppPresentationModel
    @ObservedObject var capabilitySettings: MCPServerEditorModel
    @ObservedObject var privacySettings: PrivacyDataSettingsModel
    @ObservedObject var diagnosticsSettings: DiagnosticsSettingsModel
    @AppStorage(SettingsSelectionPreferences.key)
    private var selectedSectionRawValue = SettingsSection.general.rawValue

    init(
        model: AppPresentationModel,
        capabilitySettings: MCPServerEditorModel = .init(),
        privacySettings: PrivacyDataSettingsModel = .init(),
        diagnosticsSettings: DiagnosticsSettingsModel = .init()
    ) {
        self.model = model
        self.capabilitySettings = capabilitySettings
        self.privacySettings = privacySettings
        self.diagnosticsSettings = diagnosticsSettings
    }

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
            ToolsIntegrationsSettingsTab(editor: capabilitySettings)
        case .privacyData:
            PrivacyDataSettingsTab(model: model, privacy: privacySettings)
        case .diagnostics:
            DiagnosticsSettingsTab(model: model, diagnostics: diagnosticsSettings)
        }
    }
}

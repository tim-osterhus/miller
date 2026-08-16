import SwiftUI
import MillerWake

struct SettingsView: View {
    @ObservedObject var model: AppPresentationModel
    @ObservedObject var capabilitySettings: MCPServerEditorModel
    @ObservedObject var privacySettings: PrivacyDataSettingsModel
    @ObservedObject var diagnosticsSettings: DiagnosticsSettingsModel
    @ObservedObject var wakeSettings: WakeWordSettingsController
    @ObservedObject var remoteLiveSettings: RemoteLiveSettingsModel
    @ObservedObject var avatarSettings: AvatarSettingsModel
    @AppStorage(SettingsSelectionPreferences.key)
    private var selectedSectionRawValue = SettingsSection.general.rawValue

    init(
        model: AppPresentationModel,
        capabilitySettings: MCPServerEditorModel = .init(),
        privacySettings: PrivacyDataSettingsModel = .init(),
        diagnosticsSettings: DiagnosticsSettingsModel = .init(),
        wakeSettings: WakeWordSettingsController = .init(
            enable: { .disabled },
            disable: { .disabled }
        ),
        remoteLiveSettings: RemoteLiveSettingsModel = .init(),
        avatarSettings: AvatarSettingsModel = .init()
    ) {
        self.model = model
        self.capabilitySettings = capabilitySettings
        self.privacySettings = privacySettings
        self.diagnosticsSettings = diagnosticsSettings
        self.wakeSettings = wakeSettings
        self.remoteLiveSettings = remoteLiveSettings
        self.avatarSettings = avatarSettings
    }

    var body: some View {
        let selection = Binding<SettingsSection?>(
            get: { SettingsSection(rawValue: selectedSectionRawValue) ?? .general },
            set: { selectedSectionRawValue = ($0 ?? .general).rawValue }
        )

        HStack(spacing: 0) {
            List(selection: selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .accessibilityLabel(section.accessibilityLabel)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: SettingsLayout.sidebarWidth)
            .accessibilityLabel("Settings sections")

            Divider()

            tabContent(for: selection.wrappedValue ?? .general)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
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
            let currentSection = selection.wrappedValue ?? .general
            selection.wrappedValue = currentSection.moving(
                key.modifiers.contains(.shift) ? .backward : .forward
            )
            return .handled
        }
    }

    @ViewBuilder
    private func tabContent(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsTab(model: model)
        case .providers:
            ProvidersSettingsTab(model: model)
        case .voice:
            VoiceSettingsTab(
                model: model,
                wakeSettings: wakeSettings,
                remoteLiveSettings: remoteLiveSettings
            )
        case .avatar:
            AvatarSettingsTab(model: avatarSettings)
        case .toolsIntegrations:
            ToolsIntegrationsSettingsTab(editor: capabilitySettings)
        case .privacyData:
            PrivacyDataSettingsTab(model: model, privacy: privacySettings)
        case .diagnostics:
            DiagnosticsSettingsTab(model: model, diagnostics: diagnosticsSettings)
        }
    }
}

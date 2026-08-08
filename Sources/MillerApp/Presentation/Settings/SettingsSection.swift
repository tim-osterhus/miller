import Foundation

enum SettingsNavigationDirection {
    case forward
    case backward
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case providers
    case voice
    case toolsIntegrations = "tools-integrations"
    case privacyData = "privacy-data"
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .voice: "Voice"
        case .toolsIntegrations: "Tools & Integrations"
        case .privacyData: "Privacy & Data"
        case .diagnostics: "Diagnostics"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .general: "General settings"
        case .providers: "Providers settings"
        case .voice: "Voice settings"
        case .toolsIntegrations: "Tools and integrations settings"
        case .privacyData: "Privacy and data settings"
        case .diagnostics: "Diagnostics settings"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .providers: "network"
        case .voice: "waveform"
        case .toolsIntegrations: "wrench.and.screwdriver"
        case .privacyData: "hand.raised"
        case .diagnostics: "stethoscope"
        }
    }

    var sourceFileName: String {
        switch self {
        case .general: "GeneralSettingsTab.swift"
        case .providers: "ProvidersSettingsTab.swift"
        case .voice: "VoiceSettingsTab.swift"
        case .toolsIntegrations: "ToolsIntegrationsSettingsTab.swift"
        case .privacyData: "PrivacyDataSettingsTab.swift"
        case .diagnostics: "DiagnosticsSettingsTab.swift"
        }
    }

    var mayContainCredentialFields: Bool {
        self == .providers || self == .toolsIntegrations
    }

    func moving(_ direction: SettingsNavigationDirection) -> Self {
        guard let index = Self.allCases.firstIndex(of: self) else { return .general }
        switch direction {
        case .forward:
            return Self.allCases[(index + 1) % Self.allCases.count]
        case .backward:
            return Self.allCases[(index - 1 + Self.allCases.count) % Self.allCases.count]
        }
    }
}

struct SettingsSelectionPreferences {
    static let key = "settings.selectedSection"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SettingsSection {
        guard
            let rawValue = defaults.string(forKey: Self.key),
            let section = SettingsSection(rawValue: rawValue)
        else {
            return .general
        }
        return section
    }

    func save(_ section: SettingsSection) {
        defaults.set(section.rawValue, forKey: Self.key)
    }
}

enum SettingsLayout {
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 520
    static let sidebarWidth: CGFloat = 200
    static let contentSpacing: CGFloat = 16
}

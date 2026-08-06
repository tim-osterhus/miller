import Foundation
import Testing
@testable import MillerApp

@Suite
struct SettingsNavigationTests {
    @Test
    func sectionsHaveTheApprovedStableOrderAndLabels() {
        #expect(SettingsSection.allCases.map(\.title) == [
            "General",
            "Providers",
            "Voice",
            "Tools & Integrations",
            "Privacy & Data",
            "Diagnostics",
        ])
        #expect(SettingsSection.allCases.map(\.accessibilityLabel) == [
            "General settings",
            "Providers settings",
            "Voice settings",
            "Tools and integrations settings",
            "Privacy and data settings",
            "Diagnostics settings",
        ])
    }

    @Test
    func keyboardNavigationMovesForwardAndBackwardWithoutChangingOrder() {
        #expect(SettingsSection.general.moving(.forward) == .providers)
        #expect(SettingsSection.providers.moving(.backward) == .general)
        #expect(SettingsSection.diagnostics.moving(.forward) == .general)
        #expect(SettingsSection.general.moving(.backward) == .diagnostics)
    }

    @Test
    func selectedSectionPersistsIndependentlyOfPresentationRefreshes() throws {
        let suite = "miller.settings-navigation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SettingsSelectionPreferences(defaults: defaults)

        preferences.save(.privacyData)
        // Recreating the navigation owner models a presentation-model refresh.
        let reloaded = SettingsSelectionPreferences(defaults: defaults)

        #expect(reloaded.load() == .privacyData)
        #expect(Array((defaults.persistentDomain(forName: suite) ?? [:]).keys) == [
            SettingsSelectionPreferences.key,
        ])
    }

    @Test
    func invalidPersistedSectionFailsClosedToGeneral() throws {
        let suite = "miller.settings-navigation-invalid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-tab", forKey: SettingsSelectionPreferences.key)

        #expect(SettingsSelectionPreferences(defaults: defaults).load() == .general)
    }

    @Test
    func shellUsesTaggedTabsKeyboardNavigationAndMinimumWindowSize() throws {
        let source = try presentationSource(named: "SettingsView.swift")

        #expect(source.contains("TabView(selection:"))
        #expect(source.contains("ForEach(SettingsSection.allCases)"))
        #expect(source.contains(".tag(section)"))
        #expect(source.contains("key.modifiers.contains(.control)"))
        #expect(source.contains("minWidth: SettingsLayout.minimumWidth"))
        #expect(source.contains("minHeight: SettingsLayout.minimumHeight"))
        #expect(SettingsLayout.minimumWidth >= 700)
        #expect(SettingsLayout.minimumHeight >= 480)
    }

    @Test
    func eachTabOwnsItsAccessibleScrollableSurface() throws {
        for section in SettingsSection.allCases {
            let source = try settingsSource(named: section.sourceFileName)
            #expect(source.contains("ScrollView"), "\(section.title) must scroll independently")
            #expect(
                source.contains(".accessibilityLabel(section.accessibilityLabel)"),
                "\(section.title) must expose its stable VoiceOver label"
            )
        }
    }

    @Test
    func credentialInputsAreConfinedToApprovedTabs() throws {
        for section in SettingsSection.allCases where !section.mayContainCredentialFields {
            let source = try settingsSource(named: section.sourceFileName)
            #expect(!source.contains("SecureField("))
            #expect(!source.contains("API key"))
            #expect(!source.contains("CredentialField"))
        }
    }

    private func presentationSource(named name: String) throws -> String {
        let repository = repositoryRoot()
        return try String(
            contentsOf: repository
                .appendingPathComponent("Sources/MillerApp/Presentation")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func settingsSource(named name: String) throws -> String {
        let repository = repositoryRoot()
        return try String(
            contentsOf: repository
                .appendingPathComponent("Sources/MillerApp/Presentation/Settings")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

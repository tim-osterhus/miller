import Foundation
import Security
import Carbon.HIToolbox
import Testing
@testable import MillerApp

@Test
func moduleLoads() {
    #expect(MillerApp.version == 1)
}

@Test
func accessibilityContractIsStable() {
    #expect(AccessibilityLabel.status == "Miller status")
    #expect(AccessibilityLabel.input == "Message Miller")
    #expect(AccessibilityLabel.send == "Send message")
    #expect(AccessibilityLabel.stop == "Stop response")
    #expect(AccessibilityIdentifier.input == "miller.message-input")
    #expect(AccessibilityIdentifier.stop == "miller.stop")
}

@Test
func keyboardCommandMapping() {
    #expect(HostKeyboardCommand.map(key: "\r", command: false) == .submit)
    #expect(
        HostKeyboardCommand.map(key: "\u{1b}", command: false) == .dismiss
    )
    #expect(HostKeyboardCommand.map(key: ".", command: true) == .stop)
    #expect(HostKeyboardCommand.map(key: "x", command: false) == nil)
}

@Test
func keychainProbeUsesBoundedEligibleQuery() {
    let query = KeychainProbe.query(account: "fixture")
    #expect(
        query[kSecClass as String] as? String == kSecClassGenericPassword as String
    )
    #expect(
        query[kSecAttrService as String] as? String
            == "ai.millrace.miller.credentials.probe"
    )
    #expect(query[kSecAttrAccount as String] as? String == "fixture")
    #expect(
        query[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecReturnData as String] == nil)
    #expect(query[kSecValueData as String] == nil)
}

@MainActor
@Test
func fakeHelperModeIsAnExplicitOptionalArgument() {
    let helper = URL(fileURLWithPath: "/tmp/fake-helper.mjs")
    #expect(
        AppCoordinator.helperArguments(
            helperURL: helper,
            environment: [:]
        ) == [helper.path]
    )
    #expect(
        AppCoordinator.helperArguments(
            helperURL: helper,
            environment: ["MILLER_FAKE_HELPER_MODE": "qualification"]
        ) == [helper.path, "qualification"]
    )
}

@Test
func globalShortcutPresetsHaveStableIdentityAndCarbonMappings() {
    #expect(GlobalShortcut.default == .commandShiftSpace)
    #expect(GlobalShortcut.allCases.map(\.displayName) == [
        "Command-Shift-Space",
        "Control-Shift-Space",
        "Option-Shift-Space",
    ])
    #expect(
        GlobalShortcut.allCases.allSatisfy {
            $0.keyCode == UInt32(kVK_Space)
        }
    )
    #expect(
        GlobalShortcut.commandShiftSpace.modifiers
            == UInt32(cmdKey | shiftKey)
    )
    #expect(
        GlobalShortcut.controlShiftSpace.modifiers
            == UInt32(controlKey | shiftKey)
    )
    #expect(
        GlobalShortcut.optionShiftSpace.modifiers
            == UInt32(optionKey | shiftKey)
    )
}

@Test
func globalShortcutPreferencesRoundTripAndFailClosedToDefault() {
    let suite = "ai.millrace.miller.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
    }
    let preferences = GlobalShortcutPreferences(defaults: defaults)

    #expect(preferences.load() == .default)
    preferences.save(.optionShiftSpace)
    #expect(preferences.load() == .optionShiftSpace)

    defaults.set("unsupported", forKey: GlobalShortcutPreferences.key)
    #expect(preferences.load() == .default)
}

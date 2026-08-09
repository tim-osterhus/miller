import Testing
@testable import MillerWake

@Suite("Wakeword settings")
struct WakeWordSettingsControllerTests {
    @Test @MainActor
    func persistedEnabledStateCanBeRestoredWithoutUserDefaults() async {
        let settings = WakeWordSettingsController(
            initialPhrase: "Hey Miller",
            enable: { .monitoring },
            disable: { .disabled }
        )

        await settings.restorePersistedPreferences(
            enabled: true,
            phrase: "Custom Miller"
        )

        #expect(settings.isEnabled)
        #expect(settings.phrase == "Custom Miller")
        #expect(settings.state == .monitoring)
    }

    @Test @MainActor
    func invalidPhraseKeepsTheLastWorkingPhraseAndPublishesAnError() async {
        let controller = WakeWordSettingsController(
            initialPhrase: "Hey Miller",
            enable: { .monitoring },
            disable: { .disabled },
            savePhrase: { _ in
                throw WakeWordPhraseError.unsupportedToken("!")
            }
        )

        controller.updatePhrase("Hey!!!")
        await waitUntil { !controller.isWorking }

        #expect(controller.phrase == "Hey Miller")
        #expect(controller.errorMessage?.isEmpty == false)
    }
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
}

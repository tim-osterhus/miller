import Testing
@testable import MillerWake

@Suite("Wakeword settings")
struct WakeWordSettingsControllerTests {
    @Test @MainActor
    func persistedEnabledStateCanBeRestoredWithoutUserDefaults() async throws {
        let settings = WakeWordSettingsController(
            initialPhrase: "Hey Miller",
            enable: { .monitoring },
            disable: { .disabled }
        )

        await settings.restorePersistedPreferences(
            enabled: true,
            phrase: "Custom Miller",
            tuning: try #require(SherpaWakeWordTuning(
                keywordScore: 7.5,
                keywordThreshold: 0.08
            ))
        )

        #expect(settings.isEnabled)
        #expect(settings.phrase == "Custom Miller")
        #expect(settings.keywordScore == 7.5)
        #expect(settings.detectionThreshold == 0.08)
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

    @Test @MainActor
    func invalidOrFailedTuningUpdateKeepsTheLastWorkingValues() async throws {
        let controller = WakeWordSettingsController(
            initialTuning: try #require(SherpaWakeWordTuning(
                keywordScore: 5.0,
                keywordThreshold: 0.05
            )),
            enable: { .monitoring },
            disable: { .disabled },
            saveTuning: { _ in throw WakeWordDetectorError.unavailable }
        )

        controller.updateTuning(keywordScore: 0, detectionThreshold: 0.1)
        #expect(controller.keywordScore == 5.0)
        #expect(controller.detectionThreshold == 0.05)
        #expect(controller.errorMessage?.isEmpty == false)

        controller.updateTuning(keywordScore: 8.0, detectionThreshold: 0.1)
        await waitUntil { !controller.isWorking }
        #expect(controller.keywordScore == 5.0)
        #expect(controller.detectionThreshold == 0.05)
        #expect(controller.errorMessage?.isEmpty == false)
    }

    @Test @MainActor
    func validTuningUpdatePublishesOnlyAfterTheSerializedSave() async {
        let controller = WakeWordSettingsController(
            enable: { .monitoring },
            disable: { .disabled },
            saveTuning: { $0 }
        )

        controller.updateTuning(keywordScore: 7.0, detectionThreshold: 0.08)
        await waitUntil { !controller.isWorking }

        #expect(controller.keywordScore == 7.0)
        #expect(controller.detectionThreshold == 0.08)
        #expect(controller.errorMessage == nil)
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

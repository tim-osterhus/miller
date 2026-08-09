import Foundation
import MillerCore
import MillerStorage
import MillerWake
import Testing
@testable import MillerApp

@Suite("Wakeword production composition")
struct WakeWordCompositionTests {
    @Test @MainActor
    func detectedWakeOpensMillerAndAdmitsOneWakeLive() async {
        let integration = WakeWordLiveIntegration()
        let admissions = WakeLiveAdmissionRecorder()
        var openCount = 0

        AppCoordinator.wireWakeIntegrationOpener(integration) {
            openCount += 1
        }

        let model = AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in TurnID() },
                stop: {},
                loadTurn: { _ in nil },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in },
                admitLive: { _, source in
                    await admissions.record(source)
                    return LiveAdmission(
                        conversationID: ConversationID(),
                        activationSource: source
                    )
                }
            ),
            liveVoice: .init(
                initialAvailability: .available,
                availability: { .available },
                start: { receive in await receive(.state(.closed)) },
                mute: { _ in },
                interrupt: {},
                end: {}
            )
        )
        integration.model = model

        integration.wakeDetected()
        await integration.commandAudio(.init(
            id: UUID(),
            generation: 1,
            samples: ContiguousArray([1, 2, 3]),
            sampleRate: 16_000
        ))

        #expect(openCount == 1)
        #expect(await admissions.sources == [.wakeword])
    }
}

private actor WakeLiveAdmissionRecorder {
    private(set) var sources = [VoiceActivationSource]()

    func record(_ source: VoiceActivationSource) {
        sources.append(source)
    }
}

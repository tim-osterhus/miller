import Foundation
import MillerCore
import MillerLiveAudio
import MillerWake
import Testing
@testable import MillerApp

@Suite("Wakeword prepared Live start")
struct WakeWordPreparedLiveStartTests {
    @Test
    func preparedStartUsesTheSingleInjectedStartPath() async throws {
        let expected = WakeWordPreparedCommandAudio(
            id: UUID(),
            generation: 2,
            samples: ContiguousArray([1, 2]),
            sampleRate: 16_000
        )
        let recorder = PreparedStartRecorder()
        let dependencies = LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { receive in
                await receive(.state(.connecting))
            },
            mute: { _ in },
            interrupt: {},
            end: {},
            startPrepared: { audio, receive in
                await recorder.record(audio)
                await receive(.state(.connecting))
            }
        )

        try await dependencies.startPrepared(expected) { _ in }

        #expect(await recorder.audio == expected)
    }

    @Test @MainActor
    func presentationModelRoutesWakeAudioToThePreparedStartClosure() async {
        let expected = WakeWordPreparedCommandAudio(
            id: UUID(),
            generation: 3,
            samples: ContiguousArray([4, 5, 6]),
            sampleRate: 16_000
        )
        let recorder = PreparedStartRecorder()
        let live = LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { _ in },
            mute: { _ in },
            interrupt: {},
            end: {},
            startPrepared: { audio, receive in
                await recorder.record(audio)
                await receive(.state(.closed))
            }
        )
        let model = AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in TurnID() },
                stop: {},
                loadTurn: { _ in nil },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in }
            ),
            liveVoice: live
        )

        await model.startLiveVoice(
            activationSource: .wakeword,
            preparedAudio: expected
        )

        #expect(await recorder.audio == expected)
        #expect(model.voiceState == .closed)
    }
}

private actor PreparedStartRecorder {
    private(set) var audio: WakeWordPreparedCommandAudio?

    func record(_ audio: WakeWordPreparedCommandAudio) {
        self.audio = audio
    }
}

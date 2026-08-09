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

    @Test @MainActor
    func wakeAdmissionFailureRearmsWakeExactlyOnce() async {
        let callbacks = WakeLiveCleanupCallbacks()
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
                admitLive: { _, _ in throw WakeLiveAdmissionFailure.failed }
            ),
            liveVoice: .init(
                initialAvailability: .available,
                availability: { .available },
                start: { _ in },
                mute: { _ in },
                interrupt: {},
                end: {}
            ),
            prepareLiveStart: { source in
                if source == .wakeword { await callbacks.markSuspended() }
            },
            liveVoiceFinished: { await callbacks.markFinished() }
        )

        await model.startLiveVoice(activationSource: .wakeword)

        #expect(await callbacks.suspendedCount == 1)
        #expect(await callbacks.finishedCount == 1)
        #expect(model.voiceState == .failed)
    }

    @Test @MainActor
    func cancelledWakeAdmissionRearmsWakeExactlyOnce() async {
        let callbacks = WakeLiveCleanupCallbacks()
        let admission = WakeLiveAdmissionProbe()
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
                admitLive: { _, _ in
                    await admission.markEntered()
                    try await Task.sleep(for: .seconds(60))
                    throw WakeLiveAdmissionFailure.failed
                }
            ),
            liveVoice: .init(
                initialAvailability: .available,
                availability: { .available },
                start: { _ in },
                mute: { _ in },
                interrupt: {},
                end: {}
            ),
            prepareLiveStart: { source in
                if source == .wakeword { await callbacks.markSuspended() }
            },
            liveVoiceFinished: { await callbacks.markFinished() }
        )

        let start = Task { await model.startLiveVoice(activationSource: .wakeword) }
        await admission.waitUntilEntered()
        start.cancel()
        await start.value

        #expect(await callbacks.suspendedCount == 1)
        #expect(await callbacks.finishedCount == 1)
    }

    @Test @MainActor
    func manualLiveDoesNotInvokeWakeCleanupCallback() async {
        let callbacks = WakeLiveCleanupCallbacks()
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
            liveVoice: .init(
                initialAvailability: .available,
                availability: { .available },
                start: { receive in await receive(.state(.closed)) },
                mute: { _ in },
                interrupt: {},
                end: {}
            ),
            liveVoiceFinished: { await callbacks.markFinished() }
        )

        await model.startLiveVoice()

        #expect(await callbacks.finishedCount == 0)
        #expect(model.voiceState == .closed)
    }
}

private actor PreparedStartRecorder {
    private(set) var audio: WakeWordPreparedCommandAudio?

    func record(_ audio: WakeWordPreparedCommandAudio) {
        self.audio = audio
    }
}

private enum WakeLiveAdmissionFailure: Error {
    case failed
}

private actor WakeLiveCleanupCallbacks {
    private(set) var suspendedCount = 0
    private(set) var finishedCount = 0

    func markSuspended() { suspendedCount += 1 }
    func markFinished() { finishedCount += 1 }
}

private actor WakeLiveAdmissionProbe {
    private var entered = false

    func markEntered() { entered = true }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }
}

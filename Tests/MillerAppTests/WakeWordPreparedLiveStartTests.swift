import Foundation
import MillerCore
import Testing
@testable import MillerApp

@Suite("Wakeword Live start context")
struct WakeWordLiveStartContextTests {
    @Test
    func dependenciesPassStartContextThroughTheOrdinaryStartClosure() async throws {
        let recorder = LiveStartContextRecorder()
        let dependencies = LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { context, receive in
                await recorder.record(context)
                await receive(.state(.connecting))
            },
            mute: { _ in },
            interrupt: {},
            end: {}
        )

        try await dependencies.start(LiveVoiceStartContext.wakeword) { _ in }
        try await dependencies.start(LiveVoiceStartContext.manual) { _ in }

        #expect(await recorder.contexts == [.wakeword, .manual])
    }

    @Test @MainActor
    func presentationModelMapsWakeAndManualActivationToStartContext() async {
        let recorder = LiveStartContextRecorder()
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
                start: { context, receive in
                    await recorder.record(context)
                    await receive(.state(.closed))
                },
                mute: { _ in },
                interrupt: {},
                end: {}
            )
        )

        await model.startLiveVoice(activationSource: .wakeword)
        await model.startLiveVoice()

        #expect(await recorder.contexts == [.wakeword, .manual])
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
                start: { _, _ in },
                mute: { _ in },
                interrupt: {},
                end: {}
            ),
            prepareLiveStart: { source in
                if source == .wakeword {
                    await callbacks.markSuspended()
                    return true
                }
                return false
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
                start: { _, _ in },
                mute: { _ in },
                interrupt: {},
                end: {}
            ),
            prepareLiveStart: { source in
                if source == .wakeword {
                    await callbacks.markSuspended()
                    return true
                }
                return false
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
    func manualLiveWithoutWakeIntegrationDoesNotInvokeCleanupCallback() async {
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
                start: { _, receive in await receive(.state(.closed)) },
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

private actor LiveStartContextRecorder {
    private(set) var contexts = [LiveVoiceStartContext]()

    func record(_ context: LiveVoiceStartContext) {
        contexts.append(context)
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

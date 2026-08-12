import Foundation
import MillerCore
import MillerWake
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
    func disabledWakeAdmissionDoesNotReachTheLiveProvider() async {
        let result = await runInvalidatedWakeAdmission(.disable)

        #expect(result.callbackFinished)
        #expect(result.providerStartCount == 0)
        #expect(result.rearmCount == 1)
        #expect(result.releaseCount == 1)
        #expect(result.state == .disabled)
        #expect(!result.liveSessionActive)
    }

    @Test @MainActor
    func asleepWakeAdmissionDoesNotReachTheLiveProvider() async {
        let result = await runInvalidatedWakeAdmission(.sleep)

        #expect(result.callbackFinished)
        #expect(result.providerStartCount == 0)
        #expect(result.rearmCount == 1)
        #expect(result.releaseCount == 1)
        #expect(result.state == .suspended(.sleep))
        #expect(!result.liveSessionActive)
    }

    @Test @MainActor
    func sleepWakeWhileWakeLiveIsActiveRearmsAfterCleanupExactlyOnce() async {
        let integration = WakeWordLiveIntegration()
        let recorder = WakeInvalidationRecorder()
        var capturedAdmission: WakeWordAdmission?
        let production = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { WakeInvalidationDetector() },
            onWakeDetectedWithAdmission: { admission in
                capturedAdmission = admission
                await integration.wakeDetected(admission)
            }
        )
        integration.production = production

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
                    LiveAdmission(
                        conversationID: ConversationID(),
                        activationSource: source
                    )
                }
            ),
            liveVoice: .init(
                initialAvailability: .available,
                availability: { .available },
                start: { _, receive in
                    await receive(.state(.listening))
                },
                mute: { _ in },
                interrupt: {},
                end: {}
            ),
            prepareLiveStart: { source in
                await integration.prepareLiveStart(source)
            },
            liveVoiceFinished: {
                await integration.liveVoiceFinished()
            },
            validateLiveStart: { source in
                await integration.validateLiveStart(source)
            }
        )
        integration.model = model

        await production.setEnabled(true)
        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        await waitForWakeLiveSession {
            integration.liveSessionActive && model.voiceState == .listening
        }

        #expect(recorder.startCount == 1)
        #expect(capturedAdmission?.isValid == true)

        await production.setSystemAwake(false)

        #expect(production.state == .suspended(.sleep))
        #expect(capturedAdmission?.isValid == false)
        #expect(recorder.startCount == 1)

        let wakeTask = Task { @MainActor in
            await production.setSystemAwake(true)
            guard !integration.liveSessionActive else { return }
            await production.resumeAfterLiveCleanup()
        }
        await wakeTask.value

        #expect(integration.liveSessionActive)
        #expect(production.state == .suspended(.sleep))
        #expect(recorder.startCount == 1)
        #expect(capturedAdmission?.isValid == false)

        await model.endLiveVoice()

        #expect(!integration.liveSessionActive)
        #expect(production.state == .monitoring)
        #expect(recorder.startCount == 2)
        #expect(capturedAdmission?.isValid == false)

        await integration.liveVoiceFinished()
        await capturedAdmission?.complete()

        #expect(recorder.startCount == 2)
        #expect(production.state == .monitoring)
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

private enum WakeInvalidationAction {
    case disable
    case sleep
}

private struct WakeInvalidationResult {
    let callbackFinished: Bool
    let providerStartCount: Int
    let rearmCount: Int
    let releaseCount: Int
    let state: WakeWordState
    let liveSessionActive: Bool
}

@MainActor
private func waitForWakeLiveSession(
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
}

@MainActor
private func runInvalidatedWakeAdmission(
    _ action: WakeInvalidationAction
) async -> WakeInvalidationResult {
    let gate = WakeInvalidationGate()
    let provider = WakeInvalidationProviderProbe()
    let releaseProbe = WakeInvalidationReleaseProbe()
    let callback = WakeInvalidationCallbackProbe()
    let integration = WakeWordLiveIntegration()
    let recorder = WakeInvalidationRecorder()
    let production = WakeWordProductionController(
        recorder: recorder,
        detectorFactory: { WakeInvalidationDetector() },
        onWakeDetectedWithAdmission: { admission in
            await integration.wakeDetected(admission)
            await callback.finish()
        }
    )
    integration.production = production

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
                await gate.waitForRelease()
                return LiveAdmission(
                    conversationID: ConversationID(),
                    activationSource: source,
                    release: { await releaseProbe.release() }
                )
            }
        ),
        liveVoice: .init(
            initialAvailability: .available,
            availability: { .available },
            start: { _, receive in
                await provider.start()
                await receive(.state(.listening))
            },
            mute: { _ in },
            interrupt: {},
            end: {}
        ),
        prepareLiveStart: { source in
            await integration.prepareLiveStart(source)
        },
        liveVoiceFinished: {
            await integration.liveVoiceFinished()
        },
        validateLiveStart: { source in
            await integration.validateLiveStart(source)
        }
    )
    integration.model = model

    await production.setEnabled(true)
    recorder.emit(ContiguousArray(repeating: 0, count: 480))
    _ = await gate.waitUntilEntered()

    let actionTask = Task { @MainActor in
        switch action {
        case .disable:
            _ = await production.disableFromSettings()
        case .sleep:
            await production.setSystemAwake(false)
        }
    }
    for _ in 0..<8 { await Task.yield() }
    await gate.release()
    await actionTask.value
    let callbackFinished = await callback.waitUntilFinished()

    return WakeInvalidationResult(
        callbackFinished: callbackFinished,
        providerStartCount: await provider.startCount,
        rearmCount: recorder.startCount,
        releaseCount: await releaseProbe.count,
        state: production.state,
        liveSessionActive: integration.liveSessionActive
    )
}

private actor WakeInvalidationGate {
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        entered = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            await Task.yield()
        }
        return false
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor WakeInvalidationProviderProbe {
    private(set) var startCount = 0

    func start() {
        startCount += 1
    }
}

private actor WakeInvalidationReleaseProbe {
    private(set) var count = 0

    func release() {
        count += 1
    }
}

private actor WakeInvalidationCallbackProbe {
    private(set) var finished = false

    func finish() {
        finished = true
    }

    func waitUntilFinished() async -> Bool {
        for _ in 0..<200 {
            if finished { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class WakeInvalidationRecorder: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false
    private(set) var startCount = 0

    func startWakeMonitoring() async throws -> UUID {
        startCount += 1
        isWakeMonitoring = true
        return UUID()
    }

    func stopWakeMonitoring() async {
        isWakeMonitoring = false
    }

    func emit(_ samples: ContiguousArray<Int16>) {
        onSamples?(samples)
    }
}

private struct WakeInvalidationDetector: WakeWordDetecting {
    let requiredSampleRate = 16_000
    let requiredFrameLength = 480
    func process(frame: ContiguousArray<Int16>) throws -> Bool { true }
    func reset() throws {}
    func shutdown() {}
}

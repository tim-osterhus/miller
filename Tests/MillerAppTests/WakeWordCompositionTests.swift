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

    @Test @MainActor
    func manualLiveCleanupRearmsWakeExactlyOnceAfterSuspension() async {
        let recorder = WakeWordCompositionRecorder()
        let production = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { WakeWordCompositionDetector() }
        )
        let integration = WakeWordLiveIntegration()
        integration.production = production

        await production.setEnabled(true)
        #expect(production.state == .monitoring)
        #expect(recorder.startCount == 1)

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
            prepareLiveStart: { source in
                await integration.prepareLiveStart(source)
            },
            liveVoiceFinished: {
                await integration.liveVoiceFinished()
            }
        )

        await model.startLiveVoice()

        #expect(recorder.stopCount == 1)
        #expect(recorder.startCount == 2)
        #expect(production.state == .monitoring)
        #expect(!integration.liveSessionActive)
    }
}

private actor WakeLiveAdmissionRecorder {
    private(set) var sources = [VoiceActivationSource]()

    func record(_ source: VoiceActivationSource) {
        sources.append(source)
    }
}

@MainActor
private final class WakeWordCompositionRecorder: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startWakeMonitoring() async throws -> UUID {
        startCount += 1
        isWakeMonitoring = true
        return UUID()
    }

    func stopWakeMonitoring() async {
        stopCount += 1
        isWakeMonitoring = false
    }
}

private struct WakeWordCompositionDetector: WakeWordDetecting {
    let requiredSampleRate = 16_000
    let requiredFrameLength = 480

    func process(frame: ContiguousArray<Int16>) throws -> Bool { false }
    func reset() throws {}
    func shutdown() {}
}

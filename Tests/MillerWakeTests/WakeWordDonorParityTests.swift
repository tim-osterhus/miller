import Foundation
import Testing
@testable import MillerWake

@Suite("Wakeword donor parity")
struct WakeWordDonorParityTests {
    @Test @MainActor
    func wakeListeningDefaultsDisabled() {
        let suite = "WakeWordDonorParityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = WakeWordSettingsController(
            defaults: defaults,
            enable: { .monitoring },
            disable: { .disabled }
        )

        #expect(settings.isEnabled == false)
        #expect(settings.state == .disabled)
    }

    @Test
    func phraseCompilationIsBoundedAndDeterministic() throws {
        let compiler = WakeWordPhraseCompiler(
            tokens: ["<blk>", "▁hey", "▁miller", "m", "i", "l", "e", "r"]
        )

        #expect(try compiler.compile("Hey Miller") == [1, 2])
        #expect(throws: WakeWordPhraseError.empty) {
            try compiler.compile("  ")
        }
        #expect(throws: WakeWordPhraseError.tooLong) {
            try compiler.compile(String(repeating: "a", count: 129))
        }
    }

    @Test
    func frameAccumulatorRetainsOnlyTheTail() {
        var accumulator = WakeWordFrameAccumulator(frameLength: 4)
        let frames = accumulator.append([1, 2, 3, 4, 5, 6])

        #expect(frames == [ContiguousArray([1, 2, 3, 4])])
        #expect(accumulator.tail == ContiguousArray([5, 6]))
        #expect(accumulator.append([7, 8]) == [ContiguousArray([5, 6, 7, 8])])
        #expect(accumulator.tail.isEmpty)
    }

    @Test
    func commandEndpointRequiresSpeechThenSilence() {
        var detector = WakeCommandEndpointDetector(ambientDBFS: -60)

        for _ in 0..<5 {
            #expect(detector.process(dbfs: -30) == .continueListening)
        }
        #expect(detector.speechStarted)

        var event = WakeCommandEndpointEvent.continueListening
        for _ in 0..<50 {
            event = detector.process(dbfs: -70)
        }
        #expect(event == .silence)
    }

    @Test
    func suspensionRejectsThePreviousGeneration() throws {
        let detector = DetectorProbe()
        let coordinator = WakeWordCoordinator(detector: detector)
        let generation = try #require(coordinator.beginStarting())
        try coordinator.confirmMonitoring(generation: generation)

        let suspendedGeneration = coordinator.suspend(.foregroundSession)

        #expect(suspendedGeneration != generation)
        #expect(coordinator.accepts(generation) == false)
        #expect(coordinator.currentState() == .suspended(.foregroundSession))
        #expect(coordinator.receive(samples: [1, 2], generation: generation).isEmpty)
    }

    @Test @MainActor
    func recorderOwnershipIsReleasedBeforeSuspensionCompletes() async {
        let recorder = RecorderProbe()
        let detector = DetectorProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { detector }
        )

        await controller.setEnabled(true)
        #expect(recorder.isWakeMonitoring)
        await controller.suspend(.foregroundSession)

        #expect(recorder.isWakeMonitoring == false)
        #expect(controller.state == .suspended(.foregroundSession))
        #expect(recorder.stopCount == 1)
    }

    @Test @MainActor
    func controllerTeardownStopsRecorderAndDetectorExactlyOnce() async {
        let recorder = RecorderProbe()
        let detector = DetectorProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { detector }
        )

        await controller.setEnabled(true)
        #expect(await controller.shutdown())
        #expect(await controller.shutdown())

        #expect(recorder.isWakeMonitoring == false)
        #expect(recorder.stopCount == 1)
        #expect(detector.shutdownCount == 1)
        #expect(controller.state == .disabled)
    }
}

private final class DetectorProbe: WakeWordDetecting, @unchecked Sendable {
    let requiredSampleRate = 16_000
    let requiredFrameLength = 480
    private(set) var shutdownCount = 0

    func process(frame: ContiguousArray<Int16>) throws -> Bool { false }
    func reset() throws {}
    func shutdown() { shutdownCount += 1 }
}

@MainActor
private final class RecorderProbe: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false
    private(set) var stopCount = 0

    func startWakeMonitoring() async throws -> UUID {
        isWakeMonitoring = true
        return UUID()
    }

    func stopWakeMonitoring() async {
        guard isWakeMonitoring else { return }
        isWakeMonitoring = false
        stopCount += 1
    }
}

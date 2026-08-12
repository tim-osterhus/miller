import Foundation
import Testing
@testable import MillerWake

@Suite("Wakeword production handoff")
struct WakeWordProductionHandoffTests {
    @Test @MainActor
    func reloadDetectorReleasesTheOldGenerationBeforeRestarting() async throws {
        let recorder = HandoffRecorderProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { HandoffDetectorProbe() }
        )

        await controller.setEnabled(true)
        _ = try await controller.reloadDetector()

        #expect(controller.state == .monitoring)
        #expect(recorder.startCount == 2)
        #expect(recorder.stopCount == 1)
    }

    @Test @MainActor
    func detectorReloadUsesRequestedSherpaTuning() async throws {
        let recorder = HandoffRecorderProbe()
        let factory = HandoffTunedDetectorFactory()
        let controller = WakeWordProductionController(
            recorder: recorder,
            tunedDetectorFactory: { tuning in
                try MainActor.assumeIsolated { try factory.make(tuning: tuning) }
            }
        )
        let requested = try #require(SherpaWakeWordTuning(
            keywordScore: 7.0,
            keywordThreshold: 0.08
        ))

        await controller.setEnabled(true)
        _ = try await controller.applyDetectorTuningFromSettings(requested)

        #expect(factory.createdTunings == [.default, requested])
        #expect(controller.state == .monitoring)
        #expect(recorder.startCount == 2)
    }

    @Test @MainActor
    func failedTuningReloadRestoresTheLastWorkingDetector() async throws {
        let recorder = HandoffRecorderProbe()
        let factory = HandoffTunedDetectorFactory(rejectedKeywordScore: 8.0)
        let controller = WakeWordProductionController(
            recorder: recorder,
            tunedDetectorFactory: { tuning in
                try MainActor.assumeIsolated { try factory.make(tuning: tuning) }
            }
        )
        let rejected = try #require(SherpaWakeWordTuning(
            keywordScore: 8.0,
            keywordThreshold: 0.1
        ))

        await controller.setEnabled(true)
        await #expect(throws: (any Error).self) {
            _ = try await controller.applyDetectorTuningFromSettings(rejected)
        }

        #expect(factory.createdTunings == [.default, rejected, .default])
        #expect(controller.state == .monitoring)
        #expect(recorder.isWakeMonitoring)
    }

    @Test @MainActor
    func activeWakeWaitsForSystemWakeBeforeRearming() async {
        let recorder = HandoffRecorderProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { HandoffDetectorProbe() }
        )

        await controller.setEnabled(true)
        await controller.setSystemAwake(false)
        await controller.setSystemAwake(true)
        await controller.resumeAfterLiveCleanup()

        #expect(controller.state == .monitoring)
        #expect(recorder.startCount == 2)
    }

    @Test @MainActor
    func liveCleanupCannotRestartCaptureWhileAsleep() async {
        let recorder = HandoffRecorderProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { HandoffDetectorProbe() }
        )

        await controller.setEnabled(true)
        await controller.setSystemAwake(false)
        await controller.resumeAfterLiveCleanup()

        #expect(controller.state == .suspended(.sleep))
        #expect(recorder.startCount == 1)

        await controller.setSystemAwake(true)
        await controller.resumeAfterLiveCleanup()

        #expect(controller.state == .monitoring)
        #expect(recorder.startCount == 2)
    }

    @Test @MainActor
    func wakeDetectionStopsRecorderBeforeCallback() async {
        let recorder = HandoffRecorderProbe()
        let detector = HandoffDetectorProbe()
        let callback = WakeTriggerProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { detector },
            onWakeDetected: {
                callback.record(stopCompleted: recorder.stopCompleted)
            }
        )

        await controller.setEnabled(true)
        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        await waitUntil { callback.count == 1 }
        recorder.emit(ContiguousArray(repeating: 0, count: 480))

        #expect(callback.count == 1)
        #expect(callback.sawCompletedStop)
        #expect(recorder.stopCompleted)
        #expect(recorder.stopCount == 1)
        #expect(controller.state == .suspended(.processing))
    }
}

@MainActor
private final class HandoffTunedDetectorFactory {
    private let rejectedKeywordScore: Double?
    private(set) var createdTunings = [SherpaWakeWordTuning]()

    init(rejectedKeywordScore: Double? = nil) {
        self.rejectedKeywordScore = rejectedKeywordScore
    }

    func make(tuning: SherpaWakeWordTuning) throws -> HandoffDetectorProbe {
        createdTunings.append(tuning)
        if tuning.keywordScore == rejectedKeywordScore {
            throw WakeWordDetectorError.unavailable
        }
        return HandoffDetectorProbe()
    }
}

@MainActor
private final class HandoffRecorderProbe: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopCompleted = false

    func startWakeMonitoring() async throws -> UUID {
        startCount += 1
        isWakeMonitoring = true
        return UUID()
    }

    func stopWakeMonitoring() async {
        stopCount += 1
        isWakeMonitoring = false
        stopCompleted = true
    }

    func emit(_ samples: ContiguousArray<Int16>) {
        onSamples?(samples)
    }
}

@MainActor
private final class WakeTriggerProbe {
    private(set) var count = 0
    private(set) var sawCompletedStop = false

    func record(stopCompleted: Bool) {
        count += 1
        sawCompletedStop = stopCompleted
    }
}

private final class HandoffDetectorProbe: WakeWordDetecting, @unchecked Sendable {
    let requiredSampleRate = 16_000
    let requiredFrameLength = 480
    private let lock = NSLock()
    private var didDetect = false

    func process(frame: ContiguousArray<Int16>) throws -> Bool {
        lock.withLock {
            guard !didDetect else { return false }
            didDetect = true
            return true
        }
    }

    func reset() throws {}
    func shutdown() {}
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

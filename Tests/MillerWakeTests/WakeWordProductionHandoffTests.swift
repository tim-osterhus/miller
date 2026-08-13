import Foundation
import Testing
@testable import MillerWake

@Suite("Wakeword production handoff")
struct WakeWordProductionHandoffTests {
    @Test
    func productionRequiresAdmissionAwareWakeHandler() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/MillerWake/WakeWordProductionController.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("onWakeDetectedWithAdmission"))
        #expect(!source.contains("WakeWordDetectedHandler"))
        #expect(!source.contains("onWakeDetected:"))
    }

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
    func liveCleanupWaitsForSettlingInputRouteBeforeRearming() async {
        let recorder = SettlingHandoffRecorderProbe()
        let handoffSleep = HandoffSleepGate()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { HandoffDetectorProbe() },
            eventScheduler: { operation in
                Task { @MainActor in await operation() }
            },
            handoffSleep: { await handoffSleep.wait() }
        )

        await controller.setEnabled(true)
        await controller.suspend(.foregroundSession)
        recorder.inputRouteSettled = false

        let rearm = Task { @MainActor in
            await controller.resumeAfterLiveCleanup()
        }
        await handoffSleep.waitUntilEntered()

        #expect(recorder.startCount == 1)
        #expect(controller.state == .suspended(.foregroundSession))

        recorder.inputRouteSettled = true
        await handoffSleep.release()
        await rearm.value

        #expect(controller.state == .monitoring)
        #expect(recorder.startCount == 2)
    }

    @Test @MainActor
    func liveCleanupDoesNotRearmAfterDisableDuringSettlingDelay() async {
        let recorder = SettlingHandoffRecorderProbe()
        let handoffSleep = HandoffSleepGate()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { HandoffDetectorProbe() },
            eventScheduler: { operation in
                Task { @MainActor in await operation() }
            },
            handoffSleep: { await handoffSleep.wait() }
        )

        await controller.setEnabled(true)
        await controller.suspend(.foregroundSession)
        recorder.inputRouteSettled = true

        let rearm = Task { @MainActor in
            await controller.resumeAfterLiveCleanup()
        }
        await handoffSleep.waitUntilEntered()

        let disable = Task { @MainActor in
            await controller.setEnabled(false)
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        await handoffSleep.release()
        await rearm.value
        await disable.value

        #expect(controller.state == .disabled)
        #expect(recorder.startCount == 1)
        #expect(recorder.isWakeMonitoring == false)
    }

    @Test @MainActor
    func canceledLiveCleanupDoesNotRearmAfterSettlingDelay() async {
        let recorder = SettlingHandoffRecorderProbe()
        let handoffSleep = HandoffSleepGate()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { HandoffDetectorProbe() },
            eventScheduler: { operation in
                Task { @MainActor in await operation() }
            },
            handoffSleep: { await handoffSleep.wait() }
        )

        await controller.setEnabled(true)
        await controller.suspend(.foregroundSession)

        let rearm = Task { @MainActor in
            await controller.resumeAfterLiveCleanup()
        }
        await handoffSleep.waitUntilEntered()
        rearm.cancel()
        await handoffSleep.release()
        await rearm.value

        #expect(controller.state == .suspended(.foregroundSession))
        #expect(recorder.startCount == 1)
        #expect(recorder.isWakeMonitoring == false)
    }

    @Test @MainActor
    func wakeDetectionStopsRecorderBeforeCallback() async {
        let recorder = HandoffRecorderProbe()
        let detector = HandoffDetectorProbe()
        let callback = WakeTriggerProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { detector },
            onWakeDetectedWithAdmission: { admission in
                callback.record(
                    stopCompleted: recorder.stopCompleted,
                    admissionValid: admission.isValid
                )
                admission.cancel()
            }
        )

        await controller.setEnabled(true)
        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        await waitUntil { callback.count == 1 }
        recorder.emit(ContiguousArray(repeating: 0, count: 480))

        #expect(callback.count == 1)
        #expect(callback.sawCompletedStop)
        #expect(callback.sawValidAdmission)
        #expect(recorder.stopCompleted)
        #expect(recorder.stopCount == 1)
        #expect(controller.state == .suspended(.processing))
    }

    @Test @MainActor
    func completedWakeRecreatesDetectorBeforeSecondTrigger() async {
        let recorder = HandoffRecorderProbe()
        let factory = HandoffTunedDetectorFactory()
        let callback = WakeTriggerProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            tunedDetectorFactory: { tuning in
                try MainActor.assumeIsolated { try factory.make(tuning: tuning) }
            },
            initialTuning: .default,
            onWakeDetectedWithAdmission: { admission in
                callback.record(
                    stopCompleted: recorder.stopCompleted,
                    admissionValid: admission.isValid
                )
                await admission.complete()
            },
            eventScheduler: { operation in
                Task { @MainActor in await operation() }
            },
            handoffSleep: {}
        )

        await controller.setEnabled(true)
        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        await waitUntil {
            callback.count == 1 && controller.state == .monitoring
        }

        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        await waitUntil {
            callback.count == 2 && controller.state == .monitoring
        }

        #expect(callback.count == 2)
        #expect(factory.createdTunings == [.default, .default, .default])
        #expect(recorder.startCount == 3)
        #expect(recorder.stopCount == 2)
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
private final class SettlingHandoffRecorderProbe: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    var inputRouteSettled = true
    private(set) var isWakeMonitoring = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startWakeMonitoring() async throws -> UUID {
        startCount += 1
        guard inputRouteSettled else {
            throw WakeWordCaptureStartError.inputDeviceUnavailable
        }
        isWakeMonitoring = true
        return UUID()
    }

    func stopWakeMonitoring() async {
        stopCount += 1
        isWakeMonitoring = false
    }
}

private actor HandoffSleepGate {
    private var entered = false
    private var entryWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class WakeTriggerProbe {
    private(set) var count = 0
    private(set) var sawCompletedStop = false
    private(set) var sawValidAdmission = false

    func record(stopCompleted: Bool, admissionValid: Bool) {
        count += 1
        sawCompletedStop = stopCompleted
        sawValidAdmission = admissionValid
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

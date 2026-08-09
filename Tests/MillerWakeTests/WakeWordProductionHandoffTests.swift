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
    func commandAudioIsDeliveredOnceAfterWakeDetection() async {
        let recorder = HandoffRecorderProbe()
        let detector = HandoffDetectorProbe()
        let events = HandoffEvents()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { detector },
            onWakeDetected: { await events.recordWake() },
            onCommandAudio: { audio, reason in
                await events.recordCommand(audio: audio, reason: reason)
            }
        )

        await controller.setEnabled(true)
        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        await waitUntil { controller.state == .handoff }
        for _ in 0..<5 {
            recorder.emit(ContiguousArray(repeating: 10_000, count: 480))
        }
        for _ in 0..<50 {
            recorder.emit(ContiguousArray(repeating: 0, count: 480))
        }
        await events.waitForCommand()

        let snapshot = await events.snapshot()
        #expect(snapshot.wakeCount == 1)
        #expect(snapshot.commandCount == 1)
        #expect(snapshot.reason == .silence)
        #expect(snapshot.sampleCount > 0)
        #expect(snapshot.sampleCount <= 32_000)
    }
}

@MainActor
private final class HandoffRecorderProbe: WakeWordCaptureOwning {
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

    func emit(_ samples: ContiguousArray<Int16>) {
        onSamples?(samples)
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

private actor HandoffEvents {
    struct Snapshot: Sendable {
        var wakeCount = 0
        var commandCount = 0
        var sampleCount = 0
        var reason: WakeCommandEndpointEvent?
    }

    private var value = Snapshot()
    private var commandWaiters = [CheckedContinuation<Void, Never>]()

    func recordWake() {
        value.wakeCount += 1
    }

    func recordCommand(
        audio: WakeWordPreparedCommandAudio,
        reason: WakeCommandEndpointEvent
    ) {
        value.commandCount += 1
        value.sampleCount = audio.samples.count
        value.reason = reason
        let waiters = commandWaiters
        commandWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForCommand() async {
        guard value.commandCount == 0 else { return }
        await withCheckedContinuation { commandWaiters.append($0) }
    }

    func snapshot() -> Snapshot { value }
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

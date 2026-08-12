import Foundation
import Testing
@testable import MillerWake

@Suite("Wakeword donor parity")
struct WakeWordDonorParityTests {
    @Test @MainActor
    func wakeListeningDefaultsDisabled() {
        let settings = WakeWordSettingsController(
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
    func wakeDetectionSuspendsImmediatelyAndIgnoresSubsequentAudio() throws {
        let generation: UInt64
        let coordinator = WakeWordCoordinator(
            detector: DetectorProbe(process: { _ in true })
        )
        generation = try #require(coordinator.beginStarting())
        try coordinator.confirmMonitoring(generation: generation)

        let firstEvents = coordinator.receive(
            samples: ContiguousArray(repeating: 0, count: 480),
            generation: generation
        )
        let laterEvents = coordinator.receive(
            samples: ContiguousArray(repeating: 0, count: 480),
            generation: generation
        )

        #expect(firstEvents == [.wakeDetected(generation: generation)])
        #expect(laterEvents.isEmpty)
        #expect(coordinator.currentState() == .suspended(.processing))
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

    @Test @MainActor
    func suspendedStartCannotPublishAfterSuspension() async {
        let recorder = GatedRecorderProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { DetectorProbe() }
        )

        let start = Task { @MainActor in
            await controller.setEnabled(true)
        }
        await recorder.waitForStartRequest()
        let suspension = Task { @MainActor in
            await controller.suspend(.foregroundSession)
        }
        await waitUntil {
            controller.state == .suspended(.foregroundSession)
        }
        recorder.releaseStart()
        await start.value
        await suspension.value

        #expect(recorder.isWakeMonitoring == false)
        #expect(controller.state == .suspended(.foregroundSession))
    }

    @Test @MainActor
    func suspendedStartCannotPublishAfterDisable() async {
        let recorder = GatedRecorderProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { DetectorProbe() }
        )

        let start = Task { @MainActor in
            await controller.setEnabled(true)
        }
        await recorder.waitForStartRequest()
        let disable = Task { @MainActor in
            await controller.setEnabled(false)
        }
        await waitUntil { controller.state == .stopping }
        recorder.releaseStart()
        await start.value
        await disable.value

        #expect(recorder.isWakeMonitoring == false)
        #expect(controller.state == .disabled)
    }

    @Test @MainActor
    func suspendedStartCannotPublishAfterShutdown() async {
        let recorder = GatedRecorderProbe()
        let detector = DetectorProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { detector }
        )

        let start = Task { @MainActor in
            await controller.setEnabled(true)
        }
        await recorder.waitForStartRequest()
        let shutdown = Task { @MainActor in
            await controller.shutdown()
        }
        await waitUntil { controller.state == .stopping }
        recorder.releaseStart()
        await start.value
        #expect(await shutdown.value)

        #expect(recorder.isWakeMonitoring == false)
        #expect(detector.shutdownCount == 1)
        #expect(controller.state == .disabled)
    }

    @Test @MainActor
    func newestEnableWaitsForSupersededStartupAndReconcilesMonitoring() async {
        let recorder = GatedRecorderProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { DetectorProbe() }
        )

        let firstEnable = Task { @MainActor in
            await controller.setEnabled(true)
        }
        await recorder.waitForStartRequest(count: 1)
        let newestEnable = Task { @MainActor in
            await controller.setEnabled(true)
        }

        recorder.releaseStart()
        await recorder.waitForStartRequest(count: 2)
        recorder.releaseStart()
        await firstEnable.value
        await newestEnable.value

        #expect(controller.state == .monitoring)
        #expect(recorder.isWakeMonitoring)
        #expect(recorder.startCount == 2)
        #expect(recorder.stopCount == 1)
    }

    @Test @MainActor
    func newestEnableWaitsForSupersededStopAndReconcilesMonitoring() async {
        let recorder = GatedStopRecorderProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { DetectorProbe() }
        )
        await controller.setEnabled(true)

        let disable = Task { @MainActor in
            await controller.setEnabled(false)
        }
        await recorder.waitForStopRequest()
        let newestEnable = Task { @MainActor in
            await controller.setEnabled(true)
        }

        recorder.releaseStop()
        await disable.value
        await newestEnable.value

        #expect(controller.state == .monitoring)
        #expect(recorder.isWakeMonitoring)
        #expect(recorder.startCount == 2)
        #expect(recorder.stopCount == 1)
    }

    @Test @MainActor
    func shutdownSerializesBehindAnInFlightDisableStop() async {
        let recorder = GatedStopRecorderProbe()
        let detector = DetectorProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { detector }
        )
        await controller.setEnabled(true)

        let disable = Task { @MainActor in
            await controller.setEnabled(false)
        }
        await recorder.waitForStopRequest(count: 1)
        let shutdown = Task { @MainActor in
            await controller.shutdown()
        }
        await Task.yield()
        await Task.yield()

        #expect(recorder.stopRequestCount == 1)
        #expect(recorder.maximumConcurrentStopCount == 1)

        recorder.releaseAllStops()
        await disable.value
        #expect(await shutdown.value)

        #expect(controller.state == .disabled)
        #expect(recorder.isWakeMonitoring == false)
        #expect(recorder.stopCount == 1)
        #expect(recorder.maximumConcurrentStopCount == 1)
        #expect(detector.shutdownCount == 1)
    }

    @Test @MainActor
    func disableSerializesBehindAnInFlightSuspensionStop() async {
        let recorder = GatedStopRecorderProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { DetectorProbe() }
        )
        await controller.setEnabled(true)

        let suspension = Task { @MainActor in
            await controller.suspend(.foregroundSession)
        }
        await recorder.waitForStopRequest(count: 1)
        let disable = Task { @MainActor in
            await controller.setEnabled(false)
        }
        await Task.yield()
        await Task.yield()

        #expect(recorder.stopRequestCount == 1)
        #expect(recorder.maximumConcurrentStopCount == 1)

        recorder.releaseAllStops()
        await suspension.value
        await disable.value

        #expect(controller.state == .disabled)
        #expect(recorder.isWakeMonitoring == false)
        #expect(recorder.stopCount == 1)
        #expect(recorder.maximumConcurrentStopCount == 1)
    }

    @Test @MainActor
    func detectorFailureReleasesCaptureBeforePublishingUnavailable() async {
        let recorder = RecorderProbe()
        let detector = DetectorProbe(process: { _ in
            throw WakeWordDetectorError.runtimeFailure
        })
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { detector }
        )

        await controller.setEnabled(true)
        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        await waitUntil { controller.state == .unavailable(.detectorRuntime) }

        #expect(controller.state == .unavailable(.detectorRuntime))
        #expect(recorder.isWakeMonitoring == false)
        #expect(recorder.onSamples == nil)
        #expect(recorder.stopCount == 1)
        #expect(detector.shutdownCount == 1)
    }

    @Test @MainActor
    func queuedWakeEventCannotPublishAfterSuspension() async {
        let recorder = RecorderProbe()
        let scheduler = EventSchedulerProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: { DetectorProbe(process: { _ in true }) },
            eventScheduler: scheduler.enqueue
        )

        await controller.setEnabled(true)
        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        #expect(scheduler.count == 1)

        await controller.suspend(.foregroundSession)
        await scheduler.drain()

        #expect(controller.state == .suspended(.foregroundSession))
    }

    @Test @MainActor
    func queuedDetectorFailureCannotPublishAfterDisable() async {
        let recorder = RecorderProbe()
        let scheduler = EventSchedulerProbe()
        let controller = WakeWordProductionController(
            recorder: recorder,
            detectorFactory: {
                DetectorProbe(process: { _ in
                    throw WakeWordDetectorError.runtimeFailure
                })
            },
            eventScheduler: scheduler.enqueue
        )

        await controller.setEnabled(true)
        recorder.emit(ContiguousArray(repeating: 0, count: 480))
        #expect(scheduler.count == 1)

        await controller.setEnabled(false)
        await scheduler.drain()

        #expect(controller.state == .disabled)
        #expect(recorder.isWakeMonitoring == false)
    }

    @Test @MainActor
    func settingsControllerDoesNotRetainItselfAcrossAnOperationAwait() async {
        let gate = StateOperationGate()
        var controller: WakeWordSettingsController? = WakeWordSettingsController(
            enable: { await gate.run() },
            disable: { .disabled }
        )
        weak var weakController = controller

        controller?.setEnabled(true)
        await gate.waitUntilStarted()
        controller = nil
        await waitUntil { weakController == nil }

        #expect(weakController == nil)
        await gate.finish(with: .monitoring)
    }

    @Test
    func sherpaRuntimeMapsCreateAcceptResetAndIdempotentDestroy() throws {
        let probe = SherpaRuntimeProbe(createHandle: true)
        let detector = try SherpaWakeWordDetector(
            paths: modelPaths(),
            runtime: probe.runtime
        )

        probe.acceptResult = 0
        #expect(try detector.process(frame: .init(repeating: 0, count: 480)) == false)
        probe.acceptResult = 1
        #expect(try detector.process(frame: .init(repeating: 0, count: 480)))
        probe.acceptResult = -1
        #expect(throws: WakeWordDetectorError.runtimeFailure) {
            try detector.process(frame: .init(repeating: 0, count: 480))
        }
        #expect(throws: WakeWordDetectorError.invalidFrame) {
            try detector.process(frame: [0])
        }

        detector.shutdown()
        detector.shutdown()
        #expect(throws: WakeWordDetectorError.unavailable) {
            try detector.reset()
        }
        #expect(probe.destroyCount == 1)
    }

    @Test
    func sherpaRuntimeRejectsNilCreate() {
        let probe = SherpaRuntimeProbe(createHandle: false)
        #expect(throws: WakeWordDetectorError.unavailable) {
            try SherpaWakeWordDetector(
                paths: modelPaths(),
                runtime: probe.runtime
            )
        }
        #expect(probe.destroyCount == 0)
    }
}

private final class DetectorProbe: WakeWordDetecting, @unchecked Sendable {
    let requiredSampleRate = 16_000
    let requiredFrameLength = 480
    private(set) var shutdownCount = 0
    private let processOperation:
        @Sendable (ContiguousArray<Int16>) throws -> Bool

    init(
        process: @escaping @Sendable (ContiguousArray<Int16>) throws -> Bool = {
            _ in false
        }
    ) {
        processOperation = process
    }

    func process(frame: ContiguousArray<Int16>) throws -> Bool {
        try processOperation(frame)
    }
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

    func emit(_ samples: ContiguousArray<Int16>) {
        onSamples?(samples)
    }
}

@MainActor
private final class GatedRecorderProbe: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var startWaiters = [(Int, CheckedContinuation<Void, Never>)]()
    private var startGates = [CheckedContinuation<Void, Never>]()

    func startWakeMonitoring() async throws -> UUID {
        startCount += 1
        let ready = startWaiters.filter { $0.0 <= startCount }
        startWaiters.removeAll { $0.0 <= startCount }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { continuation in
            startGates.append(continuation)
        }
        isWakeMonitoring = true
        return UUID()
    }

    func stopWakeMonitoring() async {
        guard isWakeMonitoring else { return }
        isWakeMonitoring = false
        stopCount += 1
    }

    func waitForStartRequest(count: Int = 1) async {
        guard startCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func releaseStart() {
        guard !startGates.isEmpty else { return }
        startGates.removeFirst().resume()
    }
}

@MainActor
private final class GatedStopRecorderProbe: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopRequestCount = 0
    private(set) var maximumConcurrentStopCount = 0
    private var concurrentStopCount = 0
    private var stopWaiters = [(Int, CheckedContinuation<Void, Never>)]()
    private var stopGates = [CheckedContinuation<Void, Never>]()

    func startWakeMonitoring() async throws -> UUID {
        startCount += 1
        isWakeMonitoring = true
        return UUID()
    }

    func stopWakeMonitoring() async {
        stopRequestCount += 1
        concurrentStopCount += 1
        maximumConcurrentStopCount = max(
            maximumConcurrentStopCount,
            concurrentStopCount
        )
        let ready = stopWaiters.filter { $0.0 <= stopRequestCount }
        stopWaiters.removeAll { $0.0 <= stopRequestCount }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { continuation in
            stopGates.append(continuation)
        }
        concurrentStopCount -= 1
        isWakeMonitoring = false
        stopCount += 1
    }

    func waitForStopRequest(count: Int = 1) async {
        guard stopRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append((count, continuation))
        }
    }

    func releaseStop() {
        guard !stopGates.isEmpty else { return }
        stopGates.removeFirst().resume()
    }

    func releaseAllStops() {
        let gates = stopGates
        stopGates.removeAll()
        gates.forEach { $0.resume() }
    }
}

private actor StateOperationGate {
    private var started = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var result: WakeWordState?
    private var resultWaiters = [CheckedContinuation<WakeWordState, Never>]()

    func run() async -> WakeWordState {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let result { return result }
        return await withCheckedContinuation { continuation in
            resultWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(with state: WakeWordState) {
        result = state
        let waiters = resultWaiters
        resultWaiters.removeAll()
        waiters.forEach { $0.resume(returning: state) }
    }
}

private final class EventSchedulerProbe: @unchecked Sendable {
    typealias Operation = @MainActor @Sendable () async -> Void
    private let lock = NSLock()
    private var operations = [Operation]()

    var count: Int {
        lock.withLock { operations.count }
    }

    func enqueue(_ operation: @escaping Operation) {
        lock.withLock { operations.append(operation) }
    }

    @MainActor
    func drain() async {
        while true {
            let operation = lock.withLock {
                operations.isEmpty ? nil : operations.removeFirst()
            }
            guard let operation else { return }
            await operation()
        }
    }
}

private final class SherpaRuntimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let createHandle: Bool
    var acceptResult: Int32 = 0
    private(set) var destroyCount = 0

    init(createHandle: Bool) {
        self.createHandle = createHandle
    }

    var runtime: SherpaWakeWordRuntime {
        SherpaWakeWordRuntime(
            create: { [self] _, _ in
                createHandle ? OpaquePointer(bitPattern: 0x1) : nil
            },
            accept: { [self] _, _, _ in lock.withLock { acceptResult } },
            reset: { _ in },
            destroy: { [self] _ in
                lock.withLock { destroyCount += 1 }
            }
        )
    }
}

private func modelPaths() -> WakeWordModelPaths {
    WakeWordModelPaths(
        encoder: URL(fileURLWithPath: "/private/tmp/encoder.onnx"),
        decoder: URL(fileURLWithPath: "/private/tmp/decoder.onnx"),
        joiner: URL(fileURLWithPath: "/private/tmp/joiner.onnx"),
        tokens: URL(fileURLWithPath: "/private/tmp/tokens.txt"),
        keywords: URL(fileURLWithPath: "/private/tmp/keywords.txt")
    )
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
}

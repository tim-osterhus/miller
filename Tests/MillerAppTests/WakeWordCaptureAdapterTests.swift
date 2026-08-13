import AVFoundation
import Foundation
import MillerLiveAudio
import MillerWake
import Testing
@testable import MillerApp

@Suite("Wakeword capture adapter")
struct WakeWordCaptureAdapterTests {
    @Test
    func realtimeCallbackHandsActorWorkToMainActor() async {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "MillerWakeTests.realtime").async {
                WakeWordRealtimeHandoff.deliver(42) { value in
                    MainActor.preconditionIsolated()
                    #expect(value == 42)
                    continuation.resume()
                }
            }
        }
    }

    @Test
    func audioTapCopiesBoundedSamplesBeforeTheMainActorHandoff() async throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 2
        ))
        buffer.frameLength = 2
        buffer.floatChannelData?[0][0] = 0.25
        buffer.floatChannelData?[0][1] = -0.5
        let sourceIdentity = ObjectIdentifier(buffer)
        #expect(WakeWordAudioBufferSnapshot(
            copying: buffer,
            maximumFrameCount: 1
        ) == nil)

        await withCheckedContinuation { continuation in
            let tap = WakeWordRealtimeAudioTap.make { snapshot in
                MainActor.preconditionIsolated()
                #expect(ObjectIdentifier(snapshot.buffer) != sourceIdentity)
                #expect(snapshot.buffer.frameLength == 2)
                #expect(snapshot.buffer.floatChannelData?[0][0] == 0.25)
                #expect(snapshot.buffer.floatChannelData?[0][1] == -0.5)
                continuation.resume()
            }
            let invocation = UncheckedSendableBox((tap, buffer))
            DispatchQueue(label: "MillerWakeTests.audio-tap").async {
                invocation.value.0(invocation.value.1, AVAudioTime())
            }
        }
    }

    @Test
    @MainActor
    func legitimateLargeTapBufferIsDeliveredAsOrderedBoundedSnapshots() async throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 2_500
        ))
        buffer.frameLength = 2_500
        for index in 0..<2_500 {
            buffer.floatChannelData?[0][index] = Float(index)
        }

        let snapshots = await withCheckedContinuation { continuation in
            var received = [WakeWordAudioBufferSnapshot]()
            let tap = WakeWordRealtimeAudioTap.make(
                chunkFrameCount: 1_024,
                maximumBufferFrameCount: 4_096,
                onFailure: {
                    Issue.record("Legitimate tap buffer was rejected")
                },
                receive: { snapshot in
                    received.append(snapshot)
                    if received.count == 3 {
                        continuation.resume(returning: received)
                    }
                }
            )
            let invocation = UncheckedSendableBox((tap, buffer))
            DispatchQueue(label: "MillerWakeTests.large-audio-tap").async {
                invocation.value.0(invocation.value.1, AVAudioTime())
            }
        }

        #expect(snapshots.map(\.buffer.frameLength) == [1_024, 1_024, 452])
        #expect(snapshots.map { $0.buffer.floatChannelData?[0][0] } == [
            0,
            1_024,
            2_048,
        ])
    }

    @Test
    @MainActor
    func trulyOversizedTapBufferReportsFailureInsteadOfDroppingSilently() async throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_097
        ))
        buffer.frameLength = 4_097
        let failed = await withCheckedContinuation { continuation in
            let tap = WakeWordRealtimeAudioTap.make(
                chunkFrameCount: 1_024,
                maximumBufferFrameCount: 4_096,
                onFailure: {
                    continuation.resume(returning: true)
                },
                receive: { _ in
                    Issue.record("Oversized tap buffer was delivered")
                }
            )
            tap(buffer, AVAudioTime())
        }

        #expect(failed)
    }

    @Test
    @MainActor
    func startedAdapterHandsInstalledTapToMainActorAndFencesOldGeneration() async throws {
        let audio = InjectedWakeAudioEngine()
        let adapter = WakeWordAVAudioCaptureAdapter(
            ownership: MicrophoneOwnership(),
            permissionStatus: { .authorized },
            requestPermission: { .authorized },
            inputAvailable: { true },
            audioEngineBoundaryFactory: { audio.boundary }
        )
        let received = WakeSampleDeliveryProbe()
        adapter.onSamples = { samples in
            received.record(samples, deliveredOnMainThread: Thread.isMainThread)
        }

        _ = try await adapter.startWakeMonitoring()
        let oldTap = try #require(audio.installedTaps.first)
        audio.invokeAndOverwriteAfterTap(
            oldTap,
            buffer: try audio.makeBuffer(),
            replacementSample: 12_345
        )
        try await waitForSampleCount(1, in: received)
        #expect(received.deliveries == [
            .init(
                sampleCount: 480,
                firstSample: 0,
                deliveredOnMainThread: true
            ),
        ])

        await adapter.stopWakeMonitoring()
        _ = try await adapter.startWakeMonitoring()
        let currentTap = try #require(audio.installedTaps.last)
        audio.invoke(oldTap, with: try audio.makeBuffer())
        audio.invoke(currentTap, with: try audio.makeBuffer())
        try await waitForSampleCount(2, in: received)
        try await Task.sleep(for: .milliseconds(25))
        #expect(received.deliveries.count == 2)
        #expect(received.deliveries.last == .init(
            sampleCount: 480,
            firstSample: 0,
            deliveredOnMainThread: true
        ))

        await adapter.stopWakeMonitoring()
    }

    @Test
    @MainActor
    func restartNegotiatesNativeTapAndConvertsTheDeliveredFormat() async throws {
        let initialFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let postLiveFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let deliveredFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ))
        let audio = InjectedWakeAudioEngine(format: initialFormat)
        let adapter = WakeWordAVAudioCaptureAdapter(
            ownership: MicrophoneOwnership(),
            permissionStatus: { .authorized },
            requestPermission: { .authorized },
            inputAvailable: { true },
            audioEngineBoundaryFactory: { audio.boundary }
        )
        let received = WakeSampleDeliveryProbe()
        let failures = WakeCaptureFailureProbe()
        adapter.onSamples = { samples in
            received.record(samples, deliveredOnMainThread: Thread.isMainThread)
        }
        adapter.setFailureHandler { failures.record($0) }

        _ = try await adapter.startWakeMonitoring()
        await adapter.stopWakeMonitoring()
        audio.setOutputFormat(postLiveFormat)
        _ = try await adapter.startWakeMonitoring()

        let nativeTapNegotiation = audio.installedTapFormats.map { $0 == nil }
        #expect(nativeTapNegotiation == [true, true])
        guard nativeTapNegotiation == [true, true] else { return }

        audio.setOutputFormat(deliveredFormat)
        let currentTap = try #require(audio.installedTaps.last)
        audio.invoke(
            currentTap,
            with: try audio.makeBuffer(
                format: deliveredFormat,
                frameCount: 1_024
            )
        )
        try await waitForSampleCount(1, in: received)

        #expect(received.deliveries == [
            .init(
                sampleCount: 480,
                firstSample: 0,
                deliveredOnMainThread: true
            ),
        ])
        #expect(failures.reasons.isEmpty)
        #expect(adapter.isWakeMonitoring)

        await adapter.stopWakeMonitoring()
    }

    @Test
    @MainActor
    func restartCreatesFreshEngineForTheCurrentHardwareRoute() async throws {
        let route48k = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let route16k = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let audio = InjectedWakeAudioEngineFactory(format: route48k)
        let adapter = WakeWordAVAudioCaptureAdapter(
            ownership: MicrophoneOwnership(),
            permissionStatus: { .authorized },
            requestPermission: { .authorized },
            inputAvailable: { true },
            audioEngineBoundaryFactory: audio.makeBoundary
        )
        let received = WakeSampleDeliveryProbe()
        adapter.onSamples = { samples in
            received.record(samples, deliveredOnMainThread: Thread.isMainThread)
        }

        _ = try await adapter.startWakeMonitoring()
        weak var releasedFirstEngine: InjectedWakeAudioEngine?
        do {
            let firstEngine = try #require(audio.liveEngines.first)
            releasedFirstEngine = firstEngine
            #expect(firstEngine.outputSampleRate == 48_000)
            await adapter.stopWakeMonitoring()
            #expect(firstEngine.stopCount == 1)
        }
        #expect(releasedFirstEngine == nil)

        audio.setHardwareFormat(route16k)
        _ = try await adapter.startWakeMonitoring()
        #expect(audio.creationCount == 2)
        let secondEngine = try #require(audio.liveEngines.last)
        #expect(secondEngine.outputSampleRate == 16_000)
        let currentTap = try #require(secondEngine.installedTaps.last)
        secondEngine.invoke(
            currentTap,
            with: try secondEngine.makeBuffer(frameCount: 480)
        )
        try await waitForSampleCount(1, in: received)

        #expect(received.deliveries == [
            .init(
                sampleCount: 480,
                firstSample: 0,
                deliveredOnMainThread: true
            ),
        ])
        #expect(adapter.isWakeMonitoring)

        await adapter.stopWakeMonitoring()
    }

    @Test
    @MainActor
    func inputAvailabilityMonitorToleratesTransientRecoveryAndBoundsSustainedFailure() async throws {
        let audio = InjectedWakeAudioEngine()
        let input = WakeInputAvailabilityProbe()
        let monitorGate = WakeAvailabilityMonitorGate()
        let adapter = WakeWordAVAudioCaptureAdapter(
            ownership: MicrophoneOwnership(),
            permissionStatus: { .authorized },
            requestPermission: { .authorized },
            inputAvailable: { input.isAvailable },
            audioEngineBoundaryFactory: { audio.boundary },
            waitForAvailabilityCheck: { await monitorGate.wait() }
        )
        let received = WakeSampleDeliveryProbe()
        let failures = WakeCaptureFailureProbe()
        adapter.onSamples = { samples in
            received.record(samples, deliveredOnMainThread: Thread.isMainThread)
        }
        adapter.setFailureHandler { failures.record($0) }

        _ = try await adapter.startWakeMonitoring()
        await waitForMonitorWaiters(monitorGate, atLeast: 1)
        await adapter.stopWakeMonitoring()
        _ = try await adapter.startWakeMonitoring()
        await waitForMonitorWaiters(monitorGate, atLeast: 2)

        input.setAvailable(false)
        monitorGate.signal()
        await Task.yield()
        #expect(adapter.isWakeMonitoring)
        #expect(failures.reasons.isEmpty)

        monitorGate.signal()
        await waitForMonitorWaiters(monitorGate, atLeast: 1)
        input.setAvailable(true)
        monitorGate.signal()
        await waitForMonitorWaiters(monitorGate, atLeast: 1)

        #expect(adapter.isWakeMonitoring)
        #expect(failures.reasons.isEmpty)

        let currentTap = try #require(audio.installedTaps.last)
        audio.invoke(currentTap, with: try audio.makeBuffer(frameCount: 480))
        try await waitForSampleCount(1, in: received)

        #expect(received.deliveries == [
            .init(
                sampleCount: 480,
                firstSample: 0,
                deliveredOnMainThread: true
            ),
        ])
        #expect(adapter.isWakeMonitoring)

        input.setAvailable(false)
        for _ in 0..<3 {
            await waitForMonitorWaiters(monitorGate, atLeast: 1)
            monitorGate.signal()
        }
        await waitForMonitoringState(false, in: adapter)

        #expect(failures.reasons == [.inputDevice])
        #expect(!adapter.isWakeMonitoring)
    }

    @Test
    @MainActor
    func startedAdapterReportsOversizedTapBufferAndStopsMonitoring() async throws {
        let audio = InjectedWakeAudioEngine()
        let adapter = WakeWordAVAudioCaptureAdapter(
            ownership: MicrophoneOwnership(),
            permissionStatus: { .authorized },
            requestPermission: { .authorized },
            inputAvailable: { true },
            audioEngineBoundaryFactory: { audio.boundary }
        )
        let failures = WakeCaptureFailureProbe()
        adapter.setFailureHandler { failures.record($0) }

        _ = try await adapter.startWakeMonitoring()
        let tap = try #require(audio.installedTaps.first)
        audio.invoke(tap, with: try audio.makeBuffer(frameCount: 16_385))
        for _ in 0..<100 {
            if failures.reasons == [.capture], !adapter.isWakeMonitoring {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(failures.reasons == [.capture])
        #expect(!adapter.isWakeMonitoring)
    }

    @Test
    @MainActor
    func staleTapFailureCannotStopTheCurrentGeneration() async throws {
        let audio = InjectedWakeAudioEngine()
        let adapter = WakeWordAVAudioCaptureAdapter(
            ownership: MicrophoneOwnership(),
            permissionStatus: { .authorized },
            requestPermission: { .authorized },
            inputAvailable: { true },
            audioEngineBoundaryFactory: { audio.boundary }
        )
        let failures = WakeCaptureFailureProbe()
        adapter.setFailureHandler { failures.record($0) }

        _ = try await adapter.startWakeMonitoring()
        let oldTap = try #require(audio.installedTaps.first)
        audio.invokeAndWait(
            oldTap,
            with: try audio.makeBuffer(frameCount: 16_385)
        )

        await adapter.stopWakeMonitoring()
        _ = try await adapter.startWakeMonitoring()
        try await Task.sleep(for: .milliseconds(25))

        #expect(adapter.isWakeMonitoring)
        #expect(failures.reasons.isEmpty)

        let currentTap = try #require(audio.installedTaps.last)
        audio.invokeAndWait(
            currentTap,
            with: try audio.makeBuffer(frameCount: 16_385)
        )
        for _ in 0..<100 {
            if failures.reasons == [.capture], !adapter.isWakeMonitoring {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(failures.reasons == [.capture])
        #expect(!adapter.isWakeMonitoring)
    }

    @Test
    func lifecycleFenceRejectsInactiveAndStaleRealtimeBuffers() {
        let fence = WakeWordCaptureLifecycleFence()

        fence.prepare(generation: 1)
        #expect(!fence.accepts(generation: 1))
        fence.activate(generation: 1)
        #expect(fence.accepts(generation: 1))

        fence.prepare(generation: 2)
        #expect(!fence.accepts(generation: 1))
        #expect(!fence.accepts(generation: 2))
        fence.activate(generation: 2)
        #expect(fence.accepts(generation: 2))

        fence.invalidate()
        #expect(!fence.accepts(generation: 2))
    }

    @Test @MainActor
    func deniedPermissionDoesNotAcquireOrStartWakeCapture() async {
        let ownership = MicrophoneOwnership()
        let adapter = WakeWordAVAudioCaptureAdapter(
            ownership: ownership,
            permissionStatus: { .denied },
            requestPermission: { .denied }
        )

        await #expect(throws: WakeWordCaptureError.permissionDenied) {
            try await adapter.startWakeMonitoring()
        }
        #expect(adapter.isWakeMonitoring == false)
        let lease = try? ownership.acquire(.wake)
        #expect(lease != nil)
        lease?.release()
    }

    @MainActor
    private func waitForSampleCount(
        _ expectedCount: Int,
        in probe: WakeSampleDeliveryProbe
    ) async throws {
        for _ in 0..<100 {
            if probe.deliveries.count == expectedCount { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(expectedCount) sample deliveries")
    }

    @MainActor
    private func waitForMonitorWaiters(
        _ gate: WakeAvailabilityMonitorGate,
        atLeast expectedCount: Int
    ) async {
        for _ in 0..<100 {
            if gate.waitingCount >= expectedCount { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for monitor gate")
    }

    @MainActor
    private func waitForMonitoringState(
        _ expectedState: Bool,
        in adapter: WakeWordAVAudioCaptureAdapter
    ) async {
        for _ in 0..<100 {
            if adapter.isWakeMonitoring == expectedState { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for wake monitoring state")
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class InjectedWakeAudioEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var format: AVAudioFormat
    private var taps = [AVAudioNodeTapBlock]()
    private var tapFormats = [AVAudioFormat?]()
    private var stops = 0

    init(format: AVAudioFormat? = nil) {
        self.format = format ?? AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }

    var boundary: WakeWordAudioEngineBoundary {
        WakeWordAudioEngineBoundary(
            outputFormat: { [self] in lock.withLock { format } },
            installTap: { [self] _, format, tap in
                lock.withLock {
                    taps.append(tap)
                    tapFormats.append(format)
                }
            },
            removeTap: {},
            prepare: {},
            start: {},
            stop: { [self] in lock.withLock { stops += 1 } }
        )
    }

    var installedTaps: [AVAudioNodeTapBlock] {
        lock.withLock { taps }
    }

    var installedTapFormats: [AVAudioFormat?] {
        lock.withLock { tapFormats }
    }

    var outputSampleRate: Double {
        lock.withLock { format.sampleRate }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    func setOutputFormat(_ format: AVAudioFormat) {
        lock.withLock { self.format = format }
    }

    func makeBuffer(
        format: AVAudioFormat? = nil,
        frameCount: AVAudioFrameCount = 480
    ) throws -> AVAudioPCMBuffer {
        let format = format ?? lock.withLock { self.format }
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            buffer.int16ChannelData?[0][index] = Int16(truncatingIfNeeded: index)
        }
        return buffer
    }

    func invoke(
        _ tap: @escaping AVAudioNodeTapBlock,
        with buffer: AVAudioPCMBuffer
    ) {
        let invocation = UncheckedSendableBox((tap, buffer))
        DispatchQueue(label: "MillerWakeTests.installed-tap").async {
            invocation.value.0(invocation.value.1, AVAudioTime())
        }
    }

    func invokeAndOverwriteAfterTap(
        _ tap: @escaping AVAudioNodeTapBlock,
        buffer: AVAudioPCMBuffer,
        replacementSample: Int16
    ) {
        let invocation = UncheckedSendableBox((tap, buffer, replacementSample))
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue(label: "MillerWakeTests.snapshot-tap").async {
            invocation.value.0(invocation.value.1, AVAudioTime())
            for index in 0..<Int(invocation.value.1.frameLength) {
                invocation.value.1.int16ChannelData?[0][index] = invocation.value.2
            }
            completed.signal()
        }
        completed.wait()
    }

    func invokeAndWait(
        _ tap: @escaping AVAudioNodeTapBlock,
        with buffer: AVAudioPCMBuffer
    ) {
        let invocation = UncheckedSendableBox((tap, buffer))
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue(label: "MillerWakeTests.failure-tap").async {
            invocation.value.0(invocation.value.1, AVAudioTime())
            completed.signal()
        }
        completed.wait()
    }
}

private final class InjectedWakeAudioEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var format: AVAudioFormat
    private var engineReferences = [WeakInjectedWakeAudioEngine]()
    private var creations = 0

    init(format: AVAudioFormat) {
        self.format = format
    }

    var creationCount: Int {
        lock.withLock { creations }
    }

    var liveEngines: [InjectedWakeAudioEngine] {
        lock.withLock { engineReferences.compactMap(\.value) }
    }

    func setHardwareFormat(_ format: AVAudioFormat) {
        lock.withLock { self.format = format }
    }

    func makeBoundary() -> WakeWordAudioEngineBoundary {
        lock.withLock {
            let engine = InjectedWakeAudioEngine(format: format)
            creations += 1
            engineReferences.append(.init(engine))
            return engine.boundary
        }
    }
}

private final class WeakInjectedWakeAudioEngine {
    weak var value: InjectedWakeAudioEngine?

    init(_ value: InjectedWakeAudioEngine) {
        self.value = value
    }
}

private final class WakeCaptureFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [WakeWordUnavailableReason]()

    var reasons: [WakeWordUnavailableReason] {
        lock.withLock { storage }
    }

    func record(_ reason: WakeWordUnavailableReason) {
        lock.withLock { storage.append(reason) }
    }
}

private final class WakeInputAvailabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    var isAvailable: Bool {
        lock.withLock { available }
    }

    func setAvailable(_ available: Bool) {
        lock.withLock { self.available = available }
    }
}

private final class WakeAvailabilityMonitorGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations = [CheckedContinuation<Void, Never>]()

    var waitingCount: Int {
        lock.withLock { continuations.count }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }

    func signal() {
        let continuation = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        continuation?.resume()
    }
}

private final class WakeSampleDeliveryProbe: @unchecked Sendable {
    struct Delivery: Equatable {
        let sampleCount: Int
        let firstSample: Int16?
        let deliveredOnMainThread: Bool
    }

    private let lock = NSLock()
    private var storage = [Delivery]()

    var deliveries: [Delivery] {
        lock.withLock { storage }
    }

    func record(
        _ samples: ContiguousArray<Int16>,
        deliveredOnMainThread: Bool
    ) {
        lock.withLock {
            storage.append(.init(
                sampleCount: samples.count,
                firstSample: samples.first,
                deliveredOnMainThread: deliveredOnMainThread
            ))
        }
    }
}

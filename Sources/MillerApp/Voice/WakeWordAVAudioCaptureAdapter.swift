import AVFoundation
import Foundation
import MillerLiveAudio
import MillerWake

typealias WakeWordCaptureError = WakeWordCaptureStartError

enum WakeWordRealtimeHandoff {
    nonisolated static func deliver<Value: Sendable>(
        _ value: Value,
        to operation: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        DispatchQueue.main.async { operation(value) }
    }
}

struct WakeWordAudioBufferSnapshot: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    nonisolated init?(
        copying source: AVAudioPCMBuffer,
        maximumFrameCount: AVAudioFrameCount
    ) {
        guard source.frameLength <= maximumFrameCount else { return nil }
        self.init(
            copying: source,
            frameOffset: 0,
            frameCount: source.frameLength
        )
    }

    nonisolated init?(
        copying source: AVAudioPCMBuffer,
        frameOffset: AVAudioFrameCount,
        frameCount: AVAudioFrameCount
    ) {
        guard frameCount > 0,
              frameOffset <= source.frameLength,
              frameCount <= source.frameLength - frameOffset,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: frameCount
              )
        else { return nil }

        buffer.frameLength = frameCount
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let sourceByteCount = Int(sourceBuffer.mDataByteSize)
            guard source.frameLength > 0,
                  sourceByteCount % Int(source.frameLength) == 0
            else { return nil }
            let bytesPerFrame = sourceByteCount / Int(source.frameLength)
            let sourceOffset = Int(frameOffset) * bytesPerFrame
            let byteCount = Int(frameCount) * bytesPerFrame
            guard byteCount <= Int(destinationBuffers[index].mDataByteSize),
                  let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData
            else { return nil }
            destinationData.copyMemory(
                from: sourceData.advanced(by: sourceOffset),
                byteCount: byteCount
            )
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        self.buffer = buffer
    }
}

enum WakeWordRealtimeAudioTap {
    nonisolated static func make(
        chunkFrameCount: AVAudioFrameCount = 1_024,
        maximumBufferFrameCount: AVAudioFrameCount = 16_384,
        maximumBufferByteCount: Int = 1_048_576,
        shouldCapture: @escaping @Sendable () -> Bool = { true },
        onFailure: @escaping @MainActor @Sendable () -> Void = {},
        receive: @escaping @MainActor @Sendable (
            WakeWordAudioBufferSnapshot
        ) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard shouldCapture() else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(
                buffer.mutableAudioBufferList
            )
            let totalByteCount = buffers.reduce(0) {
                $0 + Int($1.mDataByteSize)
            }
            guard chunkFrameCount > 0,
                  maximumBufferFrameCount >= chunkFrameCount,
                  buffer.frameLength > 0,
                  buffer.frameLength <= maximumBufferFrameCount,
                  totalByteCount <= maximumBufferByteCount
            else {
                WakeWordRealtimeHandoff.deliver((), to: { _ in onFailure() })
                return
            }

            var snapshots = [WakeWordAudioBufferSnapshot]()
            var offset: AVAudioFrameCount = 0
            while offset < buffer.frameLength {
                let frameCount = min(
                    chunkFrameCount,
                    buffer.frameLength - offset
                )
                guard let snapshot = WakeWordAudioBufferSnapshot(
                    copying: buffer,
                    frameOffset: offset,
                    frameCount: frameCount
                ) else {
                    WakeWordRealtimeHandoff.deliver((), to: { _ in onFailure() })
                    return
                }
                snapshots.append(snapshot)
                offset += frameCount
            }
            for snapshot in snapshots {
                guard shouldCapture() else { return }
                WakeWordRealtimeHandoff.deliver(snapshot, to: receive)
            }
        }
    }
}

final class WakeWordCaptureLifecycleFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false

    func prepare(generation: UInt64) {
        lock.withLock {
            self.generation = generation
            active = false
        }
    }

    func activate(generation: UInt64) {
        lock.withLock {
            guard self.generation == generation else { return }
            active = true
        }
    }

    func invalidate() {
        lock.withLock { active = false }
    }

    func accepts(generation: UInt64) -> Bool {
        lock.withLock { active && self.generation == generation }
    }
}

struct WakeWordAudioEngineBoundary: @unchecked Sendable {
    typealias InstallTap = (
        AVAudioFrameCount,
        AVAudioFormat?,
        @escaping AVAudioNodeTapBlock
    ) -> Void

    let outputFormat: () -> AVAudioFormat
    let installTap: InstallTap
    let removeTap: () -> Void
    let prepare: () -> Void
    let start: () throws -> Void
    let isRunning: () -> Bool
    let stop: () -> Void

    static func live(engine: AVAudioEngine) -> Self {
        Self(
            outputFormat: {
                engine.inputNode.outputFormat(forBus: 0)
            },
            installTap: { bufferSize, format, tap in
                engine.inputNode.installTap(
                    onBus: 0,
                    bufferSize: bufferSize,
                    format: format,
                    block: tap
                )
            },
            removeTap: {
                engine.inputNode.removeTap(onBus: 0)
            },
            prepare: {
                engine.prepare()
            },
            start: {
                try engine.start()
            },
            isRunning: {
                engine.isRunning
            },
            stop: {
                engine.stop()
            }
        )
    }
}

typealias WakeWordAudioEngineBoundaryFactory =
    @Sendable () -> WakeWordAudioEngineBoundary

@MainActor
final class WakeWordAVAudioCaptureAdapter: WakeWordCaptureOwning {
    private static let inputAvailabilityFailureLimit = 3

    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false

    private let ownership: MicrophoneOwnership
    private let permissionStatus: @Sendable () -> MicrophonePermission
    private let requestPermission: @Sendable () async -> MicrophonePermission
    private let inputAvailable: (@Sendable () -> Bool)?
    private let audioQueue: DispatchQueue
    private let audioEngineBoundaryFactory: WakeWordAudioEngineBoundaryFactory
    private let waitForAvailabilityCheck: @Sendable () async -> Void
    private let lifecycleFence = WakeWordCaptureLifecycleFence()
    private let chunker = WakeWordPCM16Chunker()
    private var generation: UInt64 = 0
    private var lease: MicrophoneOwnership.Lease?
    private var audioEngineBoundary: WakeWordAudioEngineBoundary?
    private var converter: AVAudioConverter?
    private var invalidationTask: Task<Void, Never>?
    private var failureHandler:
        (@Sendable (WakeWordUnavailableReason) -> Void)?

    init(
        ownership: MicrophoneOwnership,
        permissionStatus: @escaping @Sendable () -> MicrophonePermission = {
            SystemMicrophonePermission.current()
        },
        requestPermission: @escaping @Sendable () async -> MicrophonePermission = {
            await SystemMicrophonePermission.request()
        },
        inputAvailable: (@Sendable () -> Bool)? = nil,
        audioEngineBoundaryFactory: @escaping WakeWordAudioEngineBoundaryFactory = {
            WakeWordAudioEngineBoundary.live(engine: AVAudioEngine())
        },
        waitForAvailabilityCheck: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(250))
        }
    ) {
        self.ownership = ownership
        self.permissionStatus = permissionStatus
        self.requestPermission = requestPermission
        self.inputAvailable = inputAvailable
        self.audioEngineBoundaryFactory = audioEngineBoundaryFactory
        self.waitForAvailabilityCheck = waitForAvailabilityCheck
        audioQueue = DispatchQueue(label: "MillerWake.capture")
    }

    func setFailureHandler(
        _ handler: @escaping @Sendable (WakeWordUnavailableReason) -> Void
    ) {
        failureHandler = handler
    }

    func startWakeMonitoring() async throws -> UUID {
        guard !isWakeMonitoring else { return UUID() }
        var permission = permissionStatus()
        if permission == .notDetermined {
            permission = await requestPermission()
        }
        guard permission == .authorized else {
            throw WakeWordCaptureStartError.permissionDenied
        }
        if let inputAvailable, !inputAvailable() {
            throw WakeWordCaptureStartError.inputDeviceUnavailable
        }
        let lease: MicrophoneOwnership.Lease
        do {
            lease = try ownership.acquire(.wake)
        } catch {
            throw WakeWordCaptureStartError.microphoneBusy
        }

        generation &+= 1
        let generation = self.generation
        let callback = onSamples
        let lifecycleFence = self.lifecycleFence
        lifecycleFence.prepare(generation: generation)
        do {
            audioEngineBoundary = try makeStartedAudioEngine(
                generation: generation,
                callback: callback
            )
        } catch {
            lifecycleFence.invalidate()
            lease.release()
            throw (error as? WakeWordCaptureStartError)
                ?? WakeWordCaptureStartError.captureFailed
        }

        self.lease = lease
        isWakeMonitoring = true
        lifecycleFence.activate(generation: generation)
        invalidationTask?.cancel()
        let waitForAvailabilityCheck = self.waitForAvailabilityCheck
        invalidationTask = Task { @MainActor [weak self] in
            var inputUnavailableChecks = 0
            while !Task.isCancelled {
                await waitForAvailabilityCheck()
                guard let self,
                      self.isWakeMonitoring,
                      self.generation == generation
                else { return }
                if self.permissionStatus() != .authorized {
                    self.report(.microphonePermission, generation: generation)
                    return
                }
                let inputStillAvailable = self.inputAvailable?()
                    ?? self.inputIsAvailable()
                if inputStillAvailable {
                    inputUnavailableChecks = 0
                    if !self.audioEngineIsRunning() {
                        do {
                            try self.restartAudioEngine(
                                generation: generation,
                                callback: callback
                            )
                        } catch {
                            self.report(.capture, generation: generation)
                            return
                        }
                    }
                    continue
                }
                inputUnavailableChecks += 1
                if inputUnavailableChecks >= Self.inputAvailabilityFailureLimit {
                    self.report(.inputDevice, generation: generation)
                    return
                }
            }
        }
        return UUID()
    }

    private func makeStartedAudioEngine(
        generation: UInt64,
        callback: (@Sendable (ContiguousArray<Int16>) -> Void)?
    ) throws -> WakeWordAudioEngineBoundary {
        let boundary = audioEngineBoundaryFactory()
        let lifecycleFence = self.lifecycleFence
        do {
            try audioQueue.sync {
                let inputFormat = boundary.outputFormat()
                guard inputFormat.sampleRate > 0,
                      let target = AVAudioFormat(
                        commonFormat: .pcmFormatInt16,
                        sampleRate: 16_000,
                        channels: 1,
                        interleaved: true
                      )
                else { throw WakeWordCaptureStartError.inputDeviceUnavailable }

                boundary.removeTap()
                let tap = WakeWordRealtimeAudioTap.make(
                    chunkFrameCount: 1_024,
                    shouldCapture: {
                        lifecycleFence.accepts(generation: generation)
                    },
                    onFailure: { [weak self] in
                        self?.report(.capture, generation: generation)
                    }
                ) { [weak self] snapshot in
                    self?.process(
                        snapshot,
                        generation: generation,
                        callback: callback,
                        target: target
                    )
                }
                boundary.installTap(1_024, nil, tap)
                boundary.prepare()
                try boundary.start()
                converter = nil
            }
            return boundary
        } catch {
            audioQueue.sync {
                boundary.removeTap()
                boundary.stop()
            }
            throw error
        }
    }

    private func restartAudioEngine(
        generation: UInt64,
        callback: (@Sendable (ContiguousArray<Int16>) -> Void)?
    ) throws {
        guard lifecycleFence.accepts(generation: generation),
              isWakeMonitoring,
              let previous = audioEngineBoundary else {
            return
        }
        audioEngineBoundary = nil
        audioQueue.sync {
            previous.removeTap()
            previous.stop()
            converter = nil
        }
        guard lifecycleFence.accepts(generation: generation),
              isWakeMonitoring else {
            return
        }
        audioEngineBoundary = try makeStartedAudioEngine(
            generation: generation,
            callback: callback
        )
    }

    func stopWakeMonitoring() async {
        stopWakeMonitoringImmediately()
    }

    private func stopWakeMonitoringImmediately() {
        generation &+= 1
        lifecycleFence.invalidate()
        isWakeMonitoring = false
        invalidationTask?.cancel()
        invalidationTask = nil
        let audioEngineBoundary = self.audioEngineBoundary
        self.audioEngineBoundary = nil
        audioQueue.sync {
            audioEngineBoundary?.removeTap()
            audioEngineBoundary?.stop()
            converter = nil
        }
        chunker.reset()
        let lease = self.lease
        self.lease = nil
        lease?.release()
    }

    private func process(
        _ snapshot: WakeWordAudioBufferSnapshot,
        generation: UInt64,
        callback: (@Sendable (ContiguousArray<Int16>) -> Void)?,
        target: AVAudioFormat
    ) {
        guard lifecycleFence.accepts(generation: generation) else { return }
        do {
            let converter: AVAudioConverter
            if let current = self.converter,
               current.inputFormat == snapshot.buffer.format {
                converter = current
            } else {
                guard let current = AVAudioConverter(
                    from: snapshot.buffer.format,
                    to: target
                ) else { throw WakeWordCaptureStartError.captureFailed }
                self.converter = current
                converter = current
            }
            let converted = try Self.convert(
                snapshot.buffer,
                using: converter,
                to: target
            )
            for frame in chunker.append(converted) {
                guard lifecycleFence.accepts(generation: generation) else {
                    return
                }
                callback?(frame)
            }
        } catch {
            report(.capture, generation: generation)
        }
    }

    private func report(
        _ reason: WakeWordUnavailableReason,
        generation: UInt64? = nil
    ) {
        if let generation {
            guard lifecycleFence.accepts(generation: generation) else { return }
        }
        guard isWakeMonitoring else { return }
        failureHandler?(reason)
        stopWakeMonitoringImmediately()
    }

    private func inputIsAvailable() -> Bool {
        guard let audioEngineBoundary else { return false }
        return audioQueue.sync {
            audioEngineBoundary.outputFormat().sampleRate > 0
        }
    }

    private func audioEngineIsRunning() -> Bool {
        guard let audioEngineBoundary else { return false }
        return audioQueue.sync { audioEngineBoundary.isRunning() }
    }

    private static func convert(
        _ source: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) throws -> ContiguousArray<Int16> {
        let capacity = AVAudioFrameCount(
            ceil(
                Double(source.frameLength) * format.sampleRate
                    / source.format.sampleRate
            )
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: max(capacity, 1)
        ) else { throw WakeWordCaptureStartError.captureFailed }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard !supplied else {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard conversionError == nil, status != .error,
              let samples = output.int16ChannelData?[0]
        else { throw WakeWordCaptureStartError.captureFailed }
        return ContiguousArray(
            UnsafeBufferPointer(
                start: samples,
                count: Int(output.frameLength)
            )
        )
    }
}

private final class WakeWordPCM16Chunker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ContiguousArray<Int16>()

    func append(_ samples: ContiguousArray<Int16>) -> [ContiguousArray<Int16>] {
        lock.withLock {
            pending.append(contentsOf: samples)
            var result = [ContiguousArray<Int16>]()
            while pending.count >= 480 {
                result.append(ContiguousArray(pending.prefix(480)))
                pending.removeFirst(480)
            }
            return result
        }
    }

    func reset() {
        lock.withLock { pending.removeAll(keepingCapacity: false) }
    }
}

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
        AVAudioFormat,
        @escaping AVAudioNodeTapBlock
    ) -> Void

    let outputFormat: () -> AVAudioFormat
    let installTap: InstallTap
    let removeTap: () -> Void
    let prepare: () -> Void
    let start: () throws -> Void
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
            stop: {
                engine.stop()
            }
        )
    }
}

@MainActor
final class WakeWordAVAudioCaptureAdapter: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false

    private let ownership: MicrophoneOwnership
    private let permissionStatus: @Sendable () -> MicrophonePermission
    private let requestPermission: @Sendable () async -> MicrophonePermission
    private let inputAvailable: (@Sendable () -> Bool)?
    private let audioQueue: DispatchQueue
    private let audioEngineBoundary: WakeWordAudioEngineBoundary
    private let lifecycleFence = WakeWordCaptureLifecycleFence()
    private let chunker = WakeWordPCM16Chunker()
    private var generation: UInt64 = 0
    private var lease: MicrophoneOwnership.Lease?
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
        engine: AVAudioEngine = AVAudioEngine(),
        audioEngineBoundary: WakeWordAudioEngineBoundary? = nil
    ) {
        self.ownership = ownership
        self.permissionStatus = permissionStatus
        self.requestPermission = requestPermission
        self.inputAvailable = inputAvailable
        self.audioEngineBoundary = audioEngineBoundary
            ?? WakeWordAudioEngineBoundary.live(engine: engine)
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
        guard inputAvailable?() ?? inputIsAvailable() else {
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
            try audioQueue.sync {
                let inputFormat = audioEngineBoundary.outputFormat()
                guard inputFormat.sampleRate > 0,
                      let target = AVAudioFormat(
                        commonFormat: .pcmFormatInt16,
                        sampleRate: 16_000,
                        channels: 1,
                        interleaved: true
                      ),
                      let converter = AVAudioConverter(
                        from: inputFormat,
                        to: target
                      )
                else { throw WakeWordCaptureStartError.inputDeviceUnavailable }

                audioEngineBoundary.removeTap()
                let tap = WakeWordRealtimeAudioTap.make(
                    chunkFrameCount: 1_024,
                    shouldCapture: {
                        lifecycleFence.accepts(generation: generation)
                    },
                    onFailure: { [weak self] in
                        Task { @MainActor [weak self] in
                            await self?.report(.capture)
                        }
                    }
                ) { [weak self] snapshot in
                    self?.process(
                        snapshot,
                        generation: generation,
                        callback: callback,
                        converter: converter,
                        target: target
                    )
                }
                audioEngineBoundary.installTap(1_024, inputFormat, tap)
                audioEngineBoundary.prepare()
                do {
                    try audioEngineBoundary.start()
                } catch {
                    audioEngineBoundary.removeTap()
                    throw WakeWordCaptureStartError.captureFailed
                }
                self.converter = converter
            }
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
        invalidationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isWakeMonitoring else { return }
                if self.permissionStatus() != .authorized {
                    await self.report(.microphonePermission)
                    return
                }
                let inputStillAvailable = self.inputAvailable?()
                    ?? self.inputIsAvailable()
                if !inputStillAvailable {
                    await self.report(.inputDevice)
                    return
                }
            }
        }
        return UUID()
    }

    func stopWakeMonitoring() async {
        generation &+= 1
        lifecycleFence.invalidate()
        isWakeMonitoring = false
        invalidationTask?.cancel()
        invalidationTask = nil
        audioQueue.sync {
            audioEngineBoundary.removeTap()
            audioEngineBoundary.stop()
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
        converter: AVAudioConverter,
        target: AVAudioFormat
    ) {
        guard lifecycleFence.accepts(generation: generation) else { return }
        do {
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
            Task { @MainActor [weak self] in
                await self?.report(.capture)
            }
        }
    }

    private func report(_ reason: WakeWordUnavailableReason) async {
        guard isWakeMonitoring else { return }
        failureHandler?(reason)
        await stopWakeMonitoring()
    }

    private func inputIsAvailable() -> Bool {
        audioQueue.sync {
            audioEngineBoundary.outputFormat().sampleRate > 0
        }
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

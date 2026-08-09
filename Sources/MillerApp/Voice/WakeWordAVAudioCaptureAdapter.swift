import AVFoundation
import Foundation
import MillerLiveAudio
import MillerWake

typealias WakeWordCaptureError = WakeWordCaptureStartError

@MainActor
final class WakeWordAVAudioCaptureAdapter: WakeWordCaptureOwning {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)?
    private(set) var isWakeMonitoring = false

    private let ownership: MicrophoneOwnership
    private let permissionStatus: @Sendable () -> MicrophonePermission
    private let requestPermission: @Sendable () async -> MicrophonePermission
    private let inputAvailable: (@Sendable () -> Bool)?
    private let audioQueue: DispatchQueue
    private let engine: AVAudioEngine
    private let stateLock = NSLock()
    private let chunker = WakeWordPCM16Chunker()
    private var generation: UInt64 = 0
    private var physicalRunning = false
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
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.ownership = ownership
        self.permissionStatus = permissionStatus
        self.requestPermission = requestPermission
        self.inputAvailable = inputAvailable
        self.engine = engine
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
        do {
            try audioQueue.sync {
                let input = engine.inputNode
                let inputFormat = input.outputFormat(forBus: 0)
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

                input.removeTap(onBus: 0)
                input.installTap(
                    onBus: 0,
                    bufferSize: 1_024,
                    format: inputFormat
                ) { [weak self] buffer, _ in
                    guard let self,
                          self.stateLock.withLock({
                              self.physicalRunning && self.generation == generation
                          })
                    else { return }
                    do {
                        let converted = try Self.convert(
                            buffer,
                            using: converter,
                            to: target
                        )
                        for frame in self.chunker.append(converted) {
                            guard self.stateLock.withLock({
                                self.physicalRunning && self.generation == generation
                            }) else { return }
                            callback?(frame)
                        }
                    } catch {
                        Task { @MainActor [weak self] in
                            await self?.report(.capture)
                        }
                    }
                }
                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    input.removeTap(onBus: 0)
                    throw WakeWordCaptureStartError.captureFailed
                }
                self.converter = converter
            }
        } catch {
            lease.release()
            throw (error as? WakeWordCaptureStartError)
                ?? WakeWordCaptureStartError.captureFailed
        }

        self.lease = lease
        stateLock.withLock { physicalRunning = true }
        isWakeMonitoring = true
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
        stateLock.withLock { physicalRunning = false }
        isWakeMonitoring = false
        invalidationTask?.cancel()
        invalidationTask = nil
        audioQueue.sync {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            converter = nil
        }
        chunker.reset()
        let lease = self.lease
        self.lease = nil
        lease?.release()
    }

    private func report(_ reason: WakeWordUnavailableReason) async {
        guard isWakeMonitoring else { return }
        failureHandler?(reason)
        await stopWakeMonitoring()
    }

    private func inputIsAvailable() -> Bool {
        audioQueue.sync {
            engine.inputNode.outputFormat(forBus: 0).sampleRate > 0
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

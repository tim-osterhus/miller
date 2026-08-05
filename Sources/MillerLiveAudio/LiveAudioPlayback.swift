import AVFoundation
import Foundation
import MillerLive

public protocol LiveAudioPlaybackDriving: Sendable {
    func play(_ frame: LiveAudioFrame) async throws
    func interrupt() async
    func invalidations() async -> AsyncStream<LiveAudioError>
}

public extension LiveAudioPlaybackDriving {
    func invalidations() async -> AsyncStream<LiveAudioError> {
        AsyncStream { $0.finish() }
    }
}

public actor LiveAudioPlayback {
    private struct PhysicalInterrupt {
        let generation: UInt64
        let token: UInt64
        let task: Task<Void, Never>
    }

    private let driver: any LiveAudioPlaybackDriving
    private let maximumQueuedDuration: Duration
    private var queue: [LiveAudioFrame] = []
    private var playingDuration: Duration = .zero
    private var drain: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var physicalInterrupt: PhysicalInterrupt?
    private var nextPhysicalInterruptToken: UInt64 = 0
    private var interruptionPending = true
    private var failureClaimGate: LiveAudioFailureClaimGate?
    private var receiveFailure: (@Sendable (LiveAudioError) async -> Void)?
    private var failureReported = false
    private var generation: UInt64 = 0

    public init(
        driver: any LiveAudioPlaybackDriving = AVFoundationPlaybackDriver(),
        maximumQueuedDuration: Duration = .seconds(2)
    ) {
        self.driver = driver
        self.maximumQueuedDuration = maximumQueuedDuration
    }

    public var queuedDuration: Duration {
        queue.reduce(playingDuration) { $0 + $1.duration }
    }

    public func start(
        claimFailure: @escaping @Sendable (LiveAudioError) -> Bool = { _ in true },
        receiveFailure: @escaping @Sendable (LiveAudioError) async -> Void
    ) {
        generation &+= 1
        let generation = self.generation
        failureClaimGate?.deactivate()
        let failureClaimGate = LiveAudioFailureClaimGate(claimFailure: claimFailure)
        self.failureClaimGate = failureClaimGate
        self.receiveFailure = receiveFailure
        failureReported = false
        interruptionPending = true
        monitor?.cancel()
        monitor = Task { [weak self, driver, failureClaimGate] in
            for await failure in await driver.invalidations() {
                let sanitized = failure == .microphoneUnavailable
                    ? failure : .playbackFailed
                let claimed = failureClaimGate.claim(sanitized)
                await self?.reportFailure(
                    sanitized,
                    generation: generation,
                    notify: claimed
                )
            }
        }
    }

    public func enqueue(_ frame: LiveAudioFrame) throws {
        try Self.validate(frame)
        guard !failureReported else { throw LiveAudioError.playbackFailed }
        guard queuedDuration + frame.duration <= maximumQueuedDuration else {
            _ = failureClaimGate?.claim(.audioBackpressure)
            throw LiveAudioError.audioBackpressure
        }
        interruptionPending = true
        queue.append(frame)
        if drain == nil {
            let generation = self.generation
            drain = Task { [weak self] in
                await self?.drainQueue(generation: generation)
            }
        }
    }

    public func interrupt() async {
        guard interruptionPending || physicalInterrupt != nil else { return }
        if interruptionPending {
            generation &+= 1
            interruptionPending = false
            failureClaimGate?.deactivate()
            drain?.cancel()
            drain = nil
            monitor?.cancel()
            monitor = nil
            queue.removeAll(keepingCapacity: false)
            playingDuration = .zero
            receiveFailure = nil
        }
        let interruption = beginPhysicalInterrupt(generation: generation)
        await interruption.task.value
        guard generation == interruption.generation else { return }
        clearPhysicalInterrupt(interruption)
    }

    private func drainQueue(generation: UInt64) async {
        while !Task.isCancelled, self.generation == generation, !queue.isEmpty {
            let frame = queue.removeFirst()
            playingDuration = frame.duration
            do { try await driver.play(frame) }
            catch {
                guard self.generation == generation else { return }
                let claimed = failureClaimGate?.claim(.playbackFailed) ?? true
                await reportFailure(
                    .playbackFailed,
                    generation: generation,
                    notify: claimed
                )
                return
            }
            guard self.generation == generation else { return }
            playingDuration = .zero
        }
        guard self.generation == generation else { return }
        playingDuration = .zero
        drain = nil
    }

    private func reportFailure(
        _ failure: LiveAudioError,
        generation: UInt64,
        notify: Bool
    ) async {
        guard self.generation == generation, !failureReported else { return }
        failureClaimGate?.deactivate()
        self.generation &+= 1
        failureReported = true
        interruptionPending = false
        drain?.cancel()
        drain = nil
        monitor?.cancel()
        monitor = nil
        queue.removeAll(keepingCapacity: false)
        playingDuration = .zero
        let receiveFailure = self.receiveFailure
        let interruptionGeneration = self.generation
        let interruption = beginPhysicalInterrupt(generation: interruptionGeneration)
        if notify { await receiveFailure?(failure) }
        guard self.generation == interruptionGeneration else { return }
        await interruption.task.value
        guard self.generation == interruptionGeneration else { return }
        clearPhysicalInterrupt(interruption)
    }

    private func beginPhysicalInterrupt(generation: UInt64) -> PhysicalInterrupt {
        if let physicalInterrupt, physicalInterrupt.generation == generation {
            return physicalInterrupt
        }
        nextPhysicalInterruptToken &+= 1
        let interruption = PhysicalInterrupt(
            generation: generation,
            token: nextPhysicalInterruptToken,
            task: Task { [driver] in await driver.interrupt() }
        )
        physicalInterrupt = interruption
        return interruption
    }

    private func clearPhysicalInterrupt(_ interruption: PhysicalInterrupt) {
        guard physicalInterrupt?.generation == interruption.generation,
              physicalInterrupt?.token == interruption.token else { return }
        physicalInterrupt = nil
    }

    private static func validate(_ frame: LiveAudioFrame) throws {
        guard frame.sampleRate == 24_000, frame.numChannels == 1,
              frame.data.count.isMultiple(of: MemoryLayout<Int16>.size),
              frame.samplesPerChannel == nil
                || frame.samplesPerChannel == frame.data.count / MemoryLayout<Int16>.size
        else { throw LiveAudioError.invalidFrame }
    }
}

public final class AVFoundationPlaybackDriver: LiveAudioPlaybackDriving, @unchecked Sendable {
    private let audioQueue: DispatchQueue
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private var started = false
    private let outputAvailable: (@Sendable () -> Bool)?
    private let monitoringInterval: Duration

    public convenience init() {
        self.init(
            outputAvailable: nil,
            monitoringInterval: .milliseconds(250)
        )
    }

    init(
        outputAvailable: (@Sendable () -> Bool)?,
        monitoringInterval: Duration
    ) {
        let audioQueue = DispatchQueue(label: "MillerLiveAudio.playback")
        let audioObjects = audioQueue.sync {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            return (engine, player)
        }
        self.audioQueue = audioQueue
        self.engine = audioObjects.0
        self.player = audioObjects.1
        self.outputAvailable = outputAvailable
        self.monitoringInterval = monitoringInterval
    }

    public func play(_ frame: LiveAudioFrame) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async { [self] in
                do {
                    guard let sourceFormat = AVAudioFormat(
                        commonFormat: .pcmFormatInt16,
                        sampleRate: Double(frame.sampleRate),
                        channels: AVAudioChannelCount(frame.numChannels),
                        interleaved: true
                    ), let source = AVAudioPCMBuffer(
                        pcmFormat: sourceFormat,
                        frameCapacity: AVAudioFrameCount(frame.data.count / 2)
                    ) else { throw LiveAudioError.invalidFrame }
                    source.frameLength = source.frameCapacity
                    let copied = frame.data.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress,
                              let destination = source.mutableAudioBufferList.pointee
                                .mBuffers.mData else { return false }
                        memcpy(destination, base, frame.data.count)
                        return true
                    }
                    guard copied else { throw LiveAudioError.invalidFrame }

                    let outputFormat = engine.outputNode.outputFormat(forBus: 0)
                    guard outputFormat.sampleRate > 0,
                          let converter = AVAudioConverter(
                            from: sourceFormat,
                            to: outputFormat
                          )
                    else { throw LiveAudioError.playbackFailed }
                    let capacity = AVAudioFrameCount(
                        ceil(
                            Double(source.frameLength) * outputFormat.sampleRate
                                / sourceFormat.sampleRate
                        )
                    )
                    guard let output = AVAudioPCMBuffer(
                        pcmFormat: outputFormat,
                        frameCapacity: capacity
                    ) else { throw LiveAudioError.playbackFailed }
                    var supplied = false
                    var conversionError: NSError?
                    let status = converter.convert(
                        to: output,
                        error: &conversionError
                    ) { _, state in
                        guard !supplied else {
                            state.pointee = .noDataNow
                            return nil
                        }
                        supplied = true
                        state.pointee = .haveData
                        return source
                    }
                    guard status != .error, conversionError == nil else {
                        throw LiveAudioError.playbackFailed
                    }
                    if !started {
                        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
                        try engine.start()
                        player.play()
                        started = true
                    }
                    player.scheduleBuffer(
                        output,
                        completionCallbackType: .dataPlayedBack
                    ) { _ in continuation.resume() }
                } catch let failure as LiveAudioError {
                    continuation.resume(throwing: failure)
                } catch {
                    continuation.resume(throwing: LiveAudioError.playbackFailed)
                }
            }
        }
    }

    public func interrupt() async {
        audioQueue.sync {
            player.stop()
            engine.stop()
            started = false
        }
    }

    public func invalidations() async -> AsyncStream<LiveAudioError> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled, let self {
                    let available = audioQueue.sync {
                        outputAvailable?()
                            ?? (engine.outputNode.outputFormat(forBus: 0).sampleRate > 0)
                    }
                    if !available {
                        continuation.yield(.microphoneUnavailable)
                        break
                    }
                    try? await Task.sleep(for: monitoringInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

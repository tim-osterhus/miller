import AVFoundation
import Foundation
import MillerLive

public enum MicrophonePermission: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    public var mayRequestCapture: Bool { self == .authorized }
}

public enum LiveAudioError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case permissionDenied
    case captureFailed
    case playbackFailed
    case invalidFrame
    case audioBackpressure
}

public struct PCM16InputChunker: Sendable {
    public static let sampleRate = 24_000
    public static let channels = 1
    public static let samplesPerChunk = 2_400
    public static let bytesPerChunk = samplesPerChunk * MemoryLayout<Int16>.size

    private var pending = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [LiveAudioFrame] {
        guard bytes.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw LiveAudioError.invalidFrame
        }
        pending.append(bytes)
        var result: [LiveAudioFrame] = []
        while pending.count >= Self.bytesPerChunk {
            let chunk = Data(pending.prefix(Self.bytesPerChunk))
            pending.removeFirst(Self.bytesPerChunk)
            result.append(try LiveAudioFrame(
                data: chunk,
                sampleRate: Self.sampleRate,
                numChannels: Self.channels,
                samplesPerChannel: Self.samplesPerChunk,
                itemID: nil
            ))
        }
        return result
    }

    public mutating func reset() { pending.removeAll(keepingCapacity: false) }
}

public protocol LiveAudioCaptureDriving: Sendable {
    func start(
        _ receive: @escaping @Sendable (Result<Data, Error>) -> Void
    ) async throws
    func stop() async
    func invalidations() async -> AsyncStream<LiveAudioError>
}

public extension LiveAudioCaptureDriving {
    func invalidations() async -> AsyncStream<LiveAudioError> {
        AsyncStream { $0.finish() }
    }
}

public actor LiveAudioCapture {
    private let driver: any LiveAudioCaptureDriving
    private var chunker = PCM16InputChunker()
    private var muted = false
    private var running = false
    private var failureReported = false
    private var monitor: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failureClaimGate: LiveAudioFailureClaimGate?

    public init(driver: any LiveAudioCaptureDriving = AVFoundationCaptureDriver()) {
        self.driver = driver
    }

    public func start(
        permission: MicrophonePermission,
        claimFailure: @escaping @Sendable (LiveAudioError) -> Bool = { _ in true },
        receive: @escaping @Sendable (Result<LiveAudioFrame, Error>) -> Void
    ) async throws {
        guard permission == .authorized else {
            _ = claimFailure(.permissionDenied)
            throw LiveAudioError.permissionDenied
        }
        guard !running else { return }
        generation &+= 1
        let generation = self.generation
        failureClaimGate?.deactivate()
        let failureClaimGate = LiveAudioFailureClaimGate(claimFailure: claimFailure)
        self.failureClaimGate = failureClaimGate
        running = true
        failureReported = false
        do {
            try await driver.start { [weak self] result in
                let claimedFailure: Bool?
                if case let .failure(error) = result {
                    claimedFailure = failureClaimGate.claim(Self.sanitize(error))
                } else {
                    claimedFailure = nil
                }
                Task {
                    await self?.consume(
                        result,
                        claimedFailure: claimedFailure,
                        failureClaimGate: failureClaimGate,
                        generation: generation,
                        receive: receive
                    )
                }
            }
            guard self.generation == generation, running else { return }
            monitor = Task { [weak self, driver, failureClaimGate] in
                for await failure in await driver.invalidations() {
                    let sanitized = Self.sanitize(failure)
                    let claimed = failureClaimGate.claim(sanitized)
                    await self?.consumeInvalidation(
                        sanitized,
                        claimed: claimed,
                        generation: generation,
                        receive: receive
                    )
                }
            }
        } catch {
            if self.generation == generation { running = false }
            let failure = Self.sanitize(error)
            _ = failureClaimGate.claim(failure)
            failureClaimGate.deactivate()
            throw failure
        }
    }

    public func setMuted(_ muted: Bool) { self.muted = muted }

    public func stop() async {
        let wasRunning = running
        generation &+= 1
        failureClaimGate?.deactivate()
        running = false
        muted = false
        chunker.reset()
        monitor?.cancel()
        monitor = nil
        guard wasRunning else { return }
        await driver.stop()
    }

    private func consume(
        _ result: Result<Data, Error>,
        claimedFailure: Bool?,
        failureClaimGate: LiveAudioFailureClaimGate,
        generation: UInt64,
        receive: @escaping @Sendable (Result<LiveAudioFrame, Error>) -> Void
    ) {
        guard running, self.generation == generation else { return }
        switch result {
        case let .success(bytes):
            guard !muted else { return }
            do {
                for frame in try chunker.append(bytes) { receive(.success(frame)) }
            } catch {
                guard failureClaimGate.claim(.invalidFrame) else {
                    failureReported = true
                    return
                }
                report(.invalidFrame, receive: receive)
            }
        case let .failure(error):
            guard claimedFailure != false else {
                failureReported = true
                return
            }
            report(Self.sanitize(error), receive: receive)
        }
    }

    private func report(
        _ failure: LiveAudioError,
        receive: @escaping @Sendable (Result<LiveAudioFrame, Error>) -> Void
    ) {
        guard !failureReported else { return }
        failureReported = true
        receive(.failure(failure))
    }

    private func consumeInvalidation(
        _ failure: LiveAudioError,
        claimed: Bool,
        generation: UInt64,
        receive: @escaping @Sendable (Result<LiveAudioFrame, Error>) -> Void
    ) {
        guard running, self.generation == generation else { return }
        guard claimed else {
            failureReported = true
            return
        }
        report(failure, receive: receive)
    }

    private nonisolated static func sanitize(_ error: Error) -> LiveAudioError {
        switch error as? LiveAudioError {
        case .microphoneUnavailable: .microphoneUnavailable
        case .permissionDenied: .permissionDenied
        case .invalidFrame: .invalidFrame
        default: .captureFailed
        }
    }
}

public final class AVFoundationCaptureDriver: LiveAudioCaptureDriving, @unchecked Sendable {
    private let audioQueue: DispatchQueue
    private let engine: AVAudioEngine
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var running = false
    private let permissionStatus: @Sendable () -> MicrophonePermission
    private let inputAvailable: (@Sendable () -> Bool)?
    private let monitoringInterval: Duration

    public convenience init() {
        self.init(
            permissionStatus: { SystemMicrophonePermission.current() },
            inputAvailable: nil,
            monitoringInterval: .milliseconds(250)
        )
    }

    init(
        permissionStatus: @escaping @Sendable () -> MicrophonePermission,
        inputAvailable: (@Sendable () -> Bool)?,
        monitoringInterval: Duration
    ) {
        let audioQueue = DispatchQueue(label: "MillerLiveAudio.capture")
        self.audioQueue = audioQueue
        self.engine = audioQueue.sync { AVAudioEngine() }
        self.permissionStatus = permissionStatus
        self.inputAvailable = inputAvailable
        self.monitoringInterval = monitoringInterval
    }

    public func start(
        _ receive: @escaping @Sendable (Result<Data, Error>) -> Void
    ) async throws {
        try audioQueue.sync {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0,
                  let target = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: 24_000,
                    channels: 1,
                    interleaved: true
                  ),
                  let converter = AVAudioConverter(from: inputFormat, to: target)
            else { throw LiveAudioError.microphoneUnavailable }
            lock.withLock { self.converter = converter; running = true }
            input.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self, self.lock.withLock({ self.running }) else { return }
                do { receive(.success(try self.convert(buffer, using: converter, to: target))) }
                catch { receive(.failure(LiveAudioError.captureFailed)) }
            }
            engine.prepare()
            do { try engine.start() }
            catch {
                input.removeTap(onBus: 0)
                lock.withLock { running = false; self.converter = nil }
                throw LiveAudioError.captureFailed
            }
        }
    }

    public func stop() async {
        audioQueue.sync {
            lock.withLock { running = false; converter = nil }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    public func invalidations() async -> AsyncStream<LiveAudioError> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled, let self {
                    if let failure = currentInvalidation() {
                        continuation.yield(failure)
                        break
                    }
                    try? await Task.sleep(for: monitoringInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func currentInvalidation() -> LiveAudioError? {
        guard permissionStatus() == .authorized else { return .permissionDenied }
        let available = audioQueue.sync {
            inputAvailable?()
                ?? (engine.inputNode.outputFormat(forBus: 0).sampleRate > 0)
        }
        return available ? nil : .microphoneUnavailable
    }

    private func convert(
        _ source: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) throws -> Data {
        let capacity = AVAudioFrameCount(
            ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw LiveAudioError.captureFailed
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard conversionError == nil, status != .error,
              let bytes = output.int16ChannelData?[0]
        else { throw LiveAudioError.captureFailed }
        return Data(
            bytes: bytes,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }
}

// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
import Foundation

/// Owns content-free detector state and the bounded post-detection PCM buffer.
/// Physical capture and microphone-lease transfer remain with Miller's audio
/// owner. A lock prevents lifecycle and sample delivery from reordering audio.
public final class WakeWordCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let detector: any WakeWordDetecting
    private var accumulator: WakeWordFrameAccumulator
    private var ambient = WakeCommandAmbientSampler()
    private var endpoint: WakeCommandEndpointDetector?
    private var commandBuffer: WakeWordCommandBuffer
    private var preparedAudioConsumed = false

    private(set) var state: WakeWordState = .disabled
    private(set) var generation: UInt64 = 0

    public init(detector: any WakeWordDetecting) {
        self.detector = detector
        accumulator = WakeWordFrameAccumulator(
            frameLength: detector.requiredFrameLength
        )
        commandBuffer = WakeWordCommandBuffer(
            sampleRate: detector.requiredSampleRate
        )
    }

    @discardableResult
    public func beginStarting() -> UInt64? {
        lock.withLock {
            guard transition(to: .starting) else { return nil }
            beginGeneration()
            return generation
        }
    }

    public func confirmMonitoring(generation expectedGeneration: UInt64) throws {
        try lock.withLock {
            guard acceptsLocked(expectedGeneration),
                  transition(to: .monitoring) else {
                return
            }
            try detector.reset()
        }
    }

    public func receive(
        samples: ContiguousArray<Int16>,
        generation expectedGeneration: UInt64
    ) -> [WakeWordCoordinatorEvent] {
        lock.withLock {
            guard acceptsLocked(expectedGeneration) else { return [] }

            switch state {
            case .monitoring:
                return processMonitoring(samples: samples)
            case .handoff, .capturingCommand:
                return processCommand(samples: samples)
            default:
                return []
            }
        }
    }

    public func beginCommandCapture(
        generation expectedGeneration: UInt64
    ) -> WakeWordPreparedCommandAudio? {
        lock.withLock {
            guard acceptsLocked(expectedGeneration),
                  state == .handoff,
                  !preparedAudioConsumed,
                  transition(to: .capturingCommand) else {
                return nil
            }

            preparedAudioConsumed = true
            return WakeWordPreparedCommandAudio(
                id: UUID(),
                generation: generation,
                samples: commandBuffer.take(),
                sampleRate: detector.requiredSampleRate
            )
        }
    }

    @discardableResult
    public func suspend(_ reason: WakeWordSuspensionReason) -> UInt64 {
        lock.withLock {
            beginGeneration()
            _ = transition(to: .suspended(reason), allowingAnyActiveState: true)
            return generation
        }
    }

    @discardableResult
    public func resumeStarting() -> UInt64? {
        lock.withLock {
            guard case .suspended = state else { return nil }
            guard transition(to: .starting) else { return nil }
            beginGeneration()
            return generation
        }
    }

    @discardableResult
    public func beginStopping() -> UInt64? {
        lock.withLock {
            guard transition(to: .stopping, allowingAnyActiveState: true) else {
                return nil
            }
            beginGeneration()
            return generation
        }
    }

    public func finishStopping() {
        lock.withLock {
            guard transition(to: .disabled) else { return }
            resetGenerationState()
        }
    }

    public func markUnavailable(_ reason: WakeWordUnavailableReason) {
        lock.withLock {
            beginGeneration()
            _ = transition(
                to: .unavailable(reason),
                allowingAnyActiveState: true
            )
        }
    }

    public func shutdown() {
        lock.withLock {
            beginGeneration()
            state = .disabled
            detector.shutdown()
            resetGenerationState()
        }
    }

    public func accepts(_ candidateGeneration: UInt64) -> Bool {
        lock.withLock { acceptsLocked(candidateGeneration) }
    }

    public func currentState() -> WakeWordState {
        lock.withLock { state }
    }

    private func acceptsLocked(_ candidateGeneration: UInt64) -> Bool {
        candidateGeneration == generation
    }

    private func processMonitoring(
        samples: ContiguousArray<Int16>
    ) -> [WakeWordCoordinatorEvent] {
        let frames = accumulator.append(samples)
        let trailingTail = accumulator.tail
        var events = [WakeWordCoordinatorEvent]()
        var detected = false

        for frame in frames {
            if detected {
                commandBuffer.append(frame)
                if let endpointEvent = processEndpoint(frame: frame) {
                    events.append(endpointEvent)
                }
                continue
            }

            let dbfs = WakeWordFrameAudio.dbfs(frame)
            do {
                if try detector.process(frame: frame) {
                    endpoint = WakeCommandEndpointDetector(
                        ambientDBFS: ambient.medianOrFallback
                    )
                    commandBuffer.reset()
                    preparedAudioConsumed = false
                    guard transition(to: .handoff) else { break }
                    accumulator.reset()
                    detected = true
                    events.append(.wakeDetected(generation: generation))
                } else {
                    ambient.observe(dbfs: dbfs)
                }
            } catch {
                markUnavailable(.detectorRuntime)
                events.append(.detectorUnavailable(generation: generation))
                break
            }
        }

        if detected, !trailingTail.isEmpty {
            commandBuffer.append(trailingTail)
            _ = accumulator.append(trailingTail)
        }
        return events
    }

    private func processCommand(
        samples: ContiguousArray<Int16>
    ) -> [WakeWordCoordinatorEvent] {
        if state == .handoff {
            commandBuffer.append(samples)
        }
        let frames = accumulator.append(samples)
        var events = [WakeWordCoordinatorEvent]()
        for frame in frames {
            if let endpointEvent = processEndpoint(frame: frame) {
                events.append(endpointEvent)
                break
            }
        }
        return events
    }

    private func processEndpoint(
        frame: ContiguousArray<Int16>
    ) -> WakeWordCoordinatorEvent? {
        guard var endpoint else { return nil }
        let result = endpoint.process(dbfs: WakeWordFrameAudio.dbfs(frame))
        self.endpoint = endpoint
        guard result != .continueListening else { return nil }
        return .commandEndpoint(generation: generation, reason: result)
    }

    private func beginGeneration() {
        generation &+= 1
        resetGenerationState()
    }

    private func resetGenerationState() {
        accumulator.reset()
        ambient.reset()
        endpoint = nil
        commandBuffer.reset()
        preparedAudioConsumed = false
    }

    @discardableResult
    private func transition(
        to destination: WakeWordState,
        allowingAnyActiveState: Bool = false
    ) -> Bool {
        if allowingAnyActiveState, state != .disabled {
            state = destination
            return true
        }

        let legal: Bool
        switch (state, destination) {
        case (.disabled, .starting),
             (.unavailable, .starting),
             (.starting, .monitoring),
             (.monitoring, .handoff),
             (.handoff, .capturingCommand),
             (.suspended, .starting),
             (.stopping, .disabled):
            legal = true
        default:
            legal = false
        }

        guard legal else { return false }
        state = destination
        return true
    }
}

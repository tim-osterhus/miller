// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
import Foundation

/// Owns content-free detector state. A lock prevents lifecycle and sample
/// delivery from reordering audio.
public final class WakeWordCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let detector: any WakeWordDetecting
    private var accumulator: WakeWordFrameAccumulator

    private(set) var state: WakeWordState = .disabled
    private(set) var generation: UInt64 = 0

    public init(detector: any WakeWordDetecting) {
        self.detector = detector
        accumulator = WakeWordFrameAccumulator(
            frameLength: detector.requiredFrameLength
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
            default:
                return []
            }
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
        var events = [WakeWordCoordinatorEvent]()

        for frame in frames {
            do {
                if try detector.process(frame: frame) {
                    guard transition(to: .suspended(.processing)) else {
                        break
                    }
                    accumulator.reset()
                    events.append(.wakeDetected(generation: generation))
                    break
                } else {
                    continue
                }
            } catch {
                markUnavailable(.detectorRuntime)
                events.append(.detectorUnavailable(generation: generation))
                break
            }
        }
        return events
    }

    private func beginGeneration() {
        generation &+= 1
        resetGenerationState()
    }

    private func resetGenerationState() {
        accumulator.reset()
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
             (.monitoring, .suspended),
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

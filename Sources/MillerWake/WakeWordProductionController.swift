// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
import Combine
import Foundation

/// Narrow capture boundary. Task 17 binds this to Miller's concrete audio
/// owner, preserving the rule that wake listening never opens a second input.
@MainActor
public protocol WakeWordCaptureOwning: AnyObject {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)? { get set }
    var isWakeMonitoring: Bool { get }

    func startWakeMonitoring() async throws -> UUID
    func stopWakeMonitoring() async
}

@MainActor
public final class WakeWordProductionController: ObservableObject {
    @Published public private(set) var state: WakeWordState = .disabled

    private let recorder: any WakeWordCaptureOwning
    private let detectorFactory: @Sendable () throws -> any WakeWordDetecting
    private var coordinator: WakeWordCoordinator?
    private var monitoringSessionID: UUID?
    private var isEnabled = false

    public init(
        recorder: any WakeWordCaptureOwning,
        detectorFactory: @escaping @Sendable () throws -> any WakeWordDetecting
    ) {
        self.recorder = recorder
        self.detectorFactory = detectorFactory
    }

    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        if enabled {
            await startMonitoringIfEligible()
        } else {
            await stop(disable: true, shutDownDetector: false)
        }
    }

    public func enableFromSettings() async throws -> WakeWordState {
        await setEnabled(true)
        if case .unavailable(let reason) = state {
            isEnabled = false
            await stop(disable: true, shutDownDetector: false)
            throw WakeWordProductionError.unavailable(reason)
        }
        return state
    }

    public func disableFromSettings() async -> WakeWordState {
        await setEnabled(false)
        return state
    }

    public func applyDetectorTuningFromSettings() async throws -> WakeWordState {
        guard isEnabled else { return state }
        await stop(disable: false, shutDownDetector: true)
        await startMonitoringIfEligible()
        if case .unavailable(let reason) = state {
            throw WakeWordProductionError.unavailable(reason)
        }
        return state
    }

    public func suspend(_ reason: WakeWordSuspensionReason) async {
        guard isEnabled else { return }
        coordinator?.suspend(reason)
        state = .suspended(reason)
        recorder.onSamples = nil
        if recorder.isWakeMonitoring {
            await recorder.stopWakeMonitoring()
        }
        monitoringSessionID = nil
    }

    public func shutdown() async -> Bool {
        isEnabled = false
        await stop(disable: true, shutDownDetector: true)
        return !recorder.isWakeMonitoring
    }

    private func startMonitoringIfEligible() async {
        guard isEnabled,
              monitoringSessionID == nil,
              !recorder.isWakeMonitoring else {
            return
        }

        do {
            let coordinator: WakeWordCoordinator
            if let existing = self.coordinator {
                coordinator = existing
            } else {
                let created = WakeWordCoordinator(detector: try detectorFactory())
                self.coordinator = created
                coordinator = created
            }

            let generation: UInt64?
            if case .suspended = coordinator.currentState() {
                generation = coordinator.resumeStarting()
            } else {
                generation = coordinator.beginStarting()
            }
            guard let generation else { return }
            state = .starting

            recorder.onSamples = { [weak self, weak coordinator] samples in
                guard let coordinator else { return }
                let events = coordinator.receive(
                    samples: samples,
                    generation: generation
                )
                guard !events.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.handle(events: events)
                }
            }

            let sessionID = try await recorder.startWakeMonitoring()
            guard isEnabled else {
                recorder.onSamples = nil
                await recorder.stopWakeMonitoring()
                coordinator.suspend(.foregroundSession)
                state = .suspended(.foregroundSession)
                return
            }
            monitoringSessionID = sessionID
            try coordinator.confirmMonitoring(generation: generation)
            state = .monitoring
        } catch {
            recorder.onSamples = nil
            monitoringSessionID = nil
            if recorder.isWakeMonitoring {
                await recorder.stopWakeMonitoring()
            }
            coordinator?.markUnavailable(.capture)
            state = .unavailable(.capture)
        }
    }

    private func handle(events: [WakeWordCoordinatorEvent]) {
        for event in events {
            switch event {
            case .wakeDetected:
                state = .handoff
            case .commandEndpoint:
                state = .suspended(.processing)
            case .detectorUnavailable:
                state = .unavailable(.detectorRuntime)
            }
        }
    }

    private func stop(
        disable: Bool,
        shutDownDetector: Bool
    ) async {
        recorder.onSamples = nil
        if disable, coordinator != nil {
            coordinator?.beginStopping()
            state = .stopping
        }
        if recorder.isWakeMonitoring {
            await recorder.stopWakeMonitoring()
        }
        monitoringSessionID = nil

        if shutDownDetector {
            coordinator?.shutdown()
            coordinator = nil
        } else if disable {
            coordinator?.finishStopping()
        }
        if disable {
            state = .disabled
        }
    }
}

private enum WakeWordProductionError: LocalizedError {
    case unavailable(WakeWordUnavailableReason)

    var errorDescription: String? {
        switch self {
        case .unavailable(.microphonePermission):
            return "Enable Microphone access for Miller in System Settings."
        case .unavailable(.assistantMode):
            return "Enable a reasoning provider before wake listening."
        case .unavailable(.model), .unavailable(.detectorRuntime):
            return "Miller's wake engine is unavailable. Reinstall Miller."
        case .unavailable(.inputDevice):
            return "Connect or choose a microphone before enabling wake listening."
        case .unavailable(.capture):
            return "Miller could not start wake listening."
        }
    }
}

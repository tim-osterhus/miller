// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
import Combine
import Foundation

typealias WakeWordEventScheduler = @Sendable (
    @escaping @MainActor @Sendable () async -> Void
) -> Void

public typealias WakeWordDetectedHandler =
    @MainActor @Sendable () async -> Void
public typealias WakeWordCommandAudioHandler =
    @MainActor @Sendable (WakeWordPreparedCommandAudio, WakeCommandEndpointEvent) async -> Void

/// Coordinates the detector, the exclusive capture owner, and one bounded
/// post-keyword handoff into the Live voice authority.
@MainActor
public protocol WakeWordCaptureOwning: AnyObject {
    var onSamples: (@Sendable (ContiguousArray<Int16>) -> Void)? { get set }
    var isWakeMonitoring: Bool { get }

    func setFailureHandler(
        _ handler: @escaping @Sendable (WakeWordUnavailableReason) -> Void
    )
    func startWakeMonitoring() async throws -> UUID
    func stopWakeMonitoring() async
}

public extension WakeWordCaptureOwning {
    func setFailureHandler(
        _ handler: @escaping @Sendable (WakeWordUnavailableReason) -> Void
    ) {}
}

@MainActor
public final class WakeWordProductionController: ObservableObject {
    @Published public private(set) var state: WakeWordState = .disabled

    private let recorder: any WakeWordCaptureOwning
    private let detectorFactory: @Sendable () throws -> any WakeWordDetecting
    private let eventScheduler: WakeWordEventScheduler
    private var coordinator: WakeWordCoordinator?
    private var monitoringSessionID: UUID?
    private var pendingHandoff: WakeWordCaptureHandoff?
    private var sampleCallbackEpoch: UInt64?
    private var lifecycleEpoch: UInt64 = 0
    private var activeLifecycleEpochs = Set<UInt64>()
    private var lifecycleWaiters = [LifecycleWaiter]()
    private var startupEpoch: UInt64?
    private var startupWaiters = [CheckedContinuation<Void, Never>]()
    private var isEnabled = false
    private let onWakeDetected: WakeWordDetectedHandler
    private let onCommandAudio: WakeWordCommandAudioHandler

    public convenience init(
        recorder: any WakeWordCaptureOwning,
        detectorFactory: @escaping @Sendable () throws -> any WakeWordDetecting,
        onWakeDetected: @escaping WakeWordDetectedHandler = {},
        onCommandAudio: @escaping WakeWordCommandAudioHandler = { _, _ in }
    ) {
        self.init(
            recorder: recorder,
            detectorFactory: detectorFactory,
            onWakeDetected: onWakeDetected,
            onCommandAudio: onCommandAudio,
            eventScheduler: { operation in
                Task { @MainActor in await operation() }
            }
        )
    }

    init(
        recorder: any WakeWordCaptureOwning,
        detectorFactory: @escaping @Sendable () throws -> any WakeWordDetecting,
        onWakeDetected: @escaping WakeWordDetectedHandler = {},
        onCommandAudio: @escaping WakeWordCommandAudioHandler = { _, _ in },
        eventScheduler: @escaping WakeWordEventScheduler
    ) {
        self.recorder = recorder
        self.detectorFactory = detectorFactory
        self.onWakeDetected = onWakeDetected
        self.onCommandAudio = onCommandAudio
        self.eventScheduler = eventScheduler
    }

    public func setEnabled(_ enabled: Bool) async {
        if enabled, isEnabled, monitoringSessionID != nil {
            return
        }
        let operationEpoch = beginLifecycleOperation()
        defer { finishLifecycleOperation(operationEpoch) }
        isEnabled = enabled
        await waitForEarlierLifecycleOperations(operationEpoch)
        guard acceptsLifecycleOperation(operationEpoch),
              isEnabled == enabled else {
            return
        }
        if enabled {
            await startMonitoringIfEligible(operationEpoch: operationEpoch)
        } else {
            await stop(
                disable: true,
                shutDownDetector: false,
                operationEpoch: operationEpoch
            )
        }
    }

    public func enableFromSettings() async throws -> WakeWordState {
        await setEnabled(true)
        if case .unavailable(let reason) = state {
            isEnabled = false
            let operationEpoch = beginLifecycleOperation()
            defer { finishLifecycleOperation(operationEpoch) }
            await waitForEarlierLifecycleOperations(operationEpoch)
            guard acceptsLifecycleOperation(operationEpoch), !isEnabled else {
                throw WakeWordProductionError.unavailable(reason)
            }
            await stop(
                disable: true,
                shutDownDetector: false,
                operationEpoch: operationEpoch
            )
            throw WakeWordProductionError.unavailable(reason)
        }
        return state
    }

    public func disableFromSettings() async -> WakeWordState {
        await setEnabled(false)
        return state
    }

    public func reloadDetector() async throws -> WakeWordState {
        guard isEnabled else { return state }
        let operationEpoch = beginLifecycleOperation()
        defer { finishLifecycleOperation(operationEpoch) }
        await waitForEarlierLifecycleOperations(operationEpoch)
        guard acceptsLifecycleOperation(operationEpoch), isEnabled else {
            return state
        }
        await stop(
            disable: false,
            shutDownDetector: true,
            operationEpoch: operationEpoch
        )
        guard acceptsLifecycleOperation(operationEpoch) else { return state }
        await startMonitoringIfEligible(operationEpoch: operationEpoch)
        if case .unavailable(let reason) = state {
            throw WakeWordProductionError.unavailable(reason)
        }
        return state
    }

    @available(*, deprecated, message: "Use reloadDetector()")
    public func applyDetectorTuningFromSettings() async throws -> WakeWordState {
        try await reloadDetector()
    }

    public func suspend(_ reason: WakeWordSuspensionReason) async {
        guard isEnabled else { return }
        if case .suspended(let currentReason) = state {
            switch (currentReason, reason) {
            case (.foregroundSession, _), (.inactiveSession, _), (.sleep, _),
                 (.deviceTransition, _):
                return
            case (.processing, .inactiveSession), (.processing, .sleep):
                break
            default:
                return
            }
        }
        let operationEpoch = beginLifecycleOperation()
        defer { finishLifecycleOperation(operationEpoch) }
        await waitForEarlierLifecycleOperations(operationEpoch)
        guard acceptsLifecycleOperation(operationEpoch), isEnabled else {
            return
        }
        coordinator?.suspend(reason)
        state = .suspended(reason)
        clearSampleCallback()
        monitoringSessionID = nil
        if recorder.isWakeMonitoring {
            await recorder.stopWakeMonitoring()
            guard acceptsLifecycleOperation(operationEpoch) else { return }
        }
        await waitForStartupToSettle()
        guard acceptsLifecycleOperation(operationEpoch) else { return }
        if recorder.isWakeMonitoring {
            await recorder.stopWakeMonitoring()
            guard acceptsLifecycleOperation(operationEpoch) else { return }
        }
        state = .suspended(reason)
    }

    public func shutdown() async -> Bool {
        let operationEpoch = beginLifecycleOperation()
        defer { finishLifecycleOperation(operationEpoch) }
        isEnabled = false
        await waitForEarlierLifecycleOperations(operationEpoch)
        guard acceptsLifecycleOperation(operationEpoch), !isEnabled else {
            return !recorder.isWakeMonitoring
        }
        await stop(
            disable: true,
            shutDownDetector: true,
            operationEpoch: operationEpoch
        )
        return !recorder.isWakeMonitoring
    }

    /// Releases the wake lease before Live starts and begins a fresh detector
    /// generation only after the caller has completed Live cleanup.
    public func resumeAfterLiveCleanup() async {
        guard isEnabled else { return }
        if case .suspended(let reason) = state,
           reason == .inactiveSession || reason == .sleep
        {
            return
        }
        let operationEpoch = beginLifecycleOperation()
        defer { finishLifecycleOperation(operationEpoch) }
        await waitForEarlierLifecycleOperations(operationEpoch)
        guard acceptsLifecycleOperation(operationEpoch), isEnabled else { return }
        await startMonitoringIfEligible(operationEpoch: operationEpoch)
    }

    private func startMonitoringIfEligible(operationEpoch: UInt64) async {
        guard acceptsLifecycleOperation(operationEpoch),
              isEnabled,
              monitoringSessionID == nil,
              !recorder.isWakeMonitoring,
              beginStartup(operationEpoch: operationEpoch) else {
            return
        }
        defer { finishStartup(operationEpoch: operationEpoch) }

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
                guard let eventScheduler = self?.eventScheduler else { return }
                eventScheduler { @MainActor [weak self] in
                    await self?.handle(
                        events: events,
                        from: coordinator,
                        operationEpoch: operationEpoch
                    )
                }
            }
            sampleCallbackEpoch = operationEpoch
            recorder.setFailureHandler { [weak self] reason in
                Task { @MainActor [weak self] in
                    await self?.handleCaptureFailure(
                        reason,
                        callbackEpoch: operationEpoch
                    )
                }
            }

            let sessionID = try await recorder.startWakeMonitoring()
            guard acceptsLifecycleOperation(operationEpoch),
                  isEnabled,
                  self.coordinator === coordinator,
                  coordinator.accepts(generation) else {
                settleSupersededStartup(coordinator)
                clearSampleCallback(ifOwnedBy: operationEpoch)
                if recorder.isWakeMonitoring {
                    await recorder.stopWakeMonitoring()
                }
                return
            }
            monitoringSessionID = sessionID
            try coordinator.confirmMonitoring(generation: generation)
            guard acceptsLifecycleOperation(operationEpoch),
                  self.coordinator === coordinator,
                  coordinator.accepts(generation),
                  coordinator.currentState() == .monitoring else {
                settleSupersededStartup(coordinator)
                clearSampleCallback(ifOwnedBy: operationEpoch)
                monitoringSessionID = nil
                if recorder.isWakeMonitoring {
                    await recorder.stopWakeMonitoring()
                }
                return
            }
            state = .monitoring
        } catch {
            clearSampleCallback(ifOwnedBy: operationEpoch)
            monitoringSessionID = nil
            if recorder.isWakeMonitoring {
                await recorder.stopWakeMonitoring()
                guard acceptsLifecycleOperation(operationEpoch) else { return }
            }
            guard acceptsLifecycleOperation(operationEpoch) else { return }
            let reason = Self.unavailableReason(for: error)
            coordinator?.markUnavailable(reason)
            state = .unavailable(reason)
        }
    }

    private func handleCaptureFailure(
        _ reason: WakeWordUnavailableReason,
        callbackEpoch: UInt64
    ) async {
        guard acceptsLifecycleOperation(callbackEpoch) else { return }
        let operationEpoch = beginLifecycleOperation()
        defer { finishLifecycleOperation(operationEpoch) }
        await waitForEarlierLifecycleOperations(operationEpoch)
        guard acceptsLifecycleOperation(operationEpoch), isEnabled else { return }
        clearSampleCallback(ifOwnedBy: callbackEpoch)
        monitoringSessionID = nil
        pendingHandoff = nil
        coordinator?.markUnavailable(reason)
        if recorder.isWakeMonitoring {
            await recorder.stopWakeMonitoring()
        }
        guard acceptsLifecycleOperation(operationEpoch) else { return }
        state = .unavailable(reason)
    }

    private func handle(
        events: [WakeWordCoordinatorEvent],
        from eventCoordinator: WakeWordCoordinator,
        operationEpoch: UInt64
    ) async {
        guard acceptsLifecycleOperation(operationEpoch),
              coordinator === eventCoordinator else {
            return
        }

        for event in events {
            guard acceptsLifecycleOperation(operationEpoch),
                  coordinator === eventCoordinator else {
                return
            }
            switch event {
            case .wakeDetected(let generation):
                guard eventCoordinator.accepts(generation) else { continue }
                state = .handoff
                if let monitoringSessionID {
                    pendingHandoff = WakeWordCaptureHandoff(
                        monitoringSessionID: monitoringSessionID,
                        generation: generation,
                        coordinator: eventCoordinator
                    )
                }
                await onWakeDetected()
            case .commandEndpoint(let generation, let reason):
                guard eventCoordinator.accepts(generation) else { continue }
                await finishCommandEndpoint(
                    eventCoordinator: eventCoordinator,
                    generation: generation,
                    reason: reason,
                    operationEpoch: operationEpoch
                )
                return
            case .detectorUnavailable(let generation):
                guard eventCoordinator.accepts(generation) else { continue }
                await handleDetectorRuntimeFailure(
                    eventCoordinator: eventCoordinator,
                    callbackEpoch: operationEpoch
                )
                return
            }
        }
    }

    private func finishCommandEndpoint(
        eventCoordinator: WakeWordCoordinator,
        generation: UInt64,
        reason: WakeCommandEndpointEvent,
        operationEpoch: UInt64
    ) async {
        guard acceptsLifecycleOperation(operationEpoch),
              eventCoordinator.accepts(generation) else { return }
        let preparedAudio: WakeWordPreparedCommandAudio?
        switch reason {
        case .emptyWakeTimeout:
            preparedAudio = nil
        case .continueListening:
            return
        case .silence, .hardLimit:
            preparedAudio = pendingHandoff?.consume()
        }
        pendingHandoff = nil
        eventCoordinator.suspend(.processing)
        state = .suspended(.processing)
        await stop(
            disable: false,
            shutDownDetector: false,
            operationEpoch: operationEpoch
        )
        guard acceptsLifecycleOperation(operationEpoch), isEnabled else { return }
        if let preparedAudio {
            await onCommandAudio(preparedAudio, reason)
        } else {
            await startMonitoringIfEligible(operationEpoch: operationEpoch)
        }
    }

    private func handleDetectorRuntimeFailure(
        eventCoordinator: WakeWordCoordinator,
        callbackEpoch: UInt64
    ) async {
        guard acceptsLifecycleOperation(callbackEpoch),
              coordinator === eventCoordinator else {
            return
        }
        let operationEpoch = beginLifecycleOperation()
        defer { finishLifecycleOperation(operationEpoch) }
        await waitForEarlierLifecycleOperations(operationEpoch)
        guard acceptsLifecycleOperation(operationEpoch),
              coordinator === eventCoordinator else {
            return
        }
        clearSampleCallback(ifOwnedBy: callbackEpoch)
        monitoringSessionID = nil
        eventCoordinator.shutdown()
        if coordinator === eventCoordinator {
            coordinator = nil
        }
        if recorder.isWakeMonitoring {
            await recorder.stopWakeMonitoring()
            guard acceptsLifecycleOperation(operationEpoch) else { return }
        }
        state = .unavailable(.detectorRuntime)
    }

    private func stop(
        disable: Bool,
        shutDownDetector: Bool,
        operationEpoch: UInt64
    ) async {
        guard acceptsLifecycleOperation(operationEpoch) else { return }
        clearSampleCallback()
        monitoringSessionID = nil
        pendingHandoff = nil
        if disable, coordinator != nil {
            coordinator?.beginStopping()
            state = .stopping
        }
        if shutDownDetector {
            coordinator?.shutdown()
            coordinator = nil
        }
        if recorder.isWakeMonitoring {
            await recorder.stopWakeMonitoring()
            guard acceptsLifecycleOperation(operationEpoch) else {
                settleSupersededStop(
                    disable: disable,
                    shutDownDetector: shutDownDetector
                )
                return
            }
        }
        await waitForStartupToSettle()
        guard acceptsLifecycleOperation(operationEpoch) else {
            settleSupersededStop(
                disable: disable,
                shutDownDetector: shutDownDetector
            )
            return
        }
        if recorder.isWakeMonitoring {
            await recorder.stopWakeMonitoring()
            guard acceptsLifecycleOperation(operationEpoch) else {
                settleSupersededStop(
                    disable: disable,
                    shutDownDetector: shutDownDetector
                )
                return
            }
        }

        if disable, !shutDownDetector {
            coordinator?.finishStopping()
        }
        if disable {
            state = .disabled
        }
    }

    private func beginLifecycleOperation() -> UInt64 {
        lifecycleEpoch &+= 1
        activeLifecycleEpochs.insert(lifecycleEpoch)
        return lifecycleEpoch
    }

    private func finishLifecycleOperation(_ operationEpoch: UInt64) {
        activeLifecycleEpochs.remove(operationEpoch)
        let ready = lifecycleWaiters.filter { waiter in
            !activeLifecycleEpochs.contains { $0 < waiter.operationEpoch }
        }
        lifecycleWaiters.removeAll { waiter in
            !activeLifecycleEpochs.contains { $0 < waiter.operationEpoch }
        }
        ready.forEach { $0.continuation.resume() }
    }

    private func waitForEarlierLifecycleOperations(
        _ operationEpoch: UInt64
    ) async {
        guard activeLifecycleEpochs.contains(where: { $0 < operationEpoch }) else {
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(
                LifecycleWaiter(
                    operationEpoch: operationEpoch,
                    continuation: continuation
                )
            )
        }
    }

    private func acceptsLifecycleOperation(_ candidate: UInt64) -> Bool {
        candidate == lifecycleEpoch
    }

    private func beginStartup(operationEpoch: UInt64) -> Bool {
        guard startupEpoch == nil else { return false }
        startupEpoch = operationEpoch
        return true
    }

    private func finishStartup(operationEpoch: UInt64) {
        guard startupEpoch == operationEpoch else { return }
        startupEpoch = nil
        let waiters = startupWaiters
        startupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForStartupToSettle() async {
        guard startupEpoch != nil else { return }
        await withCheckedContinuation { continuation in
            startupWaiters.append(continuation)
        }
    }

    private func clearSampleCallback(ifOwnedBy ownerEpoch: UInt64? = nil) {
        if let ownerEpoch, sampleCallbackEpoch != ownerEpoch {
            return
        }
        recorder.onSamples = nil
        recorder.setFailureHandler { _ in }
        sampleCallbackEpoch = nil
    }

    private func settleSupersededStop(
        disable: Bool,
        shutDownDetector: Bool
    ) {
        if disable, !shutDownDetector {
            coordinator?.finishStopping()
        }
    }

    private func settleSupersededStartup(
        _ eventCoordinator: WakeWordCoordinator
    ) {
        guard eventCoordinator.currentState() == .starting else { return }
        eventCoordinator.suspend(.foregroundSession)
    }

    private static func unavailableReason(
        for error: Error
    ) -> WakeWordUnavailableReason {
        if error is WakeWordDetectorError || error is WakeWordKeywordMaterializerError {
            return .model
        }
        let reason: WakeWordUnavailableReason = switch error as? WakeWordCaptureStartError {
        case .permissionDenied: .microphonePermission
        case .inputDeviceUnavailable, .microphoneBusy: .inputDevice
        case .captureFailed: .capture
        case nil: .capture
        }
        return reason
    }
}

private struct LifecycleWaiter {
    let operationEpoch: UInt64
    let continuation: CheckedContinuation<Void, Never>
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

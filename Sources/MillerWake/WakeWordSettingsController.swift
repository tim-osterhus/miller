// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
import Combine
import Foundation

@MainActor
public final class WakeWordSettingsController: ObservableObject {
    public typealias Operation =
        @MainActor @Sendable () async throws -> WakeWordState

    public nonisolated static let enabledDefaultsKey = "WakeWordEnabled"

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var state: WakeWordState
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var keywordScore: Double
    @Published public private(set) var keywordThreshold: Double

    private let defaults: UserDefaults
    private let enableOperation: Operation
    private let disableOperation: Operation
    private let applyTuningOperation: Operation
    private var operationTask: Task<Void, Never>?
    private var pendingEnabled: Bool?
    private var stateProjection: AnyCancellable?

    public init(
        defaults: UserDefaults = .standard,
        initialState: WakeWordState = .disabled,
        enable: @escaping Operation,
        disable: @escaping Operation,
        applyTuning: @escaping Operation = { .disabled }
    ) {
        self.defaults = defaults
        state = initialState
        enableOperation = enable
        disableOperation = disable
        applyTuningOperation = applyTuning
        isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        let tuning = SherpaWakeWordTuning.load(from: defaults)
        keywordScore = tuning.keywordScore
        keywordThreshold = tuning.keywordThreshold
    }

    deinit {
        operationTask?.cancel()
    }

    public var statusText: String {
        if pendingEnabled != nil {
            return pendingEnabled == true
                ? "Starting wake listening"
                : "Stopping wake listening"
        }

        return Self.statusText(for: state)
    }

    public var isTuningEditable: Bool {
        switch state {
        case .starting, .handoff, .capturingCommand, .stopping:
            false
        default:
            true
        }
    }

    public func setEnabled(_ requestedEnabled: Bool) {
        guard !isWorking, requestedEnabled != isEnabled else { return }

        pendingEnabled = requestedEnabled
        isWorking = true
        errorMessage = nil
        let operation = requestedEnabled ? enableOperation : disableOperation
        let defaults = defaults

        if !requestedEnabled {
            // An explicit off request must survive relaunch even if teardown
            // reports a failure.
            isEnabled = false
            defaults.set(false, forKey: Self.enabledDefaultsKey)
        }

        operationTask = Task { @MainActor [weak self] in
            do {
                let nextState = try await operation()
                guard !Task.isCancelled, let self else { return }
                defer {
                    self.pendingEnabled = nil
                    self.isWorking = false
                }
                self.state = nextState
                if requestedEnabled {
                    self.isEnabled = true
                    defaults.set(true, forKey: Self.enabledDefaultsKey)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                defer {
                    self.pendingEnabled = nil
                    self.isWorking = false
                }
                if requestedEnabled {
                    self.isEnabled = false
                    defaults.set(false, forKey: Self.enabledDefaultsKey)
                } else {
                    self.state = .unavailable(.capture)
                }
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Miller could not update wake listening."
            }
        }
    }

    public func applyTuning(
        keywordScore requestedScore: Double,
        keywordThreshold requestedThreshold: Double
    ) {
        guard !isWorking else { return }
        guard isTuningEditable else {
            errorMessage =
                "Wait for the current wake request to finish before changing sensitivity."
            return
        }
        guard let tuning = SherpaWakeWordTuning(
            keywordScore: requestedScore,
            keywordThreshold: requestedThreshold
        ) else {
            errorMessage =
                "Keyword score must be greater than 0, and threshold must be between 0 and 1."
            return
        }

        keywordScore = tuning.keywordScore
        keywordThreshold = tuning.keywordThreshold
        defaults.set(
            tuning.keywordScore,
            forKey: SherpaWakeWordTuning.keywordScoreDefaultsKey
        )
        defaults.set(
            tuning.keywordThreshold,
            forKey: SherpaWakeWordTuning.keywordThresholdDefaultsKey
        )
        errorMessage = nil

        guard isEnabled else { return }
        isWorking = true
        let operation = applyTuningOperation
        operationTask = Task { @MainActor [weak self] in
            do {
                let state = try await operation()
                guard !Task.isCancelled, let self else { return }
                self.state = state
                self.isWorking = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.errorMessage = (error as? LocalizedError)?
                    .errorDescription
                    ?? "Miller could not apply wake sensitivity."
                self.isWorking = false
            }
        }
    }

    public func bind(to production: WakeWordProductionController) {
        stateProjection = production.$state.sink { [weak self] state in
            self?.project(state: state)
        }
    }

    public func startPersistedPreference() {
        guard isEnabled, !isWorking else { return }
        // The stored preference describes intent; production capture still
        // starts only after the app's launch-reset fence.
        isEnabled = false
        setEnabled(true)
    }

    public func project(state: WakeWordState) {
        self.state = state
    }

    public static func statusText(for state: WakeWordState) -> String {
        switch state {
        case .disabled:
            "Off"
        case .starting:
            "Starting wake listening"
        case .monitoring:
            "Wake listening"
        case .handoff, .capturingCommand:
            "Recording request"
        case .stopping:
            "Stopping wake listening"
        case .unavailable(let reason):
            switch reason {
            case .microphonePermission:
                "Waiting for microphone permission"
            case .detectorRuntime:
                "Wake engine unavailable — reinstall Miller"
            case .model:
                "Wake model unavailable"
            case .inputDevice:
                "Input device unavailable"
            case .assistantMode:
                "Wake listening unavailable — enable a reasoning provider"
            case .capture:
                "Wake listening unavailable"
            }
        case .suspended(let reason):
            switch reason {
            case .speaking:
                "Paused while Miller is speaking"
            case .processing, .foregroundSession:
                "Paused while Miller is working"
            case .deviceTransition:
                "Input device unavailable"
            case .sleep, .inactiveSession:
                "Wake listening paused"
            }
        }
    }
}

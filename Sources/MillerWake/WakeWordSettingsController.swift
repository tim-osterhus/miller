import Combine
import Foundation

@MainActor
public final class WakeWordSettingsController: ObservableObject {
    public typealias Operation =
        @MainActor @Sendable () async throws -> WakeWordState
    public typealias PhraseOperation =
        @MainActor @Sendable (String) async throws -> String
    public typealias TuningOperation =
        @MainActor @Sendable (SherpaWakeWordTuning) async throws -> SherpaWakeWordTuning

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var phrase: String
    @Published public private(set) var tuning: SherpaWakeWordTuning
    @Published public private(set) var state: WakeWordState
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?

    private let enableOperation: Operation
    private let disableOperation: Operation
    private let retryOperation: Operation
    private let savePhraseOperation: PhraseOperation
    private let saveTuningOperation: TuningOperation
    private var operationTask: Task<Void, Never>?
    private var pendingEnabled: Bool?
    private var stateProjection: AnyCancellable?

    public init(
        initialEnabled: Bool = false,
        initialPhrase: String = "Hey Miller",
        initialTuning: SherpaWakeWordTuning = .default,
        initialState: WakeWordState = .disabled,
        enable: @escaping Operation,
        disable: @escaping Operation,
        retry: @escaping Operation = { .disabled },
        savePhrase: @escaping PhraseOperation = { $0 },
        saveTuning: @escaping TuningOperation = { $0 }
    ) {
        isEnabled = initialEnabled
        phrase = initialPhrase
        tuning = initialTuning
        state = initialState
        enableOperation = enable
        disableOperation = disable
        retryOperation = retry
        savePhraseOperation = savePhrase
        saveTuningOperation = saveTuning
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

    public var keywordScore: Double { tuning.keywordScore }
    public var detectionThreshold: Double { tuning.keywordThreshold }

    public func setEnabled(_ requestedEnabled: Bool) {
        guard !isWorking, requestedEnabled != isEnabled else { return }
        pendingEnabled = requestedEnabled
        isWorking = true
        errorMessage = nil
        let operation = requestedEnabled ? enableOperation : disableOperation
        operationTask = Task { @MainActor [weak self] in
            do {
                let nextState = try await operation()
                guard !Task.isCancelled, let self else { return }
                self.state = nextState
                self.isEnabled = requestedEnabled
                self.pendingEnabled = nil
                self.isWorking = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.pendingEnabled = nil
                self.isWorking = false
                if requestedEnabled { self.isEnabled = false }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    public func updatePhrase(_ requestedPhrase: String) {
        guard !isWorking, requestedPhrase != phrase else { return }
        isWorking = true
        errorMessage = nil
        let operation = savePhraseOperation
        operationTask = Task { @MainActor [weak self] in
            do {
                let normalized = try await operation(requestedPhrase)
                guard !Task.isCancelled, let self else { return }
                self.phrase = normalized
                self.isWorking = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isWorking = false
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    public func updateTuning(
        keywordScore: Double,
        detectionThreshold: Double
    ) {
        guard !isWorking else { return }
        guard let requested = SherpaWakeWordTuning(
            keywordScore: keywordScore,
            keywordThreshold: detectionThreshold
        ) else {
            errorMessage = "Enter a positive keyword score and a detection threshold from 0 to 1."
            return
        }
        guard requested != tuning else { return }
        isWorking = true
        errorMessage = nil
        let operation = saveTuningOperation
        operationTask = Task { @MainActor [weak self] in
            do {
                let saved = try await operation(requested)
                guard !Task.isCancelled, let self else { return }
                self.tuning = saved
                self.isWorking = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isWorking = false
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    public func retry() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        let operation = retryOperation
        operationTask = Task { @MainActor [weak self] in
            do {
                let nextState = try await operation()
                guard !Task.isCancelled, let self else { return }
                self.state = nextState
                self.isEnabled = nextState != .disabled
                self.isWorking = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isWorking = false
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    public func restorePersistedPreferences(
        enabled: Bool,
        phrase: String,
        tuning: SherpaWakeWordTuning = .default
    ) async {
        operationTask?.cancel()
        operationTask = nil
        pendingEnabled = nil
        errorMessage = nil
        self.phrase = phrase
        self.tuning = tuning
        guard enabled else {
            isEnabled = false
            state = .disabled
            isWorking = false
            return
        }
        isWorking = true
        do {
            let nextState = try await enableOperation()
            state = nextState
            isEnabled = nextState != .disabled
            isWorking = false
        } catch {
            isEnabled = false
            isWorking = false
            errorMessage = Self.message(for: error)
        }
    }

    public func bind(to production: WakeWordProductionController) {
        stateProjection = production.$state.sink { [weak self] state in
            self?.project(state: state)
        }
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
            case .sleep:
                "Wake listening paused"
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case WakeWordPhraseError.empty:
            "Enter a wake phrase."
        case WakeWordPhraseError.tooLong:
            "Wake phrase is too long."
        case WakeWordPhraseError.tooManyTokens:
            "Wake phrase has too many tokens."
        case WakeWordPhraseError.unsupportedToken(let token):
            "Wake phrase contains unsupported input: \(token)."
        default:
            (error as? LocalizedError)?.errorDescription
                ?? "Miller could not update wake listening."
        }
    }
}

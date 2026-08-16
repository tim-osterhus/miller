import SwiftUI
import MillerWake

@MainActor
final class RemoteLiveSettingsModel: ObservableObject {
    typealias Operation = @MainActor @Sendable () async throws -> Void

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let enableOperation: Operation
    private let disableOperation: Operation
    private var operationTask: Task<Void, Never>?
    private var pendingEnabled: Bool?
    private var lifecycleGeneration: UInt64 = 0
    private var lifecycleFence = false
    private var externalEnableMayBeActive = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initialEnabled: Bool = false,
        enable: @escaping Operation = {},
        disable: @escaping Operation = {}
    ) {
        isEnabled = initialEnabled
        enableOperation = enable
        disableOperation = disable
    }

    deinit {
        operationTask?.cancel()
    }

    var statusText: String {
        if let pendingEnabled {
            return pendingEnabled ? "Starting remote Live Voice" : "Stopping remote Live Voice"
        }
        return isEnabled ? "Enabled" : "Disabled"
    }

    func setEnabled(_ requestedEnabled: Bool) {
        if lifecycleFence {
            guard requestedEnabled else { return }
            lifecycleFence = false
        }
        guard requestedEnabled != isEnabled
            || operationTask != nil
            || pendingEnabled != nil
        else { return }
        pendingEnabled = requestedEnabled
        errorMessage = nil
        startNextOperation()
    }

    func restorePersistedPreferences(enabled: Bool) async {
        let generation = lifecycleGeneration
        errorMessage = nil
        guard !lifecycleFence else {
            isEnabled = false
            pendingEnabled = nil
            return
        }
        pendingEnabled = enabled
        startNextOperation()
        await drainOperations()
        guard lifecycleGeneration == generation, !lifecycleFence else {
            isEnabled = false
            return
        }
    }

    internal func waitUntilIdle() async {
        guard operationTask != nil || pendingEnabled != nil || isWorking else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func disableForLifecycle() async {
        lifecycleGeneration &+= 1
        lifecycleFence = true
        pendingEnabled = false
        errorMessage = nil
        startNextOperation()
        await drainOperations()
        if externalEnableMayBeActive || isEnabled {
            isWorking = true
            do {
                try await disableOperation()
                externalEnableMayBeActive = false
            } catch {
                errorMessage = "Miller could not stop remote Live Voice."
            }
            isWorking = false
        }
        pendingEnabled = nil
        isEnabled = false
    }

    private func startNextOperation() {
        guard operationTask == nil, let requestedEnabled = pendingEnabled else {
            return
        }
        pendingEnabled = nil
        guard requestedEnabled != isEnabled else {
            isWorking = false
            return
        }
        isWorking = true
        let operation = requestedEnabled ? enableOperation : disableOperation
        if requestedEnabled { externalEnableMayBeActive = true }
        operationTask = Task { @MainActor [weak self] in
            do {
                try await operation()
                guard let self else { return }
                self.finishOperation(
                    requestedEnabled: requestedEnabled,
                    succeeded: true
                )
            } catch {
                guard let self else { return }
                self.errorMessage = "Miller could not update remote Live Voice."
                self.finishOperation(
                    requestedEnabled: requestedEnabled,
                    succeeded: false
                )
            }
        }
    }

    private func finishOperation(
        requestedEnabled: Bool,
        succeeded: Bool
    ) {
        operationTask = nil
        if succeeded {
            isEnabled = requestedEnabled
            if !requestedEnabled { externalEnableMayBeActive = false }
        } else if requestedEnabled {
            isEnabled = false
        }
        if lifecycleFence { pendingEnabled = false }
        if !succeeded {
            if !(requestedEnabled && pendingEnabled == false) {
                pendingEnabled = nil
            }
        }
        isWorking = false
        startNextOperation()
        guard operationTask == nil, pendingEnabled == nil, !isWorking else {
            return
        }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func drainOperations() async {
        while let task = operationTask {
            await task.value
        }
        if pendingEnabled != nil {
            startNextOperation()
            await drainOperations()
        }
    }
}

struct VoiceSettingsTab: View {
    let section = SettingsSection.voice
    @ObservedObject var model: AppPresentationModel
    @ObservedObject var wakeSettings: WakeWordSettingsController
    @ObservedObject var remoteLiveSettings: RemoteLiveSettingsModel
    @State private var phraseDraft = ""
    @State private var keywordScoreDraft = ""
    @State private var detectionThresholdDraft = ""

    init(
        model: AppPresentationModel,
        wakeSettings: WakeWordSettingsController = .init(
            enable: { .disabled },
            disable: { .disabled }
        ),
        remoteLiveSettings: RemoteLiveSettingsModel = .init()
    ) {
        self.model = model
        self.wakeSettings = wakeSettings
        self.remoteLiveSettings = remoteLiveSettings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                GroupBox("Live Voice") {
                    LabeledContent("Readiness") {
                        Text(model.voiceStatusText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                GroupBox("Remote Live Voice") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Allow browser Live Voice",
                            isOn: Binding(
                                get: { remoteLiveSettings.isEnabled },
                                set: { remoteLiveSettings.setEnabled($0) }
                            )
                        )
                        .disabled(remoteLiveSettings.isWorking)
                        LabeledContent("Status") {
                            Text(remoteLiveSettings.statusText)
                        }
                        if let errorMessage = remoteLiveSettings.errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                GroupBox("Wake Listening") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Enable wake listening",
                            isOn: Binding(
                                get: { wakeSettings.isEnabled },
                                set: { wakeSettings.setEnabled($0) }
                            )
                        )
                        .disabled(wakeSettings.isWorking)

                        HStack {
                            TextField("Wake phrase", text: $phraseDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Save phrase") {
                                wakeSettings.updatePhrase(phraseDraft)
                            }
                            .disabled(
                                wakeSettings.isWorking
                                    || phraseDraft == wakeSettings.phrase
                            )
                        }

                        LabeledContent("Keyword score") {
                            TextField("Keyword score", text: $keywordScoreDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                        LabeledContent("Detection threshold") {
                            TextField(
                                "Detection threshold",
                                text: $detectionThresholdDraft
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        }
                        Button("Save tuning") {
                            wakeSettings.updateTuning(
                                keywordScore: Double(keywordScoreDraft) ?? .nan,
                                detectionThreshold: Double(
                                    detectionThresholdDraft
                                ) ?? .nan
                            )
                        }
                        .disabled(wakeSettings.isWorking)

                        LabeledContent("Status") {
                            Text(wakeSettings.statusText)
                        }
                        if let guidance = permissionGuidance {
                            Text(guidance)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let errorMessage = wakeSettings.errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        if isRetryAvailable {
                            Button("Retry") {
                                wakeSettings.retry()
                            }
                            .disabled(wakeSettings.isWorking)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
        .onAppear { restoreDrafts() }
        .onChange(of: wakeSettings.phrase) { _, phrase in
            phraseDraft = phrase
        }
        .onChange(of: wakeSettings.tuning) { _, _ in restoreTuningDrafts() }
        .onChange(of: wakeSettings.errorMessage) { _, message in
            if message != nil { restoreTuningDrafts() }
        }
    }

    private func restoreDrafts() {
        phraseDraft = wakeSettings.phrase
        restoreTuningDrafts()
    }

    private func restoreTuningDrafts() {
        keywordScoreDraft = String(wakeSettings.keywordScore)
        detectionThresholdDraft = String(wakeSettings.detectionThreshold)
    }

    private var isRetryAvailable: Bool {
        if case .unavailable = wakeSettings.state { return true }
        return false
    }

    private var permissionGuidance: String? {
        guard case .unavailable(let reason) = wakeSettings.state else {
            return nil
        }
        switch reason {
        case .microphonePermission:
            return "Allow Miller to use the system microphone in System Settings, then retry."
        case .model, .detectorRuntime:
            return "Wake listening requires the verified local wake model."
        case .inputDevice:
            return "The system-default microphone is unavailable. Connect it and retry."
        case .assistantMode:
            return "Select a reasoning provider before enabling wake listening."
        case .capture:
            return "Wake capture stopped. Check microphone access and retry."
        }
    }
}

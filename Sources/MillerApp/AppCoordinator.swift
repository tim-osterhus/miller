import AppKit
import Combine
import Foundation
import MillerCapabilities
import MillerCore
import MillerGateway
import MillerLive
import MillerLiveAudio
import MillerStorage
import MillerWake
import SwiftUI

enum AccessibilityLabel {
    static let status = "Miller status"
    static let input = "Message Miller"
    static let send = "Send message"
    static let stop = "Stop response"
    static let newConversation = "New conversation"
    static let conversationList = "Conversations"
    static let openConversation = "Open conversation window"
    static let settings = "Miller settings"
    static let startLiveVoice = "Start Live Voice"
    static let muteLiveVoice = "Mute Live Voice"
    static let unmuteLiveVoice = "Unmute Live Voice"
    static let interruptLiveVoice = "Interrupt Live Voice"
    static let endLiveVoice = "End Live Voice"
}

enum AccessibilityIdentifier {
    static let input = "miller.message-input"
    static let send = "miller.send"
    static let stop = "miller.stop"
    static let newConversation = "miller.new-conversation"
    static let conversationInput = "miller.conversation-input"
    static let conversationSend = "miller.conversation-send"
    static let conversationStop = "miller.conversation-stop"
}

enum HostKeyboardCommand: Equatable {
    case submit
    case dismiss
    case stop

    static func map(key: String, command: Bool) -> HostKeyboardCommand? {
        switch (key, command) {
        case ("\r", _): .submit
        case ("\u{1b}", _): .dismiss
        case (".", true): .stop
        default: nil
        }
    }
}

enum VoiceHistoryMutationError: Error, Equatable {
    case busy
}

enum LiveAdmissionError: Error, Equatable, Sendable {
    case sessionAlreadyActive
}

private final class LiveAdmissionReleaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return false }
        released = true
        return true
    }
}

private final class LiveTranscriptCleanupTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let tasks = self.tasks
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }
}

final class LiveAdmission: @unchecked Sendable {
    let conversationID: ConversationID
    let activationSource: VoiceActivationSource

    private let releaseOperation: @Sendable () async -> Void
    private let releaseState = LiveAdmissionReleaseState()

    init(
        conversationID: ConversationID,
        activationSource: VoiceActivationSource,
        release: @escaping @Sendable () async -> Void = {}
    ) {
        self.conversationID = conversationID
        self.activationSource = activationSource
        releaseOperation = release
    }

    func release() async {
        guard releaseState.claim() else { return }
        await releaseOperation()
    }

    deinit {
        guard releaseState.claim() else { return }
        let releaseOperation = releaseOperation
        Task { await releaseOperation() }
    }
}

struct LiveAdmissionReservation: Sendable {
    private let releaseOperation: @Sendable () async -> Void

    init(release: @escaping @Sendable () async -> Void) {
        releaseOperation = release
    }

    func release() async {
        await releaseOperation()
    }
}

actor LiveAdmissionAuthority {
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?

    func reserve() throws -> LiveAdmissionReservation {
        guard activeGeneration == nil else {
            throw LiveAdmissionError.sessionAlreadyActive
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation
        return LiveAdmissionReservation { [self] in
            await release(generation: generation)
        }
    }

    private func release(generation: UInt64) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
    }
}

struct MenuState: Equatable {
    let canCreateConversation: Bool
    let canStop: Bool

    static func derive(activeTurn: Bool) -> Self {
        Self(
            canCreateConversation: !activeTurn,
            canStop: activeTurn
        )
    }
}

enum PresentationDerivation {
    static func state(for turn: Turn) -> PresentationState {
        switch turn.state {
        case .accepted: .waiting
        case .streaming: turn.assistantText.isEmpty ? .waiting : .responding
        case .completed: .completed
        case .stopped: .stopped
        case .failed: .failed
        }
    }
}

struct ConversationListItem: Identifiable, Equatable, Sendable {
    let id: ConversationID
    let title: String
    let state: ConversationState
    let updatedAt: Date

    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.title ?? "New Conversation"
        state = conversation.state
        updatedAt = conversation.updatedAt
    }

    static func ordered(_ values: [Self]) -> [Self] {
        values.sorted {
            if $0.state != $1.state {
                return $0.state == .active
            }
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id.description < $1.id.description
        }
    }
}

struct HostDependencies: Sendable {
    private let submitOperation:
        @Sendable (String, ConversationID, VoiceHistoryAttachment?) async throws -> TurnID
    private let admitLiveOperation: @Sendable (
        ConversationID,
        VoiceActivationSource
    ) async throws -> LiveAdmission
    let stop: @Sendable () async throws -> Void
    let loadTurn: @Sendable (TurnID) async throws -> Turn?
    let loadConversations: @Sendable () async throws -> [Conversation]
    let loadTurns: @Sendable (ConversationID) async throws -> [Turn]
    let archive: @Sendable (ConversationID) async throws -> Void
    let unarchive: @Sendable (ConversationID) async throws -> Void
    let delete: @Sendable (ConversationID) async throws -> Void
    let reasoningStatus: @Sendable () async -> ReasoningStatus?

    init(
        submit: @escaping @Sendable (String, ConversationID) async throws -> TurnID,
        stop: @escaping @Sendable () async throws -> Void,
        loadTurn: @escaping @Sendable (TurnID) async throws -> Turn?,
        loadConversations: @escaping @Sendable () async throws -> [Conversation],
        loadTurns: @escaping @Sendable (ConversationID) async throws -> [Turn],
        archive: @escaping @Sendable (ConversationID) async throws -> Void,
        unarchive: @escaping @Sendable (ConversationID) async throws -> Void,
        delete: @escaping @Sendable (ConversationID) async throws -> Void,
        reasoningStatus: @escaping @Sendable () async -> ReasoningStatus? = { nil },
        admitLive: @escaping @Sendable (
            ConversationID,
            VoiceActivationSource
        ) async throws -> LiveAdmission = { conversationID, activationSource in
            LiveAdmission(
                conversationID: conversationID,
                activationSource: activationSource
            )
        }
    ) {
        submitOperation = { text, conversationID, _ in
            try await submit(text, conversationID)
        }
        admitLiveOperation = admitLive
        self.stop = stop
        self.loadTurn = loadTurn
        self.loadConversations = loadConversations
        self.loadTurns = loadTurns
        self.archive = archive
        self.unarchive = unarchive
        self.delete = delete
        self.reasoningStatus = reasoningStatus
    }

    init(
        submit: @escaping @Sendable (
            String,
            ConversationID,
            VoiceHistoryAttachment?
        ) async throws -> TurnID,
        stop: @escaping @Sendable () async throws -> Void,
        loadTurn: @escaping @Sendable (TurnID) async throws -> Turn?,
        loadConversations: @escaping @Sendable () async throws -> [Conversation],
        loadTurns: @escaping @Sendable (ConversationID) async throws -> [Turn],
        archive: @escaping @Sendable (ConversationID) async throws -> Void,
        unarchive: @escaping @Sendable (ConversationID) async throws -> Void,
        delete: @escaping @Sendable (ConversationID) async throws -> Void,
        reasoningStatus: @escaping @Sendable () async -> ReasoningStatus? = { nil },
        admitLive: @escaping @Sendable (
            ConversationID,
            VoiceActivationSource
        ) async throws -> LiveAdmission = { conversationID, activationSource in
            LiveAdmission(
                conversationID: conversationID,
                activationSource: activationSource
            )
        }
    ) {
        submitOperation = submit
        admitLiveOperation = admitLive
        self.stop = stop
        self.loadTurn = loadTurn
        self.loadConversations = loadConversations
        self.loadTurns = loadTurns
        self.archive = archive
        self.unarchive = unarchive
        self.delete = delete
        self.reasoningStatus = reasoningStatus
    }

    func submit(
        _ text: String,
        _ conversationID: ConversationID,
        _ voiceHistoryAttachment: VoiceHistoryAttachment? = nil
    ) async throws -> TurnID {
        try await submitOperation(text, conversationID, voiceHistoryAttachment)
    }

    func admitLive(
        conversationID: ConversationID,
        activationSource: VoiceActivationSource
    ) async throws -> LiveAdmission {
        try await admitLiveOperation(conversationID, activationSource)
    }
}

struct VoiceHistoryDependencies: Sendable {
    let sessions:
        @Sendable (Date?, Date?) async throws -> [VoiceHistorySession]
    let exportProjection:
        @Sendable ([UUID]) async throws -> [VoiceHistoryExportSession]
    let attachmentProjection:
        @Sendable ([UUID], Int) async throws -> VoiceHistoryAttachmentProjection
    let rangeAttachmentProjection:
        @Sendable (Date, Date, Int) async throws -> VoiceHistoryAttachmentProjection
    let deleteSession: @Sendable (UUID) async throws -> Void
    let deleteRange: @Sendable (Date, Date) async throws -> Void
    let deleteAll: @Sendable () async throws -> Void

    static let unavailable = Self(
        sessions: { _, _ in [] },
        exportProjection: { _ in [] },
        attachmentProjection: { _, _ in .init(sessionIDs: [], entries: [], hasMore: false) },
        rangeAttachmentProjection: { _, _, _ in .init(sessionIDs: [], entries: [], hasMore: false) },
        deleteSession: { _ in },
        deleteRange: { _, _ in },
        deleteAll: {}
    )
}

struct ProviderSettingsInput: Equatable, Sendable {
    let profileID: UUID?
    let label: String
    let endpoint: String
    let model: String
    let apiKey: String
}

struct ProviderSettingsProfile: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let kind: ProviderKind
    let endpoint: String?
    let model: String
    let credentialReference: UUID
    let isSelected: Bool

    init(
        id: UUID,
        label: String,
        kind: ProviderKind,
        endpoint: String?,
        model: String,
        credentialReference: UUID,
        isSelected: Bool
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.endpoint = endpoint
        self.model = model
        self.credentialReference = credentialReference
        self.isSelected = isSelected
    }

    init(_ profile: ProviderProfile) {
        id = profile.id
        label = profile.label
        kind = profile.kind
        endpoint = profile.baseURL
        model = profile.model
        credentialReference = profile.credentialReference
        isSelected = profile.isSelected
    }

}

struct ProviderSettingsSnapshot: Equatable, Sendable {
    let profiles: [ProviderSettingsProfile]
    let readiness: String
    let codexModels: [GatewayModelChoice]
    let codexDefaultModel: String

    init(
        profiles: [ProviderSettingsProfile],
        readiness: String,
        codexModels: [GatewayModelChoice] = [],
        codexDefaultModel: String = ""
    ) {
        self.profiles = profiles
        self.readiness = readiness
        self.codexModels = codexModels
        self.codexDefaultModel = codexDefaultModel
    }
}

struct ProviderSettingsDependencies: Sendable {
    let load: @Sendable () async throws -> ProviderSettingsSnapshot
    let saveOpenAICompatible:
        @Sendable (ProviderSettingsInput, Bool) async throws -> Void
    let saveCodexModel: @Sendable (String) async throws -> Void
    let select: @Sendable (UUID, Bool) async throws -> Void
    let beginCodexLogin: @Sendable (Bool) async throws -> Void
    let refreshCodexAuthentication: @Sendable (Bool) async throws -> Void
    let retryReadiness:
        @Sendable () async throws -> ProviderSettingsSnapshot
    let localLogout: @Sendable (Bool) async throws -> Void
    let delete: @Sendable (UUID, Bool) async throws -> Void
    let reset: @Sendable () async -> ResetResult

    static let unavailable = Self(
        load: { .init(profiles: [], readiness: "Not configured") },
        saveOpenAICompatible: { _, _ in },
        saveCodexModel: { _ in },
        select: { _, _ in },
        beginCodexLogin: { _ in },
        refreshCodexAuthentication: { _ in },
        retryReadiness: { .init(profiles: [], readiness: "Not configured") },
        localLogout: { _ in },
        delete: { _, _ in },
        reset: { .init(roots: []) }
    )
}

@MainActor
final class AppPresentationModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var presentationState: PresentationState = .ready
    @Published private(set) var visibleTurns: [Turn] = []
    @Published private(set) var transcriptContentRevision =
        TranscriptContentRevision()
    @Published private(set) var conversations: [ConversationListItem] = []
    @Published private(set) var selectedConversationID = ConversationID()
    @Published private(set) var activeTurnID: TurnID?
    @Published private(set) var selectedShortcut = GlobalShortcut.default
    @Published private(set) var shortcutAvailable = true
    @Published private(set) var errorCode: String?
    @Published private(set) var focusRequest = 0
    @Published private(set) var providerProfiles: [ProviderSettingsProfile] = []
    @Published private(set) var providerStatus = "Not configured"
    @Published private(set) var codexModels: [GatewayModelChoice] = []
    @Published private(set) var codexDefaultModel = ""
    @Published private(set) var resetResults: [ResetRootResult] = []
    @Published private(set) var voiceState: LiveVoiceState
    @Published private(set) var liveTranscriptTurns: [LiveTranscriptTurn] = []
    @Published private(set) var liveVoiceMuted = false
    @Published private(set) var liveVoiceFailureCode: String?
    @Published private(set) var liveTranscriptPersistenceMessage: String?
    @Published private(set) var liveVoiceReasoningStatus: ReasoningStatus?
    @Published private(set) var voiceHistorySessions: [VoiceHistorySession] = []
    @Published private(set) var pendingVoiceHistoryAttachment:
        PreparedVoiceHistoryAttachment?
    @Published private(set) var voiceHistoryStatus: String?
    @Published private(set) var reasoningStatus: ReasoningStatus?
    @Published private(set) var pendingCapabilityApproval:
        CapabilityApprovalPresentation?
    @Published private(set) var capabilityActivityRows: [CapabilityActivityRow] = []
    @Published private(set) var liveCapabilityConfirmationMessage: String?

    private let dependencies: HostDependencies
    private let providerSettings: ProviderSettingsDependencies
    private let liveVoice: LiveVoiceDependencies
    private let liveTranscriptRecorder: LiveVoiceTranscriptRecorder
    private let voiceHistory: VoiceHistoryDependencies
    private let capabilityController: CapabilityController?
    private let prepareLiveStart: @MainActor @Sendable (
        VoiceActivationSource
    ) async -> Void
    private let liveVoiceFinished: @MainActor @Sendable () async -> Void
    private let voiceHistoryAttachmentBuilder = VoiceHistoryAttachmentBuilder()
    private var turnObservation: Task<Void, Never>?
    private var shortcutRegistration: ((GlobalShortcut) -> Bool)?
    private var liveVoiceStartPending = false
    private var liveTranscriptProjection = LiveTranscriptProjection()
    private var liveTranscriptSessionID: UUID?
    private var liveVoiceCleanupPending = false
    private var liveVoiceCleanupRetryPending = false
    private var pendingLiveTranscriptCleanup: PendingLiveTranscriptCleanup?
    private var liveVoiceCleanupWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private var typedSubmissionPending = false
    @Published private var providerMutationPending = false
    @Published private(set) var capabilitySettingsBusy = false
    @Published private var liveVoiceAvailability: LiveVoiceState
    private var liveVoiceAvailabilityGeneration: UInt64 = 0
    private var liveVoiceEventGeneration: UInt64 = 0
    private var liveEventAdmissionActive = false
    private var liveVoiceCleanupTerminalEventGeneration: UInt64?
    private var pendingVoiceCapabilityPreparation: CapabilityVoicePreparation?
    private var providerSnapshotGeneration: UInt64 = 0
    private var conversationProjectionGeneration: UInt64 = 0
    private var voiceHistoryGeneration: UInt64 = 0
    private var pendingVoiceActivationSource: VoiceActivationSource = .manual
    private var pendingLiveAdmission: LiveAdmission?
    private var liveVoiceStartGeneration: UInt64 = 0
    private var liveVoiceStartProviderInFlight = false
    private var liveVoiceStartTerminationRequested = false
    private var liveVoiceStartCancellationRequested = false
    @Published private var voiceHistoryDeletionPending = false
    @Published private var voiceHistoryExportPending = false
    private var capabilitySubscriptions = Set<AnyCancellable>()

    private struct PendingLiveTranscriptCleanup {
        let terminalState: LiveVoiceState
        let outcome: VoiceSessionTerminalOutcome
    }

    private enum LiveTranscriptCleanupAttemptResult {
        case succeeded
        case failed
        case timedOut
    }

    private static let liveTranscriptCleanupTimeout: Duration = .seconds(1)

    init(
        dependencies: HostDependencies,
        providerSettings: ProviderSettingsDependencies = .unavailable,
        liveVoice: LiveVoiceDependencies = .unavailable,
        liveTranscriptRecorder: LiveVoiceTranscriptRecorder = .init(),
        voiceHistory: VoiceHistoryDependencies = .unavailable,
        capabilityController: CapabilityController? = nil,
        prepareLiveStart: @escaping @MainActor @Sendable (
            VoiceActivationSource
        ) async -> Void = { _ in },
        liveVoiceFinished: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.dependencies = dependencies
        self.providerSettings = providerSettings
        self.liveVoice = liveVoice
        self.liveTranscriptRecorder = liveTranscriptRecorder
        self.voiceHistory = voiceHistory
        self.capabilityController = capabilityController
        self.prepareLiveStart = prepareLiveStart
        self.liveVoiceFinished = liveVoiceFinished
        voiceState = liveVoice.initialAvailability
        liveVoiceAvailability = liveVoice.initialAvailability
        if let capabilityController {
            capabilityController.$pendingApproval
                .sink { [weak self] in self?.pendingCapabilityApproval = $0 }
                .store(in: &capabilitySubscriptions)
            capabilityController.$activityRows
                .sink { [weak self] in self?.capabilityActivityRows = $0 }
                .store(in: &capabilitySubscriptions)
            capabilityController.$liveVoiceConfirmationMessage
                .sink { [weak self] in self?.liveCapabilityConfirmationMessage = $0 }
                .store(in: &capabilitySubscriptions)
            capabilityController.$settingsBusy
                .sink { [weak self] in self?.capabilitySettingsBusy = $0 }
                .store(in: &capabilitySubscriptions)
        }
    }

    func resolveCapabilityApproval(_ decision: CapabilityApprovalDecision) {
        capabilityController?.resolveApproval(decision)
    }

    func declineCapabilityApprovalForDismissal() {
        capabilityController?.declinePendingApprovals(for: .close)
    }

    var isActiveTurn: Bool {
        activeTurnID != nil
    }

    private var hasActiveConversationOrVoiceOperation: Bool {
        isActiveTurn || voiceState.isActive
            || typedSubmissionPending
            || liveVoiceStartPending || liveVoiceCleanupPending
            || voiceHistoryDeletionPending
    }

    var isActiveOperation: Bool {
        hasActiveConversationOrVoiceOperation || providerMutationPending
            || capabilitySettingsBusy
    }

    var canSubmit: Bool {
        !isActiveTurn && !voiceState.isActive
            && !typedSubmissionPending
            && !liveVoiceStartPending && !liveVoiceCleanupPending
            && !voiceHistoryDeletionPending
            && !providerMutationPending && !capabilitySettingsBusy
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canStartLiveVoice: Bool {
        [.available, .closed, .stopped, .failed].contains(voiceState)
            && liveVoiceAvailability == .available
            && !isActiveTurn && !typedSubmissionPending
            && !liveVoiceStartPending && !liveVoiceCleanupPending
            && !voiceHistoryDeletionPending
            && !providerMutationPending && !capabilitySettingsBusy
    }

    /// Presentation surfaces use this to preserve the attached WebKit peer
    /// until the same End Live Voice cleanup path has completed.
    var requiresLiveVoiceCleanupBeforeDismissal: Bool {
        voiceState.isActive || liveVoiceStartPending || liveVoiceCleanupPending
    }

    var voiceStatusText: String {
        if let liveTranscriptPersistenceMessage {
            return liveTranscriptPersistenceMessage
        }
        let state = switch voiceState {
        case .available: "Available"
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .responding: "Responding"
        case .speaking: "Speaking"
        case .stopped: "Stopped"
        case .closed: "Closed"
        case .unavailable: "Unavailable"
        case .failed: liveVoiceFailureCode.map { "Failed (\($0))" } ?? "Failed"
        }
        if liveVoiceReasoningStatus == .portableSkillsOmitted,
           voiceState.isActive
        {
            return "\(state) — some enabled skills were omitted to stay within limits"
        }
        return state
    }

    var transcriptContentChange: TranscriptContentChange {
        TranscriptContentChange(
            typedRevision: transcriptContentRevision.typed,
            liveRevision: transcriptContentRevision.live,
            voiceStatus: TranscriptVoiceStatusToken(
                state: voiceState,
                failureCode: liveVoiceFailureCode,
                persistenceFailure: liveTranscriptPersistenceMessage != nil,
                reasoningStatus: liveVoiceReasoningStatus
            )
        )
    }

    var menuState: MenuState {
        .derive(activeTurn: isActiveOperation)
    }

    var statusText: String {
        if voiceState.isActive || voiceState == .stopped || voiceState == .closed {
            return voiceStatusText
        }
        if activeTurnID != nil, let reasoningStatus {
            return switch reasoningStatus {
            case .toolsUnavailable: "Tools unavailable — continuing without them"
            case .portableSkillsOmitted: "Some enabled skills were omitted to stay within limits"
            case .portableSkillCleanupPending:
                "Private skill cleanup is pending"
            }
        }
        return switch presentationState {
        case .idle: "Idle"
        case .ready: "Ready"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .waiting: "Waiting"
        case .responding: "Responding"
        case .speaking: "Speaking"
        case .stopped: "Stopped"
        case .completed: "Completed"
        case .failed: errorCode.map { "Failed (\($0))" } ?? "Failed"
        }
    }

    func setShortcutAvailable(_ available: Bool) {
        shortcutAvailable = available
    }

    func configureShortcut(
        _ shortcut: GlobalShortcut,
        registration: @escaping (GlobalShortcut) -> Bool
    ) {
        selectedShortcut = shortcut
        shortcutRegistration = registration
    }

    func selectShortcut(_ shortcut: GlobalShortcut) {
        selectedShortcut = shortcut
        shortcutAvailable = shortcutRegistration?(shortcut) ?? false
    }

    func requestInputFocus() {
        focusRequest += 1
    }

    func refreshProviderSettings() async {
        guard !providerMutationPending else { return }
        let generation = nextProviderSnapshotGeneration()
        do {
            _ = try await loadProviderSettings(generation: generation)
        } catch {
            setProviderStatus(
                "Provider settings unavailable.",
                generation: generation
            )
        }
    }

    private func reloadProviderSettings(
        preserving status: String,
        generation: UInt64
    ) async {
        if let snapshot = try? await providerSettings.load(),
           generation == providerSnapshotGeneration
        {
            apply(snapshot)
            await capabilityController?.reconcileProviderProjection()
        }
        setProviderStatus(status, generation: generation)
    }

    func refreshLiveVoiceAvailability() async {
        await refreshLiveVoiceAvailability(
            allowStartPending: false,
            allowTypedSubmissionPending: false
        )
    }

    private func refreshLiveVoiceAvailability(
        allowStartPending: Bool,
        allowTypedSubmissionPending: Bool = false
    ) async {
        guard canRefreshLiveVoiceAvailability(
            allowStartPending: allowStartPending,
            allowTypedSubmissionPending: allowTypedSubmissionPending
        ) else { return }
        let generation = nextLiveVoiceAvailabilityGeneration()
        let availability = await liveVoice.availability()
        guard generation == liveVoiceAvailabilityGeneration,
              canRefreshLiveVoiceAvailability(
                  allowStartPending: allowStartPending,
                  allowTypedSubmissionPending: allowTypedSubmissionPending
              ) else { return }
        liveVoiceAvailability = availability
        if voiceState == .available || voiceState == .unavailable {
            voiceState = availability
        }
    }

    private func canRefreshLiveVoiceAvailability(
        allowStartPending: Bool,
        allowTypedSubmissionPending: Bool
    ) -> Bool {
        !isActiveTurn && !voiceState.isActive
            && (allowTypedSubmissionPending || !typedSubmissionPending)
            && (allowStartPending || !liveVoiceStartPending)
            && !liveVoiceCleanupPending
    }

    @discardableResult
    private func nextLiveVoiceAvailabilityGeneration() -> UInt64 {
        liveVoiceAvailabilityGeneration &+= 1
        return liveVoiceAvailabilityGeneration
    }

    @discardableResult
    private func nextLiveVoiceEventGeneration() -> UInt64 {
        liveVoiceEventGeneration &+= 1
        liveEventAdmissionActive = false
        return liveVoiceEventGeneration
    }

    @discardableResult
    private func nextProviderSnapshotGeneration() -> UInt64 {
        providerSnapshotGeneration &+= 1
        return providerSnapshotGeneration
    }

    @discardableResult
    private func nextConversationProjectionGeneration() -> UInt64 {
        conversationProjectionGeneration &+= 1
        return conversationProjectionGeneration
    }

    private func beginProviderMutation() -> UInt64 {
        nextLiveVoiceAvailabilityGeneration()
        providerMutationPending = true
        return nextProviderSnapshotGeneration()
    }

    func saveOpenAICompatibleProfile(
        profileID: UUID? = nil,
        label: String,
        endpoint: String,
        model: String,
        apiKey: String
    ) async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before editing."
            )
            return
        }
        let normalizedEndpoint: String
        do {
            normalizedEndpoint = try EndpointPolicy.normalize(endpoint)
        } catch {
            setStandaloneProviderStatus("Endpoint is not allowed.")
            return
        }
        let input = ProviderSettingsInput(
            profileID: profileID,
            label: label,
            endpoint: normalizedEndpoint,
            model: model,
            apiKey: apiKey
        )
        let hasActiveTurn = hasActiveConversationOrVoiceOperation
        let generation = beginProviderMutation()
        defer { providerMutationPending = false }
        do {
            try await providerSettings.saveOpenAICompatible(input, hasActiveTurn)
        } catch {
            await refreshLiveVoiceAvailability()
            await reloadProviderSettings(
                preserving: "Profile could not be saved.",
                generation: generation
            )
            return
        }
        await refreshLiveVoiceAvailability()
        do {
            _ = try await loadProviderSettings(generation: generation)
        } catch {
            setProviderStatus("Profile could not be saved.", generation: generation)
        }
    }

    func selectProvider(_ id: UUID) async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before switching."
            )
            return
        }
        let hasActiveTurn = hasActiveConversationOrVoiceOperation
        let generation = beginProviderMutation()
        defer { providerMutationPending = false }
        do {
            try await providerSettings.select(id, hasActiveTurn)
        } catch {
            await refreshLiveVoiceAvailability()
            await reloadProviderSettings(
                preserving: "Provider could not be selected.",
                generation: generation
            )
            return
        }
        await refreshLiveVoiceAvailability()
        do {
            _ = try await loadProviderSettings(generation: generation)
        } catch {
            setProviderStatus(
                "Provider could not be selected.",
                generation: generation
            )
        }
    }

    func selectCodexModel(_ model: String) async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before changing the model."
            )
            return
        }
        let generation = beginProviderMutation()
        defer { providerMutationPending = false }
        do {
            try await providerSettings.saveCodexModel(model)
            guard try await loadProviderSettings(generation: generation) else {
                return
            }
            if codexModels.contains(where: { $0.id == model.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                if providerStatus == "Ready — custom model availability will be confirmed on first use" {
                    setProviderStatus("Ready", generation: generation)
                }
            } else if providerStatus == "Ready" {
                setProviderStatus(
                    "Ready — custom model availability will be confirmed on first use",
                    generation: generation
                )
            }
        } catch {
            await reloadProviderSettings(
                preserving: "Codex model could not be saved.",
                generation: generation
            )
        }
    }

    func prepareCodexLogin() async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before login."
            )
            return
        }
        let hasActiveTurn = hasActiveConversationOrVoiceOperation
        let generation = beginProviderMutation()
        defer { providerMutationPending = false }
        do {
            try await providerSettings.beginCodexLogin(hasActiveTurn)
        } catch {
            await refreshLiveVoiceAvailability()
            await reloadProviderSettings(
                preserving: "Codex login could not start.",
                generation: generation
            )
            return
        }
        await refreshLiveVoiceAvailability()
        do {
            _ = try await loadProviderSettings(generation: generation)
        } catch {
            setProviderStatus("Codex login could not start.", generation: generation)
        }
    }

    func refreshCodexAuthentication() async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before refreshing."
            )
            return
        }
        let hasActiveTurn = hasActiveConversationOrVoiceOperation
        let generation = beginProviderMutation()
        defer { providerMutationPending = false }
        do {
            try await providerSettings.refreshCodexAuthentication(hasActiveTurn)
        } catch {
            await refreshLiveVoiceAvailability()
            await reloadProviderSettings(
                preserving: "Codex refresh could not complete.",
                generation: generation
            )
            return
        }
        await refreshLiveVoiceAvailability()
        do {
            _ = try await loadProviderSettings(generation: generation)
        } catch {
            setProviderStatus(
                "Codex refresh could not complete.",
                generation: generation
            )
        }
    }

    func retryProviderReadiness() async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before retrying."
            )
            return
        }
        let generation = beginProviderMutation()
        defer { providerMutationPending = false }
        do {
            let snapshot = try await providerSettings.retryReadiness()
            if apply(snapshot, generation: generation) {
                await capabilityController?.reconcileProviderProjection()
            }
        } catch {
            setProviderStatus(
                "Provider readiness check failed.",
                generation: generation
            )
        }
    }

    func localProviderLogout() async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before logout."
            )
            return
        }
        let hasActiveTurn = hasActiveConversationOrVoiceOperation
        let generation = beginProviderMutation()
        defer { providerMutationPending = false }
        do {
            try await providerSettings.localLogout(hasActiveTurn)
        } catch {
            await refreshLiveVoiceAvailability()
            await reloadProviderSettings(
                preserving: "Local logout incomplete.",
                generation: generation
            )
            return
        }
        await refreshLiveVoiceAvailability()
        do {
            guard try await loadProviderSettings(generation: generation) else {
                return
            }
            setProviderStatus(
                "Local credential removed; remote access was not revoked.",
                generation: generation
            )
        } catch {
            setProviderStatus("Local logout incomplete.", generation: generation)
        }
    }

    func deleteProvider(_ id: UUID) async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before deleting."
            )
            return
        }
        let hasActiveTurn = hasActiveConversationOrVoiceOperation
        let generation = beginProviderMutation()
        defer { providerMutationPending = false }
        do {
            try await providerSettings.delete(id, hasActiveTurn)
        } catch {
            await refreshLiveVoiceAvailability()
            await reloadProviderSettings(
                preserving: "Profile could not be deleted.",
                generation: generation
            )
            return
        }
        await refreshLiveVoiceAvailability()
        do {
            _ = try await loadProviderSettings(generation: generation)
        } catch {
            setProviderStatus("Profile could not be deleted.", generation: generation)
        }
    }

    func resetMiller() async {
        guard !isActiveOperation else {
            setStandaloneProviderStatus(
                "Finish the active response before reset."
            )
            return
        }
        _ = await performResetAndRebuild { [providerSettings] in
            await providerSettings.reset()
        }
    }

    func performManagedPrivacyReset(
        _ operation: @escaping @Sendable () async -> ResetResult
    ) async -> ResetResult {
        guard !isActiveOperation else {
            return .init(roots: [
                .init(root: "presentation.runtime_idle", succeeded: false),
            ])
        }
        return await performResetAndRebuild(operation)
    }

    private func performResetAndRebuild(
        _ operation: @escaping @Sendable () async -> ResetResult
    ) async -> ResetResult {
        let generation = beginProviderMutation()
        let projectionGeneration = nextConversationProjectionGeneration()
        voiceHistoryGeneration &+= 1
        nextLiveVoiceEventGeneration()
        defer { providerMutationPending = false }
        let result = await operation()
        clearPresentationAfterReset(
            providerGeneration: generation,
            projectionGeneration: projectionGeneration
        )
        await refreshLiveVoiceAvailability()
        do {
            _ = apply(
                try await providerSettings.load(),
                generation: generation
            )
        } catch {
            clearProviderSnapshot(generation: generation)
        }
        await capabilityController?.reconcileProviderProjection()
        await rebuildPresentationAfterReset(generation: projectionGeneration)
        resetResults = result.roots
        setProviderStatus(
            result.failures.isEmpty
                ? "Reset completed; secure erasure is not claimed."
                : "Reset incomplete; review failed roots.",
            generation: generation
        )
        return result
    }

    func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeTurnID == nil, !voiceState.isActive,
              !typedSubmissionPending,
              !liveVoiceStartPending, !liveVoiceCleanupPending,
              !voiceHistoryDeletionPending,
              !providerMutationPending, !capabilitySettingsBusy else {
            return
        }
        nextLiveVoiceAvailabilityGeneration()
        typedSubmissionPending = true
        defer {
            if typedSubmissionPending {
                typedSubmissionPending = false
            }
        }
        let voiceHistoryAttachment: VoiceHistoryAttachment?
        if let pendingVoiceHistoryAttachment {
            let generation = voiceHistoryGeneration
            do {
                let refreshed = try await preparedVoiceHistoryAttachment(
                    sessionIDs: pendingVoiceHistoryAttachment.sessionIDs
                )
                guard generation == voiceHistoryGeneration,
                      self.pendingVoiceHistoryAttachment?.sessionIDs
                        == pendingVoiceHistoryAttachment.sessionIDs
                else { return }
                voiceHistoryAttachment = refreshed.attachment
            } catch {
                guard generation == voiceHistoryGeneration,
                      self.pendingVoiceHistoryAttachment?.sessionIDs
                        == pendingVoiceHistoryAttachment.sessionIDs
                else { return }
                self.pendingVoiceHistoryAttachment = nil
                voiceHistoryStatus = "Selected voice history is no longer available."
                return
            }
        } else {
            voiceHistoryAttachment = nil
        }
        pendingVoiceHistoryAttachment = nil
        voiceHistoryGeneration &+= 1
        voiceHistoryStatus = nil
        draft = ""
        presentationState = .waiting
        errorCode = nil
        reasoningStatus = nil
        do {
            let turnID = try await dependencies.submit(
                text,
                selectedConversationID,
                voiceHistoryAttachment
            )
            activeTurnID = turnID
            typedSubmissionPending = false
            voiceState = .unavailable
            observe(turnID)
            await refresh()
        } catch {
            presentationState = .failed
            errorCode = Self.code(for: error)
            await refreshLiveVoiceAvailability(
                allowStartPending: false,
                allowTypedSubmissionPending: true
            )
        }
    }

    func refreshVoiceHistory(
        from start: Date? = nil,
        through end: Date? = nil
    ) async {
        guard canBeginVoiceHistoryRead else { return }
        let generation = voiceHistoryGeneration
        do {
            let sessions = try await voiceHistory.sessions(start, end)
            guard generation == voiceHistoryGeneration else { return }
            voiceHistorySessions = sessions
            voiceHistoryStatus = nil
        } catch {
            guard generation == voiceHistoryGeneration else { return }
            voiceHistorySessions = []
            voiceHistoryStatus = "Voice history is unavailable."
        }
    }

    func prepareVoiceHistoryAttachment(sessionIDs: [UUID]) async {
        guard canBeginVoiceHistoryRead else { return }
        voiceHistoryGeneration &+= 1
        let generation = voiceHistoryGeneration
        do {
            let prepared = try await preparedVoiceHistoryAttachment(
                sessionIDs: sessionIDs
            )
            guard generation == voiceHistoryGeneration else { return }
            pendingVoiceHistoryAttachment = prepared
            voiceHistoryStatus = pendingVoiceHistoryAttachment?.truncated == true
                ? "Selection was truncated to 32 KiB."
                : nil
        } catch {
            guard generation == voiceHistoryGeneration else { return }
            pendingVoiceHistoryAttachment = nil
            voiceHistoryStatus = "Selected voice history is no longer available."
        }
    }

    func prepareVoiceHistoryAttachment(from start: Date, through end: Date) async {
        guard canBeginVoiceHistoryRead else { return }
        voiceHistoryGeneration &+= 1
        let generation = voiceHistoryGeneration
        do {
            let projection = try await voiceHistory.rangeAttachmentProjection(
                start, end, VoiceHistoryAttachmentBuilder.maximumBytes
            )
            let prepared = try voiceHistoryAttachmentBuilder.build(from: projection)
            guard generation == voiceHistoryGeneration else { return }
            pendingVoiceHistoryAttachment = prepared
            voiceHistoryStatus = prepared.truncated ? "Selection was truncated to 32 KiB." : nil
        } catch {
            guard generation == voiceHistoryGeneration else { return }
            pendingVoiceHistoryAttachment = nil
            voiceHistoryStatus = "Selected voice history is no longer available."
        }
    }

    func cancelVoiceHistoryAttachment() {
        voiceHistoryGeneration &+= 1
        pendingVoiceHistoryAttachment = nil
        voiceHistoryStatus = nil
    }

    func exportVoiceHistory(sessionIDs: [UUID], to url: URL) async {
        do {
            try await performVoiceHistoryExport(to: url) {
                try await self.checkedProjection(sessionIDs: sessionIDs)
            }
            voiceHistoryStatus = "Voice history exported."
        } catch {
            voiceHistoryStatus = "Voice history export failed."
        }
    }

    func exportVoiceHistory(from start: Date, through end: Date, to url: URL) async {
        do {
            try await performVoiceHistoryExport(to: url) {
                let sessions = try await self.voiceHistory.sessions(start, end)
                return try await self.checkedProjection(
                    sessionIDs: sessions.map(\.id)
                )
            }
            voiceHistoryStatus = "Voice history exported."
        } catch {
            voiceHistoryStatus = "Voice history export failed."
        }
    }

    func exportAllVoiceHistoryFromSettings(to url: URL) async throws {
        try await performVoiceHistoryExport(to: url) {
            let sessions = try await self.voiceHistory.sessions(nil, nil)
            guard !sessions.isEmpty else { return [] }
            return try await self.checkedProjection(
                sessionIDs: sessions.map(\.id)
            )
        }
    }

    func deleteVoiceHistorySession(_ id: UUID) async {
        guard beginVoiceHistoryDeletion() else {
            voiceHistoryStatus = "Voice history deletion unavailable while Miller is active."
            return
        }
        defer { voiceHistoryDeletionPending = false }
        do {
            try await voiceHistory.deleteSession(id)
            clearPendingVoiceHistory(ifItContains: [id])
            clearLiveTranscriptProjection(ifItContains: [id])
            voiceHistoryDeletionPending = false
            await refreshVoiceHistory()
        } catch {
            voiceHistoryStatus = "Voice history deletion failed."
        }
    }

    func deleteVoiceHistory(from start: Date, through end: Date) async {
        guard beginVoiceHistoryDeletion() else {
            voiceHistoryStatus = "Voice history deletion unavailable while Miller is active."
            return
        }
        defer { voiceHistoryDeletionPending = false }
        do {
            let deleted = try await voiceHistory.sessions(start, end).map(\.id)
            try await voiceHistory.deleteRange(start, end)
            clearPendingVoiceHistory(ifItContains: deleted)
            clearLiveTranscriptProjection(ifItContains: deleted)
            voiceHistoryDeletionPending = false
            await refreshVoiceHistory()
        } catch {
            voiceHistoryStatus = "Voice history deletion failed."
        }
    }

    func deleteAllVoiceHistory() async {
        guard beginVoiceHistoryDeletion() else {
            voiceHistoryStatus = "Voice history deletion unavailable while Miller is active."
            return
        }
        defer { voiceHistoryDeletionPending = false }
        do {
            try await voiceHistory.deleteAll()
            pendingVoiceHistoryAttachment = nil
            clearLiveTranscriptProjection()
            voiceHistoryDeletionPending = false
            await refreshVoiceHistory()
        } catch {
            voiceHistoryStatus = "Voice history deletion failed."
        }
    }

    func deleteAllVoiceHistoryFromSettings() async throws {
        guard beginVoiceHistoryDeletion() else {
            throw VoiceHistoryMutationError.busy
        }
        defer { voiceHistoryDeletionPending = false }
        try await voiceHistory.deleteAll()
        pendingVoiceHistoryAttachment = nil
        clearLiveTranscriptProjection()
        voiceHistoryDeletionPending = false
        await refreshVoiceHistory()
    }

    private func beginVoiceHistoryDeletion() -> Bool {
        guard !isActiveTurn,
              !voiceState.isActive,
              !typedSubmissionPending,
              !liveVoiceStartPending,
              !liveVoiceCleanupPending,
              !voiceHistoryDeletionPending,
              !providerMutationPending,
              !capabilitySettingsBusy
        else { return false }
        voiceHistoryDeletionPending = true
        voiceHistoryGeneration &+= 1
        nextLiveVoiceEventGeneration()
        return true
    }

    private var canBeginVoiceHistoryRead: Bool {
        !voiceHistoryDeletionPending
            && !providerMutationPending
            && !capabilitySettingsBusy
    }

    private func performVoiceHistoryExport(
        to url: URL,
        projection: () async throws -> [VoiceHistoryExportSession]
    ) async throws {
        guard canBeginVoiceHistoryRead, !voiceHistoryExportPending,
              !isActiveTurn, !voiceState.isActive,
              !typedSubmissionPending, !liveVoiceStartPending,
              !liveVoiceCleanupPending
        else { throw VoiceHistoryMutationError.busy }
        voiceHistoryExportPending = true
        let generation = voiceHistoryGeneration
        defer { voiceHistoryExportPending = false }
        let value = try await projection()
        guard generation == voiceHistoryGeneration,
              !voiceHistoryDeletionPending,
              !providerMutationPending
        else { throw VoiceHistoryMutationError.busy }
        try VoiceHistoryExportDocument.write(value, to: url)
    }

    private func preparedVoiceHistoryAttachment(
        sessionIDs: [UUID]
    ) async throws -> PreparedVoiceHistoryAttachment {
        let unique = Array(Set(sessionIDs))
        guard !unique.isEmpty else { throw VoiceHistoryAttachmentBuilderError.emptySelection }
        let projection = try await voiceHistory.attachmentProjection(
            unique, VoiceHistoryAttachmentBuilder.maximumBytes
        )
        guard projection.selectionIsValid,
              Set(projection.sessionIDs) == Set(unique)
        else {
            throw VoiceHistoryAttachmentBuilderError.selectedHistoryUnavailable
        }
        return try voiceHistoryAttachmentBuilder.build(from: projection)
    }

    private func checkedProjection(
        sessionIDs: [UUID]
    ) async throws -> [VoiceHistoryExportSession] {
        let unique = Array(Set(sessionIDs))
        guard !unique.isEmpty else {
            throw VoiceHistoryAttachmentBuilderError.emptySelection
        }
        let projection = try await voiceHistory.exportProjection(unique)
        guard Set(projection.map(\.session.id)) == Set(unique) else {
            throw VoiceHistoryAttachmentBuilderError.selectedHistoryUnavailable
        }
        return projection
    }

    private func clearPendingVoiceHistory(ifItContains ids: [UUID]) {
        guard let pendingVoiceHistoryAttachment,
              !Set(pendingVoiceHistoryAttachment.sessionIDs).isDisjoint(with: ids)
        else { return }
        self.pendingVoiceHistoryAttachment = nil
    }

    private func clearLiveTranscriptProjection(ifItContains ids: [UUID]? = nil) {
        if let ids {
            guard let liveTranscriptSessionID, ids.contains(liveTranscriptSessionID)
            else { return }
        }
        resetLiveTranscripts()
    }

    func startLiveVoice(
        activationSource: VoiceActivationSource = .manual,
        preparedAudio: WakeWordPreparedCommandAudio? = nil
    ) async {
        guard canStartLiveVoice else {
            if activationSource == .wakeword { await liveVoiceFinished() }
            return
        }
        await prepareLiveStart(activationSource)
        guard canStartLiveVoice else {
            if activationSource == .wakeword { await liveVoiceFinished() }
            return
        }
        liveVoiceStartPending = true
        liveVoiceStartCancellationRequested = false
        liveVoiceStartTerminationRequested = false
        liveVoiceStartProviderInFlight = false
        let startGeneration = nextLiveVoiceStartGeneration()
        defer {
            liveVoiceStartPending = false
            liveVoiceStartProviderInFlight = false
            if liveVoiceStartGeneration == startGeneration {
                liveVoiceStartCancellationRequested = false
                liveVoiceStartTerminationRequested = false
            }
        }
        do {
            let admission = try await dependencies.admitLive(
                conversationID: selectedConversationID,
                activationSource: activationSource
            )
            guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled else {
                await abortLiveVoiceStart(startGeneration: startGeneration)
                await admission.release()
                return
            }
            pendingLiveAdmission = admission
            pendingVoiceActivationSource = admission.activationSource
        } catch {
            guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled else {
                await abortLiveVoiceStart(startGeneration: startGeneration)
                return
            }
            await releasePendingLiveAdmission()
            voiceState = .failed
            liveVoiceFailureCode = Self.liveFailureCode(error)
            return
        }
        if let capabilityController {
            guard let profileID = providerProfiles.first(where: \.isSelected)?.id
            else {
                await releasePendingLiveAdmission()
                return
            }
            do {
                pendingVoiceCapabilityPreparation = try await capabilityController
                    .prepareLiveVoice(providerProfileID: profileID)
                guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled else {
                    await abortLiveVoiceStart(startGeneration: startGeneration)
                    return
                }
            } catch {
                guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled else {
                    await abortLiveVoiceStart(startGeneration: startGeneration)
                    return
                }
                pendingVoiceCapabilityPreparation = nil
                voiceState = .failed
                liveVoiceFailureCode = "capability_bridge_unavailable"
                await releasePendingLiveAdmission()
                return
            }
        }
        guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled else {
            await abortLiveVoiceStart(startGeneration: startGeneration)
            return
        }
        nextLiveVoiceAvailabilityGeneration()
        let eventGeneration = nextLiveVoiceEventGeneration()
        liveEventAdmissionActive = true
        liveVoiceCleanupTerminalEventGeneration = nil
        voiceState = .connecting
        liveVoiceFailureCode = nil
        liveVoiceReasoningStatus = nil
        liveTranscriptPersistenceMessage = nil
        resetLiveTranscripts()
        liveVoiceMuted = false
        do {
            liveVoiceStartProviderInFlight = true
            try await withTaskCancellationHandler {
                let receive: @MainActor @Sendable (LiveVoiceEvent) async -> Void = {
                    [weak self] event in
                    await self?.applyLiveEvent(event, generation: eventGeneration)
                }
                if let preparedAudio {
                    try await liveVoice.startPrepared(preparedAudio, receive)
                } else {
                    try await liveVoice.start(receive)
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.cancelLiveVoiceStart(generation: startGeneration)
                }
            }
            liveVoiceStartProviderInFlight = false
            guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled else {
                await terminateLiveVoiceProviderIfNeeded()
                await abortLiveVoiceStart(startGeneration: startGeneration)
                return
            }
        } catch {
            liveVoiceStartProviderInFlight = false
            guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled,
                  !(error is CancellationError)
            else {
                await terminateLiveVoiceProviderIfNeeded()
                await abortLiveVoiceStart(startGeneration: startGeneration)
                return
            }
            pendingVoiceCapabilityPreparation = nil
            await capabilityController?.finishLiveVoice()
            guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled else {
                await terminateLiveVoiceProviderIfNeeded()
                await abortLiveVoiceStart(startGeneration: startGeneration)
                return
            }
            voiceState = .failed
            liveVoiceFailureCode = Self.liveFailureCode(error)
            if Self.isLiveAdmissionFailure(error) {
                nextLiveVoiceAvailabilityGeneration()
                liveVoiceAvailability = .unavailable
            }
        }
        if !liveVoiceCleanupPending, !voiceState.isActive {
            let outcome: VoiceSessionTerminalOutcome =
                voiceState == .failed ? .failed
                : voiceState == .closed ? .completed : .abandoned
            await finishLiveVoiceCleanup(
                terminalState: voiceState,
                outcome: outcome
            )
        }
        guard isCurrentLiveVoiceStart(startGeneration), !Task.isCancelled else {
            return
        }
        if !voiceState.isActive, liveVoiceAvailability == .available {
            await refreshLiveVoiceAvailability(allowStartPending: true)
        }
    }

    @discardableResult
    private func nextLiveVoiceStartGeneration() -> UInt64 {
        liveVoiceStartGeneration &+= 1
        return liveVoiceStartGeneration
    }

    private func isCurrentLiveVoiceStart(_ generation: UInt64) -> Bool {
        generation == liveVoiceStartGeneration
            && !liveVoiceStartCancellationRequested
    }

    private func abortLiveVoiceStart(startGeneration: UInt64) async {
        if startGeneration == liveVoiceStartGeneration {
            liveVoiceStartCancellationRequested = true
            _ = nextLiveVoiceStartGeneration()
            nextLiveVoiceEventGeneration()
        }
        pendingVoiceCapabilityPreparation = nil
        await capabilityController?.finishLiveVoice()
        await releasePendingLiveAdmission()
        if !liveVoiceCleanupPending, liveTranscriptSessionID != nil {
            await finishLiveVoiceCleanup(
                terminalState: .closed,
                outcome: .abandoned
            )
        } else if !liveVoiceCleanupPending, voiceState.isActive {
            voiceState = .closed
        }
    }

    private func cancelLiveVoiceStart(generation: UInt64) async {
        guard generation == liveVoiceStartGeneration,
              liveVoiceStartPending
        else { return }
        liveVoiceStartCancellationRequested = true
        _ = nextLiveVoiceStartGeneration()
        nextLiveVoiceEventGeneration()
        liveVoiceCleanupTerminalEventGeneration = nil
        await releasePendingLiveAdmission()
        if liveVoiceStartProviderInFlight || voiceState.isActive {
            await terminateLiveVoiceProviderIfNeeded()
        }
    }

    private func terminateLiveVoiceProviderIfNeeded() async {
        guard !liveVoiceStartTerminationRequested else { return }
        liveVoiceStartTerminationRequested = true
        await liveVoice.end()
    }

    func shutdownLiveVoice() async {
        let hadLiveWork = liveVoiceStartPending || voiceState.isActive
            || liveVoiceCleanupPending || pendingLiveAdmission != nil
            || liveTranscriptSessionID != nil
        if liveVoiceStartPending {
            await cancelLiveVoiceStart(generation: liveVoiceStartGeneration)
        } else {
            nextLiveVoiceEventGeneration()
            liveVoiceCleanupTerminalEventGeneration = nil
        }
        if liveVoiceStartProviderInFlight || voiceState.isActive {
            await terminateLiveVoiceProviderIfNeeded()
        }
        if liveVoiceCleanupPending {
            if liveVoiceCleanupRetryPending,
               let cleanup = pendingLiveTranscriptCleanup {
                await finishLiveVoiceCleanup(
                    terminalState: cleanup.terminalState,
                    outcome: cleanup.outcome
                )
            } else if pendingLiveTranscriptCleanup == nil {
                await finishLiveVoiceCleanup(
                    terminalState: .closed,
                    outcome: .abandoned
                )
            } else {
                await waitForLiveVoiceCleanup()
            }
        } else if hadLiveWork {
            await finishLiveVoiceCleanup(
                terminalState: .closed,
                outcome: .abandoned
            )
        }
    }

    func toggleLiveMute() async {
        guard voiceState.isActive else { return }
        liveVoiceMuted.toggle()
        await liveVoice.mute(liveVoiceMuted)
    }

    func interruptLiveVoice() async {
        guard voiceState.isActive, !liveVoiceCleanupPending else { return }
        capabilityController?.declinePendingApprovals(for: .interrupt)
        nextLiveVoiceAvailabilityGeneration()
        let terminalEventGeneration = liveVoiceEventGeneration
        nextLiveVoiceEventGeneration()
        liveVoiceCleanupTerminalEventGeneration = terminalEventGeneration
        liveVoiceCleanupPending = true
        await liveVoice.interrupt()
        await finishLiveVoiceCleanup(
            terminalState: .stopped,
            outcome: voiceState == .failed ? .failed : .stopped
        )
        await refreshLiveVoiceAvailability(allowStartPending: true)
    }

    func endLiveVoice() async {
        if liveVoiceCleanupPending {
            if liveVoiceCleanupRetryPending,
               let cleanup = pendingLiveTranscriptCleanup {
                await finishLiveVoiceCleanup(
                    terminalState: cleanup.terminalState,
                    outcome: cleanup.outcome
                )
            } else {
                await waitForLiveVoiceCleanup()
            }
            return
        }
        guard voiceState.isActive || voiceState == .stopped || liveVoiceStartPending else {
            return
        }
        capabilityController?.declinePendingApprovals(for: .close)
        nextLiveVoiceAvailabilityGeneration()
        let terminalEventGeneration = liveVoiceEventGeneration
        nextLiveVoiceEventGeneration()
        liveVoiceCleanupTerminalEventGeneration = terminalEventGeneration
        liveVoiceCleanupPending = true
        await liveVoice.end()
        await finishLiveVoiceCleanup(
            terminalState: .closed,
            outcome: voiceState == .failed ? .failed : .completed
        )
        await refreshLiveVoiceAvailability(allowStartPending: true)
    }

    private func waitForLiveVoiceCleanup() async {
        await withCheckedContinuation { liveVoiceCleanupWaiters.append($0) }
    }

    private func finishLiveVoiceCleanup(
        terminalState: LiveVoiceState,
        outcome: VoiceSessionTerminalOutcome
    ) async {
        nextLiveVoiceEventGeneration()
        let cleanup = pendingLiveTranscriptCleanup
            ?? PendingLiveTranscriptCleanup(
                terminalState: terminalState,
                outcome: outcome
            )
        pendingLiveTranscriptCleanup = cleanup
        liveVoiceCleanupPending = true
        let retryingCleanup = liveVoiceCleanupRetryPending
        liveVoiceCleanupRetryPending = false
        var cleanupSucceeded = false
        var cleanupTimedOut = false
        for attempt in 0..<2 {
            switch await finishRecorderWithinBound(outcome: cleanup.outcome) {
            case .succeeded:
                cleanupSucceeded = true
            case .failed:
                guard attempt == 0 else { continue }
            case .timedOut:
                cleanupTimedOut = true
            }
            if cleanupSucceeded || cleanupTimedOut {
                break
            }
        }
        if cleanupSucceeded {
            if retryingCleanup {
                liveTranscriptPersistenceMessage = nil
            }
            pendingLiveTranscriptCleanup = nil
            liveVoiceCleanupPending = false
            await releasePendingLiveAdmission()
        } else {
            presentTranscriptPersistenceFailure()
            liveVoiceCleanupRetryPending = true
            await releasePendingLiveAdmission()
        }
        liveVoiceMuted = false
        if voiceState != .failed {
            voiceState = cleanup.terminalState
        }
        let waiters = liveVoiceCleanupWaiters
        liveVoiceCleanupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        pendingVoiceCapabilityPreparation = nil
        await capabilityController?.finishLiveVoice()
        liveVoiceCleanupTerminalEventGeneration = nil
        if cleanupSucceeded {
            await liveVoiceFinished()
        }
    }

    private func finishRecorderWithinBound(
        outcome: VoiceSessionTerminalOutcome
    ) async -> LiveTranscriptCleanupAttemptResult {
        let (stream, continuation) = AsyncStream<LiveTranscriptCleanupAttemptResult>
            .makeStream()
        let tasks = LiveTranscriptCleanupTasks()
        let cleanupTask = Task.detached { [liveTranscriptRecorder] in
            do {
                try await liveTranscriptRecorder.finish(outcome: outcome)
                continuation.yield(.succeeded)
            } catch {
                continuation.yield(.failed)
            }
            continuation.finish()
        }
        let timeoutTask = Task.detached { [timeout = Self.liveTranscriptCleanupTimeout] in
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(.timedOut)
                continuation.finish()
            } catch {
            }
        }
        tasks.add(cleanupTask)
        tasks.add(timeoutTask)
        let result = await withTaskCancellationHandler {
            await stream.first(where: { @Sendable _ in true }) ?? .timedOut
        } onCancel: {
            tasks.cancel()
            continuation.yield(.timedOut)
            continuation.finish()
        }
        tasks.cancel()
        continuation.finish()
        return result
    }

    private func releasePendingLiveAdmission() async {
        guard let admission = pendingLiveAdmission else { return }
        pendingLiveAdmission = nil
        await admission.release()
    }

    func applyLiveEvent(_ event: LiveVoiceEvent) async {
        guard liveVoiceEventGeneration == 0 || liveEventAdmissionActive else {
            return
        }
        if liveVoiceEventGeneration == 0 {
            liveEventAdmissionActive = true
        }
        await applyLiveEvent(event, generation: liveVoiceEventGeneration)
    }

    private func applyLiveEvent(
        _ event: LiveVoiceEvent,
        generation: UInt64
    ) async {
        let terminalCleanupEvent = switch event {
        case .state(.closed), .state(.stopped), .state(.failed), .failed:
            true
        default:
            false
        }
        guard (generation == liveVoiceEventGeneration && liveEventAdmissionActive)
                || (liveVoiceCleanupPending
                    && liveVoiceCleanupTerminalEventGeneration == generation
                    && terminalCleanupEvent)
        else { return }
        switch event {
        case let .sessionAdmitted(id):
            do {
                if let capabilityController {
                    guard let preparation = pendingVoiceCapabilityPreparation else {
                        throw CapabilityControllerError.staleGeneration
                    }
                    try capabilityController.admitVoiceAssociation(
                        sessionID: id,
                        preparation: preparation
                    )
                    pendingVoiceCapabilityPreparation = nil
                }
            } catch {
                pendingVoiceCapabilityPreparation = nil
                voiceState = .failed
                liveVoiceFailureCode = "capability_bridge_unavailable"
                await capabilityController?.finishLiveVoice()
                Task { [liveVoice] in await liveVoice.end() }
                return
            }
            do {
                try await liveTranscriptRecorder.begin(
                    sessionID: id,
                    conversationID: pendingLiveAdmission?.conversationID,
                    activationSource: pendingLiveAdmission?.activationSource
                        ?? pendingVoiceActivationSource
                )
            } catch {
                guard generation == liveVoiceEventGeneration else { return }
                presentTranscriptPersistenceFailure()
            }
            guard generation == liveVoiceEventGeneration else { return }
            liveTranscriptSessionID = id
        case let .state(state):
            if state == .closed || state == .stopped || state == .failed {
                nextLiveVoiceEventGeneration()
            }
            voiceState = state
        case .transcriptDelta, .transcriptDone:
            var persistenceFailed = false
            do {
                try await liveTranscriptRecorder.record(event)
            } catch {
                persistenceFailed = true
            }
            guard generation == liveVoiceEventGeneration else { return }
            if persistenceFailed { presentTranscriptPersistenceFailure() }
            liveTranscriptProjection.record(event)
            publishLiveTranscriptTurns(liveTranscriptProjection.turns)
        case let .status(status):
            liveVoiceReasoningStatus = status
        case let .failed(code):
            nextLiveVoiceEventGeneration()
            liveVoiceFailureCode = Self.sanitizedLiveCode(code)
            voiceState = .failed
        }
    }

    func recoverInterruptedVoiceSessions() async {
        do {
            try await liveTranscriptRecorder.recoverInterruptedSessions()
        } catch {
            presentTranscriptPersistenceFailure()
        }
    }

    func abandonLiveVoiceSession() async {
        await finishLiveVoiceCleanup(
            terminalState: .closed,
            outcome: .abandoned
        )
    }

    func prepareToAbandonLiveVoiceSession() {
        if liveVoiceStartPending {
            liveVoiceStartCancellationRequested = true
            _ = nextLiveVoiceStartGeneration()
        }
        nextLiveVoiceEventGeneration()
        liveVoiceCleanupPending = true
    }

    private func presentTranscriptPersistenceFailure() {
        liveTranscriptPersistenceMessage = "Transcript could not be saved"
    }

    func stop() async {
        guard activeTurnID != nil else {
            return
        }
        do {
            capabilityController?.declinePendingApprovals(for: .interrupt)
            try await dependencies.stop()
            activeTurnID = nil
            reasoningStatus = nil
            turnObservation?.cancel()
            presentationState = .stopped
            await refresh()
            await refreshLiveVoiceAvailability()
        } catch {
            presentationState = .failed
            errorCode = Self.code(for: error)
        }
    }

    func newConversation() {
        guard !isActiveOperation else {
            return
        }
        capabilityController?.declinePendingApprovals(for: .close)
        nextConversationProjectionGeneration()
        selectedConversationID = ConversationID()
        publishVisibleTurns([])
        draft = ""
        presentationState = .ready
        errorCode = nil
        reasoningStatus = nil
        requestInputFocus()
    }

    func selectConversation(_ id: ConversationID) async {
        guard !isActiveOperation else {
            return
        }
        let generation = nextConversationProjectionGeneration()
        selectedConversationID = id
        await refreshTurns(generation: generation)
        requestInputFocus()
    }

    func archiveSelected() async {
        guard !isActiveOperation else { return }
        do {
            try await dependencies.archive(selectedConversationID)
            newConversation()
            await refresh()
        } catch {
            fail(error)
        }
    }

    func unarchiveSelected() async {
        guard !isActiveOperation else { return }
        do {
            try await dependencies.unarchive(selectedConversationID)
            await refresh()
        } catch {
            fail(error)
        }
    }

    func deleteSelected() async {
        guard !isActiveOperation else { return }
        do {
            try await dependencies.delete(selectedConversationID)
            newConversation()
            await refresh()
        } catch {
            fail(error)
        }
    }

    func refresh() async {
        guard !providerMutationPending else { return }
        let generation = nextConversationProjectionGeneration()
        do {
            let loaded = ConversationListItem.ordered(
                try await dependencies.loadConversations().map(ConversationListItem.init)
            )
            guard generation == conversationProjectionGeneration else { return }
            conversations = loaded
            await refreshTurns(generation: generation)
        } catch {
            guard generation == conversationProjectionGeneration else { return }
            fail(error)
        }
    }

    private func refreshTurns(generation: UInt64) async {
        let conversationID = selectedConversationID
        do {
            let loaded = try await dependencies.loadTurns(conversationID)
            guard generation == conversationProjectionGeneration,
                  conversationID == selectedConversationID else { return }
            publishVisibleTurns(loaded)
        } catch {
            guard generation == conversationProjectionGeneration,
                  conversationID == selectedConversationID else { return }
            fail(error)
        }
    }

    private func observe(_ turnID: TurnID) {
        turnObservation?.cancel()
        turnObservation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let status = await dependencies.reasoningStatus()
                    if activeTurnID == turnID {
                        reasoningStatus = status
                    }
                    if let turn = try await dependencies.loadTurn(turnID) {
                        await apply(turn)
                        if turn.state.isTerminal {
                            return
                        }
                    }
                } catch {
                    fail(error)
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private func apply(_ turn: Turn) async {
        presentationState = PresentationDerivation.state(for: turn)
        if turn.state.isTerminal {
            activeTurnID = nil
            reasoningStatus = nil
            if turn.state == .failed {
                errorCode = turn.errorCode
            }
        }
        await refresh()
        if turn.state.isTerminal {
            await refreshLiveVoiceAvailability()
        }
    }

    private func fail(_ error: Error) {
        presentationState = .failed
        errorCode = Self.code(for: error)
    }

    private func apply(_ snapshot: ProviderSettingsSnapshot) {
        providerProfiles = snapshot.profiles
        providerStatus = snapshot.readiness
        codexModels = snapshot.codexModels
        codexDefaultModel = snapshot.codexDefaultModel
    }

    private func rebuildPresentationAfterReset(generation: UInt64) async {
        guard generation == conversationProjectionGeneration else { return }
        do {
            let loaded = ConversationListItem.ordered(
                try await dependencies.loadConversations().map(
                    ConversationListItem.init
                )
            )
            guard generation == conversationProjectionGeneration else { return }
            conversations = loaded
        } catch {
            guard generation == conversationProjectionGeneration else { return }
            conversations = []
        }
        do {
            let loaded = try await dependencies.loadTurns(
                selectedConversationID
            )
            guard generation == conversationProjectionGeneration else { return }
            publishVisibleTurns(loaded)
        } catch {
            guard generation == conversationProjectionGeneration else { return }
            publishVisibleTurns([])
        }
    }

    private func clearPresentationAfterReset(
        providerGeneration: UInt64,
        projectionGeneration: UInt64
    ) {
        clearProviderSnapshot(generation: providerGeneration)
        guard projectionGeneration == conversationProjectionGeneration else {
            return
        }
        voiceHistoryGeneration &+= 1
        nextLiveVoiceEventGeneration()
        turnObservation?.cancel()
        turnObservation = nil
        activeTurnID = nil
        selectedConversationID = ConversationID()
        draft = ""
        presentationState = .ready
        errorCode = nil
        reasoningStatus = nil
        conversations = []
        publishVisibleTurns([])
        voiceHistorySessions = []
        pendingVoiceHistoryAttachment = nil
        voiceHistoryStatus = nil
        resetLiveTranscripts()
        liveVoiceFailureCode = nil
        liveTranscriptPersistenceMessage = nil
        liveVoiceMuted = false
        voiceState = liveVoiceAvailability
    }

    private func loadProviderSettings(generation: UInt64) async throws -> Bool {
        let applied = apply(
            try await providerSettings.load(),
            generation: generation
        )
        if applied {
            await capabilityController?.reconcileProviderProjection()
        }
        return applied
    }

    @discardableResult
    private func apply(
        _ snapshot: ProviderSettingsSnapshot,
        generation: UInt64
    ) -> Bool {
        guard generation == providerSnapshotGeneration else { return false }
        apply(snapshot)
        return true
    }

    private func setProviderStatus(_ status: String, generation: UInt64) {
        guard generation == providerSnapshotGeneration else { return }
        providerStatus = status
    }

    private func setStandaloneProviderStatus(_ status: String) {
        setProviderStatus(
            status,
            generation: providerMutationPending
                ? providerSnapshotGeneration
                : nextProviderSnapshotGeneration()
        )
    }

    private func clearProviderSnapshot(generation: UInt64) {
        guard generation == providerSnapshotGeneration else { return }
        providerProfiles = []
        codexModels = []
        codexDefaultModel = ""
    }

    private static func code(for error: Error) -> String {
        if let core = error as? CoreError {
            switch core {
            case .turnAlreadyActive: return "turn_already_active"
            case .requestTooLarge: return "request_too_large"
            case .storageUnavailable: return "storage_unavailable"
            default: return "failed"
            }
        }
        return "failed"
    }

    private func resetLiveTranscripts() {
        liveTranscriptProjection.reset()
        publishLiveTranscriptTurns(liveTranscriptProjection.turns)
        liveTranscriptSessionID = nil
    }

    private func publishVisibleTurns(_ turns: [Turn]) {
        guard visibleTurns != turns else { return }
        let displayedContentChanged = TranscriptDisplayedContent.typedChanged(
            from: visibleTurns,
            to: turns
        )
        visibleTurns = turns
        if displayedContentChanged {
            transcriptContentRevision.advance(typedContentChanged: true)
        }
    }

    private func publishLiveTranscriptTurns(_ turns: [LiveTranscriptTurn]) {
        guard liveTranscriptTurns != turns else { return }
        let displayedContentChanged = TranscriptDisplayedContent.liveChanged(
            from: liveTranscriptTurns,
            to: turns
        )
        liveTranscriptTurns = turns
        if displayedContentChanged {
            transcriptContentRevision.advance(liveContentChanged: true)
        }
    }

    private static func liveFailureCode(_ error: Error) -> String {
        if (error as? GPTLiveSkillProjectionError) == .cleanupPending {
            return "cleanup_pending"
        }
        if error is LiveAdmissionError { return "voice_unavailable" }
        if error is GPTLiveCredentialError { return "voice_unavailable" }
        if let audio = error as? LiveAudioError {
            switch audio {
            case .permissionDenied: return "microphone_denied"
            case .audioBackpressure: return "audio_backpressure"
            case .captureFailed: return "capture_failed"
            case .microphoneUnavailable: return "device_unavailable"
            case .playbackFailed: return "playback_failed"
            default: return "voice_failed"
            }
        }
        if let client = error as? CodexAppServerClientError {
            switch client {
            case .audioBackpressure: return "audio_backpressure"
            case .credentialRejected, .refreshUnavailable: return "credential_rejected"
            case .initializeProtocolMismatch: return "protocol_initialize_mismatch"
            case .loginProtocolMismatch: return "protocol_login_mismatch"
            case let .loginFrameProtocolMismatch(kind, reason):
                return Self.loginFrameFailureCode(kind, reason)
            case .loginSequenceProtocolMismatch: return "protocol_login_sequence_mismatch"
            case .missingTerminal, .unexpectedMessage, .wrongResponse:
                return "protocol_mismatch"
            case .realtimeStartProtocolMismatch: return "protocol_realtime_mismatch"
            case let .realtimeStartDiagnostic(diagnostic): return diagnostic.rawValue
            case .sessionAlreadyActive: return "voice_unavailable"
            case .timeout: return "voice_timeout"
            case .sessionFailed: return "provider_failed"
            case .threadStartProtocolMismatch: return "protocol_thread_mismatch"
            }
        }
        if let process = error as? LiveProcessError {
            switch process {
            case .invalidFrame: return "protocol_mismatch"
            case .timeout: return "voice_timeout"
            case .executableMissing, .executableRejected,
                 .helperExited, .invalidConfiguration, .processUnavailable:
                return "helper_failed"
            }
        }
        if error is LiveProtocolError { return "protocol_mismatch" }
        if let wire = error as? GPTLiveWireError {
            switch wire {
            case .oauthRequired, .invalidCredential, .unauthorized:
                return "credential_rejected"
            case .badRequest: return "live_bad_request"
            case .forbidden: return "live_forbidden"
            case .serverFailure: return "live_server_failure"
            case .unexpectedStatus, .networkFailure, .invalidProviderEndpoint:
                return "live_network_failure"
            case .invalidRequestID: return "protocol_mismatch"
            case .invalidSDPOffer, .invalidSDPAnswer, .oversizedSDPAnswer:
                return "live_invalid_sdp"
            case .missingCallID, .invalidCallID: return "live_invalid_call_id"
            }
        }
        if let live = error as? GPTLiveSessionError {
            switch live {
            case .sessionAlreadyActive: return "voice_unavailable"
            case .sidebandStartup: return "live_sideband_startup"
            case .sidebandClosed: return "live_sideband_closed"
            case .expired: return "live_expired"
            case .protocolFailure: return "protocol_mismatch"
            }
        }
        return "voice_failed"
    }

    private static func loginFrameFailureCode(
        _ kind: CodexLoginFrameKind,
        _ reason: LiveProtocolError?
    ) -> String {
        let prefix: String
        switch kind {
        case .response: prefix = "protocol_login_response"
        case .responseRoot: prefix = "protocol_login_response_root"
        case .responseResult: prefix = "protocol_login_response_result"
        case .loginCompleted: prefix = "protocol_login_completed"
        case .accountUpdated: prefix = "protocol_login_updated"
        case .credentialRefresh: prefix = "protocol_login_refresh"
        case .accountOther: prefix = "protocol_login_account_other"
        case .thread: prefix = "protocol_login_thread"
        case .methodOther: prefix = "protocol_login_method_other"
        case .other: prefix = "protocol_login_frame"
        }
        switch reason {
        case .unknownMethod: return "\(prefix)_unknown_method"
        case .unknownField: return "\(prefix)_unknown_field"
        case .missingField: return "\(prefix)_missing_field"
        case .invalidField: return "\(prefix)_invalid_field"
        default: return "\(prefix)_mismatch"
        }
    }

    private static func isLiveAdmissionFailure(_ error: Error) -> Bool {
        if error is GPTLiveCredentialError || error is CredentialError {
            return true
        }
        return (error as? LiveAudioError) == .permissionDenied
    }

    private static func sanitizedLiveCode(_ code: String) -> String {
        if code.hasPrefix("protocol_login_") { return code }
        if CodexRealtimeStartDiagnostic(rawValue: code) != nil { return code }
        let admitted = [
            "audio_backpressure", "capture_failed", "credential_rejected",
            "device_unavailable", "helper_failed",
            "cleanup_pending",
            "microphone_denied", "permission_restricted", "voice_unavailable",
            "playback_failed", "protocol_initialize_mismatch",
            "protocol_login_mismatch", "protocol_mismatch",
            "protocol_realtime_mismatch", "protocol_thread_mismatch",
            "provider_failed", "live_bad_request", "live_forbidden",
            "live_server_failure", "live_network_failure", "live_invalid_sdp",
            "live_invalid_call_id", "live_sideband_startup", "live_sideband_closed",
            "live_expired",
            "voice_failed", "voice_timeout",
        ]
        return admitted.contains(code) ? code : "voice_failed"
    }
}

enum ProviderRoutingError: Error, Equatable, Sendable {
    case unsupportedProvider
    case routeChangedDuringActiveTurn
    case turnAlreadyActive
}

actor CodexTypedCredentialRefresher {
    private let refreshSelected: @Sendable () async throws -> Void
    private let loadSelected: @Sendable () async throws -> CodexOAuthCredential

    init(
        refreshSelected: @escaping @Sendable () async throws -> Void,
        loadSelected: @escaping @Sendable () async throws -> CodexOAuthCredential
    ) {
        self.refreshSelected = refreshSelected
        self.loadSelected = loadSelected
    }

    func refresh(
        accountID: String,
        previousAccessToken: Data? = nil
    ) async throws -> CodexOAuthCredential {
        try await refreshSelected()
        let replacement = try await loadSelected()
        guard replacement.accountID == accountID,
              previousAccessToken == nil || replacement.accessToken != previousAccessToken
        else { throw GPTLiveCredentialError.accountMismatch }
        return replacement
    }
}

private struct UnavailableReasoningGateway: ReasoningGateway {
    func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        _ = request
        throw ProviderRoutingError.unsupportedProvider
    }

    func cancel(_ cancellation: ReasoningCancellation) async {
        _ = cancellation
    }
}

actor ProviderRoutingGateway: ReasoningGateway {
    private struct ActiveRoute {
        var kind: ProviderKind?
        let turnID: TurnID
        let generation: Int
        var cancelled: Bool
    }

    private let selectedKind: @Sendable () async throws -> ProviderKind
    private let codex: any ReasoningGateway
    private let openAICompatible: any ReasoningGateway
    private var active: ActiveRoute?

    init(
        selectedKind: @escaping @Sendable () async throws -> ProviderKind,
        codex: any ReasoningGateway,
        openAICompatible: any ReasoningGateway
    ) {
        self.selectedKind = selectedKind
        self.codex = codex
        self.openAICompatible = openAICompatible
    }

    func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        if let active {
            let selected = try await selectedKind()
            guard active.kind == nil || active.kind == selected else {
                throw ProviderRoutingError.routeChangedDuringActiveTurn
            }
            throw ProviderRoutingError.turnAlreadyActive
        }
        active = .init(
            kind: nil,
            turnID: request.turnID,
            generation: request.generation,
            cancelled: false
        )
        do {
            let kind = try await selectedKind()
            try requireActiveAdmission(request, assigning: kind)
            let gateway = try gateway(for: kind)
            let source = try await gateway.start(request)
            guard isActive(request), active?.cancelled == false else {
                await gateway.cancel(.init(
                    turnID: request.turnID,
                    targetGeneration: request.generation
                ))
                clear(turnID: request.turnID, generation: request.generation)
                throw CancellationError()
            }
            return routedStream(source, request: request)
        } catch {
            clear(turnID: request.turnID, generation: request.generation)
            throw error
        }
    }

    private func routedStream(
        _ source: AsyncThrowingStream<ReasoningEvent, Error>,
        request: ReasoningRequest
    ) -> AsyncThrowingStream<ReasoningEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        continuation.yield(event)
                        if Self.isTerminal(event) { break }
                    }
                    self.clear(
                        turnID: request.turnID,
                        generation: request.generation
                    )
                    continuation.finish()
                } catch {
                    self.clear(
                        turnID: request.turnID,
                        generation: request.generation
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel(_ cancellation: ReasoningCancellation) async {
        guard var active,
              active.turnID == cancellation.turnID,
              active.generation == cancellation.targetGeneration
        else { return }
        active.cancelled = true
        self.active = active
        guard let kind = active.kind,
              let gateway = try? gateway(for: kind)
        else { return }
        await gateway.cancel(cancellation)
    }

    func resolveApproval(
        callID: CapabilityCallID,
        decision: CapabilityApprovalDecision
    ) async throws {
        guard let kind = active?.kind else {
            throw ReasoningGatewayError.approvalUnsupported
        }
        try await gateway(for: kind).resolveApproval(
            callID: callID, decision: decision
        )
    }

    private func gateway(for kind: ProviderKind) throws -> any ReasoningGateway {
        switch kind {
        case .codexOAuth: codex
        case .openAICompatible: openAICompatible
        }
    }

    private func clear(turnID: TurnID, generation: Int) {
        guard active?.turnID == turnID, active?.generation == generation else { return }
        active = nil
    }

    private func isActive(_ request: ReasoningRequest) -> Bool {
        active?.turnID == request.turnID && active?.generation == request.generation
    }

    private func requireActiveAdmission(
        _ request: ReasoningRequest,
        assigning kind: ProviderKind
    ) throws {
        guard var active,
              active.turnID == request.turnID,
              active.generation == request.generation,
              !active.cancelled
        else { throw CancellationError() }
        active.kind = kind
        self.active = active
    }

    private static func isTerminal(_ event: ReasoningEvent) -> Bool {
        switch event {
        case .completed, .stopped, .failed: true
        default: false
        }
    }
}

@MainActor
final class AppCoordinator: NSObject, NSMenuDelegate {
    let model: AppPresentationModel

    private let repository: SQLiteConversationRepository
    private let core: MillerCoordinator
    private let supervisor: GatewaySupervisor
    private let statusItem: NSStatusItem
    private let overlayController: OverlayPanelController
    private let conversationController: ConversationWindowController
    private let settingsController: NSWindowController
    private let activationService: GlobalActivationService
    private let shortcutPreferences: GlobalShortcutPreferences
    private var settingsObserver: NSObjectProtocol?
    private let providerController: ProviderSettingsController
    private let liveController: GPTLiveController?
    private let capabilityController: CapabilityController
    private let preferenceRepository: SQLitePreferenceRepository
    private let wakeProduction: WakeWordProductionController
    private let wakeSettings: WakeWordSettingsController
    private let wakeIntegration: WakeWordLiveIntegration
    private var wakeLifecycleObservers = [NSObjectProtocol]()

    init(
        environment: [String: String],
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws {
        let databasePath = environment["MILLER_DATABASE_PATH"]
            ?? SQLiteConversationRepository.defaultPath
        repository = try SQLiteConversationRepository(path: databasePath)

        let helperURL = try Self.helperURL(environment: environment)
        let cacheURL = Self.cacheURL(environment: environment)
        try FileManager.default.createDirectory(
            at: cacheURL,
            withIntermediateDirectories: true
        )
        let credentialStore = KeychainCredentialStore()
        let capabilityProviderCallbackAuthorityBox =
            CapabilityProviderCallbackAuthorityBox()
        let capabilityBridgeBox: CapabilityBridgeSessionBox?
        let capabilityTrustedParent: URL?
        if let bridgeURL = Self.capabilityBridgeURL(environment: environment) {
            let trustedParent = CapabilityRPCRuntime.defaultTrustedParent
            try Self.prepareCapabilityTrustedParent(trustedParent)
            capabilityBridgeBox = CapabilityBridgeSessionBox(
                executableURL: bridgeURL
            )
            capabilityTrustedParent = trustedParent
        } else {
            capabilityBridgeBox = nil
            capabilityTrustedParent = nil
        }
        capabilityController = try CapabilityController(
            databasePath: databasePath,
            credentialStore: credentialStore,
            trustedParent: capabilityTrustedParent,
            bridgeBox: capabilityBridgeBox,
            providerCallbackAuthorityBox: capabilityProviderCallbackAuthorityBox
        )
        let runtimeVerifier = CodexAppServerHelperVerifier()
        let runtimeResolver = CodexRuntimeResolver(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: environment,
            verify: { try runtimeVerifier.verify($0) }
        )
        let runtimeResolution = try Self.liveRuntimeResolution(
            arguments: arguments,
            savedPath: CodexRuntimePreferences().loadPath(),
            resolver: runtimeResolver
        )
        let runtimeSelection = runtimeResolution.selection
        let configuration = GatewayProcess.Configuration(
            executableURL: try Self.nodeURL(environment: environment),
            arguments: Self.helperArguments(
                helperURL: helperURL,
                environment: environment
            ),
            workingDirectoryURL: helperURL.deletingLastPathComponent(),
            environment: [
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "TMPDIR": cacheURL.path,
                "TZ": "UTC",
            ]
        )
        supervisor = GatewaySupervisor(configuration: configuration)
        let typedRefreshHelper = GatewayCredentialHelper(supervisor: supervisor)
        let typedRefreshCoordinator = CredentialCoordinator(
            store: credentialStore,
            helper: typedRefreshHelper,
            profiles: repository
        )
        let credentialLoader = GPTLiveCredentialLoader(
            load: { [credentialStore] reference in
                try await credentialStore.load(for: reference)
            }
        )
        let typedCredentialRefresher = CodexTypedCredentialRefresher(
            refreshSelected: { [repository] in
                guard let profile = try await repository.selectedProviderProfile(),
                      profile.kind == .codexOAuth,
                      try await repository.credentialIsInvalidated(
                          reference: profile.credentialReference
                      ) == false
                else { throw GPTLiveCredentialError.unavailable }
                try await typedRefreshHelper.authenticate(
                    reference: profile.credentialReference,
                    providerKind: .codexOAuth,
                    refresh: true,
                    openURL: { _ in },
                    persistCandidate: { candidate in
                        try await typedRefreshCoordinator.persistCandidate(
                            candidate,
                            for: profile.credentialReference,
                            hasActiveTurn: false
                        )
                    }
                )
            },
            loadSelected: { [repository] in
                guard let profile = try await repository.selectedProviderProfile(),
                      profile.kind == .codexOAuth,
                      try await repository.credentialIsInvalidated(
                          reference: profile.credentialReference
                      ) == false
                else { throw GPTLiveCredentialError.unavailable }
                return try await credentialLoader.load(profile: profile)
            }
        )
        let compatibleGateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: { [repository] in
                guard let profile = try await repository.selectedProviderProfile()
                else {
                    throw GatewayProtocolError.invalidSequence
                }
                return GatewayProviderProfile(
                    kind: profile.kind.rawValue,
                    baseURL: profile.baseURL,
                    model: profile.model,
                    credentialReference: profile.credentialReference
                )
            },
            toolHandler: { [capabilityController] call, emit in
                try await capabilityController.handlePiToolCall(call, emit: emit)
            }
        )
        let codexGateway: any ReasoningGateway
        let typedRoot = cacheURL.appendingPathComponent(
            "typed-codex", isDirectory: true
        )
        let makeSettingsCodexClient: (@Sendable () throws -> CodexAppServerClient)?
        if let codexExecutableURL = runtimeSelection?.executableURL {
            try FileManager.default.createDirectory(
                at: typedRoot,
                withIntermediateDirectories: true
            )
            makeSettingsCodexClient = { [environment, runtimeVerifier,
                                          typedCredentialRefresher, typedRoot] in
                CodexAppServerClient(
                    process: CodexAppServerProcess(
                        configuration: try Self.typedCodexProcessConfiguration(
                            executableURL: codexExecutableURL,
                            temporaryParentURL: typedRoot,
                            environment: environment,
                            spawnedProcessVerifier: { pid in
                                try runtimeVerifier.verifyRunningProcess(
                                    pid: pid,
                                    expectedExecutableURL: codexExecutableURL
                                )
                            }
                        )
                    ),
                    refreshProvider: { accountID in
                        try await typedCredentialRefresher.refresh(
                            accountID: accountID
                        )
                    }
                )
            }
        } else {
            makeSettingsCodexClient = nil
        }
        if let codexExecutableURL = runtimeSelection?.executableURL {
            let makeCodexClient: @Sendable () throws -> CodexAppServerClient = {
                [capabilityController, capabilityBridgeBox,
                 capabilityProviderCallbackAuthorityBox] in
                    let callbacks = capabilityController.providerCallbacks(
                        authority: capabilityProviderCallbackAuthorityBox.current()
                    )
                    return CodexAppServerClient(
                        process: CodexAppServerProcess(
                            configuration: try Self.typedCodexProcessConfiguration(
                                executableURL: codexExecutableURL,
                                temporaryParentURL: typedRoot,
                                environment: environment,
                                bridgeConfiguration: try capabilityBridgeBox?
                                    .configuration(),
                                spawnedProcessVerifier: { pid in
                                    try runtimeVerifier.verifyRunningProcess(
                                        pid: pid,
                                        expectedExecutableURL: codexExecutableURL
                                    )
                                }
                            )
                        ),
                        refreshProvider: { accountID in
                            try await typedCredentialRefresher.refresh(accountID: accountID)
                        },
                        onCapabilityActivity: callbacks.activity,
                        resolveProviderApproval: callbacks.approval,
                        resolveProviderApprovalDetails: callbacks.approvalDetails,
                        existingMillerCapabilities: capabilityBridgeBox?.catalog() ?? []
                    )
                }
            codexGateway = CodexTypedReasoningGateway(
                makeClient: makeCodexClient,
                credential: { [repository] in
                    guard let profile = try await repository.selectedProviderProfile(),
                          profile.kind == .codexOAuth,
                          try await repository.credentialIsInvalidated(
                              reference: profile.credentialReference
                          ) == false
                    else { throw GPTLiveCredentialError.unavailable }
                    return try await credentialLoader.load(profile: profile)
                },
                model: { [repository] in
                    guard let profile = try await repository.selectedProviderProfile(),
                          profile.kind == .codexOAuth
                    else { throw GPTLiveCredentialError.unavailable }
                    return profile.model
                },
                cwd: typedRoot.path
            )
            capabilityController.configureProviderProjection(.init(
                selectedProfile: { [repository] in
                    try await repository.selectedProviderProfile()
                },
                inventory: { [repository] profile, local in
                    guard try await repository.credentialIsInvalidated(
                        reference: profile.credentialReference
                    ) == false
                    else { throw GPTLiveCredentialError.unavailable }
                    return try await makeCodexClient().inventoryCapabilities(
                        requestID: "catalog:\(UUID().uuidString.lowercased())",
                        credential: try await credentialLoader.load(profile: profile),
                        codexProviderProfileID: profile.id,
                        existingMillerCapabilities: local
                    )
                }
            ))
        } else {
            codexGateway = UnavailableReasoningGateway()
            capabilityController.configureProviderProjection(nil)
        }
        let providerGateway = ProviderRoutingGateway(
            selectedKind: { [repository] in
                guard let profile = try await repository.selectedProviderProfile()
                else { throw ProviderRoutingError.unsupportedProvider }
                return profile.kind
            },
            codex: codexGateway,
            openAICompatible: compatibleGateway
        )
        let gateway = CapabilityReasoningGateway(
            base: providerGateway,
            selectedProfile: { [repository] in
                guard let profile = try await repository.selectedProviderProfile()
                else { throw ProviderRoutingError.unsupportedProvider }
                return profile
            },
            controller: capabilityController
        )
        core = MillerCoordinator(repository: repository, gateway: gateway)
        let liveAdmissionAuthority = LiveAdmissionAuthority()

        let dependencies = HostDependencies(
            submit: { [core] text, conversationID, voiceHistoryAttachment in
                try await core.submit(
                    text: text,
                    conversationID: conversationID,
                    voiceHistoryAttachment: voiceHistoryAttachment
                )
            },
            stop: { [core] in try await core.stop() },
            loadTurn: { [repository] id in try await repository.turn(id: id) },
            loadConversations: { [repository] in
                try await repository.conversations()
            },
            loadTurns: { [repository] id in
                try await repository.turns(conversationID: id)
            },
            archive: { [core] id in try await core.archive(conversationID: id) },
            unarchive: { [core] id in try await core.unarchive(conversationID: id) },
            delete: { [core] id in try await core.delete(conversationID: id) },
            reasoningStatus: { [core] in await core.activeReasoningStatus },
            admitLive: { [repository, liveAdmissionAuthority] conversationID, activationSource in
                let reservation = try await liveAdmissionAuthority.reserve()
                do {
                    try Task.checkCancellation()
                    try await repository.ensureConversation(
                        conversationID: conversationID
                    )
                    try Task.checkCancellation()
                    return LiveAdmission(
                        conversationID: conversationID,
                        activationSource: activationSource,
                        release: reservation.release
                    )
                } catch {
                    await reservation.release()
                    throw error
                }
            }
        )
        providerController = ProviderSettingsController(
            repository: repository,
            credentials: credentialStore,
            supervisor: supervisor,
            databaseURL: URL(fileURLWithPath: databasePath),
            cacheURL: cacheURL,
            codexTypedReadiness: { [repository] profile in
                guard let makeSettingsCodexClient else {
                    let state: CodexTypedReadinessState = switch runtimeResolution {
                    case .rejected: .executableRejected
                    case .missing, .available: .executableMissing
                    }
                    return .init(state: state)
                }
                let loader = GPTLiveCredentialLoader(
                    load: { [credentialStore] reference in
                        try await credentialStore.load(for: reference)
                    }
                )
                guard try await repository.credentialIsInvalidated(
                    reference: profile.credentialReference
                ) == false else {
                    return .init(state: .localCredentialUnavailable)
                }
                let credential: CodexOAuthCredential
                do {
                    credential = try await loader.load(profile: profile)
                } catch {
                    return .init(state: .localCredentialUnavailable)
                }
                return try await makeSettingsCodexClient().probeTypedReadiness(
                    credential: credential,
                    timeout: .seconds(10)
                )
            },
            codexTypedRemoteReadiness: { [repository, typedRoot] profile in
                guard let makeSettingsCodexClient else {
                    let state: CodexTypedReadinessState = switch runtimeResolution {
                    case .rejected: .executableRejected
                    case .missing, .available: .executableMissing
                    }
                    return .init(state: state)
                }
                guard try await repository.credentialIsInvalidated(
                    reference: profile.credentialReference
                ) == false else {
                    return .init(state: .localCredentialUnavailable)
                }
                let loader = GPTLiveCredentialLoader(
                    load: { [credentialStore] reference in
                        try await credentialStore.load(for: reference)
                    }
                )
                let credential: CodexOAuthCredential
                do {
                    credential = try await loader.load(profile: profile)
                } catch {
                    return .init(state: .localCredentialUnavailable)
                }
                let requestWorkspace = try Self.makeTypedRequestWorkspace(
                    parent: typedRoot
                )
                defer { try? Self.removeTypedRequestWorkspace(
                    requestWorkspace, parent: typedRoot
                ) }
                return try await makeSettingsCodexClient().probeTypedRemote(
                    credential: credential,
                    model: profile.model,
                    cwd: requestWorkspace.path,
                    timeout: .seconds(30)
                )
            }
        )
        let providerSettings = ProviderSettingsDependencies(
            load: { [providerController] in
                try await providerController.snapshot()
            },
            saveOpenAICompatible: { [providerController] input, hasActiveTurn in
                try await providerController.saveOpenAICompatible(
                    input,
                    hasActiveTurn: hasActiveTurn
                )
            },
            saveCodexModel: { [providerController] model in
                try await providerController.saveCodexModel(model)
            },
            select: { [providerController] id, hasActiveTurn in
                try await providerController.select(id, hasActiveTurn: hasActiveTurn)
            },
            beginCodexLogin: { [providerController] hasActiveTurn in
                try await providerController.beginCodexLogin(hasActiveTurn: hasActiveTurn)
            },
            refreshCodexAuthentication: { [providerController] hasActiveTurn in
                try await providerController.refreshCodexAuthentication(
                    hasActiveTurn: hasActiveTurn
                )
            },
            retryReadiness: { [providerController] in
                try await providerController.retryReadiness()
            },
            localLogout: { [providerController] hasActiveTurn in
                try await providerController.localLogout(hasActiveTurn: hasActiveTurn)
            },
            delete: { [providerController] id, hasActiveTurn in
                try await providerController.delete(id, hasActiveTurn: hasActiveTurn)
            },
            reset: { [providerController] in
                await providerController.reset()
            }
        )
        let preferenceRepository = try SQLitePreferenceRepository(
            path: databasePath
        )
        self.preferenceRepository = preferenceRepository
        let microphoneOwnership = MicrophoneOwnership()
        let wakeIntegration = WakeWordLiveIntegration()
        let wakeModelPaths = try? WakeWordRuntimeResources.resolve(
            environment: environment
        )
        let wakeMaterializer: WakeWordKeywordMaterializer?
        if let wakeModelPaths {
            wakeMaterializer = try? WakeWordKeywordMaterializer(
                tokensFile: wakeModelPaths.tokens,
                applicationSupportDirectory: wakeModelPaths.keywords
                    .deletingLastPathComponent()
            )
        } else {
            wakeMaterializer = nil
        }
        let wakeRecorder = WakeWordAVAudioCaptureAdapter(
            ownership: microphoneOwnership
        )
        let wakeProduction = WakeWordProductionController(
            recorder: wakeRecorder,
            detectorFactory: {
                guard let wakeModelPaths else {
                    throw WakeWordDetectorError.unavailable
                }
                return try SherpaWakeWordDetector(
                    paths: wakeModelPaths,
                    tuning: .default
                )
            },
            onWakeDetected: { [weak wakeIntegration] in
                wakeIntegration?.wakeDetected()
            },
            onCommandAudio: { [weak wakeIntegration] audio, _ in
                await wakeIntegration?.commandAudio(audio)
            }
        )
        let wakeSettings = WakeWordSettingsController(
            enable: { [preferenceRepository, wakeMaterializer, wakeProduction] in
                guard let wakeMaterializer else {
                    throw WakeWordDetectorError.unavailable
                }
                let phrase = try await preferenceRepository.value(for: .wakePhrase)
                let materialized = try wakeMaterializer.materialize(phrase)
                do {
                    let state = try await wakeProduction.enableFromSettings()
                    do {
                        try await preferenceRepository.set(true, for: .wakewordEnabled)
                    } catch {
                        _ = await wakeProduction.disableFromSettings()
                        try? wakeMaterializer.restore(materialized)
                        throw error
                    }
                    return state
                } catch {
                    try? wakeMaterializer.restore(materialized)
                    throw error
                }
            },
            disable: { [preferenceRepository, wakeProduction] in
                try await preferenceRepository.set(false, for: .wakewordEnabled)
                return await wakeProduction.disableFromSettings()
            },
            retry: { [preferenceRepository, wakeMaterializer, wakeProduction] in
                guard let wakeMaterializer else {
                    throw WakeWordDetectorError.unavailable
                }
                let phrase = try await preferenceRepository.value(for: .wakePhrase)
                let materialized = try wakeMaterializer.materialize(phrase)
                do {
                    let state: WakeWordState
                    if wakeProduction.state == .disabled
                        || wakeProduction.state == .unavailable(.model)
                    {
                        state = try await wakeProduction.enableFromSettings()
                    } else {
                        state = try await wakeProduction.reloadDetector()
                    }
                    return state
                } catch {
                    try? wakeMaterializer.restore(materialized)
                    throw error
                }
            },
            savePhrase: { [preferenceRepository, wakeMaterializer, wakeProduction] phrase in
                guard let wakeMaterializer else {
                    throw WakeWordDetectorError.unavailable
                }
                let previousPhrase = try await preferenceRepository.value(
                    for: .wakePhrase
                )
                let materialized = try wakeMaterializer.materialize(phrase)
                do {
                    try await preferenceRepository.set(
                        materialized.normalizedPhrase,
                        for: .wakePhrase
                    )
                    if try await preferenceRepository.value(for: .wakewordEnabled) {
                        _ = try await wakeProduction.reloadDetector()
                    }
                    return materialized.normalizedPhrase
                } catch {
                    try? wakeMaterializer.restore(materialized)
                    try? await preferenceRepository.set(
                        previousPhrase,
                        for: .wakePhrase
                    )
                    throw error
                }
            }
        )
        wakeSettings.bind(to: wakeProduction)
        wakeIntegration.production = wakeProduction
        self.wakeProduction = wakeProduction
        self.wakeSettings = wakeSettings
        self.wakeIntegration = wakeIntegration

        let livePeerHost = OverlayLiveVoicePeerHost(makePeer: {
            WebKitLivePeer(nativeMicrophoneAuthorized: {
                SystemMicrophonePermission.current() == .authorized
            })
        })
        let liveVoice: LiveVoiceDependencies
        if let liveHelperURL = runtimeSelection?.executableURL {
            let liveRoot = cacheURL.appendingPathComponent("gpt-live", isDirectory: true)
            try FileManager.default.createDirectory(
                at: liveRoot,
                withIntermediateDirectories: true
            )
            let controller = try GPTLiveController(
                helperURL: liveHelperURL,
                temporaryParentURL: liveRoot,
                selectedProfile: { [repository] in
                    try await repository.selectedProviderProfile()
                },
                credentialLoader: GPTLiveCredentialLoader(
                    load: { [credentialStore] reference in
                        try await credentialStore.load(for: reference)
                    }
                ),
                credentialInvalidated: { [repository] reference in
                    try await repository.credentialIsInvalidated(reference: reference)
                },
                refreshCredential: { [providerController] in
                    try await providerController.refreshCodexAuthentication(
                        hasActiveTurn: false
                    )
                },
                providerCallbacks: {
                    [capabilityController,
                     capabilityProviderCallbackAuthorityBox] in
                    capabilityController.providerCallbacks(
                        authority: capabilityProviderCallbackAuthorityBox.current()
                    )
                },
                millerCapabilityCatalog: {
                    capabilityBridgeBox?.catalog() ?? []
                },
                bridgeConfiguration: {
                    try capabilityBridgeBox?.configuration()
                },
                portableSkillAttachment: { [capabilityController] providerProfileID in
                    try await capabilityController.selectedSkillAttachment(
                        providerProfileID: providerProfileID
                    )
                },
                makePeer: { [livePeerHost] in
                    try await MainActor.run { try livePeerHost.makePeer() }
                },
                microphoneOwnership: microphoneOwnership,
                releasePeer: { [livePeerHost] in
                    await MainActor.run { livePeerHost.removePeer() }
                },
                spawnedProcessVerifier: { pid in
                    try runtimeVerifier.verifyRunningProcess(
                        pid: pid,
                        expectedExecutableURL: liveHelperURL
                    )
                }
            )
            liveController = controller
            liveVoice = controller.dependencies()
        } else {
            liveController = nil
            liveVoice = .unavailable
        }
        let voiceHistoryRepository = try SQLiteVoiceHistoryRepository(
            path: databasePath
        )
        let liveTranscriptRecorder = LiveVoiceTranscriptRecorder(
            persistence: .init(
                savingEnabled: {
                    try await preferenceRepository.value(
                        for: .voiceTranscriptSavingEnabled
                    )
                },
                nextSessionSavingEnabled: {
                    try await preferenceRepository.value(
                        for: .nextVoiceSessionSavingEnabled
                    )
                },
                restoreNextSessionSavingDefault: {
                    try await preferenceRepository.set(
                        true,
                        for: .nextVoiceSessionSavingEnabled
                    )
                },
                startSession: {
                    id, conversationID, activationSource, saveChoice in
                    try await voiceHistoryRepository.startSession(
                        id: id,
                        conversationID: conversationID,
                        activationSource: activationSource,
                        saveChoice: saveChoice
                    )
                },
                appendEntry: {
                    id, sessionID, sequence, role, text, completionState in
                    try await voiceHistoryRepository.appendEntry(
                        id: id,
                        sessionID: sessionID,
                        sequence: sequence,
                        role: role,
                        text: text,
                        completionState: completionState,
                        startedAt: Date()
                    )
                },
                completeEntry: { id, text in
                    try await voiceHistoryRepository.completeEntry(
                        id: id,
                        text: text
                    )
                },
                finalizeSession: { id, outcome in
                    try await voiceHistoryRepository.finalizeSession(
                        id: id,
                        outcome: outcome
                    )
                },
                recoverInterruptedSessions: {
                    try await voiceHistoryRepository.recoverInterruptedSessions()
                }
            )
        )
        let voiceHistory = VoiceHistoryDependencies(
            sessions: { [voiceHistoryRepository] start, end in
                try await voiceHistoryRepository.sessions(
                    from: start,
                    through: end
                )
            },
            exportProjection: { [voiceHistoryRepository] sessionIDs in
                try await voiceHistoryRepository.exportProjection(
                    sessionIDs: sessionIDs
                )
            },
            attachmentProjection: { [voiceHistoryRepository] sessionIDs, maximumBytes in
                try await voiceHistoryRepository.attachmentProjection(
                    sessionIDs: sessionIDs,
                    maximumContentBytes: maximumBytes
                )
            },
            rangeAttachmentProjection: { [voiceHistoryRepository] start, end, maximumBytes in
                try await voiceHistoryRepository.attachmentProjection(
                    from: start,
                    through: end,
                    maximumContentBytes: maximumBytes
                )
            },
            deleteSession: { [voiceHistoryRepository] id in
                try await voiceHistoryRepository.deleteSession(id: id)
            },
            deleteRange: { [voiceHistoryRepository] start, end in
                try await voiceHistoryRepository.deleteSessions(
                    from: start,
                    through: end
                )
            },
            deleteAll: { [voiceHistoryRepository] in
                try await voiceHistoryRepository.deleteAll()
            }
        )
        model = AppPresentationModel(
            dependencies: dependencies,
            providerSettings: providerSettings,
            liveVoice: liveVoice,
            liveTranscriptRecorder: liveTranscriptRecorder,
            voiceHistory: voiceHistory,
            capabilityController: capabilityController,
            prepareLiveStart: { [weak wakeIntegration] source in
                await wakeIntegration?.prepareLiveStart(source)
            },
            liveVoiceFinished: { [weak wakeIntegration] in
                await wakeIntegration?.liveVoiceFinished()
            }
        )
        wakeIntegration.model = model
        let providerNames: @Sendable () async throws -> [UUID: String] = {
            [repository] in
            Dictionary(uniqueKeysWithValues: try await repository
                .providerProfiles().map { ($0.id, $0.label) })
        }
        let capabilitySettings = MCPServerEditorModel(
            dependencies: MCPServerEditorDependencies(
                load: { [capabilityController] in
                    try await capabilityController.settingsSnapshot(
                        providerNames: try await providerNames()
                    )
                },
                save: { [capabilityController] value in
                    try await capabilityController.saveServerSettings(value)
                },
                remove: { [capabilityController] serverID in
                    try await capabilityController.removeServerFromSettings(
                        serverID: serverID
                    )
                },
                testConnection: { [capabilityController, repository] serverID in
                    let compatible = Set(try await repository.providerProfiles().map(\.id))
                    return try await capabilityController.testAndEnableServer(
                        serverID: serverID,
                        compatibleProviderProfileIDs: compatible
                    )
                },
                setProviderEnabled: { [capabilityController] enabled, serverID,
                                      profileID in
                    try await capabilityController.setProviderEnabledFromSettings(
                        enabled,
                        serverID: serverID,
                        providerProfileID: profileID
                    )
                },
                setServerPolicy: { [capabilityController] serverID, policy in
                    try await capabilityController.setServerPolicyFromSettings(
                        policy,
                        serverID: serverID
                    )
                },
                setToolPolicy: { [capabilityController] toolID, policy in
                    try await capabilityController.setToolPolicyFromSettings(
                        policy,
                        toolID: toolID
                    )
                },
                refresh: { [capabilityController] in
                    try await capabilityController.reloadLocalConfiguration()
                    return try await capabilityController.settingsSnapshot(
                        providerNames: try await providerNames()
                    )
                },
                importSkill: { [capabilityController] url in
                    try await capabilityController.importPortableSkillFromSettings(at: url)
                },
                importPlugin: { [capabilityController] url in
                    try await capabilityController.importPluginFromSettings(at: url)
                },
                setSkillEnabled: { [capabilityController] enabled, skillID, providerID in
                    try await capabilityController.setPortableSkillEnabledFromSettings(
                        enabled, skillID: skillID, providerProfileID: providerID
                    )
                },
                deleteSkill: { [capabilityController] id in
                    try await capabilityController.deletePortableSkillFromSettings(id: id)
                },
                deletePlugin: { [capabilityController] id in
                    try await capabilityController.deletePluginFromSettings(id: id)
                }
            )
        )
        let databaseURL = URL(fileURLWithPath: databasePath)
        let privacySettings = PrivacyDataSettingsModel(
            dependencies: PrivacyDataSettingsDependencies(
                loadTranscriptSavingEnabled: { [preferenceRepository] in
                    try await preferenceRepository.value(
                        for: .voiceTranscriptSavingEnabled
                    )
                },
                loadNextSessionSavingEnabled: { [preferenceRepository] in
                    try await preferenceRepository.value(
                        for: .nextVoiceSessionSavingEnabled
                    )
                },
                setTranscriptSavingEnabled: { [preferenceRepository] value in
                    try await preferenceRepository.set(
                        value, for: .voiceTranscriptSavingEnabled
                    )
                },
                setNextSessionSavingEnabled: { [preferenceRepository] value in
                    try await preferenceRepository.set(
                        value, for: .nextVoiceSessionSavingEnabled
                    )
                },
                exportVoiceHistory: { [model] url in
                    try await model.exportAllVoiceHistoryFromSettings(to: url)
                },
                deleteVoiceHistory: { [model] in
                    try await model.deleteAllVoiceHistoryFromSettings()
                },
                deleteCapabilityAudit: { [capabilityController] in
                    try await capabilityController.deleteCapabilityAuditsFromSettings()
                },
                storageUsage: { [databaseURL, cacheURL] in
                    ManagedStorageUsage.measure(
                        dataURLs: [
                            databaseURL,
                            URL(fileURLWithPath: databaseURL.path + "-wal"),
                            URL(fileURLWithPath: databaseURL.path + "-shm"),
                        ],
                        cacheURLs: [cacheURL]
                    )
                },
                reset: { [model, providerController, voiceHistoryRepository,
                          preferenceRepository, capabilityController,
                          capabilitySettings] in
                    await model.performManagedPrivacyReset {
                        let result = await capabilityController.performManagedReset {
                            await voiceHistoryRepository.close()
                            await preferenceRepository.close()
                            var roots = await providerController.reset().roots
                            await capabilitySettings.clearAfterPrivacyReset()
                            do {
                                try await voiceHistoryRepository.reopen()
                                roots.append(.init(
                                    root: "sqlite.voice_history.reopen", succeeded: true
                                ))
                            } catch {
                                roots.append(.init(
                                    root: "sqlite.voice_history.reopen", succeeded: false
                                ))
                            }
                            do {
                                try await preferenceRepository.reopen()
                                roots.append(.init(
                                    root: "sqlite.preferences.reopen", succeeded: true
                                ))
                            } catch {
                                roots.append(.init(
                                    root: "sqlite.preferences.reopen", succeeded: false
                                ))
                            }
                            return ResetResult(roots: roots)
                        }
                        return result
                    }
                },
                resetWakePreferences: { [preferenceRepository] in
                    try await preferenceRepository.set(false, for: .wakewordEnabled)
                    try await preferenceRepository.set("Hey Miller", for: .wakePhrase)
                    try await preferenceRepository.set("", for: .wakeMicrophoneID)
                    try await preferenceRepository.set(
                        0.5, for: .wakeDetectionThreshold
                    )
                    try await preferenceRepository.set(0.0, for: .wakeKeywordScore)
                }
            )
        )
        let diagnosticsSettings = DiagnosticsSettingsModel(
            dependencies: DiagnosticsSettingsDependencies(
                load: { [model, capabilityController, databaseURL, cacheURL] in
                    let names = (try? await providerNames()) ?? [:]
                    let capabilities = try? await capabilityController
                        .settingsSnapshot(providerNames: names)
                    let capabilityDiagnostics = await capabilityController
                        .diagnosticsSnapshot()
                    let freshness: String
                    if let capabilities {
                        freshness = capabilities.servers.contains(where: {
                            $0.server.staleState == .stale
                                || $0.tools.contains(where: {
                                    $0.staleState == .stale
                                })
                        }) ? "Stale" : "Current"
                    } else {
                        freshness = "Unavailable"
                    }
                    let usage = ManagedStorageUsage.measure(
                        dataURLs: [
                            databaseURL,
                            URL(fileURLWithPath: databaseURL.path + "-wal"),
                            URL(fileURLWithPath: databaseURL.path + "-shm"),
                        ],
                        cacheURLs: [cacheURL]
                    )
                    let appFailure = await MainActor.run { model.errorCode }
                    let failure = DiagnosticsSettingsSnapshot.composedFailure(
                        appFailure: appFailure,
                        capabilityFailure: capabilityDiagnostics.sanitizedLastFailure
                    )
                    return DiagnosticsSettingsSnapshot(
                        componentVersions: [
                            "Miller": MillerAppServerClientInfo.version,
                            "MCP SDK": "0.12.1",
                            "Pi overlay": "0.82.0-a3",
                        ],
                        sanitizedLastFailure: failure,
                        catalogFreshness: freshness,
                        brokerProcessState: capabilityDiagnostics.broker?
                            .state.rawValue.capitalized ?? "Unavailable",
                        adapterProcessState: capabilityDiagnostics
                            .adapterProcessState.diagnosticsLabel,
                        controllerState: capabilityDiagnostics.controllerState,
                        bridgeRPCState: capabilityDiagnostics.bridgeRPCServerRunning
                            ? "Running" : "Stopped",
                        mcpChildState: capabilityDiagnostics.broker.map {
                            "\($0.activeSessionCount) active, "
                                + "\($0.pendingConnectionCount) starting"
                        } ?? "Unavailable",
                        managedDataBytes: usage.managedDataBytes,
                        managedCacheBytes: usage.managedCacheBytes,
                        managedDataLabel: usage.dataLabel(),
                        managedCacheLabel: usage.cacheLabel()
                    )
                }
            )
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        overlayController = OverlayPanelController(
            model: model,
            peerHost: livePeerHost
        )
        conversationController = ConversationWindowController(model: model)
        settingsController = NSWindowController(
            window: NSHostingWindow(rootView: SettingsView(
                model: model,
                capabilitySettings: capabilitySettings,
                privacySettings: privacySettings,
                diagnosticsSettings: diagnosticsSettings,
                wakeSettings: wakeSettings
            ))
        )
        activationService = GlobalActivationService()
        shortcutPreferences = GlobalShortcutPreferences()
        super.init()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .millerOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openSettings()
            }
        }
        wakeLifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.wakeProduction.suspend(.inactiveSession)
                }
            }
        )
        wakeLifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          !self.wakeIntegration.liveSessionActive,
                          case .suspended(.inactiveSession) = self.wakeProduction.state
                    else { return }
                    await self.wakeProduction.resumeAfterLiveCleanup()
                }
            }
        )
        wakeLifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.wakeProduction.suspend(.sleep)
                }
            }
        )
        wakeLifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          !self.wakeIntegration.liveSessionActive,
                          case .suspended(.sleep) = self.wakeProduction.state
                    else { return }
                    await self.wakeProduction.resumeAfterLiveCleanup()
                }
            }
        )
    }

    func start() {
        if let button = statusItem.button {
            if !StatusItemAppearance.configure(button) {
                statusItem.length = NSStatusItem.variableLength
            }
        }
        statusItem.menu = makeMenu()
        statusItem.menu?.delegate = self
        activationService.onActivation = { [weak self] in
            self?.toggleOverlay()
        }
        model.configureShortcut(shortcutPreferences.load()) { [weak self] shortcut in
            self?.applyShortcut(shortcut) ?? false
        }
        model.selectShortcut(model.selectedShortcut)
        Task {
            await capabilityController.start()
            try? await repository.recoverInterruptedTurns()
            await model.recoverInterruptedVoiceSessions()
            try? await providerController.restoreSelectedProfile()
            await model.refresh()
            await model.refreshProviderSettings()
            await model.refreshLiveVoiceAvailability()
            let wakeEnabled = (try? await preferenceRepository.value(
                for: .wakewordEnabled
            )) ?? false
            let wakePhrase = (try? await preferenceRepository.value(
                for: .wakePhrase
            )) ?? "Hey Miller"
            await wakeSettings.restorePersistedPreferences(
                enabled: wakeEnabled,
                phrase: wakePhrase
            )
        }
    }

    func shutdown() async {
        activationService.unregister()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        wakeLifecycleObservers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        wakeLifecycleObservers.removeAll()
        _ = await wakeProduction.shutdown()
        await model.shutdownLiveVoice()
        await liveController?.shutdown()
        await capabilityController.shutdown()
        await model.abandonLiveVoiceSession()
        await supervisor.shutdown()
    }

    func showPrimaryInterface() {
        overlayController.show()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 2)?.isEnabled = model.menuState.canCreateConversation
        menu.item(withTag: 3)?.isHidden = !model.menuState.canStop
    }

    @objc private func openMiller() {
        overlayController.show()
    }

    @objc private func newConversation() {
        model.newConversation()
        overlayController.show()
    }

    @objc private func stopResponse() {
        Task { await model.stop() }
    }

    @objc private func openConversation() {
        conversationController.show()
    }

    @objc private func openSettings() {
        settingsController.showWindow(nil)
        settingsController.window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func toggleOverlay() {
        overlayController.toggle()
    }

    private func applyShortcut(_ shortcut: GlobalShortcut) -> Bool {
        shortcutPreferences.save(shortcut)
        let registered = activationService.register(shortcut)
        if let button = statusItem.button {
            StatusItemAppearance.setShortcutAvailable(registered, on: button)
        }
        return registered
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Miller", action: #selector(openMiller), tag: 1))
        menu.addItem(item("New Conversation", action: #selector(newConversation), tag: 2))
        menu.addItem(item("Stop Response", action: #selector(stopResponse), tag: 3))
        menu.addItem(item("Conversation Window", action: #selector(openConversation), tag: 4))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(openSettings), tag: 5))
        menu.addItem(.separator())
        menu.addItem(item("Quit", action: #selector(quit), tag: 6))
        return menu
    }

    private func item(_ title: String, action: Selector, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    private static func helperURL(environment: [String: String]) throws -> URL {
        if let path = environment["MILLER_GATEWAY_HELPER_PATH"] {
            return URL(fileURLWithPath: path)
        }
        if environment["MILLER_FAKE_HELPER_MODE"] == nil,
           let resources = Bundle.main.resourceURL
        {
            let server = resources
                .appendingPathComponent("Gateway/app/server.mjs")
            if FileManager.default.fileExists(atPath: server.path) {
                return server
            }
        }
        if let bundled = Bundle.main.url(
            forResource: "fake-helper",
            withExtension: "mjs",
            subdirectory: "Gateway"
        ) {
            return bundled
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func capabilityBridgeURL(
        environment: [String: String]
    ) -> URL? {
        let candidates: [URL?] = [
            environment["MILLER_CAPABILITY_BRIDGE_PATH"].map {
                URL(fileURLWithPath: $0)
            },
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/MillerCapabilityBridge"),
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("MillerCapabilityBridge"),
        ]
        return candidates.compactMap { $0 }.first {
            $0.isFileURL && $0.path.hasPrefix("/")
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func prepareCapabilityTrustedParent(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func nodeURL(environment: [String: String]) throws -> URL {
        if let path = environment["MILLER_NODE_PATH"] {
            return URL(fileURLWithPath: path)
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Gateway/runtime/node")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let development = URL(
            fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"
        )
        guard FileManager.default.isExecutableFile(atPath: development.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return development
    }

    static func helperArguments(
        helperURL: URL,
        environment: [String: String]
    ) -> [String] {
        var arguments = [helperURL.path]
        if let mode = environment["MILLER_FAKE_HELPER_MODE"], !mode.isEmpty {
            arguments.append(mode)
        }
        return arguments
    }

    nonisolated static func typedCodexProcessConfiguration(
        executableURL: URL,
        temporaryParentURL: URL,
        environment: [String: String],
        bridgeConfiguration: CodexMCPBridgeConfiguration? = nil,
        spawnedProcessVerifier: @escaping @Sendable (pid_t) throws -> Void
    ) throws -> CodexAppServerProcess.Configuration {
        let bridgeKeys = [
            "MILLER_CAPABILITY_BRIDGE_PATH",
            "MILLER_CAPABILITY_RPC_SOCKET",
            "MILLER_CAPABILITY_RPC_TOKEN",
            "MILLER_CAPABILITY_PROVIDER_PROFILE_ID",
            "MILLER_CAPABILITY_RPC_TRUSTED_PARENT",
        ]
        let values = bridgeKeys.map { environment[$0] }
        let appServerArguments: [String]
        let additionalEnvironment: [String: String]
        if let bridgeConfiguration {
            appServerArguments = bridgeConfiguration.appServerArguments()
            additionalEnvironment = bridgeConfiguration.additionalEnvironment
        } else if values.allSatisfy({ $0 != nil }),
           let bridgePath = values[0],
           let socketPath = values[1],
           let token = values[2],
           let profileText = values[3],
           let profileID = UUID(uuidString: profileText),
           let trustedParent = values[4]
        {
            let bridge = try CodexMCPBridgeConfiguration(
                executableURL: URL(fileURLWithPath: bridgePath),
                socketPath: socketPath,
                sessionToken: token,
                providerProfileID: profileID,
                trustedParentPath: trustedParent
            )
            appServerArguments = bridge.appServerArguments()
            additionalEnvironment = bridge.additionalEnvironment
        } else {
            guard values.allSatisfy({ $0 == nil }) else {
                throw LiveProcessError.invalidConfiguration
            }
            appServerArguments = [
                "app-server", "--listen", "stdio://", "--strict-config",
            ]
            additionalEnvironment = [:]
        }
        return try .init(
            executableURL: executableURL,
            arguments: CodexTypedProtocol.permissionProfileArguments
                + appServerArguments,
            temporaryParentURL: temporaryParentURL,
            additionalEnvironment: additionalEnvironment,
            spawnedProcessVerifier: spawnedProcessVerifier
        )
    }

    nonisolated private static func makeTypedRequestWorkspace(parent: URL) throws -> URL {
        let trustedParent = parent.standardizedFileURL
        guard trustedParent.isFileURL,
              trustedParent.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: trustedParent.path)
        else { throw LiveProcessError.invalidConfiguration }
        let root = trustedParent.appendingPathComponent(
            "miller-typed-request.\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard root.deletingLastPathComponent().standardizedFileURL == trustedParent
        else { throw LiveProcessError.invalidConfiguration }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    nonisolated private static func removeTypedRequestWorkspace(
        _ root: URL,
        parent: URL
    ) throws {
        let trustedParent = parent.standardizedFileURL
        let candidate = root.standardizedFileURL
        guard candidate.deletingLastPathComponent() == trustedParent,
              candidate.lastPathComponent.hasPrefix("miller-typed-request.")
        else { throw LiveProcessError.invalidConfiguration }
        let values = try candidate.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LiveProcessError.invalidConfiguration
        }
        try FileManager.default.removeItem(at: candidate)
    }

    private static func cacheURL(environment: [String: String]) -> URL {
        if let path = environment["MILLER_CACHE_PATH"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ai.millrace.miller/helper", isDirectory: true)
    }

    static func liveHelperURL(
        arguments: [String],
        helperVerifier: @escaping @Sendable (URL) throws -> Void = {
            try CodexAppServerHelperVerifier().verify($0)
        }
    ) throws -> URL? {
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [],
            verify: helperVerifier
        )
        return try liveRuntimeSelection(
            arguments: arguments,
            savedPath: nil,
            resolver: resolver
        )?.executableURL
    }

    nonisolated static func liveRuntimeSelection(
        arguments: [String],
        savedPath: String?,
        resolver: CodexRuntimeResolver
    ) throws -> CodexRuntimeSelection? {
        try liveRuntimeResolution(
            arguments: arguments,
            savedPath: savedPath,
            resolver: resolver
        ).selection
    }

    nonisolated static func liveRuntimeResolution(
        arguments: [String],
        savedPath: String?,
        resolver: CodexRuntimeResolver
    ) throws -> CodexRuntimeReadiness {
        let positions = arguments.indices.filter {
            arguments[$0] == "--gpt-live-app-server"
        }
        guard !positions.isEmpty else {
            return resolver.resolveReadiness(savedPath: savedPath)
        }
        guard positions.count == 1, let position = positions.first,
              arguments.indices.contains(position + 1)
        else { throw LiveProcessError.invalidConfiguration }
        let path = arguments[position + 1]
        guard path.hasPrefix("/"), !path.isEmpty else {
            throw LiveProcessError.invalidConfiguration
        }
        return .available(try resolver.resolveCandidate(
            URL(fileURLWithPath: path),
            source: .developmentOverride
        ))
    }
}

actor ProviderSettingsController {
    private let repository: SQLiteConversationRepository
    private let credentials: KeychainCredentialStore
    private let credentialCoordinator: CredentialCoordinator
    private let gatewayCredentials: GatewayCredentialHelper
    private let profileService: ProviderProfileService
    private let supervisor: GatewaySupervisor
    private let databaseURL: URL
    private let cacheURL: URL
    private let codexTypedReadiness: @Sendable (
        ProviderProfile
    ) async throws -> CodexTypedReadiness
    private let codexTypedRemoteReadiness: @Sendable (
        ProviderProfile
    ) async throws -> CodexTypedReadiness
    private let testAfterCredentialInvalidation: @Sendable () async -> Void
    private let testAfterCredentialLoad: @Sendable () async -> Void
    private var cachedCodexReadiness: (profileID: UUID, result: CodexTypedReadiness)?
    private var cachedRemoteCodexReadiness: (
        profileID: UUID, result: CodexTypedReadiness
    )?
    private var readinessGeneration = 0

    init(
        repository: SQLiteConversationRepository,
        credentials: KeychainCredentialStore,
        supervisor: GatewaySupervisor,
        databaseURL: URL,
        cacheURL: URL,
        codexTypedReadiness: @escaping @Sendable (
            ProviderProfile
        ) async throws -> CodexTypedReadiness,
        codexTypedRemoteReadiness: @escaping @Sendable (
            ProviderProfile
        ) async throws -> CodexTypedReadiness,
        testAfterCredentialInvalidation: @escaping @Sendable () async -> Void = {},
        testAfterCredentialLoad: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.credentials = credentials
        self.supervisor = supervisor
        let helper = GatewayCredentialHelper(supervisor: supervisor)
        gatewayCredentials = helper
        credentialCoordinator = CredentialCoordinator(
            store: credentials,
            helper: helper,
            profiles: repository
        )
        profileService = ProviderProfileService(
            repository: repository,
            credentials: credentials
        )
        self.databaseURL = databaseURL
        self.cacheURL = cacheURL
        self.codexTypedReadiness = codexTypedReadiness
        self.codexTypedRemoteReadiness = codexTypedRemoteReadiness
        self.testAfterCredentialInvalidation = testAfterCredentialInvalidation
        self.testAfterCredentialLoad = testAfterCredentialLoad
    }

    private func invalidateCodexReadiness() {
        cachedCodexReadiness = nil
        cachedRemoteCodexReadiness = nil
        readinessGeneration &+= 1
    }

    private func remoteReadiness(
        for profile: ProviderProfile
    ) async -> CodexTypedReadiness {
        do {
            return try await codexTypedRemoteReadiness(profile)
        } catch let error as GPTLiveCredentialError
            where error == .invalidCredential {
            return .init(state: .localCredentialUnavailable)
        } catch {
            return .init(state: .appServerUnavailable)
        }
    }

    func snapshot() async throws -> ProviderSettingsSnapshot {
        try await snapshot(retriesRemaining: 1)
    }

    private func snapshot(retriesRemaining: Int) async throws -> ProviderSettingsSnapshot {
        let generation = readinessGeneration
        let profiles = try await repository.providerProfiles()
        if let replacement = try await snapshotAfterGenerationChange(
            generation: generation,
            retriesRemaining: retriesRemaining
        ) {
            return replacement
        }
        guard let selected = profiles.first(where: \.isSelected) else {
            return .init(
                profiles: profiles.map(ProviderSettingsProfile.init),
                readiness: "Not configured"
            )
        }
        let catalog: GatewayModelCatalog?
        if selected.kind == .codexOAuth {
            catalog = try? await gatewayCredentials.codexModelCatalog()
        } else {
            catalog = nil
        }
        let codexModels = catalog?.models ?? []
        let codexDefaultModel = catalog?.defaultModel ?? ""
        if let replacement = try await snapshotAfterGenerationChange(
            generation: generation,
            retriesRemaining: retriesRemaining,
            codexModels: codexModels,
            codexDefaultModel: codexDefaultModel
        ) {
            return replacement
        }
        let credentialIsInvalidated = try await repository.credentialIsInvalidated(
            reference: selected.credentialReference
        )
        await testAfterCredentialInvalidation()
        if let replacement = try await snapshotAfterGenerationChange(
            generation: generation,
            retriesRemaining: retriesRemaining,
            codexModels: codexModels,
            codexDefaultModel: codexDefaultModel
        ) {
            return replacement
        }
        if credentialIsInvalidated {
            if let replacement = try await snapshotAfterGenerationChange(
                generation: generation,
                retriesRemaining: retriesRemaining,
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            ) {
                return replacement
            }
            invalidateCodexReadiness()
            return .init(
                profiles: profiles.map(ProviderSettingsProfile.init),
                readiness: "Local credential unavailable",
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            )
        }
        do {
            _ = try await credentials.load(for: selected.credentialReference)
            await testAfterCredentialLoad()
            if let replacement = try await snapshotAfterGenerationChange(
                generation: generation,
                retriesRemaining: retriesRemaining,
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            ) {
                return replacement
            }
        } catch {
            if let replacement = try await snapshotAfterGenerationChange(
                generation: generation,
                retriesRemaining: retriesRemaining,
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            ) {
                return replacement
            }
            invalidateCodexReadiness()
            return .init(
                profiles: profiles.map(ProviderSettingsProfile.init),
                readiness: "Local credential unavailable",
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            )
        }
        if selected.kind == .codexOAuth {
            let observed: CodexTypedReadiness
            if let cached = cachedRemoteCodexReadiness,
               cached.profileID == selected.id
            {
                observed = cached.result
            } else if let cached = cachedCodexReadiness,
               cached.profileID == selected.id
            {
                observed = cached.result
            } else {
                let generation = readinessGeneration
                do {
                    observed = try await codexTypedReadiness(selected)
                    if readinessGeneration == generation {
                        cachedCodexReadiness = (selected.id, observed)
                    }
                } catch let error as GPTLiveCredentialError
                    where error == .invalidCredential {
                    let result = CodexTypedReadiness(
                        state: .localCredentialUnavailable
                    )
                    if readinessGeneration == generation {
                        cachedCodexReadiness = (selected.id, result)
                    }
                    observed = result
                } catch {
                    let result = CodexTypedReadiness(
                        state: .appServerUnavailable
                    )
                    if readinessGeneration == generation {
                        cachedCodexReadiness = (selected.id, result)
                    }
                    observed = result
                }
            }
            if let replacement = try await snapshotAfterGenerationChange(
                generation: generation,
                retriesRemaining: retriesRemaining,
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            ) {
                return replacement
            }
            guard observed.state == .ready else {
                return .init(
                    profiles: profiles.map(ProviderSettingsProfile.init),
                    readiness: observed.ownerFacingStatus,
                    codexModels: codexModels,
                    codexDefaultModel: codexDefaultModel
                )
            }
            return .init(
                profiles: profiles.map(ProviderSettingsProfile.init),
                readiness: observed.ownerFacingStatus,
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            )
        }
        let readiness: String
        do {
            readiness = Self.readinessText(
                try await gatewayCredentials.readiness(for: selected),
                selectedModel: selected.model,
                catalog: catalog
            )
        } catch {
            readiness = "Helper readiness unavailable"
        }
        if let replacement = try await snapshotAfterGenerationChange(
            generation: generation,
            retriesRemaining: retriesRemaining,
            codexModels: codexModels,
            codexDefaultModel: codexDefaultModel
        ) {
            return replacement
        }
        return .init(
            profiles: profiles.map(ProviderSettingsProfile.init),
            readiness: readiness,
            codexModels: codexModels,
            codexDefaultModel: codexDefaultModel
        )
    }

    private func snapshotAfterGenerationChange(
        generation: Int,
        retriesRemaining: Int,
        codexModels: [GatewayModelChoice] = [],
        codexDefaultModel: String = ""
    ) async throws -> ProviderSettingsSnapshot? {
        guard readinessGeneration != generation else { return nil }
        guard retriesRemaining > 0 else {
            let currentProfiles = try await repository.providerProfiles()
            return .init(
                profiles: currentProfiles.map(ProviderSettingsProfile.init),
                readiness: "Readiness changing; retry",
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            )
        }
        return try await snapshot(retriesRemaining: retriesRemaining - 1)
    }

    func saveCodexModel(_ rawModel: String) async throws {
        invalidateCodexReadiness()
        defer { invalidateCodexReadiness() }
        guard let existing = try await repository.selectedProviderProfile(),
              existing.kind == .codexOAuth
        else {
            throw ProviderProfileError.profileNotFound
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validCodexModelID(model) else {
            throw ProviderProfileError.invalidModel
        }
        let updated = try ProviderProfile(
            id: existing.id,
            kind: existing.kind,
            label: existing.label,
            baseURL: existing.baseURL,
            model: model,
            credentialReference: existing.credentialReference,
            isSelected: existing.isSelected,
            createdAt: existing.createdAt
        )
        try await repository.saveProviderProfile(updated)
    }

    func saveOpenAICompatible(
        _ input: ProviderSettingsInput,
        hasActiveTurn: Bool
    ) async throws {
        invalidateCodexReadiness()
        defer { invalidateCodexReadiness() }
        guard !hasActiveTurn else { throw ProviderProfileError.activeTurn }
        let profiles = try await repository.providerProfiles()
        let existing = input.profileID.flatMap { id in
            profiles.first(where: { $0.id == id })
        }
        if input.profileID != nil && existing == nil {
            throw ProviderProfileError.profileNotFound
        }
        if let existing, existing.kind != .openAICompatible {
            throw ProviderProfileError.profileNotFound
        }
        let profile = try ProviderProfile(
            id: existing?.id ?? UUID(),
            kind: .openAICompatible,
            label: input.label,
            baseURL: input.endpoint,
            model: input.model,
            credentialReference: existing?.credentialReference ?? UUID(),
            isSelected: true,
            createdAt: existing?.createdAt ?? Date()
        )
        guard !input.apiKey.isEmpty || existing != nil else {
            throw CredentialError.storageFailed
        }
        let wroteCredential = !input.apiKey.isEmpty
        if wroteCredential {
            let payload = try JSONSerialization.data(
                withJSONObject: ["kind": "api_key", "key": input.apiKey],
                options: [.sortedKeys]
            )
            try await credentials.store(
                CredentialEnvelope(
                    providerKind: .openAICompatible,
                    payload: payload
                ),
                for: profile.credentialReference
            )
        }
        do {
            try await repository.saveProviderProfile(profile)
        } catch {
            if existing == nil && wroteCredential {
                try? await credentials.delete(for: profile.credentialReference)
            }
            throw error
        }
        _ = try await credentialCoordinator.restore(
            reference: profile.credentialReference
        )
    }

    func select(_ id: UUID, hasActiveTurn: Bool) async throws {
        invalidateCodexReadiness()
        defer { invalidateCodexReadiness() }
        try await profileService.selectProfile(id: id, hasActiveTurn: hasActiveTurn)
        _ = try await credentialCoordinator.restoreSelectedProfile()
    }

    func beginCodexLogin(hasActiveTurn: Bool) async throws {
        invalidateCodexReadiness()
        defer { invalidateCodexReadiness() }
        guard !hasActiveTurn else { throw ProviderProfileError.activeTurn }
        let catalog = try await gatewayCredentials.codexModelCatalog()
        guard !catalog.defaultModel.isEmpty else {
            throw GatewayProtocolError.invalidField
        }
        let profiles = try await repository.providerProfiles()
        let profile: ProviderProfile
        if let existing = profiles.first(where: { $0.kind == .codexOAuth }) {
            if existing.model == "gpt-5" {
                profile = try ProviderProfile(
                    id: existing.id,
                    kind: existing.kind,
                    label: existing.label,
                    baseURL: existing.baseURL,
                    model: catalog.defaultModel,
                    credentialReference: existing.credentialReference,
                    isSelected: existing.isSelected,
                    createdAt: existing.createdAt
                )
                try await repository.saveProviderProfile(profile)
            } else {
                profile = existing
            }
        } else {
            profile = try ProviderProfile(
                kind: .codexOAuth,
                label: "Codex OAuth",
                baseURL: nil,
                model: catalog.defaultModel,
                isSelected: true
            )
            try await repository.saveProviderProfile(profile)
        }
        try await profileService.selectProfile(id: profile.id, hasActiveTurn: hasActiveTurn)
        try await gatewayCredentials.authenticate(
            reference: profile.credentialReference,
            providerKind: .codexOAuth,
            openURL: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            },
            persistCandidate: { [credentialCoordinator] candidate in
                try await credentialCoordinator.persistCandidate(
                    candidate,
                    for: profile.credentialReference,
                    hasActiveTurn: hasActiveTurn
                )
            }
        )
    }

    func refreshCodexAuthentication(hasActiveTurn: Bool) async throws {
        invalidateCodexReadiness()
        guard !hasActiveTurn else { throw ProviderProfileError.activeTurn }
        guard let profile = try await repository.selectedProviderProfile(),
              profile.kind == .codexOAuth
        else {
            throw ProviderProfileError.profileNotFound
        }
        try await gatewayCredentials.authenticate(
            reference: profile.credentialReference,
            providerKind: .codexOAuth,
            refresh: true,
            openURL: { _ in },
            persistCandidate: { [credentialCoordinator] candidate in
                try await credentialCoordinator.persistCandidate(
                    candidate,
                    for: profile.credentialReference,
                    hasActiveTurn: hasActiveTurn
                )
            }
        )
        let generation = readinessGeneration
        let observed = await remoteReadiness(for: profile)
        if readinessGeneration == generation {
            cachedRemoteCodexReadiness = (profile.id, observed)
        }
    }

    func restoreSelectedProfile() async throws {
        invalidateCodexReadiness()
        defer { invalidateCodexReadiness() }
        _ = try await credentialCoordinator.restoreSelectedProfile()
    }

    func retryReadiness() async throws -> ProviderSettingsSnapshot {
        invalidateCodexReadiness()
        if let selected = try await repository.selectedProviderProfile(),
           selected.kind == .codexOAuth
        {
            let generation = readinessGeneration
            let observed = await remoteReadiness(for: selected)
            if readinessGeneration == generation {
                cachedRemoteCodexReadiness = (selected.id, observed)
            }
        }
        return try await snapshot()
    }

    func localLogout(hasActiveTurn: Bool) async throws {
        invalidateCodexReadiness()
        defer { invalidateCodexReadiness() }
        guard let selected = try await repository.selectedProviderProfile()
        else {
            throw ProviderProfileError.profileNotFound
        }
        try await credentialCoordinator.logout(
            reference: selected.credentialReference,
            hasActiveTurn: hasActiveTurn
        )
    }

    func delete(_ id: UUID, hasActiveTurn: Bool) async throws {
        invalidateCodexReadiness()
        defer { invalidateCodexReadiness() }
        guard !hasActiveTurn else { throw ProviderProfileError.activeTurn }
        guard let profile = try await repository.providerProfiles().first(where: {
            $0.id == id
        }) else {
            throw ProviderProfileError.profileNotFound
        }
        if profile.isSelected {
            try await gatewayCredentials.clear(
                reference: profile.credentialReference
            )
        }
        try await profileService.deleteProfile(id: id, hasActiveTurn: hasActiveTurn)
        _ = try await credentialCoordinator.restoreSelectedProfile()
    }

    func reset() async -> ResetResult {
        invalidateCodexReadiness()
        defer { invalidateCodexReadiness() }
        let service = ResetService(
            databaseURL: databaseURL,
            cacheURLs: [cacheURL],
            credentialStore: credentials,
            stopAndReapHelper: { [supervisor] in
                await supervisor.shutdown()
            },
            closeDatabase: { [repository] in
                await repository.close()
            },
            reopenDatabase: { [repository] in
                try await repository.reopen()
            },
            resumeRuntime: { [cacheURL] in
                try FileManager.default.createDirectory(
                    at: cacheURL,
                    withIntermediateDirectories: true
                )
            }
        )
        return await service.reset()
    }

    private static func readinessText(
        _ readiness: GatewayProviderReadiness,
        selectedModel: String,
        catalog: GatewayModelCatalog?
    ) -> String {
        switch readiness.status {
        case "ready":
            if catalog?.models.contains(where: { $0.id == selectedModel }) == false {
                return "Ready — custom model availability will be confirmed on first use"
            }
            return "Ready"
        case "refresh_required": return "Refresh required"
        case "authentication_required": return "Authentication required"
        case "configuration_invalid": return "Provider configuration is invalid"
        case "network_unavailable": return "Network unavailable"
        case "provider_unavailable": return "Provider unavailable"
        case "unsupported_model": return "Selected model is unsupported"
        default: return "Provider readiness unavailable"
        }
    }

    private static func validCodexModelID(_ model: String) -> Bool {
        guard !model.isEmpty, model.count <= 200 else { return false }
        return model.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 46, 95, 45, 47, 58:
                true
            default:
                false
            }
        }
    }
}

enum SettingsWindowConfiguration {
    @MainActor
    static func apply(to window: NSWindow) {
        let minimumSize = NSSize(
            width: SettingsLayout.minimumWidth,
            height: SettingsLayout.minimumHeight
        )
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumSize
        let currentSize = window.contentView?.bounds.size ?? .zero
        window.setContentSize(
            NSSize(
                width: max(currentSize.width, minimumSize.width),
                height: max(currentSize.height, minimumSize.height)
            )
        )
    }
}

private final class NSHostingWindow<Content: View>: NSWindow {
    init(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Miller Settings"
        contentView = NSHostingView(rootView: rootView)
        SettingsWindowConfiguration.apply(to: self)
        isReleasedWhenClosed = false
    }
}

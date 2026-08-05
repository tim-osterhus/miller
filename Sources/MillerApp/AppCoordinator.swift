import AppKit
import Combine
import Foundation
import MillerCore
import MillerGateway
import MillerLive
import MillerLiveAudio
import MillerStorage
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
    let stop: @Sendable () async throws -> Void
    let loadTurn: @Sendable (TurnID) async throws -> Turn?
    let loadConversations: @Sendable () async throws -> [Conversation]
    let loadTurns: @Sendable (ConversationID) async throws -> [Turn]
    let archive: @Sendable (ConversationID) async throws -> Void
    let unarchive: @Sendable (ConversationID) async throws -> Void
    let delete: @Sendable (ConversationID) async throws -> Void

    init(
        submit: @escaping @Sendable (String, ConversationID) async throws -> TurnID,
        stop: @escaping @Sendable () async throws -> Void,
        loadTurn: @escaping @Sendable (TurnID) async throws -> Turn?,
        loadConversations: @escaping @Sendable () async throws -> [Conversation],
        loadTurns: @escaping @Sendable (ConversationID) async throws -> [Turn],
        archive: @escaping @Sendable (ConversationID) async throws -> Void,
        unarchive: @escaping @Sendable (ConversationID) async throws -> Void,
        delete: @escaping @Sendable (ConversationID) async throws -> Void
    ) {
        submitOperation = { text, conversationID, _ in
            try await submit(text, conversationID)
        }
        self.stop = stop
        self.loadTurn = loadTurn
        self.loadConversations = loadConversations
        self.loadTurns = loadTurns
        self.archive = archive
        self.unarchive = unarchive
        self.delete = delete
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
        delete: @escaping @Sendable (ConversationID) async throws -> Void
    ) {
        submitOperation = submit
        self.stop = stop
        self.loadTurn = loadTurn
        self.loadConversations = loadConversations
        self.loadTurns = loadTurns
        self.archive = archive
        self.unarchive = unarchive
        self.delete = delete
    }

    func submit(
        _ text: String,
        _ conversationID: ConversationID,
        _ voiceHistoryAttachment: VoiceHistoryAttachment? = nil
    ) async throws -> TurnID {
        try await submitOperation(text, conversationID, voiceHistoryAttachment)
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
    @Published private(set) var voiceHistorySessions: [VoiceHistorySession] = []
    @Published private(set) var pendingVoiceHistoryAttachment:
        PreparedVoiceHistoryAttachment?
    @Published private(set) var voiceHistoryStatus: String?

    private let dependencies: HostDependencies
    private let providerSettings: ProviderSettingsDependencies
    private let liveVoice: LiveVoiceDependencies
    private let liveTranscriptRecorder: LiveVoiceTranscriptRecorder
    private let voiceHistory: VoiceHistoryDependencies
    private let voiceHistoryAttachmentBuilder = VoiceHistoryAttachmentBuilder()
    private var turnObservation: Task<Void, Never>?
    private var shortcutRegistration: ((GlobalShortcut) -> Bool)?
    private var liveVoiceStartPending = false
    private var liveTranscriptProjection = LiveTranscriptProjection()
    private var liveVoiceCleanupPending = false
    private var liveVoiceCleanupRetryPending = false
    private var pendingLiveTranscriptCleanup: PendingLiveTranscriptCleanup?
    private var liveVoiceCleanupWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private var typedSubmissionPending = false
    @Published private var providerMutationPending = false
    @Published private var liveVoiceAvailability: LiveVoiceState
    private var liveVoiceAvailabilityGeneration: UInt64 = 0
    private var liveVoiceEventGeneration: UInt64 = 0
    private var providerSnapshotGeneration: UInt64 = 0
    private var conversationProjectionGeneration: UInt64 = 0
    private var voiceHistoryGeneration: UInt64 = 0
    private var pendingVoiceActivationSource: VoiceActivationSource = .manual

    private struct PendingLiveTranscriptCleanup {
        let terminalState: LiveVoiceState
        let outcome: VoiceSessionTerminalOutcome
    }

    init(
        dependencies: HostDependencies,
        providerSettings: ProviderSettingsDependencies = .unavailable,
        liveVoice: LiveVoiceDependencies = .unavailable,
        liveTranscriptRecorder: LiveVoiceTranscriptRecorder = .init(),
        voiceHistory: VoiceHistoryDependencies = .unavailable
    ) {
        self.dependencies = dependencies
        self.providerSettings = providerSettings
        self.liveVoice = liveVoice
        self.liveTranscriptRecorder = liveTranscriptRecorder
        self.voiceHistory = voiceHistory
        voiceState = liveVoice.initialAvailability
        liveVoiceAvailability = liveVoice.initialAvailability
    }

    var isActiveTurn: Bool {
        activeTurnID != nil
    }

    private var hasActiveConversationOrVoiceOperation: Bool {
        isActiveTurn || voiceState.isActive
            || typedSubmissionPending
            || liveVoiceStartPending || liveVoiceCleanupPending
    }

    var isActiveOperation: Bool {
        hasActiveConversationOrVoiceOperation || providerMutationPending
    }

    var canSubmit: Bool {
        !isActiveTurn && !voiceState.isActive
            && !typedSubmissionPending
            && !liveVoiceStartPending && !liveVoiceCleanupPending
            && !providerMutationPending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canStartLiveVoice: Bool {
        [.available, .closed, .stopped, .failed].contains(voiceState)
            && liveVoiceAvailability == .available
            && !isActiveTurn && !typedSubmissionPending
            && !liveVoiceStartPending && !liveVoiceCleanupPending
            && !providerMutationPending
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
        return switch voiceState {
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
    }

    var menuState: MenuState {
        .derive(activeTurn: isActiveOperation)
    }

    var statusText: String {
        if voiceState.isActive || voiceState == .stopped || voiceState == .closed {
            return voiceStatusText
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
            _ = apply(snapshot, generation: generation)
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
        let generation = beginProviderMutation()
        let projectionGeneration = nextConversationProjectionGeneration()
        defer { providerMutationPending = false }
        let result = await providerSettings.reset()
        await refreshLiveVoiceAvailability()
        do {
            _ = apply(
                try await providerSettings.load(),
                generation: generation
            )
        } catch {
            clearProviderSnapshot(generation: generation)
        }
        await rebuildPresentationAfterReset(generation: projectionGeneration)
        resetResults = result.roots
        setProviderStatus(
            result.failures.isEmpty
                ? "Reset completed; secure erasure is not claimed."
                : "Reset incomplete; review failed roots.",
            generation: generation
        )
    }

    func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeTurnID == nil, !voiceState.isActive,
              !typedSubmissionPending,
              !liveVoiceStartPending, !liveVoiceCleanupPending,
              !providerMutationPending else {
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
        do {
            voiceHistorySessions = try await voiceHistory.sessions(start, end)
            voiceHistoryStatus = nil
        } catch {
            voiceHistorySessions = []
            voiceHistoryStatus = "Voice history is unavailable."
        }
    }

    func prepareVoiceHistoryAttachment(sessionIDs: [UUID]) async {
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
            let projection = try await checkedProjection(sessionIDs: sessionIDs)
            try VoiceHistoryExportDocument.write(projection, to: url)
            voiceHistoryStatus = "Voice history exported."
        } catch {
            voiceHistoryStatus = "Voice history export failed."
        }
    }

    func exportVoiceHistory(from start: Date, through end: Date, to url: URL) async {
        do {
            let sessions = try await voiceHistory.sessions(start, end)
            let projection = try await checkedProjection(
                sessionIDs: sessions.map(\.id)
            )
            try VoiceHistoryExportDocument.write(projection, to: url)
            voiceHistoryStatus = "Voice history exported."
        } catch {
            voiceHistoryStatus = "Voice history export failed."
        }
    }

    func deleteVoiceHistorySession(_ id: UUID) async {
        voiceHistoryGeneration &+= 1
        do {
            try await voiceHistory.deleteSession(id)
            clearPendingVoiceHistory(ifItContains: [id])
            await refreshVoiceHistory()
        } catch {
            voiceHistoryStatus = "Voice history deletion failed."
        }
    }

    func deleteVoiceHistory(from start: Date, through end: Date) async {
        voiceHistoryGeneration &+= 1
        do {
            let deleted = try await voiceHistory.sessions(start, end).map(\.id)
            try await voiceHistory.deleteRange(start, end)
            clearPendingVoiceHistory(ifItContains: deleted)
            await refreshVoiceHistory()
        } catch {
            voiceHistoryStatus = "Voice history deletion failed."
        }
    }

    func deleteAllVoiceHistory() async {
        voiceHistoryGeneration &+= 1
        do {
            try await voiceHistory.deleteAll()
            pendingVoiceHistoryAttachment = nil
            await refreshVoiceHistory()
        } catch {
            voiceHistoryStatus = "Voice history deletion failed."
        }
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

    func startLiveVoice(
        activationSource: VoiceActivationSource = .manual
    ) async {
        guard canStartLiveVoice else { return }
        nextLiveVoiceAvailabilityGeneration()
        let eventGeneration = nextLiveVoiceEventGeneration()
        liveVoiceStartPending = true
        voiceState = .connecting
        liveVoiceFailureCode = nil
        liveTranscriptPersistenceMessage = nil
        resetLiveTranscripts()
        liveVoiceMuted = false
        pendingVoiceActivationSource = activationSource
        do {
            try await liveVoice.start { [weak self] event in
                await self?.applyLiveEvent(event, generation: eventGeneration)
            }
        } catch {
            voiceState = .failed
            liveVoiceFailureCode = Self.liveFailureCode(error)
            if Self.isLiveAdmissionFailure(error) {
                nextLiveVoiceAvailabilityGeneration()
                liveVoiceAvailability = .unavailable
            }
        }
        liveVoiceStartPending = false
        if !liveVoiceCleanupPending, !voiceState.isActive {
            let outcome: VoiceSessionTerminalOutcome =
                voiceState == .failed ? .failed
                : voiceState == .closed ? .completed : .abandoned
            await finishLiveVoiceCleanup(
                terminalState: voiceState,
                outcome: outcome
            )
        }
        if !voiceState.isActive, liveVoiceAvailability == .available {
            await refreshLiveVoiceAvailability()
        }
    }

    func toggleLiveMute() async {
        guard voiceState.isActive else { return }
        liveVoiceMuted.toggle()
        await liveVoice.mute(liveVoiceMuted)
    }

    func interruptLiveVoice() async {
        guard voiceState.isActive, !liveVoiceCleanupPending else { return }
        nextLiveVoiceAvailabilityGeneration()
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
        nextLiveVoiceAvailabilityGeneration()
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
        let cleanup = pendingLiveTranscriptCleanup
            ?? PendingLiveTranscriptCleanup(
                terminalState: terminalState,
                outcome: outcome
            )
        pendingLiveTranscriptCleanup = cleanup
        liveVoiceCleanupPending = true
        liveVoiceCleanupRetryPending = false
        var cleanupSucceeded = false
        for attempt in 0..<2 {
            do {
                try await liveTranscriptRecorder.finish(outcome: cleanup.outcome)
                cleanupSucceeded = true
                break
            } catch {
                guard attempt == 0, !(error is CancellationError) else { break }
                await Task.yield()
            }
        }
        if cleanupSucceeded {
            pendingLiveTranscriptCleanup = nil
            liveVoiceCleanupPending = false
        } else {
            presentTranscriptPersistenceFailure()
            liveVoiceCleanupRetryPending = true
        }
        liveVoiceMuted = false
        if voiceState != .failed {
            voiceState = cleanup.terminalState
        }
        let waiters = liveVoiceCleanupWaiters
        liveVoiceCleanupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func applyLiveEvent(_ event: LiveVoiceEvent) async {
        await applyLiveEvent(event, generation: liveVoiceEventGeneration)
    }

    private func applyLiveEvent(
        _ event: LiveVoiceEvent,
        generation: UInt64
    ) async {
        guard generation == liveVoiceEventGeneration else { return }
        switch event {
        case let .sessionAdmitted(id):
            do {
                try await liveTranscriptRecorder.begin(
                    sessionID: id,
                    conversationID: nil,
                    activationSource: pendingVoiceActivationSource
                )
            } catch {
                presentTranscriptPersistenceFailure()
            }
        case let .state(state):
            voiceState = state
        case .transcriptDelta, .transcriptDone:
            liveTranscriptProjection.record(event)
            liveTranscriptTurns = liveTranscriptProjection.turns
            do {
                try await liveTranscriptRecorder.record(event)
            } catch {
                presentTranscriptPersistenceFailure()
            }
        case let .failed(code):
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
            try await dependencies.stop()
            activeTurnID = nil
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
        nextConversationProjectionGeneration()
        selectedConversationID = ConversationID()
        visibleTurns = []
        draft = ""
        presentationState = .ready
        errorCode = nil
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
            visibleTurns = loaded
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
        turnObservation?.cancel()
        turnObservation = nil
        activeTurnID = nil
        selectedConversationID = ConversationID()
        draft = ""
        presentationState = .ready
        errorCode = nil
        resetLiveTranscripts()
        liveVoiceFailureCode = nil
        liveTranscriptPersistenceMessage = nil
        liveVoiceMuted = false
        voiceState = liveVoiceAvailability
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
            visibleTurns = loaded
        } catch {
            guard generation == conversationProjectionGeneration else { return }
            visibleTurns = []
        }
    }

    private func loadProviderSettings(generation: UInt64) async throws -> Bool {
        apply(try await providerSettings.load(), generation: generation)
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
        liveTranscriptTurns = liveTranscriptProjection.turns
    }

    private static func liveFailureCode(_ error: Error) -> String {
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
            case .helperExited, .invalidConfiguration, .processUnavailable:
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
        let gateway = JSONLReasoningGateway(
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
            }
        )
        core = MillerCoordinator(repository: repository, gateway: gateway)

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
            delete: { [core] id in try await core.delete(conversationID: id) }
        )
        let credentialStore = KeychainCredentialStore()
        providerController = ProviderSettingsController(
            repository: repository,
            credentials: credentialStore,
            supervisor: supervisor,
            databaseURL: URL(fileURLWithPath: databasePath),
            cacheURL: cacheURL
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
        let livePeerHost = OverlayLiveVoicePeerHost(makePeer: {
            WebKitLivePeer(nativeMicrophoneAuthorized: {
                SystemMicrophonePermission.current() == .authorized
            })
        })
        let liveVoice: LiveVoiceDependencies
        let runtimeVerifier = CodexAppServerHelperVerifier()
        let runtimeResolver = CodexRuntimeResolver(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: environment,
            verify: { try runtimeVerifier.verify($0) }
        )
        let runtimeSelection = try Self.liveRuntimeSelection(
            arguments: arguments,
            savedPath: CodexRuntimePreferences().loadPath(),
            resolver: runtimeResolver
        )
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
                makePeer: { [livePeerHost] in
                    try await MainActor.run { try livePeerHost.makePeer() }
                },
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
        let preferenceRepository = try SQLitePreferenceRepository(
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
            voiceHistory: voiceHistory
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        overlayController = OverlayPanelController(
            model: model,
            peerHost: livePeerHost
        )
        conversationController = ConversationWindowController(model: model)
        settingsController = NSWindowController(
            window: NSHostingWindow(rootView: SettingsView(model: model))
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
            try? await repository.recoverInterruptedTurns()
            await model.recoverInterruptedVoiceSessions()
            try? await providerController.restoreSelectedProfile()
            await model.refresh()
            await model.refreshProviderSettings()
            await model.refreshLiveVoiceAvailability()
        }
    }

    func shutdown() async {
        activationService.unregister()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        model.prepareToAbandonLiveVoiceSession()
        await liveController?.shutdown()
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
        let positions = arguments.indices.filter {
            arguments[$0] == "--gpt-live-app-server"
        }
        guard !positions.isEmpty else {
            return resolver.resolve(savedPath: savedPath)
        }
        guard positions.count == 1, let position = positions.first,
              arguments.indices.contains(position + 1)
        else { throw LiveProcessError.invalidConfiguration }
        let path = arguments[position + 1]
        guard path.hasPrefix("/"), !path.isEmpty else {
            throw LiveProcessError.invalidConfiguration
        }
        return try resolver.resolveCandidate(
            URL(fileURLWithPath: path),
            source: .developmentOverride
        )
    }
}

private actor ProviderSettingsController {
    private let repository: SQLiteConversationRepository
    private let credentials: KeychainCredentialStore
    private let credentialCoordinator: CredentialCoordinator
    private let gatewayCredentials: GatewayCredentialHelper
    private let profileService: ProviderProfileService
    private let supervisor: GatewaySupervisor
    private let databaseURL: URL
    private let cacheURL: URL

    init(
        repository: SQLiteConversationRepository,
        credentials: KeychainCredentialStore,
        supervisor: GatewaySupervisor,
        databaseURL: URL,
        cacheURL: URL
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
    }

    func snapshot() async throws -> ProviderSettingsSnapshot {
        let profiles = try await repository.providerProfiles()
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
        do {
            _ = try await credentials.load(for: selected.credentialReference)
        } catch CredentialError.itemNotFound {
            return .init(
                profiles: profiles.map(ProviderSettingsProfile.init),
                readiness: "Authentication required",
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            )
        } catch {
            return .init(
                profiles: profiles.map(ProviderSettingsProfile.init),
                readiness: "Local credential unavailable",
                codexModels: codexModels,
                codexDefaultModel: codexDefaultModel
            )
        }
        if try await repository.credentialIsInvalidated(
            reference: selected.credentialReference
        ) {
            return .init(
                profiles: profiles.map(ProviderSettingsProfile.init),
                readiness: "Authentication required",
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
        return .init(
            profiles: profiles.map(ProviderSettingsProfile.init),
            readiness: readiness,
            codexModels: codexModels,
            codexDefaultModel: codexDefaultModel
        )
    }

    func saveCodexModel(_ rawModel: String) async throws {
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
        try await profileService.selectProfile(id: id, hasActiveTurn: hasActiveTurn)
        _ = try await credentialCoordinator.restoreSelectedProfile()
    }

    func beginCodexLogin(hasActiveTurn: Bool) async throws {
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
    }

    func restoreSelectedProfile() async throws {
        _ = try await credentialCoordinator.restoreSelectedProfile()
    }

    func retryReadiness() async throws -> ProviderSettingsSnapshot {
        try await snapshot()
    }

    func localLogout(hasActiveTurn: Bool) async throws {
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

private final class NSHostingWindow<Content: View>: NSWindow {
    init(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Miller Settings"
        contentView = NSHostingView(rootView: rootView)
        isReleasedWhenClosed = false
    }
}

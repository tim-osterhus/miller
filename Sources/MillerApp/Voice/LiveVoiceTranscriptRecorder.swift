import Foundation
import MillerCore
import MillerStorage

struct LiveTranscriptTurn: Identifiable, Equatable {
    let id: Int
    let role: LiveTranscriptRole
    fileprivate(set) var text: String
    fileprivate(set) var isComplete: Bool
}

struct LiveTranscriptProjection {
    private static let maximumBytes = 65_536

    private(set) var turns: [LiveTranscriptTurn] = []
    private var nextID = 0
    private var lastCompletion: [LiveTranscriptRole: String] = [:]

    mutating func reset() {
        turns = []
        nextID = 0
        lastCompletion = [:]
    }

    mutating func record(_ event: LiveVoiceEvent) {
        switch event {
        case let .transcriptDelta(role, text):
            guard !text.isEmpty else { return }
            lastCompletion[role] = nil
            if let index = activeTurnIndex(for: role) {
                turns[index].text = Self.bounded(
                    turns[index].text + text,
                    maximumBytes: availableBytes(excluding: index)
                )
            } else {
                appendTurn(role: role, text: text, isComplete: false)
            }
        case let .transcriptDone(role, text):
            if activeTurnIndex(for: role) == nil,
               lastCompletion[role] == text {
                return
            }
            if let index = activeTurnIndex(for: role) {
                turns[index].text = Self.bounded(
                    text,
                    maximumBytes: availableBytes(excluding: index)
                )
                if turns[index].text.isEmpty {
                    turns.remove(at: index)
                } else {
                    turns[index].isComplete = true
                }
            } else {
                appendTurn(role: role, text: text, isComplete: true)
            }
            lastCompletion[role] = text
        case .sessionAdmitted, .state, .failed:
            break
        }
    }

    private func activeTurnIndex(for role: LiveTranscriptRole) -> Int? {
        turns.indices.reversed().first {
            turns[$0].role == role && !turns[$0].isComplete
        }
    }

    private mutating func appendTurn(
        role: LiveTranscriptRole,
        text: String,
        isComplete: Bool
    ) {
        let bounded = Self.bounded(text, maximumBytes: availableBytes(excluding: nil))
        guard !bounded.isEmpty else { return }
        turns.append(.init(
            id: nextID,
            role: role,
            text: bounded,
            isComplete: isComplete
        ))
        nextID += 1
    }

    private func availableBytes(excluding excludedIndex: Int?) -> Int {
        let retainedBytes = turns.indices.reduce(into: 0) { total, index in
            guard index != excludedIndex else { return }
            total += turns[index].text.utf8.count
        }
        return max(0, Self.maximumBytes - retainedBytes)
    }

    private static func bounded(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        result.reserveCapacity(maximumBytes)
        var byteCount = 0
        for character in text {
            let count = String(character).utf8.count
            guard byteCount + count <= maximumBytes else { break }
            result.append(character)
            byteCount += count
        }
        return result
    }
}

enum LiveVoiceTranscriptRecorderError: Error, Equatable {
    case sessionAlreadyActive
}

actor LiveVoiceTranscriptRecorder {
    struct Persistence: Sendable {
        let savingEnabled: @Sendable () async throws -> Bool
        let nextSessionSavingEnabled: @Sendable () async throws -> Bool
        let restoreNextSessionSavingDefault: @Sendable () async throws -> Void
        let startSession: @Sendable (
            UUID,
            ConversationID?,
            VoiceActivationSource,
            VoiceTranscriptSaveChoice
        ) async throws -> Void
        let appendEntry: @Sendable (
            UUID,
            UUID,
            Int,
            VoiceTranscriptRole,
            String,
            VoiceEntryCompletionState
        ) async throws -> Void
        let completeEntry: @Sendable (UUID, String) async throws -> Void
        let finalizeSession: @Sendable (
            UUID,
            VoiceSessionTerminalOutcome
        ) async throws -> Void
        let recoverInterruptedSessions: @Sendable () async throws -> Void

        static let disabled = Self(
            savingEnabled: { false },
            nextSessionSavingEnabled: { true },
            restoreNextSessionSavingDefault: {},
            startSession: { _, _, _, _ in },
            appendEntry: { _, _, _, _, _, _ in },
            completeEntry: { _, _ in },
            finalizeSession: { _, _ in },
            recoverInterruptedSessions: {}
        )
    }

    private struct PendingEntry {
        let id: UUID
        let sequence: Int
        let role: LiveTranscriptRole
        var text: String
    }

    private struct ActiveSession {
        let id: UUID
        let saveChoice: VoiceTranscriptSaveChoice
        var nextSequence = 0
        var pending: [LiveTranscriptRole: PendingEntry] = [:]
        var lastCompletion: [LiveTranscriptRole: String] = [:]
    }

    private static let maximumEntryBytes = 64 * 1_024

    private let persistence: Persistence
    private var activeSession: ActiveSession?

    init(persistence: Persistence = .disabled) {
        self.persistence = persistence
    }

    func begin(
        sessionID: UUID,
        conversationID: ConversationID?,
        activationSource: VoiceActivationSource
    ) async throws {
        guard activeSession == nil else {
            throw LiveVoiceTranscriptRecorderError.sessionAlreadyActive
        }
        let globallyEnabled = try await persistence.savingEnabled()
        let nextSessionEnabled = try await persistence.nextSessionSavingEnabled()
        if !nextSessionEnabled {
            try await persistence.restoreNextSessionSavingDefault()
        }
        let saveChoice: VoiceTranscriptSaveChoice =
            globallyEnabled && nextSessionEnabled ? .save : .discard
        try await persistence.startSession(
            sessionID,
            conversationID,
            activationSource,
            saveChoice
        )
        activeSession = ActiveSession(id: sessionID, saveChoice: saveChoice)
    }

    func record(_ event: LiveVoiceEvent) async throws {
        guard var active = activeSession else { return }
        switch event {
        case let .transcriptDelta(role, text):
            guard active.saveChoice == .save, !text.isEmpty else { return }
            active.lastCompletion[role] = nil
            if var pending = active.pending[role] {
                pending.text = Self.bounded(pending.text + text)
                active.pending[role] = pending
            } else {
                active.pending[role] = PendingEntry(
                    id: UUID(),
                    sequence: active.nextSequence,
                    role: role,
                    text: Self.bounded(text)
                )
                active.nextSequence += 1
            }
            activeSession = active
        case let .transcriptDone(role, text):
            guard active.saveChoice == .save else { return }
            if active.pending[role] == nil,
               active.lastCompletion[role] == text {
                return
            }
            let pending = active.pending.removeValue(forKey: role)
            let finalText = Self.bounded(text)
            if !finalText.isEmpty {
                let id = pending?.id ?? UUID()
                let sequence = pending?.sequence ?? active.nextSequence
                if pending == nil { active.nextSequence += 1 }
                try await persistence.appendEntry(
                    id,
                    active.id,
                    sequence,
                    Self.storageRole(role),
                    pending?.text ?? finalText,
                    .incomplete
                )
                try await persistence.completeEntry(id, finalText)
            }
            active.lastCompletion[role] = text
            activeSession = active
        case .sessionAdmitted, .state, .failed:
            break
        }
    }

    func finish(outcome: VoiceSessionTerminalOutcome) async throws {
        guard let active = activeSession else { return }
        defer { activeSession = nil }
        if active.saveChoice == .save {
            for pending in active.pending.values.sorted(by: {
                $0.sequence < $1.sequence
            }) where !pending.text.isEmpty {
                try await persistence.appendEntry(
                    pending.id,
                    active.id,
                    pending.sequence,
                    Self.storageRole(pending.role),
                    pending.text,
                    .incomplete
                )
            }
        }
        try await persistence.finalizeSession(active.id, outcome)
    }

    func recoverInterruptedSessions() async throws {
        try await persistence.recoverInterruptedSessions()
    }

    private static func storageRole(_ role: LiveTranscriptRole) -> VoiceTranscriptRole {
        role == .user ? .user : .assistant
    }

    private static func bounded(_ text: String) -> String {
        guard text.utf8.count > maximumEntryBytes else { return text }
        var result = ""
        result.reserveCapacity(maximumEntryBytes)
        var byteCount = 0
        for character in text {
            let count = String(character).utf8.count
            guard byteCount + count <= maximumEntryBytes else { break }
            result.append(character)
            byteCount += count
        }
        return result
    }
}

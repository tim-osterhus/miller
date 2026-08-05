import Foundation
import MillerCore

public enum VoiceActivationSource: String, Codable, Sendable {
    case manual
    case wakeword
}

public enum VoiceSessionTerminalOutcome: String, Codable, Sendable {
    case completed
    case stopped
    case failed
    case abandoned
}

public enum VoiceTranscriptSaveChoice: String, Codable, Sendable {
    case save
    case discard
}

public enum VoiceTranscriptRole: String, Codable, Sendable {
    case user
    case assistant
}

public enum VoiceEntryCompletionState: String, Codable, Sendable {
    case incomplete
    case complete
}

public struct VoiceHistorySession: Codable, Equatable, Sendable {
    public let id: UUID
    public let conversationID: ConversationID?
    public let activationSource: VoiceActivationSource
    public let startedAt: Date
    public let endedAt: Date?
    public let terminalOutcome: VoiceSessionTerminalOutcome?
    public let saveChoice: VoiceTranscriptSaveChoice

    public init(
        id: UUID,
        conversationID: ConversationID?,
        activationSource: VoiceActivationSource,
        startedAt: Date,
        endedAt: Date?,
        terminalOutcome: VoiceSessionTerminalOutcome?,
        saveChoice: VoiceTranscriptSaveChoice
    ) {
        self.id = id
        self.conversationID = conversationID
        self.activationSource = activationSource
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.terminalOutcome = terminalOutcome
        self.saveChoice = saveChoice
    }
}

public struct VoiceHistoryEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let sequence: Int
    public let role: VoiceTranscriptRole
    public let text: String
    public let completionState: VoiceEntryCompletionState
    public let startedAt: Date
    public let completedAt: Date?

    public init(
        id: UUID,
        sessionID: UUID,
        sequence: Int,
        role: VoiceTranscriptRole,
        text: String,
        completionState: VoiceEntryCompletionState,
        startedAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.role = role
        self.text = text
        self.completionState = completionState
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct VoiceHistoryExportSession: Codable, Equatable, Sendable {
    public let session: VoiceHistorySession
    public let entries: [VoiceHistoryEntry]

    public init(session: VoiceHistorySession, entries: [VoiceHistoryEntry]) {
        self.session = session
        self.entries = entries
    }
}

public struct VoiceHistoryAttachmentProjection: Equatable, Sendable {
    public let sessionIDs: [UUID]
    public let entries: [VoiceHistoryEntry]
    public let hasMore: Bool
    public let selectionIsValid: Bool

    public init(
        sessionIDs: [UUID],
        entries: [VoiceHistoryEntry],
        hasMore: Bool,
        selectionIsValid: Bool = true
    ) {
        self.sessionIDs = sessionIDs
        self.entries = entries
        self.hasMore = hasMore
        self.selectionIsValid = selectionIsValid
    }
}

public enum VoiceHistoryRepositoryError: Error, Equatable, Sendable {
    case entryTooLarge
    case invalidEntry
    case conflictingEntryReplay
    case sessionNotFound
    case entryNotFound
    case invalidRange
    case malformedRecord
}

public actor SQLiteVoiceHistoryRepository {
    private static let maximumEntryBytes = 64 * 1_024

    private let database: SQLiteDatabase
    private let simulatedWriteFailure: SQLiteError?

    public init(path: String = SQLiteConversationRepository.defaultPath) throws {
        database = try SQLiteDatabase(path: path)
        simulatedWriteFailure = nil
    }

    init(path: String, simulatedWriteFailure: SQLiteError) throws {
        database = try SQLiteDatabase(path: path)
        self.simulatedWriteFailure = simulatedWriteFailure
    }

    init(
        path: String,
        statementObserver: @escaping (String, Int) -> Void
    ) throws {
        database = try SQLiteDatabase(path: path, statementObserver: statementObserver)
        simulatedWriteFailure = nil
    }

    public func startSession(
        id: UUID = UUID(),
        conversationID: ConversationID?,
        activationSource: VoiceActivationSource,
        saveChoice: VoiceTranscriptSaveChoice,
        startedAt: Date = Date()
    ) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                INSERT INTO voice_sessions
                    (id, conversation_id, activation_source, started_at,
                     ended_at, terminal_outcome, save_choice)
                VALUES (?, ?, ?, ?, NULL, NULL, ?)
                """,
                bindings: [
                    .text(Self.id(id)),
                    conversationID.map { .text($0.description) } ?? .null,
                    .text(activationSource.rawValue),
                    .text(Self.timestamp(startedAt)),
                    .text(saveChoice.rawValue),
                ]
            )
        }
    }

    public func appendEntry(
        id: UUID = UUID(),
        sessionID: UUID,
        sequence: Int,
        role: VoiceTranscriptRole,
        text: String,
        completionState: VoiceEntryCompletionState,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) throws {
        try Self.validateEntry(
            text: text,
            sequence: sequence,
            completionState: completionState,
            startedAt: startedAt,
            completedAt: completedAt
        )
        try preflightWrite()
        try database.transaction {
            let existing = try database.query(
                """
                SELECT id, session_id, sequence, role, text, completion_state
                FROM voice_entries
                WHERE id = ? OR (session_id = ? AND sequence = ?)
                LIMIT 1
                """,
                bindings: [
                    .text(Self.id(id)), .text(Self.id(sessionID)),
                    .integer(Int64(sequence)),
                ]
            )
            if let row = existing.first {
                guard Self.string(row[1]) == Self.id(sessionID),
                      row[2] == .integer(Int64(sequence)),
                      Self.string(row[3]) == role.rawValue,
                      Self.string(row[4]) == text,
                      Self.string(row[5]) == completionState.rawValue
                else { throw VoiceHistoryRepositoryError.conflictingEntryReplay }
                return
            }
            try database.execute(
                """
                INSERT INTO voice_entries
                    (id, session_id, sequence, role, text, completion_state,
                     started_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(Self.id(id)),
                    .text(Self.id(sessionID)),
                    .integer(Int64(sequence)),
                    .text(role.rawValue),
                    .text(text),
                    .text(completionState.rawValue),
                    .text(Self.timestamp(startedAt)),
                    completedAt.map { .text(Self.timestamp($0)) } ?? .null,
                ]
            )
        }
    }

    public func completeEntry(
        id: UUID,
        text: String,
        completedAt: Date = Date()
    ) throws {
        guard text.utf8.count <= Self.maximumEntryBytes else {
            throw VoiceHistoryRepositoryError.entryTooLarge
        }
        try preflightWrite()
        try database.transaction {
            let rows = try database.query(
                "SELECT completion_state, started_at FROM voice_entries WHERE id = ?",
                bindings: [.text(Self.id(id))]
            )
            guard let row = rows.first,
                  case let .text(state) = row[0],
                  let startedValue = Self.string(row[1]),
                  let startedAt = Self.date(startedValue)
            else {
                throw VoiceHistoryRepositoryError.entryNotFound
            }
            guard completedAt >= startedAt else {
                throw VoiceHistoryRepositoryError.invalidEntry
            }
            guard state == VoiceEntryCompletionState.incomplete.rawValue else {
                return
            }
            try database.execute(
                """
                UPDATE voice_entries
                SET text = ?, completion_state = 'complete', completed_at = ?
                WHERE id = ? AND completion_state = 'incomplete'
                """,
                bindings: [
                    .text(text),
                    .text(Self.timestamp(completedAt)),
                    .text(Self.id(id)),
                ]
            )
        }
    }

    public func finalizeSession(
        id: UUID,
        outcome: VoiceSessionTerminalOutcome,
        endedAt: Date = Date()
    ) throws {
        try preflightWrite()
        try database.transaction {
            let rows = try database.query(
                "SELECT terminal_outcome, started_at FROM voice_sessions WHERE id = ?",
                bindings: [.text(Self.id(id))]
            )
            guard let row = rows.first else {
                throw VoiceHistoryRepositoryError.sessionNotFound
            }
            guard let startedValue = Self.string(row[1]),
                  let startedAt = Self.date(startedValue),
                  endedAt >= startedAt
            else { throw VoiceHistoryRepositoryError.invalidEntry }
            guard row.first == .null else {
                return
            }
            try database.execute(
                """
                UPDATE voice_sessions
                SET ended_at = ?, terminal_outcome = ?
                WHERE id = ? AND terminal_outcome IS NULL
                """,
                bindings: [
                    .text(Self.timestamp(endedAt)),
                    .text(outcome.rawValue),
                    .text(Self.id(id)),
                ]
            )
        }
    }

    public func recoverInterruptedSessions(at date: Date = Date()) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                UPDATE voice_sessions
                SET ended_at = ?, terminal_outcome = 'abandoned'
                WHERE terminal_outcome IS NULL
                """,
                bindings: [.text(Self.timestamp(date))]
            )
        }
    }

    public func session(id: UUID) throws -> VoiceHistorySession? {
        try database.query(
            "\(Self.sessionSelect) WHERE id = ?",
            bindings: [.text(Self.id(id))]
        ).first.map(Self.decodeSession)
    }

    public func sessions(
        from start: Date? = nil,
        through end: Date? = nil
    ) throws -> [VoiceHistorySession] {
        if let start, let end, start > end {
            throw VoiceHistoryRepositoryError.invalidRange
        }
        return try database.query(
            """
            \(Self.sessionSelect)
            WHERE (? IS NULL OR started_at >= ?)
              AND (? IS NULL OR started_at <= ?)
            ORDER BY started_at ASC, id ASC
            """,
            bindings: [
                Self.optionalTimestamp(start), Self.optionalTimestamp(start),
                Self.optionalTimestamp(end), Self.optionalTimestamp(end),
            ]
        ).map(Self.decodeSession)
    }

    public func entries(sessionID: UUID) throws -> [VoiceHistoryEntry] {
        try database.query(
            """
            \(Self.entrySelect)
            WHERE session_id = ?
            ORDER BY sequence ASC, id ASC
            """,
            bindings: [.text(Self.id(sessionID))]
        ).map(Self.decodeEntry)
    }

    public func exportProjection(
        sessionIDs: [UUID]
    ) throws -> [VoiceHistoryExportSession] {
        let selected = Set(sessionIDs)
        return try sessions().filter { selected.contains($0.id) }.map {
            VoiceHistoryExportSession(
                session: $0,
                entries: try entries(sessionID: $0.id)
            )
        }
    }

    public func attachmentProjection(
        sessionIDs: [UUID],
        maximumContentBytes: Int
    ) throws -> VoiceHistoryAttachmentProjection {
        let unique = Array(Set(sessionIDs)).sorted { Self.id($0) < Self.id($1) }
        guard !unique.isEmpty else {
            return .init(sessionIDs: [], entries: [], hasMore: false)
        }
        let encodedIDs = try JSONEncoder().encode(unique.map(Self.id))
        guard let idsJSON = String(data: encodedIDs, encoding: .utf8) else {
            throw VoiceHistoryRepositoryError.invalidEntry
        }
        return try boundedAttachmentProjection(
            explicitSessionIDs: unique,
            selectionCTE: "requested(id) AS (SELECT value FROM json_each(?))",
            sessionJoin: "JOIN requested r ON r.id = s.id",
            bindings: [.text(idsJSON)],
            maximumContentBytes: maximumContentBytes
        )
    }

    public func attachmentProjection(
        from start: Date,
        through end: Date,
        maximumContentBytes: Int
    ) throws -> VoiceHistoryAttachmentProjection {
        guard start <= end else { throw VoiceHistoryRepositoryError.invalidRange }
        return try boundedAttachmentProjection(
            explicitSessionIDs: nil,
            selectionCTE: "requested(id) AS (SELECT NULL WHERE 0)",
            sessionJoin: "",
            bindings: [.text(Self.timestamp(start)), .text(Self.timestamp(end))],
            maximumContentBytes: maximumContentBytes,
            rangePredicate: "s.started_at >= ? AND s.started_at <= ?"
        )
    }

    public func deleteSession(id: UUID) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                "DELETE FROM voice_sessions WHERE id = ?",
                bindings: [.text(Self.id(id))]
            )
            guard database.changes == 1 else {
                throw VoiceHistoryRepositoryError.sessionNotFound
            }
        }
    }

    public func deleteSessions(from start: Date, through end: Date) throws {
        guard start <= end else {
            throw VoiceHistoryRepositoryError.invalidRange
        }
        try preflightWrite()
        try database.transaction {
            try database.execute(
                "DELETE FROM voice_sessions WHERE started_at >= ? AND started_at <= ?",
                bindings: [
                    .text(Self.timestamp(start)),
                    .text(Self.timestamp(end)),
                ]
            )
        }
    }

    public func deleteAll() throws {
        try preflightWrite()
        try database.transaction {
            try database.execute("DELETE FROM voice_sessions")
        }
    }

    public func close() {
        database.close()
    }

    public func reopen() throws {
        try database.reopen()
    }

    private func preflightWrite() throws {
        if let simulatedWriteFailure {
            throw simulatedWriteFailure
        }
    }

    private func boundedAttachmentProjection(
        explicitSessionIDs: [UUID]?,
        selectionCTE: String,
        sessionJoin: String,
        bindings: [SQLiteValue],
        maximumContentBytes: Int,
        rangePredicate: String = "1 = 1"
    ) throws -> VoiceHistoryAttachmentProjection {
        var entries: [VoiceHistoryEntry] = []
        var encounteredSessionIDs: [UUID] = []
        var encountered = Set<UUID>()
        var bytes = 0
        var hasMore = false
        var selectionIsValid = true
        let maximumRows = max(2, maximumContentBytes / Self.minimumSerializedLineBytes + 1)
        try database.scan(
            """
            /* voice_history_attachment_projection */
            WITH \(selectionCTE),
            selected_sessions AS (
                SELECT s.id, s.started_at
                FROM voice_sessions s
                \(sessionJoin)
                WHERE s.save_choice = 'save' AND \(rangePredicate)
            ),
            selection_counts AS (
                SELECT
                    (SELECT COUNT(*) FROM requested) AS requested_count,
                    (SELECT COUNT(*) FROM selected_sessions) AS matched_count
            ),
            selected_entries AS (
                SELECT s.id AS selected_session_id,
                       s.started_at AS session_started_at,
                       e.id, e.session_id, e.sequence, e.role, e.text,
                       e.completion_state, e.started_at, e.completed_at
                FROM selected_sessions s
                JOIN voice_entries e ON e.session_id = s.id
            )
            SELECT c.requested_count, c.matched_count, e.selected_session_id,
                   e.id, e.session_id, e.sequence, e.role, e.text,
                   e.completion_state, e.started_at, e.completed_at
            FROM selection_counts c
            LEFT JOIN selected_entries e ON 1 = 1
            ORDER BY e.started_at ASC, e.session_started_at ASC,
                     e.sequence ASC, e.id ASC, e.selected_session_id ASC
            LIMIT ?
            """,
            bindings: bindings + [.integer(Int64(maximumRows))]
        ) { row in
            guard row.count == 11,
                  case let .integer(requestedCount) = row[0],
                  case let .integer(matchedCount) = row[1]
            else { throw VoiceHistoryRepositoryError.malformedRecord }
            selectionIsValid = requestedCount == 0 || requestedCount == matchedCount
            if let sessionID = Self.uuid(row[2]), encountered.insert(sessionID).inserted {
                encounteredSessionIDs.append(sessionID)
            }
            guard row[3] != .null else { return true }
            let entry = try Self.decodeEntry(Array(row[3...10]))
            if entries.count == maximumRows - 1 {
                hasMore = true
                return false
            }
            if !entries.isEmpty, bytes >= maximumContentBytes {
                hasMore = true
                return false
            }
            entries.append(entry)
            bytes += entry.text.utf8.count
            return true
        }
        let sessionIDs = explicitSessionIDs ?? encounteredSessionIDs
        return .init(
            sessionIDs: sessionIDs,
            entries: entries,
            hasMore: hasMore,
            selectionIsValid: selectionIsValid
        )
    }

    private static func validateEntry(
        text: String,
        sequence: Int,
        completionState: VoiceEntryCompletionState,
        startedAt: Date,
        completedAt: Date?
    ) throws {
        guard text.utf8.count <= maximumEntryBytes else {
            throw VoiceHistoryRepositoryError.entryTooLarge
        }
        if let completedAt, completedAt < startedAt {
            throw VoiceHistoryRepositoryError.invalidEntry
        }
        guard sequence >= 0,
              (completionState == .complete) == (completedAt != nil)
        else {
            throw VoiceHistoryRepositoryError.invalidEntry
        }
    }

    private static func decodeSession(
        _ row: [SQLiteValue]
    ) throws -> VoiceHistorySession {
        guard row.count == 7,
              let id = uuid(row[0]),
              case let .text(activationValue) = row[2],
              let activation = VoiceActivationSource(rawValue: activationValue),
              case let .text(startedValue) = row[3],
              let startedAt = date(startedValue),
              case let .text(saveValue) = row[6],
              let saveChoice = VoiceTranscriptSaveChoice(rawValue: saveValue)
        else {
            throw VoiceHistoryRepositoryError.malformedRecord
        }
        let conversationID = uuid(row[1]).map(ConversationID.init(rawValue:))
        let outcome: VoiceSessionTerminalOutcome?
        if let value = string(row[5]) {
            guard let decoded = VoiceSessionTerminalOutcome(rawValue: value) else {
                throw VoiceHistoryRepositoryError.malformedRecord
            }
            outcome = decoded
        } else {
            outcome = nil
        }
        return VoiceHistorySession(
            id: id,
            conversationID: conversationID,
            activationSource: activation,
            startedAt: startedAt,
            endedAt: string(row[4]).flatMap(date),
            terminalOutcome: outcome,
            saveChoice: saveChoice
        )
    }

    private static func decodeEntry(
        _ row: [SQLiteValue]
    ) throws -> VoiceHistoryEntry {
        guard row.count == 8,
              let id = uuid(row[0]),
              let sessionID = uuid(row[1]),
              case let .integer(sequence) = row[2],
              case let .text(roleValue) = row[3],
              let role = VoiceTranscriptRole(rawValue: roleValue),
              case let .text(text) = row[4],
              case let .text(completionValue) = row[5],
              let completion = VoiceEntryCompletionState(rawValue: completionValue),
              case let .text(startedValue) = row[6],
              let startedAt = date(startedValue)
        else {
            throw VoiceHistoryRepositoryError.malformedRecord
        }
        return VoiceHistoryEntry(
            id: id,
            sessionID: sessionID,
            sequence: Int(sequence),
            role: role,
            text: text,
            completionState: completion,
            startedAt: startedAt,
            completedAt: string(row[7]).flatMap(date)
        )
    }

    private static func id(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    private static func uuid(_ value: SQLiteValue) -> UUID? {
        string(value).flatMap(UUID.init(uuidString:))
    }

    private static func string(_ value: SQLiteValue) -> String? {
        guard case let .text(text) = value else { return nil }
        return text
    }

    private static func optionalTimestamp(_ value: Date?) -> SQLiteValue {
        value.map { .text(timestamp($0)) } ?? .null
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        // ISO8601DateFormatter emits millisecond precision and may round up.
        // Truncate first so a value read back from SQLite can never appear
        // later than an immediately following completion/finalization time.
        let milliseconds = floor(date.timeIntervalSince1970 * 1_000)
        let persistedDate = Date(timeIntervalSince1970: milliseconds / 1_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: persistedDate)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static let sessionSelect = """
        SELECT id, conversation_id, activation_source, started_at, ended_at,
               terminal_outcome, save_choice
        FROM voice_sessions
        """

    private static let entrySelect = """
        SELECT id, session_id, sequence, role, text, completion_state,
               started_at, completed_at
        FROM voice_entries
        """

    private static let minimumSerializedLineBytes = 29
}

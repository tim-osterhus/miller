import Foundation
import MillerCore

public actor SQLiteConversationRepository:
    ConversationRepository,
    ProviderProfileRepository
{
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("ai.millrace.miller", isDirectory: true)
            .appendingPathComponent("miller.sqlite3")
            .path
    }

    private let database: SQLiteDatabase

    public init(path: String = SQLiteConversationRepository.defaultPath) throws {
        database = try SQLiteDatabase(path: path)
    }

    public func accept(
        conversationID: ConversationID,
        turnID: TurnID,
        userText: String,
        inputMode: InputMode,
        generation: Int
    ) throws {
        let timestamp = Self.timestamp()
        try database.transaction {
            try database.execute(
                """
                INSERT OR IGNORE INTO conversations
                    (id, title, state, created_at, updated_at, archived_at)
                VALUES (?, ?, 'active', ?, ?, NULL)
                """,
                bindings: [
                    .text(conversationID.description),
                    Self.optionalText(Conversation.initialTitle(from: userText)),
                    .text(timestamp),
                    .text(timestamp),
                ]
            )

            let sequence = try database.scalarInt(
                """
                SELECT COALESCE(MAX(sequence), 0) + 1
                FROM turns
                WHERE conversation_id = ?
                """,
                bindings: [.text(conversationID.description)]
            )
            try database.execute(
                """
                INSERT INTO turns
                    (id, conversation_id, sequence, input_mode, user_text,
                     assistant_text, state, generation, error_code, error_message,
                     started_at, terminal_at)
                VALUES (?, ?, ?, ?, ?, '', 'accepted', ?, NULL, NULL, ?, NULL)
                """,
                bindings: [
                    .text(turnID.description),
                    .text(conversationID.description),
                    .integer(Int64(sequence)),
                    .text(inputMode.rawValue),
                    .text(userText),
                    .integer(Int64(generation)),
                    .text(timestamp),
                ]
            )
            try database.execute(
                "UPDATE conversations SET updated_at = ? WHERE id = ?",
                bindings: [.text(timestamp), .text(conversationID.description)]
            )
        }
    }

    public func append(
        turnID: TurnID,
        text: String,
        generation: Int
    ) throws {
        try transition {
            try database.execute(
                """
                UPDATE turns
                SET assistant_text = assistant_text || ?, state = 'streaming'
                WHERE id = ?
                  AND generation = ?
                  AND state IN ('accepted', 'streaming')
                """,
                bindings: [
                    .text(text),
                    .text(turnID.description),
                    .integer(Int64(generation)),
                ]
            )
        }
    }

    public func complete(turnID: TurnID, generation: Int) throws {
        let timestamp = Self.timestamp()
        try transition {
            try database.execute(
                """
                UPDATE turns
                SET state = 'completed', terminal_at = ?
                WHERE id = ?
                  AND generation = ?
                  AND state IN ('accepted', 'streaming')
                """,
                bindings: [
                    .text(timestamp),
                    .text(turnID.description),
                    .integer(Int64(generation)),
                ]
            )
        }
    }

    public func stop(
        turnID: TurnID,
        targetGeneration: Int,
        nextGeneration: Int
    ) throws {
        guard nextGeneration == targetGeneration + 1 else {
            throw ConversationRepositoryError.transitionRejected
        }
        let timestamp = Self.timestamp()
        try transition {
            try database.execute(
                """
                UPDATE turns
                SET state = 'stopped', generation = ?, terminal_at = ?
                WHERE id = ?
                  AND generation = ?
                  AND state IN ('accepted', 'streaming')
                """,
                bindings: [
                    .integer(Int64(nextGeneration)),
                    .text(timestamp),
                    .text(turnID.description),
                    .integer(Int64(targetGeneration)),
                ]
            )
        }
    }

    public func fail(
        turnID: TurnID,
        code: String,
        message _: String,
        targetGeneration: Int,
        nextGeneration: Int
    ) throws {
        guard nextGeneration == targetGeneration + 1 else {
            throw ConversationRepositoryError.transitionRejected
        }
        let failure = MillerFailure(code: code)
        let timestamp = Self.timestamp()
        try transition {
            try database.execute(
                """
                UPDATE turns
                SET state = 'failed', generation = ?, error_code = ?,
                    error_message = ?, terminal_at = ?
                WHERE id = ?
                  AND generation = ?
                  AND state IN ('accepted', 'streaming')
                """,
                bindings: [
                    .integer(Int64(nextGeneration)),
                    .text(failure.code),
                    .text(failure.message),
                    .text(timestamp),
                    .text(turnID.description),
                    .integer(Int64(targetGeneration)),
                ]
            )
        }
    }

    public func turn(id: TurnID) throws -> Turn? {
        let rows = try database.query(
            "\(Self.turnSelect) WHERE id = ?",
            bindings: [.text(id.description)]
        )
        return try rows.first.map(Self.decodeTurn)
    }

    public func completedTurns(
        conversationID: ConversationID
    ) throws -> [Turn] {
        try database.query(
            """
            \(Self.turnSelect)
            WHERE conversation_id = ? AND state = 'completed'
            ORDER BY sequence ASC
            """,
            bindings: [.text(conversationID.description)]
        ).map(Self.decodeTurn)
    }

    public func conversations() throws -> [Conversation] {
        try database.query(
            """
            SELECT id, title, state, created_at, updated_at, archived_at
            FROM conversations
            ORDER BY CASE state WHEN 'active' THEN 0 ELSE 1 END,
                     updated_at DESC,
                     id ASC
            """
        ).map(Self.decodeConversation)
    }

    public func turns(conversationID: ConversationID) throws -> [Turn] {
        try database.query(
            """
            \(Self.turnSelect)
            WHERE conversation_id = ?
            ORDER BY sequence ASC
            """,
            bindings: [.text(conversationID.description)]
        ).map(Self.decodeTurn)
    }

    public func archive(conversationID: ConversationID) throws {
        let timestamp = Self.timestamp()
        try conversationTransition(
            """
            UPDATE conversations
            SET state = 'archived', archived_at = ?, updated_at = ?
            WHERE id = ? AND state = 'active'
            """,
            bindings: [
                .text(timestamp),
                .text(timestamp),
                .text(conversationID.description),
            ]
        )
    }

    public func unarchive(conversationID: ConversationID) throws {
        let timestamp = Self.timestamp()
        try conversationTransition(
            """
            UPDATE conversations
            SET state = 'active', archived_at = NULL, updated_at = ?
            WHERE id = ? AND state = 'archived'
            """,
            bindings: [.text(timestamp), .text(conversationID.description)]
        )
    }

    public func delete(conversationID: ConversationID) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM conversations WHERE id = ?",
                bindings: [.text(conversationID.description)]
            )
            guard database.changes == 1 else {
                throw ConversationRepositoryError.conversationNotFound
            }
        }
    }

    public func recoverInterruptedTurns() throws {
        let failure = MillerFailure(code: "interrupted_by_relaunch")
        try database.transaction {
            try database.execute(
                """
                UPDATE turns
                SET state = 'failed',
                    generation = generation + 1,
                    error_code = ?,
                    error_message = ?,
                    terminal_at = ?
                WHERE state IN ('accepted', 'streaming')
                """,
                bindings: [
                    .text(failure.code),
                    .text(failure.message),
                    .text(Self.timestamp()),
                ]
            )
        }
    }

    public func saveProviderProfile(_ profile: ProviderProfile) throws {
        try database.transaction {
            let selectedCount = try database.scalarInt(
                "SELECT COUNT(*) FROM provider_profiles WHERE is_selected = 1"
            )
            let profileWasSelected = try database.scalarInt(
                """
                SELECT COUNT(*) FROM provider_profiles
                WHERE id = ? AND is_selected = 1
                """,
                bindings: [.text(profile.id.uuidString.lowercased())]
            ) == 1
            let shouldSelect = profile.isSelected
                || selectedCount == 0
                || profileWasSelected
            if shouldSelect {
                try database.execute(
                    "UPDATE provider_profiles SET is_selected = 0 WHERE is_selected = 1"
                )
            }
            try database.execute(
                """
                INSERT INTO provider_profiles
                    (id, kind, label, base_url, model, credential_ref, is_selected,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind,
                    label = excluded.label,
                    base_url = excluded.base_url,
                    model = excluded.model,
                    credential_ref = excluded.credential_ref,
                    is_selected = excluded.is_selected,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(profile.id.uuidString.lowercased()),
                    .text(profile.kind.rawValue),
                    .text(profile.label),
                    Self.optionalText(profile.baseURL),
                    .text(profile.model),
                    .text(profile.credentialReference.uuidString.lowercased()),
                    .integer(shouldSelect ? 1 : 0),
                    .text(Self.timestamp(profile.createdAt)),
                    .text(Self.timestamp(profile.updatedAt)),
                ]
            )
        }
    }

    public func providerProfiles() throws -> [ProviderProfile] {
        try database.query(
            """
            \(Self.profileSelect)
            ORDER BY is_selected DESC, created_at ASC, id ASC
            """
        ).map(Self.decodeProfile)
    }

    public func selectedProviderProfile() throws -> ProviderProfile? {
        let rows = try database.query(
            "\(Self.profileSelect) WHERE is_selected = 1"
        )
        return try rows.first.map(Self.decodeProfile)
    }

    public func selectProviderProfile(
        id: UUID,
        hasActiveTurn: Bool
    ) throws {
        guard !hasActiveTurn else {
            throw ProviderProfileError.activeTurn
        }
        try database.transaction {
            guard try database.scalarInt(
                "SELECT COUNT(*) FROM provider_profiles WHERE id = ?",
                bindings: [.text(id.uuidString.lowercased())]
            ) == 1 else {
                throw ProviderProfileError.profileNotFound
            }
            try database.execute(
                "UPDATE provider_profiles SET is_selected = 0 WHERE is_selected = 1"
            )
            try database.execute(
                """
                UPDATE provider_profiles
                SET is_selected = 1, updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(Self.timestamp()),
                    .text(id.uuidString.lowercased()),
                ]
            )
        }
    }

    public func deleteProviderProfile(id: UUID) throws {
        try database.transaction {
            let rows = try database.query(
                "SELECT is_selected FROM provider_profiles WHERE id = ?",
                bindings: [.text(id.uuidString.lowercased())]
            )
            guard case let .integer(wasSelected)? = rows.first?.first else {
                throw ProviderProfileError.profileNotFound
            }
            try database.execute(
                "DELETE FROM provider_profiles WHERE id = ?",
                bindings: [.text(id.uuidString.lowercased())]
            )
            if wasSelected == 1 {
                try database.execute(
                    """
                    UPDATE provider_profiles
                    SET is_selected = 1, updated_at = ?
                    WHERE id = (
                        SELECT id FROM provider_profiles
                        ORDER BY created_at ASC, id ASC
                        LIMIT 1
                    )
                    """,
                    bindings: [.text(Self.timestamp())]
                )
            }
        }
    }

    public func credentialIsInvalidated(reference: UUID) throws -> Bool {
        let rows = try database.query(
            """
            SELECT credential_status
            FROM provider_profiles
            WHERE credential_ref = ?
            """,
            bindings: [.text(reference.uuidString.lowercased())]
        )
        guard case let .text(status)? = rows.first?.first else {
            throw ProviderProfileError.profileNotFound
        }
        return status == "invalid"
    }

    public func setCredentialInvalidated(
        _ invalidated: Bool,
        reference: UUID
    ) throws {
        try database.transaction {
            try database.execute(
                """
                UPDATE provider_profiles
                SET credential_status = ?, updated_at = ?
                WHERE credential_ref = ?
                """,
                bindings: [
                    .text(invalidated ? "invalid" : "valid"),
                    .text(Self.timestamp()),
                    .text(reference.uuidString.lowercased()),
                ]
            )
            guard database.changes == 1 else {
                throw ProviderProfileError.profileNotFound
            }
        }
    }

    public func close() {
        database.close()
    }

    public func reopen() throws {
        try database.reopen()
    }

    private func transition(_ update: () throws -> Void) throws {
        try database.transaction {
            try update()
            guard database.changes == 1 else {
                throw ConversationRepositoryError.transitionRejected
            }
        }
    }

    private func conversationTransition(
        _ sql: String,
        bindings: [SQLiteValue]
    ) throws {
        try database.transaction {
            try database.execute(sql, bindings: bindings)
            guard database.changes == 1 else {
                throw ConversationRepositoryError.conversationNotFound
            }
        }
    }

    private static func decodeTurn(_ row: [SQLiteValue]) throws -> Turn {
        guard row.count == 12,
              let id = uuid(row[0]).map({ TurnID(rawValue: $0) }),
              let conversationID = uuid(row[1]).map({
                  ConversationID(rawValue: $0)
              }),
              case let .integer(sequence) = row[2],
              case let .text(inputModeValue) = row[3],
              let inputMode = InputMode(rawValue: inputModeValue),
              case let .text(userText) = row[4],
              case let .text(assistantText) = row[5],
              case let .text(stateValue) = row[6],
              let state = TurnState(rawValue: stateValue),
              case let .integer(generation) = row[7],
              case let .text(startedAtValue) = row[10],
              let startedAt = date(startedAtValue)
        else {
            throw SQLiteError.integrityFailed
        }

        return Turn(
            id: id,
            conversationID: conversationID,
            sequence: Int(sequence),
            inputMode: inputMode,
            userText: userText,
            assistantText: assistantText,
            state: state,
            generation: Int(generation),
            errorCode: optionalString(row[8]),
            errorMessage: optionalString(row[9]),
            startedAt: startedAt,
            terminalAt: optionalString(row[11]).flatMap(date)
        )
    }

    private static func decodeConversation(
        _ row: [SQLiteValue]
    ) throws -> Conversation {
        guard row.count == 6,
              let id = uuid(row[0]).map({ ConversationID(rawValue: $0) }),
              case let .text(stateValue) = row[2],
              let state = ConversationState(rawValue: stateValue),
              case let .text(createdAtValue) = row[3],
              let createdAt = date(createdAtValue),
              case let .text(updatedAtValue) = row[4],
              let updatedAt = date(updatedAtValue)
        else {
            throw SQLiteError.integrityFailed
        }
        return Conversation(
            id: id,
            title: optionalString(row[1]),
            state: state,
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: optionalString(row[5]).flatMap(date)
        )
    }

    private static func decodeProfile(
        _ row: [SQLiteValue]
    ) throws -> ProviderProfile {
        guard row.count == 9,
              let id = uuid(row[0]),
              case let .text(kindValue) = row[1],
              let kind = ProviderKind(rawValue: kindValue),
              case let .text(label) = row[2],
              case let .text(model) = row[4],
              let credentialReference = uuid(row[5]),
              case let .integer(isSelected) = row[6],
              case let .text(createdAtValue) = row[7],
              let createdAt = date(createdAtValue),
              case let .text(updatedAtValue) = row[8],
              let updatedAt = date(updatedAtValue)
        else {
            throw SQLiteError.integrityFailed
        }
        do {
            return try ProviderProfile(
                id: id,
                kind: kind,
                label: label,
                baseURL: optionalString(row[3]),
                model: model,
                credentialReference: credentialReference,
                isSelected: isSelected == 1,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch {
            throw SQLiteError.integrityFailed
        }
    }

    private static func uuid(_ value: SQLiteValue) -> UUID? {
        guard case let .text(text) = value else {
            return nil
        }
        return UUID(uuidString: text)
    }

    private static func optionalString(_ value: SQLiteValue) -> String? {
        guard case let .text(text) = value else {
            return nil
        }
        return text
    }

    private static func optionalText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static let turnSelect = """
        SELECT id, conversation_id, sequence, input_mode, user_text,
               assistant_text, state, generation, error_code, error_message,
               started_at, terminal_at
        FROM turns
        """

    private static let profileSelect = """
        SELECT id, kind, label, base_url, model, credential_ref, is_selected,
               created_at, updated_at
        FROM provider_profiles
        """
}

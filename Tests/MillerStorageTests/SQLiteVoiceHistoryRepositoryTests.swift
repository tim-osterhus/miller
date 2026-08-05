import Foundation
@testable import MillerCore
@testable import MillerStorage
import Testing

@Suite
struct SQLiteVoiceHistoryRepositoryTests {
    @Test
    func attachmentProjectionIsChronologicalAndStopsAfterOneLookahead() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let first = UUID()
        let second = UUID()
        let base = Date(timeIntervalSince1970: 100)
        for (sessionID, offset) in [(second, 10.0), (first, 0.0)] {
            try await repository.startSession(
                id: sessionID, conversationID: nil, activationSource: .manual,
                saveChoice: .save, startedAt: base.addingTimeInterval(offset)
            )
        }
        for (index, value) in ["aaaaaaaa", "bbbbbbbb", "cccccccc"].enumerated() {
            let sessionID = index == 1 ? second : first
            try await repository.appendEntry(
                id: UUID(), sessionID: sessionID, sequence: index,
                role: .user, text: value, completionState: .complete,
                startedAt: base.addingTimeInterval(Double(index)),
                completedAt: base.addingTimeInterval(Double(index) + 0.5)
            )
        }

        let projection = try await repository.attachmentProjection(
            sessionIDs: [second, first], maximumContentBytes: 10
        )

        #expect(
            projection.sessionIDs
                == [first, second].sorted { $0.uuidString < $1.uuidString }
        )
        #expect(projection.entries.map(\.text) == ["aaaaaaaa"])
        #expect(projection.hasMore)
    }

    @Test
    func attachmentProjectionUsesOneBoundedSelectForLargeExplicitAndDateSelections() async throws {
        let fixture = try TestDatabase(named: #function)
        let database = try SQLiteDatabase(path: fixture.path)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = Date(timeIntervalSince1970: 10_000)
        let sessionIDs = (0..<1_500).map { _ in UUID() }
        try database.transaction {
            for (index, sessionID) in sessionIDs.enumerated().reversed() {
                let startedAt = formatter.string(
                    from: base.addingTimeInterval(Double(index))
                )
                try database.execute(
                    """
                    INSERT INTO voice_sessions
                        (id, conversation_id, activation_source, started_at,
                         ended_at, terminal_outcome, save_choice)
                    VALUES (?, NULL, 'manual', ?, NULL, NULL, 'save')
                    """,
                    bindings: [
                        .text(sessionID.uuidString.lowercased()),
                        .text(startedAt),
                    ]
                )
                try database.execute(
                    """
                    INSERT INTO voice_entries
                        (id, session_id, sequence, role, text, completion_state,
                         started_at, completed_at)
                    VALUES (?, ?, 0, 'user', '', 'complete', ?, ?)
                    """,
                    bindings: [
                        .text(UUID().uuidString.lowercased()),
                        .text(sessionID.uuidString.lowercased()),
                        .text(startedAt),
                        .text(startedAt),
                    ]
                )
            }
        }
        database.close()

        let probe = SQLiteStatementProbe()
        let repository = try SQLiteVoiceHistoryRepository(
            path: fixture.path,
            statementObserver: { sql, bindingCount in
                probe.record(sql: sql, bindingCount: bindingCount)
            }
        )

        let explicitStart = probe.count
        let explicit = try await repository.attachmentProjection(
            sessionIDs: Array(sessionIDs.reversed()),
            maximumContentBytes: 32 * 1_024
        )
        let explicitStatements = probe.records(since: explicitStart)

        #expect(explicitStatements.count == 1)
        #expect(explicitStatements.first?.sql.contains("voice_history_attachment_projection") == true)
        #expect(explicitStatements.first?.sql.contains("json_each(?)") == true)
        #expect(explicitStatements.first?.bindingCount == 2)
        #expect(explicit.selectionIsValid)
        #expect(explicit.sessionIDs.count == sessionIDs.count)
        #expect(explicit.entries.count == (32 * 1_024) / 29)
        #expect(explicit.hasMore)
        #expect(zip(explicit.entries, explicit.entries.dropFirst()).allSatisfy {
            $0.0.startedAt <= $0.1.startedAt
        })

        let rangeStart = probe.count
        let range = try await repository.attachmentProjection(
            from: base.addingTimeInterval(-1),
            through: base.addingTimeInterval(2_000),
            maximumContentBytes: 32 * 1_024
        )
        let rangeStatements = probe.records(since: rangeStart)

        #expect(rangeStatements.count == 1)
        #expect(rangeStatements.first?.sql.contains("voice_history_attachment_projection") == true)
        #expect(rangeStatements.first?.bindingCount == 3)
        #expect(range.selectionIsValid)
        #expect(range.entries.count == (32 * 1_024) / 29)
        #expect(range.hasMore)
    }

    @Test
    func explicitAttachmentProjectionRejectsMissingOrDiscardedSessionsInSameSelect() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let saved = UUID()
        let discarded = UUID()
        let missing = UUID()
        for (sessionID, saveChoice) in [
            (saved, VoiceTranscriptSaveChoice.save),
            (discarded, VoiceTranscriptSaveChoice.discard),
        ] {
            try await repository.startSession(
                id: sessionID, conversationID: nil, activationSource: .manual,
                saveChoice: saveChoice
            )
        }

        let projection = try await repository.attachmentProjection(
            sessionIDs: [saved, discarded, missing],
            maximumContentBytes: 32 * 1_024
        )

        #expect(!projection.selectionIsValid)
        #expect(Set(projection.sessionIDs) == Set([saved, discarded, missing]))
        #expect(projection.sessionIDs.count == 3)
    }

    @Test
    func transcriptPreservesChronologyAdjacentRolesAndIdempotentFinalization() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let sessionID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let started = Date(timeIntervalSince1970: 100)

        try await repository.startSession(
            id: sessionID,
            conversationID: nil,
            activationSource: .manual,
            saveChoice: .save,
            startedAt: started
        )
        try await repository.appendEntry(
            id: secondID,
            sessionID: sessionID,
            sequence: 2,
            role: .user,
            text: "second",
            completionState: .complete,
            startedAt: started.addingTimeInterval(2),
            completedAt: started.addingTimeInterval(3)
        )
        try await repository.appendEntry(
            id: firstID,
            sessionID: sessionID,
            sequence: 1,
            role: .user,
            text: "partial",
            completionState: .incomplete,
            startedAt: started.addingTimeInterval(1)
        )
        try await repository.completeEntry(
            id: firstID,
            text: "first",
            completedAt: started.addingTimeInterval(2)
        )
        try await repository.completeEntry(
            id: firstID,
            text: "ignored replay",
            completedAt: started.addingTimeInterval(4)
        )
        try await repository.finalizeSession(
            id: sessionID,
            outcome: .completed,
            endedAt: started.addingTimeInterval(5)
        )
        try await repository.finalizeSession(
            id: sessionID,
            outcome: .failed,
            endedAt: started.addingTimeInterval(9)
        )

        #expect(try await repository.entries(sessionID: sessionID).map(\.text) == [
            "first", "second",
        ])
        let session = try #require(try await repository.session(id: sessionID))
        #expect(session.terminalOutcome == .completed)
        #expect(session.endedAt == started.addingTimeInterval(5))
    }

    @Test
    func recoveryExportAndRangeDeletionKeepIncompleteEvidence() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let oldSession = UUID()
        let newSession = UUID()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 1_000)

        for (id, date) in [(oldSession, oldDate), (newSession, newDate)] {
            try await repository.startSession(
                id: id,
                conversationID: nil,
                activationSource: .wakeword,
                saveChoice: .save,
                startedAt: date
            )
            try await repository.appendEntry(
                id: UUID(),
                sessionID: id,
                sequence: 0,
                role: .assistant,
                text: "visible partial",
                completionState: .incomplete,
                startedAt: date
            )
        }

        try await repository.recoverInterruptedSessions(at: newDate.addingTimeInterval(20))
        let recovered = try #require(try await repository.session(id: newSession))
        #expect(recovered.terminalOutcome == .abandoned)
        #expect(try await repository.entries(sessionID: newSession).first?.completionState == .incomplete)

        let projection = try await repository.exportProjection(sessionIDs: [newSession])
        #expect(projection.count == 1)
        #expect(projection[0].entries.map(\.text) == ["visible partial"])

        try await repository.deleteSessions(from: oldDate.addingTimeInterval(-1), through: oldDate.addingTimeInterval(1))
        #expect(try await repository.session(id: oldSession) == nil)
        #expect(try await repository.session(id: newSession) != nil)
        try await repository.deleteAll()
        #expect(try await repository.sessions().isEmpty)
    }

    @Test
    func deletingSessionCascadesEntriesAndAssociatedAuditOnly() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let deleted = UUID()
        let retained = UUID()
        for id in [deleted, retained] {
            try await repository.startSession(
                id: id,
                conversationID: nil,
                activationSource: .manual,
                saveChoice: .save
            )
            try await repository.appendEntry(
                id: UUID(), sessionID: id, sequence: 0, role: .user,
                text: "hello", completionState: .incomplete
            )
        }
        let database = try SQLiteDatabase(path: fixture.path)
        for (auditID, sessionID) in [(UUID(), deleted), (UUID(), retained)] {
            try database.execute(
                """
                INSERT INTO capability_audit
                    (id, conversation_id, turn_id, voice_session_id, source,
                     source_server_id, tool_name, started_at, terminal_at,
                     effective_policy, approval_requested, approval_decision,
                     terminal_outcome, sanitized_summary, visibility)
                VALUES (?, NULL, NULL, ?, 'miller_mcp', 'server', 'tool', ?,
                        NULL, 'ask_before_changes', 0, NULL, NULL,
                        'Read local files.', 'complete')
                """,
                bindings: [
                    .text(auditID.uuidString.lowercased()),
                    .text(sessionID.uuidString.lowercased()),
                    .text("2026-08-05T00:00:00.000Z"),
                ]
            )
        }

        try await repository.deleteSession(id: deleted)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM voice_entries") == 1)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_audit") == 1)
    }

    @Test
    func oversizeAndInjectedWriteFailuresAreAtomic() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let sessionID = UUID()
        try await repository.startSession(
            id: sessionID,
            conversationID: nil,
            activationSource: .manual,
            saveChoice: .save
        )

        await #expect(throws: VoiceHistoryRepositoryError.entryTooLarge) {
            try await repository.appendEntry(
                id: UUID(), sessionID: sessionID, sequence: 0, role: .user,
                text: String(repeating: "é", count: 32_769),
                completionState: .incomplete
            )
        }
        #expect(try await repository.entries(sessionID: sessionID).isEmpty)

        let full = try SQLiteVoiceHistoryRepository(
            path: fixture.path,
            simulatedWriteFailure: .storageFull
        )
        await #expect(throws: SQLiteError.storageFull) {
            try await full.finalizeSession(id: sessionID, outcome: .failed)
        }
        #expect(try await repository.session(id: sessionID)?.terminalOutcome == nil)

        let readOnly = try SQLiteVoiceHistoryRepository(
            path: fixture.path,
            simulatedWriteFailure: .writeFailed
        )
        await #expect(throws: SQLiteError.writeFailed) {
            try await readOnly.deleteAll()
        }
        #expect(try await repository.session(id: sessionID) != nil)
    }

    @Test
    func completeEntryReplayIsIdempotentAndConflictsAreRejected() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let sessionID = UUID()
        let entryID = UUID()
        let started = Date(timeIntervalSince1970: 100)
        let completed = started.addingTimeInterval(2)
        try await repository.startSession(
            id: sessionID, conversationID: nil,
            activationSource: .manual, saveChoice: .save,
            startedAt: started
        )
        for replayID in [entryID, UUID()] {
            try await repository.appendEntry(
                id: replayID, sessionID: sessionID, sequence: 1,
                role: .assistant, text: "done", completionState: .complete,
                startedAt: started, completedAt: completed
            )
        }
        #expect(try await repository.entries(sessionID: sessionID).count == 1)
        await #expect(throws: VoiceHistoryRepositoryError.conflictingEntryReplay) {
            try await repository.appendEntry(
                id: entryID, sessionID: sessionID, sequence: 2,
                role: .user, text: "conflict", completionState: .complete,
                startedAt: started, completedAt: completed
            )
        }
        await #expect(throws: VoiceHistoryRepositoryError.invalidEntry) {
            try await repository.appendEntry(
                id: UUID(), sessionID: sessionID, sequence: 2,
                role: .user, text: "bad time", completionState: .complete,
                startedAt: started, completedAt: started.addingTimeInterval(-1)
            )
        }
        await #expect(throws: VoiceHistoryRepositoryError.invalidEntry) {
            try await repository.finalizeSession(
                id: sessionID, outcome: .completed,
                endedAt: started.addingTimeInterval(-1)
            )
        }
    }

    @Test
    func submillisecondStartDoesNotRoundPastImmediateCompletion() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let sessionID = UUID()
        let entryID = UUID()
        let started = Date(timeIntervalSince1970: 100.0009)
        let completed = Date(timeIntervalSince1970: 100.00091)

        try await repository.startSession(
            id: sessionID,
            conversationID: nil,
            activationSource: .manual,
            saveChoice: .save,
            startedAt: started
        )
        try await repository.appendEntry(
            id: entryID,
            sessionID: sessionID,
            sequence: 0,
            role: .user,
            text: "immediate",
            completionState: .incomplete,
            startedAt: started
        )
        try await repository.completeEntry(
            id: entryID,
            text: "immediate",
            completedAt: completed
        )
        try await repository.finalizeSession(
            id: sessionID,
            outcome: .completed,
            endedAt: completed
        )

        #expect(
            try await repository.entries(sessionID: sessionID)
                .map(\.completionState) == [.complete]
        )
        #expect(
            try await repository.session(id: sessionID)?.terminalOutcome
                == .completed
        )
    }
}

private final class SQLiteStatementProbe: @unchecked Sendable {
    struct Record {
        let sql: String
        let bindingCount: Int
    }

    private let lock = NSLock()
    private var storage: [Record] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func record(sql: String, bindingCount: Int) {
        lock.lock()
        storage.append(.init(sql: sql, bindingCount: bindingCount))
        lock.unlock()
    }

    func records(since index: Int) -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.dropFirst(index))
    }
}

import Foundation
@testable import MillerCore
@testable import MillerStorage
import Testing

@Suite
struct MillerStorageTests {
    @Test
    func testCompletedConversationSurvivesReopen() async throws {
        let fixture = try TestDatabase(named: #function)
        let conversationID = ConversationID()
        let turnID = TurnID()

        do {
            let repository = try SQLiteConversationRepository(path: fixture.path)
            try await repository.accept(
                conversationID: conversationID,
                turnID: turnID,
                userText: "Hello",
                inputMode: .text,
                generation: 1
            )
            try await repository.append(turnID: turnID, text: "Hi.", generation: 1)
            try await repository.complete(turnID: turnID, generation: 1)
        }

        let reopened = try SQLiteConversationRepository(path: fixture.path)
        let turn = try await reopened.turn(id: turnID)
        XCTAssertEqual(turn?.assistantText, "Hi.")
        XCTAssertEqual(turn?.state, .completed)
        XCTAssertEqual(try await reopened.completedTurns(conversationID: conversationID), [turn])
    }

    @Test
    func testConcurrentAcceptsAllocateUniqueIncreasingSequences() async throws {
        let fixture = try TestDatabase(named: #function)
        let conversationID = ConversationID()
        let firstID = TurnID()
        let initial = try SQLiteConversationRepository(path: fixture.path)
        try await initial.accept(
            conversationID: conversationID,
            turnID: firstID,
            userText: "first",
            inputMode: .text,
            generation: 1
        )

        let turnIDs = (0..<12).map { _ in TurnID() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, turnID) in turnIDs.enumerated() {
                group.addTask {
                    let repository = try SQLiteConversationRepository(path: fixture.path)
                    try await repository.accept(
                        conversationID: conversationID,
                        turnID: turnID,
                        userText: "message \(index)",
                        inputMode: .text,
                        generation: 1
                    )
                }
            }
            try await group.waitForAll()
        }

        let reopened = try SQLiteConversationRepository(path: fixture.path)
        var sequences = [try XCTUnwrap(await reopened.turn(id: firstID)).sequence]
        for turnID in turnIDs {
            sequences.append(try XCTUnwrap(await reopened.turn(id: turnID)).sequence)
        }
        XCTAssertEqual(sequences.sorted(), Array(1...13))
        XCTAssertEqual(Set(sequences).count, 13)
    }

    @Test
    func testStopAndFailureAreGuardedAndPreserveAdmittedText() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteConversationRepository(path: fixture.path)
        let conversationID = ConversationID()
        let stoppedID = TurnID()
        let failedID = TurnID()

        try await repository.accept(
            conversationID: conversationID,
            turnID: stoppedID,
            userText: "stop",
            inputMode: .voice,
            generation: 1
        )
        try await repository.append(turnID: stoppedID, text: "partial stop", generation: 1)
        try await repository.stop(
            turnID: stoppedID,
            targetGeneration: 1,
            nextGeneration: 2
        )

        try await repository.accept(
            conversationID: conversationID,
            turnID: failedID,
            userText: "fail",
            inputMode: .text,
            generation: 4
        )
        try await repository.append(turnID: failedID, text: "partial failure", generation: 4)
        try await repository.fail(
            turnID: failedID,
            code: "provider_unavailable",
            message: "untrusted provider text",
            targetGeneration: 4,
            nextGeneration: 5
        )

        let stopped = try XCTUnwrap(await repository.turn(id: stoppedID))
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.generation, 2)
        XCTAssertEqual(stopped.assistantText, "partial stop")

        let failed = try XCTUnwrap(await repository.turn(id: failedID))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.generation, 5)
        XCTAssertEqual(failed.assistantText, "partial failure")
        XCTAssertEqual(failed.errorCode, "provider_unavailable")
        XCTAssertEqual(failed.errorMessage, "The provider is unavailable. Try again.")

        await XCTAssertThrowsErrorAsync {
            try await repository.append(turnID: stoppedID, text: "late", generation: 1)
        }
        XCTAssertEqual(
            try await repository.turn(id: stoppedID)?.assistantText,
            "partial stop"
        )
    }

    @Test
    func testArchiveUnarchiveAndCascadeDelete() async throws {
        let fixture = try TestDatabase(named: #function)
        let conversationID = ConversationID()
        let repository = try SQLiteConversationRepository(path: fixture.path)
        try await repository.accept(
            conversationID: conversationID,
            turnID: TurnID(),
            userText: "Keep this title",
            inputMode: .text,
            generation: 1
        )

        try await repository.archive(conversationID: conversationID)
        let database = try SQLiteDatabase(path: fixture.path)
        XCTAssertEqual(
            try database.scalarText(
                "SELECT state FROM conversations WHERE id = ?",
                bindings: [.text(conversationID.description)]
            ),
            "archived"
        )

        try await repository.unarchive(conversationID: conversationID)
        XCTAssertEqual(
            try database.scalarText(
                "SELECT state FROM conversations WHERE id = ?",
                bindings: [.text(conversationID.description)]
            ),
            "active"
        )

        try await repository.delete(conversationID: conversationID)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM turns"), 0)
        database.close()
    }

    @Test
    func testConversationSnapshotsExposeDurableListAndAllTurns() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteConversationRepository(path: fixture.path)
        let activeID = ConversationID()
        let archivedID = ConversationID()
        let activeTurnID = TurnID()
        let archivedTurnID = TurnID()

        try await repository.accept(
            conversationID: activeID,
            turnID: activeTurnID,
            userText: "Active conversation",
            inputMode: .text,
            generation: 1
        )
        try await repository.accept(
            conversationID: archivedID,
            turnID: archivedTurnID,
            userText: "Archived conversation",
            inputMode: .text,
            generation: 1
        )
        try await repository.append(
            turnID: activeTurnID,
            text: "visible partial",
            generation: 1
        )
        try await repository.archive(conversationID: archivedID)

        let conversations = try await repository.conversations()
        let turns = try await repository.turns(conversationID: activeID)

        XCTAssertEqual(conversations.map(\.id), [activeID, archivedID])
        XCTAssertEqual(conversations.map(\.state), [.active, .archived])
        XCTAssertEqual(turns.map(\.id), [activeTurnID])
        XCTAssertEqual(turns.first?.assistantText, "visible partial")
        XCTAssertEqual(turns.first?.state, .streaming)
    }

    @Test
    func testSchemaAllowsExactlyOneSelectedProviderProfile() throws {
        let fixture = try TestDatabase(named: #function)
        let database = try SQLiteDatabase(path: fixture.path)
        XCTAssertEqual(try database.scalarInt("PRAGMA user_version"), 2)
        XCTAssertEqual(
            try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 1"
            ),
            1
        )
        XCTAssertEqual(
            try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 2"
            ),
            1
        )
        try database.execute(
            """
            INSERT INTO provider_profiles
                (id, kind, label, base_url, model, credential_ref, is_selected,
                 created_at, updated_at)
            VALUES (?, 'codex_oauth', 'Primary', NULL, 'gpt-5', ?, 1, ?, ?)
            """,
            bindings: [.text(UUID().uuidString), .text(UUID().uuidString), .text(now), .text(now)]
        )

        XCTAssertThrowsError(
            try database.execute(
                """
                INSERT INTO provider_profiles
                    (id, kind, label, base_url, model, credential_ref, is_selected,
                     created_at, updated_at)
                VALUES (?, 'openai_compatible', 'Second', 'https://example.com',
                        'model', ?, 1, ?, ?)
                """,
                bindings: [
                    .text(UUID().uuidString), .text(UUID().uuidString),
                    .text(now), .text(now),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? SQLiteError, .constraintFailed)
        }
    }

    @Test
    func testRecoveryFailsNonterminalTurnsAndPreservesAssistantText() async throws {
        let fixture = try TestDatabase(named: #function)
        let conversationID = ConversationID()
        let acceptedID = TurnID()
        let streamingID = TurnID()
        let completedID = TurnID()

        do {
            let repository = try SQLiteConversationRepository(path: fixture.path)
            for turnID in [acceptedID, streamingID, completedID] {
                try await repository.accept(
                    conversationID: conversationID,
                    turnID: turnID,
                    userText: "message",
                    inputMode: .text,
                    generation: 1
                )
            }
            try await repository.append(
                turnID: streamingID,
                text: "visible partial",
                generation: 1
            )
            try await repository.complete(turnID: completedID, generation: 1)
        }

        let reopened = try SQLiteConversationRepository(path: fixture.path)
        try await reopened.recoverInterruptedTurns()

        for turnID in [acceptedID, streamingID] {
            let recovered = try XCTUnwrap(await reopened.turn(id: turnID))
            XCTAssertEqual(recovered.state, .failed)
            XCTAssertEqual(recovered.generation, 2)
            XCTAssertEqual(recovered.errorCode, "interrupted_by_relaunch")
            XCTAssertEqual(recovered.errorMessage, "The request was interrupted. Try again.")
        }
        XCTAssertEqual(
            try await reopened.turn(id: streamingID)?.assistantText,
            "visible partial"
        )
        XCTAssertEqual(try await reopened.turn(id: completedID)?.state, .completed)
    }

    @Test
    func testInvalidHeaderAndNewerSchemaAreRefused() throws {
        let invalid = try TestDatabase(named: "\(#function)-invalid")
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: invalid.path))
        XCTAssertThrowsError(try SQLiteConversationRepository(path: invalid.path)) {
            XCTAssertEqual($0 as? SQLiteError, .invalidHeader)
        }

        let newer = try TestDatabase(named: "\(#function)-newer")
        do {
            let database = try SQLiteDatabase(path: newer.path)
            try database.execute("PRAGMA user_version = 99")
        }
        XCTAssertThrowsError(try SQLiteConversationRepository(path: newer.path)) {
            XCTAssertEqual($0 as? SQLiteError, .newerSchema(found: 99, supported: 2))
        }
    }

    @Test
    func testCorruptDatabaseFailsIntegrityQualification() throws {
        let fixture = try TestDatabase(named: #function)
        do {
            _ = try SQLiteConversationRepository(path: fixture.path)
        }
        var bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.path))
        XCTAssertGreaterThan(bytes.count, 200)
        bytes.replaceSubrange(100..<200, with: repeatElement(UInt8(0xFF), count: 100))
        try bytes.write(to: URL(fileURLWithPath: fixture.path))

        XCTAssertThrowsError(try SQLiteConversationRepository(path: fixture.path)) {
            XCTAssertEqual($0 as? SQLiteError, .integrityFailed)
        }
    }

    @Test
    func testDiskFullMapsToStableError() throws {
        let fixture = try TestDatabase(named: #function)
        let database = try SQLiteDatabase(path: fixture.path)
        try database.execute("CREATE TABLE fill (payload BLOB NOT NULL)")
        let currentPages = try database.scalarInt("PRAGMA page_count")
        _ = try database.scalarInt("PRAGMA max_page_count = \(currentPages + 1)")

        XCTAssertThrowsError(
            try database.execute(
                "INSERT INTO fill(payload) VALUES (zeroblob(1048576))"
            )
        ) {
            XCTAssertEqual($0 as? SQLiteError, .storageFull)
        }
    }

    @Test
    func testTerminalWriteFailureDoesNotChangeTurn() async throws {
        let fixture = try TestDatabase(named: #function)
        let conversationID = ConversationID()
        let turnID = TurnID()
        let repository = try SQLiteConversationRepository(path: fixture.path)
        try await repository.accept(
            conversationID: conversationID,
            turnID: turnID,
            userText: "hello",
            inputMode: .text,
            generation: 1
        )

        let database = try SQLiteDatabase(path: fixture.path)
        try database.execute(
            """
            CREATE TRIGGER reject_terminal_update
            BEFORE UPDATE OF state ON turns
            WHEN NEW.state = 'completed'
            BEGIN
                SELECT RAISE(ABORT, 'injected terminal failure');
            END
            """
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.complete(turnID: turnID, generation: 1)
        }
        XCTAssertEqual(try await repository.turn(id: turnID)?.state, .accepted)
    }

    @Test
    func testUncommittedWritesAreInvisibleToAnotherConnection() throws {
        let fixture = try TestDatabase(named: #function)
        let writer = try SQLiteDatabase(path: fixture.path)
        let reader = try SQLiteDatabase(path: fixture.path)

        XCTAssertThrowsError(
            try writer.transaction {
                try writer.execute(
                    """
                    INSERT INTO conversations
                        (id, title, state, created_at, updated_at, archived_at)
                    VALUES (?, NULL, 'active', ?, ?, NULL)
                    """,
                    bindings: [.text(UUID().uuidString), .text(now), .text(now)]
                )
                XCTAssertEqual(
                    try reader.scalarInt("SELECT COUNT(*) FROM conversations"),
                    0
                )
                throw InjectedFailure()
            }
        )
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM conversations"), 0)
    }

    @Test
    func testDatabaseFilesUseOwnerOnlyPermissions() throws {
        let fixture = try TestDatabase(named: #function)
        let database = try SQLiteDatabase(path: fixture.path)
        try database.execute("CREATE TABLE permissions_probe (id INTEGER)")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try fixture.directoryPermissions(), 0o700)
    }
}

private struct InjectedFailure: Error {}

private let now = "2026-07-30T00:00:00.000Z"

private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    if actual != expected {
        Issue.record("Expected \(String(describing: expected)), received \(String(describing: actual))")
    }
}

private func XCTAssertGreaterThan<T: Comparable>(_ actual: T, _ expected: T) {
    if actual <= expected {
        Issue.record("Expected \(actual) to be greater than \(expected)")
    }
}

private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else {
        Issue.record("Expected a non-nil value")
        throw MissingValue()
    }
    return value
}

private func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in }
) {
    do {
        _ = try expression()
        Issue.record("Expected an error")
    } catch {
        errorHandler(error)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
) async {
    do {
        try await expression()
        Issue.record("Expected an error")
    } catch {}
}

private struct MissingValue: Error {}

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
        XCTAssertEqual(try database.scalarInt("PRAGMA user_version"), 4)
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
        XCTAssertEqual(
            try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 3"
            ),
            1
        )
        XCTAssertEqual(
            try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 4"
            ),
            1
        )
        let capabilityColumns = try database.query(
            "PRAGMA table_info(capability_tools)"
        ).compactMap { row -> String? in
            guard row.count > 1, case let .text(name) = row[1] else { return nil }
            return name
        }
        #expect(capabilityColumns.contains("accessible"))
        #expect(capabilityColumns.contains("enabled"))
        #expect(capabilityColumns.contains("callable"))
        #expect(capabilityColumns.contains("visibility"))
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
            XCTAssertEqual($0 as? SQLiteError, .newerSchema(found: 99, supported: 4))
        }
    }

    @Test
    func testVersionTwoDatabaseMigratesWithoutChangingExistingRows() throws {
        let fixture = try TestDatabase(named: #function)
        let conversationID = UUID().uuidString.lowercased()
        let turnID = UUID().uuidString.lowercased()
        let profileID = UUID().uuidString.lowercased()
        let credentialID = UUID().uuidString.lowercased()
        let versionTwoSQL = SQLiteMigrations.all
            .filter { $0.version <= 2 }
            .map(\.sql)
            .joined(separator: "\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            fixture.path,
            """
            PRAGMA foreign_keys = ON;
            BEGIN;
            \(versionTwoSQL)
            INSERT INTO schema_migrations(version, applied_at)
                VALUES (1, '\(now)'), (2, '\(now)');
            INSERT INTO conversations
                (id, title, state, created_at, updated_at, archived_at)
                VALUES ('\(conversationID)', 'Existing', 'active', '\(now)', '\(now)', NULL);
            INSERT INTO turns
                (id, conversation_id, sequence, input_mode, user_text,
                 assistant_text, state, generation, error_code, error_message,
                 started_at, terminal_at)
                VALUES ('\(turnID)', '\(conversationID)', 1, 'text', 'Question',
                        'Answer', 'completed', 1, NULL, NULL, '\(now)', '\(now)');
            INSERT INTO provider_profiles
                (id, kind, label, base_url, model, credential_ref, is_selected,
                 created_at, updated_at, credential_status)
                VALUES ('\(profileID)', 'codex_oauth', 'Existing provider', NULL,
                        'gpt-5', '\(credentialID)', 1, '\(now)', '\(now)', 'valid');
            PRAGMA user_version = 2;
            COMMIT;
            """,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let database = try SQLiteDatabase(path: fixture.path)
        XCTAssertEqual(try database.scalarInt("PRAGMA user_version"), 4)
        XCTAssertEqual(
            try database.scalarInt("SELECT MAX(version) FROM schema_migrations"),
            4
        )
        XCTAssertEqual(try database.scalarInt("PRAGMA foreign_keys"), 1)
        XCTAssertEqual(try database.scalarText("PRAGMA quick_check"), "ok")
        XCTAssertEqual(
            try database.query(
                """
                SELECT id, title, state, created_at, updated_at, archived_at
                FROM conversations
                """
            ),
            [[
                .text(conversationID), .text("Existing"), .text("active"),
                .text(now), .text(now), .null,
            ]]
        )
        XCTAssertEqual(
            try database.query(
                """
                SELECT id, conversation_id, sequence, input_mode, user_text,
                       assistant_text, state, generation, error_code,
                       error_message, started_at, terminal_at
                FROM turns
                """
            ),
            [[
                .text(turnID), .text(conversationID), .integer(1), .text("text"),
                .text("Question"), .text("Answer"), .text("completed"),
                .integer(1), .null, .null, .text(now), .text(now),
            ]]
        )
        XCTAssertEqual(
            try database.query(
                """
                SELECT id, kind, label, base_url, model, credential_ref,
                       is_selected, created_at, updated_at, credential_status
                FROM provider_profiles
                """
            ),
            [[
                .text(profileID), .text("codex_oauth"),
                .text("Existing provider"), .null, .text("gpt-5"),
                .text(credentialID), .integer(1), .text(now), .text(now),
                .text("valid"),
            ]]
        )
    }

    @Test
    func testMigrationLedgerRequiresEveryContiguousVersion() throws {
        let fixture = try TestDatabase(named: #function)
        do {
            let database = try SQLiteDatabase(path: fixture.path)
            try database.execute("DELETE FROM schema_migrations WHERE version = 2")
        }
        XCTAssertThrowsError(try SQLiteDatabase(path: fixture.path)) {
            XCTAssertEqual($0 as? SQLiteError, .integrityFailed)
        }

        let duplicate = try TestDatabase(named: "\(#function)-duplicate")
        let database = try SQLiteDatabase(path: duplicate.path)
        XCTAssertThrowsError(
            try database.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (4, ?)",
                bindings: [.text(now)]
            )
        ) { XCTAssertEqual($0 as? SQLiteError, .constraintFailed) }
    }

    @Test
    func testConcurrentVersionTwoInitializationAppliesMigrationOnce() async throws {
        let fixture = try TestDatabase(named: #function)
        let versionTwoSQL = SQLiteMigrations.all
            .filter { $0.version <= 2 }
            .map(\.sql)
            .joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            fixture.path,
            """
            BEGIN;
            \(versionTwoSQL)
            INSERT INTO schema_migrations(version, applied_at)
                VALUES (1, '\(now)'), (2, '\(now)');
            PRAGMA user_version = 2;
            COMMIT;
            """,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let database = try SQLiteDatabase(path: fixture.path)
                    XCTAssertEqual(try database.scalarInt("PRAGMA user_version"), 4)
                }
            }
            try await group.waitForAll()
        }
        let database = try SQLiteDatabase(path: fixture.path)
        XCTAssertEqual(
            try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 4"
            ),
            1
        )
    }

    @Test
    func testVersionThreeCapabilityRowsMigrateWithSafeAuthorityDefaults() throws {
        let fixture = try TestDatabase(named: #function)
        let versionThreeSQL = SQLiteMigrations.all
            .filter { $0.version <= 3 }
            .map(\.sql)
            .joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            fixture.path,
            """
            PRAGMA foreign_keys = ON;
            BEGIN;
            \(versionThreeSQL)
            INSERT INTO schema_migrations(version, applied_at)
                VALUES (1, '\(now)'), (2, '\(now)'), (3, '\(now)');
            INSERT INTO capability_servers
                (id, display_name, transport, command, endpoint, arguments_json,
                 enabled, default_policy, stale_state, created_at, updated_at)
                VALUES ('legacy', 'Legacy', 'stdio', '/usr/bin/env', NULL, '[]',
                        1, 'ask_before_changes', 'current', '\(now)', '\(now)');
            INSERT INTO capability_tools
                (id, server_id, source, source_server_id, tool_name,
                 display_name, summary, input_schema_json, read_only_hint,
                 available, stale_state, content_hash, reconciled_at)
                VALUES ('miller_mcp/legacy/list', 'legacy', 'miller_mcp',
                        'legacy', 'list', 'List', 'List', X'7B7D', 1,
                        1, 'current', NULL, '\(now)');
            INSERT INTO capability_tools
                (id, server_id, source, source_server_id, tool_name,
                 display_name, summary, input_schema_json, read_only_hint,
                 available, stale_state, content_hash, reconciled_at)
                VALUES ('codex_account/legacy/search', 'legacy', 'codex_account',
                        'legacy', 'search', 'Search', 'Search', X'7B7D', 1,
                        1, 'current', NULL, '\(now)');
            PRAGMA user_version = 3;
            COMMIT;
            """,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let database = try SQLiteDatabase(path: fixture.path)
        XCTAssertEqual(try database.scalarInt("PRAGMA user_version"), 4)
        XCTAssertEqual(
            try database.query(
                """
                SELECT id, accessible, enabled, callable, visibility
                FROM capability_tools
                ORDER BY id
                """
            ),
            [
                [
                    .text("codex_account/legacy/search"), .integer(1), .integer(1),
                    .integer(1), .text("provider_managed"),
                ],
                [
                    .text("miller_mcp/legacy/list"), .integer(1), .integer(1),
                    .integer(1), .text("owner_managed"),
                ],
            ]
        )
        XCTAssertEqual(
            try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 4"
            ),
            1
        )
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

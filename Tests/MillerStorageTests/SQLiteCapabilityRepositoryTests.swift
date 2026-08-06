import Foundation
@testable import MillerCore
@testable import MillerStorage
import Testing

@Suite
struct SQLiteCapabilityRepositoryTests {
    @Test
    func serverSecretsAndProviderSettingsPersistAndCascade() async throws {
        let fixture = try TestDatabase(named: #function)
        let profileID = UUID()
        try insertProviderProfile(profileID, path: fixture.path)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let server = CapabilityServerRecord(
            id: "local-tools",
            displayName: "Local tools",
            transport: .stdio,
            command: "/usr/bin/env",
            endpoint: nil,
            arguments: ["node", "server.mjs"],
            enabled: true,
            defaultPolicy: .askBeforeChanges,
            staleState: .current,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try await repository.saveServer(server)
        let credential = UUID()
        try await repository.saveSecretBinding(
            CapabilitySecretBinding(
                id: UUID(), serverID: server.id, kind: .environment,
                name: "SERVICE_TOKEN", credentialReference: credential
            )
        )
        try await repository.setProviderEnabled(
            true, serverID: server.id, providerProfileID: profileID
        )
        #expect(try await repository.server(id: server.id) == server)
        #expect(try await repository.secretBindings(serverID: server.id).first?.credentialReference == credential)
        #expect(try await repository.enabledProviderProfileIDs(serverID: server.id) == [profileID])

        let database = try SQLiteDatabase(path: fixture.path)
        let columns = try database.query("PRAGMA table_info(capability_secret_bindings)")
        #expect(!columns.contains { row in
            row.contains(.text("secret")) || row.contains(.text("value"))
        })
        try database.execute(
            "DELETE FROM provider_profiles WHERE id = ?",
            bindings: [.text(profileID.uuidString.lowercased())]
        )
        #expect(try database.scalarInt("SELECT COUNT(*) FROM provider_capability_settings") == 0)
        try await repository.deleteServer(id: server.id)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_secret_bindings") == 0)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM provider_capability_settings") == 0)
    }

    @Test
    func schemaRejectsNonUUIDSecretReferencesAndMalformedToolSchemas() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        try await repository.saveServer(makeServer())
        let database = try SQLiteDatabase(path: fixture.path)

        let credentialReference = UUID().uuidString.lowercased()
        try database.execute(
            """
            INSERT INTO capability_secret_bindings
                (id, server_id, binding_kind, binding_name, credential_ref)
            VALUES (?, 'local-tools', 'header', 'X-Valid', ?)
            """,
            bindings: [
                .text(UUID().uuidString.lowercased()),
                .text(credentialReference),
            ]
        )

        for (index, invalidReference) in [
            String(repeating: "x", count: 36),
            String(repeating: "-", count: 36),
            UUID().uuidString.uppercased(),
        ].enumerated() {
            #expect(throws: SQLiteError.constraintFailed) {
                try database.execute(
                    """
                    INSERT INTO capability_secret_bindings
                        (id, server_id, binding_kind, binding_name, credential_ref)
                    VALUES (?, 'local-tools', 'header', ?, ?)
                    """,
                    bindings: [
                        .text(UUID().uuidString.lowercased()),
                        .text("X-Invalid-\(index)"),
                        .text(invalidReference),
                    ]
                )
            }
        }
        #expect(throws: SQLiteError.constraintFailed) {
            try database.execute(
                """
                INSERT INTO capability_tools
                    (id, server_id, source, source_server_id, tool_name,
                     display_name, summary, input_schema_json, read_only_hint,
                     available, stale_state, content_hash, reconciled_at)
                VALUES ('miller_mcp/local-tools/bad', 'local-tools',
                        'miller_mcp', 'local-tools', 'bad', 'Bad', 'Bad',
                        ?, 1, 1, 'current', NULL, ?)
                """,
                bindings: [
                    .blob(Data("not-json".utf8)),
                    .text("2026-08-05T00:00:00.000Z"),
                ]
            )
        }
    }

    @Test
    func serverIDsAndInputSchemasAreCanonicalBeforeWrite() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        for invalidID in ["UPPER", "has space", "has/slash", "café"] {
            let server = CapabilityServerRecord(
                id: invalidID, displayName: "Invalid", transport: .stdio,
                command: "/usr/bin/env", endpoint: nil, arguments: [],
                enabled: true, defaultPolicy: .askBeforeChanges,
                staleState: .current, createdAt: Date(), updatedAt: Date()
            )
            await #expect(throws: CapabilityStorageError.invalidServer) {
                try await repository.saveServer(server)
            }
        }
        #expect(try await repository.servers().isEmpty)

        try await repository.saveServer(makeServer())
        let arraySchema = try CapabilityDescriptor(
            id: CapabilityID(
                source: .millerMCP,
                serverID: "local-tools",
                toolName: "array"
            ),
            source: .millerMCP, serverID: "local-tools", toolName: "array",
            displayName: "Array", summary: "Array",
            inputSchemaJSON: Data("[]".utf8), readOnlyHint: true,
            providerProfileIDs: [], isAvailable: true
        )
        await #expect(throws: CapabilityStorageError.malformedSchema) {
            try await repository.reconcileCatalog(
                serverID: "local-tools",
                descriptors: [arraySchema]
            )
        }
        let canonical = try descriptor(tool: "canonical", summary: "Canonical")
        try await repository.reconcileCatalog(
            serverID: "local-tools", descriptors: [canonical]
        )
        #expect(try await repository.catalog(serverID: "local-tools").count == 1)
    }

    @Test
    func catalogReconciliationRetainsStaleToolsAndPreservesOverrides() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        try await repository.saveServer(makeServer())
        let first = try descriptor(tool: "first", summary: "First")
        let second = try descriptor(tool: "second", summary: "Second")
        try await repository.reconcileCatalog(
            serverID: "local-tools",
            descriptors: [first, second],
            refreshedAt: Date(timeIntervalSince1970: 100)
        )
        try await repository.setPolicyOverride(.fullyTrusted, toolID: first.id)

        let updatedFirst = try descriptor(tool: "first", summary: "Updated")
        try await repository.reconcileCatalog(
            serverID: "local-tools",
            descriptors: [updatedFirst],
            refreshedAt: Date(timeIntervalSince1970: 200)
        )
        let tools = try await repository.catalog(serverID: "local-tools")
        #expect(tools.count == 2)
        #expect(tools.first { $0.descriptor.id == first.id }?.descriptor.summary == "Updated")
        #expect(tools.first { $0.descriptor.id == first.id }?.policyOverride == .fullyTrusted)
        #expect(tools.first { $0.descriptor.id == second.id }?.staleState == .stale)
        #expect(tools.first { $0.descriptor.id == second.id }?.descriptor.isAvailable == false)

        try await repository.markCatalogStale(serverID: "local-tools")
        #expect(try await repository.catalog(serverID: "local-tools").allSatisfy {
            $0.staleState == .stale
        })
    }

    @Test
    func catalogRoundTripPreservesProviderAuthorityState() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        try await repository.saveServer(makeServer())
        let authorityDescriptor = try CapabilityDescriptor(
            id: CapabilityID(
                source: .codexAccount,
                serverID: "local-tools",
                toolName: "calendar"
            ),
            source: .codexAccount,
            serverID: "local-tools",
            toolName: "calendar",
            displayName: "Calendar",
            summary: "Calendar is unavailable.",
            inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            readOnlyHint: nil,
            providerProfileIDs: [],
            isAvailable: true,
            isAccessible: false,
            isEnabled: false,
            isCallable: false,
            visibility: .providerManaged
        )

        try await repository.reconcileCatalog(
            serverID: "local-tools",
            descriptors: [authorityDescriptor]
        )

        let restored = try #require(
            await repository.catalog(serverID: "local-tools").first?.descriptor
        )
        #expect(restored.isAvailable == true)
        #expect(restored.isAccessible == false)
        #expect(restored.isEnabled == false)
        #expect(restored.isCallable == false)
        #expect(restored.visibility == .providerManaged)
    }

    @Test
    func catalogBoundsAreCheckedBeforeAtomicRefresh() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        try await repository.saveServer(makeServer())
        let original = try descriptor(tool: "original", summary: "Original")
        try await repository.reconcileCatalog(
            serverID: "local-tools", descriptors: [original]
        )

        let oversized = try descriptor(
            tool: "oversized",
            summary: String(repeating: "é", count: 513)
        )
        await #expect(throws: CapabilityStorageError.summaryTooLarge) {
            try await repository.reconcileCatalog(
                serverID: "local-tools", descriptors: [oversized]
            )
        }
        #expect(try await repository.catalog(serverID: "local-tools").map(\.descriptor.id) == [original.id])

        let repeated = Array(repeating: original, count: 2_049)
        await #expect(throws: CapabilityStorageError.catalogTooLarge) {
            try await repository.reconcileCatalog(
                serverID: "local-tools", descriptors: repeated
            )
        }
        #expect(try await repository.catalog(serverID: "local-tools").count == 1)
    }

    @Test
    func sanitizedAuditSummaryRendersOnlyTrustedBoundedProjections() throws {
        let safe = SanitizedCapabilitySummary(.listCalendarEvents)
        #expect(safe.text == "List calendar events.")
        #expect(safe.text.utf8.count <= 1_024)
        #expect(
            try JSONDecoder().decode(
                SanitizedCapabilitySummary.self,
                from: JSONEncoder().encode(safe)
            ) == safe
        )

        let refusal = SanitizedCapabilitySummary(.approvalDeclined)
        #expect(refusal.text == "Capability request declined by the user.")
        #expect(
            try JSONDecoder().decode(
                SanitizedCapabilitySummary.self,
                from: JSONEncoder().encode(refusal)
            ) == refusal
        )

        for adversary in [
            "password=hunter2", "access_token=secret", "Cookie: session=x",
            "{\"result\":\"raw\"}", "private email body",
            String(repeating: "x", count: 1_025),
        ] {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    SanitizedCapabilitySummary.self,
                    from: JSONEncoder().encode(adversary)
                )
            }
        }
    }

    @Test
    func schemaAcceptsOnlyTrustedBoundedAuditSummaryRenderings() throws {
        let fixture = try TestDatabase(named: #function)
        let database = try SQLiteDatabase(path: fixture.path)
        let conversationID = ConversationID()
        try insertConversation(conversationID, database: database)
        let projections = SanitizedCapabilitySummary.Projection.allCases
        let auditIDs = projections.map { _ in UUID() }
        for (id, projection) in zip(auditIDs, projections) {
            try insertRawAudit(
                id: id,
                conversationID: conversationID,
                turnID: nil,
                voiceSessionID: nil,
                sanitizedSummary: SanitizedCapabilitySummary(projection).text,
                database: database
            )
        }
        #expect(
            try database.scalarInt("SELECT COUNT(*) FROM capability_audit")
                == projections.count
        )

        for adversary in [
            "password=hunter2", "access_token=secret", "Cookie: session=x",
            "{\"result\":\"raw\"}", "private email body",
            String(repeating: "x", count: 1_025),
        ] {
            #expect(throws: SQLiteError.constraintFailed) {
                try database.execute(
                    "UPDATE capability_audit SET sanitized_summary = ? WHERE id = ?",
                    bindings: [
                        .text(adversary),
                        .text(auditIDs[0].uuidString.lowercased()),
                    ]
                )
            }
        }
    }

    @Test
    func auditPersistsTrustedSummaryAndTerminalizesIdempotently() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let conversationID = ConversationID()
        let database = try SQLiteDatabase(path: fixture.path)
        try insertConversation(conversationID, database: database)
        let callID = CapabilityCallID()
        let started = Date(timeIntervalSince1970: 100)
        let audit = CapabilityAuditRecord(
            id: callID,
            conversationID: conversationID,
            turnID: nil,
            voiceSessionID: nil,
            source: .millerMCP,
            serverID: "local-tools",
            toolName: "search",
            startedAt: started,
            terminalAt: nil,
            effectivePolicy: .askBeforeChanges,
            approvalRequested: true,
            approvalDecision: nil,
            terminalOutcome: nil,
            summary: SanitizedCapabilitySummary(.readLocalFiles),
            visibility: .complete
        )
        try await repository.beginAudit(audit)
        try await repository.beginAudit(audit)
        await #expect(throws: CapabilityStorageError.invalidAudit) {
            try await repository.beginAudit(
                CapabilityAuditRecord(
                    id: callID, conversationID: conversationID,
                    turnID: nil, voiceSessionID: nil, source: .millerMCP,
                    serverID: "local-tools", toolName: "different",
                    startedAt: started, terminalAt: nil,
                    effectivePolicy: .askBeforeChanges,
                    approvalRequested: true, approvalDecision: nil,
                    terminalOutcome: nil,
                    summary: SanitizedCapabilitySummary(.readLocalFiles),
                    visibility: .complete
                )
            )
        }
        try await repository.terminalizeAudit(
            id: callID,
            outcome: .succeeded,
            approvalDecision: .allowOnce,
            terminalAt: started.addingTimeInterval(2)
        )
        try await repository.terminalizeAudit(
            id: callID,
            outcome: .succeeded,
            approvalDecision: .allowOnce,
            terminalAt: started.addingTimeInterval(2)
        )
        await #expect(throws: CapabilityStorageError.invalidAudit) {
            try await repository.terminalizeAudit(
                id: callID, outcome: .failed,
                approvalDecision: .allowOnce,
                terminalAt: started.addingTimeInterval(3)
            )
        }
        let stored = try #require(try await repository.audit(id: callID))
        #expect(stored.terminalOutcome == .succeeded)
        #expect(stored.approvalDecision == .allowOnce)
        #expect(stored.terminalAt == started.addingTimeInterval(2))
        #expect(
            stored.summary
                == SanitizedCapabilitySummary(.readLocalFiles)
        )

        let invalidTerminalID = CapabilityCallID()
        try await repository.beginAudit(
            CapabilityAuditRecord(
                id: invalidTerminalID, conversationID: conversationID,
                turnID: nil, voiceSessionID: nil, source: .millerMCP,
                serverID: "local-tools", toolName: "search",
                startedAt: started, terminalAt: nil,
                effectivePolicy: .askBeforeChanges,
                approvalRequested: true, approvalDecision: nil,
                terminalOutcome: nil,
                summary: SanitizedCapabilitySummary(.readLocalFiles),
                visibility: .complete
            )
        )
        await #expect(throws: CapabilityStorageError.invalidAudit) {
            try await repository.terminalizeAudit(
                id: invalidTerminalID, outcome: .succeeded,
                approvalDecision: nil,
                terminalAt: started.addingTimeInterval(-1)
            )
        }
        #expect(try await repository.audit(id: invalidTerminalID)?.terminalAt == nil)
    }

    @Test
    func openAuditCanRequireApprovalBeforeTerminalization() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let conversationID = ConversationID()
        try insertConversation(
            conversationID,
            database: SQLiteDatabase(path: fixture.path)
        )
        let callID = CapabilityCallID()
        try await repository.beginAudit(
            try makeAudit(
                id: callID,
                conversationID: conversationID,
                turnID: nil,
                voiceSessionID: nil
            )
        )

        try await repository.requireAuditApproval(
            id: callID,
            effectivePolicy: .askBeforeChanges
        )
        try await repository.requireAuditApproval(
            id: callID,
            effectivePolicy: .askBeforeChanges
        )

        var stored = try #require(try await repository.audit(id: callID))
        #expect(stored.approvalRequested)
        #expect(stored.effectivePolicy == .askBeforeChanges)
        await #expect(throws: CapabilityStorageError.invalidAudit) {
            try await repository.requireAuditApproval(
                id: callID,
                effectivePolicy: .fullyTrusted
            )
        }

        try await repository.terminalizeAudit(
            id: callID,
            outcome: .succeeded,
            approvalDecision: .allowOnce
        )
        stored = try #require(try await repository.audit(id: callID))
        #expect(stored.terminalOutcome == .succeeded)
        #expect(stored.approvalDecision == .allowOnce)
        await #expect(throws: CapabilityStorageError.invalidAudit) {
            try await repository.requireAuditApproval(
                id: callID,
                effectivePolicy: .askBeforeChanges
            )
        }
    }

    @Test
    func terminalAuditReplayWithoutTimestampDoesNotAssertANewClockValue() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let conversationID = ConversationID()
        try insertConversation(
            conversationID,
            database: SQLiteDatabase(path: fixture.path)
        )
        let callID = CapabilityCallID()
        try await repository.beginAudit(
            try makeAudit(
                id: callID,
                conversationID: conversationID,
                turnID: nil,
                voiceSessionID: nil
            )
        )

        try await repository.terminalizeAudit(
            id: callID, outcome: .succeeded, approvalDecision: nil
        )
        let firstTerminalAt = try #require(
            try await repository.audit(id: callID)?.terminalAt
        )
        try await repository.terminalizeAudit(
            id: callID, outcome: .succeeded, approvalDecision: nil
        )

        #expect(try await repository.audit(id: callID)?.terminalAt == firstTerminalAt)
    }

    @Test
    func terminalAuditReplayCanonicalizesExplicitSubmillisecondTimestamp() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let conversationID = ConversationID()
        try insertConversation(
            conversationID,
            database: SQLiteDatabase(path: fixture.path)
        )
        let callID = CapabilityCallID()
        try await repository.beginAudit(
            try makeAudit(
                id: callID,
                conversationID: conversationID,
                turnID: nil,
                voiceSessionID: nil
            )
        )
        let terminalAt = Date(timeIntervalSince1970: 100.123_456)

        try await repository.terminalizeAudit(
            id: callID,
            outcome: .succeeded,
            approvalDecision: nil,
            terminalAt: terminalAt
        )
        try await repository.terminalizeAudit(
            id: callID,
            outcome: .succeeded,
            approvalDecision: nil,
            terminalAt: terminalAt
        )

        #expect(try await repository.audit(id: callID)?.terminalAt != nil)
    }

    @Test
    func serverAndAssociationDeletesDoNotRemoveUnrelatedAudit() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let conversationID = ConversationID()
        let database = try SQLiteDatabase(path: fixture.path)
        try insertConversation(conversationID, database: database)
        try await repository.saveServer(makeServer())
        let tool = try descriptor(tool: "search", summary: "Search")
        try await repository.reconcileCatalog(serverID: "local-tools", descriptors: [tool])
        try await repository.setPolicyOverride(.fullyTrusted, toolID: tool.id)
        let callID = CapabilityCallID()
        try await repository.beginAudit(
            CapabilityAuditRecord(
                id: callID, conversationID: conversationID, turnID: nil,
                voiceSessionID: nil, source: .millerMCP,
                serverID: "local-tools", toolName: "search",
                startedAt: Date(), terminalAt: nil,
                effectivePolicy: .fullyTrusted,
                approvalRequested: false, approvalDecision: nil,
                terminalOutcome: nil,
                summary: SanitizedCapabilitySummary(.providerDetailsUnavailable),
                visibility: .opaqueProviderActivity
            )
        )
        try await repository.deleteServer(id: "local-tools")
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_tools") == 0)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_policy_overrides") == 0)
        #expect(try await repository.audit(id: callID) != nil)
    }

    @Test
    func auditRequiresAssociationAndOneExecutionKindAtRepositoryAndSQLBoundaries() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let database = try SQLiteDatabase(path: fixture.path)
        let conversationID = ConversationID()
        let turnID = TurnID()
        let voiceSessionID = UUID()
        try insertConversation(conversationID, database: database)
        try insertTurn(turnID, conversationID: conversationID, database: database)
        let voice = try SQLiteVoiceHistoryRepository(path: fixture.path)
        try await voice.startSession(
            id: voiceSessionID,
            conversationID: conversationID,
            activationSource: .manual,
            saveChoice: .save
        )

        await #expect(throws: CapabilityStorageError.invalidAudit) {
            try await repository.beginAudit(
                try makeAudit(
                    id: CapabilityCallID(),
                    conversationID: nil,
                    turnID: nil,
                    voiceSessionID: nil
                )
            )
        }
        await #expect(throws: CapabilityStorageError.invalidAudit) {
            try await repository.beginAudit(
                try makeAudit(
                    id: CapabilityCallID(),
                    conversationID: conversationID,
                    turnID: turnID,
                    voiceSessionID: voiceSessionID
                )
            )
        }
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_audit") == 0)

        #expect(throws: SQLiteError.constraintFailed) {
            try insertRawAudit(
                id: UUID(),
                conversationID: nil,
                turnID: nil,
                voiceSessionID: nil,
                database: database
            )
        }
        #expect(throws: SQLiteError.constraintFailed) {
            try insertRawAudit(
                id: UUID(),
                conversationID: conversationID,
                turnID: turnID,
                voiceSessionID: voiceSessionID,
                database: database
            )
        }
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_audit") == 0)
    }

    @Test
    func schemaRequiresDecisionsForRequestedTerminalAuditOutcomes() throws {
        let fixture = try TestDatabase(named: #function)
        let database = try SQLiteDatabase(path: fixture.path)
        let conversationID = ConversationID()
        try insertConversation(conversationID, database: database)

        for outcome in ["succeeded", "declined"] {
            #expect(throws: SQLiteError.constraintFailed) {
                try insertRawTerminalAudit(
                    id: UUID(),
                    conversationID: conversationID,
                    approvalRequested: 1,
                    approvalDecision: nil,
                    terminalOutcome: outcome,
                    database: database
                )
            }
        }

        for (requested, decision, outcome) in [
            (1, "allow_once", "succeeded"),
            (1, "decline", "declined"),
            (1, nil, "cancelled"),
            (0, nil, "succeeded"),
        ] as [(Int, String?, String)] {
            try insertRawTerminalAudit(
                id: UUID(),
                conversationID: conversationID,
                approvalRequested: requested,
                approvalDecision: decision,
                terminalOutcome: outcome,
                database: database
            )
        }
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_audit") == 4)
    }

    @Test
    func typedAuditNormalizesParentAndRejectsMismatchWithoutPartialWrite() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let database = try SQLiteDatabase(path: fixture.path)
        let actualConversationID = ConversationID()
        let unrelatedConversationID = ConversationID()
        let turnID = TurnID()
        try insertConversation(actualConversationID, database: database)
        try insertConversation(unrelatedConversationID, database: database)
        try insertTurn(
            turnID,
            conversationID: actualConversationID,
            database: database
        )

        let typedCallID = CapabilityCallID()
        try await repository.beginAudit(
            makeAudit(
                id: typedCallID,
                conversationID: nil,
                turnID: turnID,
                voiceSessionID: nil
            )
        )
        #expect(try await repository.audit(id: typedCallID)?.conversationID == actualConversationID)

        await #expect(throws: CapabilityStorageError.invalidAudit) {
            try await repository.beginAudit(
                try makeAudit(
                    id: CapabilityCallID(),
                    conversationID: unrelatedConversationID,
                    turnID: turnID,
                    voiceSessionID: nil
                )
            )
        }
        #expect(try await repository.audits().count == 1)

        let conversationOnlyCallID = CapabilityCallID()
        try await repository.beginAudit(
            makeAudit(
                id: conversationOnlyCallID,
                conversationID: actualConversationID,
                turnID: nil,
                voiceSessionID: nil
            )
        )
        try database.execute(
            "DELETE FROM conversations WHERE id = ?",
            bindings: [.text(unrelatedConversationID.description)]
        )
        #expect(try await repository.audit(id: typedCallID) != nil)
        #expect(try await repository.audit(id: conversationOnlyCallID) != nil)

        try database.execute(
            "DELETE FROM turns WHERE id = ?",
            bindings: [.text(turnID.description)]
        )
        #expect(try await repository.audit(id: typedCallID) == nil)
        #expect(try await repository.audit(id: conversationOnlyCallID) != nil)
        try database.execute(
            "DELETE FROM conversations WHERE id = ?",
            bindings: [.text(actualConversationID.description)]
        )
        #expect(try await repository.audit(id: conversationOnlyCallID) == nil)
    }

    @Test
    func voiceAuditRequiresSessionConversationCoherenceAndCascadesBySession() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let voice = try SQLiteVoiceHistoryRepository(path: fixture.path)
        let database = try SQLiteDatabase(path: fixture.path)
        let conversationID = ConversationID()
        let unrelatedConversationID = ConversationID()
        let linkedSessionID = UUID()
        let unlinkedSessionID = UUID()
        try insertConversation(conversationID, database: database)
        try insertConversation(unrelatedConversationID, database: database)
        try await voice.startSession(
            id: linkedSessionID,
            conversationID: conversationID,
            activationSource: .manual,
            saveChoice: .save
        )
        try await voice.startSession(
            id: unlinkedSessionID,
            conversationID: nil,
            activationSource: .manual,
            saveChoice: .save
        )

        let linkedCallID = CapabilityCallID()
        let unlinkedCallID = CapabilityCallID()
        try await repository.beginAudit(
            makeAudit(
                id: linkedCallID,
                conversationID: conversationID,
                turnID: nil,
                voiceSessionID: linkedSessionID
            )
        )
        try await repository.beginAudit(
            makeAudit(
                id: unlinkedCallID,
                conversationID: nil,
                turnID: nil,
                voiceSessionID: unlinkedSessionID
            )
        )

        for invalid in [
            try makeAudit(
                id: CapabilityCallID(),
                conversationID: nil,
                turnID: nil,
                voiceSessionID: linkedSessionID
            ),
            try makeAudit(
                id: CapabilityCallID(),
                conversationID: unrelatedConversationID,
                turnID: nil,
                voiceSessionID: linkedSessionID
            ),
            try makeAudit(
                id: CapabilityCallID(),
                conversationID: conversationID,
                turnID: nil,
                voiceSessionID: unlinkedSessionID
            ),
        ] {
            await #expect(throws: CapabilityStorageError.invalidAudit) {
                try await repository.beginAudit(invalid)
            }
        }
        #expect(try await repository.audits().count == 2)

        try database.execute(
            "DELETE FROM conversations WHERE id = ?",
            bindings: [.text(unrelatedConversationID.description)]
        )
        #expect(try await repository.audit(id: linkedCallID) != nil)
        #expect(try await repository.audit(id: unlinkedCallID) != nil)
        try await voice.deleteSession(id: linkedSessionID)
        #expect(try await repository.audit(id: linkedCallID) == nil)
        #expect(try await repository.audit(id: unlinkedCallID) != nil)
        try await voice.deleteSession(id: unlinkedSessionID)
        #expect(try await repository.audit(id: unlinkedCallID) == nil)
    }

    @Test
    func pluginAndSkillSnapshotsRoundTripAndProviderSettingsCascade() async throws {
        let fixture = try TestDatabase(named: #function)
        let profileID = UUID()
        try insertProviderProfile(profileID, path: fixture.path)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        let plugin = PluginPackageRecord(
            id: "plugin.example", version: "1.0.0", sourceHash: "abc123",
            supportedComponentSummary: "One portable skill", enabled: false,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let skill = PortableSkillRecord(
            id: "skill.example", pluginID: plugin.id, name: "Example",
            description: "Does one thing", markdownSnapshot: "# Example",
            sourceHash: "def456", enabled: true,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try await repository.savePlugin(plugin)
        try await repository.saveSkill(skill)
        try await repository.setSkillEnabled(
            true, skillID: skill.id, providerProfileID: profileID
        )
        #expect(try await repository.plugins() == [plugin])
        #expect(try await repository.skills() == [skill])
        #expect(try await repository.enabledSkillProviderProfileIDs(skillID: skill.id) == [profileID])

        let database = try SQLiteDatabase(path: fixture.path)
        try database.execute(
            "DELETE FROM provider_profiles WHERE id = ?",
            bindings: [.text(profileID.uuidString.lowercased())]
        )
        #expect(try database.scalarInt("SELECT COUNT(*) FROM provider_skill_settings") == 0)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM portable_skills") == 1)
        try await repository.deletePlugin(id: plugin.id)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM portable_skills") == 0)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM provider_skill_settings") == 0)
    }

    @Test
    func injectedStorageFailureDoesNotPartiallyReconcile() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        try await repository.saveServer(makeServer())
        let full = try SQLiteCapabilityRepository(
            path: fixture.path,
            simulatedWriteFailure: .storageFull
        )
        await #expect(throws: SQLiteError.storageFull) {
            try await full.reconcileCatalog(
                serverID: "local-tools",
                descriptors: [try descriptor(tool: "search", summary: "Search")]
            )
        }
        #expect(try await repository.catalog(serverID: "local-tools").isEmpty)

        let original = try descriptor(tool: "original", summary: "Original")
        try await repository.reconcileCatalog(
            serverID: "local-tools", descriptors: [original]
        )

        let midTransaction = try SQLiteCapabilityRepository(
            path: fixture.path,
            simulatedReconcileFailure: .writeFailed
        )
        await #expect(throws: SQLiteError.writeFailed) {
            try await midTransaction.reconcileCatalog(
                serverID: "local-tools",
                descriptors: [
                    try descriptor(tool: "first", summary: "First"),
                    try descriptor(tool: "second", summary: "Second"),
                ]
            )
        }
        let retained = try await repository.catalog(serverID: "local-tools")
        #expect(retained.map(\.descriptor.id) == [original.id])
        #expect(retained.first?.staleState == .current)
    }
}

private func makeServer() -> CapabilityServerRecord {
    CapabilityServerRecord(
        id: "local-tools", displayName: "Local tools", transport: .stdio,
        command: "/usr/bin/env", endpoint: nil, arguments: [], enabled: true,
        defaultPolicy: .askBeforeChanges, staleState: .current,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

private func descriptor(
    tool: String,
    summary: String
) throws -> CapabilityDescriptor {
    try CapabilityDescriptor(
        id: CapabilityID(source: .millerMCP, serverID: "local-tools", toolName: tool),
        source: .millerMCP,
        serverID: "local-tools",
        toolName: tool,
        displayName: tool.capitalized,
        summary: summary,
        inputSchemaJSON: Data("{\"type\":\"object\"}".utf8),
        readOnlyHint: true,
        providerProfileIDs: [],
        isAvailable: true
    )
}

private func makeAudit(
    id: CapabilityCallID,
    conversationID: ConversationID?,
    turnID: TurnID?,
    voiceSessionID: UUID?
) throws -> CapabilityAuditRecord {
    CapabilityAuditRecord(
        id: id,
        conversationID: conversationID,
        turnID: turnID,
        voiceSessionID: voiceSessionID,
        source: .millerMCP,
        serverID: "local-tools",
        toolName: "search",
        startedAt: Date(timeIntervalSince1970: 100),
        terminalAt: nil,
        effectivePolicy: .askBeforeChanges,
        approvalRequested: false,
        approvalDecision: nil,
        terminalOutcome: nil,
        summary: SanitizedCapabilitySummary(.readLocalFiles),
        visibility: .complete
    )
}

private func insertConversation(
    _ id: ConversationID,
    database: SQLiteDatabase
) throws {
    try database.execute(
        """
        INSERT INTO conversations
            (id, title, state, created_at, updated_at, archived_at)
        VALUES (?, NULL, 'active', ?, ?, NULL)
        """,
        bindings: [
            .text(id.description),
            .text("2026-08-05T00:00:00.000Z"),
            .text("2026-08-05T00:00:00.000Z"),
        ]
    )
}

private func insertTurn(
    _ id: TurnID,
    conversationID: ConversationID,
    database: SQLiteDatabase
) throws {
    try database.execute(
        """
        INSERT INTO turns
            (id, conversation_id, sequence, input_mode, user_text,
             assistant_text, state, generation, error_code, error_message,
             started_at, terminal_at)
        VALUES (?, ?, 1, 'text', 'Question', '', 'accepted', 1,
                NULL, NULL, ?, NULL)
        """,
        bindings: [
            .text(id.description),
            .text(conversationID.description),
            .text("2026-08-05T00:00:00.000Z"),
        ]
    )
}

private func insertRawAudit(
    id: UUID,
    conversationID: ConversationID?,
    turnID: TurnID?,
    voiceSessionID: UUID?,
    sanitizedSummary: String = SanitizedCapabilitySummary(
        .readLocalFiles
    ).text,
    database: SQLiteDatabase
) throws {
    try database.execute(
        """
        INSERT INTO capability_audit
            (id, conversation_id, turn_id, voice_session_id, source,
             source_server_id, tool_name, started_at, terminal_at,
             effective_policy, approval_requested, approval_decision,
             terminal_outcome, sanitized_summary, visibility)
        VALUES (?, ?, ?, ?, 'miller_mcp', 'local-tools', 'search', ?,
                NULL, 'ask_before_changes', 0, NULL, NULL,
                ?, 'complete')
        """,
        bindings: [
            .text(id.uuidString.lowercased()),
            conversationID.map { .text($0.description) } ?? .null,
            turnID.map { .text($0.description) } ?? .null,
            voiceSessionID.map {
                .text($0.uuidString.lowercased())
            } ?? .null,
            .text("2026-08-05T00:00:00.000Z"),
            .text(sanitizedSummary),
        ]
    )
}

private func insertRawTerminalAudit(
    id: UUID,
    conversationID: ConversationID,
    approvalRequested: Int,
    approvalDecision: String?,
    terminalOutcome: String,
    database: SQLiteDatabase
) throws {
    try database.execute(
        """
        INSERT INTO capability_audit
            (id, conversation_id, turn_id, voice_session_id, source,
             source_server_id, tool_name, started_at, terminal_at,
             effective_policy, approval_requested, approval_decision,
             terminal_outcome, sanitized_summary, visibility)
        VALUES (?, ?, NULL, NULL, 'miller_mcp', 'local-tools', 'search',
                ?, ?, 'ask_before_changes', ?, ?, ?, NULL, 'complete')
        """,
        bindings: [
            .text(id.uuidString.lowercased()),
            .text(conversationID.description),
            .text("2026-08-05T00:00:00.000Z"),
            .text("2026-08-05T00:00:01.000Z"),
            .integer(Int64(approvalRequested)),
            approvalDecision.map(SQLiteValue.text) ?? .null,
            .text(terminalOutcome),
        ]
    )
}

private func insertProviderProfile(_ id: UUID, path: String) throws {
    let database = try SQLiteDatabase(path: path)
    try database.execute(
        """
        INSERT INTO provider_profiles
            (id, kind, label, base_url, model, credential_ref, is_selected,
             created_at, updated_at, credential_status)
        VALUES (?, 'codex_oauth', 'Provider', NULL, 'gpt-5', ?, 1, ?, ?, 'valid')
        """,
        bindings: [
            .text(id.uuidString.lowercased()),
            .text(UUID().uuidString.lowercased()),
            .text("2026-08-05T00:00:00.000Z"),
            .text("2026-08-05T00:00:00.000Z"),
        ]
    )
}

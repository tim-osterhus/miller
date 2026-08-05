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

        #expect(throws: SQLiteError.constraintFailed) {
            try database.execute(
                """
                INSERT INTO capability_secret_bindings
                    (id, server_id, binding_kind, binding_name, credential_ref)
                VALUES (?, 'local-tools', 'header', 'Authorization', ?)
                """,
                bindings: [
                    .text(UUID().uuidString.lowercased()),
                    .text(String(repeating: "x", count: 36)),
                ]
            )
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
    func auditAcceptsSanitizedSummaryAndTerminalizesIdempotently() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        #expect(throws: CapabilityStorageError.unsanitizedAuditSummary) {
            _ = try SanitizedCapabilitySummary(text: "Authorization: Bearer secret")
        }
        let callID = CapabilityCallID()
        let started = Date(timeIntervalSince1970: 100)
        let audit = CapabilityAuditRecord(
            id: callID,
            conversationID: nil,
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
            summary: try SanitizedCapabilitySummary(text: "Search local index"),
            visibility: .complete
        )
        try await repository.beginAudit(audit)
        try await repository.terminalizeAudit(
            id: callID,
            outcome: .succeeded,
            approvalDecision: .allowOnce,
            terminalAt: started.addingTimeInterval(2)
        )
        try await repository.terminalizeAudit(
            id: callID,
            outcome: .failed,
            approvalDecision: .decline,
            terminalAt: started.addingTimeInterval(9)
        )
        let stored = try #require(try await repository.audit(id: callID))
        #expect(stored.terminalOutcome == .succeeded)
        #expect(stored.approvalDecision == .allowOnce)
        #expect(stored.terminalAt == started.addingTimeInterval(2))
    }

    @Test
    func serverAndAssociationDeletesDoNotRemoveUnrelatedAudit() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteCapabilityRepository(path: fixture.path)
        try await repository.saveServer(makeServer())
        let tool = try descriptor(tool: "search", summary: "Search")
        try await repository.reconcileCatalog(serverID: "local-tools", descriptors: [tool])
        try await repository.setPolicyOverride(.fullyTrusted, toolID: tool.id)
        let callID = CapabilityCallID()
        try await repository.beginAudit(
            CapabilityAuditRecord(
                id: callID, conversationID: nil, turnID: nil,
                voiceSessionID: nil, source: .millerMCP,
                serverID: "local-tools", toolName: "search",
                startedAt: Date(), terminalAt: nil,
                effectivePolicy: .fullyTrusted,
                approvalRequested: false, approvalDecision: nil,
                terminalOutcome: nil,
                summary: try SanitizedCapabilitySummary(text: "Search"),
                visibility: .opaqueProviderActivity
            )
        )
        try await repository.deleteServer(id: "local-tools")
        let database = try SQLiteDatabase(path: fixture.path)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_tools") == 0)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM capability_policy_overrides") == 0)
        #expect(try await repository.audit(id: callID) != nil)
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

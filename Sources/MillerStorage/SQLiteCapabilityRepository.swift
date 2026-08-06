import Foundation
import MillerCore

public enum CapabilityServerTransport: String, Codable, Sendable {
    case stdio
    case streamableHTTP = "streamable_http"
}

public enum CapabilityCatalogStaleState: String, Codable, Sendable {
    case current
    case stale
}

public enum CapabilitySecretBindingKind: String, Codable, Sendable {
    case environment
    case header
}

public enum CapabilityAuditVisibility: String, Codable, Sendable {
    case complete
    case opaqueProviderActivity = "opaque_provider_activity"
}

public struct CapabilityServerRecord: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let transport: CapabilityServerTransport
    public let command: String?
    public let endpoint: String?
    public let arguments: [String]
    public let enabled: Bool
    public let defaultPolicy: CapabilityPolicy
    public let staleState: CapabilityCatalogStaleState
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        displayName: String,
        transport: CapabilityServerTransport,
        command: String?,
        endpoint: String?,
        arguments: [String],
        enabled: Bool,
        defaultPolicy: CapabilityPolicy,
        staleState: CapabilityCatalogStaleState,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.command = command
        self.endpoint = endpoint
        self.arguments = arguments
        self.enabled = enabled
        self.defaultPolicy = defaultPolicy
        self.staleState = staleState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CapabilitySecretBinding: Codable, Equatable, Sendable {
    public let id: UUID
    public let serverID: String
    public let kind: CapabilitySecretBindingKind
    public let name: String
    public let credentialReference: UUID

    public init(
        id: UUID,
        serverID: String,
        kind: CapabilitySecretBindingKind,
        name: String,
        credentialReference: UUID
    ) {
        self.id = id
        self.serverID = serverID
        self.kind = kind
        self.name = name
        self.credentialReference = credentialReference
    }
}

public struct CapabilityToolRecord: Equatable, Sendable {
    public let descriptor: CapabilityDescriptor
    public let staleState: CapabilityCatalogStaleState
    public let policyOverride: CapabilityPolicy?
    public let reconciledAt: Date

    public init(
        descriptor: CapabilityDescriptor,
        staleState: CapabilityCatalogStaleState,
        policyOverride: CapabilityPolicy?,
        reconciledAt: Date
    ) {
        self.descriptor = descriptor
        self.staleState = staleState
        self.policyOverride = policyOverride
        self.reconciledAt = reconciledAt
    }
}

public struct SanitizedCapabilitySummary: Codable, Equatable, Sendable {
    public enum Projection: CaseIterable, Sendable {
        case listCalendarEvents
        case createCalendarEvent
        case searchEmailMetadata
        case readLocalFiles
        case changeLocalFiles
        case runLocalCommand
        case approvalDeclined
        case policyRefused
        case providerDetailsUnavailable
    }

    public let projection: Projection

    public var text: String {
        switch projection {
        case .listCalendarEvents:
            "List calendar events."
        case .createCalendarEvent:
            "Create a calendar event."
        case .searchEmailMetadata:
            "Search email metadata."
        case .readLocalFiles:
            "Read local files."
        case .changeLocalFiles:
            "Change local files."
        case .runLocalCommand:
            "Run a local command."
        case .approvalDeclined:
            "Capability request declined by the user."
        case .policyRefused:
            "Capability request refused by policy."
        case .providerDetailsUnavailable:
            "Provider activity recorded without result details."
        }
    }

    public init(_ projection: Projection) {
        self.projection = projection
    }

    init?(persistedText text: String) {
        guard text.utf8.count <= 1_024,
              let projection = Projection.allCases.first(where: {
                  SanitizedCapabilitySummary($0).text == text
              })
        else { return nil }
        self.projection = projection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let summary = SanitizedCapabilitySummary(persistedText: text)
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Untrusted capability audit summary"
            )
        }
        self = summary
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public struct CapabilityAuditRecord: Codable, Equatable, Sendable {
    public let id: CapabilityCallID
    public let conversationID: ConversationID?
    public let turnID: TurnID?
    public let voiceSessionID: UUID?
    public let source: CapabilitySource
    public let serverID: String
    public let toolName: String
    public let startedAt: Date
    public let terminalAt: Date?
    public let effectivePolicy: CapabilityPolicy
    public let approvalRequested: Bool
    public let approvalDecision: CapabilityApprovalDecision?
    public let terminalOutcome: CapabilityTerminalOutcome?
    public let summary: SanitizedCapabilitySummary?
    public let visibility: CapabilityAuditVisibility

    public init(
        id: CapabilityCallID,
        conversationID: ConversationID?,
        turnID: TurnID?,
        voiceSessionID: UUID?,
        source: CapabilitySource,
        serverID: String,
        toolName: String,
        startedAt: Date,
        terminalAt: Date?,
        effectivePolicy: CapabilityPolicy,
        approvalRequested: Bool,
        approvalDecision: CapabilityApprovalDecision?,
        terminalOutcome: CapabilityTerminalOutcome?,
        summary: SanitizedCapabilitySummary?,
        visibility: CapabilityAuditVisibility
    ) {
        self.id = id
        self.conversationID = conversationID
        self.turnID = turnID
        self.voiceSessionID = voiceSessionID
        self.source = source
        self.serverID = serverID
        self.toolName = toolName
        self.startedAt = startedAt
        self.terminalAt = terminalAt
        self.effectivePolicy = effectivePolicy
        self.approvalRequested = approvalRequested
        self.approvalDecision = approvalDecision
        self.terminalOutcome = terminalOutcome
        self.summary = summary
        self.visibility = visibility
    }
}

public struct PluginPackageRecord: Codable, Equatable, Sendable {
    public let id: String
    public let version: String?
    public let sourceHash: String
    public let supportedComponentSummary: String
    public let enabled: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        version: String?,
        sourceHash: String,
        supportedComponentSummary: String,
        enabled: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.version = version
        self.sourceHash = sourceHash
        self.supportedComponentSummary = supportedComponentSummary
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PortableSkillRecord: Codable, Equatable, Sendable {
    public let id: String
    public let pluginID: String?
    public let name: String
    public let description: String
    public let markdownSnapshot: String
    public let sourceHash: String
    public let enabled: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        pluginID: String?,
        name: String,
        description: String,
        markdownSnapshot: String,
        sourceHash: String,
        enabled: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.pluginID = pluginID
        self.name = name
        self.description = description
        self.markdownSnapshot = markdownSnapshot
        self.sourceHash = sourceHash
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum CapabilityStorageError: Error, Equatable, Sendable {
    case invalidServer
    case serverNotFound
    case invalidSecretBinding
    case catalogTooLarge
    case descriptorServerMismatch
    case summaryTooLarge
    case schemaTooLarge
    case malformedSchema
    case toolNotFound
    case auditNotFound
    case invalidAudit
    case pluginSummaryTooLarge
    case skillMarkdownTooLarge
    case invalidRecord
}

public actor SQLiteCapabilityRepository {
    private let database: SQLiteDatabase
    private let simulatedWriteFailure: SQLiteError?
    private let simulatedReconcileFailure: SQLiteError?

    public init(path: String = SQLiteConversationRepository.defaultPath) throws {
        database = try SQLiteDatabase(path: path)
        simulatedWriteFailure = nil
        simulatedReconcileFailure = nil
    }

    init(path: String, simulatedWriteFailure: SQLiteError) throws {
        database = try SQLiteDatabase(path: path)
        self.simulatedWriteFailure = simulatedWriteFailure
        simulatedReconcileFailure = nil
    }

    init(path: String, simulatedReconcileFailure: SQLiteError) throws {
        database = try SQLiteDatabase(path: path)
        simulatedWriteFailure = nil
        self.simulatedReconcileFailure = simulatedReconcileFailure
    }

    public func saveServer(_ server: CapabilityServerRecord) throws {
        let argumentsJSON = try Self.validate(server: server)
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                INSERT INTO capability_servers
                    (id, display_name, transport, command, endpoint,
                     arguments_json, enabled, default_policy, stale_state,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    transport = excluded.transport,
                    command = excluded.command,
                    endpoint = excluded.endpoint,
                    arguments_json = excluded.arguments_json,
                    enabled = excluded.enabled,
                    default_policy = excluded.default_policy,
                    stale_state = excluded.stale_state,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(server.id), .text(server.displayName),
                    .text(server.transport.rawValue), Self.optional(server.command),
                    Self.optional(server.endpoint), .text(argumentsJSON),
                    .integer(server.enabled ? 1 : 0),
                    .text(server.defaultPolicy.rawValue),
                    .text(server.staleState.rawValue),
                    .text(Self.timestamp(server.createdAt)),
                    .text(Self.timestamp(server.updatedAt)),
                ]
            )
        }
    }

    public func server(id: String) throws -> CapabilityServerRecord? {
        try database.query(
            "\(Self.serverSelect) WHERE id = ?",
            bindings: [.text(id)]
        ).first.map(Self.decodeServer)
    }

    public func servers() throws -> [CapabilityServerRecord] {
        try database.query(
            "\(Self.serverSelect) ORDER BY created_at ASC, id ASC"
        ).map(Self.decodeServer)
    }

    public func deleteServer(id: String) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                "DELETE FROM capability_servers WHERE id = ?",
                bindings: [.text(id)]
            )
            guard database.changes == 1 else {
                throw CapabilityStorageError.serverNotFound
            }
        }
    }

    public func saveSecretBinding(_ binding: CapabilitySecretBinding) throws {
        guard !binding.name.isEmpty, binding.name.utf8.count <= 256 else {
            throw CapabilityStorageError.invalidSecretBinding
        }
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                INSERT INTO capability_secret_bindings
                    (id, server_id, binding_kind, binding_name, credential_ref)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    server_id = excluded.server_id,
                    binding_kind = excluded.binding_kind,
                    binding_name = excluded.binding_name,
                    credential_ref = excluded.credential_ref
                """,
                bindings: [
                    .text(Self.id(binding.id)), .text(binding.serverID),
                    .text(binding.kind.rawValue), .text(binding.name),
                    .text(Self.id(binding.credentialReference)),
                ]
            )
        }
    }

    public func secretBindings(
        serverID: String
    ) throws -> [CapabilitySecretBinding] {
        try database.query(
            """
            SELECT id, server_id, binding_kind, binding_name, credential_ref
            FROM capability_secret_bindings
            WHERE server_id = ?
            ORDER BY binding_kind ASC, binding_name ASC
            """,
            bindings: [.text(serverID)]
        ).map(Self.decodeSecretBinding)
    }

    public func setProviderEnabled(
        _ enabled: Bool,
        serverID: String,
        providerProfileID: UUID
    ) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                INSERT INTO provider_capability_settings
                    (server_id, provider_profile_id, enabled)
                VALUES (?, ?, ?)
                ON CONFLICT(server_id, provider_profile_id) DO UPDATE SET
                    enabled = excluded.enabled
                """,
                bindings: [
                    .text(serverID), .text(Self.id(providerProfileID)),
                    .integer(enabled ? 1 : 0),
                ]
            )
        }
    }

    public func enabledProviderProfileIDs(
        serverID: String
    ) throws -> [UUID] {
        try database.query(
            """
            SELECT provider_profile_id
            FROM provider_capability_settings
            WHERE server_id = ? AND enabled = 1
            ORDER BY provider_profile_id ASC
            """,
            bindings: [.text(serverID)]
        ).map { row in
            guard let value = row.first.flatMap(Self.uuid) else {
                throw CapabilityStorageError.invalidRecord
            }
            return value
        }
    }

    public func reconcileCatalog(
        serverID: String,
        descriptors: [CapabilityDescriptor],
        refreshedAt: Date = Date()
    ) throws {
        try Self.validateCatalog(descriptors, serverID: serverID)
        try preflightWrite()
        try database.transaction {
            guard try database.scalarInt(
                "SELECT COUNT(*) FROM capability_servers WHERE id = ?",
                bindings: [.text(serverID)]
            ) == 1 else {
                throw CapabilityStorageError.serverNotFound
            }
            try database.execute(
                """
                UPDATE capability_tools
                SET stale_state = 'stale', available = 0
                WHERE server_id = ?
                """,
                bindings: [.text(serverID)]
            )
            for (index, descriptor) in descriptors.enumerated() {
                try database.execute(
                    """
                    INSERT INTO capability_tools
                        (id, server_id, source, source_server_id, tool_name,
                         display_name, summary, input_schema_json, read_only_hint,
                         available, accessible, enabled, callable, visibility,
                         stale_state, content_hash, reconciled_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            'current', NULL, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        server_id = excluded.server_id,
                        source = excluded.source,
                        source_server_id = excluded.source_server_id,
                        tool_name = excluded.tool_name,
                        display_name = excluded.display_name,
                        summary = excluded.summary,
                        input_schema_json = excluded.input_schema_json,
                        read_only_hint = excluded.read_only_hint,
                        available = excluded.available,
                        accessible = excluded.accessible,
                        enabled = excluded.enabled,
                        callable = excluded.callable,
                        visibility = excluded.visibility,
                        stale_state = 'current',
                        reconciled_at = excluded.reconciled_at
                    """,
                    bindings: [
                        .text(descriptor.id.description), .text(serverID),
                        .text(descriptor.source.rawValue),
                        .text(descriptor.serverID), .text(descriptor.toolName),
                        .text(descriptor.displayName), .text(descriptor.summary),
                        .blob(descriptor.inputSchemaJSON),
                        descriptor.readOnlyHint.map { .integer($0 ? 1 : 0) } ?? .null,
                        .integer(descriptor.isAvailable ? 1 : 0),
                        .integer(descriptor.isAccessible ? 1 : 0),
                        .integer(descriptor.isEnabled ? 1 : 0),
                        .integer(descriptor.isCallable ? 1 : 0),
                        .text(descriptor.visibility.rawValue),
                        .text(Self.timestamp(refreshedAt)),
                    ]
                )
                if index == 0, let simulatedReconcileFailure {
                    throw simulatedReconcileFailure
                }
            }
            try database.execute(
                """
                UPDATE capability_servers
                SET stale_state = 'current', updated_at = ?
                WHERE id = ?
                """,
                bindings: [.text(Self.timestamp(refreshedAt)), .text(serverID)]
            )
        }
    }

    public func markCatalogStale(serverID: String) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                UPDATE capability_tools
                SET stale_state = 'stale', available = 0
                WHERE server_id = ?
                """,
                bindings: [.text(serverID)]
            )
            try database.execute(
                """
                UPDATE capability_servers
                SET stale_state = 'stale', updated_at = ?
                WHERE id = ?
                """,
                bindings: [.text(Self.timestamp()), .text(serverID)]
            )
            guard database.changes == 1 else {
                throw CapabilityStorageError.serverNotFound
            }
        }
    }

    public func catalog(serverID: String) throws -> [CapabilityToolRecord] {
        let providerIDs = Set(try enabledProviderProfileIDs(serverID: serverID))
        return try database.query(
            """
            SELECT t.id, t.source, t.source_server_id, t.tool_name,
                   t.display_name, t.summary, t.input_schema_json,
                   t.read_only_hint, t.available, t.accessible, t.enabled,
                   t.callable, t.visibility, t.stale_state,
                   o.policy, t.reconciled_at
            FROM capability_tools t
            LEFT JOIN capability_policy_overrides o ON o.tool_id = t.id
            WHERE t.server_id = ?
            ORDER BY t.tool_name ASC, t.id ASC
            """,
            bindings: [.text(serverID)]
        ).map { try Self.decodeTool($0, providerIDs: providerIDs) }
    }

    public func setPolicyOverride(
        _ policy: CapabilityPolicy?,
        toolID: CapabilityID
    ) throws {
        try preflightWrite()
        try database.transaction {
            guard try database.scalarInt(
                "SELECT COUNT(*) FROM capability_tools WHERE id = ?",
                bindings: [.text(toolID.description)]
            ) == 1 else {
                throw CapabilityStorageError.toolNotFound
            }
            if let policy {
                try database.execute(
                    """
                    INSERT INTO capability_policy_overrides(tool_id, policy, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(tool_id) DO UPDATE SET
                        policy = excluded.policy,
                        updated_at = excluded.updated_at
                    """,
                    bindings: [
                        .text(toolID.description), .text(policy.rawValue),
                        .text(Self.timestamp()),
                    ]
                )
            } else {
                try database.execute(
                    "DELETE FROM capability_policy_overrides WHERE tool_id = ?",
                    bindings: [.text(toolID.description)]
                )
            }
        }
    }

    public func beginAudit(_ audit: CapabilityAuditRecord) throws {
        guard audit.terminalAt == nil,
              audit.terminalOutcome == nil,
              audit.approvalDecision == nil,
              audit.conversationID != nil
                || audit.turnID != nil
                || audit.voiceSessionID != nil,
              audit.turnID == nil || audit.voiceSessionID == nil,
              !audit.serverID.isEmpty,
              !audit.toolName.isEmpty
        else {
            throw CapabilityStorageError.invalidAudit
        }
        try preflightWrite()
        try database.transaction {
            let conversationID = try coherentConversationID(for: audit)
            let normalized = CapabilityAuditRecord(
                id: audit.id,
                conversationID: conversationID,
                turnID: audit.turnID,
                voiceSessionID: audit.voiceSessionID,
                source: audit.source,
                serverID: audit.serverID,
                toolName: audit.toolName,
                startedAt: Self.date(Self.timestamp(audit.startedAt))
                    ?? audit.startedAt,
                terminalAt: nil,
                effectivePolicy: audit.effectivePolicy,
                approvalRequested: audit.approvalRequested,
                approvalDecision: nil,
                terminalOutcome: nil,
                summary: audit.summary,
                visibility: audit.visibility
            )
            if let existing = try self.audit(id: audit.id) {
                guard existing == normalized else {
                    throw CapabilityStorageError.invalidAudit
                }
                return
            }
            try database.execute(
                """
                INSERT INTO capability_audit
                    (id, conversation_id, turn_id, voice_session_id, source,
                     source_server_id, tool_name, started_at, terminal_at,
                     effective_policy, approval_requested, approval_decision,
                     terminal_outcome, sanitized_summary, visibility)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                bindings: Self.auditBindings(
                    normalized,
                    conversationID: conversationID
                )
            )
        }
    }

    public func terminalizeAudit(
        id: CapabilityCallID,
        outcome: CapabilityTerminalOutcome,
        approvalDecision: CapabilityApprovalDecision?,
        terminalAt: Date? = nil
    ) throws {
        try preflightWrite()
        try database.transaction {
            let rows = try database.query(
                """
                SELECT started_at, terminal_at, terminal_outcome,
                       approval_requested, approval_decision
                FROM capability_audit WHERE id = ?
                """,
                bindings: [.text(Self.id(id.rawValue))]
            )
            guard let row = rows.first,
                  let startedValue = Self.string(row[0]),
                  let startedAt = Self.date(startedValue),
                  let approvalRequested = Self.bool(row[3])
            else {
                throw CapabilityStorageError.auditNotFound
            }
            if let existingOutcomeValue = Self.string(row[2]),
               let existingOutcome = CapabilityTerminalOutcome(
                   rawValue: existingOutcomeValue
               ),
               let existingTerminalValue = Self.string(row[1]) {
                let existingDecision = Self.string(row[4]).flatMap(
                    CapabilityApprovalDecision.init(rawValue:)
                )
                guard existingOutcome == outcome,
                      existingDecision == approvalDecision
                else { throw CapabilityStorageError.invalidAudit }
                if let terminalAt {
                    guard existingTerminalValue == Self.timestamp(terminalAt)
                    else { throw CapabilityStorageError.invalidAudit }
                }
                return
            }
            let terminalValue = Self.timestamp(terminalAt ?? Date())
            guard let canonicalTerminalAt = Self.date(terminalValue),
                  canonicalTerminalAt >= startedAt,
                  Self.validTerminal(
                      outcome: outcome,
                      approvalRequested: approvalRequested,
                      decision: approvalDecision
                  )
            else { throw CapabilityStorageError.invalidAudit }
            try database.execute(
                """
                UPDATE capability_audit
                SET terminal_at = ?, terminal_outcome = ?, approval_decision = ?
                WHERE id = ? AND terminal_outcome IS NULL
                """,
                bindings: [
                    .text(terminalValue), .text(outcome.rawValue),
                    approvalDecision.map { .text($0.rawValue) } ?? .null,
                    .text(Self.id(id.rawValue)),
                ]
            )
        }
    }

    public func requireAuditApproval(
        id: CapabilityCallID,
        effectivePolicy: CapabilityPolicy
    ) throws {
        try preflightWrite()
        try database.transaction {
            let rows = try database.query(
                """
                SELECT effective_policy, approval_requested, terminal_outcome
                FROM capability_audit WHERE id = ?
                """,
                bindings: [.text(Self.id(id.rawValue))]
            )
            guard let row = rows.first,
                  let existingPolicy = Self.string(row[0]),
                  let approvalRequested = Self.bool(row[1]),
                  Self.string(row[2]) == nil
            else { throw CapabilityStorageError.invalidAudit }
            if approvalRequested {
                guard existingPolicy == effectivePolicy.rawValue
                else { throw CapabilityStorageError.invalidAudit }
                return
            }
            try database.execute(
                """
                UPDATE capability_audit
                SET effective_policy = ?, approval_requested = 1
                WHERE id = ? AND terminal_outcome IS NULL
                """,
                bindings: [
                    .text(effectivePolicy.rawValue),
                    .text(Self.id(id.rawValue)),
                ]
            )
        }
    }

    public func audit(id: CapabilityCallID) throws -> CapabilityAuditRecord? {
        try database.query(
            "\(Self.auditSelect) WHERE id = ?",
            bindings: [.text(Self.id(id.rawValue))]
        ).first.map(Self.decodeAudit)
    }

    public func audits() throws -> [CapabilityAuditRecord] {
        try database.query(
            "\(Self.auditSelect) ORDER BY started_at ASC, id ASC"
        ).map(Self.decodeAudit)
    }

    public func savePlugin(_ plugin: PluginPackageRecord) throws {
        guard plugin.supportedComponentSummary.utf8.count <= 4 * 1_024 else {
            throw CapabilityStorageError.pluginSummaryTooLarge
        }
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                INSERT INTO plugin_packages
                    (id, version, source_hash, supported_component_summary,
                     enabled, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    version = excluded.version,
                    source_hash = excluded.source_hash,
                    supported_component_summary = excluded.supported_component_summary,
                    enabled = excluded.enabled,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(plugin.id), Self.optional(plugin.version),
                    .text(plugin.sourceHash),
                    .text(plugin.supportedComponentSummary),
                    .integer(plugin.enabled ? 1 : 0),
                    .text(Self.timestamp(plugin.createdAt)),
                    .text(Self.timestamp(plugin.updatedAt)),
                ]
            )
        }
    }

    public func plugins() throws -> [PluginPackageRecord] {
        try database.query(
            """
            SELECT id, version, source_hash, supported_component_summary,
                   enabled, created_at, updated_at
            FROM plugin_packages
            ORDER BY created_at ASC, id ASC
            """
        ).map(Self.decodePlugin)
    }

    public func deletePlugin(id: String) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                "DELETE FROM plugin_packages WHERE id = ?",
                bindings: [.text(id)]
            )
        }
    }

    public func saveSkill(_ skill: PortableSkillRecord) throws {
        guard skill.markdownSnapshot.utf8.count <= 64 * 1_024 else {
            throw CapabilityStorageError.skillMarkdownTooLarge
        }
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                INSERT INTO portable_skills
                    (id, plugin_id, name, description, markdown_snapshot,
                     source_hash, enabled, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    plugin_id = excluded.plugin_id,
                    name = excluded.name,
                    description = excluded.description,
                    markdown_snapshot = excluded.markdown_snapshot,
                    source_hash = excluded.source_hash,
                    enabled = excluded.enabled,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(skill.id), Self.optional(skill.pluginID),
                    .text(skill.name), .text(skill.description),
                    .text(skill.markdownSnapshot), .text(skill.sourceHash),
                    .integer(skill.enabled ? 1 : 0),
                    .text(Self.timestamp(skill.createdAt)),
                    .text(Self.timestamp(skill.updatedAt)),
                ]
            )
        }
    }

    public func skills() throws -> [PortableSkillRecord] {
        try database.query(
            """
            SELECT id, plugin_id, name, description, markdown_snapshot,
                   source_hash, enabled, created_at, updated_at
            FROM portable_skills
            ORDER BY created_at ASC, id ASC
            """
        ).map(Self.decodeSkill)
    }

    public func deleteSkill(id: String) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                "DELETE FROM portable_skills WHERE id = ?",
                bindings: [.text(id)]
            )
        }
    }

    public func setSkillEnabled(
        _ enabled: Bool,
        skillID: String,
        providerProfileID: UUID
    ) throws {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                INSERT INTO provider_skill_settings
                    (skill_id, provider_profile_id, enabled)
                VALUES (?, ?, ?)
                ON CONFLICT(skill_id, provider_profile_id) DO UPDATE SET
                    enabled = excluded.enabled
                """,
                bindings: [
                    .text(skillID), .text(Self.id(providerProfileID)),
                    .integer(enabled ? 1 : 0),
                ]
            )
        }
    }

    public func enabledSkillProviderProfileIDs(
        skillID: String
    ) throws -> [UUID] {
        try database.query(
            """
            SELECT provider_profile_id
            FROM provider_skill_settings
            WHERE skill_id = ? AND enabled = 1
            ORDER BY provider_profile_id ASC
            """,
            bindings: [.text(skillID)]
        ).map { row in
            guard let value = row.first.flatMap(Self.uuid) else {
                throw CapabilityStorageError.invalidRecord
            }
            return value
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

    private func coherentConversationID(
        for audit: CapabilityAuditRecord
    ) throws -> ConversationID? {
        if let turnID = audit.turnID {
            let rows = try database.query(
                "SELECT conversation_id FROM turns WHERE id = ?",
                bindings: [.text(turnID.description)]
            )
            guard let value = rows.first?.first,
                  let parentID = Self.uuid(value).map({
                      ConversationID(rawValue: $0)
                  }),
                  audit.conversationID == nil
                    || audit.conversationID == parentID
            else {
                throw CapabilityStorageError.invalidAudit
            }
            return parentID
        }

        if let voiceSessionID = audit.voiceSessionID {
            let rows = try database.query(
                "SELECT conversation_id FROM voice_sessions WHERE id = ?",
                bindings: [.text(Self.id(voiceSessionID))]
            )
            guard let value = rows.first?.first else {
                throw CapabilityStorageError.invalidAudit
            }
            let parentID = Self.uuid(value).map {
                ConversationID(rawValue: $0)
            }
            guard audit.conversationID == parentID else {
                throw CapabilityStorageError.invalidAudit
            }
            return parentID
        }

        return audit.conversationID
    }

    private static func validTerminal(
        outcome: CapabilityTerminalOutcome,
        approvalRequested: Bool,
        decision: CapabilityApprovalDecision?
    ) -> Bool {
        guard decision == nil || approvalRequested else { return false }
        switch outcome {
        case .declined:
            return approvalRequested ? decision == .decline : decision == nil
        case .succeeded, .failed:
            return !approvalRequested || decision == .allowOnce
        case .cancelled, .timedOut:
            return decision != .decline
        }
    }

    private static func validate(server: CapabilityServerRecord) throws -> String {
        guard !server.id.isEmpty, server.id.utf8.count <= 128,
              server.id == server.id.lowercased(),
              server.id.unicodeScalars.allSatisfy({
                  (33...126).contains($0.value) && $0 != "/"
              }),
              !server.displayName.isEmpty, server.displayName.utf8.count <= 256
        else {
            throw CapabilityStorageError.invalidServer
        }
        switch server.transport {
        case .stdio:
            guard let command = server.command, !command.isEmpty,
                  server.endpoint == nil
            else { throw CapabilityStorageError.invalidServer }
        case .streamableHTTP:
            guard server.command == nil,
                  let endpoint = server.endpoint,
                  let components = URLComponents(string: endpoint),
                  components.scheme?.lowercased() == "https",
                  components.host != nil
            else { throw CapabilityStorageError.invalidServer }
        }
        let data = try JSONEncoder().encode(server.arguments)
        guard data.count <= 64 * 1_024,
              let json = String(data: data, encoding: .utf8)
        else { throw CapabilityStorageError.invalidServer }
        return json
    }

    private static func validateCatalog(
        _ descriptors: [CapabilityDescriptor],
        serverID: String
    ) throws {
        guard descriptors.count <= 2_048 else {
            throw CapabilityStorageError.catalogTooLarge
        }
        for descriptor in descriptors {
            guard descriptor.serverID == serverID else {
                throw CapabilityStorageError.descriptorServerMismatch
            }
            guard descriptor.summary.utf8.count <= 1_024 else {
                throw CapabilityStorageError.summaryTooLarge
            }
            guard descriptor.inputSchemaJSON.count <= 64 * 1_024 else {
                throw CapabilityStorageError.schemaTooLarge
            }
            guard let object = try? JSONSerialization.jsonObject(
                with: descriptor.inputSchemaJSON
            ), object is [String: Any] else {
                throw CapabilityStorageError.malformedSchema
            }
        }
    }

    private static func decodeServer(
        _ row: [SQLiteValue]
    ) throws -> CapabilityServerRecord {
        guard row.count == 11,
              let id = string(row[0]), let displayName = string(row[1]),
              let transportValue = string(row[2]),
              let transport = CapabilityServerTransport(rawValue: transportValue),
              let argumentsJSON = string(row[5]),
              let argumentsData = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String].self, from: argumentsData),
              let enabled = bool(row[6]),
              let policyValue = string(row[7]),
              let policy = CapabilityPolicy(rawValue: policyValue),
              let staleValue = string(row[8]),
              let stale = CapabilityCatalogStaleState(rawValue: staleValue),
              let createdValue = string(row[9]), let createdAt = date(createdValue),
              let updatedValue = string(row[10]), let updatedAt = date(updatedValue)
        else { throw CapabilityStorageError.invalidRecord }
        return CapabilityServerRecord(
            id: id, displayName: displayName, transport: transport,
            command: string(row[3]), endpoint: string(row[4]),
            arguments: arguments, enabled: enabled, defaultPolicy: policy,
            staleState: stale, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    private static func decodeSecretBinding(
        _ row: [SQLiteValue]
    ) throws -> CapabilitySecretBinding {
        guard row.count == 5, let id = uuid(row[0]),
              let serverID = string(row[1]), let kindValue = string(row[2]),
              let kind = CapabilitySecretBindingKind(rawValue: kindValue),
              let name = string(row[3]), let credential = uuid(row[4])
        else { throw CapabilityStorageError.invalidRecord }
        return CapabilitySecretBinding(
            id: id, serverID: serverID, kind: kind, name: name,
            credentialReference: credential
        )
    }

    private static func decodeTool(
        _ row: [SQLiteValue],
        providerIDs: Set<UUID>
    ) throws -> CapabilityToolRecord {
        guard row.count == 16, let idValue = string(row[0]),
              let id = try? CapabilityID(rawValue: idValue),
              let sourceValue = string(row[1]),
              let source = CapabilitySource(rawValue: sourceValue),
              let serverID = string(row[2]), let toolName = string(row[3]),
              let displayName = string(row[4]), let summary = string(row[5]),
              case let .blob(schema) = row[6], let available = bool(row[8]),
              let accessible = bool(row[9]), let enabled = bool(row[10]),
              let callable = bool(row[11]),
              let visibilityValue = string(row[12]),
              let visibility = CapabilityVisibility(rawValue: visibilityValue),
              let staleValue = string(row[13]),
              let stale = CapabilityCatalogStaleState(rawValue: staleValue),
              let reconciledValue = string(row[15]),
              let reconciledAt = date(reconciledValue)
        else { throw CapabilityStorageError.invalidRecord }
        let descriptor = try CapabilityDescriptor(
            id: id, source: source, serverID: serverID, toolName: toolName,
            displayName: displayName, summary: summary,
            inputSchemaJSON: schema, readOnlyHint: optionalBool(row[7]),
            providerProfileIDs: providerIDs, isAvailable: available,
            isAccessible: accessible, isEnabled: enabled,
            isCallable: callable, visibility: visibility
        )
        let override = string(row[14]).flatMap(CapabilityPolicy.init(rawValue:))
        return CapabilityToolRecord(
            descriptor: descriptor, staleState: stale,
            policyOverride: override, reconciledAt: reconciledAt
        )
    }

    private static func auditBindings(
        _ audit: CapabilityAuditRecord,
        conversationID: ConversationID?
    ) -> [SQLiteValue] {
        [
            .text(id(audit.id.rawValue)),
            conversationID.map { .text($0.description) } ?? .null,
            audit.turnID.map { .text($0.description) } ?? .null,
            audit.voiceSessionID.map { .text(id($0)) } ?? .null,
            .text(audit.source.rawValue), .text(audit.serverID),
            .text(audit.toolName), .text(timestamp(audit.startedAt)),
            audit.terminalAt.map { .text(timestamp($0)) } ?? .null,
            .text(audit.effectivePolicy.rawValue),
            .integer(audit.approvalRequested ? 1 : 0),
            audit.approvalDecision.map { .text($0.rawValue) } ?? .null,
            audit.terminalOutcome.map { .text($0.rawValue) } ?? .null,
            audit.summary.map { .text($0.text) } ?? .null,
            .text(audit.visibility.rawValue),
        ]
    }

    private static func decodeAudit(
        _ row: [SQLiteValue]
    ) throws -> CapabilityAuditRecord {
        guard row.count == 15, let id = uuid(row[0]),
              let sourceValue = string(row[4]),
              let source = CapabilitySource(rawValue: sourceValue),
              let serverID = string(row[5]), let toolName = string(row[6]),
              let startedValue = string(row[7]), let startedAt = date(startedValue),
              let policyValue = string(row[9]),
              let policy = CapabilityPolicy(rawValue: policyValue),
              let approvalRequested = bool(row[10]),
              let visibilityValue = string(row[14]),
              let visibility = CapabilityAuditVisibility(rawValue: visibilityValue)
        else { throw CapabilityStorageError.invalidRecord }
        let decision = string(row[11]).flatMap(CapabilityApprovalDecision.init(rawValue:))
        let outcome = string(row[12]).flatMap(CapabilityTerminalOutcome.init(rawValue:))
        return CapabilityAuditRecord(
            id: CapabilityCallID(rawValue: id),
            conversationID: uuid(row[1]).map(ConversationID.init(rawValue:)),
            turnID: uuid(row[2]).map(TurnID.init(rawValue:)),
            voiceSessionID: uuid(row[3]), source: source, serverID: serverID,
            toolName: toolName, startedAt: startedAt,
            terminalAt: string(row[8]).flatMap(date),
            effectivePolicy: policy, approvalRequested: approvalRequested,
            approvalDecision: decision, terminalOutcome: outcome,
            summary: string(row[13]).flatMap(
                SanitizedCapabilitySummary.init(persistedText:)
            ),
            visibility: visibility
        )
    }

    private static func decodePlugin(
        _ row: [SQLiteValue]
    ) throws -> PluginPackageRecord {
        guard row.count == 7, let id = string(row[0]),
              let sourceHash = string(row[2]), let summary = string(row[3]),
              let enabled = bool(row[4]), let createdValue = string(row[5]),
              let createdAt = date(createdValue), let updatedValue = string(row[6]),
              let updatedAt = date(updatedValue)
        else { throw CapabilityStorageError.invalidRecord }
        return PluginPackageRecord(
            id: id, version: string(row[1]), sourceHash: sourceHash,
            supportedComponentSummary: summary, enabled: enabled,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    private static func decodeSkill(
        _ row: [SQLiteValue]
    ) throws -> PortableSkillRecord {
        guard row.count == 9, let id = string(row[0]), let name = string(row[2]),
              let description = string(row[3]), let markdown = string(row[4]),
              let sourceHash = string(row[5]), let enabled = bool(row[6]),
              let createdValue = string(row[7]), let createdAt = date(createdValue),
              let updatedValue = string(row[8]), let updatedAt = date(updatedValue)
        else { throw CapabilityStorageError.invalidRecord }
        return PortableSkillRecord(
            id: id, pluginID: string(row[1]), name: name,
            description: description, markdownSnapshot: markdown,
            sourceHash: sourceHash, enabled: enabled,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    private static func id(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    private static func string(_ value: SQLiteValue) -> String? {
        guard case let .text(text) = value else { return nil }
        return text
    }

    private static func uuid(_ value: SQLiteValue) -> UUID? {
        string(value).flatMap(UUID.init(uuidString:))
    }

    private static func bool(_ value: SQLiteValue) -> Bool? {
        guard case let .integer(integer) = value, integer == 0 || integer == 1
        else { return nil }
        return integer == 1
    }

    private static func optionalBool(_ value: SQLiteValue) -> Bool? {
        value == .null ? nil : bool(value)
    }

    private static func optional(_ value: String?) -> SQLiteValue {
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

    private static let serverSelect = """
        SELECT id, display_name, transport, command, endpoint, arguments_json,
               enabled, default_policy, stale_state, created_at, updated_at
        FROM capability_servers
        """

    private static let auditSelect = """
        SELECT id, conversation_id, turn_id, voice_session_id, source,
               source_server_id, tool_name, started_at, terminal_at,
               effective_policy, approval_requested, approval_decision,
               terminal_outcome, sanitized_summary, visibility
        FROM capability_audit
        """
}

import Foundation
import MillerCapabilities
import MillerCore
import MillerStorage

enum MCPServerEditorError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidDisplayName
    case executableMustBeAbsolute
    case argumentsMustBeJSONArray
    case invalidHTTPSEndpoint
    case invalidSecret
}

enum MCPServerMutationMode: Equatable, Sendable {
    case create
    case edit(originalID: String)
}

struct MCPServerSecretDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: CapabilitySecretBindingKind
    var name: String
    var value: String
    var existingReference: UUID?

    init(
        id: UUID = UUID(),
        kind: CapabilitySecretBindingKind,
        name: String,
        value: String,
        existingReference: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.value = value
        self.existingReference = existingReference
    }
}

struct MCPServerEditorDraft: Equatable, Sendable {
    var id = ""
    var displayName = ""
    var transport: CapabilityServerTransport = .stdio
    var executable = ""
    var argumentsJSON = "[]"
    var endpoint = ""
    var enabled = false
    var defaultPolicy: CapabilityPolicy = .askBeforeChanges
    var providerProfileIDs = Set<UUID>()
    var secrets: [MCPServerSecretDraft] = []
    var createdAt = Date()

    static var newStdio: Self { .init() }

    static var newHTTPS: Self {
        var value = Self()
        value.transport = .streamableHTTP
        return value
    }

    func validated(
        mode: MCPServerMutationMode,
        now: Date = Date()
    ) throws -> MCPServerValidatedDraft {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedID.isEmpty, normalizedID.utf8.count <= 96,
              normalizedID.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && ((97...122).contains(scalar.value)
                      || (48...57).contains(scalar.value)
                      || scalar == "-" || scalar == "_")
              })
        else { throw MCPServerEditorError.invalidIdentity }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.utf8.count <= 128,
              !normalizedName.contains("\0")
        else { throw MCPServerEditorError.invalidDisplayName }

        let command: String?
        let normalizedEndpoint: String?
        let arguments: [String]
        switch transport {
        case .stdio:
            let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/"), !trimmed.contains("\0") else {
                throw MCPServerEditorError.executableMustBeAbsolute
            }
            arguments = try Self.decodeArguments(argumentsJSON)
            command = trimmed
            normalizedEndpoint = nil
        case .streamableHTTP:
            command = nil
            arguments = []
            normalizedEndpoint = try Self.normalizeHTTPS(endpoint)
        }

        var keys = Set<String>()
        let bindings = try secrets.map { secret -> CapabilitySecretBinding in
            let name = secret.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\0"),
                  secret.existingReference != nil || !secret.value.isEmpty
            else {
                throw MCPServerEditorError.invalidSecret
            }
            let key = "\(secret.kind.rawValue):\(name.lowercased())"
            guard keys.insert(key).inserted else {
                throw MCPServerEditorError.invalidSecret
            }
            let credentialReference = secret.existingReference ?? UUID()
            do {
                _ = try MCPSecretBinding(
                    destination: secret.kind == .environment ? .environment : .header,
                    name: name,
                    credentialReference: credentialReference
                )
            } catch {
                throw MCPServerEditorError.invalidSecret
            }
            return CapabilitySecretBinding(
                id: secret.id,
                serverID: normalizedID,
                kind: secret.kind,
                name: name,
                credentialReference: credentialReference
            )
        }
        return MCPServerValidatedDraft(
            mutationMode: mode,
            server: CapabilityServerRecord(
                id: normalizedID,
                displayName: normalizedName,
                transport: transport,
                command: command,
                endpoint: normalizedEndpoint,
                arguments: arguments,
                enabled: enabled,
                defaultPolicy: defaultPolicy,
                staleState: .stale,
                createdAt: createdAt,
                updatedAt: now
            ),
            providerProfileIDs: providerProfileIDs,
            secrets: bindings,
            secretValues: Dictionary(uniqueKeysWithValues: zip(secrets, bindings)
                .compactMap { draft, binding in
                    draft.value.isEmpty
                        ? nil : (binding.credentialReference, draft.value)
                }),
            newCredentialReferences: Set(
                zip(secrets, bindings).compactMap { draft, binding in
                    draft.existingReference == nil
                        ? binding.credentialReference : nil
                }
            )
        )
    }

    private static func decodeArguments(_ source: String) throws -> [String] {
        guard let data = source.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let arguments = value as? [String], arguments.count <= 256
        else { throw MCPServerEditorError.argumentsMustBeJSONArray }
        guard arguments.allSatisfy({ argument in
            argument.utf8.count <= 16 * 1_024 && !argument.contains("\0")
        }) else { throw MCPServerEditorError.argumentsMustBeJSONArray }
        return arguments
    }

    private static func normalizeHTTPS(_ source: String) throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil
        else { throw MCPServerEditorError.invalidHTTPSEndpoint }
        components.scheme = "https"
        components.host = host
        if components.port == 443 { components.port = nil }
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let normalized = components.url?.absoluteString else {
            throw MCPServerEditorError.invalidHTTPSEndpoint
        }
        return normalized
    }
}

struct MCPServerValidatedDraft: Equatable, Sendable {
    let mutationMode: MCPServerMutationMode
    let server: CapabilityServerRecord
    let providerProfileIDs: Set<UUID>
    let secrets: [CapabilitySecretBinding]
    let secretValues: [UUID: String]
    let newCredentialReferences: Set<UUID>
}

struct CapabilitySettingsTool: Identifiable, Equatable, Sendable {
    let id: CapabilityID
    let source: CapabilitySource
    let serverID: String
    let displayName: String
    let providerProfileIDs: Set<UUID>
    let readOnlyHint: Bool?
    let staleState: CapabilityCatalogStaleState
    let policyOverride: CapabilityPolicy?
    let providerNames: [UUID: String]
    var providerMandatedApproval = false

    init(
        record: CapabilityToolRecord,
        providerNames: [UUID: String],
        providerMandatedApproval: Bool = false
    ) {
        id = record.descriptor.id
        source = record.descriptor.source
        serverID = record.descriptor.serverID
        displayName = String(record.descriptor.displayName.prefix(128))
        providerProfileIDs = record.descriptor.providerProfileIDs
        readOnlyHint = record.descriptor.readOnlyHint
        staleState = record.staleState
        policyOverride = record.policyOverride
        self.providerNames = providerNames
        self.providerMandatedApproval = providerMandatedApproval
            || record.descriptor.visibility == .providerManaged
    }

    var providerAvailability: String {
        let names = providerProfileIDs.compactMap { providerNames[$0] }
            .sorted()
        return names.isEmpty ? "Unavailable to providers" : "Available to \(names.joined(separator: ", "))"
    }

    func effectivePolicy(serverPolicy: CapabilityPolicy) -> CapabilitySettingsPolicy {
        let resolution = CapabilityPolicyResolver().resolve(
            serverPolicy: serverPolicy,
            toolOverride: policyOverride,
            readOnlyHint: readOnlyHint,
            mandatoryProviderApproval: providerMandatedApproval
        )
        return CapabilitySettingsPolicy(
            value: resolution.effectivePolicy.value,
            requiresApproval: resolution.effectivePolicy.requiresApproval,
            note: providerMandatedApproval ? "Provider requires approval" : nil
        )
    }

    func with(policyOverride: CapabilityPolicy?) -> Self {
        Self(
            id: id,
            source: source,
            serverID: serverID,
            displayName: displayName,
            providerProfileIDs: providerProfileIDs,
            readOnlyHint: readOnlyHint,
            staleState: staleState,
            policyOverride: policyOverride,
            providerNames: providerNames,
            providerMandatedApproval: providerMandatedApproval
        )
    }

    func with(providerMandatedApproval: Bool) -> Self {
        Self(
            id: id,
            source: source,
            serverID: serverID,
            displayName: displayName,
            providerProfileIDs: providerProfileIDs,
            readOnlyHint: readOnlyHint,
            staleState: staleState,
            policyOverride: policyOverride,
            providerNames: providerNames,
            providerMandatedApproval: providerMandatedApproval
        )
    }

    private init(
        id: CapabilityID,
        source: CapabilitySource,
        serverID: String,
        displayName: String,
        providerProfileIDs: Set<UUID>,
        readOnlyHint: Bool?,
        staleState: CapabilityCatalogStaleState,
        policyOverride: CapabilityPolicy?,
        providerNames: [UUID: String],
        providerMandatedApproval: Bool
    ) {
        self.id = id
        self.source = source
        self.serverID = serverID
        self.displayName = displayName
        self.providerProfileIDs = providerProfileIDs
        self.readOnlyHint = readOnlyHint
        self.staleState = staleState
        self.policyOverride = policyOverride
        self.providerNames = providerNames
        self.providerMandatedApproval = providerMandatedApproval
    }
}

struct CapabilitySettingsPolicy: Equatable, Sendable {
    let value: CapabilityPolicy
    let requiresApproval: Bool
    let note: String?
}

struct CodexAccountAppSettings: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let tools: [CapabilitySettingsTool]
    let availabilityLabel = "Codex only"
}

struct MCPServerSettingsSnapshot: Identifiable, Equatable, Sendable {
    let server: CapabilityServerRecord
    let providerNames: [UUID: String]
    let tools: [CapabilitySettingsTool]
    let secretBindings: [CapabilitySecretBinding]
    var id: String { server.id }

    init(
        server: CapabilityServerRecord,
        providerNames: [UUID: String],
        tools: [CapabilitySettingsTool],
        secretBindings: [CapabilitySecretBinding] = []
    ) {
        self.server = server
        self.providerNames = providerNames
        self.tools = tools
        self.secretBindings = secretBindings
    }
}

struct CapabilitySettingsSnapshot: Equatable, Sendable {
    let codexApps: [CodexAccountAppSettings]
    let servers: [MCPServerSettingsSnapshot]
    let providerNames: [UUID: String]
    let plugins: [PluginPackageRecord]
    let skills: [PortableSkillSettingsSnapshot]

    init(
        codexApps: [CodexAccountAppSettings] = [],
        servers: [MCPServerSettingsSnapshot] = [],
        providerNames: [UUID: String] = [:],
        plugins: [PluginPackageRecord] = [],
        skills: [PortableSkillSettingsSnapshot] = []
    ) {
        self.codexApps = codexApps
        self.servers = servers
        self.providerNames = providerNames
        self.plugins = plugins
        self.skills = skills
    }

    static let empty = Self()
}

struct PortableSkillSettingsSnapshot: Identifiable, Equatable, Sendable {
    let record: PortableSkillRecord
    let enabledProviderProfileIDs: Set<UUID>
    var id: String { record.id }
}

struct MCPServerEditorDependencies: Sendable {
    let load: @Sendable () async throws -> CapabilitySettingsSnapshot
    let save: @Sendable (MCPServerValidatedDraft) async throws -> Void
    let remove: @Sendable (String) async throws -> Void
    let testConnection: @Sendable (String) async throws -> Int
    let setProviderEnabled: @Sendable (Bool, String, UUID) async throws -> Void
    let setServerPolicy: @Sendable (String, CapabilityPolicy) async throws -> Void
    let setToolPolicy: @Sendable (CapabilityID, CapabilityPolicy?) async throws -> Void
    let refresh: @Sendable () async throws -> CapabilitySettingsSnapshot
    let importSkill: @Sendable (URL) async throws -> Void
    let importPlugin: @Sendable (URL) async throws -> Void
    let setSkillEnabled: @Sendable (Bool, String, UUID) async throws -> Void
    let deleteSkill: @Sendable (String) async throws -> Void
    let deletePlugin: @Sendable (String) async throws -> Void

    init(
        load: @escaping @Sendable () async throws -> CapabilitySettingsSnapshot,
        save: @escaping @Sendable (MCPServerValidatedDraft) async throws -> Void,
        remove: @escaping @Sendable (String) async throws -> Void,
        testConnection: @escaping @Sendable (String) async throws -> Int,
        setProviderEnabled: @escaping @Sendable (Bool, String, UUID) async throws -> Void,
        setServerPolicy: @escaping @Sendable (String, CapabilityPolicy) async throws -> Void,
        setToolPolicy: @escaping @Sendable (CapabilityID, CapabilityPolicy?) async throws -> Void,
        refresh: @escaping @Sendable () async throws -> CapabilitySettingsSnapshot,
        importSkill: @escaping @Sendable (URL) async throws -> Void = { _ in },
        importPlugin: @escaping @Sendable (URL) async throws -> Void = { _ in },
        setSkillEnabled: @escaping @Sendable (Bool, String, UUID) async throws -> Void = { _, _, _ in },
        deleteSkill: @escaping @Sendable (String) async throws -> Void = { _ in },
        deletePlugin: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) {
        self.load = load
        self.save = save
        self.remove = remove
        self.testConnection = testConnection
        self.setProviderEnabled = setProviderEnabled
        self.setServerPolicy = setServerPolicy
        self.setToolPolicy = setToolPolicy
        self.refresh = refresh
        self.importSkill = importSkill
        self.importPlugin = importPlugin
        self.setSkillEnabled = setSkillEnabled
        self.deleteSkill = deleteSkill
        self.deletePlugin = deletePlugin
    }

    static let unavailable = Self(
        load: { .empty }, save: { _ in }, remove: { _ in },
        testConnection: { _ in 0 },
        setProviderEnabled: { _, _, _ in }, setServerPolicy: { _, _ in },
        setToolPolicy: { _, _ in }, refresh: { .empty },
        importSkill: { _ in }, importPlugin: { _ in },
        setSkillEnabled: { _, _, _ in }, deleteSkill: { _ in },
        deletePlugin: { _ in }
    )
}

@MainActor
final class MCPServerEditorModel: ObservableObject {
    @Published private(set) var snapshot: CapabilitySettingsSnapshot = .empty
    @Published private(set) var status = ""
    @Published private(set) var connectionStatus: [String: String] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var resetEpoch: UInt64 = 0

    private let dependencies: MCPServerEditorDependencies
    private var operationGeneration: UInt64 = 0

    init(dependencies: MCPServerEditorDependencies = .unavailable) {
        self.dependencies = dependencies
    }

    func load() async {
        await perform("Settings unavailable") { generation in
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
        }
    }

    func save(
        _ draft: MCPServerEditorDraft,
        mode: MCPServerMutationMode
    ) async {
        switch mode {
        case .create:
            clearConnectionStatus(serverID: draft.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case let .edit(originalID):
            clearConnectionStatus(serverID: originalID)
        }
        await perform("Server could not be saved") { generation in
            let validated = try draft.validated(mode: mode)
            try await dependencies.save(validated)
            guard isCurrent(generation) else { return }
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
            status = "Server saved"
        }
    }

    func remove(serverID: String) async {
        clearConnectionStatus(serverID: serverID)
        await perform("Server could not be removed") { generation in
            try await dependencies.remove(serverID)
            guard isCurrent(generation) else { return }
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
            status = "Server removed"
        }
    }

    func testConnection(serverID: String) async {
        clearConnectionStatus(serverID: serverID)
        await perform("Connection failed") { generation in
            let count = try await dependencies.testConnection(serverID)
            guard isCurrent(generation) else { return }
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
            guard let server = snapshot.servers.first(where: {
                $0.server.id == serverID
            })?.server,
            server.enabled, server.staleState == .current
            else {
                status = "Connection failed"
                return
            }
            connectionStatus[serverID] = "Connected — \(count) tools"
        }
    }

    func setProviderEnabled(_ enabled: Bool, serverID: String, providerID: UUID) async {
        await perform("Provider setting could not be saved") { generation in
            try await dependencies.setProviderEnabled(enabled, serverID, providerID)
            guard isCurrent(generation) else { return }
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
        }
    }

    func setServerPolicy(_ policy: CapabilityPolicy, serverID: String) async {
        await perform("Server policy could not be saved") { generation in
            try await dependencies.setServerPolicy(serverID, policy)
            guard isCurrent(generation) else { return }
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
        }
    }

    func setToolPolicy(_ policy: CapabilityPolicy?, toolID: CapabilityID) async {
        await perform("Tool policy could not be saved") { generation in
            try await dependencies.setToolPolicy(toolID, policy)
            guard isCurrent(generation) else { return }
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
        }
    }

    func refreshCatalogs() async {
        connectionStatus.removeAll()
        await perform("Catalog refresh failed; last catalog retained as stale") {
            generation in
            let refreshed = try await dependencies.refresh()
            guard isCurrent(generation) else { return }
            snapshot = refreshed
        }
    }

    func importSkill(at url: URL) async {
        await perform("Skill could not be imported") { generation in
            try await dependencies.importSkill(url)
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
            status = "Skill imported — review provider access before enabling"
        }
    }

    func importPlugin(at url: URL) async {
        await perform("Plugin bundle could not be imported") { generation in
            try await dependencies.importPlugin(url)
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
            status = "Plugin imported — review every component before enabling"
        }
    }

    func setSkillEnabled(
        _ enabled: Bool, skillID: String, providerID: UUID
    ) async {
        await perform("Skill setting could not be saved") { generation in
            try await dependencies.setSkillEnabled(enabled, skillID, providerID)
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
        }
    }

    func deleteSkill(id: String) async {
        await perform("Skill could not be removed") { generation in
            try await dependencies.deleteSkill(id)
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
            status = "Skill removed"
        }
    }

    func deletePlugin(id: String) async {
        await perform("Plugin could not be removed") { generation in
            try await dependencies.deletePlugin(id)
            let loaded = try await dependencies.load()
            guard isCurrent(generation) else { return }
            snapshot = loaded
            status = "Plugin removed"
        }
    }

    func clearAfterPrivacyReset() {
        operationGeneration &+= 1
        resetEpoch &+= 1
        snapshot = .empty
        status = ""
        connectionStatus.removeAll()
        isBusy = false
    }

    func clearConnectionStatus(serverID: String?) {
        guard let serverID else { return }
        connectionStatus[serverID] = nil
    }

    private func perform(
        _ failure: String,
        operation: (UInt64) async throws -> Void
    ) async {
        guard !isBusy else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        isBusy = true
        status = ""
        defer {
            if isCurrent(generation) {
                isBusy = false
            }
        }
        do {
            try await operation(generation)
        } catch {
            guard isCurrent(generation) else { return }
            status = failure
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration
    }
}

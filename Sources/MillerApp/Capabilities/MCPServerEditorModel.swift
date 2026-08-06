import Foundation
import MillerCore
import MillerStorage

enum MCPServerEditorError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidDisplayName
    case executableMustBeAbsolute
    case argumentsMustBeJSONArray
    case shellSyntaxNotAllowed
    case invalidHTTPSEndpoint
    case invalidSecret
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

    func validated(now: Date = Date()) throws -> MCPServerValidatedDraft {
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
            return CapabilitySecretBinding(
                id: secret.id,
                serverID: normalizedID,
                kind: secret.kind,
                name: name,
                credentialReference: secret.existingReference ?? UUID()
            )
        }
        return MCPServerValidatedDraft(
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
        let shellMarkers = ["&&", "||", ";", "`", "$(", "|", ">", "<"]
        guard arguments.allSatisfy({ argument in
            argument.utf8.count <= 16 * 1_024 && !argument.contains("\0")
                && !shellMarkers.contains(where: argument.contains)
        }) else { throw MCPServerEditorError.shellSyntaxNotAllowed }
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

    init(
        codexApps: [CodexAccountAppSettings] = [],
        servers: [MCPServerSettingsSnapshot] = [],
        providerNames: [UUID: String] = [:]
    ) {
        self.codexApps = codexApps
        self.servers = servers
        self.providerNames = providerNames
    }

    static let empty = Self()
}

struct MCPServerEditorDependencies: Sendable {
    let load: @Sendable () async throws -> CapabilitySettingsSnapshot
    let save: @Sendable (MCPServerValidatedDraft) async throws -> Void
    let remove: @Sendable (String) async throws -> Void
    let persistSecret: @Sendable (String, UUID, String) async throws -> Void
    let deleteSecret: @Sendable (UUID) async -> Void
    let testConnection: @Sendable (String) async throws -> Int
    let setProviderEnabled: @Sendable (Bool, String, UUID) async throws -> Void
    let setServerPolicy: @Sendable (String, CapabilityPolicy) async throws -> Void
    let setToolPolicy: @Sendable (CapabilityID, CapabilityPolicy?) async throws -> Void
    let refresh: @Sendable () async throws -> CapabilitySettingsSnapshot

    init(
        load: @escaping @Sendable () async throws -> CapabilitySettingsSnapshot,
        save: @escaping @Sendable (MCPServerValidatedDraft) async throws -> Void,
        remove: @escaping @Sendable (String) async throws -> Void,
        persistSecret: @escaping @Sendable (String, UUID, String) async throws -> Void,
        deleteSecret: @escaping @Sendable (UUID) async -> Void = { _ in },
        testConnection: @escaping @Sendable (String) async throws -> Int,
        setProviderEnabled: @escaping @Sendable (Bool, String, UUID) async throws -> Void,
        setServerPolicy: @escaping @Sendable (String, CapabilityPolicy) async throws -> Void,
        setToolPolicy: @escaping @Sendable (CapabilityID, CapabilityPolicy?) async throws -> Void,
        refresh: @escaping @Sendable () async throws -> CapabilitySettingsSnapshot
    ) {
        self.load = load
        self.save = save
        self.remove = remove
        self.persistSecret = persistSecret
        self.deleteSecret = deleteSecret
        self.testConnection = testConnection
        self.setProviderEnabled = setProviderEnabled
        self.setServerPolicy = setServerPolicy
        self.setToolPolicy = setToolPolicy
        self.refresh = refresh
    }

    static let unavailable = Self(
        load: { .empty }, save: { _ in }, remove: { _ in },
        persistSecret: { _, _, _ in }, testConnection: { _ in 0 },
        setProviderEnabled: { _, _, _ in }, setServerPolicy: { _, _ in },
        setToolPolicy: { _, _ in }, refresh: { .empty }
    )
}

@MainActor
final class MCPServerEditorModel: ObservableObject {
    @Published private(set) var snapshot: CapabilitySettingsSnapshot = .empty
    @Published private(set) var status = ""
    @Published private(set) var connectionStatus: [String: String] = [:]
    @Published private(set) var isBusy = false

    private let dependencies: MCPServerEditorDependencies

    init(dependencies: MCPServerEditorDependencies = .unavailable) {
        self.dependencies = dependencies
    }

    func load() async {
        await perform("Settings unavailable") { snapshot = try await dependencies.load() }
    }

    func save(_ draft: MCPServerEditorDraft) async {
        await perform("Server could not be saved") {
            let validated = try draft.validated()
            var written = Set<UUID>()
            do {
                for binding in validated.secrets {
                    guard let value = validated.secretValues[
                        binding.credentialReference
                    ] else { continue }
                    try await dependencies.persistSecret(
                        KeychainCredentialStore.service,
                        binding.credentialReference,
                        value
                    )
                    if validated.newCredentialReferences.contains(
                        binding.credentialReference
                    ) {
                        written.insert(binding.credentialReference)
                    }
                }
                try await dependencies.save(validated)
            } catch {
                for reference in written {
                    await dependencies.deleteSecret(reference)
                }
                throw error
            }
            snapshot = try await dependencies.load()
            status = "Server saved"
        }
    }

    func remove(serverID: String) async {
        await perform("Server could not be removed") {
            try await dependencies.remove(serverID)
            snapshot = try await dependencies.load()
            status = "Server removed"
        }
    }

    func testConnection(serverID: String) async {
        await perform("Connection failed") {
            let count = try await dependencies.testConnection(serverID)
            snapshot = try await dependencies.load()
            connectionStatus[serverID] = "Connected — \(count) tools"
        }
    }

    func setProviderEnabled(_ enabled: Bool, serverID: String, providerID: UUID) async {
        await perform("Provider setting could not be saved") {
            try await dependencies.setProviderEnabled(enabled, serverID, providerID)
            snapshot = try await dependencies.load()
        }
    }

    func setServerPolicy(_ policy: CapabilityPolicy, serverID: String) async {
        await perform("Server policy could not be saved") {
            try await dependencies.setServerPolicy(serverID, policy)
            snapshot = try await dependencies.load()
        }
    }

    func setToolPolicy(_ policy: CapabilityPolicy?, toolID: CapabilityID) async {
        await perform("Tool policy could not be saved") {
            try await dependencies.setToolPolicy(toolID, policy)
            snapshot = try await dependencies.load()
        }
    }

    func refreshCatalogs() async {
        await perform("Catalog refresh failed; last catalog retained as stale") {
            snapshot = try await dependencies.refresh()
        }
    }

    private func perform(
        _ failure: String,
        operation: () async throws -> Void
    ) async {
        guard !isBusy else { return }
        isBusy = true
        status = ""
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            status = failure
        }
    }
}

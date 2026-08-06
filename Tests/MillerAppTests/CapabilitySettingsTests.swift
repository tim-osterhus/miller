import Foundation
import MillerCore
import MillerStorage
import Testing
@testable import MillerApp

@Suite
struct CapabilitySettingsTests {
    @Test
    func projectsCodexAppsSeparatelyFromMillerServersWithAvailabilityLabels() throws {
        let provider = UUID()
        let codex = try settingsTool(
            source: .codexAccount,
            serverID: "gmail",
            toolName: "search",
            providers: [provider]
        )
        let miller = try settingsTool(
            source: .millerMCP,
            serverID: "notes",
            toolName: "lookup",
            providers: [provider]
        )
        let snapshot = CapabilitySettingsSnapshot(
            codexApps: [.init(id: "gmail", displayName: "Gmail", tools: [codex])],
            servers: [.init(
                server: settingsServer(id: "notes"),
                providerNames: [provider: "Codex"],
                tools: [miller]
            )]
        )

        #expect(snapshot.codexApps[0].availabilityLabel == "Codex only")
        #expect(snapshot.servers[0].tools[0].providerAvailability == "Available to Codex")
        #expect(snapshot.codexApps[0].tools[0].source == .codexAccount)
        #expect(snapshot.servers[0].tools[0].source == .millerMCP)
    }

    @Test
    func effectivePolicyShowsInheritanceOverridesAndProviderMandate() throws {
        let tool = try settingsTool(
            source: .millerMCP,
            serverID: "notes",
            toolName: "change",
            readOnly: false,
            override: nil
        )
        #expect(tool.effectivePolicy(serverPolicy: .askBeforeChanges).value == .askBeforeChanges)
        #expect(tool.effectivePolicy(serverPolicy: .fullyTrusted).value == .fullyTrusted)

        let overridden = tool.with(policyOverride: .fullyTrusted)
        #expect(overridden.effectivePolicy(serverPolicy: .askBeforeChanges).value == .fullyTrusted)

        let mandated = overridden.with(providerMandatedApproval: true)
        let resolution = mandated.effectivePolicy(serverPolicy: .fullyTrusted)
        #expect(resolution.requiresApproval)
        #expect(resolution.note == "Provider requires approval")
    }

    @Test
    func providerManagedDescriptorsCarryTruthfulApprovalMandates() throws {
        let tool = try settingsTool(
            source: .millerMCP,
            serverID: "managed",
            toolName: "change",
            readOnly: false,
            visibility: .providerManaged
        )

        let resolution = tool.effectivePolicy(serverPolicy: .fullyTrusted)

        #expect(tool.providerMandatedApproval)
        #expect(resolution.requiresApproval)
        #expect(resolution.note == "Provider requires approval")
    }

    @Test @MainActor
    func enablementPoliciesAndRefreshPreserveExplicitOverridesAndStaleCatalog() async throws {
        let recorder = CapabilitySettingsRecorder()
        let model = MCPServerEditorModel(dependencies: recorder.dependencies)
        await model.load()
        let toolID = try CapabilityID(source: .millerMCP, serverID: "notes", toolName: "lookup")

        await model.setProviderEnabled(true, serverID: "notes", providerID: recorder.provider)
        await model.setServerPolicy(.fullyTrusted, serverID: "notes")
        await model.setToolPolicy(.askBeforeChanges, toolID: toolID)
        await model.refreshCatalogs()

        #expect(await recorder.providerChanges.count == 1)
        #expect(await recorder.serverPolicies == ["notes": .fullyTrusted])
        #expect(await recorder.toolPolicies[toolID] == .askBeforeChanges)
        #expect(model.snapshot.servers[0].server.staleState == .stale)
        #expect(model.snapshot.servers[0].tools[0].policyOverride == .askBeforeChanges)
    }

    @Test
    func toolsSurfaceDoesNotCallExperimentalInstallAPIs() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/MillerApp/Presentation/Settings/ToolsIntegrationsSettingsTab.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("plugin/install"))
        #expect(!source.contains("plugin/uninstall"))
        #expect(!source.contains("dynamicTools"))
        #expect(source.contains("Codex only"))
    }

    @Test
    func diagnosticsExposeApprovedSanitizedFields() throws {
        let usage = ManagedStorageUsage(
            managedDataBytes: 123,
            managedCacheBytes: 0,
            dataCompleteness: .partial,
            cacheCompleteness: .unavailable
        )
        let snapshot = DiagnosticsSettingsSnapshot(
            componentVersions: ["Miller": "0.1.1"],
            sanitizedLastFailure: "provider_unavailable",
            catalogFreshness: "Stale",
            brokerProcessState: "Stopped",
            adapterProcessState: "Ready",
            managedDataBytes: usage.managedDataBytes,
            managedCacheBytes: usage.managedCacheBytes,
            managedDataLabel: usage.dataLabel(),
            managedCacheLabel: usage.cacheLabel()
        )
        #expect(snapshot.rows.map(\.label) == [
            "Miller version", "Last failure", "Catalog", "Capability controller",
            "Broker process", "Bridge RPC", "Adapter process",
            "MCP child sessions", "Managed data", "Managed cache",
        ])
        #expect(snapshot.rows.first(where: { $0.label == "Managed data" })?
            .value.hasSuffix("(partial)") == true)
        #expect(snapshot.rows.last?.value == "Unavailable")
    }

    @Test
    func diagnosticsComposeAppAndCapabilityFailuresDeterministically() {
        #expect(DiagnosticsSettingsSnapshot.composedFailure(
            appFailure: nil, capabilityFailure: nil
        ) == nil)
        #expect(DiagnosticsSettingsSnapshot.composedFailure(
            appFailure: "provider_unavailable", capabilityFailure: nil
        ) == "provider_unavailable")
        #expect(DiagnosticsSettingsSnapshot.composedFailure(
            appFailure: nil, capabilityFailure: "startup_failed"
        ) == "capability=startup_failed")
        #expect(DiagnosticsSettingsSnapshot.composedFailure(
            appFailure: "provider_unavailable",
            capabilityFailure: "adapter_unavailable"
        ) == "app=provider_unavailable;capability=adapter_unavailable")
        #expect(DiagnosticsSettingsSnapshot.composedFailure(
            appFailure: "private payload!", capabilityFailure: nil
        ) == "unknown_failure")
    }
}

private actor CapabilitySettingsRecorder {
    let provider = UUID()
    let toolID = try! CapabilityID(source: .millerMCP, serverID: "notes", toolName: "lookup")
    var providerChanges: [(Bool, String, UUID)] = []
    var serverPolicies: [String: CapabilityPolicy] = [:]
    var toolPolicies: [CapabilityID: CapabilityPolicy?] = [:]

    var initial: CapabilitySettingsSnapshot {
        get async {
            let tool = try! settingsTool(
                source: .millerMCP,
                serverID: "notes",
                toolName: "lookup",
                providers: [provider]
            )
            return .init(servers: [.init(
                server: settingsServer(id: "notes"),
                providerNames: [provider: "Codex"],
                tools: [tool]
            )])
        }
    }

    nonisolated var dependencies: MCPServerEditorDependencies {
        MCPServerEditorDependencies(
            load: { [self] in await initial },
            save: { _ in }, remove: { _ in },
            testConnection: { _ in 0 },
            setProviderEnabled: { [self] enabled, server, provider in
                await setProvider(enabled, server, provider)
            },
            setServerPolicy: { [self] server, policy in await setServer(server, policy) },
            setToolPolicy: { [self] tool, policy in await setTool(tool, policy) },
            refresh: { [self] in
                let current = await initial
                let changed = current.servers[0].tools[0].with(policyOverride: .askBeforeChanges)
                return .init(servers: [.init(
                    server: settingsServer(id: "notes", stale: .stale),
                    providerNames: [provider: "Codex"],
                    tools: [changed]
                )])
            }
        )
    }

    private func setProvider(_ enabled: Bool, _ server: String, _ provider: UUID) {
        providerChanges.append((enabled, server, provider))
    }
    private func setServer(_ server: String, _ policy: CapabilityPolicy) {
        serverPolicies[server] = policy
    }
    private func setTool(_ tool: CapabilityID, _ policy: CapabilityPolicy?) {
        toolPolicies[tool] = policy
    }
}

private func settingsServer(
    id: String,
    stale: CapabilityCatalogStaleState = .current
) -> CapabilityServerRecord {
    .init(
        id: id, displayName: id.capitalized, transport: .stdio,
        command: "/usr/bin/true", endpoint: nil, arguments: [], enabled: true,
        defaultPolicy: .askBeforeChanges, staleState: stale,
        createdAt: .distantPast, updatedAt: .distantPast
    )
}

private func settingsTool(
    source: CapabilitySource,
    serverID: String,
    toolName: String,
    providers: Set<UUID> = [],
    readOnly: Bool? = true,
    override: CapabilityPolicy? = nil,
    visibility: CapabilityVisibility = .ownerManaged
) throws -> CapabilitySettingsTool {
    let descriptor = try CapabilityDescriptor(
        id: CapabilityID(source: source, serverID: serverID, toolName: toolName),
        source: source, serverID: serverID, toolName: toolName,
        displayName: toolName.capitalized, summary: "Bounded summary",
        inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
        readOnlyHint: readOnly, providerProfileIDs: providers,
        isAvailable: true,
        visibility: visibility
    )
    return .init(
        record: .init(
            descriptor: descriptor, staleState: .current,
            policyOverride: override, reconciledAt: .distantPast
        ),
        providerNames: Dictionary(uniqueKeysWithValues: providers.map { ($0, "Codex") })
    )
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

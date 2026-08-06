import MillerCore
import MillerStorage
import SwiftUI

struct ToolsIntegrationsSettingsTab: View {
    let section = SettingsSection.toolsIntegrations
    @ObservedObject var editor: MCPServerEditorModel
    @State private var draft = MCPServerEditorDraft.newStdio
    @State private var showingEditor = false
    @State private var editingServerID: String?

    init(editor: MCPServerEditorModel = .init()) {
        self.editor = editor
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                codexAppsSection
                millerServersSection
                if showingEditor { serverEditor }
                if !editor.status.isEmpty {
                    Text(editor.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
        .task { await editor.load() }
        .onChange(of: editor.resetEpoch) { _, _ in
            dismissEditor()
        }
    }

    private var codexAppsSection: some View {
        GroupBox("Codex account apps") {
            VStack(alignment: .leading, spacing: 10) {
                if editor.snapshot.codexApps.isEmpty {
                    Text("No Codex account apps reported")
                        .foregroundStyle(.secondary)
                }
                ForEach(editor.snapshot.codexApps) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(app.displayName).fontWeight(.medium)
                            Spacer()
                            Text("Codex only").foregroundStyle(.secondary)
                        }
                        ForEach(app.tools) { tool in
                            HStack {
                                Text(tool.displayName).font(.caption)
                                if tool.providerMandatedApproval {
                                    Text("Provider approval required")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Text(
                    "Codex account apps are managed by Codex. Miller does not call "
                        + "under-development install or uninstall APIs."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var millerServersSection: some View {
        GroupBox("Miller MCP servers") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Add stdio server") {
                        draft = .newStdio
                        editingServerID = nil
                        showingEditor = true
                    }
                    Button("Add HTTPS server") {
                        draft = .newHTTPS
                        editingServerID = nil
                        showingEditor = true
                    }
                    Button("Refresh catalogs") {
                        Task { await editor.refreshCatalogs() }
                    }
                    .disabled(editor.isBusy)
                }
                ForEach(editor.snapshot.servers) { server in
                    serverRow(server)
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func serverRow(_ snapshot: MCPServerSettingsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.server.displayName).fontWeight(.medium)
                Text(snapshot.server.staleState == .stale ? "Catalog stale" : "Catalog current")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit") { edit(snapshot) }
                Button("Remove", role: .destructive) {
                    Task { await editor.remove(serverID: snapshot.server.id) }
                }
            }
            Picker(
                "Server policy",
                selection: Binding(
                    get: { snapshot.server.defaultPolicy },
                    set: { policy in
                        Task {
                            await editor.setServerPolicy(
                                policy, serverID: snapshot.server.id
                            )
                        }
                    }
                )
            ) {
                ForEach(CapabilityPolicy.allCases, id: \.self) { policy in
                    Text(policy.settingsLabel).tag(policy)
                }
            }
            .pickerStyle(.menu)
            ForEach(editor.snapshot.providerNames.keys.sorted(by: {
                editor.snapshot.providerNames[$0, default: ""]
                    < editor.snapshot.providerNames[$1, default: ""]
            }), id: \.self) { providerID in
                Toggle(
                    "Available to \(editor.snapshot.providerNames[providerID, default: "Provider"])",
                    isOn: Binding(
                        get: { snapshot.providerNames[providerID] != nil },
                        set: { enabled in
                            Task {
                                await editor.setProviderEnabled(
                                    enabled,
                                    serverID: snapshot.server.id,
                                    providerID: providerID
                                )
                            }
                        }
                    )
                )
            }
            ForEach(snapshot.tools) { tool in
                HStack {
                    VStack(alignment: .leading) {
                        Text(tool.displayName)
                        Text(tool.providerAvailability)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(
                        "Tool policy",
                        selection: Binding<CapabilityPolicy?>(
                            get: { tool.policyOverride },
                            set: { policy in
                                Task { await editor.setToolPolicy(policy, toolID: tool.id) }
                            }
                        )
                    ) {
                        Text("Inherit").tag(nil as CapabilityPolicy?)
                        ForEach(CapabilityPolicy.allCases, id: \.self) { policy in
                            Text(policy.settingsLabel).tag(policy as CapabilityPolicy?)
                        }
                    }
                    .pickerStyle(.menu)
                    let effective = tool.effectivePolicy(
                        serverPolicy: snapshot.server.defaultPolicy
                    )
                    Text("Effective: \(effective.value.settingsLabel)")
                        .font(.caption)
                    if let note = effective.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Test connection") {
                    Task { await editor.testConnection(serverID: snapshot.server.id) }
                }
                if let status = editor.connectionStatus[snapshot.server.id] {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var serverEditor: some View {
        GroupBox(editingServerID == nil ? "New MCP server" : "Edit MCP server") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Stable server ID", text: $draft.id)
                    .disabled(editingServerID != nil)
                TextField("Display name", text: $draft.displayName)
                Picker("Transport", selection: $draft.transport) {
                    Text("stdio").tag(CapabilityServerTransport.stdio)
                    Text("HTTPS").tag(CapabilityServerTransport.streamableHTTP)
                }
                .pickerStyle(.segmented)
                if draft.transport == .stdio {
                    TextField("Absolute executable path", text: $draft.executable)
                    TextField("Arguments JSON array", text: $draft.argumentsJSON)
                    Text("Arguments are stored and launched as a direct JSON argument array.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("HTTPS MCP endpoint", text: $draft.endpoint)
                }
                if draft.enabled {
                    Toggle("Enabled", isOn: $draft.enabled)
                    Text("After disabling a server, test its connection to enable it again.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Test the saved connection to enable this server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Default policy", selection: $draft.defaultPolicy) {
                    ForEach(CapabilityPolicy.allCases, id: \.self) { policy in
                        Text(policy.settingsLabel).tag(policy)
                    }
                }
                HStack {
                    Button("Add environment secret") {
                        draft.secrets.append(.init(
                            kind: .environment, name: "", value: ""
                        ))
                    }
                    Button("Add header secret") {
                        draft.secrets.append(.init(
                            kind: .header, name: "", value: ""
                        ))
                    }
                }
                ForEach($draft.secrets) { $secret in
                    HStack {
                        TextField("Binding name", text: $secret.name)
                        SecureField("Secret value", text: $secret.value)
                        Button("Remove secret", role: .destructive) {
                            let id = secret.id
                            draft.secrets.removeAll { $0.id == id }
                        }
                    }
                }
                Text(
                    "Secrets are stored only in the \(KeychainCredentialStore.service) "
                        + "Keychain service under generated references."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save server") {
                        let value = draft
                        let mode: MCPServerMutationMode = editingServerID.map {
                            .edit(originalID: $0)
                        } ?? .create
                        Task {
                            await editor.save(value, mode: mode)
                            if editor.status == "Server saved" {
                                dismissEditor()
                            }
                        }
                    }
                    .disabled(editor.isBusy)
                    Button("Cancel") {
                        dismissEditor()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func edit(_ snapshot: MCPServerSettingsSnapshot) {
        let server = snapshot.server
        editingServerID = server.id
        editor.clearConnectionStatus(serverID: server.id)
        draft = MCPServerEditorDraft(
            id: server.id,
            displayName: server.displayName,
            transport: server.transport,
            executable: server.command ?? "",
            argumentsJSON: (try? String(
                data: JSONSerialization.data(withJSONObject: server.arguments),
                encoding: .utf8
            )) ?? "[]",
            endpoint: server.endpoint ?? "",
            enabled: server.enabled,
            defaultPolicy: server.defaultPolicy,
            providerProfileIDs: Set(snapshot.providerNames.keys),
            secrets: snapshot.secretBindings.map { binding in
                MCPServerSecretDraft(
                    id: binding.id,
                    kind: binding.kind,
                    name: binding.name,
                    value: "",
                    existingReference: binding.credentialReference
                )
            },
            createdAt: server.createdAt
        )
        showingEditor = true
    }

    private func dismissEditor() {
        draft = .newStdio
        editingServerID = nil
        showingEditor = false
    }
}

private extension CapabilityPolicy {
    var settingsLabel: String {
        switch self {
        case .readOnlyAutomatic: "Read-only automatic"
        case .askBeforeChanges: "Ask before changes"
        case .fullyTrusted: "Fully trusted"
        }
    }
}

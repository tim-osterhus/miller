import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppPresentationModel
    @State private var keychainResult: String?
    @State private var providerLabel = ""
    @State private var providerEndpoint = ""
    @State private var providerModel = ""
    @State private var providerAPIKey = ""
    @State private var customCodexModel = ""
    @State private var advancedCodexModel = false
    @State private var editingProviderID: UUID?
    @State private var resetConfirmation = false
    @StateObject private var codexRuntime = CodexRuntimeSettingsModel()

    var body: some View {
        Form {
            Section("Activation") {
                Picker(
                    "Global shortcut",
                    selection: Binding(
                        get: { model.selectedShortcut },
                        set: { model.selectShortcut($0) }
                    )
                ) {
                    ForEach(GlobalShortcut.allCases) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                LabeledContent("Status") {
                    Text(model.shortcutAvailable ? "Ready" : "Unavailable")
                }
                if !model.shortcutAvailable {
                    Text("Open Miller remains available from the menu bar.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Capabilities") {
                LabeledContent("Typed conversation") { Text("Ready") }
                LabeledContent("Live voice") { Text(model.voiceStatusText) }
                LabeledContent("Avatar") { Text("Unavailable") }
            }

            Section("Codex Live Voice runtime") {
                LabeledContent("Status") { Text(codexRuntime.status) }
                if let path = codexRuntime.displayPath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose Codex…") { chooseCodexRuntime() }
                    Button("Use automatic detection") { codexRuntime.clear() }
                }
                .disabled(model.isActiveOperation)
                if codexRuntime.requiresRelaunch {
                    Text("Relaunch Miller to apply the runtime selection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "Miller uses an installed, OpenAI-signed Codex CLI for Live Voice. "
                        + "Miller does not install, update, or remove Codex."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Reasoning provider") {
                LabeledContent("Readiness") {
                    Text(model.providerStatus)
                }
                if let codex = model.providerProfiles.first(where: {
                    $0.kind == .codexOAuth && $0.isSelected
                }), !model.codexModels.isEmpty {
                    Picker(
                        "Codex model",
                        selection: Binding(
                            get: { codex.model },
                            set: { selected in
                                advancedCodexModel = false
                                Task { await model.selectCodexModel(selected) }
                            }
                        )
                    ) {
                        ForEach(model.codexModels, id: \.id) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                        if !model.codexModels.contains(where: { $0.id == codex.model }) {
                            Text(codex.model).tag(codex.model)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.isActiveOperation)
                    DisclosureGroup(
                        "Advanced custom model ID",
                        isExpanded: $advancedCodexModel
                    ) {
                        HStack {
                            Text("Model ID")
                            Spacer()
                            TextField(
                                "Custom Codex model ID",
                                text: $customCodexModel
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                            Button("Use custom model") {
                                let selected = customCodexModel
                                Task { await model.selectCodexModel(selected) }
                            }
                            .disabled(
                                model.isActiveOperation
                                    || customCodexModel.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                        }
                    }
                    .disabled(model.isActiveOperation)
                }
                ForEach(model.providerProfiles) { profile in
                    HStack {
                        Button {
                            Task { await model.selectProvider(profile.id) }
                        } label: {
                            HStack {
                                Text(profile.label)
                                Spacer()
                                if profile.isSelected {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button("Edit") {
                            editingProviderID = profile.id
                            providerLabel = profile.label
                            providerEndpoint = profile.endpoint ?? ""
                            providerModel = profile.model
                            providerAPIKey = ""
                            Task { await model.selectProvider(profile.id) }
                        }
                        .disabled(model.isActiveOperation || profile.kind != .openAICompatible)
                        Button("Delete", role: .destructive) {
                            Task { await model.deleteProvider(profile.id) }
                        }
                        .disabled(model.isActiveOperation)
                    }
                    .disabled(model.isActiveOperation)
                }
                HStack {
                    Button("Start Codex login") {
                        Task { await model.prepareCodexLogin() }
                    }
                    Button("Refresh Codex") {
                        Task { await model.refreshCodexAuthentication() }
                    }
                    Button("Retry helper readiness") {
                        Task { await model.retryProviderReadiness() }
                    }
                    Button("Local logout") {
                        Task { await model.localProviderLogout() }
                    }
                }
                .disabled(model.isActiveOperation)
                Text(
                    "Credentials are stored as generic passwords in the "
                        + "ai.millrace.miller.credentials Keychain service, "
                        + "under the profile's generated credential reference."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("OpenAI-compatible profile") {
                TextField("Label", text: $providerLabel)
                TextField("HTTPS endpoint", text: $providerEndpoint)
                TextField("Model", text: $providerModel)
                SecureField(
                    editingProviderID == nil ? "API key" : "New API key (optional)",
                    text: $providerAPIKey
                )
                Button(
                    editingProviderID == nil
                        ? "Save profile and credential"
                        : "Update profile"
                ) {
                    let apiKey = providerAPIKey
                    providerAPIKey = ""
                    Task {
                        await model.saveOpenAICompatibleProfile(
                            profileID: editingProviderID,
                            label: providerLabel,
                            endpoint: providerEndpoint,
                            model: providerModel,
                            apiKey: apiKey
                        )
                    }
                }
                .disabled(
                    model.isActiveOperation
                        || providerLabel.isEmpty
                        || providerEndpoint.isEmpty
                        || providerModel.isEmpty
                        || (editingProviderID == nil && providerAPIKey.isEmpty)
                )
                Text("The endpoint is normalized and refused before any Keychain write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if editingProviderID != nil {
                    Button("Create another profile") {
                        editingProviderID = nil
                        providerLabel = ""
                        providerEndpoint = ""
                        providerModel = ""
                        providerAPIKey = ""
                    }
                }
            }

            Section("Reset") {
                Button("Reset Miller…", role: .destructive) {
                    resetConfirmation = true
                }
                .disabled(model.isActiveOperation)
                ForEach(
                    Array(model.resetResults.enumerated()),
                    id: \.offset
                ) { _, result in
                    LabeledContent(result.root) {
                        Text(result.succeeded ? "Removed" : "Failed")
                    }
                }
            }

            Section("Keychain qualification") {
                Button("Run Keychain probe") {
                    do {
                        try KeychainProbe().run()
                        keychainResult = "Probe succeeded and cleaned up"
                    } catch {
                        keychainResult = "Probe failed"
                    }
                }
                if let keychainResult {
                    Text(keychainResult)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 480, minHeight: 360)
        .accessibilityLabel(AccessibilityLabel.settings)
        .confirmationDialog(
            "Reset Miller local data and credentials?",
            isPresented: $resetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Miller", role: .destructive) {
                Task { await model.resetMiller() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Miller will stop its helper and remove its managed database, "
                    + "cache, and Keychain items. This does not claim secure erasure."
            )
        }
    }

    private func chooseCodexRuntime() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose Codex"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try codexRuntime.choose(url)
        } catch {
            codexRuntime.reportSelectionFailure()
        }
    }
}

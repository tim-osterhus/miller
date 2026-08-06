import AppKit
import SwiftUI

struct ProvidersSettingsTab: View {
    let section = SettingsSection.providers
    @ObservedObject var model: AppPresentationModel
    @State private var providerLabel = ""
    @State private var providerEndpoint = ""
    @State private var providerModel = ""
    @State private var providerAPIKey = ""
    @State private var customCodexModel = ""
    @State private var advancedCodexModel = false
    @State private var editingProviderID: UUID?
    @StateObject private var codexRuntime = CodexRuntimeSettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                runtimeSection
                reasoningProviderSection
                compatibleProfileSection
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
    }

    private var runtimeSection: some View {
        GroupBox("Codex Live Voice runtime") {
            VStack(alignment: .leading, spacing: 10) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var reasoningProviderSection: some View {
        GroupBox("Reasoning provider") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Readiness") { Text(model.providerStatus) }
                codexModelPicker
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
                        Button("Edit") { edit(profile) }
                            .disabled(
                                model.isActiveOperation
                                    || profile.kind != .openAICompatible
                            )
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var codexModelPicker: some View {
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
                    TextField("Custom Codex model ID", text: $customCodexModel)
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
    }

    private var compatibleProfileSection: some View {
        GroupBox("OpenAI-compatible profile") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Label", text: $providerLabel)
                TextField("HTTPS endpoint", text: $providerEndpoint)
                TextField("Model", text: $providerModel)
                SecureField(
                    editingProviderID == nil ? "API key" : "New API key (optional)",
                    text: $providerAPIKey
                )
                Button(editingProviderID == nil ? "Save profile and credential" : "Update profile") {
                    saveProfile()
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
                    Button("Create another profile") { clearProfileDraft() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func edit(_ profile: ProviderSettingsProfile) {
        editingProviderID = profile.id
        providerLabel = profile.label
        providerEndpoint = profile.endpoint ?? ""
        providerModel = profile.model
        providerAPIKey = ""
        Task { await model.selectProvider(profile.id) }
    }

    private func saveProfile() {
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

    private func clearProfileDraft() {
        editingProviderID = nil
        providerLabel = ""
        providerEndpoint = ""
        providerModel = ""
        providerAPIKey = ""
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

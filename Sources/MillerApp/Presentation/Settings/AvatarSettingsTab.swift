import AppKit
import MillerAvatarCore
import MillerAvatarHost
import SwiftUI
import UniformTypeIdentifiers

struct AvatarSettingsTab: View {
    let section = SettingsSection.avatar
    @ObservedObject var model: AvatarSettingsModel
    @State private var renameDrafts: [UUID: String] = [:]

    init(model: AvatarSettingsModel = .init()) {
        self.model = model
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                enablementSection
                HStack {
                    Text(model.runtimeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.runtimeRetryAvailable {
                        Button("Retry Renderer") { model.retryRuntime() }
                    }
                }
                profileSection
                if let profile = model.selectedProfile {
                    paneWidthSection(profile)
                    motionLibrarySection(profile)
                    roleBindingsSection(profile)
                }
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
        .task { await model.load() }
    }

    private var enablementSection: some View {
        GroupBox("Avatar") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Enable Avatar",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { value in Task { _ = await model.setEnabled(value) } }
                    )
                )
                Toggle(
                    "Reduce Avatar Motion",
                    isOn: Binding(
                        get: { model.reduceMotion },
                        set: { value in Task { _ = await model.setReduceMotion(value) } }
                    )
                )
                Toggle(
                    "Enable Lip Sync",
                    isOn: Binding(
                        get: { model.mouthCuesEnabled },
                        set: { value in
                            Task { _ = await model.setMouthCuesEnabled(value) }
                        }
                    )
                )
                Text(
                    "Uses five-vowel lip sync when the selected model supports it, "
                        + "with basic mouth movement as a fallback."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    model.effectiveReducedMotion
                        ? "Reduced Motion is active for Avatar."
                        : "Avatar animation follows the selected profile."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var profileSection: some View {
        GroupBox("Model profile") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    "Selected profile",
                    selection: Binding<UUID?>(
                        get: { model.selectedProfileID },
                        set: { value in Task { _ = await model.selectProfile(value) } }
                    )
                ) {
                    Text("None").tag(nil as UUID?)
                    ForEach(model.profiles, id: \.id) { profile in
                        Text(profile.displayName).tag(Optional(profile.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(!model.isEnabled || model.isBusy)

                Picker(
                    "Import quality",
                    selection: Binding(
                        get: { model.importQualityMode },
                        set: { value in
                            model.setImportQualityMode(value)
                        }
                    )
                ) {
                    Text("Lightweight").tag(AvatarAssetQualityMode.lightweight)
                    Text("High Quality").tag(AvatarAssetQualityMode.highQuality)
                }
                .pickerStyle(.menu)
                .disabled(model.isBusy)

                if model.importQualityMode == .highQuality {
                    Text(
                        "High Quality permits substantially larger models and may use "
                            + "substantial memory, GPU memory, load time, and animation performance "
                            + "within finite safety ceilings."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button("Choose VRM 1.0 Model…") { chooseModel() }
                    .disabled(
                        !model.isEnabled
                            || model.isBusy
                            || model.isImportQualityPersistencePending
                    )

                ForEach(model.profiles, id: \.id) { profile in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(profile.displayName)
                            Text(Self.modelStatus(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Self.qualityLabel(profile.qualityMode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if profile.modelConsecutiveLoadFailures > 0 {
                                Button("Retry") {
                                    Task { _ = await model.retryProfile(id: profile.id) }
                                }
                            }
                            Button("Remove", role: .destructive) {
                                Task { _ = await model.removeProfile(id: profile.id) }
                            }
                        }
                        HStack {
                            TextField(
                                "Profile name",
                                text: Binding(
                                    get: {
                                        renameDrafts[profile.id, default: profile.displayName]
                                    },
                                    set: { renameDrafts[profile.id] = $0 }
                                )
                            )
                            Button("Rename") {
                                let name = renameDrafts[
                                    profile.id,
                                    default: profile.displayName
                                ]
                                Task {
                                    _ = await model.renameProfile(
                                        id: profile.id,
                                        displayName: name
                                    )
                                }
                            }
                            .disabled(model.isBusy)
                        }
                    }
                }
                Text(
                    "Miller stores Avatar metadata and security-scoped access only; "
                        + "the selected original model and motion files are not copied."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func motionLibrarySection(_ profile: AvatarProfileSummary) -> some View {
        GroupBox("Motion library") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Import VRMA 1.0 Motion…") {
                        chooseMotion(profileID: profile.id)
                    }
                    .disabled(!model.isEnabled || model.isBusy || profile.motions.count >= 32)
                    Text("\(profile.motions.count)/32")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(profile.motions, id: \.id) { motion in
                    motionRow(profileID: profile.id, motion: motion)
                }
                if profile.motions.isEmpty {
                    Text("No motions imported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func paneWidthSection(_ profile: AvatarProfileSummary) -> some View {
        GroupBox("Avatar surface") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Width")
                    Slider(
                        value: Binding(
                            get: { model.paneWidth(for: profile.id) },
                            set: { value in
                                Task { _ = await model.setPaneWidth(value, for: profile.id) }
                            }
                        ),
                        in: AvatarPaneWidth.minimum...AvatarPaneWidth.maximum,
                        step: 10
                    )
                    Text("\(Int(model.paneWidth(for: profile.id))) pt")
                        .monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                }
                Text("Controls the noninteractive Avatar surface width for this profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func motionRow(
        profileID: UUID,
        motion: AvatarMotionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(motion.displayName)
                    .fontWeight(.medium)
                Text(Self.motionStatus(motion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove", role: .destructive) {
                    Task {
                        _ = await model.removeMotion(
                            profileID: profileID,
                            motionID: motion.id
                        )
                    }
                }
                if motion.consecutiveLoadFailures > 0 || motion.lastFailure != nil {
                    Button("Retry") {
                        Task {
                            _ = await model.retryMotion(
                                profileID: profileID,
                                motionID: motion.id
                            )
                        }
                    }
                }
            }
            HStack {
                TextField(
                    "Motion name",
                    text: Binding(
                        get: { renameDrafts[motion.id, default: motion.displayName] },
                        set: { renameDrafts[motion.id] = $0 }
                    )
                )
                Button("Rename") {
                    let name = renameDrafts[motion.id, default: motion.displayName]
                    Task {
                        _ = await model.renameMotion(
                            profileID: profileID,
                            motionID: motion.id,
                            displayName: name
                        )
                    }
                }
                .disabled(model.isBusy)
            }
        }
    }

    private func roleBindingsSection(_ profile: AvatarProfileSummary) -> some View {
        GroupBox("Semantic motion roles") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AvatarMotionRole.allCases, id: \.rawValue) { role in
                    Picker(
                        Self.roleLabel(role),
                        selection: Binding<UUID?>(
                            get: { profile.motionBindings[role] },
                            set: { value in
                                Task {
                                    _ = await model.bindMotion(
                                        profileID: profile.id,
                                        role: role,
                                        motionID: value
                                    )
                                }
                            }
                        )
                    ) {
                        Text("Unbound").tag(nil as UUID?)
                        ForEach(profile.motions, id: \.id) { motion in
                            Text(motion.displayName).tag(Optional(motion.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!model.isEnabled || model.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func chooseModel() {
        guard let url = chooseFile(contentType: Self.modelType, prompt: "Choose Model")
        else { return }
        let name = url.deletingPathExtension().lastPathComponent
        Task { _ = await model.importModel(at: url, displayName: name) }
    }

    private func chooseMotion(profileID: UUID) {
        guard let url = chooseFile(contentType: Self.motionType, prompt: "Choose Motion")
        else { return }
        let name = url.deletingPathExtension().lastPathComponent
        Task {
            _ = await model.importMotion(
                profileID: profileID,
                at: url,
                displayName: name
            )
        }
    }

    private func chooseFile(contentType: UTType, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [contentType]
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static let modelType = UTType(filenameExtension: "vrm") ?? .data
    private static let motionType = UTType(filenameExtension: "vrma") ?? .data

    private static func modelStatus(_ profile: AvatarProfileSummary) -> String {
        if profile.modelConsecutiveLoadFailures > 0 {
            if profile.modelStatus == .quarantined { return "Quarantined" }
            return "Failed (\(profile.modelConsecutiveLoadFailures))"
        }
        return switch profile.modelStatus {
        case .available: "Available"
        case .quarantined: "Quarantined"
        }
    }

    private static func qualityLabel(_ mode: AvatarAssetQualityMode) -> String {
        switch mode {
        case .lightweight: "Lightweight"
        case .highQuality: "High Quality"
        }
    }

    private static func motionStatus(_ motion: AvatarMotionSummary) -> String {
        if motion.isQuarantined { return "Quarantined" }
        if let failure = motion.lastFailure { return failure.rawValue }
        if motion.consecutiveLoadFailures > 0 {
            return "Failed (\(motion.consecutiveLoadFailures))"
        }
        return "Ready"
    }

    private static func roleLabel(_ role: AvatarMotionRole) -> String {
        switch role {
        case .idle: "Idle"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .success: "Success"
        case .failure: "Failure"
        }
    }
}

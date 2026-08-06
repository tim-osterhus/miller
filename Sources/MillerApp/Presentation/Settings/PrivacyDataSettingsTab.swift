import AppKit
import Foundation
import SwiftUI

struct ManagedStorageUsage: Equatable, Sendable {
    let managedDataBytes: Int64
    let managedCacheBytes: Int64

    static let zero = Self(managedDataBytes: 0, managedCacheBytes: 0)

    static func measure(
        dataURLs: [URL],
        cacheURLs: [URL],
        fileManager: FileManager = .default
    ) -> Self {
        Self(
            managedDataBytes: dataURLs.reduce(0) {
                $0 + bytes(at: $1, fileManager: fileManager)
            },
            managedCacheBytes: cacheURLs.reduce(0) {
                $0 + bytes(at: $1, fileManager: fileManager)
            }
        )
    }

    private static func bytes(at url: URL, fileManager: FileManager) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys),
           values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if let values = try? child.resourceValues(forKeys: keys),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

struct PrivacyDataSettingsDependencies: Sendable {
    let loadTranscriptSavingEnabled: @Sendable () async throws -> Bool
    let loadNextSessionSavingEnabled: @Sendable () async throws -> Bool
    let setTranscriptSavingEnabled: @Sendable (Bool) async throws -> Void
    let setNextSessionSavingEnabled: @Sendable (Bool) async throws -> Void
    let exportVoiceHistory: @Sendable (URL) async throws -> Void
    let deleteVoiceHistory: @Sendable () async throws -> Void
    let deleteCapabilityAudit: @Sendable () async throws -> Void
    let storageUsage: @Sendable () async throws -> ManagedStorageUsage
    let reset: @Sendable () async -> ResetResult
    let resetWakePreferences: @Sendable () async throws -> Void

    static let unavailable = Self(
        loadTranscriptSavingEnabled: { true },
        loadNextSessionSavingEnabled: { true },
        setTranscriptSavingEnabled: { _ in },
        setNextSessionSavingEnabled: { _ in },
        exportVoiceHistory: { _ in },
        deleteVoiceHistory: {}, deleteCapabilityAudit: {},
        storageUsage: { .zero }, reset: { .init(roots: []) },
        resetWakePreferences: {}
    )
}

@MainActor
final class PrivacyDataSettingsModel: ObservableObject {
    @Published private(set) var transcriptSavingEnabled = true
    @Published private(set) var nextSessionSavingEnabled = true
    @Published private(set) var storageUsage = ManagedStorageUsage.zero
    @Published private(set) var resetResults: [ResetRootResult] = []
    @Published private(set) var status = ""
    @Published private(set) var isBusy = false

    private let dependencies: PrivacyDataSettingsDependencies

    init(dependencies: PrivacyDataSettingsDependencies = .unavailable) {
        self.dependencies = dependencies
    }

    func load() async {
        await perform("Privacy settings unavailable") {
            async let saving = dependencies.loadTranscriptSavingEnabled()
            async let next = dependencies.loadNextSessionSavingEnabled()
            async let usage = dependencies.storageUsage()
            transcriptSavingEnabled = try await saving
            nextSessionSavingEnabled = try await next
            storageUsage = try await usage
        }
    }

    func setTranscriptSavingEnabled(_ value: Bool) async {
        await perform("Transcript preference could not be saved") {
            try await dependencies.setTranscriptSavingEnabled(value)
            transcriptSavingEnabled = value
        }
    }

    func setNextSessionSavingEnabled(_ value: Bool) async {
        await perform("Next-session preference could not be saved") {
            try await dependencies.setNextSessionSavingEnabled(value)
            nextSessionSavingEnabled = value
        }
    }

    func exportVoiceHistory(to url: URL) async {
        await perform("Voice history export failed") {
            try await dependencies.exportVoiceHistory(url)
            status = "Voice history exported"
        }
    }

    func deleteVoiceHistory() async {
        await perform("Voice history deletion failed") {
            try await dependencies.deleteVoiceHistory()
            status = "Voice history deleted"
            storageUsage = try await dependencies.storageUsage()
        }
    }

    func deleteCapabilityAudit() async {
        await perform("Capability audit deletion failed") {
            try await dependencies.deleteCapabilityAudit()
            status = "Capability audit deleted"
            storageUsage = try await dependencies.storageUsage()
        }
    }

    func reset() async {
        guard !isBusy else { return }
        isBusy = true
        status = ""
        defer { isBusy = false }
        let result = await dependencies.reset()
        resetResults = result.roots
        guard result.failures.isEmpty else {
            status = "Reset incomplete; review Diagnostics."
            return
        }
        do {
            try await dependencies.resetWakePreferences()
            resetResults.append(.init(
                root: "preferences.wake.reset",
                succeeded: true
            ))
            transcriptSavingEnabled = true
            nextSessionSavingEnabled = true
            storageUsage = try await dependencies.storageUsage()
            status = "Reset completed; secure erasure is not claimed."
        } catch {
            resetResults.append(.init(
                root: "preferences.wake.reset",
                succeeded: false
            ))
            status = "Reset incomplete; review Diagnostics."
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
        do { try await operation() } catch { status = failure }
    }
}

struct PrivacyDataSettingsTab: View {
    let section = SettingsSection.privacyData
    @ObservedObject var model: AppPresentationModel
    @ObservedObject var privacy: PrivacyDataSettingsModel
    @State private var resetConfirmation = false
    @State private var voiceDeleteConfirmation = false
    @State private var auditDeleteConfirmation = false

    init(
        model: AppPresentationModel,
        privacy: PrivacyDataSettingsModel = .init()
    ) {
        self.model = model
        self.privacy = privacy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                transcriptSection
                retentionSection
                storageSection
                resetSection
                if !privacy.status.isEmpty {
                    Text(privacy.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
        .task { await privacy.load() }
        .confirmationDialog(
            "Delete all saved voice transcripts?",
            isPresented: $voiceDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete voice history", role: .destructive) {
                Task { await privacy.deleteVoiceHistory() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete the capability audit ledger?",
            isPresented: $auditDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete capability audit", role: .destructive) {
                Task { await privacy.deleteCapabilityAudit() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Reset Miller local data and credentials?",
            isPresented: $resetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Miller", role: .destructive) {
                Task { await privacy.reset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Miller will stop its helpers and remove its managed database, "
                    + "cache, Keychain items, capability records, saved transcripts, "
                    + "and wake preferences. This does not claim secure erasure."
            )
        }
    }

    private var transcriptSection: some View {
        GroupBox("Live Voice transcripts") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Save transcripts by default",
                    isOn: Binding(
                        get: { privacy.transcriptSavingEnabled },
                        set: { value in
                            Task { await privacy.setTranscriptSavingEnabled(value) }
                        }
                    )
                )
                Toggle(
                    "Save the next voice session",
                    isOn: Binding(
                        get: { privacy.nextSessionSavingEnabled },
                        set: { value in
                            Task { await privacy.setNextSessionSavingEnabled(value) }
                        }
                    )
                )
                Text("The next-session choice resets to the global default after use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var retentionSection: some View {
        GroupBox("Export and retention") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Export all voice history…") { exportVoiceHistory() }
                Button("Delete all voice history…", role: .destructive) {
                    voiceDeleteConfirmation = true
                }
                Button("Delete capability audit…", role: .destructive) {
                    auditDeleteConfirmation = true
                }
                Text("Exports contain transcript text, never audio or credentials.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var storageSection: some View {
        GroupBox("Managed storage") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Data") {
                    Text(ByteCountFormatter.string(
                        fromByteCount: privacy.storageUsage.managedDataBytes,
                        countStyle: .file
                    ))
                }
                LabeledContent("Cache") {
                    Text(ByteCountFormatter.string(
                        fromByteCount: privacy.storageUsage.managedCacheBytes,
                        countStyle: .file
                    ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var resetSection: some View {
        GroupBox("Reset") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Reset Miller…", role: .destructive) {
                    resetConfirmation = true
                }
                .disabled(model.isActiveOperation || privacy.isBusy)
                ForEach(Array(privacy.resetResults.enumerated()), id: \.offset) { _, result in
                    LabeledContent(result.root) {
                        Text(result.succeeded ? "Removed" : "Failed")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func exportVoiceHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Miller Voice History.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await privacy.exportVoiceHistory(to: url) }
    }
}

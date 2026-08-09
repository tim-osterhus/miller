import AppKit
import Foundation
import SwiftUI

struct ManagedStorageUsage: Equatable, Sendable {
    enum Completeness: Equatable, Sendable {
        case complete
        case partial
        case unavailable
    }

    let managedDataBytes: Int64
    let managedCacheBytes: Int64
    var dataCompleteness: Completeness = .complete
    var cacheCompleteness: Completeness = .complete

    static let zero = Self(
        managedDataBytes: 0,
        managedCacheBytes: 0,
        dataCompleteness: .unavailable,
        cacheCompleteness: .unavailable
    )

    static func measure(
        dataURLs: [URL],
        cacheURLs: [URL],
        fileManager: FileManager = .default
    ) -> Self {
        let data = measurement(at: dataURLs, fileManager: fileManager)
        let cache = measurement(at: cacheURLs, fileManager: fileManager)
        return Self(
            managedDataBytes: data.bytes,
            managedCacheBytes: cache.bytes,
            dataCompleteness: data.completeness,
            cacheCompleteness: cache.completeness
        )
    }

    func dataLabel() -> String {
        Self.label(bytes: managedDataBytes, completeness: dataCompleteness)
    }

    func cacheLabel() -> String {
        Self.label(bytes: managedCacheBytes, completeness: cacheCompleteness)
    }

    private static func measurement(
        at urls: [URL],
        fileManager: FileManager
    ) -> (bytes: Int64, completeness: Completeness) {
        var total: Int64 = 0
        var measuredAnyRoot = false
        var encounteredError = false
        for url in urls {
            let value = measurement(at: url, fileManager: fileManager)
            total += value.bytes
            measuredAnyRoot = measuredAnyRoot || value.measured
            if value.completeness != .complete {
                encounteredError = true
            }
        }
        let completeness: Completeness
        if !encounteredError {
            completeness = .complete
        } else {
            completeness = measuredAnyRoot ? .partial : .unavailable
        }
        return (total, completeness)
    }

    private static func measurement(
        at url: URL,
        fileManager: FileManager
    ) -> (bytes: Int64, completeness: Completeness, measured: Bool) {
        let rootAttributes: [FileAttributeKey: Any]
        do {
            rootAttributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            return Self.fileIsAbsent(error)
                ? (0, .complete, true)
                : (0, .unavailable, false)
        }
        if rootAttributes[.type] as? FileAttributeType == .typeRegular {
            guard let size = rootAttributes[.size] as? NSNumber else {
                return (0, .partial, true)
            }
            return (size.int64Value, .complete, true)
        }
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            return (0, .complete, true)
        }
        var encounteredError = false
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                encounteredError = true
                return true
            }
        ) else { return (0, .unavailable, false) }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            do {
                let attributes = try fileManager.attributesOfItem(
                    atPath: child.path
                )
                if attributes[.type] as? FileAttributeType == .typeRegular {
                    guard let size = attributes[.size] as? NSNumber else {
                        encounteredError = true
                        continue
                    }
                    total += size.int64Value
                }
            } catch {
                encounteredError = true
            }
        }
        return (
            total,
            encounteredError ? .partial : .complete,
            true
        )
    }

    private static func fileIsAbsent(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == CocoaError.Code.fileNoSuchFile.rawValue
            || error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }

    private static func label(bytes: Int64, completeness: Completeness) -> String {
        switch completeness {
        case .complete:
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .partial:
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                + " (partial)"
        case .unavailable:
            "Unavailable"
        }
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
        var wakeResetSucceeded = false
        do {
            try await dependencies.resetWakePreferences()
            wakeResetSucceeded = true
        } catch {
        }
        let result = await dependencies.reset()
        resetResults = result.roots
        resetResults.append(.init(
            root: "preferences.wake.reset",
            succeeded: wakeResetSucceeded
        ))
        guard result.failures.isEmpty, wakeResetSucceeded else {
            status = "Reset incomplete; review Diagnostics."
            return
        }
        do {
            transcriptSavingEnabled = true
            nextSessionSavingEnabled = true
            storageUsage = try await dependencies.storageUsage()
            status = "Reset completed; secure erasure is not claimed."
        } catch {
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
                .disabled(model.isActiveOperation || privacy.isBusy)
                Button("Delete capability audit…", role: .destructive) {
                    auditDeleteConfirmation = true
                }
                .disabled(model.isActiveOperation || privacy.isBusy)
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
                    Text(privacy.storageUsage.dataLabel())
                }
                LabeledContent("Cache") {
                    Text(privacy.storageUsage.cacheLabel())
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

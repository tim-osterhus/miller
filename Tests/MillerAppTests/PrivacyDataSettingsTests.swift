import Foundation
import Testing
@testable import MillerApp

@Suite
struct PrivacyDataSettingsTests {
    @Test
    func managedStorageUsageIncludesHiddenFilesInsideOwnedRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-storage-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 3).write(
            to: root.appendingPathComponent("visible")
        )
        try Data(repeating: 2, count: 5).write(
            to: root.appendingPathComponent(".hidden")
        )

        let usage = ManagedStorageUsage.measure(dataURLs: [root], cacheURLs: [])

        #expect(usage.managedDataBytes == 8)
    }

    @Test
    func managedSQLiteUsageIncludesMainWALAndSharedMemoryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-sqlite-usage-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let database = root.appendingPathComponent("miller.sqlite3")
        let urls = [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm"),
        ]
        for (index, url) in urls.enumerated() {
            try Data(repeating: UInt8(index), count: index + 2).write(to: url)
        }

        let usage = ManagedStorageUsage.measure(dataURLs: urls, cacheURLs: [])

        #expect(usage.managedDataBytes == 9)
        #expect(usage.dataCompleteness == .complete)
    }

    @Test
    func missingStorageRootIsCompleteZeroButMetadataFailureIsUnavailable() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-missing-storage-\(UUID().uuidString)"
        )
        let absent = ManagedStorageUsage.measure(
            dataURLs: [missing], cacheURLs: []
        )
        #expect(absent.managedDataBytes == 0)
        #expect(absent.dataCompleteness == .complete)

        let unavailable = ManagedStorageUsage.measure(
            dataURLs: [missing], cacheURLs: [],
            fileManager: MetadataFailureFileManager(failing: [missing])
        )
        #expect(unavailable.dataCompleteness == .unavailable)
        #expect(unavailable.dataLabel() == "Unavailable")
    }

    @Test
    func successfulZeroByteRootPlusMetadataFailureIsPartial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-zero-storage-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let measured = root.appendingPathComponent("measured")
        try Data().write(to: measured)
        let inaccessible = root.appendingPathComponent("inaccessible")

        let usage = ManagedStorageUsage.measure(
            dataURLs: [measured, inaccessible], cacheURLs: [],
            fileManager: MetadataFailureFileManager(failing: [inaccessible])
        )

        #expect(usage.managedDataBytes == 0)
        #expect(usage.dataCompleteness == .partial)
        #expect(usage.dataLabel().hasSuffix("(partial)"))
    }

    @Test
    func childMetadataFailureRetainsKnownBytesAsPartial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-partial-storage-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let measured = root.appendingPathComponent("measured")
        let inaccessible = root.appendingPathComponent("inaccessible")
        try Data(repeating: 1, count: 3).write(to: measured)
        try Data(repeating: 2, count: 5).write(to: inaccessible)

        let usage = ManagedStorageUsage.measure(
            dataURLs: [root], cacheURLs: [],
            fileManager: MetadataFailureFileManager(failing: [inaccessible])
        )

        #expect(usage.managedDataBytes == 3)
        #expect(usage.dataCompleteness == .partial)
        #expect(usage.dataLabel().hasSuffix("(partial)"))
    }

    @Test @MainActor
    func transcriptSavingDefaultsOnAndNextSessionOverrideIsExplicit() async {
        let recorder = PrivacySettingsRecorder()
        let model = PrivacyDataSettingsModel(dependencies: recorder.dependencies)
        await model.load()

        #expect(model.transcriptSavingEnabled)
        #expect(model.nextSessionSavingEnabled)

        await model.setNextSessionSavingEnabled(false)
        #expect(!model.nextSessionSavingEnabled)
        #expect(await recorder.nextSessionValues == [false])
    }

    @Test @MainActor
    func exportAndDeletionActionsDelegateWithoutRetainingContent() async {
        let recorder = PrivacySettingsRecorder()
        let model = PrivacyDataSettingsModel(dependencies: recorder.dependencies)
        let destination = URL(fileURLWithPath: "/tmp/miller-voice-export.json")

        await model.exportVoiceHistory(to: destination)
        await model.deleteVoiceHistory()
        await model.deleteCapabilityAudit()

        #expect(await recorder.exportDestinations == [destination])
        #expect(await recorder.voiceDeletes == 1)
        #expect(await recorder.auditDeletes == 1)
    }

    @Test @MainActor
    func storageUsageUsesByteCountsAndResetIncludesNewRecordsAndWakePreferences() async {
        let recorder = PrivacySettingsRecorder()
        let model = PrivacyDataSettingsModel(dependencies: recorder.dependencies)
        await model.load()

        #expect(model.storageUsage == .init(managedDataBytes: 1_024, managedCacheBytes: 2_048))
        await model.reset()

        #expect(await recorder.resets == 1)
        #expect(await recorder.wakePreferenceResets == 1)
        #expect(model.resetResults == [
            .init(root: "managed", succeeded: true),
            .init(root: "preferences.wake.reset", succeeded: true),
        ])
        #expect(model.status == "Reset completed; secure erasure is not claimed.")
    }

    @Test @MainActor
    func resetReportsIncompleteWhenAManagedRootFails() async {
        let recorder = PrivacySettingsRecorder(resetSucceeds: false)
        let model = PrivacyDataSettingsModel(dependencies: recorder.dependencies)

        await model.reset()

        #expect(model.status == "Reset incomplete; review Diagnostics.")
        #expect(model.resetResults == [
            .init(root: "managed", succeeded: false),
        ])
        #expect(await recorder.wakePreferenceResets == 0)
    }


    @Test @MainActor
    func wakePreferenceFailureAppearsAsAVisibleResetRoot() async {
        let recorder = PrivacySettingsRecorder(wakeResetSucceeds: false)
        let model = PrivacyDataSettingsModel(dependencies: recorder.dependencies)

        await model.reset()

        #expect(model.status == "Reset incomplete; review Diagnostics.")
        #expect(model.resetResults == [
            .init(root: "managed", succeeded: true),
            .init(root: "preferences.wake.reset", succeeded: false),
        ])
    }
}

private final class MetadataFailureFileManager: FileManager, @unchecked Sendable {
    private let failingPaths: Set<String>

    init(failing urls: [URL]) {
        failingPaths = Set(urls.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        })
        super.init()
    }

    override func attributesOfItem(
        atPath path: String
    ) throws -> [FileAttributeKey: Any] {
        let canonicalPath = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath().standardizedFileURL.path
        if failingPaths.contains(canonicalPath) {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.attributesOfItem(atPath: path)
    }
}

private actor PrivacySettingsRecorder {
    var nextSessionValues: [Bool] = []
    var exportDestinations: [URL] = []
    var voiceDeletes = 0
    var auditDeletes = 0
    var resets = 0
    var wakePreferenceResets = 0
    let resetSucceeds: Bool
    let wakeResetSucceeds: Bool

    init(resetSucceeds: Bool = true, wakeResetSucceeds: Bool = true) {
        self.resetSucceeds = resetSucceeds
        self.wakeResetSucceeds = wakeResetSucceeds
    }

    nonisolated var dependencies: PrivacyDataSettingsDependencies {
        .init(
            loadTranscriptSavingEnabled: { true },
            loadNextSessionSavingEnabled: { true },
            setTranscriptSavingEnabled: { _ in },
            setNextSessionSavingEnabled: { [self] value in await appendNext(value) },
            exportVoiceHistory: { [self] url in await appendExport(url) },
            deleteVoiceHistory: { [self] in await deleteVoice() },
            deleteCapabilityAudit: { [self] in await deleteAudit() },
            storageUsage: { .init(managedDataBytes: 1_024, managedCacheBytes: 2_048) },
            reset: { [self] in await resetAll() },
            resetWakePreferences: { [self] in try await resetWake() }
        )
    }

    private func appendNext(_ value: Bool) { nextSessionValues.append(value) }
    private func appendExport(_ value: URL) { exportDestinations.append(value) }
    private func deleteVoice() { voiceDeletes += 1 }
    private func deleteAudit() { auditDeletes += 1 }
    private func resetAll() -> ResetResult {
        resets += 1
        return .init(roots: [
            .init(root: "managed", succeeded: resetSucceeds),
        ])
    }
    private func resetWake() throws {
        wakePreferenceResets += 1
        if !wakeResetSucceeds { throw CocoaError(.fileWriteUnknown) }
    }
}

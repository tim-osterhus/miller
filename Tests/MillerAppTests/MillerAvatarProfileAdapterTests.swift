import Foundation
import MillerAvatarCore
import MillerAvatarHost
import Testing
@testable import MillerApp

@Suite
struct MillerAvatarProfileAdapterTests {
    @Test
    func packageBackedAdapterMigratesV1AndRelaunchesFromV2() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        try JSONEncoder().encode(
            LegacyProfileEnvelopeFixture(profiles: [
                LegacyProfileFixture(
                    id: profileID,
                    displayName: "Legacy",
                    modelBookmark: Data([1]),
                    modelSHA256: String(repeating: "a", count: 64)
                ),
            ])
        ).write(to: root.appendingPathComponent("profiles-v1.json"))

        let firstLaunch = MillerAvatarProfileAdapter(root: root)
        let migrated = try await firstLaunch.list()
        #expect(migrated.map(\.id) == [profileID])
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("profiles-v2.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("profiles-v1.json").path
        ))

        let relaunched = MillerAvatarProfileAdapter(root: root)
        #expect(try await relaunched.list() == migrated)
    }

    @Test
    func packageBackedAdapterListsWithoutStartingRendererOrMicrophone() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerAvatarProfileAdapter(root: root)

        #expect(try await adapter.list().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("profiles-v2.json").path
        ))
        let adapterSource = try String(
            contentsOf: sourceURL(
                relativePath: "Sources/MillerApp/Avatar/MillerAvatarProfileAdapter.swift"
            ),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: sourceURL(
                relativePath: "Sources/MillerApp/Avatar/AvatarSettingsModel.swift"
            ),
            encoding: .utf8
        )
        let source = adapterSource + modelSource
        #expect(!source.contains("AvatarSurfaceController"))
        #expect(!source.contains("Microphone"))
        #expect(!source.contains("WakeWord"))
    }

    @Test
    func packageBackedAdapterImportsSyntheticModelAndPreservesOriginalFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("selected.vrm")
        let original = try minimalVRM()
        try original.write(to: source)

        let adapter = MillerAvatarProfileAdapter(
            root: root.appendingPathComponent("metadata", isDirectory: true)
        )
        let change = try await adapter.importModel(at: source, displayName: "Synthetic")
        let profile = try await adapter.profile(id: change.profileID)

        #expect(change.profileRevision == profile.profileRevision)
        #expect(profile.modelCapturedByteCount == UInt64(original.count))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test
    func packageBackedAdapterRejectsUnsafeModelWithoutCreatingMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rejected.vrm")
        let original = Data("not a VRM".utf8)
        try original.write(to: source)
        let metadata = root.appendingPathComponent("metadata", isDirectory: true)
        let adapter = MillerAvatarProfileAdapter(root: metadata)

        await #expect(throws: AvatarProfileStoreError.assetRejected) {
            _ = try await adapter.importModel(at: source, displayName: "Rejected")
        }

        #expect(try await adapter.list().isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(
            atPath: metadata.appendingPathComponent("profiles-v2.json").path
        ))
    }

    @Test
    func adapterUsesAtomicReceiptsForNoOpAndNeverPerformsPostWriteRead() async throws {
        let profileID = UUID()
        let profile = AvatarProfileSummary(
            id: profileID,
            displayName: "Miller",
            profileRevision: 1,
            modelCapturedByteCount: 12,
            modelConsecutiveLoadFailures: 0,
            modelStatus: .available,
            motions: [],
            motionBindings: [:]
        )
        let store = RecordingAvatarProfileStore(profile: profile)
        let adapter = MillerAvatarProfileAdapter(store: store)
        await store.setFailProfileReads(true)

        #expect(try await adapter.rename(
            id: profileID,
            displayName: "Renamed"
        ) == .init(profileID: profileID, profileRevision: 1))
        #expect(await store.profileReadCount == 0)

        await store.setNextRenameCommit(nil)
        #expect(try await adapter.rename(
            id: profileID,
            displayName: "Renamed"
        ) == nil)
        #expect(await store.profileReadCount == 0)
    }

    @Test
    func successfulMutationsEmitOneBoundedProfileChangeAndFailuresEmitNone() async throws {
        let profileID = UUID()
        let profile = AvatarProfileSummary(
            id: profileID,
            displayName: "Miller",
            profileRevision: 1,
            modelCapturedByteCount: 12,
            modelConsecutiveLoadFailures: 0,
            modelStatus: .available,
            motions: [],
            motionBindings: [:]
        )
        let store = RecordingAvatarProfileStore(profile: profile)
        let adapter = MillerAvatarProfileAdapter(store: store)

        let change = try await adapter.rename(
            id: profileID,
            displayName: "Renamed"
        )
        #expect(change == .init(profileID: profileID, profileRevision: 1))
        await #expect(throws: AvatarProfileStoreError.unknownProfile) {
            _ = try await adapter.rename(id: UUID(), displayName: "Nope")
        }
        #expect(await store.renameCount == 2)
    }

    @Test
    func adapterForwardsEveryPublicStoreMutation() async throws {
        let profileID = UUID()
        let profile = AvatarProfileSummary(
            id: profileID,
            displayName: "Miller",
            profileRevision: 7,
            modelCapturedByteCount: 12,
            modelConsecutiveLoadFailures: 0,
            modelStatus: .available,
            motions: [],
            motionBindings: [:]
        )
        let store = RecordingAvatarProfileStore(profile: profile)
        let adapter = MillerAvatarProfileAdapter(store: store)
        let modelURL = URL(fileURLWithPath: "/tmp/model.vrm")
        let motionURL = URL(fileURLWithPath: "/tmp/motion.vrma")

        let changes: [AvatarCommittedProfileChange?] = [
            try await adapter.importModel(at: modelURL, displayName: "Miller"),
            try await adapter.rename(id: profileID, displayName: "Renamed"),
            try await adapter.remove(id: profileID),
            try await adapter.importMotion(
                profileID: profileID,
                at: motionURL,
                displayName: "Motion"
            ),
            try await adapter.renameMotion(
                profileID: profileID,
                motionID: UUID(),
                displayName: "Renamed motion"
            ),
            try await adapter.removeMotion(profileID: profileID, motionID: UUID()),
            try await adapter.bindMotion(
                profileID: profileID,
                role: .speaking,
                motionID: nil
            ),
            try await adapter.retry(id: profileID),
            try await adapter.retryMotion(profileID: profileID, motionID: UUID()),
        ]

        let expectedChange = AvatarCommittedProfileChange(
            profileID: profileID,
            profileRevision: 7
        )
        var expectedChanges = Array(repeating: Optional(expectedChange), count: 9)
        expectedChanges[6] = .init(
            profileID: profileID,
            profileRevision: 4
        )
        #expect(changes == expectedChanges)
        #expect(await store.operations == [
            "importModel",
            "rename",
            "remove",
            "importMotion",
            "renameMotion",
            "removeMotion",
            "bindMotion",
            "retry",
            "retryMotion",
        ])
    }

    @Test
    func adapterExposesSixPackageMotionRolesWithoutCopyingStorePolicy() async throws {
        let profileID = UUID()
        let profile = AvatarProfileSummary(
            id: profileID,
            displayName: "Miller",
            profileRevision: 4,
            modelCapturedByteCount: 12,
            modelConsecutiveLoadFailures: 0,
            modelStatus: .available,
            motions: [],
            motionBindings: [:]
        )
        let store = RecordingAvatarProfileStore(profile: profile)
        let adapter = MillerAvatarProfileAdapter(store: store)

        #expect(AvatarMotionRole.allCases.count == 6)
        let change = try #require(try await adapter.bindMotion(
            profileID: profileID,
            role: .speaking,
            motionID: nil
        ))
        #expect(change.profileID == profileID)
        #expect(change.profileRevision == 4)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-avatar-adapter-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func minimalVRM(binaryByteCount: Int = 4) throws -> Data {
        let json = Data(
            "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":\(binaryByteCount)}],\"extensionsUsed\":[\"VRMC_vrm\"],\"extensionsRequired\":[\"VRMC_vrm\"],\"extensions\":{\"VRMC_vrm\":{\"specVersion\":\"1.0\"}}}".utf8
        )
        var paddedJSON = json
        while paddedJSON.count % 4 != 0 { paddedJSON.append(0x20) }
        let binary = Data(repeating: 0, count: binaryByteCount)
        var result = Data()
        result.appendLE(0x4654_6C67)
        result.appendLE(2)
        result.appendLE(UInt32(12 + 8 + paddedJSON.count + 8 + binary.count))
        result.appendLE(UInt32(paddedJSON.count))
        result.appendLE(0x4E4F_534A)
        result.append(paddedJSON)
        result.appendLE(UInt32(binary.count))
        result.appendLE(0x004E_4942)
        result.append(binary)
        return result
    }

    private func sourceURL(relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

private struct LegacyProfileEnvelopeFixture: Encodable {
    let schemaVersion = 1
    let profiles: [LegacyProfileFixture]
}

private struct LegacyProfileFixture: Encodable {
    let schemaVersion = 1
    let id: UUID
    let displayName: String
    let modelBookmark: Data
    let modelSHA256: String
    let capturedByteCount: UInt64 = 1
    let rightsLabel = "local_user_supplied"
    let performanceProfile = "lightweight"
    let consecutiveLoadFailures = 0
}

private actor RecordingAvatarProfileStore: MillerAvatarProfileStoreAPI {
    let profile: AvatarProfileSummary
    var renameCount = 0
    var profileReadCount = 0
    var failProfileReads = false
    var nextRenameCommit: AvatarProfileCommit?
    var operations: [String] = []

    init(profile: AvatarProfileSummary) {
        self.profile = profile
        nextRenameCommit = AvatarProfileCommit(
            profileID: profile.id,
            profileRevision: profile.profileRevision
        )
    }

    func list() async throws -> [AvatarProfileSummary] { [profile] }
    func profile(id: UUID) async throws -> AvatarProfileSummary {
        profileReadCount += 1
        if failProfileReads { throw AvatarProfileStoreError.persistenceFailed }
        guard id == profile.id else { throw AvatarProfileStoreError.unknownProfile }
        return profile
    }
    func importModel(at: URL, displayName: String) async throws -> AvatarProfileSummary {
        operations.append("importModel")
        return profile
    }
    func renameCommitted(
        id: UUID,
        displayName: String
    ) async throws -> AvatarProfileCommit? {
        operations.append("rename")
        renameCount += 1
        guard id == profile.id else { throw AvatarProfileStoreError.unknownProfile }
        return nextRenameCommit
    }
    func removeCommitted(id: UUID) async throws -> AvatarProfileCommit? {
        operations.append("remove")
        return AvatarProfileCommit(profileID: profile.id, profileRevision: 7)
    }
    func importMotionCommitted(
        profileID: UUID,
        at: URL,
        displayName: String
    ) async throws -> AvatarMotionImportResult {
        operations.append("importMotion")
        let summary = AvatarMotionSummary(
            id: UUID(),
            displayName: displayName,
            capturedByteCount: 0,
            consecutiveLoadFailures: 0,
            lastFailure: nil
        )
        return AvatarMotionImportResult(
            summary: summary,
            commit: AvatarProfileCommit(profileID: profileID, profileRevision: 7)
        )
    }
    func renameMotionCommitted(
        profileID: UUID,
        motionID: UUID,
        displayName: String
    ) async throws -> AvatarProfileCommit? {
        operations.append("renameMotion")
        return AvatarProfileCommit(profileID: profileID, profileRevision: 7)
    }
    func removeMotionCommitted(
        profileID: UUID,
        motionID: UUID
    ) async throws -> AvatarProfileCommit? {
        operations.append("removeMotion")
        return AvatarProfileCommit(profileID: profileID, profileRevision: 7)
    }
    func bindMotionCommitted(
        profileID: UUID,
        role: AvatarMotionRole,
        motionID: UUID?
    ) async throws -> AvatarProfileCommit? {
        operations.append("bindMotion")
        return AvatarProfileCommit(profileID: profileID, profileRevision: 4)
    }
    func retryCommitted(id: UUID) async throws -> AvatarProfileCommit? {
        operations.append("retry")
        return AvatarProfileCommit(profileID: id, profileRevision: 7)
    }
    func retryMotionCommitted(
        profileID: UUID,
        motionID: UUID
    ) async throws -> AvatarProfileCommit? {
        operations.append("retryMotion")
        return AvatarProfileCommit(profileID: profileID, profileRevision: 7)
    }
    func resetMetadata() async throws {
        operations.append("resetMetadata")
    }

    func setFailProfileReads(_ value: Bool) {
        failProfileReads = value
    }

    func setNextRenameCommit(_ value: AvatarProfileCommit?) {
        nextRenameCommit = value
    }
}

import Foundation
import MillerAvatarCore
import MillerAvatarHost

struct AvatarCommittedProfileChange: Equatable, Sendable {
    let profileID: UUID
    let profileRevision: UInt64

    init(profileID: UUID, profileRevision: UInt64) {
        self.profileID = profileID
        self.profileRevision = profileRevision
    }
}

protocol MillerAvatarProfileStoreAPI: Sendable {
    func list() async throws -> [AvatarProfileSummary]
    func profile(id: UUID) async throws -> AvatarProfileSummary
    func importModel(
        at url: URL,
        displayName: String,
        qualityMode: AvatarAssetQualityMode
    ) async throws -> AvatarProfileSummary
    func renameCommitted(
        id: UUID,
        displayName: String
    ) async throws -> AvatarProfileCommit?
    func removeCommitted(id: UUID) async throws -> AvatarProfileCommit?
    func importMotionCommitted(
        profileID: UUID,
        at url: URL,
        displayName: String
    ) async throws -> AvatarMotionImportResult
    func renameMotionCommitted(
        profileID: UUID,
        motionID: UUID,
        displayName: String
    ) async throws -> AvatarProfileCommit?
    func removeMotionCommitted(
        profileID: UUID,
        motionID: UUID
    ) async throws -> AvatarProfileCommit?
    func bindMotionCommitted(
        profileID: UUID,
        role: AvatarMotionRole,
        motionID: UUID?
    ) async throws -> AvatarProfileCommit?
    func retryCommitted(id: UUID) async throws -> AvatarProfileCommit?
    func retryMotionCommitted(
        profileID: UUID,
        motionID: UUID
    ) async throws -> AvatarProfileCommit?
    func resetMetadata() async throws
}

extension AvatarProfileStore: MillerAvatarProfileStoreAPI {}

final class MillerAvatarProfileAdapter: Sendable {
    private let store: any MillerAvatarProfileStoreAPI
    let renderingStore: AvatarProfileStore?

    init(root: URL) {
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = AvatarProfileStore(root: root)
        self.store = store
        renderingStore = store
    }

    init(store: any MillerAvatarProfileStoreAPI) {
        self.store = store
        renderingStore = store as? AvatarProfileStore
    }

    func list() async throws -> [AvatarProfileSummary] {
        try await store.list()
    }

    func profile(id: UUID) async throws -> AvatarProfileSummary {
        try await store.profile(id: id)
    }

    func importModel(
        at url: URL,
        displayName: String
    ) async throws -> AvatarCommittedProfileChange {
        try await importModel(
            at: url,
            displayName: displayName,
            qualityMode: .lightweight
        )
    }

    func importModel(
        at url: URL,
        displayName: String,
        qualityMode: AvatarAssetQualityMode
    ) async throws -> AvatarCommittedProfileChange {
        let summary = try await store.importModel(
            at: url,
            displayName: displayName,
            qualityMode: qualityMode
        )
        return Self.change(from: summary)
    }

    func rename(
        id: UUID,
        displayName: String
    ) async throws -> AvatarCommittedProfileChange? {
        guard let commit = try await store.renameCommitted(
            id: id,
            displayName: displayName
        ) else { return nil }
        return Self.change(from: commit)
    }

    func remove(id: UUID) async throws -> AvatarCommittedProfileChange? {
        guard let commit = try await store.removeCommitted(id: id)
        else { return nil }
        return Self.change(from: commit)
    }

    func importMotion(
        profileID: UUID,
        at url: URL,
        displayName: String
    ) async throws -> AvatarCommittedProfileChange {
        let result = try await store.importMotionCommitted(
            profileID: profileID,
            at: url,
            displayName: displayName
        )
        return Self.change(from: result.commit)
    }

    func renameMotion(
        profileID: UUID,
        motionID: UUID,
        displayName: String
    ) async throws -> AvatarCommittedProfileChange? {
        guard let commit = try await store.renameMotionCommitted(
            profileID: profileID,
            motionID: motionID,
            displayName: displayName
        ) else { return nil }
        return Self.change(from: commit)
    }

    func removeMotion(
        profileID: UUID,
        motionID: UUID
    ) async throws -> AvatarCommittedProfileChange? {
        guard let commit = try await store.removeMotionCommitted(
            profileID: profileID,
            motionID: motionID
        ) else { return nil }
        return Self.change(from: commit)
    }

    func bindMotion(
        profileID: UUID,
        role: AvatarMotionRole,
        motionID: UUID?
    ) async throws -> AvatarCommittedProfileChange? {
        guard let commit = try await store.bindMotionCommitted(
            profileID: profileID,
            role: role,
            motionID: motionID
        ) else { return nil }
        return Self.change(from: commit)
    }

    func retry(id: UUID) async throws -> AvatarCommittedProfileChange? {
        guard let commit = try await store.retryCommitted(id: id)
        else { return nil }
        return Self.change(from: commit)
    }

    func retryMotion(
        profileID: UUID,
        motionID: UUID
    ) async throws -> AvatarCommittedProfileChange? {
        guard let commit = try await store.retryMotionCommitted(
            profileID: profileID,
            motionID: motionID
        ) else { return nil }
        return Self.change(from: commit)
    }

    func resetMetadata() async throws {
        try await store.resetMetadata()
    }

    private static func change(
        from summary: AvatarProfileSummary
    ) -> AvatarCommittedProfileChange {
        AvatarCommittedProfileChange(
            profileID: summary.id,
            profileRevision: summary.profileRevision
        )
    }

    private static func change(
        from commit: AvatarProfileCommit
    ) -> AvatarCommittedProfileChange {
        AvatarCommittedProfileChange(
            profileID: commit.profileID,
            profileRevision: commit.profileRevision
        )
    }
}

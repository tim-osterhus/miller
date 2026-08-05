import AppKit
import Foundation
import MillerCore
import MillerStorage
import Testing
@testable import MillerApp

@Suite
@MainActor
struct CodexProfileTests {
    @Test
    func loginCreatesCodexProfileWithPinnedSupportedModel() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-codex-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let database = root.appendingPathComponent("miller.sqlite3")
        let coordinator = try AppCoordinator(environment: [
            "MILLER_DATABASE_PATH": database.path,
            "MILLER_CACHE_PATH": root.appendingPathComponent("cache").path,
            "MILLER_GATEWAY_HELPER_PATH": helperPath.path,
            "MILLER_NODE_PATH": "/opt/homebrew/opt/node@22/bin/node",
            "MILLER_FAKE_HELPER_MODE": "normal",
        ])

        await coordinator.model.prepareCodexLogin()
        await coordinator.shutdown()

        let repository = try SQLiteConversationRepository(path: database.path)
        let profile = try await repository.selectedProviderProfile()
        await repository.close()

        #expect(profile?.model == "gpt-5.6-terra")
    }

    @Test
    func exactLegacyCodexModelMigratesWithoutChangingProfileIdentityOrCredential() async throws {
        _ = NSApplication.shared
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("miller.sqlite3")
        let profileID = UUID()
        let credentialReference = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = try ProviderProfile(
            id: profileID,
            kind: .codexOAuth,
            label: "Codex OAuth",
            baseURL: nil,
            model: "gpt-5",
            credentialReference: credentialReference,
            isSelected: true,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let repository = try SQLiteConversationRepository(path: database.path)
        try await repository.saveProviderProfile(legacy)
        await repository.close()

        let coordinator = try AppCoordinator(environment: environment(root, database: database))
        await coordinator.model.prepareCodexLogin()
        await coordinator.shutdown()

        let reopened = try SQLiteConversationRepository(path: database.path)
        let migrated = try await reopened.selectedProviderProfile()
        await reopened.close()

        #expect(migrated?.id == profileID)
        #expect(migrated?.model == "gpt-5.6-terra")
        #expect(migrated?.credentialReference == credentialReference)
        #expect(migrated?.label == legacy.label)
        #expect(migrated?.isSelected == legacy.isSelected)
        #expect(migrated?.createdAt == createdAt)
    }

    @Test
    func intentionalCustomCodexModelIsPreservedAcrossLoginPreparation() async throws {
        _ = NSApplication.shared
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("miller.sqlite3")
        let custom = "org/custom-model"
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex OAuth",
            baseURL: nil,
            model: custom,
            isSelected: true
        )
        let repository = try SQLiteConversationRepository(path: database.path)
        try await repository.saveProviderProfile(profile)
        await repository.close()

        let coordinator = try AppCoordinator(environment: environment(root, database: database))
        await coordinator.model.prepareCodexLogin()
        await coordinator.shutdown()

        let reopened = try SQLiteConversationRepository(path: database.path)
        let preserved = try await reopened.selectedProviderProfile()
        await reopened.close()

        #expect(preserved?.id == profile.id)
        #expect(preserved?.model == custom)
        #expect(preserved?.credentialReference == profile.credentialReference)
    }

    private var helperPath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Gateway/src/fake-helper.mjs")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-codex-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }

    private func environment(_ root: URL, database: URL) -> [String: String] {
        [
            "MILLER_DATABASE_PATH": database.path,
            "MILLER_CACHE_PATH": root.appendingPathComponent("cache").path,
            "MILLER_GATEWAY_HELPER_PATH": helperPath.path,
            "MILLER_NODE_PATH": "/opt/homebrew/opt/node@22/bin/node",
            "MILLER_FAKE_HELPER_MODE": "normal",
        ]
    }
}

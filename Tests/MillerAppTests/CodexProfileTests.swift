import AppKit
import Foundation
import MillerCore
import MillerGateway
import MillerLive
import MillerStorage
import Testing
@testable import MillerApp

private actor ReadinessCallCounts {
    private var local = 0
    private var remote = 0

    func recordLocal() { local += 1 }
    func recordRemote() { remote += 1 }
    func values() -> (local: Int, remote: Int) { (local, remote) }
}

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

    @Test
    func missingSelectedCredentialProjectsLocalCredentialUnavailable() async throws {
        _ = NSApplication.shared
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("miller.sqlite3")
        let profile = try ProviderProfile(
            kind: .openAICompatible,
            label: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            credentialReference: UUID(),
            isSelected: true
        )
        let repository = try SQLiteConversationRepository(path: database.path)
        try await repository.saveProviderProfile(profile)
        await repository.close()

        let coordinator = try AppCoordinator(environment: environment(root, database: database))
        await coordinator.model.refreshProviderSettings()
        #expect(coordinator.model.providerStatus == "Local credential unavailable")
        await coordinator.shutdown()
    }

    @Test
    func invalidatedSelectedCredentialProjectsLocalCredentialUnavailable() async throws {
        _ = NSApplication.shared
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("miller.sqlite3")
        let credentialStore = KeychainCredentialStore()
        let profile = try ProviderProfile(
            kind: .openAICompatible,
            label: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            credentialReference: UUID(),
            isSelected: true
        )
        defer { Task { try? await credentialStore.delete(for: profile.credentialReference) } }
        let repository = try SQLiteConversationRepository(path: database.path)
        try await repository.saveProviderProfile(profile)
        try await credentialStore.store(
            CredentialEnvelope(
                providerKind: .openAICompatible,
                payload: Data("{\"kind\":\"api_key\",\"key\":\"test\"}".utf8)
            ),
            for: profile.credentialReference
        )
        try await repository.setCredentialInvalidated(
            true,
            reference: profile.credentialReference
        )
        await repository.close()

        let coordinator = try AppCoordinator(environment: environment(root, database: database))
        await coordinator.model.refreshProviderSettings()
        #expect(coordinator.model.providerStatus == "Local credential unavailable")
        await coordinator.shutdown()
    }

    @Test
    func retryPerformsOneCachedRemoteProbeAndMutationsInvalidateIt() async throws {
        _ = NSApplication.shared
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("miller.sqlite3")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex OAuth",
            baseURL: nil,
            model: "gpt-5",
            credentialReference: UUID(),
            isSelected: true
        )
        let repository = try SQLiteConversationRepository(path: database.path)
        try await repository.saveProviderProfile(profile)
        let credentials = KeychainCredentialStore()
        try await credentials.store(
            CredentialEnvelope(
                providerKind: .codexOAuth,
                payload: Data("synthetic".utf8)
            ),
            for: profile.credentialReference
        )
        let gatewayRoot = helperPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let supervisor = GatewaySupervisor(configuration: .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [helperPath.path, "normal"],
            workingDirectoryURL: gatewayRoot,
            environment: [
                "LANG": "C", "LC_ALL": "C", "TMPDIR": cache.path, "TZ": "UTC",
            ],
            terminationGrace: .milliseconds(200)
        ))
        let counts = ReadinessCallCounts()
        let controller = ProviderSettingsController(
            repository: repository,
            credentials: credentials,
            supervisor: supervisor,
            databaseURL: database,
            cacheURL: cache,
            codexTypedReadiness: { _ in
                await counts.recordLocal()
                return .init(state: .ready)
            },
            codexTypedRemoteReadiness: { _ in
                await counts.recordRemote()
                return .init(state: .remoteProbeTimedOut)
            }
        )
        defer {
            Task {
                await supervisor.shutdown()
                await repository.close()
                try? await credentials.delete(for: profile.credentialReference)
            }
        }

        _ = try await controller.snapshot()
        #expect(await counts.values().local == 1)
        #expect(await counts.values().remote == 0)

        let retried = try await controller.retryReadiness()
        #expect(retried.readiness == "Readiness probe timed out")
        let cached = try await controller.snapshot()
        #expect(cached.readiness == "Readiness probe timed out")
        #expect(await counts.values().remote == 1)

        try await controller.saveCodexModel("gpt-5.6-terra")
        _ = try await controller.snapshot()
        #expect(await counts.values().local == 2)
        #expect(await counts.values().remote == 1)
    }

    @Test
    func snapshotDiscardsReadinessFromAProfileGenerationThatMutatedDuringProbe() async throws {
        _ = NSApplication.shared
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("miller.sqlite3")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex OAuth",
            baseURL: nil,
            model: "gpt-5",
            credentialReference: UUID(),
            isSelected: true
        )
        let repository = try SQLiteConversationRepository(path: database.path)
        try await repository.saveProviderProfile(profile)
        let credentials = KeychainCredentialStore()
        try await credentials.store(
            CredentialEnvelope(
                providerKind: .codexOAuth,
                payload: Data("synthetic".utf8)
            ),
            for: profile.credentialReference
        )
        let gatewayRoot = helperPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let supervisor = GatewaySupervisor(configuration: .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [helperPath.path, "normal"],
            workingDirectoryURL: gatewayRoot,
            environment: [
                "LANG": "C", "LC_ALL": "C", "TMPDIR": cache.path, "TZ": "UTC",
            ],
            terminationGrace: .milliseconds(200)
        ))
        let probe = SnapshotReadinessProbe()
        let controller = ProviderSettingsController(
            repository: repository,
            credentials: credentials,
            supervisor: supervisor,
            databaseURL: database,
            cacheURL: cache,
            codexTypedReadiness: { profile in await probe.load(profile) },
            codexTypedRemoteReadiness: { _ in .init(state: .remoteProbeTimedOut) }
        )
        defer {
            Task {
                await supervisor.shutdown()
                await repository.close()
                try? await credentials.delete(for: profile.credentialReference)
            }
        }

        let snapshotTask = Task { try await controller.snapshot() }
        try await probe.waitUntilEntered()
        try await controller.saveCodexModel("gpt-5.6-terra")
        await probe.release()

        let snapshot = try await snapshotTask.value
        #expect(snapshot.profiles.first?.model == "gpt-5.6-terra")
        #expect(snapshot.readiness == "Ready")
        #expect(await probe.calls == 2)
    }

    @Test
    func snapshotRetriesWhenGenerationMutatesAfterSuccessfulCredentialInvalidationCheck() async throws {
        _ = NSApplication.shared
        let boundary = SnapshotCredentialBoundary()
        let loadCounter = SnapshotCallCounter()
        let fixture = try await makeCodexSnapshotFixture(
            afterCredentialInvalidation: { await boundary.pauseFirstCall() },
            afterCredentialLoad: { await loadCounter.record() }
        )
        defer {
            Task {
                await fixture.supervisor.shutdown()
                await fixture.repository.close()
                try? await fixture.credentials.delete(for: fixture.profile.credentialReference)
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }

        let snapshotTask = Task { try await fixture.controller.snapshot() }
        try await boundary.waitUntilEntered()
        try await fixture.controller.saveCodexModel("gpt-5.6-terra")
        await boundary.release()

        let snapshot = try await snapshotTask.value
        #expect(snapshot.profiles.first?.model == "gpt-5.6-terra")
        #expect(await loadCounter.calls == 1)
    }

    @Test
    func snapshotRetriesWhenGenerationMutatesAfterSuccessfulCredentialLoad() async throws {
        _ = NSApplication.shared
        let boundary = SnapshotCredentialBoundary()
        let readinessProbe = SnapshotProfileProbe()
        let fixture = try await makeCodexSnapshotFixture(
            afterCredentialLoad: { await boundary.pauseFirstCall() },
            readinessProbe: readinessProbe
        )
        defer {
            Task {
                await fixture.supervisor.shutdown()
                await fixture.repository.close()
                try? await fixture.credentials.delete(for: fixture.profile.credentialReference)
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }

        let snapshotTask = Task { try await fixture.controller.snapshot() }
        try await boundary.waitUntilEntered()
        try await fixture.controller.saveCodexModel("gpt-5.6-terra")
        await boundary.release()

        let snapshot = try await snapshotTask.value
        #expect(snapshot.profiles.first?.model == "gpt-5.6-terra")
        #expect(await readinessProbe.models == ["gpt-5.6-terra"])
    }

    private func makeCodexSnapshotFixture(
        afterCredentialInvalidation: @escaping @Sendable () async -> Void = {},
        afterCredentialLoad: @escaping @Sendable () async -> Void = {},
        readinessProbe: SnapshotProfileProbe? = nil
    ) async throws -> CodexSnapshotFixture {
        let root = try makeRoot()
        let database = root.appendingPathComponent("miller.sqlite3")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex OAuth",
            baseURL: nil,
            model: "gpt-5",
            credentialReference: UUID(),
            isSelected: true
        )
        let repository = try SQLiteConversationRepository(path: database.path)
        try await repository.saveProviderProfile(profile)
        let credentials = KeychainCredentialStore()
        try await credentials.store(
            CredentialEnvelope(
                providerKind: .codexOAuth,
                payload: Data("synthetic".utf8)
            ),
            for: profile.credentialReference
        )
        let gatewayRoot = helperPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let supervisor = GatewaySupervisor(configuration: .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [helperPath.path, "normal"],
            workingDirectoryURL: gatewayRoot,
            environment: [
                "LANG": "C", "LC_ALL": "C", "TMPDIR": cache.path, "TZ": "UTC",
            ],
            terminationGrace: .milliseconds(200)
        ))
        let controller = ProviderSettingsController(
            repository: repository,
            credentials: credentials,
            supervisor: supervisor,
            databaseURL: database,
            cacheURL: cache,
            codexTypedReadiness: { profile in
                await readinessProbe?.record(profile)
                return .init(state: .ready)
            },
            codexTypedRemoteReadiness: { _ in .init(state: .remoteProbeTimedOut) },
            testAfterCredentialInvalidation: afterCredentialInvalidation,
            testAfterCredentialLoad: afterCredentialLoad
        )
        return CodexSnapshotFixture(
            root: root,
            profile: profile,
            repository: repository,
            credentials: credentials,
            supervisor: supervisor,
            controller: controller
        )
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

private actor SnapshotReadinessProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func load(_ profile: ProviderProfile) async -> CodexTypedReadiness {
        _ = profile
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
        return .init(state: .ready)
    }

    func waitUntilEntered() async throws {
        while calls == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct CodexSnapshotFixture {
    let root: URL
    let profile: ProviderProfile
    let repository: SQLiteConversationRepository
    let credentials: KeychainCredentialStore
    let supervisor: GatewaySupervisor
    let controller: ProviderSettingsController
}

private actor SnapshotCredentialBoundary {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func pauseFirstCall() async {
        calls += 1
        guard calls == 1 else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async throws {
        while calls == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SnapshotCallCounter {
    private(set) var calls = 0

    func record() { calls += 1 }
}

private actor SnapshotProfileProbe {
    private(set) var models: [String] = []

    func record(_ profile: ProviderProfile) {
        models.append(profile.model)
    }
}

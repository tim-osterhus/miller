import Foundation
import MillerCore
import MillerGateway
import MillerStorage
import Testing
@testable import MillerApp

@Suite
struct ResetServiceTests {
    @Test
    func profilePersistenceSelectsExactlyOneAndRefusesActiveTurnSwitch() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try SQLiteConversationRepository(path: fixture.database.path)
        let first = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5",
            credentialReference: UUID(),
            isSelected: false
        )
        let second = try ProviderProfile(
            kind: .openAICompatible,
            label: "Fixture",
            baseURL: "https://example.invalid/",
            model: "fixture-model",
            credentialReference: UUID(),
            isSelected: false
        )

        try await repository.saveProviderProfile(first)
        try await repository.saveProviderProfile(second)
        #expect(try await repository.selectedProviderProfile()?.id == first.id)

        let updatedFirst = try ProviderProfile(
            id: first.id,
            kind: first.kind,
            label: "Updated Codex",
            baseURL: first.baseURL,
            model: first.model,
            credentialReference: first.credentialReference,
            isSelected: false,
            createdAt: first.createdAt
        )
        try await repository.saveProviderProfile(updatedFirst)
        #expect(try await repository.selectedProviderProfile()?.id == first.id)
        #expect(try await repository.providerProfiles().count == 2)

        await #expect(throws: ProviderProfileError.activeTurn) {
            try await repository.selectProviderProfile(id: second.id, hasActiveTurn: true)
        }
        try await repository.selectProviderProfile(id: second.id, hasActiveTurn: false)

        let profiles = try await repository.providerProfiles()
        #expect(profiles.filter(\.isSelected).map(\.id) == [second.id])
    }

    @Test
    func endpointPolicyNormalizesOriginsAndRejectsUnsafeDestinations() throws {
        #expect(
            try EndpointPolicy.normalize("HTTPS://Example.COM:443/")
                == "https://example.com"
        )
        #expect(
            try EndpointPolicy.normalize("http://127.0.0.42:43191/")
                == "http://127.0.0.42:43191"
        )
        #expect(
            try EndpointPolicy.normalize("http://[::1]:43191/")
                == "http://[::1]:43191"
        )

        for endpoint in [
            "http://example.invalid/",
            "http://localhost:43191/",
            "http://loopback.invalid:43191/",
            "https://user@example.invalid/",
            "https://example.invalid/?query=1",
            "https://example.invalid/#fragment",
            "https://example.invalid/v1",
            "file:///tmp/provider",
        ] {
            #expect(throws: EndpointPolicyError.self) {
                _ = try EndpointPolicy.normalize(endpoint)
            }
        }
        #expect(throws: EndpointPolicyError.redirectNotAllowed) {
            try EndpointPolicy.validateAuthenticatedRedirect(
                from: URL(string: "https://example.invalid")!,
                to: URL(string: "https://other.invalid")!
            )
        }
    }

    @Test
    func profileDeletionRemovesCredentialBeforeSQLiteRow() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try SQLiteConversationRepository(path: fixture.database.path)
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5",
            credentialReference: UUID(),
            isSelected: true
        )
        try await repository.saveProviderProfile(profile)
        let credentials = DeletionOrderingCredentialStore(
            repository: repository,
            profileID: profile.id,
            reference: profile.credentialReference
        )
        let service = ProviderProfileService(
            repository: repository,
            credentials: credentials
        )

        await #expect(throws: ProviderProfileError.activeTurn) {
            try await service.deleteProfile(id: profile.id, hasActiveTurn: true)
        }
        #expect(try await repository.providerProfiles().map(\.id) == [profile.id])

        try await service.deleteProfile(id: profile.id, hasActiveTurn: false)

        #expect(await credentials.profileExistedDuringDeletion)
        #expect(try await repository.providerProfiles().isEmpty)
    }

    @Test
    func resetStopsClosesAndRemovesEveryManagedRoot() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = MemoryCredentialStore()
        let reference = UUID()
        try await store.store(try syntheticEnvelope(), for: reference)
        for url in fixture.managedURLs {
            try Data("managed".utf8).write(to: url)
        }
        let order = EventRecorder()
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [fixture.cache],
            credentialStore: store,
            stopAndReapHelper: { await order.append("helper") },
            closeDatabase: { await order.append("database") },
            reopenDatabase: {},
            resumeRuntime: {}
        )

        let result = await service.reset()

        #expect(result.failures.isEmpty)
        #expect(await order.values == ["helper", "database"])
        #expect(fixture.managedURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        #expect((await store.allReferences()).isEmpty)
    }

    @Test
    func successfulResetReopensRepositoryWithEmptyAuthoritativeState() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try SQLiteConversationRepository(path: fixture.database.path)
        let preResetProfile = try syntheticProfile(label: "Before reset")
        try await repository.saveProviderProfile(preResetProfile)
        try FileManager.default.createDirectory(
            at: fixture.cache,
            withIntermediateDirectories: false
        )
        let supervisor = GatewaySupervisor(
            configuration: gatewayConfiguration(cacheURL: fixture.cache)
        )
        #expect(!(try await supervisor.codexModelCatalog()).models.isEmpty)
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [fixture.cache],
            credentialStore: MemoryCredentialStore(),
            stopAndReapHelper: { await supervisor.shutdown() },
            closeDatabase: { await repository.close() },
            reopenDatabase: {
                try await repository.reopen()
                try await repository.reopen()
            },
            resumeRuntime: {
                try FileManager.default.createDirectory(
                    at: fixture.cache,
                    withIntermediateDirectories: true
                )
            }
        )

        let result = await service.reset()

        #expect(result.failures.isEmpty)
        #expect(result.roots.last == .init(root: "runtime.resume", succeeded: true))
        #expect(FileManager.default.fileExists(atPath: fixture.cache.path))
        #expect(try await repository.providerProfiles().isEmpty)

        let postResetProfile = try syntheticProfile(label: "After reset")
        try await repository.saveProviderProfile(postResetProfile)
        #expect(try await repository.providerProfiles().map(\.id) == [postResetProfile.id])
        let conversationID = ConversationID()
        let turnID = TurnID()
        try await repository.accept(
            conversationID: conversationID,
            turnID: turnID,
            userText: "repository remains usable",
            inputMode: .text,
            generation: 1
        )
        #expect(try await repository.turn(id: turnID)?.userText == "repository remains usable")

        let catalog = try await supervisor.codexModelCatalog()
        #expect(catalog.providerKind == "codex_oauth")
        #expect(!catalog.models.isEmpty)
        await supervisor.shutdown()
    }

    @Test
    func partialDatabaseDeletionReopensRepositoryWithSurvivingAuthority() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try SQLiteConversationRepository(path: fixture.database.path)
        let survivingProfile = try syntheticProfile(label: "Surviving profile")
        try await repository.saveProviderProfile(survivingProfile)
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [],
            credentialStore: MemoryCredentialStore(),
            stopAndReapHelper: {},
            closeDatabase: { await repository.close() },
            reopenDatabase: { try await repository.reopen() },
            resumeRuntime: {},
            removeItem: { url in
                if url == fixture.database {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        let result = await service.reset()

        #expect(result.failures.map(\.root) == [fixture.database.path])
        #expect(result.roots.last == .init(root: "runtime.resume", succeeded: true))
        #expect(try await repository.providerProfiles().map(\.id) == [survivingProfile.id])

        let additionalProfile = try syntheticProfile(label: "Additional profile")
        try await repository.saveProviderProfile(additionalProfile)
        let profiles = try await repository.providerProfiles()
        #expect(
            Set(profiles.map(\.id))
                == Set([survivingProfile.id, additionalProfile.id])
        )
    }

    @Test
    func resetReportsEachFailureAndPermitsRetry() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("managed".utf8).write(to: fixture.database)
        let attempts = AttemptCounter()
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [],
            credentialStore: MemoryCredentialStore(),
            stopAndReapHelper: {},
            closeDatabase: {},
            reopenDatabase: {},
            resumeRuntime: {},
            removeItem: { url in
                if await attempts.increment() == 1 {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        let first = await service.reset()
        #expect(first.failures.map(\.root) == [fixture.database.path])
        #expect(FileManager.default.fileExists(atPath: fixture.database.path))

        let retry = await service.reset()
        #expect(retry.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.database.path))
    }

    @Test
    func resetTreatsFileDisappearanceDuringRemovalAsSuccess() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("managed".utf8).write(to: fixture.database)
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [],
            credentialStore: MemoryCredentialStore(),
            stopAndReapHelper: {},
            closeDatabase: {},
            reopenDatabase: {},
            resumeRuntime: {},
            removeItem: { url in
                try FileManager.default.removeItem(at: url)
                throw CocoaError(.fileNoSuchFile)
            }
        )

        let result = await service.reset()

        #expect(result.failures.isEmpty)
        #expect(result.roots.first(where: { $0.root == fixture.database.path })?.succeeded == true)
    }

    @Test
    func resetTreatsCredentialDisappearanceDuringDeletionAsSuccess() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let credentials = DisappearingCredentialStore()
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [],
            credentialStore: credentials,
            stopAndReapHelper: {},
            closeDatabase: {},
            reopenDatabase: {},
            resumeRuntime: {}
        )

        let result = await service.reset()

        #expect(result.failures.isEmpty)
        #expect(result.roots.first(where: {
            $0.root.hasPrefix("keychain:")
        })?.succeeded == true)
    }

    @Test
    func resetDoesNotRemoveAnythingUntilHelperStopsAndDatabaseCloses() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("managed".utf8).write(to: fixture.database)
        let store = MemoryCredentialStore()
        let reference = UUID()
        try await store.store(try syntheticEnvelope(), for: reference)
        let stop = FailableAction()
        let reopen = AttemptCounter()
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [],
            credentialStore: store,
            stopAndReapHelper: { try await stop.run() },
            closeDatabase: {},
            reopenDatabase: { _ = await reopen.increment() },
            resumeRuntime: {}
        )

        let first = await service.reset()
        #expect(first.failures.map(\.root) == ["helper"])
        #expect(FileManager.default.fileExists(atPath: fixture.database.path))
        #expect((await store.allReferences()) == [reference])
        #expect(await reopen.value == 0)

        await stop.allowSuccess()
        let retry = await service.reset()
        #expect(retry.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.database.path))
        #expect((await store.allReferences()).isEmpty)
        #expect(await reopen.value == 1)
    }

    @Test
    func resetDoesNotReopenWhenDatabaseCloseFails() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let reopen = AttemptCounter()
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [],
            credentialStore: MemoryCredentialStore(),
            stopAndReapHelper: {},
            closeDatabase: { throw CocoaError(.fileWriteUnknown) },
            reopenDatabase: { _ = await reopen.increment() },
            resumeRuntime: {}
        )

        let result = await service.reset()

        #expect(result.failures.map(\.root) == ["sqlite.close"])
        #expect(await reopen.value == 0)
    }

    @Test
    func resetReportsSanitizedReopenFailureAfterDeletion() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [],
            credentialStore: MemoryCredentialStore(),
            stopAndReapHelper: {},
            closeDatabase: {},
            reopenDatabase: { throw CocoaError(.fileWriteUnknown) },
            resumeRuntime: {}
        )

        let result = await service.reset()

        #expect(result.roots.last == ResetRootResult(
            root: "sqlite.reopen",
            succeeded: false
        ))
        #expect(result.failures.map(\.root) == ["sqlite.reopen"])
    }

    @Test
    func resetReportsSanitizedRuntimeResumeFailure() async throws {
        let fixture = try TestRoot(name: #function)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ResetService(
            databaseURL: fixture.database,
            cacheURLs: [],
            credentialStore: MemoryCredentialStore(),
            stopAndReapHelper: {},
            closeDatabase: {},
            reopenDatabase: {},
            resumeRuntime: { throw CocoaError(.fileWriteUnknown) }
        )

        let result = await service.reset()

        #expect(result.roots.last == ResetRootResult(
            root: "runtime.resume",
            succeeded: false
        ))
        #expect(result.failures.map(\.root) == ["runtime.resume"])
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor AttemptCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private actor FailableAction {
    private var succeeds = false

    func allowSuccess() {
        succeeds = true
    }

    func run() throws {
        guard succeeds else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private actor MemoryCredentialStore: CredentialStore {
    private var values: [UUID: CredentialEnvelope] = [:]

    func store(_ envelope: CredentialEnvelope, for reference: UUID) throws {
        values[reference] = envelope
    }

    func load(for reference: UUID) throws -> CredentialEnvelope {
        guard let value = values[reference] else {
            throw CredentialError.itemNotFound
        }
        return value
    }

    func delete(for reference: UUID) throws {
        guard values.removeValue(forKey: reference) != nil else {
            throw CredentialError.itemNotFound
        }
    }

    func allReferences() -> [UUID] {
        values.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

private actor DisappearingCredentialStore: CredentialStore {
    private let reference = UUID()

    func store(_: CredentialEnvelope, for _: UUID) {}

    func load(for _: UUID) throws -> CredentialEnvelope {
        throw CredentialError.itemNotFound
    }

    func delete(for _: UUID) throws {
        throw CredentialError.itemNotFound
    }

    func allReferences() -> [UUID] {
        [reference]
    }
}

private actor DeletionOrderingCredentialStore: CredentialStore {
    private let repository: SQLiteConversationRepository
    private let profileID: UUID
    private var reference: UUID?
    private(set) var profileExistedDuringDeletion = false

    init(
        repository: SQLiteConversationRepository,
        profileID: UUID,
        reference: UUID
    ) {
        self.repository = repository
        self.profileID = profileID
        self.reference = reference
    }

    func store(_: CredentialEnvelope, for reference: UUID) {
        self.reference = reference
    }

    func load(for reference: UUID) throws -> CredentialEnvelope {
        guard self.reference == reference else {
            throw CredentialError.itemNotFound
        }
        return try syntheticEnvelope()
    }

    func delete(for reference: UUID) async throws {
        guard self.reference == reference else {
            throw CredentialError.itemNotFound
        }
        profileExistedDuringDeletion = try await repository
            .providerProfiles()
            .contains(where: { $0.id == profileID })
        self.reference = nil
    }

    func allReferences() -> [UUID] {
        reference.map { [$0] } ?? []
    }
}

private func syntheticEnvelope() throws -> CredentialEnvelope {
    try CredentialEnvelope(
        providerKind: .codexOAuth,
        payload: Data("synthetic".utf8)
    )
}

private func syntheticProfile(label: String) throws -> ProviderProfile {
    try ProviderProfile(
        kind: .openAICompatible,
        label: label,
        baseURL: "https://example.invalid",
        model: "fixture-model",
        credentialReference: UUID(),
        isSelected: true
    )
}

private func gatewayConfiguration(
    cacheURL: URL
) -> GatewayProcess.Configuration {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return GatewayProcess.Configuration(
        executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
        arguments: ["Gateway/src/fake-helper.mjs", "normal"],
        workingDirectoryURL: repository,
        environment: [
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": cacheURL.path,
        ],
        terminationGrace: .milliseconds(200)
    )
}

private struct TestRoot {
    let directory: URL
    let database: URL
    let cache: URL

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        database = directory.appendingPathComponent("miller.sqlite3")
        cache = directory.appendingPathComponent("cache")
    }

    var managedURLs: [URL] {
        [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm"),
            cache,
        ]
    }
}

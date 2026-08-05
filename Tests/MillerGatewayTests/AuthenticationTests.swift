import Foundation
import MillerCore
import Testing

@Suite
struct AuthenticationTests {
    @Test
    func candidateIsPersistedBeforeHelperAcknowledgment() async throws {
        let store = RecordingCredentialStore()
        let helper = RecordingCredentialHelper(store: store)
        let reference = UUID()
        let profiles = RecordingProfileRepository(
            profiles: [try profile(reference: reference)]
        )
        let coordinator = CredentialCoordinator(
            store: store,
            helper: helper,
            profiles: profiles
        )
        let candidate = try envelope("synthetic-candidate")

        try await coordinator.persistCandidate(
            candidate,
            for: reference,
            hasActiveTurn: false
        )

        #expect(try await store.load(for: reference) == candidate)
        #expect(await helper.events == ["persisted"])
        #expect(await helper.sawStoredCredentialAtAcknowledgment)
    }

    @Test
    func persistFailureRejectsCandidateAndRequiresAuthentication() async throws {
        let store = RecordingCredentialStore()
        let helper = RecordingCredentialHelper(store: store)
        let reference = UUID()
        let profiles = RecordingProfileRepository(
            profiles: [try profile(reference: reference)]
        )
        let coordinator = CredentialCoordinator(
            store: store,
            helper: helper,
            profiles: profiles
        )
        let old = try envelope("old")
        try await store.store(old, for: reference)
        await store.failWrites()
        await store.failDeletes()

        await #expect(throws: CredentialCoordinationError.persistenceFailed) {
            try await coordinator.persistCandidate(
                try envelope("rotated"),
                for: reference,
                hasActiveTurn: false
            )
        }

        #expect(await helper.events == ["persist_failed"])
        #expect(try await store.load(for: reference) == old)
        let relaunched = CredentialCoordinator(
            store: store,
            helper: RecordingCredentialHelper(store: store),
            profiles: profiles
        )
        #expect(
            try await relaunched.restore(reference: reference)
                == .authenticationRequired
        )
    }

    @Test
    func logoutClearsHelperBeforeDeletingKeychainAndReportsIncompleteDeletion() async throws {
        let store = RecordingCredentialStore()
        let helper = RecordingCredentialHelper(store: store)
        let reference = UUID()
        let profiles = RecordingProfileRepository(
            profiles: [try profile(reference: reference)]
        )
        let coordinator = CredentialCoordinator(
            store: store,
            helper: helper,
            profiles: profiles
        )
        let stored = try envelope("synthetic")
        try await store.store(stored, for: reference)
        await store.failDeletes()

        await #expect(throws: CredentialCoordinationError.logoutIncompleteLocalCredentialRemains) {
            try await coordinator.logout(
                reference: reference,
                hasActiveTurn: false
            )
        }

        #expect(await helper.events == ["clear"])
        #expect(try await store.load(for: reference) == stored)
    }

    @Test
    func startupRestoresOnlySelectedProfile() async throws {
        let selected = try ProviderProfile(
            kind: .codexOAuth,
            label: "Selected",
            baseURL: nil,
            model: "gpt-5",
            credentialReference: UUID(),
            isSelected: true
        )
        let other = try ProviderProfile(
            kind: .codexOAuth,
            label: "Other",
            baseURL: nil,
            model: "gpt-5",
            credentialReference: UUID(),
            isSelected: false
        )
        let repository = RecordingProfileRepository(
            profiles: [selected, other]
        )
        let store = RecordingCredentialStore()
        try await store.store(
            try envelope("selected"),
            for: selected.credentialReference
        )
        try await store.store(
            try envelope("other"),
            for: other.credentialReference
        )
        let helper = RecordingCredentialHelper(store: store)
        let coordinator = CredentialCoordinator(
            store: store,
            helper: helper,
            profiles: repository
        )

        #expect(
            try await coordinator.restoreSelectedProfile()
                == .ready
        )
        #expect(await helper.restoredReferences == [selected.credentialReference])
    }

    @Test
    func credentialMutationIsRefusedDuringActiveTurn() async throws {
        let store = RecordingCredentialStore()
        let helper = RecordingCredentialHelper(store: store)
        let reference = UUID()
        let profiles = RecordingProfileRepository(
            profiles: [try profile(reference: reference)]
        )
        let coordinator = CredentialCoordinator(
            store: store,
            helper: helper,
            profiles: profiles
        )
        try await store.store(try envelope("existing"), for: reference)

        await #expect(throws: CredentialCoordinationError.activeTurn) {
            try await coordinator.persistCandidate(
                try envelope("replacement"),
                for: reference,
                hasActiveTurn: true
            )
        }
        await #expect(throws: CredentialCoordinationError.activeTurn) {
            try await coordinator.logout(
                reference: reference,
                hasActiveTurn: true
            )
        }

        #expect(
            (try await store.load(for: reference)).payload
                == Data("existing".utf8)
        )
        #expect(await helper.events.isEmpty)
    }

    @Test
    func envelopeKindMustMatchOwningProfile() async throws {
        let store = RecordingCredentialStore()
        let helper = RecordingCredentialHelper(store: store)
        let reference = UUID()
        let profiles = RecordingProfileRepository(
            profiles: [
                try profile(
                    reference: reference,
                    kind: .openAICompatible
                ),
            ]
        )
        let coordinator = CredentialCoordinator(
            store: store,
            helper: helper,
            profiles: profiles
        )

        await #expect(throws: CredentialCoordinationError.providerMismatch) {
            try await coordinator.persistCandidate(
                try envelope("wrong-kind"),
                for: reference,
                hasActiveTurn: false
            )
        }
        #expect((await store.allReferences()).isEmpty)

        try await store.store(try envelope("misbound"), for: reference)
        #expect(
            try await coordinator.restore(reference: reference)
                == .authenticationRequired
        )
        #expect(await helper.events.isEmpty)
    }

    @Test
    func cleanupIsAttemptedWhenDurableInvalidationFails() async throws {
        let store = RecordingCredentialStore()
        let helper = RecordingCredentialHelper(store: store)
        let reference = UUID()
        let profiles = RecordingProfileRepository(
            profiles: [try profile(reference: reference)]
        )
        let coordinator = CredentialCoordinator(
            store: store,
            helper: helper,
            profiles: profiles
        )
        try await store.store(try envelope("old"), for: reference)
        await store.failWrites()
        await profiles.failInvalidationWrites()

        await #expect(
            throws: CredentialCoordinationError.invalidationPersistenceFailed
        ) {
            try await coordinator.persistCandidate(
                try envelope("rotated"),
                for: reference,
                hasActiveTurn: false
            )
        }

        await #expect(throws: CredentialError.itemNotFound) {
            _ = try await store.load(for: reference)
        }
        #expect(await helper.events == ["persist_failed"])
    }
}

private actor RecordingCredentialStore: CredentialStore {
    private var values: [UUID: CoreCredentialEnvelope] = [:]
    private var shouldFailWrites = false
    private var shouldFailDeletes = false

    func failWrites() {
        shouldFailWrites = true
    }

    func failDeletes() {
        shouldFailDeletes = true
    }

    func store(_ envelope: CoreCredentialEnvelope, for reference: UUID) throws {
        guard !shouldFailWrites else {
            throw CredentialError.storageFailed
        }
        values[reference] = envelope
    }

    func load(for reference: UUID) throws -> CoreCredentialEnvelope {
        guard let value = values[reference] else {
            throw CredentialError.itemNotFound
        }
        return value
    }

    func delete(for reference: UUID) throws {
        guard !shouldFailDeletes else {
            throw CredentialError.deletionFailed
        }
        guard values.removeValue(forKey: reference) != nil else {
            throw CredentialError.itemNotFound
        }
    }

    func allReferences() -> [UUID] {
        values.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

private actor RecordingCredentialHelper: CredentialHelper {
    private let store: RecordingCredentialStore
    private(set) var events: [String] = []
    private(set) var sawStoredCredentialAtAcknowledgment = false
    private(set) var restoredReferences: [UUID] = []

    init(store: RecordingCredentialStore) {
        self.store = store
    }

    func restore(reference: UUID, credential _: Data) {
        restoredReferences.append(reference)
        events.append("restore")
    }

    func persisted(reference: UUID) async {
        sawStoredCredentialAtAcknowledgment =
            (try? await store.load(for: reference)) != nil
        events.append("persisted")
    }

    func persistFailed(reference _: UUID) {
        events.append("persist_failed")
    }

    func clear(reference _: UUID) {
        events.append("clear")
    }
}

private func envelope(_ payload: String) throws -> CoreCredentialEnvelope {
    try CoreCredentialEnvelope(
        providerKind: .codexOAuth,
        payload: Data(payload.utf8)
    )
}

private actor RecordingProfileRepository: ProviderProfileRepository {
    private var profiles: [ProviderProfile]
    private var invalidated: Set<UUID> = []
    private var shouldFailInvalidationWrites = false

    init(profiles: [ProviderProfile]) {
        self.profiles = profiles
    }

    func saveProviderProfile(_ profile: ProviderProfile) {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
    }

    func providerProfiles() -> [ProviderProfile] {
        profiles
    }

    func selectedProviderProfile() -> ProviderProfile? {
        profiles.first(where: \.isSelected)
    }

    func selectProviderProfile(id: UUID, hasActiveTurn _: Bool) throws {
        guard profiles.contains(where: { $0.id == id }) else {
            throw ProviderProfileError.profileNotFound
        }
        profiles = try profiles.map { try $0.selected($0.id == id) }
    }

    func deleteProviderProfile(id: UUID) {
        let references = profiles
            .filter { $0.id == id }
            .map(\.credentialReference)
        profiles.removeAll { $0.id == id }
        invalidated.subtract(references)
    }

    func credentialIsInvalidated(reference: UUID) -> Bool {
        invalidated.contains(reference)
    }

    func failInvalidationWrites() {
        shouldFailInvalidationWrites = true
    }

    func setCredentialInvalidated(
        _ value: Bool,
        reference: UUID
    ) throws {
        guard !shouldFailInvalidationWrites else {
            throw CredentialCoordinationError.invalidationPersistenceFailed
        }
        if value {
            invalidated.insert(reference)
        } else {
            invalidated.remove(reference)
        }
    }
}

private func profile(
    reference: UUID,
    kind: ProviderKind = .codexOAuth
) throws -> ProviderProfile {
    try ProviderProfile(
        kind: kind,
        label: "Fixture",
        baseURL: kind == .openAICompatible
            ? "https://example.invalid/"
            : nil,
        model: "fixture-model",
        credentialReference: reference,
        isSelected: true
    )
}

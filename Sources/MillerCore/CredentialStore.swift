import Foundation

public enum CredentialError: Error, Equatable, Sendable {
    case payloadTooLarge
    case storageFailed
    case itemNotFound
    case deletionFailed
}

public struct CoreCredentialEnvelope: Codable, Sendable, Equatable {
    public let version: Int
    public let providerKind: ProviderKind
    public let payload: Data

    public init(providerKind: ProviderKind, payload: Data) throws {
        guard payload.count <= 65_536 else {
            throw CredentialError.payloadTooLarge
        }
        version = 1
        self.providerKind = providerKind
        self.payload = payload
    }
}

public protocol CredentialStore: Sendable {
    func store(
        _ envelope: CoreCredentialEnvelope,
        for reference: UUID
    ) async throws
    func load(for reference: UUID) async throws -> CoreCredentialEnvelope
    func delete(for reference: UUID) async throws
    func allReferences() async throws -> [UUID]
}

public protocol CredentialHelper: Sendable {
    func restore(reference: UUID, credential: Data) async throws
    func persisted(reference: UUID) async throws
    func persistFailed(reference: UUID) async
    func clear(reference: UUID) async throws
}

public enum CredentialReadiness: Equatable, Sendable {
    case ready
    case authenticationRequired
}

public enum CredentialCoordinationError: Error, Equatable, Sendable {
    case activeTurn
    case providerMismatch
    case persistenceFailed
    case invalidationPersistenceFailed
    case helperFailed
    case logoutIncompleteLocalCredentialRemains
}

public actor CredentialCoordinator {
    private let store: any CredentialStore
    private let helper: any CredentialHelper
    private let profiles: any ProviderProfileRepository

    public init(
        store: any CredentialStore,
        helper: any CredentialHelper,
        profiles: any ProviderProfileRepository
    ) {
        self.store = store
        self.helper = helper
        self.profiles = profiles
    }

    public func persistCandidate(
        _ envelope: CoreCredentialEnvelope,
        for reference: UUID,
        hasActiveTurn: Bool
    ) async throws {
        guard !hasActiveTurn else {
            throw CredentialCoordinationError.activeTurn
        }
        let profile = try await profile(for: reference)
        guard envelope.providerKind == profile.kind else {
            throw CredentialCoordinationError.providerMismatch
        }
        do {
            try await store.store(envelope, for: reference)
        } catch {
            var invalidationFailed = false
            do {
                try await profiles.setCredentialInvalidated(
                    true,
                    reference: reference
                )
            } catch {
                invalidationFailed = true
            }
            try? await store.delete(for: reference)
            await helper.persistFailed(reference: reference)
            if invalidationFailed {
                throw CredentialCoordinationError.invalidationPersistenceFailed
            }
            throw CredentialCoordinationError.persistenceFailed
        }
        do {
            try await profiles.setCredentialInvalidated(
                false,
                reference: reference
            )
        } catch {
            try? await store.delete(for: reference)
            await helper.persistFailed(reference: reference)
            throw CredentialCoordinationError.invalidationPersistenceFailed
        }

        do {
            try await helper.persisted(reference: reference)
        } catch {
            throw CredentialCoordinationError.helperFailed
        }
    }

    public func restore(reference: UUID) async throws -> CredentialReadiness {
        let profile = try await profile(for: reference)
        let invalidated = try await profiles.credentialIsInvalidated(
            reference: reference
        )
        guard !invalidated else {
            return .authenticationRequired
        }
        let envelope: CoreCredentialEnvelope
        do {
            envelope = try await store.load(for: reference)
        } catch CredentialError.itemNotFound {
            try await profiles.setCredentialInvalidated(true, reference: reference)
            return .authenticationRequired
        } catch {
            throw CredentialCoordinationError.persistenceFailed
        }
        guard envelope.providerKind == profile.kind else {
            try await profiles.setCredentialInvalidated(true, reference: reference)
            return .authenticationRequired
        }
        do {
            try await helper.restore(
                reference: reference,
                credential: envelope.payload
            )
            return .ready
        } catch {
            throw CredentialCoordinationError.helperFailed
        }
    }

    public func restoreSelectedProfile() async throws -> CredentialReadiness {
        guard let profile = try await profiles.selectedProviderProfile() else {
            return .authenticationRequired
        }
        return try await restore(reference: profile.credentialReference)
    }

    public func logout(reference: UUID, hasActiveTurn: Bool) async throws {
        guard !hasActiveTurn else {
            throw CredentialCoordinationError.activeTurn
        }
        try await profiles.setCredentialInvalidated(true, reference: reference)
        do {
            try await helper.clear(reference: reference)
        } catch {
            throw CredentialCoordinationError.helperFailed
        }
        do {
            try await store.delete(for: reference)
        } catch CredentialError.itemNotFound {
            return
        } catch {
            throw CredentialCoordinationError
                .logoutIncompleteLocalCredentialRemains
        }
    }

    private func profile(for reference: UUID) async throws -> ProviderProfile {
        guard let profile = try await profiles.providerProfiles().first(where: {
            $0.credentialReference == reference
        }) else {
            throw CredentialCoordinationError.providerMismatch
        }
        return profile
    }
}

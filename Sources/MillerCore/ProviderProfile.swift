import Foundation

public enum ProviderKind: String, Codable, Sendable {
    case codexOAuth = "codex_oauth"
    case openAICompatible = "openai_compatible"
}

public enum ProviderProfileError: Error, Equatable, Sendable {
    case invalidLabel
    case invalidEndpoint
    case invalidModel
    case profileNotFound
    case activeTurn
}

public struct ProviderProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: ProviderKind
    public let label: String
    public let baseURL: String?
    public let model: String
    public let credentialReference: UUID
    public let isSelected: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: ProviderKind,
        label: String,
        baseURL: String?,
        model: String,
        credentialReference: UUID = UUID(),
        isSelected: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw ProviderProfileError.invalidLabel
        }
        guard !normalizedModel.isEmpty else {
            throw ProviderProfileError.invalidModel
        }

        let normalizedBaseURL: String?
        switch kind {
        case .codexOAuth:
            guard baseURL == nil else {
                throw ProviderProfileError.invalidEndpoint
            }
            normalizedBaseURL = nil
        case .openAICompatible:
            guard let baseURL else {
                throw ProviderProfileError.invalidEndpoint
            }
            do {
                normalizedBaseURL = try EndpointPolicy.normalize(baseURL)
            } catch {
                throw ProviderProfileError.invalidEndpoint
            }
        }

        self.id = id
        self.kind = kind
        self.label = normalizedLabel
        self.baseURL = normalizedBaseURL
        self.model = normalizedModel
        self.credentialReference = credentialReference
        self.isSelected = isSelected
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func selected(_ selected: Bool, at date: Date = Date()) throws -> Self {
        try Self(
            id: id,
            kind: kind,
            label: label,
            baseURL: baseURL,
            model: model,
            credentialReference: credentialReference,
            isSelected: selected,
            createdAt: createdAt,
            updatedAt: date
        )
    }
}

public protocol ProviderProfileRepository: Sendable {
    func saveProviderProfile(_ profile: ProviderProfile) async throws
    func providerProfiles() async throws -> [ProviderProfile]
    func selectedProviderProfile() async throws -> ProviderProfile?
    func selectProviderProfile(id: UUID, hasActiveTurn: Bool) async throws
    func deleteProviderProfile(id: UUID) async throws
    func credentialIsInvalidated(reference: UUID) async throws -> Bool
    func setCredentialInvalidated(_ invalidated: Bool, reference: UUID) async throws
}

public actor ProviderProfileService {
    private let repository: any ProviderProfileRepository
    private let credentials: any CredentialStore

    public init(
        repository: any ProviderProfileRepository,
        credentials: any CredentialStore
    ) {
        self.repository = repository
        self.credentials = credentials
    }

    public func selectProfile(id: UUID, hasActiveTurn: Bool) async throws {
        guard !hasActiveTurn else {
            throw ProviderProfileError.activeTurn
        }
        try await repository.selectProviderProfile(id: id, hasActiveTurn: false)
    }

    public func deleteProfile(id: UUID, hasActiveTurn: Bool) async throws {
        guard !hasActiveTurn else {
            throw ProviderProfileError.activeTurn
        }
        guard let profile = try await repository.providerProfiles().first(where: {
            $0.id == id
        }) else {
            throw ProviderProfileError.profileNotFound
        }
        do {
            try await credentials.delete(for: profile.credentialReference)
        } catch CredentialError.itemNotFound {
            // Absence already satisfies local credential deletion.
        }
        try await repository.deleteProviderProfile(id: id)
    }
}

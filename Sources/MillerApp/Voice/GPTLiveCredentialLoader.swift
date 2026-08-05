import CoreFoundation
import Foundation
import MillerCore
import MillerLive

enum GPTLiveCredentialError: Error, Equatable, Sendable {
    case unavailable
    case invalidCredential
    case accountMismatch
    case reusedAccessToken
}

struct GPTLiveCredentialLoader: Sendable {
    private let loadEnvelope: @Sendable (UUID) async throws -> CredentialEnvelope

    init(
        load: @escaping @Sendable (UUID) async throws -> CredentialEnvelope
    ) {
        loadEnvelope = load
    }

    func load(profile: ProviderProfile) async throws -> CodexOAuthCredential {
        guard profile.isSelected, profile.kind == .codexOAuth else {
            throw GPTLiveCredentialError.unavailable
        }
        let envelope = try await loadEnvelope(profile.credentialReference)
        guard envelope.version == 1, envelope.providerKind == .codexOAuth,
              !envelope.payload.isEmpty, envelope.payload.count <= 65_536
        else { throw GPTLiveCredentialError.invalidCredential }

        var payload = envelope.payload
        defer { payload.resetBytes(in: payload.startIndex..<payload.endIndex) }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { throw GPTLiveCredentialError.invalidCredential }
            object = decoded
        } catch {
            throw GPTLiveCredentialError.invalidCredential
        }
        guard Set(object.keys) == ["type", "access", "refresh", "expires", "accountId"],
              object["type"] as? String == "oauth",
              let access = object["access"] as? String, !access.isEmpty,
              access.utf8.count <= 32_768,
              let refresh = object["refresh"] as? String, !refresh.isEmpty,
              refresh.utf8.count <= 32_768,
              let accountID = object["accountId"] as? String, !accountID.isEmpty,
              accountID.utf8.count <= 1_024,
              validExpiry(object["expires"])
        else { throw GPTLiveCredentialError.invalidCredential }
        return CodexOAuthCredential(
            accessToken: Data(access.utf8),
            accountID: accountID,
            planType: nil
        )
    }

    private func validExpiry(_ value: Any?) -> Bool {
        if value is NSNull { return true }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue > 0
        else { return false }
        return true
    }
}

import Foundation
import MillerCore
import MillerGateway

actor GatewayCredentialHelper: CredentialHelper {
    private let supervisor: GatewaySupervisor
    private var pendingAuthentication: GatewayAuthenticationOperation?

    init(supervisor: GatewaySupervisor) {
        self.supervisor = supervisor
    }

    func authenticate(
        reference: UUID,
        providerKind: ProviderKind,
        refresh: Bool = false,
        openURL: @escaping @Sendable (URL) async -> Void,
        persistCandidate: @escaping @Sendable (CoreCredentialEnvelope) async throws -> Void
    ) async throws {
        let source = if refresh {
            try await supervisor.refreshAuthentication(reference: reference)
        } else {
            try await supervisor.beginAuthentication(
                reference: reference,
                providerKind: providerKind.rawValue
            )
        }
        for try await event in source {
            switch event {
            case let .openURL(_, url):
                await openURL(url)
            case let .credentialCandidate(operation, payload):
                guard pendingAuthentication == nil else {
                    throw GatewayProtocolError.invalidSequence
                }
                pendingAuthentication = operation
                do {
                    try await persistCandidate(
                        CoreCredentialEnvelope(
                            providerKind: providerKind,
                            payload: payload
                        )
                    )
                } catch {
                    await persistFailed(reference: reference)
                    pendingAuthentication = nil
                    throw error
                }
            case let .completed(operation):
                guard pendingAuthentication == operation else {
                    throw GatewayProtocolError.invalidSequence
                }
                pendingAuthentication = nil
                return
            case let .stopped(operation):
                guard pendingAuthentication == nil || pendingAuthentication == operation else {
                    throw GatewayProtocolError.invalidSequence
                }
                pendingAuthentication = nil
                throw GatewayProtocolError.invalidSequence
            case let .failed(operation, code):
                guard pendingAuthentication == nil || pendingAuthentication == operation else {
                    throw GatewayProtocolError.invalidSequence
                }
                pendingAuthentication = nil
                throw GatewayProtocolError.authenticationFailed(code)
            }
        }
        throw GatewayProtocolError.invalidSequence
    }

    func readiness(
        for profile: ProviderProfile
    ) async throws -> GatewayProviderReadiness {
        try await supervisor.providerReadiness(
            profile: GatewayProviderProfile(
                kind: profile.kind.rawValue,
                baseURL: profile.baseURL,
                model: profile.model,
                credentialReference: profile.credentialReference
            )
        )
    }

    func codexModelCatalog() async throws -> GatewayModelCatalog {
        try await supervisor.codexModelCatalog()
    }

    func restore(reference: UUID, credential: Data) async throws {
        try await supervisor.restoreCredential(
            reference: reference,
            credential: credential
        )
    }

    func persisted(reference: UUID) async throws {
        guard let operation = pendingAuthentication,
              operation.credentialReference == reference
        else {
            throw GatewayProtocolError.invalidSequence
        }
        try await supervisor.acknowledgeAuthentication(operation, persisted: true)
    }

    func persistFailed(reference: UUID) async {
        guard let operation = pendingAuthentication,
              operation.credentialReference == reference
        else {
            return
        }
        try? await supervisor.acknowledgeAuthentication(operation, persisted: false)
    }

    func clear(reference: UUID) async throws {
        try await supervisor.clearCredential(reference: reference)
    }
}

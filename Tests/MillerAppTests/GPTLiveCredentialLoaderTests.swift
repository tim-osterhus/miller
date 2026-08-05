import Foundation
import MillerCore
import Testing
@testable import MillerApp

struct GPTLiveCredentialLoaderTests {
    @Test
    func loadsOnlyTheSelectedCodexEnvelopeWithExactFields() async throws {
        let reference = UUID()
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(#"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":4102444800000,"accountId":"synthetic-account"}"#.utf8)
        )
        let loader = GPTLiveCredentialLoader(load: { requested in
            #expect(requested == reference)
            return envelope
        })
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: reference,
            isSelected: true
        )

        let credential = try await loader.load(profile: profile)

        #expect(credential.accountID == "synthetic-account")
        #expect(credential.accessToken == Data("synthetic-access".utf8))
        #expect(credential.redactedDescription == "CodexOAuthCredential(redacted)")
    }

    @Test(arguments: [
        #"{"type":"oauth","access":"a","refresh":"r","expires":null}"#,
        #"{"type":"api_key","access":"a","refresh":"r","expires":null,"accountId":"account"}"#,
        #"{"type":"oauth","access":"","refresh":"r","expires":null,"accountId":"account"}"#,
        #"{"type":"oauth","access":"a","refresh":"r","expires":null,"accountId":"account","future":true}"#,
    ])
    func rejectsMalformedOrNonExactCredentialPayload(payload: String) async throws {
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(payload.utf8)
        )
        let loader = GPTLiveCredentialLoader(load: { _ in envelope })
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            isSelected: true
        )

        await #expect(throws: GPTLiveCredentialError.invalidCredential) {
            _ = try await loader.load(profile: profile)
        }
    }

    @Test
    func rejectsWrongProfileKindsAndUnselectedProfilesBeforeLoading() async throws {
        let loader = GPTLiveCredentialLoader(load: { _ in
            Issue.record("credential load must not be attempted")
            throw GPTLiveCredentialError.invalidCredential
        })
        let profile = try ProviderProfile(
            kind: .openAICompatible,
            label: "Other",
            baseURL: "https://example.invalid",
            model: "model",
            isSelected: true
        )

        await #expect(throws: GPTLiveCredentialError.unavailable) {
            _ = try await loader.load(profile: profile)
        }
    }
}

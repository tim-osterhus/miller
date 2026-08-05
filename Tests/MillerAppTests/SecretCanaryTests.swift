import Foundation
import MillerCore
import MillerStorage
import Testing
@testable import MillerApp

@Suite(.serialized)
struct SecretCanaryTests {
    @Test
    func credentialCanaryDoesNotReachProfileDatabaseOrErrors() async throws {
        let canary = "MILLER_SECRET_CANARY_\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-secret-canary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("miller.sqlite3")
        let repository = try SQLiteConversationRepository(path: databaseURL.path)
        let reference = UUID()
        let keychain = KeychainCredentialStore(
            service: "\(KeychainCredentialStore.service).tests.\(UUID().uuidString.lowercased())"
        )
        do {
            let envelope = try CredentialEnvelope(
                providerKind: .openAICompatible,
                payload: Data(canary.utf8)
            )
            try await keychain.save(envelope, for: reference)
            #expect(try await keychain.load(for: reference) == envelope)

            let profile = try ProviderProfile(
                kind: .openAICompatible,
                label: "Synthetic",
                baseURL: "https://example.invalid/",
                model: "fixture-model",
                credentialReference: reference,
                isSelected: true
            )
            try await repository.saveProviderProfile(profile)
            await repository.close()

            let storedBytes = try Data(contentsOf: databaseURL)
            #expect(!String(decoding: storedBytes, as: UTF8.self).contains(canary))
            #expect(
                !String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
                    .contains(canary)
            )
            #expect(!String(describing: CredentialError.storageFailed).contains(canary))
            #expect(!String(describing: ProviderProfileError.invalidEndpoint).contains(canary))
            #expect(!String(describing: profile).contains(canary))
        } catch {
            try? await keychain.deleteAll()
            throw error
        }

        try await keychain.deleteAll()
        #expect((try await keychain.allReferences()).isEmpty)
    }
}

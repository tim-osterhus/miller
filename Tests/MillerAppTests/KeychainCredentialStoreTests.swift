import Foundation
import MillerCore
import Security
import Testing
@testable import MillerApp

@Suite(.serialized)
struct KeychainCredentialStoreTests {
    @Test
    func addUpdateLookupDeleteAndMissingItem() async throws {
        try await withTestStore { store in
            let reference = UUID()

            let initial = try CredentialEnvelope(
                providerKind: .openAICompatible,
                payload: Data(#"{"kind":"api_key","key":"synthetic-one"}"#.utf8)
            )
            let updated = try CredentialEnvelope(
                providerKind: .openAICompatible,
                payload: Data(#"{"kind":"api_key","key":"synthetic-two"}"#.utf8)
            )

            try await store.save(initial, for: reference)
            #expect(try await store.load(for: reference) == initial)

            try await store.save(updated, for: reference)
            #expect(try await store.load(for: reference) == updated)
            #expect(try await store.allReferences() == [reference])

            try await store.delete(for: reference)
            await #expect(throws: CredentialError.itemNotFound) {
                _ = try await store.load(for: reference)
            }
            #expect((try await store.allReferences()).isEmpty)
            await #expect(throws: CredentialError.itemNotFound) {
                try await store.delete(for: reference)
            }
        }
    }

    @Test
    func corruptedEnvelopeFailsClosed() async throws {
        try await withTestStore { store in
            let reference = UUID()
            try await store.storeRawForTesting(
                Data("not-an-envelope".utf8),
                for: reference
            )

            await #expect(throws: CredentialError.storageFailed) {
                _ = try await store.load(for: reference)
            }
        }
    }

    @Test
    func envelopeRejectsPayloadLargerThanSixtyFourKiB() {
        #expect(throws: CredentialError.payloadTooLarge) {
            _ = try CredentialEnvelope(
                providerKind: .codexOAuth,
                payload: Data(repeating: 0x61, count: 65_537)
            )
        }
    }

    @Test
    func queryUsesExactMillerAttributesAndLowercaseAccount() {
        let reference = UUID()
        let query = KeychainCredentialStore.query(
            service: KeychainCredentialStore.service,
            reference: reference
        )

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(
            query[kSecAttrService as String] as? String
                == "ai.millrace.miller.credentials"
        )
        #expect(
            query[kSecAttrAccount as String] as? String
                == reference.uuidString.lowercased()
        )
        #expect(
            query[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(query[kSecValueData as String] == nil)
        #expect(query[kSecReturnData as String] == nil)
    }

    private func testService() -> String {
        "\(KeychainCredentialStore.service).tests.\(UUID().uuidString.lowercased())"
    }

    private func withTestStore(
        _ operation: (KeychainCredentialStore) async throws -> Void
    ) async throws {
        let store = KeychainCredentialStore(service: testService())
        do {
            try await operation(store)
        } catch {
            try? await store.deleteAll()
            throw error
        }
        try await store.deleteAll()
        #expect((try await store.allReferences()).isEmpty)
    }
}

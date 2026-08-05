import Foundation
import MillerCore
import Security

public struct KeychainCredentialStore: CredentialStore, Sendable {
    public static let service = "ai.millrace.miller.credentials"

    private let serviceName: String

    public init(service: String = KeychainCredentialStore.service) {
        serviceName = service
    }

    public func save(
        _ envelope: CredentialEnvelope,
        for reference: UUID
    ) async throws {
        try await store(envelope, for: reference)
    }

    public func store(
        _ envelope: CredentialEnvelope,
        for reference: UUID
    ) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            throw CredentialError.storageFailed
        }
        try storeData(data, for: reference)
    }

    public func load(for reference: UUID) async throws -> CredentialEnvelope {
        let data = try await loadData(for: reference)
        do {
            let envelope = try JSONDecoder().decode(CredentialEnvelope.self, from: data)
            guard envelope.version == 1, envelope.payload.count <= 65_536 else {
                throw CredentialError.storageFailed
            }
            return envelope
        } catch let error as CredentialError {
            throw error
        } catch {
            throw CredentialError.storageFailed
        }
    }

    private func storeData(_ data: Data, for reference: UUID) throws {
        let match = Self.query(service: serviceName, reference: reference)
        var item = match
        item[kSecValueData as String] = data
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let status = SecItemUpdate(
                match as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw CredentialError.storageFailed
            }
        default:
            throw CredentialError.storageFailed
        }
    }

    private func loadData(for reference: UUID) async throws -> Data {
        var query = Self.query(service: serviceName, reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw CredentialError.storageFailed
            }
            return data
        case errSecItemNotFound:
            throw CredentialError.itemNotFound
        default:
            throw CredentialError.storageFailed
        }
    }

    public func delete(for reference: UUID) async throws {
        switch SecItemDelete(
            Self.query(service: serviceName, reference: reference) as CFDictionary
        ) {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw CredentialError.itemNotFound
        default:
            throw CredentialError.deletionFailed
        }
    }

    public func allReferences() async throws -> [UUID] {
        var query = Self.serviceQuery(service: serviceName)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            let items: [[String: Any]]
            if let values = result as? [[String: Any]] {
                items = values
            } else if let value = result as? [String: Any] {
                items = [value]
            } else {
                throw CredentialError.storageFailed
            }
            return items.compactMap {
                ($0[kSecAttrAccount as String] as? String)
                    .flatMap(UUID.init(uuidString:))
            }.sorted { $0.uuidString < $1.uuidString }
        case errSecItemNotFound:
            return []
        default:
            throw CredentialError.storageFailed
        }
    }

    public func deleteAll() async throws {
        switch SecItemDelete(Self.serviceQuery(service: serviceName) as CFDictionary) {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw CredentialError.deletionFailed
        }
    }

    func storeRawForTesting(_ data: Data, for reference: UUID) async throws {
        try storeData(data, for: reference)
    }

    static func query(service: String, reference: UUID) -> [String: Any] {
        var query = serviceQuery(service: service)
        query[kSecAttrAccount as String] = reference.uuidString.lowercased()
        return query
    }

    private static func serviceQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

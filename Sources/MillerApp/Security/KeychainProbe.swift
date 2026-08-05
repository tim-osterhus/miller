import Foundation
import Security

struct KeychainProbe {
    static let service = "ai.millrace.miller.credentials.probe"

    func run() throws {
        let account = UUID().uuidString.lowercased()
        let initial = Data("miller-keychain-probe".utf8)
        let updated = Data("miller-keychain-probe-updated".utf8)
        let query = Self.query(account: account)

        defer {
            SecItemDelete(query as CFDictionary)
        }

        var add = query
        add[kSecValueData as String] = initial
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw ProbeError.add
        }

        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &value) == errSecSuccess,
              value as? Data == initial
        else {
            throw ProbeError.read
        }

        guard SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: updated] as CFDictionary
        ) == errSecSuccess else {
            throw ProbeError.update
        }

        value = nil
        guard SecItemCopyMatching(read as CFDictionary, &value) == errSecSuccess,
              value as? Data == updated
        else {
            throw ProbeError.read
        }

        guard SecItemDelete(query as CFDictionary) == errSecSuccess,
              SecItemCopyMatching(read as CFDictionary, nil) == errSecItemNotFound
        else {
            throw ProbeError.delete
        }
    }

    static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
    }

    enum ProbeError: Error {
        case add
        case read
        case update
        case delete
    }
}

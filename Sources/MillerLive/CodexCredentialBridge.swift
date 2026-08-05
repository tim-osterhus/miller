import Foundation

public struct CodexOAuthCredential: Sendable, CustomStringConvertible {
    public let accessToken: Data
    public let accountID: String
    public let planType: String?

    public init(accessToken: Data, accountID: String, planType: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.planType = planType
    }

    public var redactedDescription: String {
        "CodexOAuthCredential(redacted)"
    }

    public var description: String { redactedDescription }
}

public enum CredentialBridgeError: Error, Equatable, Sendable {
    case invalidUTF8
    case accountMismatch
    case invalidCredential
}

public struct CodexCredentialBridge: Sendable {
    public init() {}

    public func loginRequest(id: String, credential: CodexOAuthCredential) throws -> Data {
        guard let token = String(data: credential.accessToken, encoding: .utf8),
              !token.isEmpty, !credential.accountID.isEmpty
        else { throw CredentialBridgeError.invalidCredential }
        var params: [String: Any] = [
            "type": "chatgptAuthTokens",
            "accessToken": token,
            "chatgptAccountId": credential.accountID,
        ]
        params["chatgptPlanType"] = credential.planType ?? NSNull()
        return try encode([
            "id": id,
            "method": "account/login/start",
            "params": params,
        ])
    }

    public func refreshResponse(
        id: JSONRPCRequestID,
        previousAccountID: String?,
        credential: CodexOAuthCredential
    ) throws -> Data {
        if let previousAccountID, previousAccountID != credential.accountID {
            throw CredentialBridgeError.accountMismatch
        }
        guard let token = String(data: credential.accessToken, encoding: .utf8),
              !token.isEmpty
        else { throw CredentialBridgeError.invalidUTF8 }
        var result: [String: Any] = [
            "accessToken": token,
            "chatgptAccountId": credential.accountID,
        ]
        result["chatgptPlanType"] = credential.planType ?? NSNull()
        let encodedID: Any
        switch id {
        case let .string(value): encodedID = value
        case let .integer(value): encodedID = value
        }
        return try encode(["id": encodedID, "result": result])
    }

    private func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([0x0A])
    }
}

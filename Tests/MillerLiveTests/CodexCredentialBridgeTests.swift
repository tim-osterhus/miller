@testable import MillerLive
import Foundation
import Testing

struct CodexCredentialBridgeTests {
    @Test
    func emitsExactPinnedInMemoryLoginWithoutSecretDiagnostics() throws {
        let secret = Data("synthetic-access-token".utf8)
        let credential = CodexOAuthCredential(
            accessToken: secret,
            accountID: "synthetic-account",
            planType: "plus"
        )
        let bridge = CodexCredentialBridge()
        let data = try bridge.loginRequest(id: "request:login", credential: credential)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        #expect(object["method"] as? String == "account/login/start")
        #expect(params["type"] as? String == "chatgptAuthTokens")
        #expect(params["accessToken"] as? String == "synthetic-access-token")
        #expect(params["chatgptAccountId"] as? String == "synthetic-account")
        #expect(credential.redactedDescription == "CodexOAuthCredential(redacted)")
        #expect(!credential.redactedDescription.contains("synthetic"))
    }

    @Test
    func refreshIsFencedToTheAdmittedAccount() throws {
        let bridge = CodexCredentialBridge()
        let credential = CodexOAuthCredential(
            accessToken: Data("replacement".utf8),
            accountID: "account-1",
            planType: nil
        )
        #expect(throws: CredentialBridgeError.accountMismatch) {
            try bridge.refreshResponse(
                id: .string("server-refresh"),
                previousAccountID: "account-other",
                credential: credential
            )
        }
        let response = try bridge.refreshResponse(
            id: .string("server-refresh"),
            previousAccountID: "account-1",
            credential: credential
        )
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        #expect(object["id"] as? String == "server-refresh")
        #expect(object["result"] is [String: Any])
    }
}

public enum CoreError: Error, Equatable, Sendable {
    case illegalTransition(from: TurnState, event: String)
    case generationMismatch(expected: Int, received: Int)
    case turnAlreadyTerminal
    case turnAlreadyActive
    case requestTooLarge
    case storageUnavailable
}

public struct MillerFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String) {
        let pair = Self.allowlistedPair(for: code)
        self.code = pair.code
        self.message = pair.message
    }

    private static func allowlistedPair(
        for code: String
    ) -> (code: String, message: String) {
        switch code {
        case "gateway_unavailable":
            ("gateway_unavailable", "The reasoning service is unavailable. Try again.")
        case "interrupted_by_relaunch":
            ("interrupted_by_relaunch", "The request was interrupted. Try again.")
        case "authentication_expired":
            ("authentication_expired", "Authentication expired. Reconnect the provider.")
        case "authentication_required":
            ("authentication_required", "Authentication is required. Connect the provider.")
        case "configuration_invalid":
            ("configuration_invalid", "The provider configuration is invalid.")
        case "network_unavailable":
            ("network_unavailable", "The network is unavailable. Try again.")
        case "provider_unavailable":
            ("provider_unavailable", "The provider is unavailable. Try again.")
        case "capability_timeout":
            ("capability_timeout", "A tool timed out. Try again.")
        case "unsupported_model":
            ("unsupported_model", "The selected model is not supported.")
        case "request_too_large":
            ("request_too_large", "The request is too large. Shorten it and try again.")
        case "storage_unavailable":
            ("storage_unavailable", "Storage is unavailable. Resolve the storage problem.")
        default:
            ("failed", "The request failed. Try again.")
        }
    }
}

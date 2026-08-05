import Foundation

public enum EndpointPolicyError: Error, Equatable, Sendable {
    case invalidEndpoint
    case insecureRemoteEndpoint
    case redirectNotAllowed
}

public enum EndpointPolicy {
    public static func normalize(_ value: String) throws -> String {
        guard var components = URLComponents(string: value),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw EndpointPolicyError.invalidEndpoint
        }

        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw EndpointPolicyError.invalidEndpoint
        }
        if scheme == "http", !isNumericLoopback(host) {
            throw EndpointPolicyError.insecureRemoteEndpoint
        }

        components.scheme = scheme
        components.host = host
        components.path = ""
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        guard let normalized = components.url?.absoluteString,
              !normalized.isEmpty
        else {
            throw EndpointPolicyError.invalidEndpoint
        }
        return normalized.hasSuffix("/")
            ? String(normalized.dropLast())
            : normalized
    }

    public static func validateAuthenticatedRedirect(
        from _: URL,
        to _: URL
    ) throws {
        throw EndpointPolicyError.redirectNotAllowed
    }

    private static func isNumericLoopback(_ host: String) -> Bool {
        if host == "::1" || host == "[::1]" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }
        var values: [Int] = []
        for octet in octets {
            guard !octet.isEmpty,
                  octet.allSatisfy(\.isNumber),
                  octet.count == 1 || octet.first != "0",
                  let value = Int(octet),
                  value <= 255
            else {
                return false
            }
            values.append(value)
        }
        return values[0] == 127
    }
}

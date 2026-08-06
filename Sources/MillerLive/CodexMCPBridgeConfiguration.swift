import Foundation

public struct CodexMCPBridgeConfiguration: Equatable, Sendable {
    public static let serverName = "miller-capability-bridge"

    public let executableURL: URL
    public let additionalEnvironment: [String: String]

    public init(
        executableURL: URL,
        socketPath: String,
        sessionToken: String,
        providerProfileID: UUID,
        trustedParentPath: String
    ) throws {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              Self.safePath(executableURL.path),
              socketPath.hasPrefix("/"), Self.safeEnvironmentValue(socketPath),
              let token = Data(base64Encoded: sessionToken), token.count == 32,
              Self.safeEnvironmentValue(sessionToken),
              trustedParentPath.hasPrefix("/"), Self.safeEnvironmentValue(trustedParentPath)
        else { throw LiveProcessError.invalidConfiguration }
        self.executableURL = executableURL.standardizedFileURL
        additionalEnvironment = [
            "MILLER_CAPABILITY_RPC_SOCKET": socketPath,
            "MILLER_CAPABILITY_RPC_TOKEN": sessionToken,
            "MILLER_CAPABILITY_PROVIDER_PROFILE_ID": providerProfileID.uuidString.lowercased(),
            "MILLER_CAPABILITY_RPC_TRUSTED_PARENT": trustedParentPath,
        ]
    }

    /// Codex's stable MCP configuration surface. Sensitive bridge values are
    /// inherited by name from the child environment and never serialized into
    /// arguments or `config.toml`.
    public func appServerArguments() -> [String] {
        let command = Self.tomlString(executableURL.path)
        let names = additionalEnvironment.keys.sorted().map(Self.tomlString).joined(separator: ", ")
        return [
            "-c", "mcp_servers.\(Self.serverName).command=\(command)",
            "-c", "mcp_servers.\(Self.serverName).env_vars=[\(names)]",
            "-c", "mcp_servers.\(Self.serverName).required=true",
            "app-server", "--listen", "stdio://", "--strict-config",
        ]
    }

    private static func safePath(_ value: String) -> Bool {
        safeEnvironmentValue(value) && !value.contains("\"") && !value.contains("\\")
    }

    private static func safeEnvironmentValue(_ value: String) -> Bool {
        value.utf8.count <= 4_096 && !value.utf8.contains(0)
            && !value.contains("\n") && !value.contains("\r")
    }

    private static func tomlString(_ value: String) -> String { "\"\(value)\"" }
}

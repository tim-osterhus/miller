import Foundation
import MillerCore

public enum MCPConfigurationError: Error, Equatable, Sendable {
    case invalidServerID
    case duplicateServerID(String)
    case invalidDisplayName
    case invalidExecutable
    case unsafeArgument
    case invalidEndpoint
    case invalidSecretBinding
    case invalidBounds
}

public struct MCPBounds: Hashable, Sendable {
    public static let standard = MCPBounds()

    public let startupTimeout: Duration
    public let callTimeout: Duration
    public let maximumTools: Int
    public let maximumSchemaBytes: Int
    public let maximumArgumentBytes: Int
    public let maximumResultBytes: Int
    public let maximumStderrBytes: Int

    public init(
        startupTimeout: Duration = .seconds(10),
        callTimeout: Duration = .seconds(60),
        maximumTools: Int = 2_048,
        maximumSchemaBytes: Int = 64 * 1_024,
        maximumArgumentBytes: Int = 64 * 1_024,
        maximumResultBytes: Int = 256 * 1_024,
        maximumStderrBytes: Int = 8 * 1_024
    ) {
        self.startupTimeout = startupTimeout
        self.callTimeout = callTimeout
        self.maximumTools = maximumTools
        self.maximumSchemaBytes = maximumSchemaBytes
        self.maximumArgumentBytes = maximumArgumentBytes
        self.maximumResultBytes = maximumResultBytes
        self.maximumStderrBytes = maximumStderrBytes
    }

    func validate() throws {
        guard startupTimeout > .zero, startupTimeout <= .seconds(10),
              callTimeout > .zero, callTimeout <= .seconds(60),
              maximumTools > 0, maximumTools <= 2_048,
              maximumSchemaBytes > 0, maximumSchemaBytes <= 64 * 1_024,
              maximumArgumentBytes > 0, maximumArgumentBytes <= 64 * 1_024,
              maximumResultBytes > 0, maximumResultBytes <= 256 * 1_024,
              maximumStderrBytes > 0, maximumStderrBytes <= 8 * 1_024
        else { throw MCPConfigurationError.invalidBounds }
    }
}

public enum MCPServerTransport: Hashable, Codable, Sendable {
    case stdio(executable: String, arguments: [String])
    case http(endpoint: URL)
}

public enum MCPSecretDestination: String, Codable, Sendable {
    case environment
    case header
}

public struct MCPSecretBinding: Hashable, Codable, Sendable {
    public let destination: MCPSecretDestination
    public let name: String
    public let credentialReference: UUID

    public init(
        destination: MCPSecretDestination,
        name: String,
        credentialReference: UUID
    ) throws {
        let scalars = name.unicodeScalars
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.contains("\0"),
              scalars.allSatisfy({ $0.isASCII && $0.value >= 33 && $0.value <= 126 })
        else { throw MCPConfigurationError.invalidSecretBinding }
        if destination == .environment {
            guard name.first?.isLetter == true,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { throw MCPConfigurationError.invalidSecretBinding }
        } else {
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
            else { throw MCPConfigurationError.invalidSecretBinding }
        }
        self.destination = destination
        self.name = name
        self.credentialReference = credentialReference
    }

    private enum CodingKeys: CodingKey {
        case destination, name, credentialReference
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            destination: container.decode(
                MCPSecretDestination.self, forKey: .destination
            ),
            name: container.decode(String.self, forKey: .name),
            credentialReference: container.decode(
                UUID.self, forKey: .credentialReference
            )
        )
    }
}

public struct MCPServerConfiguration: Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let transport: MCPServerTransport
    public let secrets: [MCPSecretBinding]
    public let enabled: Bool
    public let defaultPolicy: CapabilityPolicy
    public let providerProfileIDs: Set<UUID>
    public let bounds: MCPBounds

    public init(
        id: String,
        displayName: String,
        transport: MCPServerTransport,
        secrets: [MCPSecretBinding] = [],
        enabled: Bool = false,
        defaultPolicy: CapabilityPolicy = .askBeforeChanges,
        providerProfileIDs: Set<UUID> = [],
        bounds: MCPBounds = .standard
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedID.isEmpty, normalizedID.utf8.count <= 96,
              normalizedID.unicodeScalars.allSatisfy({
                  $0.isASCII && (($0.value >= 97 && $0.value <= 122)
                      || ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "_")
              })
        else { throw MCPConfigurationError.invalidServerID }
        guard !displayName.isEmpty, displayName.utf8.count <= 128,
              !displayName.contains("\0")
        else { throw MCPConfigurationError.invalidDisplayName }
        try Self.validate(transport)
        try bounds.validate()
        var bindingKeys = Set<String>()
        for binding in secrets {
            let key = "\(binding.destination.rawValue):\(binding.name.lowercased())"
            guard bindingKeys.insert(key).inserted else {
                throw MCPConfigurationError.invalidSecretBinding
            }
        }
        self.id = normalizedID
        self.displayName = displayName
        self.transport = transport
        self.secrets = secrets
        self.enabled = enabled
        self.defaultPolicy = defaultPolicy
        self.providerProfileIDs = providerProfileIDs
        self.bounds = bounds
    }

    public static func validateUnique(
        _ configurations: [MCPServerConfiguration]
    ) throws {
        var ids = Set<String>()
        for configuration in configurations {
            guard ids.insert(configuration.id).inserted else {
                throw MCPConfigurationError.duplicateServerID(configuration.id)
            }
        }
    }

    private static func validate(_ transport: MCPServerTransport) throws {
        switch transport {
        case .stdio(let executable, let arguments):
            guard executable.hasPrefix("/"), executable.utf8.count <= 4_096,
                  !executable.contains("\0")
            else { throw MCPConfigurationError.invalidExecutable }
            guard arguments.count <= 256 else { throw MCPConfigurationError.unsafeArgument }
            for argument in arguments {
                guard argument.utf8.count <= 16 * 1_024,
                      !argument.contains("\0")
                else { throw MCPConfigurationError.unsafeArgument }
            }
        case .http(let endpoint):
            guard endpoint.user == nil, endpoint.password == nil,
                  endpoint.fragment == nil,
                  let scheme = endpoint.scheme?.lowercased(),
                  let host = endpoint.host?.lowercased()
            else { throw MCPConfigurationError.invalidEndpoint }
            let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
            guard scheme == "https" || (scheme == "http" && loopback) else {
                throw MCPConfigurationError.invalidEndpoint
            }
        }
    }

    private enum CodingKeys: CodingKey {
        case id, displayName, transport, secrets, enabled, defaultPolicy
        case providerProfileIDs, bounds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            displayName: container.decode(String.self, forKey: .displayName),
            transport: container.decode(MCPServerTransport.self, forKey: .transport),
            secrets: container.decode([MCPSecretBinding].self, forKey: .secrets),
            enabled: container.decode(Bool.self, forKey: .enabled),
            defaultPolicy: container.decode(CapabilityPolicy.self, forKey: .defaultPolicy),
            providerProfileIDs: container.decode(Set<UUID>.self, forKey: .providerProfileIDs),
            bounds: container.decode(MCPBounds.self, forKey: .bounds)
        )
    }
}

extension MCPBounds: Codable {
    private enum CodingKeys: CodingKey {
        case startupTimeout, callTimeout, maximumTools, maximumSchemaBytes
        case maximumArgumentBytes, maximumResultBytes, maximumStderrBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startupTimeout: try container.decode(Duration.self, forKey: .startupTimeout),
            callTimeout: try container.decode(Duration.self, forKey: .callTimeout),
            maximumTools: try container.decode(Int.self, forKey: .maximumTools),
            maximumSchemaBytes: try container.decode(
                Int.self, forKey: .maximumSchemaBytes
            ),
            maximumArgumentBytes: try container.decode(
                Int.self, forKey: .maximumArgumentBytes
            ),
            maximumResultBytes: try container.decode(
                Int.self, forKey: .maximumResultBytes
            ),
            maximumStderrBytes: try container.decode(
                Int.self, forKey: .maximumStderrBytes
            )
        )
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startupTimeout, forKey: .startupTimeout)
        try container.encode(callTimeout, forKey: .callTimeout)
        try container.encode(maximumTools, forKey: .maximumTools)
        try container.encode(maximumSchemaBytes, forKey: .maximumSchemaBytes)
        try container.encode(maximumArgumentBytes, forKey: .maximumArgumentBytes)
        try container.encode(maximumResultBytes, forKey: .maximumResultBytes)
        try container.encode(maximumStderrBytes, forKey: .maximumStderrBytes)
    }
}

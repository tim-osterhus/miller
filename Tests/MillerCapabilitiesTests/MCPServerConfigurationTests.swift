import Foundation
@testable import MillerCapabilities
import Testing

@Suite
struct MCPServerConfigurationTests {
    @Test
    func stdioRequiresAbsoluteExecutableAndLiteralArguments() throws {
        #expect(throws: MCPConfigurationError.self) {
            try MCPServerConfiguration(
                id: "notes", displayName: "Notes",
                transport: .stdio(executable: "node", arguments: [])
            )
        }
        let configuration = try MCPServerConfiguration(
            id: "NOTES", displayName: "Notes",
            transport: .stdio(
                executable: "/usr/bin/env",
                arguments: ["node", "$(remains-literal)", "server.mjs"]
            )
        )
        #expect(configuration.id == "notes")
        guard case .stdio(_, let arguments) = configuration.transport else {
            Issue.record("Expected stdio transport")
            return
        }
        #expect(arguments == ["node", "$(remains-literal)", "server.mjs"])
    }

    @Test
    func remoteHTTPRequiresHTTPSExceptLoopbackFixtures() throws {
        #expect(throws: MCPConfigurationError.self) {
            try MCPServerConfiguration(
                id: "remote", displayName: "Remote",
                transport: .http(endpoint: URL(string: "http://example.com/mcp")!)
            )
        }
        _ = try MCPServerConfiguration(
            id: "secure", displayName: "Secure",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!)
        )
        _ = try MCPServerConfiguration(
            id: "fixture", displayName: "Fixture",
            transport: .http(endpoint: URL(string: "http://127.0.0.1:9182/mcp")!)
        )
    }

    @Test
    func validatesUniqueIDsKeychainBindingsAndExplicitBounds() throws {
        let reference = UUID()
        let first = try MCPServerConfiguration(
            id: "notes", displayName: "Notes",
            transport: .stdio(executable: "/usr/bin/env", arguments: ["node"]),
            secrets: [
                try MCPSecretBinding(
                    destination: .environment, name: "NOTES_TOKEN",
                    credentialReference: reference
                ),
            ]
        )
        let duplicate = try MCPServerConfiguration(
            id: "NOTES", displayName: "Duplicate",
            transport: .stdio(executable: "/usr/bin/env", arguments: [])
        )
        #expect(throws: MCPConfigurationError.duplicateServerID("notes")) {
            try MCPServerConfiguration.validateUnique([first, duplicate])
        }
        #expect(first.secrets.first?.credentialReference == reference)
        #expect(MCPBounds.standard.startupTimeout == .seconds(10))
        #expect(MCPBounds.standard.callTimeout == .seconds(60))
        #expect(MCPBounds.standard.maximumTools == 2_048)
        #expect(MCPBounds.standard.maximumSchemaBytes == 64 * 1_024)
        #expect(MCPBounds.standard.maximumArgumentBytes == 64 * 1_024)
        #expect(MCPBounds.standard.maximumResultBytes == 256 * 1_024)
        #expect(MCPBounds.standard.maximumStderrBytes == 8 * 1_024)
    }

    @Test
    func timeoutBoundsAcceptCeilingsAndRejectAnythingAboveThem() throws {
        _ = try MCPServerConfiguration(
            id: "boundary", displayName: "Boundary",
            transport: .stdio(executable: "/usr/bin/env", arguments: []),
            bounds: MCPBounds(
                startupTimeout: .seconds(10),
                callTimeout: .seconds(60)
            )
        )

        for bounds in [
            MCPBounds(
                startupTimeout: .seconds(10) + .nanoseconds(1),
                callTimeout: .seconds(60)
            ),
            MCPBounds(
                startupTimeout: .seconds(10),
                callTimeout: .seconds(60) + .nanoseconds(1)
            ),
            MCPBounds(startupTimeout: .zero),
            MCPBounds(callTimeout: .zero),
        ] {
            #expect(throws: MCPConfigurationError.invalidBounds) {
                try MCPServerConfiguration(
                    id: "invalid", displayName: "Invalid",
                    transport: .stdio(
                        executable: "/usr/bin/env", arguments: []
                    ),
                    bounds: bounds
                )
            }
        }
    }

    @Test
    func stdioEnvironmentDoesNotInheritUnboundCredentials() {
        let environment = MCPClientSession.safeBaseEnvironment(from: [
            "PATH": "/usr/bin",
            "HOME": "/tmp/home",
            "TMPDIR": "/tmp",
            "LANG": "en_US.UTF-8",
            "DEEPSEEK_API_KEY": "secret",
            "SSH_AUTH_SOCK": "/tmp/agent.sock",
            "UNRELATED_TOKEN": "secret",
        ])
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/tmp/home")
        #expect(environment["DEEPSEEK_API_KEY"] == nil)
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["UNRELATED_TOKEN"] == nil)
    }
}

import Foundation
import MCP
@testable import MillerCapabilities
@testable import MillerCapabilityBridge
import MillerCore
import Testing

@Suite(.serialized)
struct MillerCapabilityBridgeTests {
    @Test
    func projectsBrokerCatalogAndForwardsCallsOverRPC() async throws {
        let root = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appending(path: "miller-bridge-test-\(UUID().uuidString)")
        let profileID = UUID()
        let descriptor = try makeBridgeDescriptor(profileID: profileID)
        let callProbe = BridgeCallProbe()
        let rpcServer = CapabilityRPCServer(runtimeRoot: root) { request in
            switch request {
            case .list(let receivedProfileID):
                return receivedProfileID == profileID
                    ? .catalog([descriptor])
                    : .failed(nil, code: "profile_mismatch")
            case .call(let callID, let capabilityID, let argumentsJSON):
                await callProbe.record(
                    callID: callID,
                    capabilityID: capabilityID,
                    argumentsJSON: argumentsJSON
                )
                return .result(
                    callID,
                    contentJSON: Data(
                        #"{"content":[{"type":"text","text":"bridge-ok"}],"isError":false}"#.utf8
                    ),
                    isError: false
                )
            case .cancel(let callID):
                return .failed(callID, code: "cancelled")
            }
        }
        let endpoint = try await rpcServer.start()
        defer { Task { await rpcServer.stop() } }

        let runtime = MillerCapabilityBridgeRuntime(
            rpcClient: CapabilityRPCClient(endpoint: endpoint, timeout: .seconds(1)),
            providerProfileID: profileID
        )
        let server = await runtime.makeServer()
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: transports.server)
        let client = Client(
            name: "bridge-test", version: "1.0", configuration: .strict
        )
        _ = try await client.connect(transport: transports.client)

        let tools = try await client.listTools().tools
        #expect(tools.count == 1)
        let tool = try #require(tools.first)
        #expect(tool.name.hasPrefix("miller_"))
        #expect(tool.title == "Lookup")
        #expect(tool.description == "Looks up a value")
        #expect(tool.annotations.readOnlyHint == true)

        let result = try await client.callTool(
            name: tool.name,
            arguments: ["query": .string("value")]
        ).value
        #expect(result.isError == false)
        #expect(result.content == [
            .text(text: "bridge-ok", annotations: nil, _meta: nil),
        ])
        #expect(await callProbe.capabilityID == descriptor.id)
        #expect(await callProbe.argumentsJSON != nil)

        await client.disconnect()
        await server.stop()
        await rpcServer.stop()
    }

    @Test
    func rejectsMissingOrInvalidProcessLifetimeConfiguration() throws {
        #expect(throws: MillerCapabilityBridgeError.invalidEnvironment) {
            _ = try MillerCapabilityBridgeRuntime(environment: [:])
        }
        #expect(throws: MillerCapabilityBridgeError.invalidEnvironment) {
            _ = try MillerCapabilityBridgeRuntime(environment: [
                CapabilityRPCEnvironment.socketPath: "/tmp/socket",
                CapabilityRPCEnvironment.sessionToken: "not-a-token",
                CapabilityRPCEnvironment.providerProfileID: UUID().uuidString,
            ])
        }
    }

    @Test
    func unknownProjectedToolIsRejectedWithoutRPCExecution() async throws {
        let root = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appending(path: "miller-bridge-unknown-\(UUID().uuidString)")
        let profileID = UUID()
        let rpcServer = CapabilityRPCServer(runtimeRoot: root) { request in
            switch request {
            case .list: .catalog([])
            case .call(let callID, _, _): .failed(callID, code: "unexpected_call")
            case .cancel(let callID): .failed(callID, code: "cancelled")
            }
        }
        let endpoint = try await rpcServer.start()
        let runtime = MillerCapabilityBridgeRuntime(
            rpcClient: CapabilityRPCClient(endpoint: endpoint, timeout: .seconds(1)),
            providerProfileID: profileID
        )
        let server = await runtime.makeServer()
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: transports.server)
        let client = Client(name: "bridge-test", version: "1.0")
        _ = try await client.connect(transport: transports.client)

        let result = try await client.callTool(name: "not_cataloged").value
        #expect(result.isError == true)

        await client.disconnect()
        await server.stop()
        await rpcServer.stop()
    }
}

private actor BridgeCallProbe {
    private(set) var callID: CapabilityCallID?
    private(set) var capabilityID: CapabilityID?
    private(set) var argumentsJSON: Data?

    func record(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        argumentsJSON: Data
    ) {
        self.callID = callID
        self.capabilityID = capabilityID
        self.argumentsJSON = argumentsJSON
    }
}

private func makeBridgeDescriptor(profileID: UUID) throws -> CapabilityDescriptor {
    let id = try CapabilityID(
        source: .millerMCP, serverID: "local", toolName: "lookup"
    )
    return try CapabilityDescriptor(
        id: id,
        source: .millerMCP,
        serverID: "local",
        toolName: "lookup",
        displayName: "Lookup",
        summary: "Looks up a value",
        inputSchemaJSON: Data(
            #"{"type":"object","properties":{"query":{"type":"string"}}}"#.utf8
        ),
        readOnlyHint: true,
        providerProfileIDs: [profileID],
        isAvailable: true
    )
}

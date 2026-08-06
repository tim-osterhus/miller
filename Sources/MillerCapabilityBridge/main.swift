import Foundation
import MCP
import MillerCapabilities
import MillerCore

public enum MillerCapabilityBridgeError: Error, Equatable, Sendable {
    case invalidEnvironment
    case brokerUnavailable
    case invalidCatalog
    case invalidResult
}

public struct MillerCapabilityBridgeRuntime: Sendable {
    private let rpcClient: CapabilityRPCClient
    private let providerProfileID: UUID
    private let trustedParent: URL?
    private let catalog = ProjectedCapabilityCatalog()

    public init(
        rpcClient: CapabilityRPCClient,
        providerProfileID: UUID
    ) {
        self.rpcClient = rpcClient
        self.providerProfileID = providerProfileID
        self.trustedParent = nil
    }

    public init(environment: [String: String]) throws {
        guard let socketPath = environment[CapabilityRPCEnvironment.socketPath],
              socketPath.hasPrefix("/"), !socketPath.contains("\0"),
              let tokenValue = environment[CapabilityRPCEnvironment.sessionToken],
              let profileValue = environment[
                CapabilityRPCEnvironment.providerProfileID
              ],
              let profileID = UUID(uuidString: profileValue),
              let trustedParentPath = environment[
                CapabilityRPCEnvironment.trustedParent
              ],
              trustedParentPath.hasPrefix("/"),
              !trustedParentPath.contains("\0")
        else { throw MillerCapabilityBridgeError.invalidEnvironment }
        let token: CapabilityRPCSessionToken
        do { token = try CapabilityRPCSessionToken(environmentValue: tokenValue) }
        catch { throw MillerCapabilityBridgeError.invalidEnvironment }
        let socketURL = URL(filePath: socketPath)
        let trustedParent = URL(
            filePath: trustedParentPath,
            directoryHint: .isDirectory
        )
        do {
            try CapabilityRPCRuntime.validateEndpoint(
                socketURL: socketURL,
                trustedParent: trustedParent
            )
        } catch {
            throw MillerCapabilityBridgeError.invalidEnvironment
        }
        self.rpcClient = CapabilityRPCClient(socketURL: socketURL, token: token)
        self.providerProfileID = profileID
        self.trustedParent = trustedParent
    }

    public func makeServer() async -> Server {
        let server = Server(
            name: "miller-capability-bridge",
            version: "0.1.1",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .strict
        )
        let rpcClient = self.rpcClient
        let providerProfileID = self.providerProfileID
        let catalog = self.catalog
        await server.withMethodHandler(ListTools.self) { _ in
            let response: CapabilityRPCResponse
            do {
                response = try await rpcClient.send(
                    .list(providerProfileID: providerProfileID)
                )
            } catch {
                throw MillerCapabilityBridgeError.brokerUnavailable
            }
            guard case .catalog(let descriptors) = response else {
                throw MillerCapabilityBridgeError.invalidCatalog
            }
            return ListTools.Result(
                tools: try await catalog.replace(with: descriptors)
            )
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            guard let capabilityID = await catalog.capabilityID(
                for: parameters.name
            ) else {
                return .init(
                    content: [.text(
                        text: "Capability is not in the current Miller catalog.",
                        annotations: nil,
                        _meta: nil
                    )],
                    isError: true
                )
            }
            let arguments = try JSONEncoder().encode(parameters.arguments ?? [:])
            let callID = CapabilityCallID()
            let response: CapabilityRPCResponse
            do {
                response = try await rpcClient.call(
                    callID: callID,
                    capabilityID: capabilityID,
                    argumentsJSON: arguments
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .init(
                    content: [.text(
                        text: "Miller capability broker is unavailable.",
                        annotations: nil,
                        _meta: nil
                    )],
                    isError: true
                )
            }
            switch response {
            case .result(let receivedCallID, let contentJSON, let isError):
                guard receivedCallID == callID,
                      let payload = try? JSONDecoder().decode(
                        BridgeToolResultPayload.self,
                        from: contentJSON
                      )
                else { throw MillerCapabilityBridgeError.invalidResult }
                return .init(
                    content: payload.content,
                    structuredContent: payload.structuredContent,
                    isError: isError || payload.isError
                )
            case .failed(let receivedCallID, let code):
                guard receivedCallID == nil || receivedCallID == callID else {
                    throw MillerCapabilityBridgeError.invalidResult
                }
                return .init(
                    content: [.text(
                        text: "Miller capability call failed (\(code)).",
                        annotations: nil,
                        _meta: nil
                    )],
                    isError: true
                )
            case .catalog:
                throw MillerCapabilityBridgeError.invalidResult
            }
        }
        return server
    }

    public func run() async throws {
        let lease: CapabilityRPCBridgeProcessLease?
        if let trustedParent {
            do {
                lease = try CapabilityRPCBridgeProcessLease.acquire(
                    trustedParent: trustedParent
                )
            } catch {
                throw MillerCapabilityBridgeError.invalidEnvironment
            }
        } else {
            lease = nil
        }
        defer { lease?.release() }
        let server = await makeServer()
        try await server.start(transport: StdioTransport())
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await server.waitUntilCompleted() }
            group.addTask { await rpcClient.waitUntilEndpointUnavailable() }
            _ = await group.next()
            await server.stop()
            group.cancelAll()
        }
    }
}

private actor ProjectedCapabilityCatalog {
    private var capabilities: [String: CapabilityID] = [:]

    func replace(with descriptors: [CapabilityDescriptor]) throws -> [Tool] {
        var next: [String: CapabilityID] = [:]
        var tools: [Tool] = []
        tools.reserveCapacity(descriptors.count)
        for descriptor in descriptors.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let name = Self.projectedName(descriptor)
            guard next.updateValue(descriptor.id, forKey: name) == nil,
                  let schema = try? JSONDecoder().decode(
                    Value.self,
                    from: descriptor.inputSchemaJSON
                  ),
                  schema.objectValue != nil
            else { throw MillerCapabilityBridgeError.invalidCatalog }
            tools.append(Tool(
                name: name,
                title: descriptor.displayName,
                description: descriptor.summary,
                inputSchema: schema,
                annotations: .init(
                    title: descriptor.displayName,
                    readOnlyHint: descriptor.readOnlyHint
                )
            ))
        }
        capabilities = next
        return tools
    }

    func capabilityID(for name: String) -> CapabilityID? { capabilities[name] }

    private static func projectedName(_ descriptor: CapabilityDescriptor) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in descriptor.id.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let suffix = descriptor.toolName.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII,
               (scalar.properties.isAlphabetic || (48...57).contains(scalar.value)
                    || scalar == "_" || scalar == "-")
            {
                return Character(String(scalar))
            }
            return "_"
        }
        return "miller_\(String(hash, radix: 16))_\(String(suffix).prefix(72))"
    }
}

private struct BridgeToolResultPayload: Decodable {
    let content: [Tool.Content]
    let structuredContent: Value?
    let isError: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case content, structuredContent, isError
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode([Tool.Content].self, forKey: .content)
        structuredContent = try container.decodeIfPresent(
            Value.self, forKey: .structuredContent
        )
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    do {
        try await MillerCapabilityBridgeRuntime(
            environment: ProcessInfo.processInfo.environment
        ).run()
    } catch {
        exit(1)
    }
}

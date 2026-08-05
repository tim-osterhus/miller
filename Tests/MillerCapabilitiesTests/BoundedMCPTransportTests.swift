import Foundation
@testable import MillerCapabilities
import Testing

@Suite(.serialized)
struct BoundedMCPTransportTests {
    @Test
    func oversizedUnterminatedStdioFrameFailsQuickly() async throws {
        let input = Pipe()
        let output = Pipe()
        let failure = TransportFailureProbe()
        let transport = BoundedStdioTransport(
            inputDescriptor: input.fileHandleForReading.fileDescriptor,
            outputDescriptor: output.fileHandleForWriting.fileDescriptor,
            maximumInboundBytes: 64,
            failureHandler: { failure.record() }
        )
        try await transport.connect()
        let stream = await transport.receive()
        let receive = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        let started = ContinuousClock.now
        try input.fileHandleForWriting.write(
            contentsOf: Data(repeating: UInt8(ascii: "x"), count: 65)
        )
        await #expect(throws: MCPClientSessionError.inboundTooLarge) {
            _ = try await receive.value
        }
        #expect(started.duration(to: .now) < .milliseconds(500))
        #expect(failure.didFail)

        await transport.disconnect()
        try input.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
    }

    @Test
    func unexpectedStdioEOFFailsInsteadOfFinishingNormally() async throws {
        let input = Pipe()
        let output = Pipe()
        let failure = TransportFailureProbe()
        let transport = BoundedStdioTransport(
            inputDescriptor: input.fileHandleForReading.fileDescriptor,
            outputDescriptor: output.fileHandleForWriting.fileDescriptor,
            maximumInboundBytes: 64,
            failureHandler: { failure.record() }
        )
        try await transport.connect()
        let stream = await transport.receive()
        let receive = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try input.fileHandleForWriting.close()
        await #expect(throws: MCPClientSessionError.connectionClosed) {
            _ = try await receive.value
        }
        #expect(failure.didFail)

        await transport.disconnect()
        try output.fileHandleForReading.close()
    }

    @Test
    func httpRejectsDeclaredAndStreamingBodiesAboveLimit() async throws {
        for plan in [
            HTTPFixturePlan(
                headers: ["Content-Type": "application/json", "Content-Length": "65"],
                chunks: []
            ),
            HTTPFixturePlan(
                headers: ["Content-Type": "application/json"],
                chunks: [Data(repeating: UInt8(ascii: "x"), count: 33),
                         Data(repeating: UInt8(ascii: "y"), count: 32)]
            ),
        ] {
            HTTPFixtureURLProtocol.setPlan(plan)
            let configuration = MCPHTTPTransportPolicy.ephemeralConfiguration(
                protocolClasses: [HTTPFixtureURLProtocol.self]
            )
            let transport = BoundedHTTPTransport(
                endpoint: URL(string: "https://example.com/mcp")!,
                headers: [:], maximumInboundBytes: 64,
                configuration: configuration
            )
            try await transport.connect()
            await #expect(throws: MCPClientSessionError.inboundTooLarge) {
                try await transport.send(Data(#"{"jsonrpc":"2.0"}"#.utf8))
            }
            await transport.disconnect()
        }
    }

    @Test
    func pinnedSDKClientRunsThroughBoundedHTTPTransport() async throws {
        let secretReference = UUID()
        MCPHTTPClientFixtureURLProtocol.reset()
        let configuration = try MCPServerConfiguration(
            id: "http-fixture", displayName: "HTTP Fixture",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!),
            secrets: [
                try MCPSecretBinding(
                    destination: .header, name: "Authorization",
                    credentialReference: secretReference
                ),
            ],
            enabled: true, providerProfileIDs: [UUID()]
        )
        let session = try await MCPClientSession.connect(
            configuration: configuration,
            credentialResolver: { reference in
                #expect(reference == secretReference)
                return "Bearer fixture-token"
            },
            httpConfiguration: MCPHTTPTransportPolicy.ephemeralConfiguration(
                protocolClasses: [MCPHTTPClientFixtureURLProtocol.self]
            )
        )
        #expect(try await session.listTools().map { $0.name } == ["lookup"])
        #expect(MCPHTTPClientFixtureURLProtocol.authorizationHeader
            == "Bearer fixture-token")
        await session.disconnect()
    }

    @Test
    func boundedHTTPUsesNegotiatedProtocolVersionAfterInitialize() async throws {
        MCPHTTPClientFixtureURLProtocol.reset(
            negotiatedProtocolVersion: "2025-03-26"
        )
        let configuration = try MCPServerConfiguration(
            id: "http-fixture", displayName: "HTTP Fixture",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!),
            enabled: true, providerProfileIDs: [UUID()]
        )
        let session = try await MCPClientSession.connect(
            configuration: configuration,
            credentialResolver: { _ in "unused" },
            httpConfiguration: MCPHTTPTransportPolicy.ephemeralConfiguration(
                protocolClasses: [MCPHTTPClientFixtureURLProtocol.self]
            )
        )

        #expect(try await session.listTools().map(\.name) == ["lookup"])
        #expect(MCPHTTPClientFixtureURLProtocol.postInitializeProtocolVersions
            == ["2025-03-26", "2025-03-26"])
        await session.disconnect()
    }

    @Test
    func sseCombinesMultilineDataAndSeparatesMultipleEvents() async throws {
        HTTPFixtureURLProtocol.setPlan(HTTPFixturePlan(
            headers: ["Content-Type": "text/event-stream"],
            chunks: [
                Data("data: {\"jsonrpc\":\"2.0\",\n".utf8),
                Data("data: \"id\":1}\n\n: ignored\n".utf8),
                Data("data: {\"jsonrpc\":\"2.0\",\"id\":2}\n\n".utf8),
            ]
        ))
        let transport = BoundedHTTPTransport(
            endpoint: URL(string: "https://example.com/mcp")!,
            headers: [:], maximumInboundBytes: 256,
            configuration: MCPHTTPTransportPolicy.ephemeralConfiguration(
                protocolClasses: [HTTPFixtureURLProtocol.self]
            )
        )
        try await transport.connect()
        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        try await transport.send(Data(#"{"jsonrpc":"2.0"}"#.utf8))
        let first = try #require(try await iterator.next())
        let second = try #require(try await iterator.next())
        #expect(String(decoding: first, as: UTF8.self)
            == "{\"jsonrpc\":\"2.0\",\n\"id\":1}")
        #expect(String(decoding: second, as: UTF8.self)
            == "{\"jsonrpc\":\"2.0\",\"id\":2}")
        await transport.disconnect()
    }

    @Test
    func inboundMessageQueueIsBounded() async throws {
        HTTPFixtureURLProtocol.setPlan(HTTPFixturePlan(
            headers: ["Content-Type": "application/json"],
            chunks: [Data("{}".utf8)]
        ))
        let transport = BoundedHTTPTransport(
            endpoint: URL(string: "https://example.com/mcp")!,
            headers: [:], maximumInboundBytes: 64,
            configuration: MCPHTTPTransportPolicy.ephemeralConfiguration(
                protocolClasses: [HTTPFixtureURLProtocol.self]
            )
        )
        try await transport.connect()
        for _ in 0..<4 {
            try await transport.send(Data(#"{"jsonrpc":"2.0"}"#.utf8))
        }
        await #expect(throws: MCPClientSessionError.inboundTooLarge) {
            try await transport.send(Data(#"{"jsonrpc":"2.0"}"#.utf8))
        }
        await transport.disconnect()
    }

    @Test
    func httpUsesEphemeralStateAndRejectsEveryRedirect() throws {
        let configuration = MCPHTTPTransportPolicy.ephemeralConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)

        for target in [
            "https://example.com/other",
            "https://other.example/mcp",
            "http://127.0.0.1:9876/mcp",
        ] {
            var proposed = URLRequest(url: URL(string: target)!)
            proposed.setValue("redirect-secret-canary", forHTTPHeaderField: "Authorization")
            #expect(MCPHTTPTransportPolicy.redirectedRequest(proposed) == nil)
        }
    }

    @Test
    func resolvedSecretsAreBoundedValidatedAndRedactionSafe() async throws {
        let reference = UUID()
        for invalidName in ["Authorization\r\nInjected", "Bad_Name", "Bad\0Name"] {
            #expect(throws: MCPConfigurationError.invalidSecretBinding) {
                try MCPSecretBinding(
                    destination: .header, name: invalidName,
                    credentialReference: reference
                )
            }
        }
        let environment = try MCPSecretBinding(
            destination: .environment, name: "TOKEN",
            credentialReference: reference
        )
        let header = try MCPSecretBinding(
            destination: .header, name: "Authorization",
            credentialReference: reference
        )
        let invalidEnvironmentValues = [
            "secret-canary\0suffix",
            "secret-canary" + String(repeating: "x", count: 16 * 1_024),
        ]
        for value in invalidEnvironmentValues {
            do {
                _ = try await MCPClientSession.resolvedEnvironment(
                    [environment], resolver: { _ in value }
                )
                Issue.record("Expected invalid environment secret")
            } catch {
                #expect(error as? MCPClientSessionError == .invalidSecret)
                #expect(!String(describing: error).contains("secret-canary"))
            }
        }

        let invalidHeaderValues = invalidEnvironmentValues + [
            "secret-canary\r\ninjected: yes",
            "secret-canary\u{1f}",
            "secret-canary-é",
        ]
        for value in invalidHeaderValues {
            do {
                _ = try await MCPClientSession.resolvedHeaders(
                    [header], resolver: { _ in value }
                )
                Issue.record("Expected invalid header secret")
            } catch {
                #expect(error as? MCPClientSessionError == .invalidSecret)
                #expect(!String(describing: error).contains("secret-canary"))
            }
        }
    }
}

private struct HTTPFixturePlan: Sendable {
    let headers: [String: String]
    let chunks: [Data]
}

private final class TransportFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    var didFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
    func record() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}

private final class HTTPFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var plan = HTTPFixturePlan(headers: [:], chunks: [])

    static func setPlan(_ value: HTTPFixturePlan) {
        lock.lock()
        plan = value
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let plan = Self.plan
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: plan.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MCPHTTPClientFixtureURLProtocol: URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var capturedAuthorization: String?
    nonisolated(unsafe) private static var negotiatedProtocolVersion: String?
    nonisolated(unsafe) private static var capturedPostInitializeVersions: [String] = []

    static var authorizationHeader: String? {
        lock.lock()
        defer { lock.unlock() }
        return capturedAuthorization
    }

    static var postInitializeProtocolVersions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedPostInitializeVersions
    }

    static func reset(negotiatedProtocolVersion: String? = nil) {
        lock.lock()
        capturedAuthorization = nil
        Self.negotiatedProtocolVersion = negotiatedProtocolVersion
        capturedPostInitializeVersions = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
        Self.lock.unlock()
        let object = (try? JSONSerialization.jsonObject(with: requestBody()))
            as? [String: Any]
        let method = object?["method"] as? String
        let id = object?["id"]
        let requestVersion = request.value(
            forHTTPHeaderField: "MCP-Protocol-Version"
        )
        Self.lock.lock()
        let negotiatedVersion = Self.negotiatedProtocolVersion
        if method != "initialize", let requestVersion {
            Self.capturedPostInitializeVersions.append(requestVersion)
        }
        Self.lock.unlock()
        let versionRejected = method != "initialize"
            && negotiatedVersion != nil
            && requestVersion != negotiatedVersion
        let result: [String: Any]?
        switch method {
        case "initialize":
            let parameters = object?["params"] as? [String: Any]
            result = [
                "protocolVersion": negotiatedVersion
                    ?? parameters?["protocolVersion"] as? String
                    ?? "2025-03-26",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "http-fixture", "version": "1"],
            ]
        case "tools/list":
            result = [
                "tools": [[
                    "name": "lookup",
                    "description": "Lookup",
                    "inputSchema": ["type": "object"],
                    "annotations": ["readOnlyHint": true],
                ]],
            ]
        default:
            result = nil
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: versionRejected ? 400 : (result == nil ? 202 : 200),
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let result, let id {
            let body = try! JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ])
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}

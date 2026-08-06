import Foundation
@testable import MillerCapabilities
@testable import MillerCore
import Testing

@Suite
struct CapabilityBrokerLifecycleTests {
    @Test
    func lifecycleSnapshotTracksConfiguredStartingReadyDegradedAndStopped() async throws {
        let providerID = UUID()
        let factory = SuspendedSessionFactory()
        let broker = try CapabilityBroker(
            configurations: [try Self.configuration(providerID: providerID)],
            sessionFactory: { configuration in
                try await factory.connect(serverID: configuration.id)
            },
            approval: { _ in .allowOnce }, audit: { _ in }
        )
        #expect(await broker.lifecycleSnapshot() == .init(
            state: .configured, configuredServerCount: 1,
            activeSessionCount: 0, pendingConnectionCount: 0,
            activeCallCount: 0
        ))

        let refresh = Task { await broker.refresh() }
        try await eventually { await factory.requestCount == 1 }
        #expect(await broker.lifecycleSnapshot().state == .starting)
        #expect(await broker.lifecycleSnapshot().pendingConnectionCount == 1)

        let session = ControlledSession(tools: [Self.lookupTool])
        await factory.resolveNext(with: session)
        _ = await refresh.value
        #expect(await broker.lifecycleSnapshot().state == .ready)
        #expect(await broker.lifecycleSnapshot().activeSessionCount == 1)

        await session.setListFailure(true)
        _ = await broker.refresh()
        #expect(await broker.lifecycleSnapshot().state == .degraded)

        await broker.disconnectAll()
        #expect(await broker.lifecycleSnapshot() == .init(
            state: .stopped, configuredServerCount: 1,
            activeSessionCount: 0, pendingConnectionCount: 0,
            activeCallCount: 0
        ))
    }

    @Test
    func concurrentRefreshUsesOnePendingConnection() async throws {
        let providerID = UUID()
        let factory = SuspendedSessionFactory()
        let broker = try CapabilityBroker(
            configurations: [try Self.configuration(providerID: providerID)],
            sessionFactory: { configuration in
                try await factory.connect(serverID: configuration.id)
            },
            approval: { _ in .allowOnce }, audit: { _ in }
        )

        let first = Task { await broker.refresh() }
        let second = Task { await broker.refresh() }
        try await eventually { await factory.requestCount == 1 }

        let session = ControlledSession(tools: [Self.lookupTool])
        await factory.resolveNext(with: session)
        let firstResult = await first.value
        let secondResult = await second.value
        let counts = [firstResult.descriptors.count, secondResult.descriptors.count]
        #expect(counts.contains(1))
        #expect(await broker.catalog(providerProfileID: providerID).count == 1)
        #expect(await factory.requestCount == 1)
    }

    @Test
    func olderRefreshCannotPublishAfterNewerRefresh() async throws {
        let providerID = UUID()
        let session = SuspendedListSession()
        let broker = try CapabilityBroker(
            configurations: [try Self.configuration(providerID: providerID)],
            sessionFactory: { _ in session },
            approval: { _ in .allowOnce }, audit: { _ in }
        )

        let older = Task { await broker.refresh() }
        try await eventually { await session.requestCount == 1 }
        let newer = Task { await broker.refresh() }
        try await eventually { await session.requestCount == 2 }

        await session.resolve(request: 2, tools: [Self.tool(named: "new")])
        #expect(await newer.value.descriptors.map { $0.toolName } == ["new"])
        await session.resolve(request: 1, tools: [Self.tool(named: "old")])
        #expect(await older.value.descriptors.map { $0.toolName } == ["new"])

        let published = await broker.catalog(providerProfileID: providerID)
        #expect(published.map { $0.toolName } == ["new"])
    }

    @Test
    func refreshFailureDoesNotDisconnectHealthyCallSession() async throws {
        let providerID = UUID()
        let session = ControlledSession(tools: [Self.lookupTool])
        let broker = try CapabilityBroker(
            configurations: [try Self.configuration(providerID: providerID)],
            sessionFactory: { _ in session },
            approval: { _ in .allowOnce }, audit: { _ in }
        )
        _ = await broker.refresh()
        await session.suspendCalls()

        let call = Task {
            try await broker.call(
                callID: CapabilityCallID(), capabilityID: try Self.lookupID,
                argumentsJSON: Data("{}".utf8), providerProfileID: providerID
            )
        }
        try await eventually { await session.callCount == 1 }
        await session.setListFailure(true)
        #expect(await broker.refresh().staleServerIDs == ["notes"])
        #expect(await session.disconnectCount == 0)

        await session.resumeCalls()
        _ = try await call.value
    }

    @Test
    func ordinaryListErrorRetainsSessionAndLaterRefreshReusesIt() async throws {
        let providerID = UUID()
        let session = ControlledSession(tools: [Self.lookupTool])
        let connections = ConnectionCountProbe()
        let broker = try CapabilityBroker(
            configurations: [try Self.configuration(providerID: providerID)],
            sessionFactory: { _ in
                await connections.record()
                return session
            },
            approval: { _ in .allowOnce }, audit: { _ in }
        )

        #expect(await broker.refresh().staleServerIDs.isEmpty)
        await session.setListFailure(true)
        let stale = await broker.refresh()
        #expect(stale.staleServerIDs == ["notes"])
        #expect(stale.descriptors.allSatisfy { !$0.isAvailable })
        #expect(await session.disconnectCount == 0)

        await session.setListFailure(false)
        #expect(await broker.refresh().staleServerIDs.isEmpty)
        #expect(await connections.count == 1)
        #expect(await session.disconnectCount == 0)
    }

    @Test
    func stdioEOFDuringListDiscardsOnlyDeadLeaseAndNextRefreshReconnects() async throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "eof-during-list-mcp-server", withExtension: "mjs",
            subdirectory: "Fixtures"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-mcp-list-eof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("sentinel")
        let pidLog = root.appendingPathComponent("pids")
        let sentinelReference = UUID()
        let pidReference = UUID()
        let providerID = UUID()
        let configuration = try MCPServerConfiguration(
            id: "notes", displayName: "Notes",
            transport: .stdio(
                executable: "/opt/homebrew/opt/node@22/bin/node",
                arguments: [fixtureURL.path]
            ),
            secrets: [
                try MCPSecretBinding(
                    destination: .environment, name: "MILLER_MCP_EOF_SENTINEL",
                    credentialReference: sentinelReference
                ),
                try MCPSecretBinding(
                    destination: .environment, name: "MILLER_MCP_PID_LOG",
                    credentialReference: pidReference
                ),
            ],
            enabled: true, defaultPolicy: .fullyTrusted,
            providerProfileIDs: [providerID],
            bounds: MCPBounds(startupTimeout: .seconds(2))
        )
        let connections = ConnectionCountProbe()
        let broker = try CapabilityBroker(
            configurations: [configuration],
            sessionFactory: { configuration in
                await connections.record()
                return try await MCPClientSession.connect(
                    configuration: configuration,
                    credentialResolver: { reference in
                        if reference == sentinelReference { return sentinel.path }
                        if reference == pidReference { return pidLog.path }
                        throw LifecycleTestFailure()
                    }
                )
            },
            approval: { _ in .allowOnce }, audit: { _ in }
        )

        let initial = await broker.refresh()
        #expect(initial.descriptors.map(\.toolName) == ["lookup"])
        #expect(initial.staleServerIDs.isEmpty)
        let firstPID = try #require(Self.recordedPIDs(at: pidLog).first)

        let started = ContinuousClock.now
        let stale = await broker.refresh()
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(stale.staleServerIDs == ["notes"])
        #expect(stale.descriptors.map(\.toolName) == ["lookup"])
        #expect(stale.descriptors.allSatisfy { !$0.isAvailable })
        try await eventually { !Self.processExists(firstPID) }

        let recovered = await broker.refresh()
        #expect(recovered.staleServerIDs.isEmpty)
        #expect(recovered.descriptors.map(\.toolName) == ["lookup"])
        #expect(recovered.descriptors.allSatisfy { $0.isAvailable })
        #expect(await connections.count == 2)

        await broker.disconnectAll()
        for pid in Self.recordedPIDs(at: pidLog) {
            try await eventually { !Self.processExists(pid) }
        }
    }

    @Test
    func disconnectDuringPendingConnectPreventsLateInstall() async throws {
        let providerID = UUID()
        let factory = SuspendedSessionFactory()
        let broker = try CapabilityBroker(
            configurations: [try Self.configuration(providerID: providerID)],
            sessionFactory: { configuration in
                try await factory.connect(serverID: configuration.id)
            },
            approval: { _ in .allowOnce }, audit: { _ in }
        )

        let refresh = Task { await broker.refresh() }
        try await eventually { await factory.requestCount == 1 }
        await broker.disconnectAll()
        let late = ControlledSession(tools: [Self.lookupTool])
        await factory.resolveNext(with: late)

        #expect(await refresh.value.descriptors.isEmpty)
        try await eventually { await late.disconnectCount == 1 }
        #expect(await broker.catalog(providerProfileID: providerID).isEmpty)
    }

    @Test
    func duplicateCallIDExecutesOnlyOnceConcurrentlyAndAfterTerminal() async throws {
        let providerID = UUID()
        let session = ControlledSession(tools: [Self.lookupTool])
        let broker = try CapabilityBroker(
            configurations: [try Self.configuration(providerID: providerID)],
            sessionFactory: { _ in session },
            approval: { _ in .allowOnce }, audit: { _ in }
        )
        _ = await broker.refresh()
        await session.suspendCalls()
        let callID = CapabilityCallID()
        let first = Task {
            try await broker.call(
                callID: callID, capabilityID: try Self.lookupID,
                argumentsJSON: Data("{}".utf8), providerProfileID: providerID
            )
        }
        try await eventually { await session.callCount == 1 }

        await #expect(throws: CapabilityBrokerError.duplicateCallID) {
            try await broker.call(
                callID: callID, capabilityID: try Self.lookupID,
                argumentsJSON: Data("{}".utf8), providerProfileID: providerID
            )
        }
        await session.resumeCalls()
        _ = try await first.value
        await #expect(throws: CapabilityBrokerError.duplicateCallID) {
            try await broker.call(
                callID: callID, capabilityID: try Self.lookupID,
                argumentsJSON: Data("{}".utf8), providerProfileID: providerID
            )
        }
        #expect(await session.callCount == 1)
    }

    @Test
    func invalidCallsDoNotConsumeIdentityAndValidCallsHaveNoFiniteBudget() async throws {
        let providerID = UUID()
        let session = ControlledSession(tools: [Self.lookupTool])
        let broker = try CapabilityBroker(
            configurations: [try Self.configuration(providerID: providerID)],
            sessionFactory: { _ in session },
            approval: { _ in .allowOnce }, audit: { _ in }
        )
        _ = await broker.refresh()
        let missing = try CapabilityID(
            source: .millerMCP, serverID: "missing", toolName: "missing"
        )
        let reusableID = CapabilityCallID()
        for index in 0..<4_097 {
            let expected: CapabilityBrokerError
            let candidateCapability: CapabilityID
            let candidateProvider: UUID
            let candidateArguments: Data
            switch index % 3 {
            case 0:
                expected = .capabilityUnavailable
                candidateCapability = missing
                candidateProvider = providerID
                candidateArguments = Data("{}".utf8)
            case 1:
                expected = .capabilityUnavailable
                candidateCapability = try Self.lookupID
                candidateProvider = UUID()
                candidateArguments = Data("{}".utf8)
            default:
                expected = .invalidArguments
                candidateCapability = try Self.lookupID
                candidateProvider = providerID
                candidateArguments = Data("[]".utf8)
            }
            await #expect(throws: expected) {
                try await broker.call(
                    callID: reusableID, capabilityID: candidateCapability,
                    argumentsJSON: candidateArguments,
                    providerProfileID: candidateProvider
                )
            }
        }
        _ = try await broker.call(
            callID: reusableID, capabilityID: try Self.lookupID,
            argumentsJSON: Data("{}".utf8), providerProfileID: providerID
        )
        for _ in 0..<4_097 {
            _ = try await broker.call(
                callID: CapabilityCallID(), capabilityID: try Self.lookupID,
                argumentsJSON: Data("{}".utf8), providerProfileID: providerID
            )
        }
        #expect(await session.callCount == 4_098)
    }

    @Test
    func stdioEOFDuringCallDiscardsLeaseAndReconnectsWithoutProcessLeak() async throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "eof-once-mcp-server", withExtension: "mjs",
            subdirectory: "Fixtures"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-mcp-eof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("sentinel")
        let pidLog = root.appendingPathComponent("pids")
        let sentinelReference = UUID()
        let pidReference = UUID()
        let providerID = UUID()
        let configuration = try MCPServerConfiguration(
            id: "notes", displayName: "Notes",
            transport: .stdio(
                executable: "/opt/homebrew/opt/node@22/bin/node",
                arguments: [fixtureURL.path]
            ),
            secrets: [
                try MCPSecretBinding(
                    destination: .environment, name: "MILLER_MCP_EOF_SENTINEL",
                    credentialReference: sentinelReference
                ),
                try MCPSecretBinding(
                    destination: .environment, name: "MILLER_MCP_PID_LOG",
                    credentialReference: pidReference
                ),
            ],
            enabled: true, defaultPolicy: .fullyTrusted,
            providerProfileIDs: [providerID],
            bounds: MCPBounds(callTimeout: .seconds(2))
        )
        let connectionProbe = ConnectionCountProbe()
        let broker = try CapabilityBroker(
            configurations: [configuration],
            sessionFactory: { configuration in
                await connectionProbe.record()
                return try await MCPClientSession.connect(
                    configuration: configuration,
                    credentialResolver: { reference in
                        if reference == sentinelReference { return sentinel.path }
                        if reference == pidReference { return pidLog.path }
                        throw LifecycleTestFailure()
                    }
                )
            },
            approval: { _ in .allowOnce }, audit: { _ in }
        )
        _ = await broker.refresh()
        let capabilityID = try Self.lookupID
        let started = ContinuousClock.now
        await #expect(throws: CapabilityBrokerError.callFailed) {
            try await broker.call(
                callID: CapabilityCallID(), capabilityID: capabilityID,
                argumentsJSON: Data("{}".utf8), providerProfileID: providerID
            )
        }
        #expect(started.duration(to: .now) < .seconds(1))
        let firstPID = try #require(Self.recordedPIDs(at: pidLog).first)
        try await eventually { !Self.processExists(firstPID) }

        let result = try await broker.call(
            callID: CapabilityCallID(), capabilityID: capabilityID,
            argumentsJSON: Data("{}".utf8), providerProfileID: providerID
        )
        #expect(!result.isError)
        #expect(await connectionProbe.count == 2)
        await broker.disconnectAll()
        for pid in Self.recordedPIDs(at: pidLog) {
            try await eventually { !Self.processExists(pid) }
        }
    }

    @Test
    func aggregateCatalogOverflowPublishesNoPartialRows() async throws {
        let providerID = UUID()
        let first = ControlledSession(
            serverID: "first", tools: [Self.tool(named: "legacy-first")]
        )
        let second = ControlledSession(
            serverID: "second", tools: [Self.tool(named: "legacy-second")]
        )
        let sessions = ["first": first, "second": second]
        let broker = try CapabilityBroker(
            configurations: try sessions.keys.sorted().map {
                try Self.configuration(id: $0, providerID: providerID)
            },
            sessionFactory: { sessions[$0.id]! },
            approval: { _ in .allowOnce }, audit: { _ in }
        )
        #expect(await broker.refresh().descriptors.count == 2)

        await first.setTools((0..<1_025).map {
            Self.tool(named: "first-\($0)")
        })
        await second.setTools((0..<1_025).map {
            Self.tool(named: "second-\($0)")
        })
        let overflow = await broker.refresh()
        #expect(overflow.descriptors.count == 2)
        #expect(overflow.descriptors.allSatisfy { !$0.isAvailable })
        #expect(overflow.staleServerIDs == ["first", "second"])
        #expect(await broker.catalog(providerProfileID: providerID).isEmpty)
    }

    @Test
    func disconnectAllStartsSessionShutdownsInParallel() async throws {
        let providerID = UUID()
        let probe = DisconnectProbe(expected: 2)
        let sessions = [
            "first": ControlledSession(
                serverID: "first", tools: [Self.lookupTool], disconnectProbe: probe
            ),
            "second": ControlledSession(
                serverID: "second", tools: [Self.lookupTool], disconnectProbe: probe
            ),
        ]
        let broker = try CapabilityBroker(
            configurations: try sessions.keys.sorted().map {
                try Self.configuration(id: $0, providerID: providerID)
            },
            sessionFactory: { sessions[$0.id]! },
            approval: { _ in .allowOnce }, audit: { _ in }
        )
        _ = await broker.refresh()

        let disconnect = Task { await broker.disconnectAll() }
        try await eventually(timeout: .milliseconds(500)) {
            await probe.enteredCount == 2
        }
        await probe.releaseAll()
        await disconnect.value
    }

    private static let lookupTool = tool(named: "lookup")

    private static var lookupID: CapabilityID {
        get throws {
            try CapabilityID(
                source: .millerMCP, serverID: "notes", toolName: "lookup"
            )
        }
    }

    private static func tool(named name: String) -> MCPDiscoveredTool {
        MCPDiscoveredTool(
            name: name, displayName: name, summary: name,
            inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            readOnlyHint: true
        )
    }

    private static func configuration(
        id: String = "notes", providerID: UUID
    ) throws -> MCPServerConfiguration {
        try MCPServerConfiguration(
            id: id, displayName: id,
            transport: .stdio(executable: "/usr/bin/env", arguments: []),
            enabled: true, defaultPolicy: .fullyTrusted,
            providerProfileIDs: [providerID]
        )
    }

    private static func recordedPIDs(at url: URL) -> [Int32] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap { Int32($0) }
    }

    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}

private actor SuspendedSessionFactory {
    private var waiters: [CheckedContinuation<any MCPClientSessionProtocol, Error>] = []
    private(set) var requestCount = 0

    func connect(serverID: String) async throws -> any MCPClientSessionProtocol {
        requestCount += 1
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func resolveNext(with session: any MCPClientSessionProtocol) {
        waiters.removeFirst().resume(returning: session)
    }
}

private actor SuspendedListSession: MCPClientSessionProtocol {
    nonisolated let serverID = "notes"
    private var waiters: [Int: CheckedContinuation<[MCPDiscoveredTool], Error>] = [:]
    private(set) var requestCount = 0

    func listTools() async throws -> [MCPDiscoveredTool] {
        requestCount += 1
        let request = requestCount
        return try await withCheckedThrowingContinuation { waiters[request] = $0 }
    }

    func resolve(request: Int, tools: [MCPDiscoveredTool]) {
        waiters.removeValue(forKey: request)?.resume(returning: tools)
    }

    func callTool(name: String, argumentsJSON: Data) async throws -> MCPToolCallResult {
        throw LifecycleTestFailure()
    }

    func disconnect() async {}
}

private actor ControlledSession: MCPClientSessionProtocol {
    nonisolated let serverID: String
    private var tools: [MCPDiscoveredTool]
    private let disconnectProbe: DisconnectProbe?
    private var listFailure = false
    private var callsSuspended = false
    private var pendingCalls: [CheckedContinuation<MCPToolCallResult, Error>] = []
    private(set) var callCount = 0
    private(set) var disconnectCount = 0

    init(
        serverID: String = "notes",
        tools: [MCPDiscoveredTool],
        disconnectProbe: DisconnectProbe? = nil
    ) {
        self.serverID = serverID
        self.tools = tools
        self.disconnectProbe = disconnectProbe
    }

    func setTools(_ tools: [MCPDiscoveredTool]) { self.tools = tools }
    func setListFailure(_ value: Bool) { listFailure = value }
    func suspendCalls() { callsSuspended = true }

    func resumeCalls() {
        callsSuspended = false
        let result = MCPToolCallResult(
            contentJSON: Data(#"{"text":"ok"}"#.utf8), isError: false
        )
        let waiters = pendingCalls
        pendingCalls.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func listTools() async throws -> [MCPDiscoveredTool] {
        if listFailure { throw LifecycleTestFailure() }
        return tools
    }

    func callTool(name: String, argumentsJSON: Data) async throws -> MCPToolCallResult {
        callCount += 1
        if callsSuspended {
            return try await withCheckedThrowingContinuation { pendingCalls.append($0) }
        }
        return MCPToolCallResult(
            contentJSON: Data(#"{"text":"ok"}"#.utf8), isError: false
        )
    }

    func disconnect() async {
        disconnectCount += 1
        if let disconnectProbe { await disconnectProbe.entered() }
        let waiters = pendingCalls
        pendingCalls.removeAll()
        for waiter in waiters { waiter.resume(throwing: LifecycleTestFailure()) }
    }
}

private actor DisconnectProbe {
    private let expected: Int
    private(set) var enteredCount = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) { self.expected = expected }

    func entered() async {
        enteredCount += 1
        guard !released, enteredCount <= expected else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        released = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor ConnectionCountProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw LifecycleTestFailure() }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private struct LifecycleTestFailure: Error {}

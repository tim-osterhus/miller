import Foundation
@testable import MillerCapabilities
@testable import MillerCore
import Testing

@Suite
struct CapabilityBrokerTests {
    @Test
    func directPinnedSDKStdioSessionListsCallsAndCleansUpFixture() async throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "read-only-mcp-server",
            withExtension: "mjs",
            subdirectory: "Fixtures"
        ))
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let rootReference = UUID()
        let configuration = try MCPServerConfiguration(
            id: "fixture", displayName: "Fixture",
            transport: .stdio(
                executable: "/opt/homebrew/opt/node@22/bin/node",
                arguments: [fixtureURL.path]
            ),
            secrets: [
                try MCPSecretBinding(
                    destination: .environment,
                    name: "MILLER_MCP_FIXTURE_ROOT",
                    credentialReference: rootReference
                ),
            ],
            enabled: true,
            providerProfileIDs: [UUID()]
        )
        let session = try await MCPClientSession.connect(
            configuration: configuration,
            credentialResolver: { reference in
                #expect(reference == rootReference)
                return temporaryRoot.path
            }
        )
        let tools = try await session.listTools()
        #expect(tools.count == 5)
        #expect(tools.first(where: { $0.name == "lookup_note" })?.readOnlyHint == true)
        #expect(tools.first(where: { $0.name == "replace_note" })?.readOnlyHint == false)

        let result = try await session.callTool(
            name: "replace_note", argumentsJSON: Data("{}".utf8)
        )
        #expect(!result.isError)
        #expect(FileManager.default.fileExists(
            atPath: temporaryRoot.appendingPathComponent("note.txt").path
        ))
        let oversized = try await session.callTool(
            name: "oversize_result", argumentsJSON: Data("{}".utf8)
        )
        #expect(oversized.contentJSON.count <= 256 * 1_024)
        await #expect(throws: (any Error).self) {
            try await session.callTool(
                name: "fail_note", argumentsJSON: Data("{}".utf8)
            )
        }
        let afterFailure = try await session.callTool(
            name: "lookup_note", argumentsJSON: Data("{}".utf8)
        )
        #expect(!afterFailure.isError)
        await session.disconnect()

        let timeoutConfiguration = try MCPServerConfiguration(
            id: "fixture", displayName: "Fixture",
            transport: .stdio(
                executable: "/opt/homebrew/opt/node@22/bin/node",
                arguments: [fixtureURL.path]
            ),
            secrets: [
                try MCPSecretBinding(
                    destination: .environment,
                    name: "MILLER_MCP_FIXTURE_ROOT",
                    credentialReference: rootReference
                ),
            ],
            enabled: true, providerProfileIDs: [UUID()],
            bounds: MCPBounds(callTimeout: .milliseconds(100))
        )
        let timeoutSession = try await MCPClientSession.connect(
            configuration: timeoutConfiguration,
            credentialResolver: { _ in temporaryRoot.path }
        )
        await #expect(throws: MCPClientSessionError.callTimedOut) {
            try await timeoutSession.callTool(
                name: "slow_note", argumentsJSON: Data("{}".utf8)
            )
        }
        await timeoutSession.disconnect()
    }

    @Test
    func refreshListsEnabledServerAndRetainsStaleCatalogOnFailure() async throws {
        let fixture = BrokerFixture()
        let broker = try await fixture.makeBroker()
        let current = await broker.refresh()
        #expect(current.descriptors.map(\.toolName) == ["lookup_note", "replace_note"])
        #expect(current.staleServerIDs.isEmpty)

        await fixture.session.setListFailure(true)
        let stale = await broker.refresh()
        #expect(stale.descriptors.map(\.toolName) == ["lookup_note", "replace_note"])
        #expect(stale.staleServerIDs == ["notes"])
    }

    @Test
    func duplicateNormalizedToolIDsFailOnlyTheirServerAndRetainLastCatalog() async throws {
        let providerID = UUID()
        let healthySession = FakeSession(
            serverID: "healthy",
            tools: [
                .init(
                    name: "lookup", displayName: "Lookup", summary: "Lookup",
                    inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
                    readOnlyHint: true
                ),
            ]
        )
        let collisionSession = FakeSession(
            serverID: "collision",
            tools: Self.collidingTools
        )
        let sessions = [
            "healthy": healthySession,
            "collision": collisionSession,
        ]
        let configurations = try ["healthy", "collision"].map { id in
            try MCPServerConfiguration(
                id: id, displayName: id,
                transport: .stdio(
                    executable: "/usr/bin/env", arguments: []
                ),
                enabled: true, defaultPolicy: .fullyTrusted,
                providerProfileIDs: [providerID]
            )
        }
        let broker = try CapabilityBroker(
            configurations: configurations,
            sessionFactory: { configuration in sessions[configuration.id]! },
            approval: { _ in .allowOnce }, audit: { _ in }
        )

        let initial = await broker.refresh()
        #expect(initial.descriptors.map(\.id.rawValue) == ["miller_mcp/healthy/lookup"])
        #expect(initial.staleServerIDs == ["collision"])

        await collisionSession.setTools([
            .init(
                name: "legacy", displayName: "Legacy", summary: "Legacy",
                inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
                readOnlyHint: true
            ),
        ])
        let admitted = await broker.refresh()
        #expect(admitted.staleServerIDs.isEmpty)
        #expect(admitted.descriptors.count == 2)

        await collisionSession.setTools(Self.collidingTools)
        let stale = await broker.refresh()
        #expect(stale.staleServerIDs == ["collision"])
        #expect(stale.descriptors.first(where: {
            $0.id.rawValue == "miller_mcp/healthy/lookup"
        })?.isAvailable == true)
        #expect(stale.descriptors.first(where: {
            $0.id.rawValue == "miller_mcp/collision/legacy"
        })?.isAvailable == false)
    }

    @Test
    func disabledServerIsNotListedOrExecutedForProvider() async throws {
        let fixture = BrokerFixture(providerEnabled: false)
        let broker = try await fixture.makeBroker()
        #expect(await broker.refresh().descriptors.isEmpty)
        await #expect(throws: CapabilityBrokerError.capabilityUnavailable) {
            try await broker.call(
                callID: CapabilityCallID(),
                capabilityID: fixture.lookupID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.providerID
            )
        }
    }

    @Test
    func policyInheritanceRequestsApprovalAndHonorsDecision() async throws {
        let fixture = BrokerFixture()
        await fixture.approvals.setDecision(.decline)
        let broker = try await fixture.makeBroker()
        _ = await broker.refresh()
        await #expect(throws: CapabilityBrokerError.declined) {
            try await broker.call(
                callID: CapabilityCallID(),
                capabilityID: fixture.replaceID,
                argumentsJSON: Data("{}".utf8),
                providerProfileID: fixture.providerID
            )
        }
        #expect(await fixture.approvals.count == 1)
        #expect(await fixture.session.callCount == 0)

        await fixture.approvals.setDecision(.allowOnce)
        _ = try await broker.call(
            callID: CapabilityCallID(), capabilityID: fixture.replaceID,
            argumentsJSON: Data("{}".utf8), providerProfileID: fixture.providerID
        )
        #expect(await fixture.session.callCount == 1)
    }

    @Test
    func toolOverrideNeverGetsOverwrittenByRefresh() async throws {
        let fixture = BrokerFixture(overrides: [:])
        let broker = try await fixture.makeBroker()
        await broker.setToolPolicy(.fullyTrusted, for: fixture.replaceID)
        _ = await broker.refresh()
        _ = await broker.refresh()
        _ = try await broker.call(
            callID: CapabilityCallID(), capabilityID: fixture.replaceID,
            argumentsJSON: Data("{}".utf8), providerProfileID: fixture.providerID
        )
        #expect(await fixture.approvals.count == 0)
    }

    @Test
    func timeoutCancellationAndLateResultsAreTerminalOnce() async throws {
        let fixture = BrokerFixture(callTimeout: .milliseconds(30))
        await fixture.session.setDelay(.milliseconds(120))
        await fixture.session.setIgnoreCancellation(true)
        let broker = try await fixture.makeBroker()
        _ = await broker.refresh()
        let startedAt = ContinuousClock.now
        await #expect(throws: CapabilityBrokerError.timedOut) {
            try await broker.call(
                callID: CapabilityCallID(), capabilityID: fixture.lookupID,
                argumentsJSON: Data("{}".utf8), providerProfileID: fixture.providerID
            )
        }
        #expect(startedAt.duration(to: .now) < .milliseconds(500))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fixture.audit.terminalCount == 1)

        let task = Task {
            try await broker.call(
                callID: CapabilityCallID(), capabilityID: fixture.lookupID,
                argumentsJSON: Data("{}".utf8), providerProfileID: fixture.providerID
            )
        }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fixture.audit.terminalCount == 2)
    }

    @Test
    func crashIsIsolatedAndAuditIsSanitized() async throws {
        let fixture = BrokerFixture()
        let broker = try await fixture.makeBroker()
        _ = await broker.refresh()
        await fixture.session.setCallFailure(true)
        await #expect(throws: CapabilityBrokerError.callFailed) {
            try await broker.call(
                callID: CapabilityCallID(), capabilityID: fixture.lookupID,
                argumentsJSON: Data(#"{"password":"hunter2"}"#.utf8),
                providerProfileID: fixture.providerID
            )
        }
        await fixture.session.setCallFailure(false)
        _ = try await broker.call(
            callID: CapabilityCallID(), capabilityID: fixture.lookupID,
            argumentsJSON: Data("{}".utf8), providerProfileID: fixture.providerID
        )
        let summaries = await fixture.audit.summaries
        #expect(!summaries.joined().contains("hunter2"))
        #expect(summaries.allSatisfy { $0.utf8.count <= 1_024 })
    }

    @Test
    func enforcesFourGlobalAndOnePerServer() async throws {
        let probe = ConcurrencyProbe()
        let providerID = UUID()
        var configurations: [MCPServerConfiguration] = []
        var sessions: [String: FakeSession] = [:]
        for index in 0..<6 {
            let id = "server-\(index)"
            configurations.append(try MCPServerConfiguration(
                id: id, displayName: id,
                transport: .stdio(executable: "/usr/bin/env", arguments: []),
                enabled: true, defaultPolicy: .fullyTrusted,
                providerProfileIDs: [providerID]
            ))
            sessions[id] = FakeSession(
                serverID: id,
                tools: [.init(name: "lookup", displayName: "Lookup", summary: "Lookup", inputSchemaJSON: Data(#"{"type":"object"}"#.utf8), readOnlyHint: true)],
                probe: probe, delay: .milliseconds(60)
            )
        }
        let sessionsByID = sessions
        let broker = try CapabilityBroker(
            configurations: configurations,
            sessionFactory: { configuration in sessionsByID[configuration.id]! },
            approval: { _ in .allowOnce }, audit: { _ in }
        )
        _ = await broker.refresh()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for configuration in configurations {
                for _ in 0..<2 {
                    group.addTask {
                        let id = try CapabilityID(source: .millerMCP, serverID: configuration.id, toolName: "lookup")
                        _ = try await broker.call(
                            callID: CapabilityCallID(), capabilityID: id,
                            argumentsJSON: Data("{}".utf8), providerProfileID: providerID
                        )
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.maximumGlobal <= 4)
        #expect(await probe.maximumByServer.values.allSatisfy { $0 <= 1 })
        #expect(await probe.maximumGlobal == 4)
    }

    private static var collidingTools: [MCPDiscoveredTool] {
        ["Foo", "foo"].map { name in
            MCPDiscoveredTool(
                name: name, displayName: name, summary: name,
                inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
                readOnlyHint: true
            )
        }
    }
}

private struct BrokerFixture {
    let providerID = UUID()
    let session: FakeSession
    let approvals = ApprovalProbe()
    let audit = AuditProbe()
    let providerEnabled: Bool
    let overrides: [CapabilityID: CapabilityPolicy]
    let callTimeout: Duration

    var lookupID: CapabilityID { try! CapabilityID(source: .millerMCP, serverID: "notes", toolName: "lookup_note") }
    var replaceID: CapabilityID { try! CapabilityID(source: .millerMCP, serverID: "notes", toolName: "replace_note") }

    init(
        providerEnabled: Bool = true,
        overrides: [CapabilityID: CapabilityPolicy] = [:],
        callTimeout: Duration = .seconds(60)
    ) {
        self.providerEnabled = providerEnabled
        self.overrides = overrides
        self.callTimeout = callTimeout
        self.session = FakeSession(tools: [
            .init(name: "lookup_note", displayName: "Lookup", summary: "Look up a note", inputSchemaJSON: Data(#"{"type":"object"}"#.utf8), readOnlyHint: true),
            .init(name: "replace_note", displayName: "Replace", summary: "Replace a note", inputSchemaJSON: Data(#"{"type":"object"}"#.utf8), readOnlyHint: false),
        ])
    }

    func makeBroker() async throws -> CapabilityBroker {
        let config = try MCPServerConfiguration(
            id: "notes", displayName: "Notes",
            transport: .stdio(executable: "/usr/bin/env", arguments: []),
            enabled: true, defaultPolicy: .askBeforeChanges,
            providerProfileIDs: providerEnabled ? [providerID] : [],
            bounds: MCPBounds(callTimeout: callTimeout)
        )
        return try CapabilityBroker(
            configurations: [config], toolPolicies: overrides,
            sessionFactory: { _ in session },
            approval: { request in await approvals.decide(request) },
            audit: { event in await audit.record(event) }
        )
    }
}

private actor FakeSession: MCPClientSessionProtocol {
    let serverID: String
    private var tools: [MCPDiscoveredTool]
    private let probe: ConcurrencyProbe?
    private var delay: Duration
    private var listFailure = false
    private var callFailure = false
    private var ignoreCancellation = false
    private(set) var callCount = 0

    init(serverID: String = "notes", tools: [MCPDiscoveredTool], probe: ConcurrencyProbe? = nil, delay: Duration = .zero) {
        self.serverID = serverID
        self.tools = tools
        self.probe = probe
        self.delay = delay
    }
    func setListFailure(_ value: Bool) { listFailure = value }
    func setTools(_ value: [MCPDiscoveredTool]) { tools = value }
    func setCallFailure(_ value: Bool) { callFailure = value }
    func setDelay(_ value: Duration) { delay = value }
    func setIgnoreCancellation(_ value: Bool) { ignoreCancellation = value }
    func listTools() async throws -> [MCPDiscoveredTool] {
        if listFailure { throw TestFailure() }
        return tools
    }
    func callTool(name: String, argumentsJSON: Data) async throws -> MCPToolCallResult {
        callCount += 1
        await probe?.entered(serverID: serverID)
        defer { Task { await probe?.left(serverID: serverID) } }
        do {
            try await Task.sleep(for: delay)
        } catch is CancellationError where ignoreCancellation {
            try? await Task.sleep(for: delay)
        }
        if callFailure { throw TestFailure() }
        return MCPToolCallResult(contentJSON: Data(#"{"text":"private result"}"#.utf8), isError: false)
    }
    func disconnect() async {}
}

private actor ApprovalProbe {
    private var decision: CapabilityApprovalDecision = .allowOnce
    private(set) var count = 0
    func setDecision(_ value: CapabilityApprovalDecision) { decision = value }
    func decide(_ request: CapabilityApprovalRequest) -> CapabilityApprovalDecision {
        count += 1
        return decision
    }
}

private actor AuditProbe {
    private(set) var summaries: [String] = []
    private(set) var terminalCount = 0
    func record(_ event: CapabilityLifecycleEvent) {
        summaries.append(event.summary.text)
        if event.state == .terminal { terminalCount += 1 }
    }
}

private actor ConcurrencyProbe {
    private var global = 0
    private var byServer: [String: Int] = [:]
    private(set) var maximumGlobal = 0
    private(set) var maximumByServer: [String: Int] = [:]
    func entered(serverID: String) {
        global += 1
        byServer[serverID, default: 0] += 1
        maximumGlobal = max(maximumGlobal, global)
        maximumByServer[serverID] = max(maximumByServer[serverID, default: 0], byServer[serverID]!)
    }
    func left(serverID: String) {
        global -= 1
        byServer[serverID, default: 0] -= 1
    }
}

private struct TestFailure: Error {}

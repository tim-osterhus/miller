import Foundation
import MillerCore
@testable import MillerGateway
import Testing

@Suite(.serialized)
struct JSONLReasoningGatewayToolTests {
    @Test
    func toolDefinitionsAndRecordsAreClosedAndBounded() throws {
        let sessionID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        let turnID = UUID().uuidString.lowercased()
        let callID = UUID().uuidString.lowercased()
        let tool: JSONValue = .object([
            "capability_id": .string("miller_mcp/notes/lookup"),
            "name": .string("miller_tool_0"),
            "description": .string("Look up a note"),
            "input_schema": .object(["type": .string("object")]),
        ])
        _ = try GatewayRecord.make(
            type: "reasoning.start",
            sessionID: sessionID,
            requestID: requestID,
            fields: [
                "conversation_id": .string(UUID().uuidString.lowercased()),
                "turn_id": .string(turnID),
                "generation": .integer(1),
                "provider_profile": .object([
                    "kind": .string("fake"), "model": .string("fake"),
                    "credential_ref": .string(UUID().uuidString.lowercased()),
                ]),
                "context": .array([]), "user_text": .string("question"),
                "tools": .array([tool]),
            ]
        )
        _ = try GatewayRecord.make(
            type: "reasoning.tool_call",
            sessionID: sessionID,
            requestID: requestID,
            fields: [
                "turn_id": .string(turnID), "generation": .integer(1),
                "call_id": .string(callID),
                "capability_id": .string("miller_mcp/notes/lookup"),
                "arguments": .object(["query": .string("bounded")]),
            ]
        )
        #expect(throws: GatewayProtocolError.invalidField) {
            try GatewayRecord.make(
                type: "reasoning.tool_call",
                sessionID: sessionID,
                requestID: requestID,
                fields: [
                    "turn_id": .string(turnID), "generation": .integer(1),
                    "call_id": .string(callID),
                    "capability_id": .string("miller_mcp/notes/lookup"),
                    "arguments": .array([]),
                ]
            )
        }
        #expect(throws: GatewayProtocolError.invalidField) {
            try GatewayRecord.make(
                type: "reasoning.start",
                sessionID: sessionID,
                requestID: requestID,
                fields: [
                    "conversation_id": .string(UUID().uuidString.lowercased()),
                    "turn_id": .string(turnID), "generation": .integer(1),
                    "provider_profile": .object([
                        "kind": .string("fake"), "model": .string("fake"),
                        "credential_ref": .string(UUID().uuidString.lowercased()),
                    ]),
                    "context": .array([]), "user_text": .string("question"),
                    "tools": .array(Array(repeating: tool, count: 2_049)),
                ]
            )
        }
    }

    @Test
    func sessionValidatorRejectsDuplicateAndStaleToolResults() throws {
        let sessionID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        let turnID = UUID().uuidString.lowercased()
        let callID = UUID().uuidString.lowercased()
        var validator = GatewaySessionValidator()
        try validator.accept(GatewayRecord.make(
            type: "gateway.ready",
            sessionID: sessionID,
            fields: [
                "helper_version": .string("test"),
                "supported_protocols": .array([.integer(1)]),
            ]
        ))
        try validator.register(
            requestID: requestID,
            turnID: turnID,
            generation: 3
        )
        try validator.accept(GatewayRecord.make(
            type: "reasoning.accepted",
            sessionID: sessionID,
            requestID: requestID,
            fields: ["turn_id": .string(turnID), "generation": .integer(3)]
        ))
        try validator.accept(GatewayRecord.make(
            type: "reasoning.tool_call",
            sessionID: sessionID,
            requestID: requestID,
            fields: [
                "turn_id": .string(turnID), "generation": .integer(3),
                "call_id": .string(callID),
                "capability_id": .string("miller_mcp/notes/lookup"),
                "arguments": .object([:]),
            ]
        ))
        try validator.resolveTool(
            requestID: requestID,
            turnID: turnID,
            generation: 3,
            callID: callID
        )
        #expect(throws: GatewayProtocolError.invalidSequence) {
            try validator.resolveTool(
                requestID: requestID,
                turnID: turnID,
                generation: 3,
                callID: callID
            )
        }
        #expect(throws: GatewayProtocolError.invalidSequence) {
            try validator.resolveTool(
                requestID: requestID,
                turnID: turnID,
                generation: 2,
                callID: callID
            )
        }
    }

    @Test
    func distinctToolCallsExecuteConcurrentlyAndContinueWithoutRawPayloadEvents() async throws {
        let fixture = try ToolHelperFixture(mode: "two-calls")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(configuration: fixture.configuration)
        let probe = ToolProbe()
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile,
            toolHandler: { call, emit in
                await probe.handle(call, emit: emit)
            }
        )
        let events = try await collect(try await gateway.start(toolRequest()))

        #expect(await probe.callCount == 2)
        #expect(await probe.distinctCallCount == 2)
        #expect(await probe.maximumConcurrentCalls == 2)
        #expect(events.contains(.textDelta(ordinal: 0, text: "continued")))
        #expect(events.last == .completed)
        #expect(!String(describing: events).contains("private-result"))
        await supervisor.shutdown()
    }

    @Test
    func cancellationCancelsPendingHandlerAndFencesLateGeneration() async throws {
        let fixture = try ToolHelperFixture(mode: "one-call")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(
            configuration: fixture.configuration,
            cancellationTimeout: .milliseconds(250)
        )
        let probe = SuspendedToolProbe()
        let request = toolRequest()
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile,
            toolHandler: { call, emit in
                try await probe.handle(call, emit: emit)
            }
        )
        let stream = try await gateway.start(request)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted)
        try await probe.waitUntilStarted()

        await gateway.cancel(.init(
            turnID: request.turnID,
            targetGeneration: request.generation
        ))
        await probe.releaseLate()

        var remaining: [ReasoningEvent] = []
        do {
            while let event = try await iterator.next() { remaining.append(event) }
        } catch {}
        #expect(!remaining.contains(where: {
            if case .capabilityLifecycle = $0 { return true }
            return false
        }))
        await supervisor.shutdown()
    }

    @Test
    func malformedToolArgumentsRestartHelperWithoutInvokingHandler() async throws {
        let fixture = try ToolHelperFixture(mode: "malformed")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(configuration: fixture.configuration)
        let probe = ToolProbe()
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile,
            toolHandler: { call, emit in
                await probe.handle(call, emit: emit)
            }
        )
        do {
            _ = try await collect(try await gateway.start(toolRequest()))
            Issue.record("Expected malformed arguments to fail")
        } catch {}
        try await eventually {
            let restartCount = await supervisor.restartCount
            let isReady = await supervisor.isReady
            return restartCount == 1 && isReady
        }
        #expect(await probe.callCount == 0)
        await supervisor.shutdown()
    }

    private func toolRequest() -> ReasoningRequest {
        ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: "use tools",
            capabilityCatalog: try! CapabilityCatalogSnapshot([
                try! CapabilityDescriptor(
                    id: CapabilityID(rawValue: "miller_mcp/notes/lookup"),
                    source: .millerMCP,
                    serverID: "notes",
                    toolName: "lookup",
                    displayName: "Lookup",
                    summary: "Look up a note",
                    inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
                    readOnlyHint: true,
                    providerProfileIDs: [],
                    isAvailable: true
                ),
                try! CapabilityDescriptor(
                    id: CapabilityID(rawValue: "miller_mcp/notes/list"),
                    source: .millerMCP,
                    serverID: "notes",
                    toolName: "list",
                    displayName: "List",
                    summary: "List notes",
                    inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
                    readOnlyHint: true,
                    providerProfileIDs: [],
                    isAvailable: true
                ),
            ])
        )
    }

    private func providerProfile() -> GatewayProviderProfile {
        GatewayProviderProfile(
            kind: "openai_compatible",
            baseURL: "https://fixture.invalid/v1",
            model: "fixture-model",
            credentialReference: UUID()
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<ReasoningEvent, Error>
    ) async throws -> [ReasoningEvent] {
        var result: [ReasoningEvent] = []
        for try await event in stream { result.append(event) }
        return result
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Condition did not become true")
    }
}

private actor ToolProbe {
    private var calls: [GatewayToolCall] = []
    private var active = 0
    private var maximum = 0

    var callCount: Int { calls.count }
    var distinctCallCount: Int { Set(calls.map(\.callID)).count }
    var maximumConcurrentCalls: Int { maximum }

    func handle(
        _ call: GatewayToolCall,
        emit: @escaping @Sendable (ReasoningEvent) -> Void
    ) async -> GatewayToolResult {
        calls.append(call)
        active += 1
        maximum = max(maximum, active)
        try? await Task.sleep(for: .milliseconds(30))
        active -= 1
        return try! GatewayToolResult(
            outcome: .succeeded,
            contentJSON: Data(#"{"value":"private-result"}"#.utf8)
        )
    }
}

private actor SuspendedToolProbe {
    private var started = false
    private var released = false

    func handle(
        _ call: GatewayToolCall,
        emit: @escaping @Sendable (ReasoningEvent) -> Void
    ) async throws -> GatewayToolResult {
        started = true
        while !released {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try GatewayToolResult(
            outcome: .succeeded,
            contentJSON: Data(#"{"late":true}"#.utf8)
        )
    }

    func waitUntilStarted() async throws {
        while !started { try await Task.sleep(for: .milliseconds(10)) }
    }

    func releaseLate() { released = true }
}

private struct ToolHelperFixture {
    let root: URL
    let configuration: GatewayProcess.Configuration

    init(mode: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-tool-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let helper = root.appendingPathComponent("helper.mjs")
        try Data(Self.source(mode: mode).utf8).write(to: helper)
        configuration = GatewayProcess.Configuration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [helper.path],
            workingDirectoryURL: root,
            environment: ["LANG": "C", "LC_ALL": "C", "TMPDIR": root.path],
            terminationGrace: .milliseconds(100)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func source(mode: String) -> String {
        """
        import crypto from "node:crypto";
        const mode = \(String(reflecting: mode));
        const session = crypto.randomUUID();
        var operation;
        var results = 0;
        const send = (value) => process.stdout.write(JSON.stringify(value) + "\\n");
        const base = (type) => ({protocol:"miller.gateway",version:1,type,session_id:session,request_id:operation.request_id,turn_id:operation.turn_id,generation:operation.generation});
        send({protocol:"miller.gateway",version:1,type:"gateway.ready",session_id:session,helper_version:"tool-fixture",supported_protocols:[1]});
        var pending = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", chunk => {
          pending += chunk;
          for (;;) {
            const newline = pending.indexOf("\\n");
            if (newline < 0) break;
            const record = JSON.parse(pending.slice(0, newline)); pending = pending.slice(newline + 1);
            if (record.type === "reasoning.start") {
              operation = record; send(base("reasoning.accepted"));
              const calls = mode === "two-calls" ? record.tools.slice(0, 2) : record.tools.slice(0, 1);
              for (const tool of calls) send({...base("reasoning.tool_call"),call_id:crypto.randomUUID(),capability_id:tool.capability_id,arguments:mode === "malformed" ? [] : {query:tool.name}});
            } else if (record.type === "reasoning.tool_result") {
              results += 1;
              const expected = mode === "two-calls" ? 2 : 1;
              if (results === expected) { send({...base("reasoning.text_delta"),ordinal:0,text:"continued"}); send(base("reasoning.completed")); }
            } else if (record.type === "reasoning.cancel") {
              send(base("reasoning.stopped"));
            }
          }
        });
        """
    }
}

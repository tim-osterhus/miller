import Foundation
import MillerCore
@testable import MillerGateway
import Testing

@Suite(.serialized)
struct JSONLReasoningGatewayToolTests {
    @Test
    func serializesPortableSkillsAndSurfacesBoundedOmission() async throws {
        let fixture = try ToolHelperFixture(mode: "record-portable")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(configuration: fixture.configuration)
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor, selectedProvider: providerProfile
        )
        let attachment = try PortableSkillAttachment(
            skills: [.init(
                id: "weather", pluginID: nil, name: "Weather",
                description: "Forecast guidance", markdown: "Use forecasts.",
                sourceHash: String(repeating: "a", count: 64), enabled: true
            )],
            omittedCount: 2
        )
        let request = ReasoningRequest(
            conversationID: ConversationID(), turnID: TurnID(), generation: 1,
            context: [], userText: "weather", portableSkillAttachment: attachment
        )

        let events = try await collect(try await gateway.start(request))

        #expect(events == [
            .accepted,
            .status(.portableSkillsOmitted),
            .textDelta(ordinal: 0, text: "portable"),
            .completed,
        ])
        await supervisor.shutdown()
    }

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
            "input_schema": .object([:]),
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
    func synchronousToolLifecycleEventsRemainOrderedBeforeResultAndTerminal() async throws {
        let fixture = try ToolHelperFixture(mode: "one-call")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(configuration: fixture.configuration)
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile,
            toolHandler: { call, emit in
                let policy = CapabilityPolicyResolver().resolve(
                    serverPolicy: .askBeforeChanges,
                    readOnlyHint: false
                ).effectivePolicy
                let summary = try CapabilitySummary(text: "Ordered fixture")
                await emit(.capabilityLifecycle(try CapabilityLifecycleEvent(
                    callID: call.callID,
                    capabilityID: call.capabilityID,
                    summary: summary,
                    state: .started,
                    outcome: nil,
                    policy: policy
                )))
                await emit(.capabilityApprovalRequested(try CapabilityApprovalRequest(
                    callID: call.callID,
                    capabilityID: call.capabilityID,
                    summary: summary,
                    policy: policy
                )))
                await emit(.capabilityLifecycle(try CapabilityLifecycleEvent(
                    callID: call.callID,
                    capabilityID: call.capabilityID,
                    summary: summary,
                    state: .running,
                    outcome: nil,
                    policy: policy
                )))
                return try GatewayToolResult(
                    outcome: .succeeded,
                    contentJSON: Data(#"{"value":"private-result"}"#.utf8)
                )
            }
        )

        let events = try await collect(try await gateway.start(toolRequest()))
        #expect(events.count == 6)
        #expect(events[0] == .accepted)
        if case .capabilityLifecycle(let event) = events[1] {
            #expect(event.state == .started)
        } else { Issue.record("Missing started lifecycle") }
        if case .capabilityApprovalRequested = events[2] {
        } else { Issue.record("Missing approval request") }
        if case .capabilityLifecycle(let event) = events[3] {
            #expect(event.state == .running)
        } else { Issue.record("Missing running lifecycle") }
        #expect(events[4] == .textDelta(ordinal: 0, text: "continued"))
        #expect(events[5] == .completed)
        await supervisor.shutdown()
    }

    @Test
    func concurrentToolTimeoutIsTerminalWithoutHelperRestart() async throws {
        let fixture = try ToolHelperFixture(mode: "concurrent-timeout")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(configuration: fixture.configuration)
        let probe = SuspendedToolProbe()
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile,
            toolHandler: { call, emit in
                try await probe.handle(call, emit: emit)
            }
        )

        let events = try await collect(try await gateway.start(toolRequest()))
        #expect(events == [
            .accepted,
            .failed(
                code: "capability_timeout",
                message: "A tool timed out. Try again."
            ),
        ])
        #expect(await supervisor.restartCount == 0)

        let ordinary = try await collect(try await gateway.start(toolRequest(
            capabilityCatalog: .empty
        )))
        #expect(ordinary == [
            .accepted,
            .textDelta(ordinal: 0, text: "ordinary"),
            .completed,
        ])
        #expect(await supervisor.restartCount == 0)
        await supervisor.shutdown()
    }

    @Test
    func aggregateToolDefinitionsRejectBeforeHelperAndLeaveItHealthy() async throws {
        let fixture = try ToolHelperFixture(mode: "ordinary")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(configuration: fixture.configuration)
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile
        )
        let descriptors = try (0..<600).map { index in
            try CapabilityDescriptor(
                id: CapabilityID(rawValue: "miller_mcp/bulk/tool_\(index)"),
                source: .millerMCP,
                serverID: "bulk",
                toolName: "tool_\(index)",
                displayName: "Tool \(index)",
                summary: String(repeating: "s", count: 1_024),
                inputSchemaJSON: Data("{}".utf8),
                readOnlyHint: true,
                providerProfileIDs: [],
                isAvailable: true
            )
        }
        let oversized = toolRequest(
            capabilityCatalog: try CapabilityCatalogSnapshot(descriptors)
        )

        await #expect(throws: GatewayProtocolError.recordTooLarge) {
            _ = try await gateway.start(oversized)
        }
        #expect(await supervisor.restartCount == 0)
        let ordinary = try await collect(try await gateway.start(toolRequest(
            capabilityCatalog: .empty
        )))
        #expect(ordinary.last == .completed)
        #expect(await supervisor.restartCount == 0)
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

    @Test
    func toolsUnavailableIsSurfacedOnceWhileTextContinues() async throws {
        let fixture = try ToolHelperFixture(mode: "tools-unavailable")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(configuration: fixture.configuration)
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile
        )

        let events = try await collect(try await gateway.start(toolRequest()))

        #expect(events.filter { $0 == .status(.toolsUnavailable) }.count == 1)
        #expect(events.contains(.textDelta(ordinal: 0, text: "ordinary text")))
        #expect(events.last == .completed)
        await supervisor.shutdown()
    }

    @Test(arguments: ["late-completed", "late-failed"])
    func everyInboundRecordIsFencedAfterCancellation(mode: String) async throws {
        let fixture = try ToolHelperFixture(mode: mode)
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(
            configuration: fixture.configuration,
            cancellationTimeout: .milliseconds(500)
        )
        let probe = ToolProbe()
        let request = toolRequest()
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile,
            toolHandler: { call, emit in
                await probe.handle(call, emit: emit)
            }
        )
        let stream = try await gateway.start(request)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted)

        await gateway.cancel(.init(
            turnID: request.turnID,
            targetGeneration: request.generation
        ))

        var remaining: [ReasoningEvent] = []
        do {
            while let event = try await iterator.next() { remaining.append(event) }
        } catch {}
        #expect(remaining.isEmpty)
        #expect(await probe.callCount == 0)
        await supervisor.shutdown()
    }

    @Test
    func replacementGenerationCannotReceiveBufferedPriorRunRecords() async throws {
        let fixture = try ToolHelperFixture(mode: "late-completed")
        defer { fixture.cleanup() }
        let supervisor = GatewaySupervisor(
            configuration: fixture.configuration,
            cancellationTimeout: .milliseconds(500)
        )
        let probe = ToolProbe()
        let first = toolRequest()
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile,
            toolHandler: { call, emit in
                await probe.handle(call, emit: emit)
            }
        )
        let firstStream = try await gateway.start(first)
        var firstIterator = firstStream.makeAsyncIterator()
        #expect(try await firstIterator.next() == .accepted)
        await gateway.cancel(.init(
            turnID: first.turnID,
            targetGeneration: first.generation
        ))
        while (try? await firstIterator.next()) != nil {}

        let replacement = toolRequest(
            turnID: first.turnID,
            generation: first.generation + 1
        )
        var replacementStream: AsyncThrowingStream<ReasoningEvent, Error>?
        for _ in 0..<100 where replacementStream == nil {
            replacementStream = try? await gateway.start(replacement)
            if replacementStream == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let replacementEvents = try await collect(
            try #require(replacementStream)
        )

        #expect(replacementEvents == [
            .accepted,
            .textDelta(ordinal: 0, text: "fresh generation"),
            .completed,
        ])
        #expect(await probe.callCount == 0)
        await supervisor.shutdown()
    }

    private func toolRequest(
        turnID: TurnID = TurnID(),
        generation: Int = 1,
        capabilityCatalog: CapabilityCatalogSnapshot? = nil
    ) -> ReasoningRequest {
        ReasoningRequest(
            conversationID: ConversationID(),
            turnID: turnID,
            generation: generation,
            context: [],
            userText: "use tools",
            capabilityCatalog: capabilityCatalog ?? (try! CapabilityCatalogSnapshot([
                try! CapabilityDescriptor(
                    id: CapabilityID(rawValue: "miller_mcp/notes/lookup"),
                    source: .millerMCP,
                    serverID: "notes",
                    toolName: "lookup",
                    displayName: "Lookup",
                    summary: "Look up a note",
                    inputSchemaJSON: Data("{}".utf8),
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
            ]))
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
        emit: @escaping @Sendable (ReasoningEvent) async -> Void
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
        emit: @escaping @Sendable (ReasoningEvent) async -> Void
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
        var starts = 0;
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
              operation = record; starts += 1; send(base("reasoning.accepted"));
              if (mode === "record-portable") {
                const skill = record.portable_skills?.[0];
                if (skill?.id !== "weather" || skill?.name !== "Weather" ||
                    skill?.description !== "Forecast guidance" ||
                    skill?.markdown !== "Use forecasts." ||
                    record.portable_skills_omitted !== 2) process.exit(60);
                send({...base("reasoning.text_delta"),ordinal:0,text:"portable"});
                send(base("reasoning.completed"));
                continue;
              }
              if (record.tools.length === 0) {
                send({...base("reasoning.text_delta"),ordinal:0,text:"ordinary"});
                send(base("reasoning.completed"));
                continue;
              }
              if (mode.startsWith("late-") && starts > 1) {
                send({...base("reasoning.text_delta"),ordinal:0,text:"fresh generation"});
                send(base("reasoning.completed"));
                continue;
              }
              if (mode === "tools-unavailable") {
                send({...base("reasoning.tool_event"),call_id:record.request_id,status:"tools_unavailable"});
                send({...base("reasoning.text_delta"),ordinal:0,text:"ordinary text"});
                send(base("reasoning.completed"));
                continue;
              }
              if (mode === "concurrent-timeout") {
                const first = crypto.randomUUID();
                const second = crypto.randomUUID();
                send({...base("reasoning.tool_call"),call_id:first,capability_id:record.tools[0].capability_id,arguments:{}});
                send({...base("reasoning.tool_call"),call_id:second,capability_id:record.tools[1].capability_id,arguments:{}});
                send({...base("reasoning.tool_event"),call_id:first,capability_id:record.tools[0].capability_id,status:"timed_out"});
                send({...base("reasoning.tool_event"),call_id:second,capability_id:record.tools[1].capability_id,status:"cancelled"});
                send({...base("reasoning.failed"),error_code:"capability_timeout"});
                continue;
              }
              const calls = mode === "two-calls" ? record.tools.slice(0, 2) : record.tools.slice(0, 1);
              if (!mode.startsWith("late-")) for (const tool of calls) send({...base("reasoning.tool_call"),call_id:crypto.randomUUID(),capability_id:tool.capability_id,arguments:mode === "malformed" ? [] : {query:tool.name}});
            } else if (record.type === "reasoning.tool_result") {
              results += 1;
              const expected = mode === "two-calls" ? 2 : 1;
              if (results === expected) { send({...base("reasoning.text_delta"),ordinal:0,text:"continued"}); send(base("reasoning.completed")); }
            } else if (record.type === "reasoning.cancel") {
              if (mode.startsWith("late-")) {
                const callID = crypto.randomUUID();
                send({...base("reasoning.text_delta"),ordinal:0,text:"late-private-text"});
                send({...base("reasoning.usage"),input_tokens:1,output_tokens:1});
                send({...base("reasoning.tool_event"),call_id:record.request_id,status:"tools_unavailable"});
                send({...base("reasoning.tool_call"),call_id:callID,capability_id:operation.tools[0].capability_id,arguments:{private:true}});
                send({...base("reasoning.tool_event"),call_id:callID,capability_id:operation.tools[0].capability_id,status:"cancelled"});
                if (mode === "late-completed") send(base("reasoning.completed"));
                else send({...base("reasoning.failed"),error_code:"provider_unavailable"});
              } else send(base("reasoning.stopped"));
            }
          }
        });
        """
    }
}

import Foundation
import MillerCore

public struct GatewayToolCall: Sendable, Equatable {
    public let requestID: String
    public let turnID: TurnID
    public let generation: Int
    public let callID: CapabilityCallID
    public let capabilityID: CapabilityID
    public let argumentsJSON: Data
}

public enum GatewayToolOutcome: String, Sendable, Equatable {
    case succeeded
    case failed
    case declined
    case timedOut = "timed_out"
    case cancelled
}

public struct GatewayToolResult: Sendable, Equatable {
    public let outcome: GatewayToolOutcome
    public let contentJSON: Data?

    public init(
        outcome: GatewayToolOutcome,
        contentJSON: Data? = nil
    ) throws {
        let requiresContent = outcome == .succeeded || outcome == .failed
        guard requiresContent == (contentJSON != nil) else {
            throw GatewayProtocolError.invalidField
        }
        if let contentJSON {
            guard contentJSON.count <= 256 * 1_024 else {
                throw GatewayProtocolError.recordTooLarge
            }
            do {
                try StrictJSONScanner.validate(contentJSON)
                let value = try JSONSerialization.jsonObject(
                    with: contentJSON,
                )
                guard value is [String: Any] else {
                    throw GatewayProtocolError.invalidJSON
                }
            } catch {
                throw GatewayProtocolError.invalidJSON
            }
        }
        self.outcome = outcome
        self.contentJSON = contentJSON
    }
}

public typealias GatewayToolHandler = @Sendable (
    GatewayToolCall,
    @escaping @Sendable (ReasoningEvent) async -> Void
) async throws -> GatewayToolResult

public actor JSONLReasoningGateway: ReasoningGateway {
    private struct ActiveRun {
        let requestID: String
        let turnID: TurnID
        let generation: Int
        var toolTasks: [String: Task<Void, Never>] = [:]
    }

    private let supervisor: GatewaySupervisor
    private let selectedProvider: @Sendable () async throws -> GatewayProviderProfile
    private let toolHandler: GatewayToolHandler
    private var activeRun: ActiveRun?

    public init(
        supervisor: GatewaySupervisor,
        selectedProvider: @escaping @Sendable () async throws -> GatewayProviderProfile,
        toolHandler: @escaping GatewayToolHandler
    ) {
        self.supervisor = supervisor
        self.selectedProvider = selectedProvider
        self.toolHandler = toolHandler
    }

    public init(
        supervisor: GatewaySupervisor,
        selectedProvider: @escaping @Sendable () async throws -> GatewayProviderProfile
    ) {
        self.init(
            supervisor: supervisor,
            selectedProvider: selectedProvider,
            toolHandler: JSONLReasoningGateway.unavailableToolHandler
        )
    }

    public func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        let requestID = UUID().uuidString.lowercased()
        let profile = try await selectedProvider()
        let tools = try Self.toolDefinitions(request.capabilityCatalog)
        try Self.validateAggregateToolDefinitions(tools)
        var fields: [String: JSONValue] = [
            "conversation_id": .string(request.conversationID.description),
            "turn_id": .string(request.turnID.description),
            "generation": .integer(request.generation),
            "provider_profile": .object(profile.fields),
            "context": .array(request.context.map {
                .object(["role": .string($0.role.rawValue), "text": .string($0.text)])
            }),
            "user_text": .string(request.userText),
            "tools": tools,
        ]
        if let attachment = request.voiceHistoryAttachment {
            fields["voice_history_attachment"] = .string(attachment.text)
        }
        let source = try await supervisor.openReasoning(
            requestID: requestID,
            turnID: request.turnID.description,
            generation: request.generation,
            fields: fields
        )

        activeRun = ActiveRun(
            requestID: requestID,
            turnID: request.turnID,
            generation: request.generation
        )
        return AsyncThrowingStream { continuation in
            Task {
                await self.consume(
                    source,
                    requestID: requestID,
                    turnID: request.turnID,
                    generation: request.generation,
                    continuation: continuation
                )
            }
        }
    }

    public func cancel(_ cancellation: ReasoningCancellation) async {
        guard let run = activeRun,
              run.turnID == cancellation.turnID,
              run.generation == cancellation.targetGeneration
        else {
            return
        }
        activeRun = nil
        for task in run.toolTasks.values { task.cancel() }
        for callID in run.toolTasks.keys {
            try? await supervisor.cancelTool(
                requestID: run.requestID,
                turnID: run.turnID.description,
                generation: run.generation,
                callID: callID
            )
        }
        await supervisor.cancel(
            turnID: cancellation.turnID.description,
            targetGeneration: cancellation.targetGeneration
        )
    }

    private func consume(
        _ source: AsyncThrowingStream<GatewayRecord, Error>,
        requestID: String,
        turnID: TurnID,
        generation: Int,
        continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation
    ) async {
        do {
            var eventCount = 0
            var responseScalars = 0
            for try await record in source {
                guard isActiveRun(
                    requestID: requestID,
                    turnID: turnID,
                    generation: generation
                ) else {
                    continuation.finish()
                    return
                }
                eventCount += 1
                guard eventCount <= 1_024 else {
                    throw GatewayProtocolError.invalidSequence
                }
                switch record.type {
                case "reasoning.tool_call":
                    try beginToolCall(
                        record,
                        requestID: requestID,
                        turnID: turnID,
                        generation: generation,
                        continuation: continuation
                    )
                case "reasoning.tool_event":
                    if record["status"]?.stringValue == "tools_unavailable" {
                        continuation.yield(.status(.toolsUnavailable))
                    }
                default:
                    let event = try Self.map(record)
                    if case let .textDelta(_, text) = event {
                        responseScalars += text.unicodeScalars.count
                        guard responseScalars <= 256_000 else {
                            throw GatewayProtocolError.recordTooLarge
                        }
                    }
                    continuation.yield(event)
                    if event.isTerminal {
                        finishRun(requestID: requestID, cancellingTools: true)
                        continuation.finish()
                        return
                    }
                }
            }
            finishRun(requestID: requestID, cancellingTools: true)
            continuation.finish()
        } catch {
            finishRun(requestID: requestID, cancellingTools: true)
            continuation.finish(throwing: error)
        }
    }

    private func beginToolCall(
        _ record: GatewayRecord,
        requestID: String,
        turnID: TurnID,
        generation: Int,
        continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation
    ) throws {
        guard var run = activeRun,
              run.requestID == requestID,
              run.turnID == turnID,
              run.generation == generation,
              let rawCallID = record["call_id"]?.stringValue,
              let uuid = UUID(uuidString: rawCallID),
              uuid.uuidString.lowercased() == rawCallID,
              let rawCapabilityID = record["capability_id"]?.stringValue,
              let arguments = record["arguments"]
        else {
            throw GatewayProtocolError.invalidSequence
        }
        let argumentsJSON = try JSONSerialization.data(
            withJSONObject: arguments.foundationValue,
            options: [.sortedKeys]
        )
        let call = GatewayToolCall(
            requestID: requestID,
            turnID: turnID,
            generation: generation,
            callID: CapabilityCallID(rawValue: uuid),
            capabilityID: try CapabilityID(rawValue: rawCapabilityID),
            argumentsJSON: argumentsJSON
        )
        let task = Task {
            await self.executeToolCall(
                call,
                continuation: continuation
            )
        }
        run.toolTasks[rawCallID] = task
        activeRun = run
    }

    private func executeToolCall(
        _ call: GatewayToolCall,
        continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation
    ) async {
        let result: GatewayToolResult
        do {
            result = try await toolHandler(call) { event in
                await self.emitToolEvent(
                    event,
                    call: call,
                    continuation: continuation
                )
            }
        } catch is CancellationError {
            guard let cancelled = try? GatewayToolResult(outcome: .cancelled) else {
                return
            }
            result = cancelled
        } catch {
            guard let failed = try? GatewayToolResult(
                outcome: .failed,
                contentJSON: Data(#"{"error":"tool_execution_failed"}"#.utf8)
            ) else {
                return
            }
            result = failed
        }
        let rawCallID = call.callID.rawValue.uuidString.lowercased()
        guard isActive(call) else { return }
        do {
            let value = try result.contentJSON.map(Self.jsonValue)
            try await supervisor.submitToolResult(
                requestID: call.requestID,
                turnID: call.turnID.description,
                generation: call.generation,
                callID: rawCallID,
                outcome: result.outcome.rawValue,
                result: value
            )
            removeToolTask(rawCallID, requestID: call.requestID)
        } catch {
            removeToolTask(rawCallID, requestID: call.requestID)
        }
    }

    private func emitToolEvent(
        _ event: ReasoningEvent,
        call: GatewayToolCall,
        continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation
    ) {
        guard isActive(call) else { return }
        switch event {
        case .capabilityLifecycle, .capabilityApprovalRequested:
            continuation.yield(event)
        default:
            break
        }
    }

    private func isActive(_ call: GatewayToolCall) -> Bool {
        guard let run = activeRun else { return false }
        return run.requestID == call.requestID
            && run.turnID == call.turnID
            && run.generation == call.generation
            && run.toolTasks[call.callID.rawValue.uuidString.lowercased()] != nil
    }

    private func isActiveRun(
        requestID: String,
        turnID: TurnID,
        generation: Int
    ) -> Bool {
        guard let run = activeRun else { return false }
        return run.requestID == requestID
            && run.turnID == turnID
            && run.generation == generation
    }

    private func removeToolTask(_ callID: String, requestID: String) {
        guard var run = activeRun, run.requestID == requestID else { return }
        run.toolTasks.removeValue(forKey: callID)
        activeRun = run
    }

    private func finishRun(requestID: String, cancellingTools: Bool) {
        guard let run = activeRun, run.requestID == requestID else { return }
        activeRun = nil
        if cancellingTools {
            for task in run.toolTasks.values { task.cancel() }
        }
    }

    private static func toolDefinitions(
        _ catalog: CapabilityCatalogSnapshot
    ) throws -> JSONValue {
        let tools = try catalog.descriptors
            .filter(\.isAvailable)
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .enumerated()
            .map { index, descriptor -> JSONValue in
                let rawSchema = try JSONSerialization.jsonObject(
                    with: descriptor.inputSchemaJSON
                )
                guard let schema = rawSchema as? [String: Any] else {
                    throw GatewayProtocolError.invalidField
                }
                return .object([
                    "capability_id": .string(descriptor.id.rawValue),
                    "name": .string("miller_tool_\(index)"),
                    "description": .string(descriptor.summary),
                    "input_schema": try JSONValue(foundation: schema),
                ])
            }
        return .array(tools)
    }

    private static func validateAggregateToolDefinitions(
        _ tools: JSONValue
    ) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: tools.foundationValue,
                options: [.sortedKeys]
            )
        } catch {
            throw GatewayProtocolError.invalidField
        }
        guard data.count <= 512 * 1_024 else {
            throw GatewayProtocolError.recordTooLarge
        }
    }

    private static func jsonValue(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard raw is [String: Any] else {
            throw GatewayProtocolError.invalidField
        }
        return try JSONValue(foundation: raw)
    }

    static func unavailableToolHandler(
        _ call: GatewayToolCall,
        _ emit: @escaping @Sendable (ReasoningEvent) async -> Void
    ) async throws -> GatewayToolResult {
        try GatewayToolResult(
            outcome: .failed,
            contentJSON: Data(#"{"error":"tool_handler_unavailable"}"#.utf8)
        )
    }

    private static func map(_ record: GatewayRecord) throws -> ReasoningEvent {
        switch record.type {
        case "reasoning.accepted":
            return .accepted
        case "reasoning.tool_event":
            guard record["status"]?.stringValue == "tools_unavailable" else {
                throw GatewayProtocolError.invalidSequence
            }
            return .status(.toolsUnavailable)
        case "reasoning.text_delta":
            guard let ordinal = record["ordinal"]?.integerValue,
                  let text = record["text"]?.stringValue
            else {
                throw GatewayProtocolError.invalidField
            }
            return .textDelta(ordinal: ordinal, text: text)
        case "reasoning.usage":
            return .usage(
                inputTokens: optionalInteger(record["input_tokens"]),
                outputTokens: optionalInteger(record["output_tokens"])
            )
        case "reasoning.completed":
            return .completed
        case "reasoning.stopped":
            return .stopped
        case "reasoning.failed":
            let code = record["error_code"]?.stringValue ?? "gateway_unavailable"
            let admitted = failureMessages[code] != nil
                ? code
                : "gateway_unavailable"
            return .failed(
                code: admitted,
                message: failureMessages[admitted]!
            )
        default:
            throw GatewayProtocolError.invalidSequence
        }
    }

    private static func optionalInteger(_ value: JSONValue?) -> Int? {
        value?.integerValue
    }

    private static let failureMessages = [
        "authentication_expired": "Authentication must be refreshed.",
        "network_unavailable": "The network is unavailable.",
        "provider_unavailable": "The reasoning provider is unavailable.",
        "capability_timeout": "A tool timed out. Try again.",
        "unsupported_model": "The selected model is unavailable for this account.",
        "response_limit": "The response exceeded a safety limit.",
        "gateway_unavailable": "The reasoning helper is unavailable.",
    ]
}

private extension ReasoningEvent {
    var isTerminal: Bool {
        switch self {
        case .completed, .stopped, .failed:
            true
        default:
            false
        }
    }
}

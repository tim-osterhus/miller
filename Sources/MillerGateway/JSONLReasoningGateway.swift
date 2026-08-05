import Foundation
import MillerCore

public actor JSONLReasoningGateway: ReasoningGateway {
    private let supervisor: GatewaySupervisor
    private let selectedProvider: @Sendable () async throws -> GatewayProviderProfile

    public init(
        supervisor: GatewaySupervisor,
        selectedProvider: @escaping @Sendable () async throws -> GatewayProviderProfile
    ) {
        self.supervisor = supervisor
        self.selectedProvider = selectedProvider
    }

    public func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        let requestID = UUID().uuidString.lowercased()
        let profile = try await selectedProvider()
        var fields: [String: JSONValue] = [
            "conversation_id": .string(request.conversationID.description),
            "turn_id": .string(request.turnID.description),
            "generation": .integer(request.generation),
            "provider_profile": .object(profile.fields),
            "context": .array(request.context.map {
                .object(["role": .string($0.role.rawValue), "text": .string($0.text)])
            }),
            "user_text": .string(request.userText),
            "tools": .array([]),
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

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var eventCount = 0
                    var responseScalars = 0
                    for try await record in source {
                        eventCount += 1
                        guard eventCount <= 1_024 else {
                            throw GatewayProtocolError.invalidSequence
                        }
                        let event = try Self.map(record)
                        if case let .textDelta(_, text) = event {
                            responseScalars += text.unicodeScalars.count
                            guard responseScalars <= 256_000 else {
                                throw GatewayProtocolError.recordTooLarge
                            }
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel(_ cancellation: ReasoningCancellation) async {
        await supervisor.cancel(
            turnID: cancellation.turnID.description,
            targetGeneration: cancellation.targetGeneration
        )
    }

    private static func map(_ record: GatewayRecord) throws -> ReasoningEvent {
        switch record.type {
        case "reasoning.accepted":
            return .accepted
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
        "unsupported_model": "The selected model is unavailable for this account.",
        "response_limit": "The response exceeded a safety limit.",
        "gateway_unavailable": "The reasoning helper is unavailable.",
    ]
}

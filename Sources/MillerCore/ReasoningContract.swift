public struct ReasoningMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct ReasoningRequest: Sendable, Equatable {
    public let conversationID: ConversationID
    public let turnID: TurnID
    public let generation: Int
    public let context: [ReasoningMessage]
    public let userText: String

    public init(
        conversationID: ConversationID,
        turnID: TurnID,
        generation: Int,
        context: [ReasoningMessage],
        userText: String
    ) {
        self.conversationID = conversationID
        self.turnID = turnID
        self.generation = generation
        self.context = context
        self.userText = userText
    }
}

public enum ReasoningEvent: Sendable, Equatable {
    case accepted
    case textDelta(ordinal: Int, text: String)
    case usage(inputTokens: Int?, outputTokens: Int?)
    case completed
    case stopped
    case failed(code: String, message: String)
}

public protocol ReasoningGateway: Sendable {
    func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error>

    func cancel(_ cancellation: ReasoningCancellation) async
}

public struct ReasoningCancellation: Sendable, Equatable {
    public let turnID: TurnID
    public let targetGeneration: Int

    public init(turnID: TurnID, targetGeneration: Int) {
        self.turnID = turnID
        self.targetGeneration = targetGeneration
    }
}

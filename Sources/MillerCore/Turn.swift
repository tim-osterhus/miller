import Foundation

public enum TurnState: String, Codable, CaseIterable, Sendable {
    case accepted
    case streaming
    case completed
    case stopped
    case failed

    public var isTerminal: Bool {
        self == .completed || self == .stopped || self == .failed
    }
}

public enum TurnEvent: Sendable, Equatable {
    case textDelta(String, generation: Int)
    case completed(at: Date)
    case stopped(at: Date, nextGeneration: Int)
    case failed(
        code: String,
        message: String,
        at: Date,
        nextGeneration: Int
    )
}

public struct Turn: Codable, Equatable, Sendable {
    public let id: TurnID
    public let conversationID: ConversationID
    public let sequence: Int
    public let inputMode: InputMode
    public let userText: String
    public private(set) var assistantText: String
    public private(set) var state: TurnState
    public private(set) var generation: Int
    public private(set) var errorCode: String?
    public private(set) var errorMessage: String?
    public let startedAt: Date
    public private(set) var terminalAt: Date?

    public var completionCode: String? {
        state == .completed && assistantText.isEmpty
            ? "completed_without_text"
            : nil
    }

    public init(
        id: TurnID,
        conversationID: ConversationID,
        sequence: Int,
        inputMode: InputMode,
        userText: String,
        assistantText: String,
        state: TurnState,
        generation: Int,
        errorCode: String?,
        errorMessage: String?,
        startedAt: Date,
        terminalAt: Date?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sequence = sequence
        self.inputMode = inputMode
        self.userText = userText
        self.assistantText = assistantText
        self.state = state
        self.generation = generation
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.terminalAt = terminalAt
    }

    public static func accepted(
        id: TurnID,
        conversationID: ConversationID,
        sequence: Int,
        inputMode: InputMode,
        userText: String,
        generation: Int,
        at: Date
    ) -> Self {
        Self(
            id: id,
            conversationID: conversationID,
            sequence: sequence,
            inputMode: inputMode,
            userText: userText,
            assistantText: "",
            state: .accepted,
            generation: generation,
            errorCode: nil,
            errorMessage: nil,
            startedAt: at,
            terminalAt: nil
        )
    }

    public mutating func apply(_ event: TurnEvent) throws {
        guard !state.isTerminal else {
            throw CoreError.turnAlreadyTerminal
        }

        switch event {
        case let .textDelta(text, receivedGeneration):
            guard receivedGeneration == generation else {
                throw CoreError.generationMismatch(
                    expected: generation,
                    received: receivedGeneration
                )
            }
            assistantText.append(text)
            state = .streaming

        case let .completed(at):
            state = .completed
            terminalAt = at

        case let .stopped(at, nextGeneration):
            try applyFence(nextGeneration)
            state = .stopped
            terminalAt = at

        case let .failed(code, _, at, nextGeneration):
            try applyFence(nextGeneration)
            let failure = MillerFailure(code: code)
            state = .failed
            errorCode = failure.code
            errorMessage = failure.message
            terminalAt = at
        }
    }

    private mutating func applyFence(_ nextGeneration: Int) throws {
        let expected = generation + 1
        guard nextGeneration == expected else {
            throw CoreError.generationMismatch(
                expected: expected,
                received: nextGeneration
            )
        }
        generation = nextGeneration
    }
}

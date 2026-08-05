public protocol ConversationRepository: Sendable {
    func accept(
        conversationID: ConversationID,
        turnID: TurnID,
        userText: String,
        inputMode: InputMode,
        generation: Int
    ) async throws

    func append(
        turnID: TurnID,
        text: String,
        generation: Int
    ) async throws

    func complete(turnID: TurnID, generation: Int) async throws

    func stop(
        turnID: TurnID,
        targetGeneration: Int,
        nextGeneration: Int
    ) async throws

    func fail(
        turnID: TurnID,
        code: String,
        message: String,
        targetGeneration: Int,
        nextGeneration: Int
    ) async throws

    func turn(id: TurnID) async throws -> Turn?

    func completedTurns(
        conversationID: ConversationID
    ) async throws -> [Turn]

    func archive(conversationID: ConversationID) async throws
    func unarchive(conversationID: ConversationID) async throws
    func delete(conversationID: ConversationID) async throws
    func recoverInterruptedTurns() async throws
}

public enum ConversationRepositoryError: Error, Equatable, Sendable {
    case transitionRejected
    case conversationNotFound
}

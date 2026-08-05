public struct ContextSelector: Sendable {
    public static let maximumPairs = 20
    public static let maximumContextScalars = 32_000
    public static let maximumCurrentInputScalars = 65_536

    public init() {}

    public func select(from turns: [Turn]) -> [ReasoningMessage] {
        var selected: [Turn] = []
        var scalarCount = 0

        for turn in turns
            .filter({ $0.state == .completed })
            .sorted(by: { $0.sequence > $1.sequence })
        {
            guard selected.count < Self.maximumPairs else {
                break
            }

            let pairScalarCount =
                turn.userText.unicodeScalars.count
                + turn.assistantText.unicodeScalars.count
            guard pairScalarCount <= Self.maximumContextScalars - scalarCount else {
                continue
            }

            selected.append(turn)
            scalarCount += pairScalarCount
        }

        return selected.reversed().flatMap { turn in
            [
                ReasoningMessage(role: .user, text: turn.userText),
                ReasoningMessage(role: .assistant, text: turn.assistantText),
            ]
        }
    }

    public func validateCurrentInput(_ text: String) throws {
        guard text.unicodeScalars.count <= Self.maximumCurrentInputScalars else {
            throw CoreError.requestTooLarge
        }
    }
}

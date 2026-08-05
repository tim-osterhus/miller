import Foundation

public enum ConversationState: String, Codable, CaseIterable, Sendable {
    case active
    case archived
}

public struct Conversation: Codable, Equatable, Sendable {
    public let id: ConversationID
    public var title: String?
    public var state: ConversationState
    public let createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(
        id: ConversationID,
        title: String?,
        state: ConversationState = .active,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    public static func initialTitle(from firstUserMessage: String) -> String? {
        let normalized = firstUserMessage
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !normalized.isEmpty else {
            return nil
        }

        return String(normalized.unicodeScalars.prefix(60))
    }
}

public enum InputMode: String, Codable, CaseIterable, Sendable {
    case text
    case voice
}

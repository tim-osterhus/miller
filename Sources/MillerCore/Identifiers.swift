import Foundation

public protocol MillerIdentifier:
    Codable, Hashable, Sendable, CustomStringConvertible
{
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension MillerIdentifier {
    init() {
        self.init(rawValue: UUID())
    }

    var description: String {
        rawValue.uuidString.lowercased()
    }
}

public struct ConversationID: MillerIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct TurnID: MillerIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct OperationID: MillerIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

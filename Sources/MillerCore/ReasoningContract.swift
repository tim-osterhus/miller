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
    public let capabilityCatalog: CapabilityCatalogSnapshot
    public let voiceHistoryAttachment: VoiceHistoryAttachment?
    public let portableSkillAttachment: PortableSkillAttachment?

    public init(
        conversationID: ConversationID,
        turnID: TurnID,
        generation: Int,
        context: [ReasoningMessage],
        userText: String,
        capabilityCatalog: CapabilityCatalogSnapshot = .empty,
        voiceHistoryAttachment: VoiceHistoryAttachment? = nil,
        portableSkillAttachment: PortableSkillAttachment? = nil
    ) {
        self.conversationID = conversationID
        self.turnID = turnID
        self.generation = generation
        self.context = context
        self.userText = userText
        self.capabilityCatalog = capabilityCatalog
        self.voiceHistoryAttachment = voiceHistoryAttachment
        self.portableSkillAttachment = portableSkillAttachment
    }
}

public enum ReasoningStatus: String, Sendable, Equatable, Codable {
    case toolsUnavailable = "tools_unavailable"
    case portableSkillsOmitted = "portable_skills_omitted"
}

public enum ReasoningEvent: Sendable, Equatable {
    case accepted
    case status(ReasoningStatus)
    case textDelta(ordinal: Int, text: String)
    case usage(inputTokens: Int?, outputTokens: Int?)
    case completed
    case stopped
    case failed(code: String, message: String)
    case capabilityLifecycle(CapabilityLifecycleEvent)
    case capabilityApprovalRequested(CapabilityApprovalRequest)
}

public enum ReasoningGatewayError: Error, Equatable, Sendable {
    case approvalUnsupported
}

public protocol ReasoningGateway: Sendable {
    func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error>

    func cancel(_ cancellation: ReasoningCancellation) async

    func resolveApproval(
        callID: CapabilityCallID,
        decision: CapabilityApprovalDecision
    ) async throws
}

public extension ReasoningGateway {
    func resolveApproval(
        callID _: CapabilityCallID,
        decision _: CapabilityApprovalDecision
    ) async throws {
        throw ReasoningGatewayError.approvalUnsupported
    }
}

public struct ReasoningCancellation: Sendable, Equatable {
    public let turnID: TurnID
    public let targetGeneration: Int

    public init(turnID: TurnID, targetGeneration: Int) {
        self.turnID = turnID
        self.targetGeneration = targetGeneration
    }
}

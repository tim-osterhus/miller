public enum CapabilityStatus: String, Codable, CaseIterable, Sendable {
    case unavailable
    case checking
    case ready
    case failed
}

public enum MillerCapability: String, Codable, CaseIterable, Sendable {
    case durableStorage
    case reasoningHelper
    case selectedProviderAndAuthentication
    case microphoneAndInputDevice
    case transcription
    case localNeuralSpeechOutput
    case macOSSpeechFallback
    case avatarPresentation

    public var isRequiredForText: Bool {
        switch self {
        case .durableStorage, .reasoningHelper, .selectedProviderAndAuthentication:
            true
        default:
            false
        }
    }
}

public struct CapabilityReadiness: Codable, Equatable, Sendable {
    public let capability: MillerCapability
    public let status: CapabilityStatus
    public let failureCode: String?

    public init(
        capability: MillerCapability,
        status: CapabilityStatus,
        failureCode: String? = nil
    ) {
        self.capability = capability
        self.status = status
        self.failureCode = failureCode
    }

    public var isRequiredForText: Bool {
        capability.isRequiredForText
    }

    public var isReadyForText: Bool {
        isRequiredForText && status == .ready
    }
}

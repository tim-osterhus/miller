public enum PresentationState: String, Codable, CaseIterable, Sendable {
    case idle
    case ready
    case listening
    case transcribing
    case waiting
    case responding
    case speaking
    case stopped
    case completed
    case failed
}

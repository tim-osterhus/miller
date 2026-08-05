public enum AvatarAnimationIntent: String, Codable, CaseIterable, Sendable {
    case none
    case attentive
    case thinking
    case speaking
}

public enum AvatarGazeIntent: String, Codable, CaseIterable, Sendable {
    case center
    case left
    case right
}

public struct AvatarProjection: Codable, Equatable, Sendable {
    public let generation: Int
    public let phase: PresentationState
    public let isVisible: Bool
    public let reduceMotion: Bool
    public let animationIntent: AvatarAnimationIntent
    public let gazeIntent: AvatarGazeIntent?
    public let mouthEnvelope: Double?

    public init(
        generation: Int,
        phase: PresentationState,
        isVisible: Bool,
        reduceMotion: Bool,
        animationIntent: AvatarAnimationIntent,
        gazeIntent: AvatarGazeIntent? = nil,
        mouthEnvelope: Double? = nil
    ) {
        self.generation = generation
        self.phase = phase
        self.isVisible = isVisible
        self.reduceMotion = reduceMotion
        self.animationIntent = animationIntent
        self.gazeIntent = gazeIntent
        if let mouthEnvelope, mouthEnvelope.isFinite {
            self.mouthEnvelope = min(max(mouthEnvelope, 0), 1)
        } else {
            self.mouthEnvelope = nil
        }
    }
}

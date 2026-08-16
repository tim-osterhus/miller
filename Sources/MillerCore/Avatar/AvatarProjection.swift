import Foundation

public enum AvatarVisibility: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case visible
    case occluded
    case hidden
}

public enum AvatarPresentationPhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case idle
    case listening
    case transcribing
    case thinking
    case responding
    case speaking
    case succeeded
    case stopped
    case failed
}

public enum AvatarProjectionError: Error, Equatable, Sendable {
    case invalidProjectionSequence
    case invalidCueIndex
    case unsafeInteger
    case nonFiniteEnvelope
    case invalidPhaseIdentity
    case mouthCueNotAdmitted
}

private enum AvatarProjectionContract {
    static let maximumSafeInteger: UInt64 = 9_007_199_254_740_991
}

public struct AvatarMouthCue: Codable, Equatable, Sendable {
    public let generationID: UUID
    public let playbackID: UUID
    public let cueIndex: UInt64
    public let playbackOffsetMilliseconds: UInt64
    public let envelope: Double

    public init(
        generationID: UUID,
        playbackID: UUID,
        cueIndex: UInt64,
        playbackOffsetMilliseconds: UInt64,
        envelope: Double
    ) throws {
        guard cueIndex > 0 else {
            throw AvatarProjectionError.invalidCueIndex
        }
        guard cueIndex <= AvatarProjectionContract.maximumSafeInteger,
              playbackOffsetMilliseconds <= AvatarProjectionContract.maximumSafeInteger
        else {
            throw AvatarProjectionError.unsafeInteger
        }
        guard envelope.isFinite else {
            throw AvatarProjectionError.nonFiniteEnvelope
        }

        self.generationID = generationID
        self.playbackID = playbackID
        self.cueIndex = cueIndex
        self.playbackOffsetMilliseconds = playbackOffsetMilliseconds
        self.envelope = min(max(envelope, 0), 1)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            generationID: container.decode(UUID.self, forKey: .generationID),
            playbackID: container.decode(UUID.self, forKey: .playbackID),
            cueIndex: container.decode(UInt64.self, forKey: .cueIndex),
            playbackOffsetMilliseconds: container.decode(
                UInt64.self,
                forKey: .playbackOffsetMilliseconds
            ),
            envelope: container.decode(Double.self, forKey: .envelope)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case generationID
        case playbackID
        case cueIndex
        case playbackOffsetMilliseconds
        case envelope
    }
}

public struct AvatarProjection: Codable, Equatable, Sendable {
    public let projectionSequence: UInt64
    public let generationID: UUID?
    public let phase: AvatarPresentationPhase
    public let visibility: AvatarVisibility
    public let reduceMotion: Bool
    public let playbackID: UUID?
    public let mouthCue: AvatarMouthCue?

    public init(
        projectionSequence: UInt64,
        generationID: UUID?,
        phase: AvatarPresentationPhase,
        visibility: AvatarVisibility,
        reduceMotion: Bool,
        playbackID: UUID?,
        mouthCue: AvatarMouthCue? = nil
    ) throws {
        guard projectionSequence > 0 else {
            throw AvatarProjectionError.invalidProjectionSequence
        }
        guard projectionSequence <= AvatarProjectionContract.maximumSafeInteger else {
            throw AvatarProjectionError.unsafeInteger
        }
        guard Self.phaseIdentityIsValid(
            phase: phase,
            generationID: generationID,
            playbackID: playbackID
        ) else {
            throw AvatarProjectionError.invalidPhaseIdentity
        }
        if let mouthCue {
            guard phase == .speaking,
                  visibility == .visible,
                  !reduceMotion,
                  generationID == mouthCue.generationID,
                  playbackID == mouthCue.playbackID
            else {
                throw AvatarProjectionError.mouthCueNotAdmitted
            }
        }

        self.projectionSequence = projectionSequence
        self.generationID = generationID
        self.phase = phase
        self.visibility = visibility
        self.reduceMotion = reduceMotion
        self.playbackID = playbackID
        self.mouthCue = mouthCue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectionSequence: container.decode(UInt64.self, forKey: .projectionSequence),
            generationID: container.decodeIfPresent(UUID.self, forKey: .generationID),
            phase: container.decode(AvatarPresentationPhase.self, forKey: .phase),
            visibility: container.decode(AvatarVisibility.self, forKey: .visibility),
            reduceMotion: container.decode(Bool.self, forKey: .reduceMotion),
            playbackID: container.decodeIfPresent(UUID.self, forKey: .playbackID),
            mouthCue: container.decodeIfPresent(AvatarMouthCue.self, forKey: .mouthCue)
        )
    }

    private static func phaseIdentityIsValid(
        phase: AvatarPresentationPhase,
        generationID: UUID?,
        playbackID: UUID?
    ) -> Bool {
        switch phase {
        case .speaking:
            generationID != nil && playbackID != nil
        case .thinking, .responding, .succeeded, .stopped, .failed:
            generationID != nil && playbackID == nil
        case .idle, .listening, .transcribing:
            generationID == nil && playbackID == nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case projectionSequence
        case generationID
        case phase
        case visibility
        case reduceMotion
        case playbackID
        case mouthCue
    }
}

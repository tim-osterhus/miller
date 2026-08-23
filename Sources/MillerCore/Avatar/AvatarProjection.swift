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

/// Optional five-vowel weights carried across Miller's typed Avatar boundary.
///
/// Native analyser output is clamped at construction. Decoding is deliberately
/// strict so an externally supplied present object cannot silently degrade to a
/// scalar-only cue.
public struct AvatarVowelWeights: Codable, Equatable, Sendable {
    public let aa: Double
    public let ih: Double
    public let ou: Double
    public let ee: Double
    public let oh: Double

    public init(aa: Double, ih: Double, ou: Double, ee: Double, oh: Double) {
        self.init(clamping: aa, ih: ih, ou: ou, ee: ee, oh: oh)
    }

    init(clamping aa: Double, ih: Double, ou: Double, ee: Double, oh: Double) {
        self.aa = Self.clamp(aa)
        self.ih = Self.clamp(ih)
        self.ou = Self.clamp(ou)
        self.ee = Self.clamp(ee)
        self.oh = Self.clamp(oh)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let expectedKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let actualKeys = Set(container.allKeys.map(\.stringValue))
        guard actualKeys == expectedKeys else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyCodingKey(stringValue: "aa")!,
                in: container,
                debugDescription: "vowel weights must contain exactly aa, ih, ou, ee, and oh"
            )
        }

        let values = try [
            container.decode(Double.self, forKey: AnyCodingKey(stringValue: "aa")!),
            container.decode(Double.self, forKey: AnyCodingKey(stringValue: "ih")!),
            container.decode(Double.self, forKey: AnyCodingKey(stringValue: "ou")!),
            container.decode(Double.self, forKey: AnyCodingKey(stringValue: "ee")!),
            container.decode(Double.self, forKey: AnyCodingKey(stringValue: "oh")!),
        ]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyCodingKey(stringValue: "aa")!,
                in: container,
                debugDescription: "vowel weights must be finite and within 0...1"
            )
        }
        self.init(
            uncheckedAA: values[0],
            ih: values[1],
            ou: values[2],
            ee: values[3],
            oh: values[4]
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aa, forKey: .aa)
        try container.encode(ih, forKey: .ih)
        try container.encode(ou, forKey: .ou)
        try container.encode(ee, forKey: .ee)
        try container.encode(oh, forKey: .oh)
    }

    private init(
        uncheckedAA aa: Double,
        ih: Double,
        ou: Double,
        ee: Double,
        oh: Double
    ) {
        self.aa = aa
        self.ih = ih
        self.ou = ou
        self.ee = ee
        self.oh = oh
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case aa
        case ih
        case ou
        case ee
        case oh
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct AvatarMouthCue: Codable, Equatable, Sendable {
    public let generationID: UUID
    public let playbackID: UUID
    public let cueIndex: UInt64
    public let playbackOffsetMilliseconds: UInt64
    public let envelope: Double
    public let vowels: AvatarVowelWeights?

    public init(
        generationID: UUID,
        playbackID: UUID,
        cueIndex: UInt64,
        playbackOffsetMilliseconds: UInt64,
        envelope: Double,
        vowels: AvatarVowelWeights? = nil
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
        self.vowels = vowels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let vowels = container.contains(.vowels)
            ? try container.decode(AvatarVowelWeights.self, forKey: .vowels)
            : nil
        try self.init(
            generationID: container.decode(UUID.self, forKey: .generationID),
            playbackID: container.decode(UUID.self, forKey: .playbackID),
            cueIndex: container.decode(UInt64.self, forKey: .cueIndex),
            playbackOffsetMilliseconds: container.decode(
                UInt64.self,
                forKey: .playbackOffsetMilliseconds
            ),
            envelope: container.decode(Double.self, forKey: .envelope),
            vowels: vowels
        )
    }

    private enum CodingKeys: String, CodingKey {
        case generationID
        case playbackID
        case cueIndex
        case playbackOffsetMilliseconds
        case envelope
        case vowels
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

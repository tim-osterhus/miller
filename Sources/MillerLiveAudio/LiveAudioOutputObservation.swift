import Foundation

/// Bounded vowel weights derived from the played remote output stream.
///
/// The public initializer is deliberately forgiving for native callers. JSON
/// decoding is strict, and the peer's payload decoder treats a failed decode
/// as scalar-only output instead of failing the live session.
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

/// A bounded observation of the audio element that plays the admitted remote
/// WebRTC stream. It intentionally contains no PCM, media object, or provider
/// data.
public struct LiveAudioOutputSample: Equatable, Sendable {
    public let isPlaying: Bool
    public let outputBufferActive: Bool?
    public let offsetMilliseconds: UInt64
    public let envelope: Double
    public let vowels: AvatarVowelWeights?

    public init(
        isPlaying: Bool,
        outputBufferActive: Bool? = nil,
        offsetMilliseconds: UInt64,
        envelope: Double,
        vowels: AvatarVowelWeights? = nil
    ) {
        self.isPlaying = isPlaying
        self.outputBufferActive = outputBufferActive
        self.offsetMilliseconds = offsetMilliseconds
        self.envelope = envelope
        self.vowels = vowels
    }
}

/// Miller-side lifecycle inputs derived from played remote output. Playback
/// and cue identities are assigned by the Miller presentation coordinator,
/// not by this low-level observer.
public enum LiveAudioOutputObservation: Equatable, Sendable {
    case playbackStarted(offsetMilliseconds: UInt64)
    case mouthCue(
        offsetMilliseconds: UInt64,
        envelope: Double,
        vowels: AvatarVowelWeights? = nil
    )
    case playbackStopped(offsetMilliseconds: UInt64)
}

/// Deterministic native hysteresis for remote played-output samples.
///
/// The processor accepts at most one sample every 34 ms (strictly below
/// 30 Hz), requires two consecutive above-threshold samples to attack, and
/// uses an authoritative WebRTC output-buffer boundary when available, and
/// otherwise releases after 400 ms without an above-threshold sample. The
/// explicit time overload keeps tests deterministic; the convenience overload
/// uses the sample's monotonic playback offset as its clock.
public struct LiveAudioOutputObservationProcessor: Sendable {
    public static let maximumSampleRateHz = 30
    public static let minimumSampleIntervalMilliseconds: UInt64 = 34
    public static let silenceReleaseMilliseconds: UInt64 = 400

    private static let speakingThreshold = 0.05
    private static let maximumSafeInteger: UInt64 = 9_007_199_254_740_991

    private let threshold: Double
    private let releaseAfterMilliseconds: UInt64
    private var lastAcceptedTimestampMilliseconds: UInt64?
    private var lastOffsetMilliseconds: UInt64 = 0
    private var consecutiveAboveThreshold = 0
    private var lastAboveThresholdTimestampMilliseconds: UInt64?
    private var active = false

    public init() {
        self.init(
            threshold: Self.speakingThreshold,
            releaseAfterMilliseconds: Self.silenceReleaseMilliseconds
        )
    }

    init(threshold: Double, releaseAfterMilliseconds: UInt64) {
        self.threshold = threshold.isFinite
            ? min(max(threshold, 0), 1)
            : Self.speakingThreshold
        self.releaseAfterMilliseconds = releaseAfterMilliseconds
    }

    public var isActive: Bool { active }

    public mutating func observe(
        _ sample: LiveAudioOutputSample
    ) -> [LiveAudioOutputObservation] {
        observe(sample, atMilliseconds: sample.offsetMilliseconds)
    }

    public mutating func observe(
        _ sample: LiveAudioOutputSample,
        atMilliseconds timestampMilliseconds: UInt64
    ) -> [LiveAudioOutputObservation] {
        let timestamp = max(
            timestampMilliseconds,
            lastAcceptedTimestampMilliseconds ?? timestampMilliseconds
        )
        if let lastAcceptedTimestampMilliseconds {
            guard timestamp >= lastAcceptedTimestampMilliseconds,
                  timestamp - lastAcceptedTimestampMilliseconds
                    >= Self.minimumSampleIntervalMilliseconds
            else { return [] }
        }
        lastAcceptedTimestampMilliseconds = timestamp

        let offset = min(
            max(lastOffsetMilliseconds, sample.offsetMilliseconds),
            Self.maximumSafeInteger
        )
        lastOffsetMilliseconds = offset
        let envelope = Self.sanitizeEnvelope(sample.envelope)
        if active, sample.outputBufferActive == false {
            active = false
            consecutiveAboveThreshold = 0
            lastAboveThresholdTimestampMilliseconds = nil
            return [.playbackStopped(offsetMilliseconds: offset)]
        }

        let aboveThreshold = sample.isPlaying
            && sample.outputBufferActive != false
            && envelope > threshold
        if aboveThreshold {
            consecutiveAboveThreshold = min(consecutiveAboveThreshold + 1, 2)
            lastAboveThresholdTimestampMilliseconds = timestamp
        } else {
            consecutiveAboveThreshold = 0
        }

        if !active {
            guard aboveThreshold, consecutiveAboveThreshold >= 2 else {
                return []
            }
            active = true
            return [
                .playbackStarted(offsetMilliseconds: offset),
                .mouthCue(
                    offsetMilliseconds: offset,
                    envelope: envelope,
                    vowels: sample.vowels
                ),
            ]
        }

        if aboveThreshold {
            return [
                .mouthCue(
                    offsetMilliseconds: offset,
                    envelope: envelope,
                    vowels: sample.vowels
                ),
            ]
        }

        guard sample.outputBufferActive == nil,
              let lastAboveThresholdTimestampMilliseconds,
              timestamp >= lastAboveThresholdTimestampMilliseconds,
              timestamp - lastAboveThresholdTimestampMilliseconds
                >= releaseAfterMilliseconds
        else { return [] }

        active = false
        self.lastAboveThresholdTimestampMilliseconds = nil
        return [.playbackStopped(offsetMilliseconds: offset)]
    }

    /// Immediately ends a currently active playback segment. Repeated calls
    /// are idempotent and produce no duplicate stop input.
    public mutating func stop() -> [LiveAudioOutputObservation] {
        guard active else {
            consecutiveAboveThreshold = 0
            lastAboveThresholdTimestampMilliseconds = nil
            return []
        }
        active = false
        consecutiveAboveThreshold = 0
        lastAboveThresholdTimestampMilliseconds = nil
        return [.playbackStopped(offsetMilliseconds: lastOffsetMilliseconds)]
    }

    public mutating func reset() -> [LiveAudioOutputObservation] {
        let observations = stop()
        lastAcceptedTimestampMilliseconds = nil
        lastOffsetMilliseconds = 0
        return observations
    }

    private static func sanitizeEnvelope(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

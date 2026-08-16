import Foundation

/// A bounded observation of the audio element that plays the admitted remote
/// WebRTC stream. It intentionally contains no PCM, media object, or provider
/// data.
public struct LiveAudioOutputSample: Equatable, Sendable {
    public let isPlaying: Bool
    public let offsetMilliseconds: UInt64
    public let envelope: Double

    public init(
        isPlaying: Bool,
        offsetMilliseconds: UInt64,
        envelope: Double
    ) {
        self.isPlaying = isPlaying
        self.offsetMilliseconds = offsetMilliseconds
        self.envelope = envelope
    }
}

/// Miller-side lifecycle inputs derived from played remote output. Playback
/// and cue identities are assigned by the Miller presentation coordinator,
/// not by this low-level observer.
public enum LiveAudioOutputObservation: Equatable, Sendable {
    case playbackStarted(offsetMilliseconds: UInt64)
    case mouthCue(offsetMilliseconds: UInt64, envelope: Double)
    case playbackStopped(offsetMilliseconds: UInt64)
}

/// Deterministic native hysteresis for remote played-output samples.
///
/// The processor accepts at most one sample every 34 ms (strictly below
/// 30 Hz), requires two consecutive above-threshold samples to attack, and
/// releases after 400 ms without an above-threshold sample. The explicit time
/// overload keeps tests deterministic; the convenience overload uses the
/// sample's monotonic playback offset as its clock.
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
        let aboveThreshold = sample.isPlaying && envelope > threshold
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
                .mouthCue(offsetMilliseconds: offset, envelope: envelope),
            ]
        }

        if aboveThreshold {
            return [.mouthCue(offsetMilliseconds: offset, envelope: envelope)]
        }

        guard let lastAboveThresholdTimestampMilliseconds,
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

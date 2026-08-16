import Foundation
import Testing
@testable import MillerLiveAudio

@Suite("Live audio output observation")
struct LiveAudioOutputObservationTests {
    @Test
    func twoConsecutiveAudibleSamplesStartOnePlaybackAndEmitOrderedCues() {
        var observation = LiveAudioOutputObservationProcessor()

        #expect(observation.observe(
            sample(isPlaying: true, offset: 100, envelope: 0.5),
            atMilliseconds: 0
        ).isEmpty)

        let started = observation.observe(
            sample(isPlaying: true, offset: 132, envelope: 0.75),
            atMilliseconds: 34
        )

        #expect(started == [
            .playbackStarted(offsetMilliseconds: 132),
            .mouthCue(offsetMilliseconds: 132, envelope: 0.75),
        ])

        let cue = observation.observe(
            sample(isPlaying: true, offset: 164, envelope: 0.25),
            atMilliseconds: 68
        )
        #expect(cue == [
            .mouthCue(offsetMilliseconds: 164, envelope: 0.25),
        ])
    }

    @Test
    func nonFiniteAndBelowThresholdSamplesCannotStartPlayback() {
        var observation = LiveAudioOutputObservationProcessor()

        for (index, envelope) in [Double.nan, .infinity, -.infinity, 0.01]
            .enumerated()
        {
            #expect(observation.observe(
                sample(isPlaying: true, offset: UInt64(index * 34), envelope: envelope),
                atMilliseconds: UInt64(index * 34)
            ).isEmpty)
        }
    }

    @Test
    func silenceReleasesAfterFourHundredMillisecondsAndCleanupIsImmediate() {
        var observation = LiveAudioOutputObservationProcessor()
        _ = observation.observe(
            sample(isPlaying: true, offset: 0, envelope: 0.5), atMilliseconds: 0
        )
        _ = observation.observe(
            sample(isPlaying: true, offset: 34, envelope: 0.5), atMilliseconds: 34
        )

        #expect(observation.observe(
            sample(isPlaying: true, offset: 400, envelope: 0), atMilliseconds: 399
        ).isEmpty)
        #expect(observation.observe(
            sample(isPlaying: true, offset: 434, envelope: 0), atMilliseconds: 434
        ) == [.playbackStopped(offsetMilliseconds: 434)])

        _ = observation.observe(
            sample(isPlaying: true, offset: 500, envelope: 0.5), atMilliseconds: 500
        )
        #expect(observation.observe(
            sample(isPlaying: true, offset: 534, envelope: 0.5), atMilliseconds: 534
        ).first == .playbackStarted(offsetMilliseconds: 534))
        #expect(observation.stop() == [.playbackStopped(offsetMilliseconds: 534)])
    }

    @Test
    func offsetsAreMonotonicAndSamplesAreRateLimitedToThirtyHertz() {
        var observation = LiveAudioOutputObservationProcessor()
        _ = observation.observe(
            sample(isPlaying: true, offset: 200, envelope: 0.5), atMilliseconds: 0
        )
        let started = observation.observe(
            sample(isPlaying: true, offset: 100, envelope: 0.5), atMilliseconds: 34
        )
        #expect(started.contains(.playbackStarted(offsetMilliseconds: 200)))

        #expect(observation.observe(
            sample(isPlaying: true, offset: 300, envelope: 0.5), atMilliseconds: 40
        ).isEmpty)
        let cue = observation.observe(
            sample(isPlaying: true, offset: 250, envelope: 0.5), atMilliseconds: 68
        )
        #expect(cue == [
            .mouthCue(offsetMilliseconds: 250, envelope: 0.5),
        ])
    }

    private func sample(
        isPlaying: Bool,
        offset: UInt64,
        envelope: Double
    ) -> LiveAudioOutputSample {
        LiveAudioOutputSample(
            isPlaying: isPlaying,
            offsetMilliseconds: offset,
            envelope: envelope
        )
    }
}

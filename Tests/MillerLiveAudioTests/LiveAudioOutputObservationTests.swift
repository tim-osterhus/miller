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
    func authoritativeOutputBufferKeepsOnePlaybackAcrossSentenceSilence() {
        var observation = LiveAudioOutputObservationProcessor()
        _ = observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: true,
                offset: 0,
                envelope: 0.5
            ),
            atMilliseconds: 0
        )
        _ = observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: true,
                offset: 34,
                envelope: 0.5
            ),
            atMilliseconds: 34
        )

        #expect(observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: true,
                offset: 434,
                envelope: 0
            ),
            atMilliseconds: 434
        ).isEmpty)
        #expect(observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: true,
                offset: 2_000,
                envelope: 0
            ),
            atMilliseconds: 2_000
        ).isEmpty)
        #expect(observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: false,
                offset: 2_034,
                envelope: 0
            ),
            atMilliseconds: 2_034
        ) == [.playbackStopped(offsetMilliseconds: 2_034)])
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

    @Test
    func enrichedSamplesCarryCompleteVowelsWithoutChangingSpeakingThreshold() {
        let vowels = AvatarVowelWeights(
            aa: 0.1,
            ih: 0.2,
            ou: 0.3,
            ee: 0.4,
            oh: 0.5
        )
        var observation = LiveAudioOutputObservationProcessor()

        #expect(observation.observe(
            sample(isPlaying: true, offset: 100, envelope: 0.05),
            atMilliseconds: 0
        ).isEmpty)

        #expect(observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: true,
                offset: 132,
                envelope: 0.06,
                vowels: vowels
            ),
            atMilliseconds: 34
        ).isEmpty)

        let started = observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: true,
                offset: 164,
                envelope: 0.06,
                vowels: vowels
            ),
            atMilliseconds: 68
        )

        #expect(started == [
            .playbackStarted(offsetMilliseconds: 164),
            .mouthCue(offsetMilliseconds: 164, envelope: 0.06, vowels: vowels),
        ])

        #expect(observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: true,
                offset: 198,
                envelope: 0,
                vowels: vowels
            ),
            atMilliseconds: 102
        ).isEmpty)

        #expect(observation.observe(
            sample(
                isPlaying: true,
                outputBufferActive: false,
                offset: 232,
                envelope: 0,
                vowels: vowels
            ),
            atMilliseconds: 136
        ) == [.playbackStopped(offsetMilliseconds: 232)])
    }

    @Test
    func avatarVowelWeightsDecodeOnlyCompleteFiniteBoundedObjects() throws {
        let valid = Data(
            "{\"aa\":0.1,\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5}".utf8
        )
        #expect(try JSONDecoder().decode(AvatarVowelWeights.self, from: valid) == AvatarVowelWeights(
            aa: 0.1,
            ih: 0.2,
            ou: 0.3,
            ee: 0.4,
            oh: 0.5
        ))

        for invalid in [
            "{}",
            "{\"aa\":0.1}",
            "{\"aa\":2,\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5}",
            "{\"aa\":\"NaN\",\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5}",
            "{\"aa\":1e400,\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5}",
            "{\"aa\":0.1,\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5,\"extra\":0}",
        ] {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    AvatarVowelWeights.self,
                    from: Data(invalid.utf8)
                )
            }
        }
    }

    private func sample(
        isPlaying: Bool,
        outputBufferActive: Bool? = nil,
        offset: UInt64,
        envelope: Double,
        vowels: AvatarVowelWeights? = nil
    ) -> LiveAudioOutputSample {
        LiveAudioOutputSample(
            isPlaying: isPlaying,
            outputBufferActive: outputBufferActive,
            offsetMilliseconds: offset,
            envelope: envelope,
            vowels: vowels
        )
    }
}

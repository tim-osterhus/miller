import Foundation
import MillerCore
import MillerLiveAudio
import Testing
@testable import MillerApp

@Suite("Avatar played-output projection")
@MainActor
struct AvatarOutputProjectionTests {
    @Test
    func closedLiveStateImmediatelyNeutralizesMeasuredPlayback() throws {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 10),
            for: sessionID
        )
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 20, envelope: 0.9),
            for: sessionID
        )
        let prior = try #require(projections.last)

        coordinator.projectLiveState(.closed, for: sessionID)

        let closed = try #require(projections.last)
        #expect(closed.projectionSequence > prior.projectionSequence)
        #expect(closed.phase == .idle)
        #expect(closed.playbackID == nil)
        #expect(closed.mouthCue == nil)

        let countAfterClose = projections.count
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 30, envelope: 0.9),
            for: sessionID
        )
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 40),
            for: sessionID
        )
        #expect(projections.count == countAfterClose)
        #expect(coordinator.lastProjection?.phase == .idle)
        #expect(coordinator.lastProjection?.playbackID == nil)
        #expect(coordinator.lastProjection?.mouthCue == nil)
    }

    @Test(arguments: AvatarOutputClearTrigger.allCases)
    func rendererAndAvatarPolicyClearsFenceMouthCues(
        _ trigger: AvatarOutputClearTrigger
    ) throws {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveState(.responding, for: sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 10),
            for: sessionID
        )
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 20, envelope: 0.9),
            for: sessionID
        )
        let prior = try #require(projections.last)

        switch trigger {
        case .rendererLoss, .avatarDisabled:
            coordinator.clearPresentation()
        case .hidden:
            coordinator.setPresentationPolicy(
                visibility: .hidden,
                reduceMotion: false
            )
        case .occluded:
            coordinator.setPresentationPolicy(
                visibility: .occluded,
                reduceMotion: false
            )
        case .reducedMotion:
            coordinator.setPresentationPolicy(
                visibility: .visible,
                reduceMotion: true
            )
        }

        let countAfterClear = projections.count
        let clearing = try #require(projections.last)
        #expect(clearing.projectionSequence > prior.projectionSequence)
        #expect(clearing.mouthCue == nil)
        #expect(clearing.playbackID == nil)

        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 30, envelope: 0.9),
            for: sessionID
        )
        #expect(projections.count == countAfterClear)
        #expect(coordinator.lastProjection?.mouthCue == nil)
    }

    @Test
    func onlyMeasuredOutputCreatesSpeakingAndOrderedMouthCues() throws {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()
        let generationID = coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveState(.responding, for: sessionID)

        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 100),
            for: sessionID
        )
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 132, envelope: 0.8),
            for: sessionID
        )
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 120, envelope: 0.4),
            for: sessionID
        )
        coordinator.projectLiveOutput(
            .playbackStopped(offsetMilliseconds: 132),
            for: sessionID
        )

        #expect(projections.map(\.phase) == [
            .idle, .responding, .speaking, .speaking, .speaking, .speaking,
        ])
        let speaking = projections.filter { $0.phase == .speaking }
        #expect(speaking.allSatisfy {
            $0.generationID == generationID && $0.playbackID != nil
        })
        let cues = speaking.compactMap(\.mouthCue)
        #expect(cues.map(\.cueIndex) == [1, 2, 3])
        #expect(cues.map(\.playbackOffsetMilliseconds) == [132, 132, 132])
        #expect(cues.map(\.envelope) == [0.8, 0.4, 0])
        #expect(Set(speaking.compactMap(\.playbackID)).count == 1)
    }

    @Test
    func providerSpeakingWithoutMeasuredOutputRemainsResponding() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveState(.speaking, for: sessionID)

        #expect(projections.last?.phase == .responding)
        #expect(projections.last?.mouthCue == nil)
    }

    @Test
    func sentenceSilenceKeepsOneSpeakingLeaseUntilAnAuthoritativePhaseChange() throws {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 10), for: sessionID
        )
        let playbackID = try #require(coordinator.currentPlaybackID)
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 15, envelope: 0.7), for: sessionID
        )
        coordinator.projectLiveOutput(
            .playbackStopped(offsetMilliseconds: 20), for: sessionID
        )
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 30), for: sessionID
        )
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 35, envelope: 0.5), for: sessionID
        )

        #expect(coordinator.currentPlaybackID == playbackID)
        #expect(projections.suffix(4).allSatisfy { $0.phase == .speaking })
        #expect(projections.compactMap(\.playbackID).allSatisfy { $0 == playbackID })
        #expect(projections.compactMap(\.mouthCue).map(\.cueIndex) == [1, 2, 3])
        #expect(projections.compactMap(\.mouthCue).map(\.envelope) == [0.7, 0, 0.5])

        coordinator.projectLiveState(.listening, for: sessionID)

        #expect(coordinator.currentPlaybackID == nil)
        #expect(projections.last?.phase == .listening)
        #expect(projections.last?.playbackID == nil)
        #expect(projections.last?.mouthCue == nil)
    }

    @Test
    func finalResponseSilenceExpiresTheSpeakingLease() async {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator(
            speakingSilenceGrace: .zero
        ) {
            projections.append($0)
        }
        let sessionID = UUID()

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 10), for: sessionID
        )
        coordinator.projectLiveOutput(
            .playbackStopped(offsetMilliseconds: 20), for: sessionID
        )
        for _ in 0..<8 where coordinator.currentPlaybackID != nil {
            await Task.yield()
        }

        #expect(coordinator.currentPlaybackID == nil)
        #expect(projections.last?.phase == .responding)
        #expect(projections.last?.playbackID == nil)
        #expect(projections.last?.mouthCue == nil)
    }

    @Test
    func reentrantDuplicateStopEmitsOnlyOneZeroCue() {
        var projections = [AvatarProjection]()
        var coordinator: AvatarProjectionCoordinator!
        let sessionID = UUID()
        var reentered = false
        coordinator = AvatarProjectionCoordinator { projection in
            projections.append(projection)
            guard projection.mouthCue?.envelope == 0, !reentered else { return }
            reentered = true
            coordinator.projectLiveOutput(
                .playbackStopped(offsetMilliseconds: 20), for: sessionID
            )
        }

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 10), for: sessionID
        )
        coordinator.projectLiveOutput(
            .playbackStopped(offsetMilliseconds: 20), for: sessionID
        )

        #expect(projections.compactMap(\.mouthCue).filter { $0.envelope == 0 }.count == 1)
        #expect(coordinator.currentPlaybackID != nil)
    }

    @Test(arguments: [AvatarVisibility.occluded, .hidden])
    func policyClearsPlaybackAndRejectsLaterSamples(
        visibility: AvatarVisibility
    ) {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveState(.responding, for: sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 10), for: sessionID
        )
        coordinator.setPresentationPolicy(
            visibility: visibility,
            reduceMotion: false
        )
        let countAfterPolicy = projections.count
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 20, envelope: 0.9), for: sessionID
        )

        #expect(projections[countAfterPolicy - 1].mouthCue == nil)
        #expect(projections.last?.mouthCue == nil)
        #expect(projections.last?.phase != .speaking)
    }

    @Test
    func resetFencesLateOutputAndReturnsToNeutral() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 10), for: sessionID
        )
        coordinator.resetLiveSession(sessionID)
        let countAfterReset = projections.count
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 20, envelope: 0.9), for: sessionID
        )

        #expect(projections.last?.phase == .idle)
        #expect(projections.last?.mouthCue == nil)
        #expect(projections.count == countAfterReset)
    }
}

enum AvatarOutputClearTrigger: CaseIterable, Sendable {
    case rendererLoss
    case avatarDisabled
    case hidden
    case occluded
    case reducedMotion
}

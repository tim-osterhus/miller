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
            .idle, .responding, .speaking, .speaking, .speaking, .responding,
        ])
        let speaking = projections.filter { $0.phase == .speaking }
        #expect(speaking.allSatisfy {
            $0.generationID == generationID && $0.playbackID != nil
        })
        let cues = speaking.compactMap(\.mouthCue)
        #expect(cues.map(\.cueIndex) == [1, 2])
        #expect(cues.map(\.playbackOffsetMilliseconds) == [132, 132])
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
    func measuredOutputReturnsToRespondingAfterSilence() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
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

        #expect(projections.map(\.phase).last == .responding)
        #expect(projections.last?.mouthCue == nil)
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

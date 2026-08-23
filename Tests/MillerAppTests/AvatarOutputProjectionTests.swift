import Foundation
import MillerAvatarCore
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
    func enrichedPlayedOutputPreservesVowelsAtTheProjectionBoundary() throws {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()
        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 100),
            for: sessionID
        )
        let vowels = MillerLiveAudio.AvatarVowelWeights(
            aa: 0,
            ih: 0.62,
            ou: 0,
            ee: 0.1,
            oh: 0
        )
        coordinator.projectLiveOutput(
            .mouthCue(
                offsetMilliseconds: 132,
                envelope: 0.62,
                vowels: vowels
            ),
            for: sessionID
        )

        let cue = try #require(projections.last?.mouthCue)
        #expect(cue.envelope == 0.62)
        #expect(cue.vowels?.ih == 0.62)
        #expect(cue.vowels?.ee == 0.1)
    }

    @Test
    func mouthPolicyOffClearsOnceWithoutRestartingPlaybackOrReplayingOldCue() throws {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let sessionID = UUID()
        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 100),
            for: sessionID
        )
        let playbackID = try #require(coordinator.currentPlaybackID)
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 132, envelope: 0.8),
            for: sessionID
        )
        let countBeforeOff = projections.count

        coordinator.setMouthCuesEnabled(false)
        #expect(projections.count == countBeforeOff + 1)
        #expect(coordinator.currentPlaybackID == playbackID)
        #expect(projections.last?.phase == .speaking)
        #expect(projections.last?.mouthCue == nil)

        let countAfterOff = projections.count
        coordinator.setMouthCuesEnabled(false)
        #expect(projections.count == countAfterOff)

        coordinator.setMouthCuesEnabled(true)
        #expect(projections.count == countAfterOff)
        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 164, envelope: 0.4),
            for: sessionID
        )
        #expect(projections.last?.mouthCue?.envelope == 0.4)
        #expect(coordinator.currentPlaybackID == playbackID)
    }

    @Test
    func validNeutralFixturePolicyCycleExercisesPackageReducer() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Tests/MillerCoreTests/Fixtures/Avatar/valid.json"
            )
        let data = try Data(contentsOf: fixtureURL)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let operations = try #require(root["operations"] as? [[String: Any]])
        #expect(operations.count == 23)

        var state = MillerAvatarCore.ProjectionState()
        var sawPolicyOff = false
        var sawSuppressedCue = false
        var sawPolicyOn = false

        for operation in operations {
            let name = try #require(operation["name"] as? String)
            let input = try neutralFixtureProjectionInput(operation["input"])
            let result = MillerAvatarCore.ProjectionReducer.reduce(
                state: state,
                input: input
            )
            state = result.state

            switch name {
            case "mouth-policy-off":
                sawPolicyOff = true
                #expect(state.mouthCuesEnabled == false)
                #expect(state.lastCueIndex == 3)
                #expect(state.mouthScalar == 0)
                #expect(state.mouthVowels == nil)
                #expect(result.effects == [
                    .setMouthCuesEnabled(false), .clearMouth,
                ])
            case "suppressed-mouth-cue-four":
                sawSuppressedCue = true
                #expect(state.mouthCuesEnabled == false)
                #expect(state.lastCueIndex == 4)
                #expect(state.lastPlaybackOffsetMilliseconds == 400)
                #expect(state.mouthScalar == 0)
                #expect(state.mouthVowels == nil)
                #expect(result.effects.isEmpty)
            case "mouth-policy-on":
                sawPolicyOn = true
                #expect(state.mouthCuesEnabled)
                #expect(state.lastCueIndex == 4)
                #expect(state.mouthScalar == 0)
                #expect(state.mouthVowels == nil)
                #expect(result.effects == [.setMouthCuesEnabled(true)])
            case "mouth-cue-five-scalar-only-after-re-enable":
                #expect(sawPolicyOff && sawSuppressedCue && sawPolicyOn)
                #expect(state.lastCueIndex == 5)
                #expect(state.lastPlaybackOffsetMilliseconds == 500)
                #expect(state.mouthScalar == 0.5)
                #expect(state.mouthVowels == nil)
                #expect(result.effects.count == 1)
                guard case .applyMouth(let payload) = result.effects.first else {
                    Issue.record("The fresh scalar cue must be applied")
                    continue
                }
                #expect(payload.cueIndex == 5)
                #expect(payload.vowels == nil)
            default:
                break
            }
        }

        #expect(sawPolicyOff)
        #expect(sawSuppressedCue)
        #expect(sawPolicyOn)
    }

    @Test
    func invalidNeutralFixtureRejectsStaleCueAfterPolicyCycle() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Tests/MillerCoreTests/Fixtures/Avatar/invalid.json"
            )
        let data = try Data(contentsOf: fixtureURL)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let cases = try #require(root["cases"] as? [[String: Any]])
        let testCase = try #require(
            cases.first { $0["name"] as? String == "stale-cue-after-policy-cycle" }
        )
        let prelude = try #require(testCase["prelude"] as? [[String: Any]])

        var state = MillerAvatarCore.ProjectionState()
        for input in prelude {
            state = MillerAvatarCore.ProjectionReducer.reduce(
                state: state,
                input: try neutralFixtureProjectionInput(input)
            ).state
        }
        let before = state
        let result = MillerAvatarCore.ProjectionReducer.reduce(
            state: state,
            input: try neutralFixtureProjectionInput(testCase["input"])
        )

        #expect(result.effects.isEmpty)
        #expect(result.state.lastCueIndex == before.lastCueIndex)
        #expect(
            result.state.lastPlaybackOffsetMilliseconds
                == before.lastPlaybackOffsetMilliseconds
        )
        #expect(result.state.mouthScalar == 0)
        #expect(result.state.mouthVowels == nil)
        #expect(result.state.mouthCuesEnabled)
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

private enum NeutralFixtureProjectionError: Error {
    case invalid
}

private func neutralFixtureProjectionInput(
    _ value: Any?
) throws -> MillerAvatarCore.ProjectionInput {
    guard let input = value as? [String: Any],
          let type = input["type"] as? String
    else { throw NeutralFixtureProjectionError.invalid }

    switch type {
    case "project":
        guard let sequence = neutralFixtureUInt(input["projection_sequence"]),
              let phase = (input["phase"] as? String).flatMap(
                  MillerAvatarCore.PresentationPhase.init(rawValue:)
              )
        else { throw NeutralFixtureProjectionError.invalid }
        return .project(MillerAvatarCore.ProjectPhasePayload(
            projectionSequence: sequence,
            generationID: try neutralFixtureUUID(input["generation_id"]),
            phase: phase,
            playbackID: try neutralFixtureUUID(input["playback_id"])
        ))
    case "mouth":
        guard let generationID = try neutralFixtureUUID(input["generation_id"]),
              let playbackID = try neutralFixtureUUID(input["playback_id"]),
              let cueIndex = neutralFixtureUInt(input["cue_index"]),
              let offset = neutralFixtureUInt(input["playback_offset_ms"]),
              let scalar = (input["scalar"] as? NSNumber)?.doubleValue
        else { throw NeutralFixtureProjectionError.invalid }
        return .mouth(MillerAvatarCore.SetMouthPayload(
            generationID: generationID,
            playbackID: playbackID,
            cueIndex: cueIndex,
            playbackOffsetMilliseconds: offset,
            scalar: scalar,
            vowels: try neutralFixtureVowels(input["vowels"])
        ))
    case "set_mouth_cues_enabled":
        guard let enabled = input["enabled"] as? Bool else {
            throw NeutralFixtureProjectionError.invalid
        }
        return .setMouthCuesEnabled(enabled)
    case "set_reduced_motion":
        guard let enabled = input["enabled"] as? Bool else {
            throw NeutralFixtureProjectionError.invalid
        }
        return .setReducedMotion(enabled)
    case "suspend":
        return .suspend
    case "resume":
        return .resume
    case "reset":
        guard let reasonRawValue = input["reason"] as? String,
              let reason = MillerAvatarCore.ResetReason(rawValue: reasonRawValue)
        else { throw NeutralFixtureProjectionError.invalid }
        return .reset(
            generationID: try neutralFixtureUUID(input["generation_id"]),
            reason: reason
        )
    default:
        throw NeutralFixtureProjectionError.invalid
    }
}

private func neutralFixtureUUID(_ value: Any?) throws -> UUID? {
    if value == nil || value is NSNull { return nil }
    guard let string = value as? String,
          let uuid = UUID(uuidString: string)
    else { throw NeutralFixtureProjectionError.invalid }
    return uuid
}

private func neutralFixtureUInt(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber,
          number.doubleValue.isFinite,
          number.doubleValue.rounded(.towardZero) == number.doubleValue,
          number.doubleValue >= 0
    else { return nil }
    return number.uint64Value
}

private func neutralFixtureVowels(
    _ value: Any?
) throws -> MillerAvatarCore.MouthVowelWeights? {
    if value == nil || value is NSNull { return nil }
    guard let values = value as? [String: Any],
          let aa = (values["aa"] as? NSNumber)?.doubleValue,
          let ih = (values["ih"] as? NSNumber)?.doubleValue,
          let ou = (values["ou"] as? NSNumber)?.doubleValue,
          let ee = (values["ee"] as? NSNumber)?.doubleValue,
          let oh = (values["oh"] as? NSNumber)?.doubleValue
    else { throw NeutralFixtureProjectionError.invalid }
    return MillerAvatarCore.MouthVowelWeights(
        aa: aa,
        ih: ih,
        ou: ou,
        ee: ee,
        oh: oh
    )
}

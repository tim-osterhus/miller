import Foundation
import MillerCore
import Testing
@testable import MillerApp

@Suite
@MainActor
struct AvatarProjectionCoordinatorTests {
    @Test
    func typedTurnUsesOneGenerationAndMapsSemanticStates() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator { projections.append($0) }
        let turnID = TurnID(rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)

        let generationID = coordinator.beginTypedTurn(turnID)
        coordinator.projectTypedState(.waiting, for: turnID)
        coordinator.projectTypedState(.waiting, for: turnID)
        coordinator.projectTypedState(.responding, for: turnID)
        coordinator.projectTypedState(.responding, for: turnID)
        coordinator.projectTypedState(.speaking, for: turnID)
        coordinator.projectTypedState(.completed, for: turnID)
        coordinator.projectTypedState(.responding, for: turnID)

        #expect(projections.map(\.phase) == [
            .thinking, .responding, .succeeded,
        ])
        #expect(projections.dropFirst().allSatisfy {
            $0.generationID == generationID
        })
        #expect(projections.allSatisfy { $0.playbackID == nil })
        #expect(projections.map(\.projectionSequence) == [1, 2, 3])
    }

    @Test
    func liveSessionMapsConnectingToIdleWithoutClaimingSpeaking() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator { projections.append($0) }
        let sessionID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let generationID = coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveState(.connecting, for: sessionID)
        coordinator.projectLiveState(.connecting, for: sessionID)
        coordinator.projectLiveState(.listening, for: sessionID)
        coordinator.projectLiveState(.listening, for: sessionID)
        coordinator.projectLiveState(.responding, for: sessionID)
        coordinator.projectLiveState(.responding, for: sessionID)
        coordinator.projectLiveState(.speaking, for: sessionID)

        #expect(projections.map(\.phase) == [
            .idle, .listening, .responding,
        ])
        #expect(projections[1].generationID == nil)
        #expect(projections[2...].allSatisfy {
            $0.generationID == generationID
        })
        #expect(projections.allSatisfy { $0.phase != .speaking })
        #expect(projections.map(\.projectionSequence) == [1, 2, 3])
    }

    @Test
    func typedAndLiveTerminalMappingsRemainMillerOwned() {
        var typedProjections = [AvatarProjection]()
        let typedCoordinator = AvatarProjectionCoordinator {
            typedProjections.append($0)
        }
        let typedTurn = TurnID()
        typedCoordinator.beginTypedTurn(typedTurn)
        typedCoordinator.projectTypedState(.idle, for: typedTurn)
        typedCoordinator.projectTypedState(.ready, for: typedTurn)
        typedCoordinator.projectTypedState(.listening, for: typedTurn)
        typedCoordinator.projectTypedState(.transcribing, for: typedTurn)
        typedCoordinator.projectTypedState(.waiting, for: typedTurn)
        typedCoordinator.projectTypedState(.responding, for: typedTurn)
        typedCoordinator.projectTypedState(.failed, for: typedTurn)

        #expect(typedProjections.map(\.phase) == [
            .thinking, .idle, .listening, .transcribing,
            .thinking, .responding, .failed,
        ])

        var stoppedProjections = [AvatarProjection]()
        let stoppedCoordinator = AvatarProjectionCoordinator {
            stoppedProjections.append($0)
        }
        let stoppedTurn = TurnID()
        stoppedCoordinator.beginTypedTurn(stoppedTurn)
        stoppedCoordinator.projectTypedState(.stopped, for: stoppedTurn)
        #expect(stoppedProjections.last?.phase == .stopped)

        var liveProjections = [AvatarProjection]()
        let liveCoordinator = AvatarProjectionCoordinator {
            liveProjections.append($0)
        }
        let liveSession = UUID()
        liveCoordinator.beginLiveSession(liveSession)
        liveCoordinator.projectLiveState(.available, for: liveSession)
        liveCoordinator.projectLiveState(.connecting, for: liveSession)
        liveCoordinator.projectLiveState(.closed, for: liveSession)
        #expect(liveProjections.map(\.phase) == [.idle])

        var stoppedLiveProjections = [AvatarProjection]()
        let stoppedLiveCoordinator = AvatarProjectionCoordinator {
            stoppedLiveProjections.append($0)
        }
        let stoppedLiveSession = UUID()
        stoppedLiveCoordinator.beginLiveSession(stoppedLiveSession)
        stoppedLiveCoordinator.projectLiveState(.stopped, for: stoppedLiveSession)
        #expect(stoppedLiveProjections.map(\.phase) == [.idle, .stopped])

        var unavailableLiveProjections = [AvatarProjection]()
        let unavailableLiveCoordinator = AvatarProjectionCoordinator {
            unavailableLiveProjections.append($0)
        }
        let unavailableLiveSession = UUID()
        unavailableLiveCoordinator.beginLiveSession(unavailableLiveSession)
        unavailableLiveCoordinator.projectLiveState(
            .unavailable,
            for: unavailableLiveSession
        )
        #expect(unavailableLiveProjections.map(\.phase) == [.idle])

        var failedLiveProjections = [AvatarProjection]()
        let failedLiveCoordinator = AvatarProjectionCoordinator {
            failedLiveProjections.append($0)
        }
        let failedLiveSession = UUID()
        failedLiveCoordinator.beginLiveSession(failedLiveSession)
        failedLiveCoordinator.projectLiveState(.failed, for: failedLiveSession)
        #expect(failedLiveProjections.last?.phase == .failed)
    }

    @Test
    func replacementResetsBeforeNewGenerationAndRejectsStaleEvents() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator { projections.append($0) }
        let firstTurn = TurnID(rawValue: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!)
        let secondTurn = TurnID(rawValue: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!)

        let firstGeneration = coordinator.beginTypedTurn(firstTurn)
        coordinator.projectTypedState(.responding, for: firstTurn)
        let secondGeneration = coordinator.beginTypedTurn(secondTurn)
        let countAfterReplacement = projections.count

        coordinator.projectTypedState(.failed, for: firstTurn)
        coordinator.projectTypedState(.responding, for: secondTurn)

        #expect(firstGeneration != secondGeneration)
        #expect(projections[countAfterReplacement - 1].phase == .thinking)
        #expect(projections.last?.phase == .responding)
        #expect(projections.last?.generationID == secondGeneration)
        #expect(projections.dropLast().contains {
            $0.generationID == firstGeneration && $0.phase == .failed
        } == false)
        #expect(projections.map(\.projectionSequence) ==
            Array(1...UInt64(projections.count)))
    }

    @Test
    func reentrantTypedReplacementKeepsCallbackOwnedGeneration() {
        var projections = [AvatarProjection]()
        var coordinator: AvatarProjectionCoordinator!
        var didReenter = false
        var callbackGeneration: UUID?
        let firstTurn = TurnID()
        let requestedTurn = TurnID()
        let callbackTurn = TurnID()
        coordinator = AvatarProjectionCoordinator { projection in
            projections.append(projection)
            guard projection.phase == .idle,
                  projection.projectionSequence > 1,
                  !didReenter else { return }
            didReenter = true
            callbackGeneration = coordinator.beginTypedTurn(callbackTurn)
        }

        coordinator.beginTypedTurn(firstTurn)
        coordinator.beginTypedTurn(requestedTurn)

        #expect(coordinator.currentGenerationID == callbackGeneration)
        #expect(projections.map(\.phase) == [.thinking, .idle, .thinking])
        #expect(projections.last?.generationID == coordinator.currentGenerationID)
        #expect(projections.last?.generationID != nil)
    }

    @Test
    func reentrantLiveReplacementKeepsCallbackOwnedGeneration() {
        var projections = [AvatarProjection]()
        var coordinator: AvatarProjectionCoordinator!
        var didReenter = false
        var callbackGeneration: UUID?
        let firstSession = UUID()
        let requestedSession = UUID()
        let callbackSession = UUID()
        coordinator = AvatarProjectionCoordinator { projection in
            projections.append(projection)
            guard projection.phase == .idle,
                  projection.projectionSequence > 1,
                  !didReenter else { return }
            didReenter = true
            callbackGeneration = coordinator.beginLiveSession(callbackSession)
        }

        coordinator.beginLiveSession(firstSession)
        coordinator.beginLiveSession(requestedSession)

        #expect(coordinator.currentGenerationID == callbackGeneration)
        #expect(projections.map(\.phase) == [.idle, .idle])
        #expect(projections.last?.generationID == nil)
        coordinator.projectLiveState(.responding, for: callbackSession)
        coordinator.projectLiveState(.failed, for: requestedSession)
        #expect(projections.last?.phase == .responding)
        #expect(projections.last?.generationID == callbackGeneration)
    }

    @Test
    func resetClearsAndRejectsTerminalAndStaleEvents() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator { projections.append($0) }
        let sessionID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveState(.responding, for: sessionID)
        coordinator.resetLiveSession(sessionID, reason: .stopped)
        let countAfterReset = projections.count

        coordinator.projectLiveState(.responding, for: sessionID)
        coordinator.projectLiveState(.failed, for: sessionID)

        #expect(projections[countAfterReset - 1].phase == .idle)
        #expect(projections[countAfterReset - 1].generationID == nil)
        #expect(projections.count == countAfterReset)
    }

    @Test
    func presentationClearPreservesSessionForSameSessionRecovery() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator { projections.append($0) }
        let turnID = TurnID()

        let generationID = coordinator.beginTypedTurn(turnID)
        coordinator.projectTypedState(.responding, for: turnID)
        coordinator.clearPresentation()
        coordinator.clearPresentation()
        coordinator.projectTypedState(.waiting, for: turnID)

        #expect(projections.map(\.phase) == [
            .thinking, .responding, .idle, .thinking,
        ])
        #expect(projections.last?.generationID == generationID)

        coordinator.resetTypedTurn(turnID, reason: .replaced)
        let countAfterReset = projections.count
        coordinator.projectTypedState(.responding, for: turnID)
        #expect(projections.count == countAfterReset)
    }

    @Test
    func terminalProjectionFencesReentrantTypedEventsAndClear() {
        var projections = [AvatarProjection]()
        var coordinator: AvatarProjectionCoordinator!
        let turnID = TurnID()
        coordinator = AvatarProjectionCoordinator { projection in
            projections.append(projection)
            if projection.phase == .succeeded {
                coordinator.projectTypedState(.responding, for: turnID)
                coordinator.clearPresentation()
            }
        }

        coordinator.beginTypedTurn(turnID)
        coordinator.projectTypedState(.completed, for: turnID)
        coordinator.projectTypedState(.responding, for: turnID)

        #expect(projections.map(\.phase) == [.thinking, .succeeded, .idle])
        #expect(projections.map(\.projectionSequence) == [1, 2, 3])
    }

    @Test
    func terminalProjectionFencesReentrantLiveEventsAndClear() {
        var projections = [AvatarProjection]()
        var coordinator: AvatarProjectionCoordinator!
        let sessionID = UUID()
        coordinator = AvatarProjectionCoordinator { projection in
            projections.append(projection)
            if projection.phase == .failed {
                coordinator.projectLiveState(.responding, for: sessionID)
                coordinator.clearPresentation()
            }
        }

        coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveState(.failed, for: sessionID)
        coordinator.projectLiveState(.responding, for: sessionID)

        #expect(projections.map(\.phase) == [.idle, .failed, .idle])
        #expect(projections.map(\.projectionSequence) == [1, 2, 3])
    }

    @Test
    func callbackTriggeredClearCannotBeUndoneOnProjectionUnwind() {
        var projections = [AvatarProjection]()
        var coordinator: AvatarProjectionCoordinator!
        let turnID = TurnID()
        coordinator = AvatarProjectionCoordinator { projection in
            projections.append(projection)
            if projection.phase == .responding {
                coordinator.clearPresentation()
            }
        }

        coordinator.beginTypedTurn(turnID)
        coordinator.projectTypedState(.responding, for: turnID)
        coordinator.clearPresentation()

        #expect(projections.map(\.phase) == [.thinking, .responding, .idle])
        #expect(projections.map(\.projectionSequence) == [1, 2, 3])
    }

    @Test
    func atomicPolicyChangeEmitsOneClearingProjection() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let turnID = TurnID()

        coordinator.beginTypedTurn(turnID)
        coordinator.projectTypedState(.responding, for: turnID)
        coordinator.setPresentationPolicy(visibility: .hidden, reduceMotion: true)

        #expect(projections.map(\.phase) == [.thinking, .responding, .idle])
        #expect(projections.last?.visibility == .hidden)
        #expect(projections.last?.reduceMotion == true)
        #expect(projections.map(\.projectionSequence) == [1, 2, 3])
    }

    @Test
    func projectionSequenceStopsAtJavaScriptSafeMaximum() {
        let maximumSafeSequence: UInt64 = 9_007_199_254_740_991
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator(
            initialProjectionSequence: maximumSafeSequence - 1
        ) {
            projections.append($0)
        }
        let turnID = TurnID()

        coordinator.beginTypedTurn(turnID)
        coordinator.projectTypedState(.responding, for: turnID)

        #expect(projections.count == 1)
        #expect(projections.first?.projectionSequence == maximumSafeSequence)
        #expect(coordinator.lastProjection?.phase == .thinking)
    }

    @Test
    func visibilityAndReducedMotionClearNewerProjectionWithoutTextOrProviderData() {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator { projections.append($0) }
        let turnID = TurnID(rawValue: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!)

        coordinator.beginTypedTurn(turnID)
        coordinator.projectTypedState(.responding, for: turnID)
        coordinator.setVisibility(.hidden)
        coordinator.setReducedMotion(true)

        #expect(projections.last?.phase == .idle)
        #expect(projections.last?.generationID == nil)
        #expect(projections.last?.visibility == .hidden)
        #expect(projections.last?.reduceMotion == true)
        #expect(projections.map(\.projectionSequence) ==
            Array(1...UInt64(projections.count)))

        let encoded = try? JSONEncoder().encode(projections.last)
        let encodedText = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        for forbidden in [
            "provider", "transcript", "tool", "conversation", "prompt", "text",
        ] {
            #expect(!encodedText.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test
    func acceptedTypedLifecycleBindsAtItsExistingTurnSeams() async {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator { projections.append($0) }
        let turnID = TurnID(rawValue: UUID(uuidString: "12121212-1212-4212-8212-121212121212")!)
        let model = AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in turnID },
                stop: {},
                loadTurn: { _ in nil },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in }
            ),
            avatarProjectionCoordinator: coordinator
        )
        model.draft = "typed input"

        await model.submit()
        #expect(projections.map(\.phase) == [.thinking])
        await model.stop()
        #expect(projections.last?.phase == .stopped)
        #expect(projections.last?.generationID == projections.first?.generationID)
    }

    @Test
    func acceptedTypedObservationFailureProjectsTerminalAvatarFailure() async {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let turnID = TurnID()
        let model = AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in turnID },
                stop: {},
                loadTurn: { _ in throw ProjectionTestFailure.injected },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in }
            ),
            avatarProjectionCoordinator: coordinator
        )
        model.draft = "typed input"

        await model.submit()
        for _ in 0..<32 {
            if projections.last?.phase == .failed { break }
            await Task.yield()
        }

        #expect(projections.map(\.phase).contains(.failed))
        #expect(projections.last?.phase == .failed)
        let countAfterFailure = projections.count
        await model.stop()
        #expect(projections.count == countAfterFailure)
    }

    @Test
    func staleTypedObserverFailureCannotFailANewerTurn() async throws {
        let probe = DelayedTypedObserverProbe()
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let model = AppPresentationModel(
            dependencies: probe.hostDependencies(),
            avatarProjectionCoordinator: coordinator
        )

        model.draft = "first input"
        await model.submit()
        await probe.waitUntilFirstLoadEntered()

        await model.stop()
        model.draft = "second input"
        await model.submit()
        let secondGeneration = try #require(coordinator.currentGenerationID)
        #expect(model.presentationState == .waiting)

        await probe.releaseFirstLoadWithFailure()
        for _ in 0..<8 { await Task.yield() }

        #expect(model.presentationState == .waiting)
        #expect(model.errorCode == nil)
        #expect(coordinator.lastProjection?.phase == .thinking)
        #expect(coordinator.lastProjection?.generationID == secondGeneration)
        #expect(projections.last?.phase == .thinking)
    }

    @Test
    func submissionFailureBeforeAcceptanceClearsPreviousAvatarPresentation() async {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator {
            projections.append($0)
        }
        let previousTurn = TurnID()
        coordinator.beginTypedTurn(previousTurn)
        coordinator.projectTypedState(.completed, for: previousTurn)
        let model = AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in throw ProjectionTestFailure.injected },
                stop: {},
                loadTurn: { _ in nil },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in }
            ),
            avatarProjectionCoordinator: coordinator
        )
        model.draft = "submission failure"

        await model.submit()

        #expect(projections.last?.phase == .idle)
        #expect(coordinator.currentGenerationID == nil)
    }

    @Test
    func liveTranscriptRolesMapWithoutTextAndProviderOrToolEventsAreIgnored() async {
        var projections = [AvatarProjection]()
        let coordinator = AvatarProjectionCoordinator { projections.append($0) }
        let model = AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in TurnID() },
                stop: {},
                loadTurn: { _ in nil },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in }
            ),
            avatarProjectionCoordinator: coordinator
        )
        let sessionID = UUID(uuidString: "34343434-3434-4434-8434-343434343434")!
        model.draft = "CONVERSATION_SECRET"

        await model.applyLiveEvent(.sessionAdmitted(id: sessionID))
        await model.applyLiveEvent(.state(.listening))
        let countBeforeTranscriptEvents = projections.count
        await model.applyLiveEvent(
            .transcriptDelta(role: .user, text: "USER_SECRET_TRANSCRIPT")
        )
        #expect(projections.count == countBeforeTranscriptEvents + 1)
        #expect(projections.last?.phase == .transcribing)

        await model.applyLiveEvent(
            .transcriptDone(role: .user, text: "USER_SECRET_DONE")
        )
        #expect(projections.count == countBeforeTranscriptEvents + 1)

        await model.applyLiveEvent(
            .transcriptDone(role: .assistant, text: "ASSISTANT_SECRET_TRANSCRIPT")
        )
        #expect(projections.count == countBeforeTranscriptEvents + 2)
        #expect(projections.last?.phase == .responding)
        let countBeforeIgnoredEvents = projections.count
        await model.applyLiveEvent(.status(.toolsUnavailable))

        #expect(projections.count == countBeforeIgnoredEvents)
        #expect(projections.allSatisfy { $0.mouthCue == nil })
        #expect(projections.allSatisfy { $0.playbackID == nil })
        for projection in projections {
            let encoded = try? JSONEncoder().encode(projection)
            let encodedText = encoded.flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            for forbidden in [
                "USER_SECRET_TRANSCRIPT", "USER_SECRET_DONE",
                "ASSISTANT_SECRET_TRANSCRIPT", "CONVERSATION_SECRET",
                "TOOL_RESULT_SECRET", "provider", "tool", "conversation",
            ] {
                #expect(!encodedText.contains(forbidden))
            }
        }
    }
}

private enum ProjectionTestFailure: Error {
    case injected
}

private actor DelayedTypedObserverProbe {
    nonisolated let firstTurn = TurnID()
    nonisolated let secondTurn = TurnID()

    private var submissionCount = 0
    private var firstLoadEntered = false
    private var firstLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstLoadContinuation:
        CheckedContinuation<Turn?, Error>?

    nonisolated func hostDependencies() -> HostDependencies {
        HostDependencies(
            submit: { [self] _, _ in await submit() },
            stop: {},
            loadTurn: { [self] id in try await loadTurn(id) },
            loadConversations: { [] },
            loadTurns: { _ in [] },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    func waitUntilFirstLoadEntered() async {
        if firstLoadEntered { return }
        await withCheckedContinuation { firstLoadWaiters.append($0) }
    }

    func releaseFirstLoadWithFailure() {
        firstLoadContinuation?.resume(throwing: ProjectionTestFailure.injected)
        firstLoadContinuation = nil
    }

    private func submit() -> TurnID {
        submissionCount += 1
        return submissionCount == 1 ? firstTurn : secondTurn
    }

    private func loadTurn(_ id: TurnID) async throws -> Turn? {
        guard id == firstTurn else { return nil }
        firstLoadEntered = true
        let waiters = firstLoadWaiters
        firstLoadWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation {
            firstLoadContinuation = $0
        }
    }
}

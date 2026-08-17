import AppKit
import Foundation
import MillerAvatarCore
import MillerAvatarHost
import MillerCore
import MillerLiveAudio
import Testing
@testable import MillerApp

@Suite(.serialized)
@MainActor
struct OverlayAvatarPresentationTests {
    @Test
    func avatarOffKeepsReleasedPanelAndAvatarRegionNoninteractive() {
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(),
            surfaceFactory: factory.make
        )
        let controller = OverlayPanelController(
            model: makeModel(),
            avatarIntegration: integration
        )

        #expect(controller.window?.contentView?.frame.width == 520)
        #expect(controller.avatarRegion?.isHidden == true)
        #expect(controller.avatarRegion?.hitTest(.zero) == nil)
        #expect(controller.avatarRegion?.accessibilityChildren()?.isEmpty == true)
        #expect(controller.avatarRegion?.nextKeyView == nil)
        #expect(controller.avatarRegion?.registeredDraggedTypes.isEmpty == true)
        #expect(factory.records.isEmpty)
    }

    @Test
    func enabledProfileDoesNotCreateRendererUntilShownAndPreLiveHideRecreates() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )

        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        await Task.yield()
        #expect(factory.records.isEmpty)

        integration.show()
        try await eventually { factory.records.count == 1 }
        let first = try #require(factory.records.first)
        integration.hide()
        #expect(first.disposeReasons == [.hiddenBeforeLive])

        integration.show()
        try await eventually { factory.records.count == 2 }
        #expect(factory.records.last !== first)
    }

    @Test
    func rendererFailureRequiresOneExplicitRetryAndNeverRetriesFromShow() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let first = try #require(factory.records.first)

        first.emit(.failed(.renderFailed, retryAvailable: true))
        try await eventually { !integration.isSurfaceAttached }
        integration.show()
        await Task.yield()
        #expect(factory.records.count == 1)

        integration.retry()
        try await eventually { factory.records.count == 2 }
        let retry = try #require(factory.records.last)
        retry.emit(.failed(.renderFailed, retryAvailable: true))
        try await eventually { !integration.isSurfaceAttached }
        integration.retry()
        await Task.yield()
        #expect(factory.records.count == 2)
    }

    @Test
    func synchronousProjectionFailureDetachesBeforeOneBoundedPresentationClear() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        var coordinator: AvatarProjectionCoordinator!
        var projections = [AvatarProjection]()
        coordinator = AvatarProjectionCoordinator {
            projections.append($0)
            integration.project($0)
        }
        integration.onPresentationClear = {
            coordinator.clearPresentation()
        }
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let surface = try #require(factory.records.first)
        surface.synchronousProjectionFailure = true

        let turnID = TurnID()
        coordinator.beginTypedTurn(turnID)

        #expect(projections.map(\.phase) == [.thinking, .idle])
        #expect(surface.projectionCalls.count == 1)
        #expect(!surface.callsAfterDetach)
        #expect(surface.disposeReasons == [.failure])
        #expect(!integration.isSurfaceAttached)

        integration.retry()
        try await eventually {
            factory.records.count == 2
                && factory.records.last?.projectionCalls.count == 1
        }
        let retry = try #require(factory.records.last)
        coordinator.projectTypedState(.responding, for: turnID)
        #expect(retry.projectionCalls.count == 2)
        #expect(retry.projectionCalls.last?.phase == .responding)
    }

    @Test
    func liveMouthCueReachesCurrentSurfaceAfterPhaseProjection() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let surface = try #require(factory.records.first)

        let coordinator = AvatarProjectionCoordinator {
            integration.project($0)
        }
        let sessionID = UUID()
        let generationID = coordinator.beginLiveSession(sessionID)
        coordinator.projectLiveState(.responding, for: sessionID)
        coordinator.projectLiveOutput(
            .playbackStarted(offsetMilliseconds: 100),
            for: sessionID
        )
        let playbackID = try #require(coordinator.currentPlaybackID)
        #expect(surface.mouthCalls.isEmpty)
        surface.resetPresentationRecords()

        coordinator.projectLiveOutput(
            .mouthCue(offsetMilliseconds: 132, envelope: 0.73),
            for: sessionID
        )

        let projection = try #require(coordinator.lastProjection)
        let cue = try #require(projection.mouthCue)
        #expect(projection.phase == .speaking)
        #expect(surface.mouthCalls.count == 1)
        guard let payload = surface.mouthCalls.first else { return }
        #expect(payload.generationID == generationID)
        #expect(payload.generationID == cue.generationID)
        #expect(payload.playbackID == playbackID)
        #expect(payload.playbackID == cue.playbackID)
        #expect(payload.cueIndex == cue.cueIndex)
        #expect(
            payload.playbackOffsetMilliseconds
                == cue.playbackOffsetMilliseconds
        )
        #expect(payload.scalar == cue.envelope)
        #expect(
            surface.callOrder
                == [.project, .mouth, .visibility, .reducedMotion]
        )
    }

    @Test
    func synchronousMouthFailureFencesStalePresentationUntilFreshProjection()
        async throws
    {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let first = try #require(factory.records.first)
        first.resetPresentationRecords()
        first.synchronousMouthFailure = true

        let generationID = UUID()
        let playbackID = UUID()
        let staleCue = try AvatarMouthCue(
            generationID: generationID,
            playbackID: playbackID,
            cueIndex: 1,
            playbackOffsetMilliseconds: 132,
            envelope: 0.73
        )
        let staleProjection = try AvatarProjection(
            projectionSequence: 1,
            generationID: generationID,
            phase: .speaking,
            visibility: .visible,
            reduceMotion: false,
            playbackID: playbackID,
            mouthCue: staleCue
        )

        integration.project(staleProjection)

        #expect(first.projectionCalls.count == 1)
        #expect(first.mouthCalls.count == 1)
        #expect(first.visibilityCalls.isEmpty)
        #expect(first.reducedMotionCalls.isEmpty)
        #expect(first.callOrder == [.project, .mouth])
        #expect(!first.callsAfterDetach)
        #expect(first.disposeReasons == [.failure])
        #expect(!integration.isSurfaceAttached)

        integration.retry()
        try await eventually { factory.records.count == 2 }
        let replacement = try #require(factory.records.last)
        replacement.resetPresentationRecords()
        #expect(replacement.projectionCalls.isEmpty)
        #expect(replacement.mouthCalls.isEmpty)

        let freshCue = try AvatarMouthCue(
            generationID: generationID,
            playbackID: playbackID,
            cueIndex: 2,
            playbackOffsetMilliseconds: 155,
            envelope: 0.61
        )
        let freshProjection = try AvatarProjection(
            projectionSequence: 2,
            generationID: generationID,
            phase: .speaking,
            visibility: .visible,
            reduceMotion: false,
            playbackID: playbackID,
            mouthCue: freshCue
        )
        integration.project(freshProjection)

        #expect(replacement.projectionCalls.count == 1)
        #expect(replacement.mouthCalls.count == 1)
        #expect(replacement.mouthCalls.first?.cueIndex == freshCue.cueIndex)
        #expect(
            replacement.callOrder
                == [.project, .mouth, .visibility, .reducedMotion]
        )
    }

    @Test
    func projectionTargetsCurrentSurfaceAndPreservesSessionAcrossReplacementAndDisable() async throws {
        let profileA = UUID()
        let profileB = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileA, additionalID: profileB),
            surfaceFactory: factory.make
        )
        var coordinator: AvatarProjectionCoordinator!
        coordinator = AvatarProjectionCoordinator { integration.project($0) }
        integration.onPresentationClear = {
            coordinator.clearPresentation()
        }
        integration.update(
            enabled: true,
            selectedProfileID: profileA,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let first = try #require(factory.records.first)
        let turnID = TurnID()
        coordinator.beginTypedTurn(turnID)
        coordinator.projectTypedState(.waiting, for: turnID)
        #expect(first.projectionCalls.count == 1)

        coordinator.projectTypedState(.responding, for: turnID)
        #expect(first.projectionCalls.count == 2)

        integration.update(
            enabled: true,
            selectedProfileID: profileB,
            reduceMotion: false
        )
        try await eventually { factory.records.count == 2 }
        let replacement = try #require(factory.records.last)
        #expect(first.projectionCalls.count == 2)
        #expect(replacement.projectionCalls.count == 1)
        #expect(replacement.projectionCalls.last?.phase == .idle)

        coordinator.projectTypedState(.responding, for: turnID)
        #expect(first.projectionCalls.count == 2)
        #expect(replacement.projectionCalls.count == 2)
        #expect(replacement.projectionCalls.last?.phase == .responding)

        integration.disable()
        #expect(replacement.disposeReasons == [.operator])
        coordinator.projectTypedState(.waiting, for: turnID)
        #expect(replacement.projectionCalls.count == 2)
        #expect(coordinator.lastProjection?.phase == .thinking)

        integration.update(
            enabled: true,
            selectedProfileID: profileB,
            reduceMotion: false
        )
        integration.show()
        try await eventually {
            factory.records.count == 3
                && factory.records.last?.projectionCalls.count == 1
        }
        let reenabled = try #require(factory.records.last)
        #expect(reenabled.projectionCalls.count == 1)
        #expect(reenabled.projectionCalls.last?.phase == .idle)
        coordinator.projectTypedState(.waiting, for: turnID)
        #expect(reenabled.projectionCalls.count == 2)
        #expect(reenabled.projectionCalls.last?.phase == .thinking)
        #expect(reenabled.projectionCalls.last?.generationID ==
            coordinator.currentGenerationID)

        let staleTurn = TurnID()
        coordinator.beginTypedTurn(staleTurn)
        coordinator.projectTypedState(.responding, for: staleTurn)
        let staleCount = reenabled.projectionCalls.count
        coordinator.projectTypedState(.failed, for: turnID)
        #expect(reenabled.projectionCalls.count == staleCount)
    }

    @Test
    func clearingDisposalDropsUnwiredLatestProjectionBeforeFreshSurface() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        let projection = try AvatarProjection(
            projectionSequence: 1,
            generationID: UUID(),
            phase: .responding,
            visibility: .visible,
            reduceMotion: false,
            playbackID: nil
        )

        integration.project(projection)
        integration.update(
            enabled: false,
            selectedProfileID: nil,
            reduceMotion: false
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually {
            factory.records.count == 1
                && factory.records.first?.projectionCalls.isEmpty == true
        }
        #expect(factory.records.first?.projectionCalls.isEmpty == true)
    }

    @Test
    func effectiveAvatarPolicyIsHiddenWhenDisabledOrProfileMissing() {
        let profileID = UUID()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID)
        )
        var policies = [(EffectiveVisibility, Bool)]()
        integration.onPresentationPolicyChange = { visibility, reduceMotion in
            policies.append((visibility, reduceMotion))
        }

        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        #expect(policies.last?.0 == .visible)

        integration.disable()
        #expect(policies.last?.0 == .hidden)

        integration.show()
        #expect(policies.last?.0 == .hidden)
        integration.update(
            enabled: true,
            selectedProfileID: nil,
            reduceMotion: false
        )
        #expect(policies.last?.0 == .hidden)

        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        #expect(policies.last?.0 == .visible)
    }

    @Test
    func quarantinedProfileNeverOffersRendererRetry() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID, modelStatus: .quarantined),
            surfaceFactory: factory.make
        )
        var mayRetry = true
        integration.onReadinessChange = { _, retryAvailable in
            mayRetry = retryAvailable
        }
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually {
            integration.readiness == .failed(.assetQuarantined)
        }

        #expect(factory.records.isEmpty)
        #expect(!mayRetry)
        integration.retry()
        await Task.yield()
        #expect(factory.records.isEmpty)
    }

    @Test
    func terminationRejectsLateSettingsAndCommitCallbacks() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        integration.disposeForTermination()

        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.profileDidCommit(
            AvatarCommittedProfileChange(profileID: profileID, profileRevision: 2)
        )
        integration.show()
        await Task.yield()
        #expect(factory.records.count == 1)
        #expect(integration.readiness == .disabled)
    }

    @Test
    func importSelectionAndCommitOrderingCreatesOnlyOneSurface() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(enabled: true, selectedProfileID: nil, reduceMotion: false)
        integration.show()
        integration.profileDidCommit(
            AvatarCommittedProfileChange(profileID: profileID, profileRevision: 1)
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        try await eventually { factory.records.count == 1 }
        await Task.yield()
        #expect(factory.records.count == 1)
    }

    @Test
    func admittedAvatarUsesLeadingTwoHundredPointsAndLeavesMillerContentAtFiveTwenty() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        let controller = OverlayPanelController(
            model: makeModel(),
            avatarIntegration: integration
        )

        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually {
            controller.window?.contentView?.frame.width == 720
                && factory.records.count == 1
        }

        let region = try #require(controller.avatarRegion)
        let content = try #require(controller.millerContentRegion)
        #expect(region.frame.width == 200)
        #expect(content.frame.width == 520)
        #expect(region.frame.maxX == content.frame.minX)
        #expect(region.hitTest(.zero) == nil)
        #expect(region.accessibilityChildren()?.isEmpty == true)
        #expect(region.nextKeyView == nil)
    }

    @Test
    func overlayIsVisibleBeforeStartingAvatarRenderer() async throws {
        let profileID = UUID()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID)
        )
        var controller: OverlayPanelController!
        var panelWasVisibleWhenAvatarBecameVisible: Bool?
        integration.onPresentationPolicyChange = { visibility, _ in
            guard visibility == .visible else { return }
            panelWasVisibleWhenAvatarBecameVisible = controller.window?.isVisible
        }
        controller = OverlayPanelController(
            model: makeModel(),
            avatarIntegration: integration
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )

        controller.show()

        try await eventually { panelWasVisibleWhenAvatarBecameVisible != nil }
        #expect(panelWasVisibleWhenAvatarBecameVisible == true)
        controller.window?.orderOut(nil)
    }

    @Test
    func profileLoadsExactlyOnceAfterTheFreshSurfaceReportsRendererReady() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )

        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let surface = try #require(factory.records.first)
        #expect(surface.startCount == 1)
        #expect(surface.loadCount == 0)

        surface.emit(.rendererReady)
        try await eventually { surface.loadCount == 1 }
        surface.emit(.rendererReady)
        await Task.yield()
        #expect(surface.loadCount == 1)
    }

    @Test
    func surfaceStartsBeforeReceivingInitialPresentationConfiguration() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        factory.configure = { surface in
            surface.emitsAbsentWhenConfiguredBeforeStart = true
        }
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )

        integration.show()

        try await eventually { factory.records.count == 1 }
        let surface = try #require(factory.records.first)
        #expect(surface.startCount == 1)
        #expect(surface.configurationCallsBeforeStart == 0)
        #expect(integration.isSurfaceAttached)
    }

    @Test
    func oldSurfaceCallbacksCannotCompleteReplacementLoad() async throws {
        let profileA = UUID()
        let profileB = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileA, additionalID: profileB),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileA,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let first = try #require(factory.records.first)
        first.emit(.rendererReady)
        try await eventually { first.loadCount == 1 }

        integration.update(
            enabled: true,
            selectedProfileID: profileB,
            reduceMotion: false
        )
        try await eventually { factory.records.count == 2 }
        let replacement = try #require(factory.records.last)
        first.emit(.rendererReady)
        await Task.yield()
        #expect(replacement.loadCount == 0)
        replacement.emit(.rendererReady)
        try await eventually { replacement.loadCount == 1 }
        #expect(first.disposeReasons == [.operator])
    }

    @Test
    func failedCommittedMutationDoesNotReplaceTheCurrentSurface() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let surface = try #require(factory.records.first)
        integration.profileMutationFailed()
        await Task.yield()

        #expect(factory.records.count == 1)
        #expect(surface.disposeReasons.isEmpty)
    }

    @Test
    func successfulCommittedRevisionReplacesImmediatelyWithoutReloadingTheLiveSurface() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let first = try #require(factory.records.first)
        first.emit(.rendererReady)
        try await eventually { first.loadCount == 1 }

        integration.profileDidCommit(
            AvatarCommittedProfileChange(profileID: profileID, profileRevision: 2)
        )
        try await eventually { factory.records.count == 2 }
        let replacement = try #require(factory.records.last)
        #expect(first.disposeReasons == [.operator])
        #expect(first.loadCount == 1)
        #expect(replacement.loadCount == 0)
    }

    @Test
    func visibilityReducedMotionDisableRetryCloseAndTerminationTargetOnlyCurrentSurface() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let first = try #require(factory.records.first)
        integration.setVisibility(.occluded)
        integration.setVisibility(.hidden)
        integration.setVisibility(.visible)
        integration.setReducedMotion(true)
        #expect(first.visibilityCalls == [.visible, .occluded])
        #expect(first.reducedMotionCalls == [false])

        // Hiding a pre-live renderer disposes it rather than sending the
        // package's hidden-before-live transition into a dead session.
        #expect(first.disposeReasons == [.hiddenBeforeLive])
        try await eventually { factory.records.count == 2 }
        let visibleReplacement = try #require(factory.records.last)
        #expect(visibleReplacement.reducedMotionCalls == [true])
        visibleReplacement.emit(.failed(.renderFailed, retryAvailable: true))
        try await eventually { visibleReplacement.disposeReasons == [.failure] }
        integration.retry()
        try await eventually { factory.records.count == 3 }
        let retry = try #require(factory.records.last)
        #expect(retry !== visibleReplacement)

        integration.disable()
        #expect(retry.disposeReasons == [.operator])
        integration.disposeForTermination()
        #expect(retry.disposeReasons == [.operator])
    }

    @Test
    func rendererAndModelFailuresMapToAvatarOnlyReadiness() {
        #expect(
            AvatarIntegrationController.readiness(
                for: .rendererUnavailable
            ) == .failed(.rendererUnavailable)
        )
        #expect(
            AvatarIntegrationController.readiness(
                for: .assetRejected
            ) == .failed(.assetRejected)
        )
        #expect(
            AvatarIntegrationController.readiness(
                for: .resourceLimit
            ) == .failed(.resourceLimit)
        )
    }

    @Test
    func settingsExposeTruthfulRuntimeReadinessAndExplicitRetry() {
        let model = AvatarSettingsModel()
        var retries = 0
        model.onRuntimeRetry = { retries += 1 }

        model.setRuntimeReadiness(.starting, canRetry: false)
        #expect(model.runtimeStatus == "Avatar starting")
        model.retryRuntime()
        #expect(retries == 0)

        model.setRuntimeReadiness(.failed(.rendererFailed), canRetry: true)
        #expect(model.runtimeStatus.contains("avatar_renderer_failed"))
        #expect(model.runtimeRetryAvailable)
        model.retryRuntime()
        #expect(retries == 1)
    }

    @Test
    func rejectedProfileLoadRemovesSurfaceAndCollapsesPanel() async throws {
        let profileID = UUID()
        let factory = SurfaceFactory()
        let integration = AvatarIntegrationController(
            adapter: makeAdapter(profileID: profileID),
            surfaceFactory: factory.make
        )
        let controller = OverlayPanelController(
            model: makeModel(),
            avatarIntegration: integration
        )
        integration.update(
            enabled: true,
            selectedProfileID: profileID,
            reduceMotion: false
        )
        integration.show()
        try await eventually { factory.records.count == 1 }
        let surface = try #require(factory.records.first)
        surface.loadDisposition = .rejected(.modelRejected)
        surface.emit(.rendererReady)

        try await eventually {
            controller.window?.contentView?.frame.width == 520
                && !integration.isSurfaceAttached
        }
        #expect(surface.disposeReasons == [.failure])
        #expect(integration.readiness == .failed(.assetRejected))
    }

    private func makeAdapter(
        profileID: UUID = UUID(),
        additionalID: UUID? = nil,
        modelStatus: AvatarModelStatus = .available
    ) -> MillerAvatarProfileAdapter {
        let profiles = [profileID, additionalID].compactMap { id in
            id.map {
                AvatarProfileSummary(
                    id: $0,
                    displayName: "Miller",
                    profileRevision: 1,
                    modelCapturedByteCount: 1,
                    modelConsecutiveLoadFailures: 0,
                    modelStatus: modelStatus,
                    motions: [],
                    motionBindings: [:]
                )
            }
        }
        return MillerAvatarProfileAdapter(
            store: TestProfileStore(profiles: profiles)
        )
    }

    private func makeModel() -> AppPresentationModel {
        AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in TurnID() },
                stop: {},
                loadTurn: { _ in nil },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in }
            )
        )
    }

    private func eventually(
        _ predicate: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum TestError: Error {
    case timeout
}

@MainActor
private final class SurfaceFactory {
    private(set) var records: [RecordingSurface] = []
    var configure: ((RecordingSurface) -> Void)?

    func make() -> any MillerAvatarSurfaceControlling {
        let surface = RecordingSurface()
        configure?(surface)
        records.append(surface)
        return surface
    }
}

private enum RecordingSurfaceCall: Equatable {
    case project
    case mouth
    case visibility
    case reducedMotion
}

@MainActor
private final class RecordingSurface: MillerAvatarSurfaceControlling {
    let view: NSView = NoninteractiveAvatarTestView(
        frame: NSRect(x: 0, y: 0, width: 200, height: 360)
    )
    var onState: ((MillerAvatarSurfaceState) -> Void)?
    var startCount = 0
    var loadCount = 0
    var disposeReasons: [DisposalReason] = []
    var projectionCalls: [ProjectPhasePayload] = []
    var mouthCalls: [SetMouthPayload] = []
    var visibilityCalls: [EffectiveVisibility] = []
    var reducedMotionCalls: [Bool] = []
    var callOrder: [RecordingSurfaceCall] = []
    var loadDisposition: ProfileLoadDisposition = .accepted
    var synchronousProjectionFailure = false
    var synchronousMouthFailure = false
    var emitsAbsentWhenConfiguredBeforeStart = false
    var configurationCallsBeforeStart = 0
    var callsAfterDetach = false
    private var disposed = false

    func start() { startCount += 1 }

    func load(
        profileID: UUID,
        from store: AvatarProfileStore?
    ) async -> ProfileLoadDisposition {
        loadCount += 1
        return loadDisposition
    }

    func project(_ payload: ProjectPhasePayload) {
        if disposed { callsAfterDetach = true }
        projectionCalls.append(payload)
        callOrder.append(.project)
        if synchronousProjectionFailure {
            onState?(.failed(.renderFailed, retryAvailable: true))
        }
    }

    func setMouth(_ payload: SetMouthPayload) {
        if disposed { callsAfterDetach = true }
        mouthCalls.append(payload)
        callOrder.append(.mouth)
        if synchronousMouthFailure {
            onState?(.failed(.renderFailed, retryAvailable: true))
        }
    }

    func setVisibility(_ visibility: EffectiveVisibility) {
        emitPreStartConfigurationIfNeeded()
        if disposed { callsAfterDetach = true }
        visibilityCalls.append(visibility)
        callOrder.append(.visibility)
    }

    func setReducedMotion(_ enabled: Bool) {
        emitPreStartConfigurationIfNeeded()
        if disposed { callsAfterDetach = true }
        reducedMotionCalls.append(enabled)
        callOrder.append(.reducedMotion)
    }

    func dispose(reason: DisposalReason) {
        disposeReasons.append(reason)
        disposed = true
    }

    func emit(_ state: MillerAvatarSurfaceState) {
        onState?(state)
    }

    func resetPresentationRecords() {
        projectionCalls.removeAll()
        mouthCalls.removeAll()
        visibilityCalls.removeAll()
        reducedMotionCalls.removeAll()
        callOrder.removeAll()
    }

    private func emitPreStartConfigurationIfNeeded() {
        guard startCount == 0 else { return }
        configurationCallsBeforeStart += 1
        if emitsAbsentWhenConfiguredBeforeStart {
            onState?(.absent)
        }
    }
}

@MainActor
private final class NoninteractiveAvatarTestView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
    override func accessibilityChildren() -> [Any]? { [] }
    override func registerForDraggedTypes(_ types: [NSPasteboard.PasteboardType]) {}
}

private actor TestProfileStore: MillerAvatarProfileStoreAPI {
    private let profiles: [AvatarProfileSummary]

    init(profiles: [AvatarProfileSummary]) {
        self.profiles = profiles
    }

    func list() async throws -> [AvatarProfileSummary] { profiles }

    func profile(id: UUID) async throws -> AvatarProfileSummary {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw AvatarProfileStoreError.unknownProfile
        }
        return profile
    }

    func importModel(at: URL, displayName: String) async throws -> AvatarProfileSummary {
        throw AvatarProfileStoreError.assetRejected
    }

    func renameCommitted(id: UUID, displayName: String) async throws -> AvatarProfileCommit? {
        throw AvatarProfileStoreError.unknownProfile
    }

    func removeCommitted(id: UUID) async throws -> AvatarProfileCommit? {
        throw AvatarProfileStoreError.unknownProfile
    }

    func importMotionCommitted(
        profileID: UUID,
        at: URL,
        displayName: String
    ) async throws -> AvatarMotionImportResult {
        throw AvatarProfileStoreError.motionRejected
    }

    func renameMotionCommitted(
        profileID: UUID,
        motionID: UUID,
        displayName: String
    ) async throws -> AvatarProfileCommit? {
        throw AvatarProfileStoreError.unknownMotion
    }

    func removeMotionCommitted(
        profileID: UUID,
        motionID: UUID
    ) async throws -> AvatarProfileCommit? {
        throw AvatarProfileStoreError.unknownMotion
    }

    func bindMotionCommitted(
        profileID: UUID,
        role: AvatarMotionRole,
        motionID: UUID?
    ) async throws -> AvatarProfileCommit? {
        throw AvatarProfileStoreError.unknownProfile
    }

    func retryCommitted(id: UUID) async throws -> AvatarProfileCommit? {
        throw AvatarProfileStoreError.unknownProfile
    }

    func retryMotionCommitted(
        profileID: UUID,
        motionID: UUID
    ) async throws -> AvatarProfileCommit? {
        throw AvatarProfileStoreError.unknownMotion
    }

    func resetMetadata() async throws {}
}

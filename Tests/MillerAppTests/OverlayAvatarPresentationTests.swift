import AppKit
import Foundation
import MillerAvatarCore
import MillerAvatarHost
import MillerCore
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

    func make() -> any MillerAvatarSurfaceControlling {
        let surface = RecordingSurface()
        records.append(surface)
        return surface
    }
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
    var visibilityCalls: [EffectiveVisibility] = []
    var reducedMotionCalls: [Bool] = []
    var loadDisposition: ProfileLoadDisposition = .accepted

    func start() { startCount += 1 }

    func load(
        profileID: UUID,
        from store: AvatarProfileStore?
    ) async -> ProfileLoadDisposition {
        loadCount += 1
        return loadDisposition
    }

    func setVisibility(_ visibility: EffectiveVisibility) {
        visibilityCalls.append(visibility)
    }

    func setReducedMotion(_ enabled: Bool) {
        reducedMotionCalls.append(enabled)
    }

    func dispose(reason: DisposalReason) {
        disposeReasons.append(reason)
    }

    func emit(_ state: MillerAvatarSurfaceState) {
        onState?(state)
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

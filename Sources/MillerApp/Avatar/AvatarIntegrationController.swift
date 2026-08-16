import AppKit
import Foundation
import MillerAvatarCore
import MillerAvatarHost

enum AvatarReadinessFailureCode: String, Equatable, Sendable {
    case packageUnavailable = "avatar_package_unavailable"
    case profileMissing = "avatar_profile_missing"
    case assetRejected = "avatar_asset_rejected"
    case assetQuarantined = "avatar_asset_quarantined"
    case motionRejected = "avatar_motion_rejected"
    case motionUnavailable = "avatar_motion_unavailable"
    case rendererUnavailable = "avatar_renderer_unavailable"
    case rendererFailed = "avatar_renderer_failed"
    case bridgeInvalid = "avatar_bridge_invalid"
    case resourceLimit = "avatar_resource_limit"
}

enum AvatarReadiness: Equatable, Sendable {
    case disabled
    case unavailable(AvatarReadinessFailureCode)
    case starting
    case ready
    case failed(AvatarReadinessFailureCode)
}

enum MillerAvatarSurfaceState: Equatable, Sendable {
    case absent
    case starting
    case rendererReady
    case loading
    case live
    case liveSuspended
    case failed(FailureCode, retryAvailable: Bool)
    case disposing
}

@MainActor
protocol MillerAvatarSurfaceControlling: AnyObject {
    var view: NSView { get }
    var onState: ((MillerAvatarSurfaceState) -> Void)? { get set }

    func start()
    func load(
        profileID: UUID,
        from store: AvatarProfileStore?
    ) async -> ProfileLoadDisposition
    func setVisibility(_ visibility: EffectiveVisibility)
    func setReducedMotion(_ enabled: Bool)
    func dispose(reason: DisposalReason)
}

@MainActor
private final class PackageAvatarSurface: MillerAvatarSurfaceControlling {
    private let surface = AvatarSurfaceController()
    var onState: ((MillerAvatarSurfaceState) -> Void)?

    var view: NSView { surface.view }

    init() {
        surface.onSnapshot = { [weak self] snapshot in
            self?.onState?(Self.state(from: snapshot))
        }
        surface.onObservation = { [weak self] observation in
            if case .disposed = observation {
                self?.onState?(.absent)
            }
        }
    }

    func start() { surface.start() }

    func load(
        profileID: UUID,
        from store: AvatarProfileStore?
    ) async -> ProfileLoadDisposition {
        guard let store else { return .rejected(.persistenceFailed) }
        return await surface.load(profileID: profileID, from: store)
    }

    func setVisibility(_ visibility: EffectiveVisibility) {
        surface.setVisibility(visibility)
    }

    func setReducedMotion(_ enabled: Bool) {
        surface.setReducedMotion(enabled)
    }

    func dispose(reason: DisposalReason) {
        onState = nil
        surface.onSnapshot = nil
        surface.onObservation = nil
        surface.dispose(reason: reason)
    }

    private static func state(from snapshot: HostSnapshot) -> MillerAvatarSurfaceState {
        if case .rejected(let failure) = snapshot.admission {
            return .failed(failure, retryAvailable: snapshot.retryAvailable)
        }
        switch snapshot.lifecycle {
        case .absent:
            return .absent
        case .startingRenderer:
            return .starting
        case .rendererReady:
            return .rendererReady
        case .loadingAsset:
            return .loading
        case .live:
            return .live
        case .liveSuspended:
            return .liveSuspended
        case .failed(let failure):
            return .failed(failure, retryAvailable: snapshot.retryAvailable)
        case .disposing:
            return .disposing
        }
    }
}

@MainActor
final class AvatarIntegrationController {
    typealias SurfaceFactory = @MainActor @Sendable () -> any MillerAvatarSurfaceControlling

    private let adapter: MillerAvatarProfileAdapter
    private let profileStore: AvatarProfileStore?
    private let surfaceFactory: SurfaceFactory
    private weak var hostRegion: NSView?
    private var surface: (any MillerAvatarSurfaceControlling)?
    private var surfaceState: MillerAvatarSurfaceState = .absent
    private var loadTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var ownerGeneration: UInt64 = 0
    private var reconciliationGeneration: UInt64 = 0
    private var requestedLoad = false
    private var enabled = false
    private var selectedProfileID: UUID?
    private var reduceMotion = false
    private var desiredVisibility: EffectiveVisibility = .hidden
    private var activeProfileKey: ProfileKey?
    private var awaitingExplicitRetry = false
    private var retryAvailable = false
    private var retryConsumed = false
    private var terminated = false

    private struct ProfileKey: Equatable, Sendable {
        let id: UUID
        let revision: UInt64
    }

    private(set) var readiness: AvatarReadiness = .disabled {
        didSet {
            onReadinessChange?(readiness, retryAvailable && !retryConsumed)
        }
    }
    private(set) var isSurfaceAttached = false
    var onReadinessChange: ((AvatarReadiness, Bool) -> Void)?
    var onSurfaceAttachmentChange: ((Bool) -> Void)?

    init(
        adapter: MillerAvatarProfileAdapter,
        profileStore: AvatarProfileStore? = nil,
        surfaceFactory: @escaping SurfaceFactory = { PackageAvatarSurface() }
    ) {
        self.adapter = adapter
        self.profileStore = profileStore ?? adapter.renderingStore
        self.surfaceFactory = surfaceFactory
    }

    var currentSurface: (any MillerAvatarSurfaceControlling)? { surface }

    func attach(to region: NSView) {
        guard !terminated else { return }
        hostRegion = region
        region.setAccessibilityElement(false)
        region.nextKeyView = nil
        if let surface {
            attach(surface, to: region)
        }
    }

    func update(
        enabled: Bool,
        selectedProfileID: UUID?,
        reduceMotion: Bool
    ) {
        guard !terminated else { return }
        let selectionChanged = self.selectedProfileID != selectedProfileID
        self.enabled = enabled
        self.selectedProfileID = selectedProfileID
        self.reduceMotion = reduceMotion

        if !enabled {
            resetRetryAuthority()
            disposeCurrent(reason: .operator)
            readiness = .disabled
            return
        }

        guard let selectedProfileID else {
            resetRetryAuthority()
            disposeCurrent(reason: .operator)
            readiness = .unavailable(.profileMissing)
            return
        }

        if selectionChanged {
            resetRetryAuthority()
            disposeCurrent(reason: .operator)
        } else if let surface {
            surface.setReducedMotion(reduceMotion)
            applyVisibilityToCurrentSurface()
            return
        }

        guard desiredVisibility == .visible else {
            readiness = .starting
            return
        }
        requestProfile(id: selectedProfileID, disposalReason: .operator)
    }

    func profileDidCommit(_ change: AvatarCommittedProfileChange) {
        guard !terminated,
              enabled,
              selectedProfileID == change.profileID
        else { return }
        resetRetryAuthority()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        disposeCurrent(reason: .operator)
        guard desiredVisibility == .visible else {
            readiness = .starting
            return
        }
        replaceSurface(
            for: ProfileKey(id: change.profileID, revision: change.profileRevision),
            disposalReason: .operator
        )
    }

    /// Failed store mutations intentionally leave the current surface intact.
    func profileMutationFailed() {}

    func setVisibility(_ visibility: EffectiveVisibility) {
        switch visibility {
        case .visible:
            show()
        case .occluded:
            occlude()
        case .hidden:
            hide()
        }
    }

    func setReducedMotion(_ enabled: Bool) {
        guard !terminated else { return }
        reduceMotion = enabled
        surface?.setReducedMotion(enabled)
    }

    func show() {
        guard !terminated else { return }
        desiredVisibility = .visible
        if let surface {
            surface.setVisibility(.visible)
            return
        }
        guard enabled,
              !awaitingExplicitRetry,
              let selectedProfileID
        else { return }
        requestProfile(id: selectedProfileID, disposalReason: .operator)
    }

    func hide() {
        guard !terminated else { return }
        desiredVisibility = .hidden
        guard let surface else { return }
        switch surfaceState {
        case .live, .liveSuspended:
            surface.setVisibility(.hidden)
        default:
            disposeCurrent(reason: .hiddenBeforeLive)
            if enabled, selectedProfileID != nil {
                readiness = .starting
            }
        }
    }

    func occlude() {
        guard !terminated else { return }
        desiredVisibility = .occluded
        surface?.setVisibility(.occluded)
    }

    func screenChanged() {
        guard !terminated else { return }
        applyVisibilityToCurrentSurface()
        surface?.setReducedMotion(reduceMotion)
    }

    func retry() {
        guard !terminated,
              enabled,
              desiredVisibility == .visible,
              awaitingExplicitRetry,
              retryAvailable,
              !retryConsumed,
              let selectedProfileID
        else { return }
        retryConsumed = true
        retryAvailable = false
        awaitingExplicitRetry = false
        requestProfile(id: selectedProfileID, disposalReason: .retry)
    }

    func disable() {
        guard !terminated else { return }
        enabled = false
        resetRetryAuthority()
        disposeCurrent(reason: .operator)
        readiness = .disabled
    }

    func close() {
        guard !terminated else { return }
        desiredVisibility = .hidden
        disposeCurrent(reason: .operator)
        if enabled, selectedProfileID != nil, !awaitingExplicitRetry {
            readiness = .starting
        }
    }

    func disposeForTermination() {
        guard !terminated else { return }
        terminated = true
        enabled = false
        resetRetryAuthority()
        disposeCurrent(reason: .termination)
        onReadinessChange = nil
        onSurfaceAttachmentChange = nil
        hostRegion = nil
        readiness = .disabled
    }

    static func readiness(for failure: FailureCode) -> AvatarReadiness {
        switch failure {
        case .bridgeInvalid, .schemeRejected, .policyViolation:
            .failed(.bridgeInvalid)
        case .rendererUnavailable, .webglUnavailable, .wrapperTimeout:
            .failed(.rendererUnavailable)
        case .assetRejected:
            .failed(.assetRejected)
        case .resourceLimit:
            .failed(.resourceLimit)
        case .assetLoadFailed, .assetLoadTimeout, .renderFailed,
             .contextLost, .disposedDuringOperation:
            .failed(.rendererFailed)
        }
    }

    private func requestProfile(id: UUID, disposalReason: DisposalReason) {
        guard !terminated,
              enabled,
              desiredVisibility == .visible,
              !awaitingExplicitRetry
        else { return }
        reconciliationGeneration &+= 1
        let generation = reconciliationGeneration
        reconciliationTask?.cancel()
        readiness = .starting
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.adapter.profile(id: id)
                guard self.reconciliationGeneration == generation,
                      !self.terminated,
                      self.enabled,
                      self.desiredVisibility == .visible,
                      self.selectedProfileID == id
                else { return }
                guard summary.modelStatus == .available else {
                    self.recordFailure(.failed(.assetQuarantined), retryAvailable: false)
                    return
                }
                let key = ProfileKey(id: id, revision: summary.profileRevision)
                if self.activeProfileKey == key, self.surface != nil {
                    return
                }
                self.replaceSurface(for: key, disposalReason: disposalReason)
            } catch let error as AvatarProfileStoreError {
                guard self.reconciliationGeneration == generation else { return }
                self.recordFailure(
                    .unavailable(Self.readiness(for: error)),
                    retryAvailable: error != .unknownProfile
                )
            } catch {
                guard self.reconciliationGeneration == generation else { return }
                self.recordFailure(.unavailable(.packageUnavailable), retryAvailable: false)
            }
        }
    }

    private func replaceSurface(
        for key: ProfileKey,
        disposalReason: DisposalReason
    ) {
        guard !terminated, desiredVisibility == .visible else { return }
        disposeCurrent(reason: disposalReason)
        requestedLoad = false
        ownerGeneration &+= 1
        let owner = ownerGeneration
        let fresh = surfaceFactory()
        surface = fresh
        surfaceState = .starting
        activeProfileKey = key
        fresh.onState = { [weak self, weak fresh] state in
            guard let self, let fresh, self.isCurrent(fresh, owner: owner) else { return }
            self.receive(state: state, from: fresh, owner: owner)
        }
        attach(fresh, to: hostRegion)
        isSurfaceAttached = true
        onSurfaceAttachmentChange?(true)
        fresh.setReducedMotion(reduceMotion)
        fresh.setVisibility(.visible)
        fresh.start()
    }

    private func receive(
        state: MillerAvatarSurfaceState,
        from surface: any MillerAvatarSurfaceControlling,
        owner: UInt64
    ) {
        guard isCurrent(surface, owner: owner) else { return }
        surfaceState = state
        switch state {
        case .absent:
            if !awaitingExplicitRetry {
                readiness = .unavailable(.rendererFailed)
            }
            detachCurrentSurface(disposeReason: nil)
        case .starting, .loading:
            readiness = .starting
        case .rendererReady:
            readiness = .starting
            loadIfReady(surface: surface, owner: owner)
        case .live, .liveSuspended:
            awaitingExplicitRetry = false
            retryAvailable = false
            retryConsumed = false
            readiness = .ready
        case .failed(let failure, let mayRetry):
            recordFailure(
                Self.readiness(for: failure),
                retryAvailable: mayRetry && !retryConsumed
            )
        case .disposing:
            break
        }
    }

    private func loadIfReady(
        surface: any MillerAvatarSurfaceControlling,
        owner: UInt64
    ) {
        guard !requestedLoad,
              let profileID = selectedProfileID,
              isCurrent(surface, owner: owner)
        else { return }
        requestedLoad = true
        loadTask = Task { @MainActor [weak self, weak surface] in
            guard let self, let surface else { return }
            let disposition = await surface.load(profileID: profileID, from: self.profileStore)
            guard self.isCurrent(surface, owner: owner), !self.terminated else { return }
            self.loadTask = nil
            switch disposition {
            case .accepted:
                break
            case .notReady, .disposed, .superseded:
                self.recordFailure(
                    .failed(.rendererFailed),
                    retryAvailable: !self.retryConsumed
                )
            case .rejected(let failure):
                self.recordFailure(
                    Self.readiness(for: failure),
                    retryAvailable: !self.retryConsumed
                )
            }
        }
    }

    private func recordFailure(
        _ failure: AvatarReadiness,
        retryAvailable: Bool
    ) {
        awaitingExplicitRetry = true
        self.retryAvailable = retryAvailable
        readiness = failure
        detachCurrentSurface(disposeReason: .failure)
    }

    private func disposeCurrent(reason: DisposalReason) {
        reconciliationGeneration &+= 1
        reconciliationTask?.cancel()
        reconciliationTask = nil
        detachCurrentSurface(disposeReason: reason)
    }

    private func detachCurrentSurface(disposeReason: DisposalReason?) {
        loadTask?.cancel()
        loadTask = nil
        requestedLoad = false
        ownerGeneration &+= 1
        let wasAttached = isSurfaceAttached || surface != nil
        if let surface {
            surface.onState = nil
            if let disposeReason {
                surface.dispose(reason: disposeReason)
            }
            surface.view.removeFromSuperview()
        }
        surface = nil
        surfaceState = .absent
        activeProfileKey = nil
        isSurfaceAttached = false
        if wasAttached {
            onSurfaceAttachmentChange?(false)
        }
    }

    private func attach(
        _ surface: any MillerAvatarSurfaceControlling,
        to region: NSView?
    ) {
        guard let region else { return }
        surface.view.translatesAutoresizingMaskIntoConstraints = false
        surface.view.nextKeyView = nil
        region.addSubview(surface.view)
        NSLayoutConstraint.activate([
            surface.view.leadingAnchor.constraint(equalTo: region.leadingAnchor),
            surface.view.trailingAnchor.constraint(equalTo: region.trailingAnchor),
            surface.view.topAnchor.constraint(equalTo: region.topAnchor),
            surface.view.bottomAnchor.constraint(equalTo: region.bottomAnchor),
        ])
    }

    private func applyVisibilityToCurrentSurface() {
        guard let surface else { return }
        if desiredVisibility == .hidden {
            hide()
        } else {
            surface.setVisibility(desiredVisibility)
        }
    }

    private func resetRetryAuthority() {
        awaitingExplicitRetry = false
        retryAvailable = false
        retryConsumed = false
    }

    private func isCurrent(
        _ candidate: any MillerAvatarSurfaceControlling,
        owner: UInt64
    ) -> Bool {
        guard ownerGeneration == owner, let current = surface else { return false }
        return current === candidate
    }

    private static func readiness(for error: AvatarProfileStoreError)
        -> AvatarReadinessFailureCode
    {
        switch error {
        case .unknownProfile:
            .profileMissing
        case .assetRejected:
            .assetRejected
        case .motionRejected:
            .motionRejected
        case .resourceLimit:
            .resourceLimit
        case .quarantined:
            .assetQuarantined
        case .motionQuarantined:
            .motionUnavailable
        case .bookmarkCreationFailed, .bookmarkResolutionFailed,
             .securityScopeDenied, .persistenceFailed, .corruptStore,
             .cancelled, .invalidDisplayName, .profileLimit, .motionLimit,
             .unknownMotion:
            .packageUnavailable
        }
    }

    private static func readiness(for failure: ProfileLoadFailure) -> AvatarReadiness {
        switch failure {
        case .unknownProfile:
            .failed(.profileMissing)
        case .modelRejected:
            .failed(.assetRejected)
        case .modelQuarantined:
            .failed(.assetQuarantined)
        case .modelUnavailable, .persistenceFailed, .corruptStore:
            .failed(.rendererFailed)
        }
    }
}

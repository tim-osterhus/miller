import Foundation
import MillerCore

enum AvatarProjectionResetReason: Equatable, Sendable {
    case stopped
    case cancelled
    case replaced
    case `operator`
}

@MainActor
final class AvatarProjectionCoordinator {
    typealias ProjectionSink = @MainActor (AvatarProjection) -> Void

    private static let maximumSafeProjectionSequence: UInt64 =
        9_007_199_254_740_991

    private enum Session: Equatable {
        case typed(TurnID)
        case live(UUID)
    }

    private var projectionSequence: UInt64
    private var session: Session?
    private var terminal = false
    private var semanticPhase: AvatarPresentationPhase = .idle
    private var presentationCleared = false

    private(set) var currentGenerationID: UUID?
    private(set) var lastProjection: AvatarProjection?
    private(set) var visibility: AvatarVisibility
    private(set) var reduceMotion: Bool
    var onProjection: ProjectionSink

    init(
        initialProjectionSequence: UInt64 = 0,
        visibility: AvatarVisibility = .visible,
        reduceMotion: Bool = false,
        onProjection: @escaping ProjectionSink = { _ in }
    ) {
        projectionSequence = min(
            initialProjectionSequence,
            Self.maximumSafeProjectionSequence
        )
        self.visibility = visibility
        self.reduceMotion = reduceMotion
        self.onProjection = onProjection
    }

    @discardableResult
    func beginTypedTurn(_ turnID: TurnID) -> UUID {
        if case .typed(turnID) = session, let currentGenerationID {
            return currentGenerationID
        }

        replaceCurrentSession()
        if let currentGenerationID {
            // A synchronous sink may have started a replacement while the
            // old session was being cleared. Preserve that callback-owned
            // session instead of overwriting it on unwind.
            return currentGenerationID
        }
        let generationID = UUID()
        session = .typed(turnID)
        currentGenerationID = generationID
        terminal = false
        semanticPhase = .thinking
        presentationCleared = false
        _ = emit(.thinking, generationID: generationID)
        return generationID
    }

    func projectTypedState(_ state: PresentationState, for turnID: TurnID) {
        guard case .typed(turnID) = session, !terminal else { return }
        if Self.isTerminal(state) {
            // Fence terminal state before the synchronous sink can re-enter.
            terminal = true
        }
        project(state: Self.phase(for: state))
    }

    func resetTypedTurn(
        _ turnID: TurnID,
        reason: AvatarProjectionResetReason = .cancelled
    ) {
        guard case .typed(turnID) = session else { return }
        reset(reason: reason)
    }

    @discardableResult
    func beginLiveSession(_ sessionID: UUID) -> UUID {
        if case .live(sessionID) = session, let currentGenerationID {
            return currentGenerationID
        }

        replaceCurrentSession()
        if let currentGenerationID {
            // A synchronous sink may have started a replacement while the
            // old session was being cleared. Preserve that callback-owned
            // session instead of overwriting it on unwind.
            return currentGenerationID
        }
        let generationID = UUID()
        session = .live(sessionID)
        currentGenerationID = generationID
        terminal = false
        semanticPhase = .idle
        presentationCleared = false
        _ = emit(.idle, generationID: nil)
        return generationID
    }

    func projectLiveState(_ state: LiveVoiceState, for sessionID: UUID) {
        guard case .live(sessionID) = session, !terminal else { return }
        if Self.isTerminal(state) {
            // Fence terminal state before the synchronous sink can re-enter.
            terminal = true
        }
        let phase = Self.phase(for: state)
        project(state: phase)
    }

    func projectLiveTranscriptRole(
        _ role: LiveTranscriptRole,
        for sessionID: UUID
    ) {
        guard case .live(sessionID) = session, !terminal else { return }
        project(
            state: role == .user ? .transcribing : .responding
        )
    }

    func resetLiveSession(
        _ sessionID: UUID,
        reason: AvatarProjectionResetReason = .cancelled
    ) {
        guard case .live(sessionID) = session else { return }
        reset(reason: reason)
    }

    func reset(reason _: AvatarProjectionResetReason = .operator) {
        guard session != nil || lastProjection != nil else { return }
        let shouldClear = !presentationCleared
        session = nil
        currentGenerationID = nil
        terminal = false
        semanticPhase = .idle
        presentationCleared = true
        if shouldClear {
            _ = emit(.idle, generationID: nil, force: true)
        }
    }

    func clearPresentation() {
        guard !presentationCleared,
              session != nil || lastProjection != nil
        else { return }
        presentationCleared = true
        _ = emit(.idle, generationID: nil, force: true)
    }

    func setVisibility(_ visibility: AvatarVisibility) {
        setPresentationPolicy(visibility: visibility, reduceMotion: reduceMotion)
    }

    func setReducedMotion(_ enabled: Bool) {
        setPresentationPolicy(visibility: visibility, reduceMotion: enabled)
    }

    func setPresentationPolicy(
        visibility: AvatarVisibility,
        reduceMotion: Bool
    ) {
        guard visibility != self.visibility || reduceMotion != self.reduceMotion
        else { return }
        self.visibility = visibility
        self.reduceMotion = reduceMotion
        clearAndReconcileIfActive()
    }

    private func replaceCurrentSession() {
        guard session != nil || lastProjection != nil else { return }
        let shouldClear = !presentationCleared
        session = nil
        currentGenerationID = nil
        terminal = false
        semanticPhase = .idle
        presentationCleared = true
        if shouldClear {
            _ = emit(.idle, generationID: nil, force: true)
        }
    }

    private func project(state phase: AvatarPresentationPhase) {
        semanticPhase = phase
        _ = emit(
            phase,
            generationID: Self.phaseNeedsGeneration(phase)
                ? currentGenerationID
                : nil,
            force: false
        )
    }

    private func clearAndReconcileIfActive() {
        presentationCleared = true
        _ = emit(.idle, generationID: nil, force: true)
        guard visibility == .visible,
              !reduceMotion,
              session != nil,
              !terminal,
              semanticPhase != .idle
        else { return }
        _ = emit(
            semanticPhase,
            generationID: Self.phaseNeedsGeneration(semanticPhase)
                ? currentGenerationID
                : nil,
            force: false
        )
    }

    private func emit(
        _ phase: AvatarPresentationPhase,
        generationID: UUID?,
        force: Bool = false
    ) -> Bool {
        let identity = Self.phaseNeedsGeneration(phase) ? generationID : nil
        guard !Self.phaseNeedsGeneration(phase) || identity != nil else {
            return false
        }
        if !force,
           let lastProjection,
           lastProjection.phase == phase,
           lastProjection.generationID == identity,
           lastProjection.visibility == visibility,
           lastProjection.reduceMotion == reduceMotion,
           lastProjection.playbackID == nil,
           lastProjection.mouthCue == nil
        {
            return false
        }
        guard projectionSequence < Self.maximumSafeProjectionSequence else {
            return false
        }
        let nextSequence = projectionSequence + 1
        let projection: AvatarProjection
        do {
            projection = try AvatarProjection(
                projectionSequence: nextSequence,
                generationID: identity,
                phase: phase,
                visibility: visibility,
                reduceMotion: reduceMotion,
                playbackID: nil
            )
        } catch {
            return false
        }
        projectionSequence = nextSequence
        lastProjection = projection
        // Mark the presentation active before synchronous delivery. A
        // reentrant clear must remain authoritative after this call unwinds.
        if !force {
            presentationCleared = false
        }
        onProjection(projection)
        return true
    }

    private static func phase(for state: PresentationState)
        -> AvatarPresentationPhase
    {
        switch state {
        case .idle, .ready:
            .idle
        case .listening:
            .listening
        case .transcribing:
            .transcribing
        case .waiting:
            .thinking
        case .responding, .speaking:
            // C6 owns the only path that may publish Avatar `speaking`.
            .responding
        case .stopped:
            .stopped
        case .completed:
            .succeeded
        case .failed:
            .failed
        }
    }

    private static func phase(for state: LiveVoiceState)
        -> AvatarPresentationPhase
    {
        switch state {
        case .available, .connecting, .closed, .unavailable:
            .idle
        case .listening:
            .listening
        case .responding, .speaking:
            // Provider state is not played-output evidence.
            .responding
        case .stopped:
            .stopped
        case .failed:
            .failed
        }
    }

    private static func isTerminal(_ state: LiveVoiceState) -> Bool {
        switch state {
        case .stopped, .closed, .failed:
            true
        default:
            false
        }
    }

    private static func isTerminal(_ state: PresentationState) -> Bool {
        switch state {
        case .stopped, .completed, .failed:
            true
        default:
            false
        }
    }

    private static func phaseNeedsGeneration(
        _ phase: AvatarPresentationPhase
    ) -> Bool {
        switch phase {
        case .thinking, .responding, .succeeded, .stopped, .failed:
            true
        case .idle, .listening, .transcribing, .speaking:
            false
        }
    }
}

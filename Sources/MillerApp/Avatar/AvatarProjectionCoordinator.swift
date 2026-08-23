import Foundation
import MillerCore
import MillerLiveAudio

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
    private var playbackID: UUID?
    private var cueIndex: UInt64 = 0
    private var playbackOffsetMilliseconds: UInt64 = 0
    private var playbackSilenced = false
    private var speakingSilenceTask: Task<Void, Never>?
    private let speakingSilenceGrace: Duration

    private(set) var currentGenerationID: UUID?
    var currentPlaybackID: UUID? {
        playbackID
    }
    private(set) var lastProjection: AvatarProjection?
    private(set) var visibility: AvatarVisibility
    private(set) var reduceMotion: Bool
    private(set) var mouthCuesEnabled: Bool
    var onProjection: ProjectionSink

    init(
        initialProjectionSequence: UInt64 = 0,
        visibility: AvatarVisibility = .visible,
        reduceMotion: Bool = false,
        mouthCuesEnabled: Bool = true,
        speakingSilenceGrace: Duration = .milliseconds(1_500),
        onProjection: @escaping ProjectionSink = { _ in }
    ) {
        projectionSequence = min(
            initialProjectionSequence,
            Self.maximumSafeProjectionSequence
        )
        self.visibility = visibility
        self.reduceMotion = reduceMotion
        self.mouthCuesEnabled = mouthCuesEnabled
        self.speakingSilenceGrace = speakingSilenceGrace
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
            clearPlayback()
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

    /// Accepts only the bounded observations produced by Miller's existing
    /// remote-output monitor. Provider state and transcript events cannot
    /// create this input.
    func projectLiveOutput(
        _ observation: LiveAudioOutputObservation,
        for sessionID: UUID
    ) {
        guard case .live(sessionID) = session, !terminal else { return }
        switch observation {
        case let .playbackStarted(offsetMilliseconds):
            guard visibility == .visible, !reduceMotion else {
                clearPlayback()
                return
            }
            speakingSilenceTask?.cancel()
            speakingSilenceTask = nil
            playbackSilenced = false
            if playbackID != nil {
                playbackOffsetMilliseconds = min(
                    max(playbackOffsetMilliseconds, offsetMilliseconds),
                    Self.maximumSafeProjectionSequence
                )
                return
            }
            playbackID = UUID()
            cueIndex = 0
            playbackOffsetMilliseconds = min(
                offsetMilliseconds,
                Self.maximumSafeProjectionSequence
            )
            // A measured remote segment establishes the Live response base
            // even when the provider's earlier listening event arrived
            // before Miller admitted the session to this coordinator.
            semanticPhase = .responding
            _ = emit(
                .speaking,
                generationID: currentGenerationID,
                playbackID: playbackID
            )
        case let .mouthCue(offsetMilliseconds, envelope, vowels):
            _ = emitMouthCue(
                offsetMilliseconds: offsetMilliseconds,
                envelope: envelope,
                vowels: vowels
            )
        case let .playbackStopped(offsetMilliseconds):
            guard playbackID != nil, !playbackSilenced else { return }
            playbackSilenced = true
            if semanticPhase == .responding,
               visibility == .visible,
               !reduceMotion
            {
                _ = emitMouthCue(
                    offsetMilliseconds: offsetMilliseconds,
                    envelope: 0,
                    vowels: nil
                )
                scheduleSpeakingSilenceExpiry()
                return
            }
            playbackSilenced = false
            clearPlayback()
            guard visibility == .visible, !reduceMotion else { return }
            project(state: semanticPhase)
        }
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
        clearPlayback()
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
        clearPlayback()
        presentationCleared = true
        _ = emit(.idle, generationID: nil, force: true)
    }

    func setVisibility(_ visibility: AvatarVisibility) {
        setPresentationPolicy(visibility: visibility, reduceMotion: reduceMotion)
    }

    func setReducedMotion(_ enabled: Bool) {
        setPresentationPolicy(visibility: visibility, reduceMotion: enabled)
    }

    /// Updates mouth presentation policy in place. Disabling mouth cues only
    /// clears the current cue; playback identity and speaking lifecycle remain
    /// owned by the played-output path.
    func setMouthCuesEnabled(_ enabled: Bool) {
        guard enabled != mouthCuesEnabled else { return }
        mouthCuesEnabled = enabled
        guard !enabled else { return }
        clearMouthPresentation()
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
        clearPlayback()
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
        if Self.isTerminal(phase) || !Self.keepsPlaybackActive(phase) {
            clearPlayback()
        }
        if playbackID != nil,
           !Self.isTerminal(phase),
           visibility == .visible,
           !reduceMotion
        {
            guard lastProjection?.phase != .speaking
                    || lastProjection?.playbackID != playbackID
            else { return }
            _ = emit(
                .speaking,
                generationID: currentGenerationID,
                playbackID: playbackID
            )
            return
        }
        _ = emit(
            phase,
            generationID: Self.phaseNeedsGeneration(phase)
                ? currentGenerationID
                : nil,
            force: false
        )
    }

    private func clearAndReconcileIfActive() {
        clearPlayback()
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
        playbackID: UUID? = nil,
        mouthCue: AvatarMouthCue? = nil,
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
           lastProjection.playbackID == playbackID,
           lastProjection.mouthCue == mouthCue
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
                playbackID: playbackID,
                mouthCue: mouthCue
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
        case .thinking, .responding, .speaking, .succeeded, .stopped, .failed:
            true
        case .idle, .listening, .transcribing:
            false
        }
    }

    private func clearPlayback() {
        speakingSilenceTask?.cancel()
        speakingSilenceTask = nil
        playbackID = nil
        cueIndex = 0
        playbackOffsetMilliseconds = 0
        playbackSilenced = false
    }

    private func clearMouthPresentation() {
        guard let playbackID,
              let generationID = currentGenerationID,
              lastProjection?.mouthCue != nil
        else { return }
        _ = emit(
            .speaking,
            generationID: generationID,
            playbackID: playbackID,
            mouthCue: nil
        )
    }

    private func scheduleSpeakingSilenceExpiry() {
        guard let playbackID, let generationID = currentGenerationID else {
            return
        }
        let expectedSession = session
        speakingSilenceTask?.cancel()
        speakingSilenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: speakingSilenceGrace)
            } catch {
                return
            }
            guard session == expectedSession,
                  currentGenerationID == generationID,
                  self.playbackID == playbackID,
                  playbackSilenced,
                  semanticPhase == .responding
            else { return }
            speakingSilenceTask = nil
            clearPlayback()
            project(state: .responding)
        }
    }

    @discardableResult
    private func emitMouthCue(
        offsetMilliseconds: UInt64,
        envelope: Double,
        vowels: MillerLiveAudio.AvatarVowelWeights? = nil
    ) -> Bool {
        guard let playbackID,
              let generationID = currentGenerationID,
              visibility == .visible,
              !reduceMotion,
              cueIndex < Self.maximumSafeProjectionSequence
        else { return false }
        let offset = min(
            max(playbackOffsetMilliseconds, offsetMilliseconds),
            Self.maximumSafeProjectionSequence
        )
        let nextCueIndex = cueIndex + 1
        let cue: AvatarMouthCue
        do {
            cue = try AvatarMouthCue(
                generationID: generationID,
                playbackID: playbackID,
                cueIndex: nextCueIndex,
                playbackOffsetMilliseconds: offset,
                envelope: envelope,
                vowels: vowels.map {
                    AvatarVowelWeights(
                        aa: $0.aa,
                        ih: $0.ih,
                        ou: $0.ou,
                        ee: $0.ee,
                        oh: $0.oh
                    )
                }
            )
        } catch {
            return false
        }
        cueIndex = nextCueIndex
        playbackOffsetMilliseconds = offset
        guard mouthCuesEnabled else { return false }
        return emit(
            .speaking,
            generationID: generationID,
            playbackID: playbackID,
            mouthCue: cue
        )
    }

    private static func keepsPlaybackActive(
        _ phase: AvatarPresentationPhase
    ) -> Bool {
        phase == .responding || phase == .speaking
    }

    private static func isTerminal(_ phase: AvatarPresentationPhase) -> Bool {
        switch phase {
        case .succeeded, .stopped, .failed:
            true
        default:
            false
        }
    }
}

import AVFoundation
import Foundation
import MillerLive

public enum SystemMicrophonePermission {
    public static func current() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    public static func request() async -> MicrophonePermission {
        guard current() == .notDetermined else { return current() }
        return await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
    }
}

final class LiveAudioTerminalClaim: @unchecked Sendable {
    private enum Outcome {
        case audio(LiveAudioError)
        case provider
    }

    private let lock = NSLock()
    private var outcome: Outcome?

    var audioFailure: LiveAudioError? {
        lock.withLock {
            guard case let .audio(failure) = outcome else { return nil }
            return failure
        }
    }

    @discardableResult
    func claimAudio(_ failure: LiveAudioError) -> Bool {
        lock.withLock {
            guard outcome == nil else { return false }
            outcome = .audio(failure)
            return true
        }
    }

    @discardableResult
    func claimProvider() -> Bool {
        lock.withLock {
            guard outcome == nil else { return false }
            outcome = .provider
            return true
        }
    }
}

final class LiveAudioFailureClaimGate: @unchecked Sendable {
    private let lock = NSLock()
    private let claimFailure: @Sendable (LiveAudioError) -> Bool
    private var active = true

    init(claimFailure: @escaping @Sendable (LiveAudioError) -> Bool) {
        self.claimFailure = claimFailure
    }

    func claim(_ failure: LiveAudioError) -> Bool {
        lock.withLock {
            guard active else { return false }
            return claimFailure(failure)
        }
    }

    func deactivate() {
        lock.withLock { active = false }
    }
}

public actor LiveAudioSession {
    private let client: CodexAppServerClient
    private let peer: (any LiveAudioPeer)?
    private let capture: LiveAudioCapture
    private let playback: LiveAudioPlayback
    private var identity: LiveSessionIdentity?
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var runGeneration: UInt64 = 0
    private var peerUsed = false
    private var peerClosed = false
    private var peerMonitor: Task<Void, Never>?
    private var terminalPeerFailure: LiveAudioPeerError?

    public init(
        client: CodexAppServerClient,
        peer: (any LiveAudioPeer)? = nil,
        capture: LiveAudioCapture = LiveAudioCapture(),
        playback: LiveAudioPlayback = LiveAudioPlayback()
    ) {
        self.client = client
        self.peer = peer
        self.capture = capture
        self.playback = playback
    }

    public func run(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        permission: MicrophonePermission,
        requestInitialResponse: Bool = false,
        receive: @escaping @Sendable (LiveSessionEvent) async -> Void
    ) async throws {
        try await run(
            identity: identity,
            credential: credential,
            permission: permission,
            requestInitialResponse: requestInitialResponse,
            onActive: {},
            onCleanupPending: {},
            receive: receive
        )
    }

    package func run(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        permission: MicrophonePermission,
        requestInitialResponse: Bool = false,
        onActive: @escaping @Sendable () async -> Void,
        onCleanupPending: @escaping @Sendable () async -> Void,
        receive: @escaping @Sendable (LiveSessionEvent) async -> Void
    ) async throws {
        try await withTaskCancellationHandler(operation: {
            try await self.runWebRTC(
                identity: identity,
                credential: credential,
                permission: permission,
                requestInitialResponse: requestInitialResponse,
                onActive: onActive,
                onCleanupPending: onCleanupPending,
                receive: receive
            )
        }, onCancel: { [weak self] in
            Task { await self?.cancelCurrentRun() }
        })
    }

    private func runWebRTC(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        permission: MicrophonePermission,
        requestInitialResponse: Bool,
        onActive: @escaping @Sendable () async -> Void,
        onCleanupPending: @escaping @Sendable () async -> Void,
        receive: @escaping @Sendable (LiveSessionEvent) async -> Void
    ) async throws {
        guard permission == .authorized else { throw LiveAudioError.permissionDenied }
        guard self.identity == nil, !peerUsed else {
            throw CodexAppServerClientError.sessionAlreadyActive
        }
        guard let peer else { throw LiveAudioPeerError.unavailable }
        peerUsed = true
        runGeneration &+= 1
        let runGeneration = self.runGeneration
        self.identity = identity
        terminalPeerFailure = nil
        defer { finishRun(generation: runGeneration) }
        var initialResponseRequested = false
        do {
            let offer = try await peer.prepareOffer()
            try Task.checkCancellation()
            for try await event in client.events(
                identity: identity,
                credential: credential,
                offerSDP: offer,
                onCleanupPending: onCleanupPending
            ) {
                var shouldReceive = true
                switch event {
                case let .sdp(_, answer):
                    shouldReceive = false
                    try await peer.applyAnswerAndWaitForConnected(answer)
                    let peerWasAdmitted = client.confirmPeerConnected(identity: identity)
                    if peerWasAdmitted {
                        beginPeerMonitor(peer: peer, generation: runGeneration)
                    }
                    try Task.checkCancellation()
                    guard peerWasAdmitted,
                          requestInitialResponse,
                          !initialResponseRequested,
                          !peerClosed
                    else { break }
                    initialResponseRequested = true
                    try await peer.requestResponse()
                case .started:
                    await onActive()
                case .outputAudio:
                    break
                case .closed:
                    await cleanup()
                case .failed:
                    await cleanup()
                default:
                    break
                }
                if shouldReceive { await receive(event) }
            }
            if let terminalPeerFailure { throw terminalPeerFailure }
        } catch {
            await cleanup()
            if terminalPeerFailure == nil {
                await client.stopAndWaitForCleanup(onCleanupPending: onCleanupPending)
            }
            throw error
        }
        await cleanup()
    }

    public func setMuted(_ muted: Bool) async {
        guard let peer, identity != nil, !peerClosed else { return }
        do {
            try await peer.setMuted(muted)
        } catch let failure as LiveAudioPeerError {
            await terminateForPeerFailure(failure, generation: runGeneration)
        } catch {
            await terminateForPeerFailure(.connectionFailed, generation: runGeneration)
        }
    }

    public func interrupt() async {
        await cleanup(playbackFirst: true)
        await stopClientAndWait()
    }

    public func end() async {
        await cleanup()
        await stopClientAndWait()
    }

    private func stopClient() {
        guard let identity else { return }
        _ = try? client.requestStop(identity: identity)
    }

    private func cancelCurrentRun() async {
        await cleanup()
        stopClient()
    }

    private func stopClientAndWait() async {
        guard let identity else { return }
        _ = try? client.requestStop(identity: identity)
        await withCheckedContinuation { continuation in
            guard self.identity == identity else {
                continuation.resume()
                return
            }
            completionWaiters.append(continuation)
        }
    }

    private func cleanup(playbackFirst: Bool = false) async {
        _ = playbackFirst
        cancelPeerMonitor()
        guard !peerClosed, let peer else { return }
        peerClosed = true
        await peer.close()
    }

    private func finishRun(generation: UInt64) {
        guard runGeneration == generation else { return }
        cancelPeerMonitor()
        terminalPeerFailure = nil
        identity = nil
        let waiters = completionWaiters
        completionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func beginPeerMonitor(
        peer: any LiveAudioPeer,
        generation: UInt64
    ) {
        guard let monitor = peer as? any LiveAudioPeerConnectionMonitoring else { return }
        cancelPeerMonitor()
        peerMonitor = Task { [weak self, monitor] in
            do {
                try await monitor.waitForConnectionFailure()
                await self?.terminateForPeerFailure(.connectionFailed, generation: generation)
            } catch is CancellationError {
                return
            } catch let failure as LiveAudioPeerError {
                await self?.terminateForPeerFailure(failure, generation: generation)
            } catch {
                await self?.terminateForPeerFailure(.connectionFailed, generation: generation)
            }
        }
    }

    private func cancelPeerMonitor() {
        peerMonitor?.cancel()
        peerMonitor = nil
    }

    private func terminateForPeerFailure(
        _ failure: LiveAudioPeerError,
        generation: UInt64
    ) async {
        guard runGeneration == generation,
              identity != nil,
              terminalPeerFailure == nil,
              !peerClosed
        else { return }
        terminalPeerFailure = failure
        await cleanup()
        stopClient()
    }
}

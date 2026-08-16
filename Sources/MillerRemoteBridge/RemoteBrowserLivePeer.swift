import Foundation
import MillerLiveAudio

/// The remote browser owns the WebRTC media plane. Miller only holds the
/// browser offer, provider answer, and the explicit browser-connected fence.
@MainActor
public final class RemoteBrowserLivePeer: LiveAudioPeer, LiveAudioPeerConnectionMonitoring {
    private let clientSessionID: UUID
    private let offerSDP: String
    private let connectedTimeout: Duration
    private let connectedTimeoutWaiter: @Sendable (Duration) async throws -> Void
    private let providerAnswerWaiterReady: (@Sendable () -> Void)?
    private let failureWaiterReady: (@Sendable () -> Void)?
    private var answerSDP: String?
    private var prepared = false
    private var connected = false
    private var closed = false
    private var terminalFailure: LiveAudioPeerError?
    private var terminalReasonValue: RemoteLiveTerminalReason?
    private var connectedWaiter: CheckedContinuation<Void, Error>?
    private var answerWaiter: CheckedContinuation<String, Error>?
    private var failureWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var connectedTimeoutTask: Task<Void, Never>?
    private var connectedTimeoutGeneration: UInt64 = 0

    public convenience init(
        clientSessionID: UUID,
        offerSDP: String,
        connectedTimeout: Duration = .seconds(45)
    ) {
        self.init(
            clientSessionID: clientSessionID,
            offerSDP: offerSDP,
            connectedTimeout: connectedTimeout,
            connectedTimeoutWaiter: { try await Task.sleep(for: $0) },
            providerAnswerWaiterReady: nil,
            failureWaiterReady: nil
        )
    }

    init(
        clientSessionID: UUID,
        offerSDP: String,
        connectedTimeout: Duration,
        connectedTimeoutWaiter: @escaping @Sendable (Duration) async throws -> Void,
        providerAnswerWaiterReady: (@Sendable () -> Void)? = nil,
        failureWaiterReady: (@Sendable () -> Void)? = nil
    ) {
        self.clientSessionID = clientSessionID
        self.offerSDP = offerSDP
        self.connectedTimeout = connectedTimeout
        self.connectedTimeoutWaiter = connectedTimeoutWaiter
        self.providerAnswerWaiterReady = providerAnswerWaiterReady
        self.failureWaiterReady = failureWaiterReady
    }

    public var sessionID: UUID { clientSessionID }
    public var isConnected: Bool { connected }
    public var terminalReason: RemoteLiveTerminalReason? { terminalReasonValue }

    public func prepareOffer() async throws -> String {
        guard !closed, terminalFailure == nil else {
            throw LiveAudioPeerError.invalidState
        }
        guard !offerSDP.isEmpty,
              offerSDP.utf8.count <= RemoteLiveBridgeContract.maximumSDPBytes
        else { throw LiveAudioPeerError.invalidOffer }
        prepared = true
        return offerSDP
    }

    public func providerAnswer() async throws -> String {
        if let terminalFailure { throw terminalFailure }
        guard !closed else { throw LiveAudioPeerError.invalidState }
        if let answerSDP { return answerSDP }
        guard answerWaiter == nil else { throw LiveAudioPeerError.invalidState }
        return try await withCheckedThrowingContinuation { continuation in
            answerWaiter = continuation
            providerAnswerWaiterReady?()
        }
    }

    public func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        guard prepared, !closed, terminalFailure == nil else {
            throw LiveAudioPeerError.invalidState
        }
        guard !answer.isEmpty,
              answer.utf8.count <= RemoteLiveBridgeContract.maximumSDPBytes
        else { throw LiveAudioPeerError.invalidAnswer }
        guard answerSDP == nil else { throw LiveAudioPeerError.invalidState }
        answerSDP = answer
        answerWaiter?.resume(returning: answer)
        answerWaiter = nil
        if connected { return }
        connectedTimeoutTask?.cancel()
        connectedTimeoutGeneration &+= 1
        let timeoutGeneration = connectedTimeoutGeneration
        let timeout = connectedTimeout
        connectedTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await self?.connectedTimeoutWaiter(timeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.connectedTimeoutGeneration == timeoutGeneration,
                  !self.connected,
                  !self.closed,
                  self.terminalFailure == nil
            else { return }
            self.fail(.timeout)
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let terminalFailure {
                    continuation.resume(throwing: terminalFailure)
                } else if closed {
                    continuation.resume(throwing: LiveAudioPeerError.invalidState)
                } else if connected {
                    continuation.resume()
                } else {
                    connectedWaiter = continuation
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelConnectedWaiter() }
        })
    }

    public func requestResponse() async throws {}

    public func setMuted(_ muted: Bool) async throws {
        guard !closed, terminalFailure == nil else {
            throw LiveAudioPeerError.invalidState
        }
        _ = muted
    }

    @discardableResult
    public func markConnected() -> Bool {
        guard answerSDP != nil, !closed, terminalFailure == nil else { return false }
        connected = true
        connectedTimeoutGeneration &+= 1
        connectedTimeoutTask?.cancel()
        connectedTimeoutTask = nil
        connectedWaiter?.resume()
        connectedWaiter = nil
        return true
    }

    public func fail(_ reason: RemoteLiveTerminalReason) {
        guard !closed, terminalFailure == nil,
              !(reason == .timeout && connected) else { return }
        let failure: LiveAudioPeerError = switch reason {
        case .trackEnded, .dataChannelClosed, .peerFailed, .providerFailed, .timeout:
            .connectionFailed
        default:
            .invalidState
        }
        terminalReasonValue = reason
        terminalFailure = failure
        connectedTimeoutGeneration &+= 1
        connectedTimeoutTask?.cancel()
        connectedTimeoutTask = nil
        connectedWaiter?.resume(throwing: failure)
        connectedWaiter = nil
        answerWaiter?.resume(throwing: failure)
        answerWaiter = nil
        let waiters = failureWaiters.values
        failureWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: failure) }
    }

    public func waitForConnectionFailure() async throws {
        if let terminalFailure { throw terminalFailure }
        guard !closed else { throw LiveAudioPeerError.invalidState }
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let terminalFailure {
                    continuation.resume(throwing: terminalFailure)
                } else if closed {
                    continuation.resume(throwing: LiveAudioPeerError.invalidState)
                } else {
                    failureWaiters[waiterID] = continuation
                    failureWaiterReady?()
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelFailureWaiter(id: waiterID) }
        })
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        connectedTimeoutGeneration &+= 1
        connectedTimeoutTask?.cancel()
        connectedTimeoutTask = nil
        connectedWaiter?.resume(throwing: LiveAudioPeerError.invalidState)
        connectedWaiter = nil
        answerWaiter?.resume(throwing: LiveAudioPeerError.invalidState)
        answerWaiter = nil
        let waiters = failureWaiters.values
        failureWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: LiveAudioPeerError.invalidState) }
    }

    private func cancelConnectedWaiter() {
        connectedTimeoutGeneration &+= 1
        connectedTimeoutTask?.cancel()
        connectedTimeoutTask = nil
        connectedWaiter?.resume(throwing: CancellationError())
        connectedWaiter = nil
    }

    private func cancelFailureWaiter(id: UUID) {
        guard let waiter = failureWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
    }
}

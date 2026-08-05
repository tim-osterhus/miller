import Foundation

public enum CodexAppServerClientError: Error, Equatable, Sendable {
    case wrongResponse
    case credentialRejected
    case missingTerminal
    case unexpectedMessage
    case timeout
    case sessionFailed
    case refreshUnavailable
    case sessionAlreadyActive
    case audioBackpressure
    case initializeProtocolMismatch
    case loginProtocolMismatch
    case loginFrameProtocolMismatch(CodexLoginFrameKind, LiveProtocolError?)
    case loginSequenceProtocolMismatch
    case threadStartProtocolMismatch
    case realtimeStartProtocolMismatch
    case realtimeStartDiagnostic(CodexRealtimeStartDiagnostic)
}

/// Fixed, non-sensitive outcomes for the experimental realtime-start boundary.
/// No upstream field, identifier, payload, or provider message is retained here.
public enum CodexRealtimeStartDiagnostic: String, Equatable, Sendable {
    case rejected = "realtime_start_rejected"
    case failed = "realtime_start_failed"
    case closed = "realtime_start_closed"
    case decodeOrFrameMismatch = "protocol_realtime_decode_frame"
    case responseOrder = "protocol_realtime_response_order"
    case threadStartOrder = "protocol_realtime_thread_start_order"
    case startedOrderOrVersion = "protocol_realtime_started_order_version"
    case sdpOrderOrThread = "protocol_realtime_sdp_order_thread"
    case credentialRefresh = "protocol_realtime_credential_refresh"
    case outOfBand = "protocol_realtime_out_of_band"
    case other = "protocol_realtime_other"
    case eof = "protocol_realtime_eof"
}

public enum CodexLoginFrameKind: String, Equatable, Sendable {
    case response
    case responseRoot
    case responseResult
    case loginCompleted
    case accountUpdated
    case credentialRefresh
    case accountOther
    case thread
    case methodOther
    case other
}

public typealias CodexCredentialRefreshProvider = @Sendable (String) async throws -> CodexOAuthCredential

public final class CodexAppServerClient: @unchecked Sendable {
    private enum StartupPhase { case initialize, login, threadStart, realtimeStart }
    private struct StartupNotifications {
        var accountLoginCompleted = false
        var accountUpdated = false
        var threadStartedID: String?
        var realtimeStarted = false
    }
    private enum StopAction { case none, send(String, String), cancelStartup, retainUntilAdmission }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var identity: LiveSessionIdentity?
        var helperThreadID: String?
        var contract = LiveSessionContract()
        var stopRequestID: String?
        var stopBeforeAdmission: LiveSessionIdentity?
        var stopAcknowledged = false
        var sessionAdmitted = false
        var realtimeStarted = false
        var peerConnected = false
        var peerAdmissionAborted = false
        var peerAdmissionWaiter: CheckedContinuation<Bool, Never>?
        var runGeneration = 0
        var nextAppendOrdinal = 0
        var pendingAppendIDs: Set<String> = []
        var acknowledgedAppendIDs: Set<String> = []

        func locked<T>(_ body: (State) throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body(self)
        }
    }

    private final class StartupTimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            timedOut = true
        }

        var didTimeOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }
    }

    private let process: CodexAppServerProcess
    private let codec: CodexAppServerProtocol
    private let bridge: CodexCredentialBridge
    private let refreshProvider: CodexCredentialRefreshProvider?
    private let state = State()

    public init(
        process: CodexAppServerProcess,
        codec: CodexAppServerProtocol = .init(),
        bridge: CodexCredentialBridge = .init(),
        refreshProvider: CodexCredentialRefreshProvider? = nil
    ) {
        self.process = process
        self.codec = codec
        self.bridge = bridge
        self.refreshProvider = refreshProvider
    }

    public var sessionState: LiveSessionState { state.locked { $0.contract.state } }
    public var unacknowledgedAudioCount: Int { state.locked { $0.pendingAppendIDs.count } }

    /// The former PCM route has no WebRTC offer and cannot start a realtime session.
    public func eventsWithoutWebRTCOffer(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        timeout: Duration = .seconds(30),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) -> AsyncThrowingStream<LiveSessionEvent, Error> {
        _ = identity; _ = credential; _ = timeout; _ = onCleanupPending
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: LiveProtocolError.invalidField)
        }
    }

    package func stopAndWaitForCleanup(
        onCleanupPending: @escaping @Sendable () async -> Void
    ) async {
        await process.stop(onCleanupPending: onCleanupPending)
    }

    public func appendAudio(
        _ audio: LiveAudioFrame,
        identity: LiveSessionIdentity
    ) throws {
        let request: (id: String, threadID: String)
        do {
            request = try state.locked { value in
                guard let admittedIdentity = value.identity else {
                    throw LiveSessionError.invalidSequence
                }
                guard admittedIdentity == identity else { throw LiveSessionError.staleGeneration }
                guard value.contract.state == .active, value.realtimeStarted,
                      let helperThreadID = value.helperThreadID
                else { throw LiveSessionError.invalidSequence }
                guard audio.sampleRate == 24_000, audio.numChannels == 1,
                      audio.samplesPerChannel == 2_400, audio.data.count == 4_800,
                      audio.itemID == nil
                else { throw LiveProtocolError.invalidField }
                guard value.pendingAppendIDs.count < 4 else {
                    try value.contract.accept(
                        .failed(threadID: identity.threadID, message: "audio_backpressure"),
                        generation: identity.generation
                    )
                    throw CodexAppServerClientError.audioBackpressure
                }
                let id = "\(identity.requestID):append:\(value.nextAppendOrdinal)"
                value.nextAppendOrdinal += 1
                value.pendingAppendIDs.insert(id)
                return (id, helperThreadID)
            }
        } catch CodexAppServerClientError.audioBackpressure {
            process.cancel()
            throw CodexAppServerClientError.audioBackpressure
        }
        do {
            try process.send(try codec.realtimeAppendAudioRequest(
                id: request.id,
                threadID: request.threadID,
                audio: audio
            ))
        } catch {
            _ = state.locked { $0.pendingAppendIDs.remove(request.id) }
            throw error
        }
    }

    /// Admits the public active state only after the local WebRTC peer has
    /// accepted the helper's SDP answer and reached a connected state.
    @discardableResult
    public func confirmPeerConnected(identity: LiveSessionIdentity) -> Bool {
        let result = state.locked { value -> (accepted: Bool, waiter: CheckedContinuation<Bool, Never>?) in
            guard value.identity == identity,
                  value.contract.state == .starting,
                  value.realtimeStarted,
                  !value.peerAdmissionAborted,
                  !value.peerConnected
            else { return (false, nil) }
            value.peerConnected = true
            let waiter = value.peerAdmissionWaiter
            value.peerAdmissionWaiter = nil
            return (true, waiter)
        }
        result.waiter?.resume(returning: true)
        return result.accepted
    }

    @discardableResult
    public func requestStop(identity: LiveSessionIdentity) throws -> Bool {
        let stopID = "\(identity.requestID):stop"
        let request = try state.locked { value -> (StopAction, CheckedContinuation<Bool, Never>?) in
            if value.identity == nil {
                if let retained = value.stopBeforeAdmission {
                    guard retained == identity else { throw LiveSessionError.staleGeneration }
                    return (.none, nil)
                }
                value.stopBeforeAdmission = identity
                return (.retainUntilAdmission, nil)
            }
            guard value.identity?.requestID == identity.requestID,
                  value.identity?.threadID == identity.threadID
            else { throw LiveSessionError.staleGeneration }
            let accepted = try value.contract.requestStop(generation: identity.generation)
            guard accepted else { return (.none, nil) }
            value.peerAdmissionAborted = true
            if value.realtimeStarted,
               let helperThreadID = value.helperThreadID {
                value.stopRequestID = stopID
                let waiter = value.peerAdmissionWaiter
                value.peerAdmissionWaiter = nil
                return (.send(stopID, helperThreadID), waiter)
            }
            try value.contract.accept(
                .closed(threadID: identity.threadID, reason: "stopped-during-startup"),
                generation: identity.generation
            )
            return (.cancelStartup, nil)
        }
        request.1?.resume(returning: false)
        switch request.0 {
        case .none: return false
        case let .send(stopID, helperThreadID):
            do { try process.send(try codec.realtimeStopRequest(id: stopID, threadID: helperThreadID)) }
            catch {
                process.cancel()
                throw error
            }
        case .cancelStartup:
            process.cancel()
        case .retainUntilAdmission:
            break
        }
        return true
    }

    public func runUntilClosed(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        offerSDP: String,
        timeout: Duration = .seconds(30),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) async throws -> [LiveSessionEvent] {
        var events: [LiveSessionEvent] = []
        for try await event in self.events(
            identity: identity,
            credential: credential,
            offerSDP: offerSDP,
            timeout: timeout,
            onCleanupPending: onCleanupPending
        ) {
            events.append(event)
        }
        try Task.checkCancellation()
        return events
    }

    public func events(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        offerSDP: String,
        timeout: Duration = .seconds(30),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) -> AsyncThrowingStream<LiveSessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.execute(
                        identity: identity,
                        credential: credential,
                        offerSDP: offerSDP,
                        timeout: timeout,
                        onCleanupPending: onCleanupPending
                    ) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        offerSDP: String,
        timeout: Duration,
        onCleanupPending: @escaping @Sendable () async -> Void,
        emit: @escaping @Sendable (LiveSessionEvent) -> Void
    ) async throws {
        do {
            try codec.validateWebRTCOffer(offerSDP)
        } catch {
            state.locked {
                if $0.stopBeforeAdmission == identity {
                    $0.stopBeforeAdmission = nil
                }
            }
            throw error
        }
        try state.locked {
            guard !$0.sessionAdmitted else {
                throw CodexAppServerClientError.sessionAlreadyActive
            }
            $0.sessionAdmitted = true
        }
        defer {
            state.locked {
                $0.sessionAdmitted = false
                $0.identity = nil
            }
        }
        let timeoutState = StartupTimeoutState()
        let startupWatchdog = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            timeoutState.markTimedOut()
            process.cancel()
        }
        defer { startupWatchdog.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await self.run(
                    identity: identity,
                    credential: credential,
                    offerSDP: offerSDP,
                    onStartupComplete: { startupWatchdog.cancel() },
                    onCleanupPending: onCleanupPending,
                    emit: emit
                )
            } onCancel: {
                process.cancel()
            }
        } catch {
            await process.stop(onCleanupPending: onCleanupPending)
            retainFailureStateIfNeeded()
            if timeoutState.didTimeOut {
                throw CodexAppServerClientError.timeout
            }
            throw error
        }
    }

    private func run(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        offerSDP: String,
        onStartupComplete: @escaping @Sendable () -> Void,
        onCleanupPending: @escaping @Sendable () async -> Void,
        emit: @escaping @Sendable (LiveSessionEvent) -> Void
    ) async throws {
        let initializeID = "\(identity.requestID):initialize"
        let loginID = "\(identity.requestID):login"
        let threadStartID = "\(identity.requestID):thread-start"
        let startID = "\(identity.requestID):start"
        var currentCredential = credential
        var startupNotifications = StartupNotifications()
        let setup = try state.locked { value -> (stoppedBeforeStartup: Bool, runGeneration: Int) in
            if let retained = value.stopBeforeAdmission, retained != identity {
                throw LiveSessionError.staleGeneration
            }
            value.identity = identity; value.helperThreadID = nil
            value.contract = LiveSessionContract(); value.stopRequestID = nil
            value.stopAcknowledged = false; value.realtimeStarted = false
            value.peerConnected = false; value.peerAdmissionAborted = false
            value.peerAdmissionWaiter = nil
            value.nextAppendOrdinal = 0; value.pendingAppendIDs = []
            value.acknowledgedAppendIDs = []
            value.runGeneration += 1
            try value.contract.begin(identity)
            guard value.stopBeforeAdmission == identity else {
                return (false, value.runGeneration)
            }
            value.stopBeforeAdmission = nil
            _ = try value.contract.requestStop(generation: identity.generation)
            try value.contract.accept(
                .closed(threadID: identity.threadID, reason: "stopped-during-startup"),
                generation: identity.generation
            )
            return (true, value.runGeneration)
        }
        if setup.stoppedBeforeStartup {
            emit(.closed(threadID: identity.threadID, reason: "stopped-during-startup"))
            return
        }
        let source = try process.start()
        var iterator = source.makeAsyncIterator()
        try process.send(try codec.initializeRequest(id: initializeID))
        do {
            try await expect(
                .initializeResponse(id: initializeID), phase: .initialize,
                notifications: &startupNotifications, iterator: &iterator
            )
        } catch {
            throw Self.classifyStartup(error, phase: .initialize)
        }
        try process.send(try codec.initializedNotification())
        try process.send(try bridge.loginRequest(id: loginID, credential: currentCredential))
        do {
            try await expect(
                .loginResponse(id: loginID), phase: .login,
                notifications: &startupNotifications, iterator: &iterator,
                credentialAdmission: true
            )
        } catch {
            throw Self.classifyStartup(error, phase: .login)
        }
        try process.send(try codec.threadStartRequest(
            id: threadStartID, cwd: process.temporaryRootURL.path
        ))
        let helperThreadID: String
        do {
            helperThreadID = try await expectThreadStart(
                id: threadStartID, notifications: &startupNotifications, iterator: &iterator
            )
        } catch {
            throw Self.classifyStartup(error, phase: .threadStart)
        }
        state.locked { $0.helperThreadID = helperThreadID }
        try process.send(try codec.realtimeStartRequest(
            id: startID,
            threadID: helperThreadID,
            offerSDP: offerSDP
        ))
        let answerSDP: String
        do {
            answerSDP = try await expectRealtimeStart(
                id: startID,
                helperThreadID: helperThreadID,
                identity: identity,
                runGeneration: setup.runGeneration,
                currentCredential: &currentCredential,
                notifications: &startupNotifications,
                iterator: &iterator
            )
        } catch {
            throw Self.classifyStartup(error, phase: .realtimeStart)
        }
        try Task.checkCancellation()
        let startedEvent = LiveSessionEvent.started(threadID: identity.threadID)
        try state.locked { value in
            guard value.identity == identity,
                  value.helperThreadID == helperThreadID,
                  value.runGeneration == setup.runGeneration,
                  value.contract.state == .starting
            else { throw LiveSessionError.staleGeneration }
            value.realtimeStarted = true
        }
        emit(.sdp(threadID: identity.threadID, value: answerSDP))
        let peerConnected = await waitForPeerConnected(
            identity: identity,
            helperThreadID: helperThreadID,
            runGeneration: setup.runGeneration
        )
        try Task.checkCancellation()
        let shouldEmitStarted = try state.locked { value -> Bool in
            guard peerConnected,
                  value.identity == identity,
                  value.helperThreadID == helperThreadID,
                  value.runGeneration == setup.runGeneration,
                  value.contract.state == .starting,
                  value.realtimeStarted,
                  value.peerConnected,
                  !value.peerAdmissionAborted
            else { return false }
            try value.contract.accept(startedEvent, generation: identity.generation)
            return true
        }
        if shouldEmitStarted {
            onStartupComplete()
            emit(startedEvent)
        }
        var terminal: LiveTerminalOutcome?
        while let data = try await iterator.next() {
            try Task.checkCancellation()
            let message = try codec.decode(data)
            switch message {
            case let .credentialRefresh(id, previousAccountID):
                try await refreshCredential(
                    id: id,
                    previousAccountID: previousAccountID,
                    currentCredential: &currentCredential
                )
            case let .realtimeItemAdded(threadID):
                guard threadID == helperThreadID else {
                    throw CodexAppServerClientError.unexpectedMessage
                }
            case let .emptyResponse(id):
                let acknowledged = state.locked { value -> Bool in
                    if value.stopRequestID == id, !value.stopAcknowledged {
                        value.stopAcknowledged = true
                        return true
                    }
                    guard value.pendingAppendIDs.remove(id) != nil,
                          value.acknowledgedAppendIDs.insert(id).inserted
                    else { return false }
                    return true
                }
                guard acknowledged else { throw CodexAppServerClientError.unexpectedMessage }
                if terminal != nil {
                    await process.stop(onCleanupPending: onCleanupPending)
                }
            case let .started(threadID, version):
                _ = threadID; _ = version
                throw CodexAppServerClientError.unexpectedMessage
            case .outOfBandStartupNotification:
                continue
            case .initializeResponse, .loginResponse, .threadStartResponse,
                 .accountLoginCompleted, .accountUpdated, .threadStarted, .requestError:
                throw CodexAppServerClientError.unexpectedMessage
            default:
                if case .sdp = message {
                    throw CodexAppServerClientError.unexpectedMessage
                }
                let event = try event(
                    from: message, helperThreadID: helperThreadID,
                    millerThreadID: identity.threadID
                )
                try accept(event, identity: identity)
                emit(event)
                terminal = state.locked { $0.contract.terminalOutcome }
                let awaitingStopAcknowledgement = state.locked {
                    $0.stopRequestID != nil && !$0.stopAcknowledged
                }
                if terminal != nil, !awaitingStopAcknowledgement {
                    await process.stop(onCleanupPending: onCleanupPending)
                }
            }
        }
        guard let terminal else { throw CodexAppServerClientError.missingTerminal }
        if state.locked({ $0.stopRequestID != nil && !$0.stopAcknowledged }) {
            throw CodexAppServerClientError.wrongResponse
        }
        if state.locked({ !$0.pendingAppendIDs.isEmpty }) {
            throw CodexAppServerClientError.wrongResponse
        }
        if terminal == .failed { throw CodexAppServerClientError.sessionFailed }
    }

    private func accept(_ event: LiveSessionEvent, identity: LiveSessionIdentity) throws {
        try state.locked { try $0.contract.accept(event, generation: identity.generation) }
    }

    private func waitForPeerConnected(
        identity: LiveSessionIdentity,
        helperThreadID: String,
        runGeneration: Int
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let immediate = state.locked { value -> Bool? in
                    guard value.identity == identity,
                          value.helperThreadID == helperThreadID,
                          value.runGeneration == runGeneration
                    else { return false }
                    guard value.contract.state == .starting,
                          !value.peerAdmissionAborted
                    else { return false }
                    if value.peerConnected { return true }
                    value.peerAdmissionWaiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        }, onCancel: {
            self.cancelPeerAdmission(identity: identity, runGeneration: runGeneration)
        })
    }

    private func cancelPeerAdmission(identity: LiveSessionIdentity, runGeneration: Int) {
        let waiter = state.locked { value -> CheckedContinuation<Bool, Never>? in
            guard value.identity == identity, value.runGeneration == runGeneration else { return nil }
            value.peerAdmissionAborted = true
            let waiter = value.peerAdmissionWaiter
            value.peerAdmissionWaiter = nil
            return waiter
        }
        waiter?.resume(returning: false)
    }

    private static func classifyStartup(
        _ error: Error,
        phase: StartupPhase
    ) -> Error {
        if phase == .realtimeStart {
            if let client = error as? CodexAppServerClientError {
                switch client {
                case .realtimeStartDiagnostic:
                    return client
                case .wrongResponse:
                    return CodexAppServerClientError.realtimeStartDiagnostic(.eof)
                case .unexpectedMessage:
                    return CodexAppServerClientError.realtimeStartDiagnostic(.other)
                default:
                    break
                }
            }
            if error is LiveProtocolError || error as? LiveProcessError == .invalidFrame {
                return CodexAppServerClientError.realtimeStartDiagnostic(.decodeOrFrameMismatch)
            }
        }
        let isProtocolMismatch: Bool
        if error is LiveProtocolError {
            isProtocolMismatch = true
        } else if let process = error as? LiveProcessError {
            isProtocolMismatch = process == .invalidFrame
        } else if let client = error as? CodexAppServerClientError {
            isProtocolMismatch = client == .wrongResponse || client == .unexpectedMessage
        } else {
            isProtocolMismatch = false
        }
        guard isProtocolMismatch else { return error }
        switch phase {
        case .initialize: return CodexAppServerClientError.initializeProtocolMismatch
        case .login:
            if let protocolError = error as? LiveProtocolError {
                return CodexAppServerClientError.loginFrameProtocolMismatch(.other, protocolError)
            }
            if error is LiveProcessError {
                return CodexAppServerClientError.loginFrameProtocolMismatch(.other, nil)
            }
            return CodexAppServerClientError.loginSequenceProtocolMismatch
        case .threadStart: return CodexAppServerClientError.threadStartProtocolMismatch
        case .realtimeStart: return CodexAppServerClientError.realtimeStartProtocolMismatch
        }
    }

    private func expect(
        _ expected: CodexAppServerMessage,
        phase: StartupPhase,
        notifications: inout StartupNotifications,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator,
        credentialAdmission: Bool = false
    ) async throws {
        while let data = try await iterator.next() {
            let message: CodexAppServerMessage
            do {
                message = try codec.decode(data)
            } catch {
                if phase == .login {
                    throw CodexAppServerClientError.loginFrameProtocolMismatch(
                        Self.loginFrameKind(data), error as? LiveProtocolError
                    )
                }
                throw error
            }
            if message == expected {
                return
            }
            if case .requestError = message, credentialAdmission {
                throw CodexAppServerClientError.credentialRejected
            }
            try consumeStartupNotification(
                message, phase: phase, notifications: &notifications
            )
        }
        throw CodexAppServerClientError.wrongResponse
    }

    private static func loginFrameKind(_ data: Data) -> CodexLoginFrameKind {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .other
        }
        switch root["method"] as? String {
        case "account/login/completed": return .loginCompleted
        case "account/updated": return .accountUpdated
        case "account/chatgptAuthTokens/refresh": return .credentialRefresh
        case let .some(method) where method.hasPrefix("account/"): return .accountOther
        case let .some(method) where method.hasPrefix("thread/"): return .thread
        case .some: return .methodOther
        case .none:
            if root["result"] != nil || root["error"] != nil {
                if !Set(root.keys).isSubset(of: ["id", "result", "error"]) {
                    return .responseRoot
                }
                if let result = root["result"] as? [String: Any],
                   !Set(result.keys).isSubset(of: ["type"])
                {
                    return .responseResult
                }
                return .response
            }
            return .other
        }
    }

    private func expectThreadStart(
        id: String,
        notifications: inout StartupNotifications,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws -> String {
        var responseThreadID: String?
        while let data = try await iterator.next() {
            let message = try codec.decode(data)
            if case let .threadStartResponse(responseID, threadID) = message,
               responseID == id {
                guard responseThreadID == nil else {
                    throw CodexAppServerClientError.unexpectedMessage
                }
                responseThreadID = threadID
                if notifications.accountLoginCompleted, notifications.accountUpdated {
                    return threadID
                }
                continue
            }
            if case let .threadStarted(threadID) = message {
                guard let responseThreadID,
                      notifications.threadStartedID == nil,
                      threadID == responseThreadID
                else { throw CodexAppServerClientError.unexpectedMessage }
                notifications.threadStartedID = threadID
                if notifications.accountLoginCompleted, notifications.accountUpdated {
                    return responseThreadID
                }
                continue
            }
            try consumeStartupNotification(
                message, phase: .threadStart, notifications: &notifications
            )
            if notifications.accountLoginCompleted, notifications.accountUpdated,
               let responseThreadID {
                return responseThreadID
            }
        }
        throw CodexAppServerClientError.wrongResponse
    }

    private func consumeStartupNotification(
        _ message: CodexAppServerMessage,
        phase: StartupPhase,
        notifications: inout StartupNotifications
    ) throws {
        switch (phase, message) {
        case (_, .outOfBandStartupNotification):
            return
        case (.threadStart, .accountLoginCompleted):
            guard !notifications.accountLoginCompleted else {
                throw CodexAppServerClientError.unexpectedMessage
            }
            notifications.accountLoginCompleted = true
        case (.threadStart, .accountUpdated):
            guard notifications.accountLoginCompleted, !notifications.accountUpdated else {
                throw CodexAppServerClientError.unexpectedMessage
            }
            notifications.accountUpdated = true
        default:
            throw CodexAppServerClientError.unexpectedMessage
        }
    }

    private func expectRealtimeStart(
        id: String,
        helperThreadID: String,
        identity: LiveSessionIdentity,
        runGeneration: Int,
        currentCredential: inout CodexOAuthCredential,
        notifications: inout StartupNotifications,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws -> String {
        var responseSeen = false
        var answerSDP: String?
        while let data = try await iterator.next() {
            try Task.checkCancellation()
            let message: CodexAppServerMessage
            do {
                message = try codec.decode(data)
            } catch {
                throw CodexAppServerClientError.realtimeStartDiagnostic(.decodeOrFrameMismatch)
            }
            switch message {
            case let .emptyResponse(responseID) where responseID == id:
                guard !responseSeen else {
                    throw CodexAppServerClientError.realtimeStartDiagnostic(.responseOrder)
                }
                responseSeen = true
            case .emptyResponse:
                throw CodexAppServerClientError.realtimeStartDiagnostic(.responseOrder)
            case let .requestError(responseID, _, _) where responseID == id:
                throw CodexAppServerClientError.realtimeStartDiagnostic(.rejected)
            case .requestError:
                throw CodexAppServerClientError.realtimeStartDiagnostic(.other)
            case let .started(threadID, version):
                guard !notifications.realtimeStarted,
                      threadID == helperThreadID,
                      version == .v3
                else {
                    throw CodexAppServerClientError.realtimeStartDiagnostic(.startedOrderOrVersion)
                }
                notifications.realtimeStarted = true
            case let .sdp(threadID, value):
                guard notifications.realtimeStarted,
                      answerSDP == nil,
                      threadID == helperThreadID
                else {
                    throw CodexAppServerClientError.realtimeStartDiagnostic(.sdpOrderOrThread)
                }
                answerSDP = value
            case let .threadStarted(threadID):
                guard notifications.threadStartedID == nil,
                      threadID == helperThreadID
                else {
                    throw CodexAppServerClientError.realtimeStartDiagnostic(.threadStartOrder)
                }
                notifications.threadStartedID = threadID
            case let .credentialRefresh(refreshID, previousAccountID):
                do {
                    try await refreshCredential(
                        id: refreshID,
                        previousAccountID: previousAccountID,
                        currentCredential: &currentCredential
                    )
                } catch let error as CodexAppServerClientError
                    where error == .credentialRejected {
                    throw error
                } catch {
                    throw CodexAppServerClientError.realtimeStartDiagnostic(.credentialRefresh)
                }
            case let .error(threadID, _):
                guard threadID == helperThreadID else {
                    throw CodexAppServerClientError.realtimeStartDiagnostic(.other)
                }
                throw CodexAppServerClientError.realtimeStartDiagnostic(.failed)
            case let .closed(threadID, _):
                guard threadID == helperThreadID else {
                    throw CodexAppServerClientError.realtimeStartDiagnostic(.other)
                }
                throw CodexAppServerClientError.realtimeStartDiagnostic(.closed)
            case .outOfBandStartupNotification:
                continue
            default:
                throw CodexAppServerClientError.realtimeStartDiagnostic(.other)
            }
            if responseSeen, notifications.threadStartedID == helperThreadID,
               notifications.realtimeStarted, let answerSDP {
                let isCurrentRun = state.locked { value in
                    value.identity == identity &&
                        value.helperThreadID == helperThreadID &&
                        value.runGeneration == runGeneration
                }
                guard isCurrentRun else { throw LiveSessionError.staleGeneration }
                return answerSDP
            }
        }
        throw CodexAppServerClientError.realtimeStartDiagnostic(.eof)
    }

    private func refreshCredential(
        id: JSONRPCRequestID,
        previousAccountID: String?,
        currentCredential: inout CodexOAuthCredential
    ) async throws {
        guard let refreshProvider else { throw CodexAppServerClientError.refreshUnavailable }
        let replacement: CodexOAuthCredential
        do { replacement = try await refreshProvider(currentCredential.accountID) }
        catch { throw CodexAppServerClientError.credentialRejected }
        guard replacement.accountID == currentCredential.accountID,
              replacement.accessToken != currentCredential.accessToken
        else { throw CodexAppServerClientError.credentialRejected }
        try process.send(try bridge.refreshResponse(
            id: id,
            previousAccountID: previousAccountID,
            credential: replacement
        ))
        currentCredential = replacement
    }

    private func event(
        from message: CodexAppServerMessage,
        helperThreadID: String,
        millerThreadID: String
    ) throws -> LiveSessionEvent {
        switch message {
        case let .sdp(threadID, value):
            guard threadID == helperThreadID else { throw CodexAppServerClientError.unexpectedMessage }
            return .sdp(threadID: millerThreadID, value: value)
        case let .transcriptDelta(threadID, role, delta):
            guard threadID == helperThreadID else { throw CodexAppServerClientError.unexpectedMessage }
            return .transcriptDelta(threadID: millerThreadID, role: role, delta: delta)
        case let .transcriptDone(threadID, role, text):
            guard threadID == helperThreadID else { throw CodexAppServerClientError.unexpectedMessage }
            return .transcriptDone(threadID: millerThreadID, role: role, text: text)
        case let .outputAudio(threadID, audio):
            guard threadID == helperThreadID else { throw CodexAppServerClientError.unexpectedMessage }
            return .outputAudio(threadID: millerThreadID, audio: audio)
        case let .error(threadID, message):
            guard threadID == helperThreadID else { throw CodexAppServerClientError.unexpectedMessage }
            return .failed(threadID: millerThreadID, message: message)
        case let .closed(threadID, reason):
            guard threadID == helperThreadID else { throw CodexAppServerClientError.unexpectedMessage }
            return .closed(threadID: millerThreadID, reason: reason)
        default: throw CodexAppServerClientError.unexpectedMessage
        }
    }

    private func retainFailureStateIfNeeded() {
        state.locked { value in
            guard let identity = value.identity,
                  value.contract.terminalOutcome == nil else { return }
            try? value.contract.accept(
                .failed(threadID: identity.threadID, message: ""),
                generation: identity.generation
            )
        }
    }
}

import Foundation
import MillerCore

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
    private struct ProviderApprovalCallAuthority: Hashable {
        let threadID: String
        let turnID: String
        let callID: String

        init(_ approval: CodexProviderApproval) {
            threadID = approval.threadID
            turnID = approval.turnID
            callID = approval.approvalID ?? approval.itemID
        }
    }
    private enum StopAction { case none, send(String, String), cancelStartup, retainUntilAdmission }
    private enum TypedStopAction {
        case none
        case interrupt(String, String, String)
        case cancelStartup
    }

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
        var typedThreadID: String?
        var typedTurnID: String?
        var typedInterruptID: String?
        var typedActive = false

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
    private let onCapabilityActivity: CodexCapabilityActivityHandler
    private let resolveProviderApproval: CodexProviderApprovalResolver
    private let resolveProviderApprovalDetails: CodexProviderApprovalDetailsResolver?
    private let existingMillerCapabilities: [CapabilityDescriptor]
    private let portableSkillRoot: String?
    private let portableSkillInstructions: String?
    private let state = State()

    public init(
        process: CodexAppServerProcess,
        codec: CodexAppServerProtocol? = nil,
        bridge: CodexCredentialBridge = .init(),
        refreshProvider: CodexCredentialRefreshProvider? = nil,
        onCapabilityActivity: @escaping CodexCapabilityActivityHandler = { _ in },
        resolveProviderApproval: @escaping CodexProviderApprovalResolver = { _ in .decline },
        resolveProviderApprovalDetails: CodexProviderApprovalDetailsResolver? = nil,
        existingMillerCapabilities: [CapabilityDescriptor] = [],
        portableSkillRoot: String? = nil,
        portableSkillInstructions: String? = nil
    ) {
        self.process = process
        self.codec = codec ?? CodexAppServerProtocol(
            existingMillerCapabilities: existingMillerCapabilities
        )
        self.bridge = bridge
        self.refreshProvider = refreshProvider
        self.onCapabilityActivity = onCapabilityActivity
        self.resolveProviderApproval = resolveProviderApproval
        self.resolveProviderApprovalDetails = resolveProviderApprovalDetails
        self.existingMillerCapabilities = existingMillerCapabilities
        self.portableSkillRoot = portableSkillRoot
        self.portableSkillInstructions = portableSkillInstructions
    }

    public var sessionState: LiveSessionState { state.locked { $0.contract.state } }
    public var unacknowledgedAudioCount: Int { state.locked { $0.pendingAppendIDs.count } }
    package var hasActiveTypedTurn: Bool {
        state.locked { $0.typedActive && $0.typedThreadID != nil && $0.typedTurnID != nil }
    }

    public func inventoryCapabilities(
        requestID: String,
        credential: CodexOAuthCredential,
        codexProviderProfileID: UUID,
        existingMillerCapabilities: [CapabilityDescriptor],
        timeout: Duration = .seconds(15),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) async throws -> CapabilityCatalogSnapshot {
        let admitted = state.locked { value -> Bool in
            guard !value.typedActive, !value.sessionAdmitted else { return false }
            value.typedActive = true
            return true
        }
        guard admitted else { throw CodexAppServerClientError.sessionAlreadyActive }
        defer { state.locked { $0.typedActive = false } }

        let timeoutState = StartupTimeoutState()
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            timeoutState.markTimedOut()
            self.process.cancel()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler(operation: {
            do {
            let wire = CodexCapabilityProtocol()
            let typed = CodexTypedProtocol()
            var currentCredential = credential
            let source = try process.start()
            var iterator = source.makeAsyncIterator()
            try await typedHandshake(
                prefix: requestID,
                credential: &currentCredential,
                codec: typed,
                iterator: &iterator
            )

            var apps: [CodexAccountApp] = []
            var appCursor: String?
            var appCursors = Set<String>()
            for pageNumber in 0..<32 {
                let id = "\(requestID):apps:\(pageNumber)"
                try process.send(try wire.appsListRequest(
                    id: id, cursor: appCursor, limit: 100
                ))
                let frame = try await awaitCapabilityResponse(
                    id: id, currentCredential: &currentCredential,
                    codec: typed, iterator: &iterator
                )
                let page = try wire.decodeAppsListResponse(frame, expectedID: id)
                apps.append(contentsOf: page.items)
                guard apps.count <= wire.maximumItems else {
                    throw CodexCapabilityProtocolError.catalogTooLarge
                }
                guard let next = page.nextCursor else {
                    appCursor = nil
                    break
                }
                guard appCursors.insert(next).inserted else {
                    throw CodexCapabilityProtocolError.wrongResponse
                }
                appCursor = next
            }
            guard appCursor == nil else { throw CodexCapabilityProtocolError.tooManyItems }

            var appDetails: [CodexAccountAppTool] = []
            for (chunkNumber, start) in stride(
                from: 0, to: apps.count, by: 100
            ).enumerated() {
                let id = "\(requestID):app-read:\(chunkNumber)"
                let appIDs = Array(apps[start..<min(start + 100, apps.count)]).map(\.id)
                try process.send(try wire.appsReadRequest(id: id, appIDs: appIDs))
                let frame = try await awaitCapabilityResponse(
                    id: id, currentCredential: &currentCredential,
                    codec: typed, iterator: &iterator
                )
                appDetails.append(contentsOf: try wire.decodeAppsReadResponse(
                    frame, expectedID: id
                ))
                guard appDetails.count <= wire.maximumItems else {
                    throw CodexCapabilityProtocolError.catalogTooLarge
                }
            }

            let installedID = "\(requestID):installed"
            try process.send(try wire.appsInstalledRequest(id: installedID))
            let installedFrame = try await awaitCapabilityResponse(
                id: installedID, currentCredential: &currentCredential,
                codec: typed, iterator: &iterator
            )
            let installed = try wire.decodeAppsInstalledResponse(
                installedFrame, expectedID: installedID
            )

            var servers: [CodexMCPServer] = []
            var serverToolCount = 0
            var mcpCursor: String?
            var mcpCursors = Set<String>()
            for pageNumber in 0..<32 {
                let id = "\(requestID):mcp:\(pageNumber)"
                try process.send(try wire.mcpServerStatusListRequest(
                    id: id, cursor: mcpCursor, limit: 100
                ))
                let frame = try await awaitCapabilityResponse(
                    id: id, currentCredential: &currentCredential,
                    codec: typed, iterator: &iterator
                )
                let page = try wire.decodeMCPServerStatusResponse(frame, expectedID: id)
                serverToolCount += page.items.reduce(0) { $0 + $1.tools.count }
                guard serverToolCount <= wire.maximumItems else {
                    throw CodexCapabilityProtocolError.catalogTooLarge
                }
                servers.append(contentsOf: page.items)
                guard servers.count <= wire.maximumItems else {
                    throw CodexCapabilityProtocolError.catalogTooLarge
                }
                guard let next = page.nextCursor else {
                    mcpCursor = nil
                    break
                }
                guard mcpCursors.insert(next).inserted else {
                    throw CodexCapabilityProtocolError.wrongResponse
                }
                mcpCursor = next
            }
            guard mcpCursor == nil else { throw CodexCapabilityProtocolError.tooManyItems }

            let catalog = try wire.projectCatalog(
                apps: apps,
                appDetails: appDetails,
                installedApps: installed,
                mcpServers: servers,
                codexProviderProfileID: codexProviderProfileID,
                existingMillerCapabilities: existingMillerCapabilities
            )
            await process.stop(onCleanupPending: onCleanupPending)
            return catalog
            } catch {
                await process.stop(onCleanupPending: onCleanupPending)
                if timeoutState.didTimeOut { throw CodexAppServerClientError.timeout }
                throw error
            }
        }, onCancel: {
            self.process.cancel()
        })
    }

    public func typedEvents(
        requestID: String,
        credential: CodexOAuthCredential,
        model: String,
        cwd: String,
        context: [CodexTypedContextMessage],
        userText: String,
        skillRoot: String? = nil,
        skills: [CodexTypedSkillInput] = [],
        timeout: Duration = .seconds(120),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) -> AsyncThrowingStream<CodexTypedMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.executeTyped(
                        requestID: requestID,
                        credential: credential,
                        model: model,
                        cwd: cwd,
                        context: context,
                        userText: userText,
                        skillRoot: skillRoot,
                        skills: skills,
                        timeout: timeout,
                        onCleanupPending: onCleanupPending,
                        emit: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                Task {
                    await self.interruptTyped()
                    task.cancel()
                }
            }
        }
    }

    public func interruptTyped(
        timeout: Duration = .seconds(2),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) async {
        let action = state.locked { value -> TypedStopAction in
            guard value.typedActive else { return .none }
            guard let threadID = value.typedThreadID,
                  let turnID = value.typedTurnID
            else { return .cancelStartup }
            guard value.typedInterruptID == nil else { return .none }
            let id = "typed:interrupt:\(UUID().uuidString.lowercased())"
            value.typedInterruptID = id
            return .interrupt(id, threadID, turnID)
        }
        switch action {
        case .none:
            return
        case .cancelStartup:
            process.cancel()
            await process.stop(onCleanupPending: onCleanupPending)
            return
        case .interrupt(let id, let threadID, let turnID):
            do {
                try process.send(try CodexTypedProtocol().turnInterruptRequest(
                    id: id, threadID: threadID, turnID: turnID
                ))
                try await process.waitForTermination(timeout: timeout)
            } catch {
                await process.stop(onCleanupPending: onCleanupPending)
            }
        }
    }

    public func probeTypedFeatures(
        credential: CodexOAuthCredential,
        model: String,
        cwd: String,
        timeout: Duration = .seconds(5),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) async throws -> CodexTypedReadiness {
        let codec = CodexTypedProtocol()
        let prefix = "probe:\(UUID().uuidString.lowercased())"
        let timeoutState = StartupTimeoutState()
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            timeoutState.markTimedOut()
            self.process.cancel()
        }
        defer { watchdog.cancel() }
        do {
            var currentCredential = credential
            let source = try process.start()
            var iterator = source.makeAsyncIterator()
            try await typedHandshake(
                prefix: prefix, credential: &currentCredential, codec: codec,
                iterator: &iterator
            )
            let threadRequestID = "\(prefix):probe:thread-start"
            try process.send(try codec.threadStartRequest(
                id: threadRequestID, model: model, cwd: cwd
            ))
            let helperThreadID = try await awaitTypedThread(
                id: threadRequestID,
                cwd: cwd,
                currentCredential: &currentCredential,
                codec: codec,
                iterator: &iterator
            )
            let turnRequestID = "\(prefix):probe:turn-start"
            try process.send(try codec.turnStartRequest(
                id: turnRequestID,
                threadID: helperThreadID,
                cwd: cwd,
                context: [],
                userText: "Reply with OK."
            ))
            let helperTurnID = try await awaitTypedTurn(
                id: turnRequestID,
                threadID: helperThreadID,
                currentCredential: &currentCredential,
                codec: codec,
                iterator: &iterator
            )
            var sawStreamedText = false
            var sawTerminal = false
            while let data = try await iterator.next() {
                switch try codec.decode(data) {
                case .assistantTextDelta(let threadID, let turnID, _, let text)
                    where threadID == helperThreadID && turnID == helperTurnID
                        && !text.isEmpty:
                    sawStreamedText = true
                case .turnCompleted(let threadID, let turnID, let outcome)
                    where threadID == helperThreadID && turnID == helperTurnID:
                    guard outcome == .completed else {
                        throw CodexTypedProtocolError.providerFailed
                    }
                    sawTerminal = true
                case .assistantTextDelta, .assistantMessageCompleted,
                     .capabilityActivity, .ignored, .threadStarted:
                    continue
                case .credentialRefresh(let refreshID, let previousAccountID):
                    try await refreshCredential(
                        id: refreshID,
                        previousAccountID: previousAccountID,
                        currentCredential: &currentCredential
                    )
                case .unsupportedApproval(let approvalID):
                    try process.send(try codec.declineUnsupportedApproval(id: approvalID))
                case .unsupportedPermissionsApproval(let approvalID):
                    try process.send(try codec.declineUnsupportedPermissionsApproval(
                        id: approvalID
                    ))
                case .requestError:
                    throw CodexTypedProtocolError.providerFailed
                default:
                    throw CodexTypedProtocolError.featureUnavailable
                }
                if sawTerminal { break }
            }
            guard sawStreamedText, sawTerminal else {
                throw CodexTypedProtocolError.featureUnavailable
            }
            let requests = try codec.featureProbeRequests(
                requestPrefix: "\(prefix):probe", cwd: cwd
            )
            var observed: Set<String> = ["thread/start", "turn/start"]
            for request in requests {
                let object = try JSONSerialization.jsonObject(with: request) as? [String: Any]
                guard let method = object?["method"] as? String,
                      let id = object?["id"] as? String
                else { throw CodexTypedProtocolError.invalidField }
                try process.send(request)
                while let data = try await iterator.next() {
                    let message = try codec.decode(data)
                    switch message {
                    case .featureResponse(let responseID) where responseID == id,
                         .threadStartResponse(let responseID, _, _) where responseID == id,
                         .turnStartResponse(let responseID, _) where responseID == id,
                         .emptyResponse(let responseID) where responseID == id:
                        observed.insert(method)
                    case .requestError(let responseID, let code) where responseID == id:
                        if code == -32601 || code == -32602 {
                            throw CodexTypedProtocolError.featureUnavailable
                        }
                        throw CodexTypedProtocolError.providerFailed
                    case .credentialRefresh(let refreshID, let previousAccountID):
                        try await refreshCredential(
                            id: refreshID,
                            previousAccountID: previousAccountID,
                            currentCredential: &currentCredential
                        )
                    case .unsupportedApproval(let approvalID):
                        try process.send(try codec.declineUnsupportedApproval(id: approvalID))
                    case .unsupportedPermissionsApproval(let approvalID):
                        try process.send(try codec.declineUnsupportedPermissionsApproval(
                            id: approvalID
                        ))
                    case .ignored, .threadStarted:
                        continue
                    default:
                        throw CodexTypedProtocolError.invalidSequence
                    }
                    if observed.contains(method) { break }
                }
                guard observed.contains(method) else {
                    throw CodexTypedProtocolError.featureUnavailable
                }
            }
            await process.stop(onCleanupPending: onCleanupPending)
            return .init(
                supportsOrdinaryTurns: observed.contains("thread/start")
                    && observed.contains("turn/start"),
                supportsApps: observed.contains("app/list"),
                supportsMCPStatus: observed.contains("mcpServerStatus/list"),
                supportsSkills: observed.contains("skills/list")
            )
        } catch {
            await process.stop(onCleanupPending: onCleanupPending)
            if timeoutState.didTimeOut { throw CodexAppServerClientError.timeout }
            throw error
        }
    }

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

    private func executeTyped(
        requestID: String,
        credential: CodexOAuthCredential,
        model: String,
        cwd: String,
        context: [CodexTypedContextMessage],
        userText: String,
        skillRoot: String?,
        skills: [CodexTypedSkillInput],
        timeout: Duration,
        onCleanupPending: @escaping @Sendable () async -> Void,
        emit: @escaping @Sendable (CodexTypedMessage) -> Void
    ) async throws {
        let admitted = state.locked { value -> Bool in
            guard !value.typedActive, !value.sessionAdmitted else { return false }
            value.typedActive = true
            value.typedThreadID = nil
            value.typedTurnID = nil
            value.typedInterruptID = nil
            return true
        }
        guard admitted else { throw CodexAppServerClientError.sessionAlreadyActive }
        defer {
            state.locked {
                $0.typedActive = false
                $0.typedThreadID = nil
                $0.typedTurnID = nil
                $0.typedInterruptID = nil
            }
        }
        let timeoutState = StartupTimeoutState()
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            timeoutState.markTimedOut()
            self.process.cancel()
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let codec = CodexTypedProtocol()
                var currentCredential = credential
                let source = try process.start()
                try Task.checkCancellation()
                var iterator = source.makeAsyncIterator()
                try await typedHandshake(
                    prefix: requestID,
                    credential: &currentCredential,
                    codec: codec,
                    iterator: &iterator
                )
                if let skillRoot {
                    let rootsID = "\(requestID):skills-roots"
                    try process.send(try codec.skillsExtraRootsSetRequest(
                        id: rootsID, roots: [skillRoot]
                    ))
                    try await awaitTypedFeature(
                        id: rootsID, credential: &currentCredential,
                        codec: codec, iterator: &iterator
                    )
                    let listID = "\(requestID):skills-list"
                    try process.send(try codec.skillsListRequest(id: listID, cwd: cwd))
                    try await awaitTypedFeature(
                        id: listID, credential: &currentCredential,
                        codec: codec, iterator: &iterator
                    )
                }
                let threadRequestID = "\(requestID):thread-start"
                try process.send(try codec.threadStartRequest(
                    id: threadRequestID, model: model, cwd: cwd
                ))
                let helperThreadID = try await awaitTypedThread(
                    id: threadRequestID,
                    cwd: cwd,
                    currentCredential: &currentCredential,
                    codec: codec,
                    iterator: &iterator
                )
                state.locked { $0.typedThreadID = helperThreadID }
                let turnRequestID = "\(requestID):turn-start"
                try process.send(try codec.turnStartRequest(
                    id: turnRequestID,
                    threadID: helperThreadID,
                    cwd: cwd,
                    context: context,
                    userText: userText,
                    skills: skills
                ))
                let responseTurnID = try await awaitTypedTurn(
                    id: turnRequestID,
                    threadID: helperThreadID,
                    currentCredential: &currentCredential,
                    codec: codec,
                    iterator: &iterator
                )
                state.locked { $0.typedTurnID = responseTurnID }
                var sequence = CodexTypedTerminalSequence()
                _ = try sequence.accept(.turnStarted(
                    threadID: helperThreadID,
                    turnID: responseTurnID
                ))
                let capabilityCodec = CodexCapabilityProtocol()
                var approvalResponseIDs = Set<JSONRPCRequestID>()
                var approvalCalls = Set<ProviderApprovalCallAuthority>()
                while let data = try await iterator.next() {
                    switch try capabilityCodec.decodeActivity(
                        data,
                        existingMillerCapabilities: existingMillerCapabilities
                    ) {
                    case .activity(let activity):
                        guard activity.threadID == helperThreadID,
                              activity.turnID == responseTurnID
                        else { throw CodexTypedProtocolError.invalidSequence }
                        await onCapabilityActivity(activity)
                    case .approval(let approval):
                        guard approval.threadID == helperThreadID,
                              approval.turnID == responseTurnID
                        else { throw CodexTypedProtocolError.invalidSequence }
                        guard approvalResponseIDs.insert(approval.responseID).inserted,
                              approvalCalls.insert(.init(approval)).inserted
                        else { throw CodexTypedProtocolError.invalidSequence }
                        let decision = if let resolveProviderApprovalDetails {
                            await resolveProviderApprovalDetails(approval)
                        } else {
                            await resolveProviderApproval(approval.request)
                        }
                        try Task.checkCancellation()
                        try process.send(try capabilityCodec.approvalResponse(
                            approval, decision: decision
                        ))
                        continue
                    case .ignored:
                        continue
                    case .notCapability:
                        break
                    }
                    let message = try codec.decode(data)
                    switch message {
                    case .ignored, .threadStarted:
                        continue
                    case .emptyResponse(let id):
                        let expected = state.locked { $0.typedInterruptID }
                        guard id == expected else {
                            throw CodexTypedProtocolError.invalidSequence
                        }
                        continue
                    case .requestError:
                        throw CodexTypedProtocolError.providerFailed
                    case .credentialRefresh(let refreshID, let previousAccountID):
                        try await refreshCredential(
                            id: refreshID,
                            previousAccountID: previousAccountID,
                            currentCredential: &currentCredential
                        )
                    case .unsupportedApproval(let approvalID):
                        try process.send(try codec.declineUnsupportedApproval(id: approvalID))
                    case .unsupportedPermissionsApproval(let approvalID):
                        try process.send(try codec.declineUnsupportedPermissionsApproval(
                            id: approvalID
                        ))
                    default:
                        let isTerminal = try sequence.accept(message)
                        if isTerminal {
                            await process.stop(onCleanupPending: onCleanupPending)
                            emit(message)
                            return
                        }
                        emit(message)
                    }
                }
                throw CodexAppServerClientError.missingTerminal
            } onCancel: {
                self.process.cancel()
            }
        } catch {
            await process.stop(onCleanupPending: onCleanupPending)
            if timeoutState.didTimeOut { throw CodexAppServerClientError.timeout }
            throw error
        }
    }

    private func awaitTypedFeature(
        id: String,
        credential: inout CodexOAuthCredential,
        codec: CodexTypedProtocol,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws {
        while let data = try await iterator.next() {
            switch try codec.decode(data) {
            case .featureResponse(let responseID) where responseID == id:
                return
            case .credentialRefresh(let refreshID, let previousAccountID):
                try await refreshCredential(
                    id: refreshID, previousAccountID: previousAccountID,
                    currentCredential: &credential
                )
            case .unsupportedApproval(let approvalID):
                try process.send(try codec.declineUnsupportedApproval(id: approvalID))
            case .unsupportedPermissionsApproval(let approvalID):
                try process.send(try codec.declineUnsupportedPermissionsApproval(id: approvalID))
            case .ignored:
                continue
            case .requestError(let responseID, _) where responseID == id:
                throw CodexTypedProtocolError.featureUnavailable
            default:
                throw CodexTypedProtocolError.invalidSequence
            }
        }
        throw CodexAppServerClientError.wrongResponse
    }

    private func awaitLiveSkillFeature(
        id: String,
        helperThreadID: String,
        credential: inout CodexOAuthCredential,
        codec: CodexTypedProtocol,
        notifications: inout StartupNotifications,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws {
        while let data = try await iterator.next() {
            switch try codec.decode(data) {
            case .featureResponse(let responseID) where responseID == id:
                return
            case .threadStarted(let threadID):
                guard threadID == helperThreadID,
                      notifications.threadStartedID == nil
                else { throw CodexTypedProtocolError.invalidSequence }
                notifications.threadStartedID = threadID
            case .credentialRefresh(let refreshID, let previousAccountID):
                try await refreshCredential(
                    id: refreshID, previousAccountID: previousAccountID,
                    currentCredential: &credential
                )
            case .unsupportedApproval(let approvalID):
                try process.send(try codec.declineUnsupportedApproval(id: approvalID))
            case .unsupportedPermissionsApproval(let approvalID):
                try process.send(try codec.declineUnsupportedPermissionsApproval(id: approvalID))
            case .ignored:
                continue
            case .requestError(let responseID, _) where responseID == id:
                throw CodexTypedProtocolError.featureUnavailable
            default:
                throw CodexTypedProtocolError.invalidSequence
            }
        }
        throw CodexAppServerClientError.wrongResponse
    }

    private func typedHandshake(
        prefix: String,
        credential: inout CodexOAuthCredential,
        codec: CodexTypedProtocol,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws {
        let initializeID = "\(prefix):initialize"
        try process.send(try codec.initializeRequest(id: initializeID))
        try await awaitTypedResponse(
            matching: .initializeResponse(id: initializeID),
            currentCredential: &credential,
            codec: codec,
            iterator: &iterator
        )
        try process.send(try codec.initializedNotification())
        let loginID = "\(prefix):login"
        try process.send(try bridge.loginRequest(id: loginID, credential: credential))
        try await awaitTypedResponse(
            matching: .loginResponse(id: loginID),
            currentCredential: &credential,
            codec: codec,
            iterator: &iterator
        )
    }

    private func awaitCapabilityResponse(
        id: String,
        currentCredential: inout CodexOAuthCredential,
        codec: CodexTypedProtocol,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws -> Data {
        var skipped = 0
        while let data = try await iterator.next() {
            guard data.count <= 1_048_576,
                  let root = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { throw CodexCapabilityProtocolError.malformedJSON }
            if root["id"] as? String == id { return data }
            skipped += 1
            guard skipped <= 64 else {
                throw CodexCapabilityProtocolError.wrongResponse
            }
            if root["method"] as? String == "account/chatgptAuthTokens/refresh" {
                guard case .credentialRefresh(let refreshID, let previousAccountID)
                    = try codec.decode(data)
                else { throw CodexCapabilityProtocolError.wrongResponse }
                try await refreshCredential(
                    id: refreshID,
                    previousAccountID: previousAccountID,
                    currentCredential: &currentCredential
                )
                continue
            }
            if root["id"] != nil {
                throw CodexCapabilityProtocolError.wrongResponse
            }
        }
        throw CodexAppServerClientError.missingTerminal
    }

    private func awaitTypedResponse(
        matching expected: CodexTypedMessage,
        currentCredential: inout CodexOAuthCredential,
        codec: CodexTypedProtocol,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws {
        while let data = try await iterator.next() {
            let message = try codec.decode(data)
            if message == expected { return }
            if message == .ignored { continue }
            if case .credentialRefresh(let refreshID, let previousAccountID) = message {
                try await refreshCredential(
                    id: refreshID,
                    previousAccountID: previousAccountID,
                    currentCredential: &currentCredential
                )
                continue
            }
            if case .unsupportedApproval(let approvalID) = message {
                try process.send(try codec.declineUnsupportedApproval(id: approvalID))
                continue
            }
            if case .unsupportedPermissionsApproval(let approvalID) = message {
                try process.send(try codec.declineUnsupportedPermissionsApproval(
                    id: approvalID
                ))
                continue
            }
            if case .requestError = message {
                throw CodexTypedProtocolError.providerFailed
            }
            throw CodexTypedProtocolError.invalidSequence
        }
        throw CodexAppServerClientError.wrongResponse
    }

    private func awaitTypedThread(
        id: String,
        cwd: String,
        currentCredential: inout CodexOAuthCredential,
        codec: CodexTypedProtocol,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws -> String {
        var responseThreadID: String?
        var startedThreadID: String?
        while let data = try await iterator.next() {
            switch try codec.decode(data) {
            case .threadStartResponse(let responseID, let threadID, let authority)
                where responseID == id:
                guard responseThreadID == nil else {
                    throw CodexTypedProtocolError.invalidSequence
                }
                guard authority.cwd == cwd,
                      authority.runtimeWorkspaceRoots == [cwd]
                else { throw CodexTypedProtocolError.invalidField }
                responseThreadID = threadID
            case .threadStarted(let threadID):
                guard startedThreadID == nil else {
                    throw CodexTypedProtocolError.invalidSequence
                }
                startedThreadID = threadID
            case .ignored:
                continue
            case .requestError:
                throw CodexTypedProtocolError.providerFailed
            case .credentialRefresh(let refreshID, let previousAccountID):
                try await refreshCredential(
                    id: refreshID,
                    previousAccountID: previousAccountID,
                    currentCredential: &currentCredential
                )
            case .unsupportedApproval(let approvalID):
                try process.send(try codec.declineUnsupportedApproval(id: approvalID))
            case .unsupportedPermissionsApproval(let approvalID):
                try process.send(try codec.declineUnsupportedPermissionsApproval(
                    id: approvalID
                ))
            default:
                throw CodexTypedProtocolError.invalidSequence
            }
            if let responseThreadID, let startedThreadID {
                guard responseThreadID == startedThreadID else {
                    throw CodexTypedProtocolError.invalidSequence
                }
                return responseThreadID
            }
        }
        throw CodexAppServerClientError.wrongResponse
    }

    private func awaitTypedTurn(
        id: String,
        threadID: String,
        currentCredential: inout CodexOAuthCredential,
        codec: CodexTypedProtocol,
        iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator
    ) async throws -> String {
        var responseTurnID: String?
        var startedTurnID: String?
        while let data = try await iterator.next() {
            switch try codec.decode(data) {
            case .turnStartResponse(let responseID, let turnID) where responseID == id:
                guard responseTurnID == nil else {
                    throw CodexTypedProtocolError.invalidSequence
                }
                responseTurnID = turnID
            case .turnStarted(let startedThreadID, let turnID)
                where startedThreadID == threadID:
                guard startedTurnID == nil else {
                    throw CodexTypedProtocolError.invalidSequence
                }
                startedTurnID = turnID
            case .ignored, .threadStarted:
                continue
            case .requestError:
                throw CodexTypedProtocolError.providerFailed
            case .credentialRefresh(let refreshID, let previousAccountID):
                try await refreshCredential(
                    id: refreshID,
                    previousAccountID: previousAccountID,
                    currentCredential: &currentCredential
                )
            case .unsupportedApproval(let approvalID):
                try process.send(try codec.declineUnsupportedApproval(id: approvalID))
            case .unsupportedPermissionsApproval(let approvalID):
                try process.send(try codec.declineUnsupportedPermissionsApproval(
                    id: approvalID
                ))
            default:
                throw CodexTypedProtocolError.invalidSequence
            }
            if let responseTurnID, let startedTurnID {
                guard responseTurnID == startedTurnID else {
                    throw CodexTypedProtocolError.invalidSequence
                }
                return responseTurnID
            }
        }
        throw CodexAppServerClientError.wrongResponse
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
        if let portableSkillRoot {
            let typed = CodexTypedProtocol()
            let rootsID = "\(identity.requestID):skills-roots"
            try process.send(try typed.skillsExtraRootsSetRequest(
                id: rootsID, roots: [portableSkillRoot]
            ))
            try await awaitLiveSkillFeature(
                id: rootsID, helperThreadID: helperThreadID,
                credential: &currentCredential, codec: typed,
                notifications: &startupNotifications, iterator: &iterator
            )
            let listID = "\(identity.requestID):skills-list"
            try process.send(try typed.skillsListRequest(
                id: listID, cwd: process.temporaryRootURL.path
            ))
            try await awaitLiveSkillFeature(
                id: listID, helperThreadID: helperThreadID,
                credential: &currentCredential, codec: typed,
                notifications: &startupNotifications, iterator: &iterator
            )
        }
        try process.send(try codec.realtimeStartRequest(
            id: startID,
            threadID: helperThreadID,
            offerSDP: offerSDP,
            prompt: CodexRealtimePrompt.make(
                additionalInstructions: portableSkillInstructions
            )
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
        var approvalResponseIDs = Set<JSONRPCRequestID>()
        var approvalCalls = Set<ProviderApprovalCallAuthority>()
        while let data = try await iterator.next() {
            try Task.checkCancellation()
            let message = try codec.decode(data)
            switch message {
            case let .capabilityActivity(activity):
                guard activity.threadID == helperThreadID else {
                    throw CodexAppServerClientError.unexpectedMessage
                }
                await onCapabilityActivity(activity)
                continue
            case let .providerApproval(approval):
                guard approval.threadID == helperThreadID else {
                    throw CodexAppServerClientError.unexpectedMessage
                }
                guard approvalResponseIDs.insert(approval.responseID).inserted,
                      approvalCalls.insert(.init(approval)).inserted
                else { throw CodexAppServerClientError.unexpectedMessage }
                let decision = if let resolveProviderApprovalDetails {
                    await resolveProviderApprovalDetails(approval)
                } else {
                    await resolveProviderApproval(approval.request)
                }
                try Task.checkCancellation()
                try process.send(try CodexCapabilityProtocol().approvalResponse(
                    approval, decision: decision
                ))
                continue
            case .ignoredCapabilityActivity:
                continue
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

public struct CodexTypedReadiness: Equatable, Sendable {
    public static let minimumTestedRelease = "0.146.0"

    public let supportsOrdinaryTurns: Bool
    public let supportsApps: Bool
    public let supportsMCPStatus: Bool
    public let supportsSkills: Bool

    public var isReady: Bool {
        supportsOrdinaryTurns && supportsApps && supportsMCPStatus && supportsSkills
    }
}

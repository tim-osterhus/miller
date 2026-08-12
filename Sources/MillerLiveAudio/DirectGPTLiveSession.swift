import Foundation
import MillerLive

// Modified donor-derived behavior: OpenClaw PR #115226 at commit
// f78ba091207b33c3bb79f1bd9879d0e56be91a16 supplied the broker/session
// lifecycle and client-delegation seam. Miller adapts it to WebKitLivePeer,
// LiveSessionContract, one-session fencing, and non-persistent transcript state.

public final class GPTLiveCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }
}

public struct GPTLiveConsultationRequest: Sendable {
    public let prompt: String
    public let transcript: [GPTLiveTranscriptEntry]
    public let cancellation: GPTLiveCancellationToken

    public init(
        prompt: String,
        transcript: [GPTLiveTranscriptEntry],
        cancellation: GPTLiveCancellationToken
    ) {
        self.prompt = prompt
        self.transcript = transcript
        self.cancellation = cancellation
    }
}

public typealias GPTLiveConsultation = @Sendable (
    GPTLiveConsultationRequest
) async throws -> String

public actor DirectGPTLiveSession {
    private enum Input: Sendable {
        case frame(GPTLiveWebSocketMessage)
        case terminal(GPTLiveSidebandTerminal)
        case stop
    }

    private static let unsupportedDelegationText =
        "The agent consultation is unavailable. Tell the user it did not complete and offer to try again."

    private let peer: any LiveAudioPeer
    private let callCreator: GPTLiveCallCreator
    private let sidebandConnector: GPTLiveSidebandConnector
    private let configuration: GPTLiveConfiguration
    private let consultation: GPTLiveConsultation?
    private let consultationTimeout: Duration
    private let cleanupPendingDelay: Duration

    private var identity: LiveSessionIdentity?
    private var sideband: GPTLiveSidebandConnection?
    private var continuation: AsyncStream<Input>.Continuation?
    private var operationTask: Task<Void, Error>?
    private var consultTask: Task<Void, Never>?
    private var consultToken: GPTLiveCancellationToken?
    private var expiryTask: Task<Void, Never>?
    private var peerMonitor: Task<Void, Never>?
    private var peerClosed = false
    private var runGeneration: UInt64 = 0
    private var hasRun = false
    private var stopRequested = false
    private var terminalFailure: GPTLiveSessionError?
    private var transcript: [GPTLiveTranscriptEntry] = []
    private var partialRole: GPTLiveTranscriptRole?
    private var contract = LiveSessionContract()
    private var cleanupPendingHandler: (@Sendable () async -> Void)?
    private var cleanupPendingReported = false

    public init(
        peer: any LiveAudioPeer,
        callCreator: GPTLiveCallCreator = .init(),
        sidebandConnector: GPTLiveSidebandConnector = .init(),
        configuration: GPTLiveConfiguration = .default,
        consultation: GPTLiveConsultation? = nil,
        consultationTimeout: Duration = .seconds(30),
        cleanupPendingDelay: Duration = .seconds(2)
    ) {
        self.peer = peer
        self.callCreator = callCreator
        self.sidebandConnector = sidebandConnector
        self.configuration = configuration
        self.consultation = consultation
        self.consultationTimeout = consultationTimeout
        self.cleanupPendingDelay = cleanupPendingDelay
    }

    public func run(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        permission: MicrophonePermission,
        requestInitialResponse: Bool = false,
        onActive: @escaping @Sendable () async -> Void = {},
        onCleanupPending: @escaping @Sendable () async -> Void = {},
        receive: @escaping @Sendable (LiveSessionEvent) async -> Void
    ) async throws {
        guard permission == .authorized else { throw LiveAudioError.permissionDenied }
        guard self.identity == nil, !hasRun else {
            throw GPTLiveSessionError.sessionAlreadyActive
        }
        hasRun = true
        runGeneration &+= 1
        let generation = runGeneration
        self.identity = identity
        stopRequested = false
        terminalFailure = nil
        peerClosed = false
        transcript.removeAll()
        partialRole = nil
        contract = LiveSessionContract()
        cleanupPendingHandler = onCleanupPending
        cleanupPendingReported = false
        try contract.begin(identity)

        let stream = AsyncStream<Input>(bufferingPolicy: .bufferingOldest(64)) { continuation in
            self.continuation = continuation
        }
        defer {
            continuation = nil
            expiryTask?.cancel()
            expiryTask = nil
            peerMonitor?.cancel()
            peerMonitor = nil
            consultTask?.cancel()
            consultTask = nil
            consultToken?.cancel()
            consultToken = nil
            operationTask = nil
            sideband = nil
            self.identity = nil
            cleanupPendingHandler = nil
            terminalFailure = nil
        }

        let operation = Task { [weak self] in
            guard let self else { return }
            try await self.startAndConsume(
                identity: identity,
                credential: credential,
                generation: generation,
                stream: stream,
                requestInitialResponse: requestInitialResponse,
                onActive: onActive,
                receive: receive
            )
        }
        operationTask = operation
        do {
            try await withTaskCancellationHandler(operation: {
                try await operation.value
            }, onCancel: { [weak self] in
                operation.cancel()
                Task { await self?.cancelFromTask(generation: generation) }
            })
        } catch is CancellationError {
            await cleanup()
            if let terminalFailure { throw terminalFailure }
            if stopRequested { return }
            throw CancellationError()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    public func setMuted(_ muted: Bool) async {
        guard self.identity != nil, !peerClosed else { return }
        do {
            try await peer.setMuted(muted)
        } catch {
            await failSession(generation: runGeneration)
        }
    }

    public func interrupt() async {
        await stop()
    }

    public func end() async {
        await stop()
    }

    private func startAndConsume(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        generation: UInt64,
        stream: AsyncStream<Input>,
        requestInitialResponse: Bool,
        onActive: @escaping @Sendable () async -> Void,
        receive: @escaping @Sendable (LiveSessionEvent) async -> Void
    ) async throws {
        let offer = try await peer.prepareOffer()
        try Task.checkCancellation()
        guard !stopRequested else { return }

        let auth = GPTLiveAuth.oauth(
            accessToken: credential.accessToken,
            accountID: credential.accountID
        )
        let requestIDs = GPTLiveRequestIDs(
            realtimeSessionID: "\(identity.requestID)-realtime",
            sessionID: identity.requestID,
            threadID: identity.threadID
        )
        let call: GPTLiveCallResponse
        do {
            call = try await callCreator.create(
                offerSDP: offer,
                configuration: configuration,
                auth: auth,
                requestIDs: requestIDs
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
        guard !stopRequested else { return }

        let connected: GPTLiveSidebandConnection
        do {
            connected = try await sidebandConnector.connect(
                url: call.sidebandURL,
                auth: auth,
                requestIDs: requestIDs
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GPTLiveSessionError.sidebandStartup
        }
        sideband = connected
        guard !stopRequested else { return }

        let inputContinuation = continuation
        let terminal = connected.attach(
            onFrame: { [weak self] message in
                let result = inputContinuation?.yield(.frame(message))
                if case .dropped = result {
                    Task { await self?.enqueue(.terminal(.protocolViolation), generation: generation) }
                }
            },
            onTerminal: { [weak self] terminal in
                inputContinuation?.yield(.terminal(terminal))
                Task {
                    await self?.handleSidebandTerminal(terminal, generation: generation)
                }
            }
        )
        guard terminal == nil else { throw GPTLiveSessionError.sidebandStartup }
        try await peer.applyAnswerAndWaitForConnected(call.answerSDP)
        if let terminalFailure { throw terminalFailure }
        guard !stopRequested else { return }
        guard connected.terminal == nil else { throw GPTLiveSessionError.sidebandStartup }
        beginPeerMonitor(generation: generation)
        if let terminalFailure { throw terminalFailure }
        if requestInitialResponse {
            try Task.checkCancellation()
            guard !stopRequested else { return }
            try await requestResponse(generation: generation)
            if let terminalFailure { throw terminalFailure }
            guard !stopRequested else { return }
        }
        try contract.accept(.started(threadID: identity.threadID), generation: identity.generation)
        await receive(.started(threadID: identity.threadID))
        await onActive()

        for await input in stream {
            try Task.checkCancellation()
            switch input {
            case let .frame(message):
                if try await handleFrame(
                    message,
                    identity: identity,
                    generation: generation,
                    receive: receive
                ) { return }
            case let .terminal(terminal):
                try await handleTerminal(
                    terminal,
                    identity: identity,
                    receive: receive
                )
                return
            case .stop:
                return
            }
        }
    }

    private func handleFrame(
        _ message: GPTLiveWebSocketMessage,
        identity: LiveSessionIdentity,
        generation: UInt64,
        receive: @escaping @Sendable (LiveSessionEvent) async -> Void
    ) async throws -> Bool {
        guard self.identity?.generation == identity.generation,
              runGeneration == generation,
              !stopRequested
        else { return false }
        guard case let .text(text) = message else {
            throw GPTLiveSessionError.protocolFailure
        }
        guard let event = GPTLiveEventParser.parse(text) else { return false }
        switch event {
        case let .sessionStarted(expiresAt):
            scheduleExpiry(expiresAt: expiresAt, generation: generation)
            return false
        case .sessionExpired:
            try await handleTerminal(
                .closed,
                identity: identity,
                receive: receive,
                expired: true
            )
            return true
        case .sessionClosed:
            try contract.accept(
                .closed(threadID: identity.threadID, reason: "provider_closed"),
                generation: identity.generation
            )
            await receive(.closed(threadID: identity.threadID, reason: "provider_closed"))
            return true
        case let .transcriptDelta(role, text):
            appendTranscript(role: role, text: text, done: false)
            try contract.accept(
                .transcriptDelta(threadID: identity.threadID, role: role.rawValue, delta: text),
                generation: identity.generation
            )
            await receive(.transcriptDelta(
                threadID: identity.threadID,
                role: role.rawValue,
                delta: text
            ))
            return false
        case let .transcriptDone(role, text):
            appendTranscript(role: role, text: text, done: true)
            try contract.accept(
                .transcriptDone(threadID: identity.threadID, role: role.rawValue, text: text),
                generation: identity.generation
            )
            await receive(.transcriptDone(
                threadID: identity.threadID,
                role: role.rawValue,
                text: text
            ))
            return false
        case let .delegation(id, prompt):
            await startConsultation(id: id, prompt: prompt)
            return false
        case let .error(fatalAuth):
            guard fatalAuth else { return false }
            try await handleTerminal(
                .error,
                identity: identity,
                receive: receive
            )
            return true
        case .unknown:
            return false
        }
    }

    private func handleTerminal(
        _ terminal: GPTLiveSidebandTerminal,
        identity: LiveSessionIdentity,
        receive: @escaping @Sendable (LiveSessionEvent) async -> Void,
        expired: Bool = false
    ) async throws {
        guard !stopRequested else { return }
        if expired {
            try contract.accept(
                .failed(threadID: identity.threadID, message: "live_expired"),
                generation: identity.generation
            )
            await receive(.failed(threadID: identity.threadID, message: "live_expired"))
            throw GPTLiveSessionError.expired
        }
        switch terminal {
        case .closed:
            try contract.accept(
                .failed(threadID: identity.threadID, message: "live_sideband_closed"),
                generation: identity.generation
            )
            await receive(.failed(threadID: identity.threadID, message: "live_sideband_closed"))
            throw GPTLiveSessionError.sidebandClosed
        case .error, .protocolViolation:
            try contract.accept(
                .failed(threadID: identity.threadID, message: "live_sideband_failed"),
                generation: identity.generation
            )
            await receive(.failed(threadID: identity.threadID, message: "live_sideband_failed"))
            throw GPTLiveSessionError.protocolFailure
        }
    }

    private func appendTranscript(
        role: GPTLiveTranscriptRole,
        text: String,
        done: Bool
    ) {
        if let index = transcript.indices.last,
           transcript[index].role == role,
           partialRole == role {
            transcript[index] = GPTLiveTranscriptEntry(
                role: role,
                text: done ? text : transcript[index].text + text
            )
        } else {
            transcript.append(GPTLiveTranscriptEntry(role: role, text: text))
        }
        partialRole = done ? nil : role
        boundTranscript()
    }

    private func boundTranscript() {
        while transcript.count > 16 { transcript.removeFirst() }
        var bytes = 0
        var retained: [GPTLiveTranscriptEntry] = []
        for entry in transcript.reversed() {
            let entryBytes = entry.text.utf8.count + entry.role.rawValue.utf8.count
            guard bytes + entryBytes <= 8_000 else { continue }
            retained.append(entry)
            bytes += entryBytes
        }
        transcript = retained.reversed()
    }

    private func startConsultation(id: String, prompt: String) async {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let context = transcript
        transcript.removeAll()
        partialRole = nil
        consultTask?.cancel()
        consultToken?.cancel()
        let token = GPTLiveCancellationToken()
        consultToken = token
        let consultation = self.consultation
        let timeout = consultationTimeout
        let request = GPTLiveConsultationRequest(
            prompt: consultationPrompt(input: prompt, transcript: context),
            transcript: context,
            cancellation: token
        )
        consultTask = Task { [weak self] in
            let text: String
            do {
                if let consultation {
                    text = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask { try await consultation(request) }
                        group.addTask {
                            try await Task.sleep(for: timeout)
                            throw GPTLiveConsultationFailure.timeout
                        }
                        guard let first = try await group.next() else {
                            throw GPTLiveConsultationFailure.timeout
                        }
                        group.cancelAll()
                        return first
                    }
                } else {
                    text = Self.unsupportedDelegationText
                }
            } catch {
                text = Self.unsupportedDelegationText
            }
            guard !Task.isCancelled, !token.isCancelled else { return }
            await self?.sendDelegationResult(
                id: id,
                text: Self.boundUTF8(text, maximumBytes: 8_000),
                token: token
            )
        }
    }

    private func sendDelegationResult(
        id: String,
        text: String,
        token: GPTLiveCancellationToken
    ) async {
        guard !token.isCancelled, !stopRequested, let sideband else { return }
        for chunk in GPTLiveEventParser.chunkSpeakableText(text) {
            guard !token.isCancelled, !stopRequested else { return }
            let body: [String: Any] = [
                "type": "delegation.context.append",
                "delegation_item_id": id,
                "channel": "speakable",
                "content": [["type": "input_text", "text": chunk]],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: body),
                  let payload = String(data: data, encoding: .utf8)
            else { return }
            try? await sideband.send(payload)
        }
    }

    private func consultationPrompt(
        input: String,
        transcript: [GPTLiveTranscriptEntry]
    ) -> String {
        let boundedInput = Self.boundUTF8(input, maximumBytes: 4_000)
        var result = "<realtime_delegation>\n  <input>\(Self.escapeXML(boundedInput))</input>"
        if !transcript.isEmpty {
            let context = transcript
                .map { "\($0.role.rawValue): \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .filter { !$0.hasSuffix(": ") }
                .joined(separator: "\n")
            result += "\n  <transcript_delta>\(Self.escapeXML(Self.boundUTF8(context, maximumBytes: 4_000)))</transcript_delta>"
        }
        result += "\n</realtime_delegation>"
        return result
    }

    private func scheduleExpiry(expiresAt: Int64?, generation: UInt64) {
        guard let expiresAt else { return }
        let remaining = min(
            1_800,
            max(0, Double(expiresAt) - Date().timeIntervalSince1970)
        )
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int64(remaining * 1_000)))
                await self?.enqueue(.terminal(.closed), generation: generation)
            } catch {}
        }
    }

    private func enqueue(_ input: Input, generation: UInt64) {
        guard runGeneration == generation, identity != nil, !stopRequested else { return }
        continuation?.yield(input)
    }

    private func stop() async {
        stopRequested = true
        operationTask?.cancel()
        consultTask?.cancel()
        consultTask = nil
        consultToken?.cancel()
        continuation?.yield(.stop)
        await cleanup()
    }

    private func cancelFromTask(generation: UInt64) async {
        guard runGeneration == generation else { return }
        stopRequested = true
        operationTask?.cancel()
        continuation?.yield(.stop)
        await cleanup()
    }

    private func failSession(generation: UInt64) async {
        guard runGeneration == generation, !stopRequested else { return }
        continuation?.yield(.terminal(.error))
    }

    private func handleSidebandTerminal(
        _ terminal: GPTLiveSidebandTerminal,
        generation: UInt64
    ) async {
        guard runGeneration == generation,
              identity != nil,
              !stopRequested,
              terminalFailure == nil else { return }
        switch terminal {
        case .closed:
            terminalFailure = .sidebandClosed
        case .error, .protocolViolation:
            terminalFailure = .protocolFailure
        }
        operationTask?.cancel()
        await cleanup()
    }

    private func beginPeerMonitor(generation: UInt64) {
        guard let monitor = peer as? any LiveAudioPeerConnectionMonitoring else { return }
        peerMonitor?.cancel()
        peerMonitor = Task { [weak self, monitor] in
            do {
                try await monitor.waitForConnectionFailure()
                await self?.handlePeerConnectionFailure(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                await self?.handlePeerConnectionFailure(generation: generation)
            }
        }
    }

    private func handlePeerConnectionFailure(generation: UInt64) async {
        guard runGeneration == generation,
              identity != nil,
              !stopRequested,
              terminalFailure == nil else { return }
        terminalFailure = .protocolFailure
        operationTask?.cancel()
        await cleanup()
    }

    private func cleanup() async {
        peerMonitor?.cancel()
        peerMonitor = nil
        expiryTask?.cancel()
        expiryTask = nil
        consultTask?.cancel()
        consultTask = nil
        consultToken?.cancel()
        consultToken = nil
        if let sideband {
            await sideband.close()
            self.sideband = nil
        }
        await cancelResponseRequest(generation: runGeneration)
        guard !peerClosed else { return }
        peerClosed = true
        let pendingDelay = cleanupPendingDelay
        let pendingHandler = cleanupPendingHandler
        let closeTask = Task { @MainActor [peer] in await peer.close() }
        let pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: pendingDelay)
                await self.reportCleanupPending(pendingHandler)
            } catch {}
        }
        await closeTask.value
        pendingTask.cancel()
    }

    private func requestResponse(generation: UInt64) async throws {
        if let fencedPeer = peer as? any LiveAudioPeerResponseFencing {
            try await fencedPeer.requestResponse(for: generation)
        } else {
            try await peer.requestResponse()
        }
    }

    private func cancelResponseRequest(generation: UInt64) async {
        guard let fencedPeer = peer as? any LiveAudioPeerResponseFencing else { return }
        await fencedPeer.cancelResponseRequest(for: generation)
    }

    private func reportCleanupPending(
        _ handler: (@Sendable () async -> Void)?
    ) async {
        guard !cleanupPendingReported, let handler else { return }
        cleanupPendingReported = true
        await handler()
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func boundUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= maximumBytes else { break }
            result.append(character)
            bytes += count
        }
        return result
    }
}

private enum GPTLiveConsultationFailure: Error {
    case timeout
}

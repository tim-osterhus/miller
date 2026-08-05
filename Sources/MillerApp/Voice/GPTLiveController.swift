import Foundation
import MillerCore
import MillerLive
import MillerLiveAudio

enum LiveVoiceState: String, Equatable, Sendable {
    case available
    case connecting
    case listening
    case responding
    case speaking
    case stopped
    case closed
    case unavailable
    case failed

    var isActive: Bool {
        switch self {
        case .connecting, .listening, .responding, .speaking: true
        default: false
        }
    }
}

enum LiveTranscriptRole: Equatable, Sendable {
    case user
    case assistant
}

enum LiveVoiceEvent: Equatable, Sendable {
    case sessionAdmitted(id: UUID)
    case state(LiveVoiceState)
    case transcriptDelta(role: LiveTranscriptRole, text: String)
    case transcriptDone(role: LiveTranscriptRole, text: String)
    case failed(code: String)
}

struct LiveVoiceDependencies: Sendable {
    let initialAvailability: LiveVoiceState
    let availability: @Sendable () async -> LiveVoiceState
    let start: @Sendable (
        @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async throws -> Void
    let mute: @Sendable (Bool) async -> Void
    let interrupt: @Sendable () async -> Void
    let end: @Sendable () async -> Void

    static let unavailable = Self(
        initialAvailability: .unavailable,
        availability: { .unavailable },
        start: { _ in throw GPTLiveCredentialError.unavailable },
        mute: { _ in },
        interrupt: {},
        end: {}
    )
}

actor GPTLiveController {
    private let helperURL: URL?
    private let temporaryParentURL: URL
    private let selectedProfile: @Sendable () async throws -> ProviderProfile?
    private let credentialLoader: GPTLiveCredentialLoader
    private let credentialInvalidated: @Sendable (UUID) async throws -> Bool
    private let refreshCredential: @Sendable () async throws -> Void
    private let microphonePermissionStatus: @Sendable () -> MicrophonePermission
    private let microphonePermission: @Sendable () async -> MicrophonePermission
    private let credentialRefreshTimeout: Duration
    private let cleanupPendingDelay: Duration
    private let makeSession: @Sendable (CodexAppServerClient) -> LiveAudioSession
    private let makePeer: (@Sendable () async throws -> any LiveAudioPeer)?
    private let makeDirectSession: (@Sendable (any LiveAudioPeer) -> DirectGPTLiveSession)?
    private let releasePeer: @Sendable () async -> Void
    private let helperVerifier: @Sendable (URL) throws -> Void
    private let spawnedProcessVerifier: @Sendable (pid_t) throws -> Void
    private var session: LiveAudioSession?
    private var directSession: DirectGPTLiveSession?
    private var startInProgress = false
    private var stopRequested = false
    private var clientSessionBecameActive = false
    private var terminalFailurePresented = false
    private var hasAttachedPeer = false
    private var credentialRefreshRace: GPTLiveCredentialRefreshRace?
    private var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        helperURL: URL?,
        temporaryParentURL: URL,
        selectedProfile: @escaping @Sendable () async throws -> ProviderProfile?,
        credentialLoader: GPTLiveCredentialLoader,
        credentialInvalidated: @escaping @Sendable (UUID) async throws -> Bool = {
            _ in false
        },
        refreshCredential: @escaping @Sendable () async throws -> Void,
        microphonePermissionStatus: @escaping @Sendable () -> MicrophonePermission = {
            SystemMicrophonePermission.current()
        },
        microphonePermission: @escaping @Sendable () async -> MicrophonePermission = {
            var permission = SystemMicrophonePermission.current()
            if permission == .notDetermined {
                permission = await SystemMicrophonePermission.request()
            }
            return permission
        },
        credentialRefreshTimeout: Duration = .seconds(15),
        cleanupPendingDelay: Duration = .seconds(2),
        makeSession: @escaping @Sendable (CodexAppServerClient) -> LiveAudioSession = {
            LiveAudioSession(client: $0)
        },
        makePeer: (@Sendable () async throws -> any LiveAudioPeer)? = nil,
        makeDirectSession: (@Sendable (any LiveAudioPeer) -> DirectGPTLiveSession)? = nil,
        releasePeer: @escaping @Sendable () async -> Void = {},
        helperVerifier: @escaping @Sendable (URL) throws -> Void = {
            try CodexAppServerHelperVerifier().verify($0)
        },
        spawnedProcessVerifier: @escaping @Sendable (pid_t) throws -> Void = {
            try CodexAppServerHelperVerifier().verifyRunningProcess(pid: $0)
        }
    ) throws {
        if let helperURL {
            guard helperURL.isFileURL, helperURL.path.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: helperURL.path)
            else { throw GPTLiveCredentialError.unavailable }
            try helperVerifier(helperURL)
        } else {
            guard makeDirectSession != nil, makePeer != nil else {
                throw GPTLiveCredentialError.unavailable
            }
        }
        self.helperURL = helperURL
        self.temporaryParentURL = temporaryParentURL
        self.selectedProfile = selectedProfile
        self.credentialLoader = credentialLoader
        self.credentialInvalidated = credentialInvalidated
        self.refreshCredential = refreshCredential
        self.microphonePermissionStatus = microphonePermissionStatus
        self.microphonePermission = microphonePermission
        self.credentialRefreshTimeout = credentialRefreshTimeout
        self.cleanupPendingDelay = cleanupPendingDelay
        self.makeSession = makeSession
        self.makePeer = makePeer
        self.makeDirectSession = makeDirectSession
        self.releasePeer = releasePeer
        self.helperVerifier = helperVerifier
        self.spawnedProcessVerifier = spawnedProcessVerifier
    }

    nonisolated static func processConfiguration(
        helperURL: URL,
        temporaryParentURL: URL,
        cleanupPendingDelay: Duration = .seconds(2),
        spawnedProcessVerifier: @escaping @Sendable (pid_t) throws -> Void = {
            try CodexAppServerHelperVerifier().verifyRunningProcess(pid: $0)
        }
    ) throws -> CodexAppServerProcess.Configuration {
        try .init(
            executableURL: helperURL,
            arguments: ["app-server", "--listen", "stdio://", "--strict-config"],
            temporaryParentURL: temporaryParentURL,
            cleanupPendingDelay: cleanupPendingDelay,
            spawnedProcessVerifier: spawnedProcessVerifier
        )
    }

    nonisolated func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .unavailable,
            availability: { [self] in await availability() },
            start: { [self] receive in try await start(receive: receive) },
            mute: { [self] muted in
                if let directSession = await directSession {
                    await directSession.setMuted(muted)
                } else {
                    await session?.setMuted(muted)
                }
            },
            interrupt: { [self] in await stop(interrupting: true) },
            end: { [self] in await stop(interrupting: false) }
        )
    }

    func availability() async -> LiveVoiceState {
        guard session == nil else { return .unavailable }
        guard directSession == nil else { return .unavailable }
        if let helperURL, makeDirectSession == nil {
            guard (try? helperVerifier(helperURL)) != nil else { return .unavailable }
        } else if makeDirectSession == nil {
            return .unavailable
        }
        let permission = microphonePermissionStatus()
        guard permission == .authorized || permission == .notDetermined,
              let profile = try? await selectedProfile(),
              profile.kind == .codexOAuth,
              profile.isSelected,
              (try? await credentialInvalidated(profile.credentialReference)) == false
        else { return .unavailable }
        if makeDirectSession == nil {
            guard (try? await credentialLoader.load(profile: profile)) != nil else {
                return .unavailable
            }
        }
        guard let confirmedProfile = try? await selectedProfile() else {
            return .unavailable
        }
        guard Self.sameCredentialAuthority(profile, confirmedProfile),
              (try? await credentialInvalidated(confirmedProfile.credentialReference)) == false
        else { return .unavailable }
        return .available
    }

    func start(
        receive: @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async throws {
        guard session == nil, !startInProgress else {
            throw GPTLiveCredentialError.unavailable
        }
        if let helperURL, makeDirectSession == nil {
            try helperVerifier(helperURL)
        } else if makeDirectSession == nil || makePeer == nil {
            throw GPTLiveCredentialError.unavailable
        }
        startInProgress = true
        stopRequested = false
        clientSessionBecameActive = false
        terminalFailurePresented = false
        defer { finishStart() }
        guard let profile = try await selectedProfile() else {
            throw GPTLiveCredentialError.unavailable
        }
        guard !stopRequested else { return }
        guard try await credentialInvalidated(profile.credentialReference) == false else {
            throw GPTLiveCredentialError.unavailable
        }
        let permission = await microphonePermission()
        guard !stopRequested else { return }
        guard permission == .authorized else { throw LiveAudioError.permissionDenied }
        do {
            try await refreshCredentialForAdmission()
        } catch is CancellationError {
            if stopRequested { return }
            throw CancellationError()
        }
        guard !stopRequested else { return }
        guard let refreshedProfile = try await selectedProfile(),
              Self.sameCredentialAuthority(profile, refreshedProfile),
              try await credentialInvalidated(
                  refreshedProfile.credentialReference
              ) == false
        else { throw GPTLiveCredentialError.unavailable }
        let credential = try await credentialLoader.load(profile: refreshedProfile)
        guard !stopRequested else { return }
        guard let confirmedProfile = try await selectedProfile(),
              Self.sameCredentialAuthority(refreshedProfile, confirmedProfile),
              try await credentialInvalidated(
                  confirmedProfile.credentialReference
              ) == false
        else { throw GPTLiveCredentialError.unavailable }
        let peer = try await makePeer?()
        hasAttachedPeer = peer != nil
        let admittedReference = refreshedProfile.credentialReference
        if let makeDirectSession {
            guard let peer else {
                throw GPTLiveCredentialError.unavailable
            }
            directSession = makeDirectSession(peer)
            session = nil
        } else {
            guard let helperURL else {
                throw GPTLiveCredentialError.unavailable
            }
            let process = CodexAppServerProcess(configuration: try Self.processConfiguration(
                helperURL: helperURL,
                temporaryParentURL: temporaryParentURL,
                cleanupPendingDelay: cleanupPendingDelay,
                spawnedProcessVerifier: spawnedProcessVerifier
            ))
            let client = CodexAppServerClient(
                process: process,
                refreshProvider: {
                    [selectedProfile, credentialLoader, credentialInvalidated, refreshCredential]
                    accountID in
                    try await refreshCredential()
                    guard let refreshedProfile = try await selectedProfile(),
                          refreshedProfile.credentialReference == admittedReference,
                          try await credentialInvalidated(
                              refreshedProfile.credentialReference
                          ) == false
                    else { throw GPTLiveCredentialError.accountMismatch }
                    let replacement = try await credentialLoader.load(profile: refreshedProfile)
                    guard let confirmedProfile = try await selectedProfile(),
                          Self.sameCredentialAuthority(
                              refreshedProfile,
                              confirmedProfile
                          ),
                          confirmedProfile.credentialReference == admittedReference,
                          try await credentialInvalidated(
                              confirmedProfile.credentialReference
                          ) == false,
                          replacement.accountID == accountID
                    else {
                        throw GPTLiveCredentialError.accountMismatch
                    }
                    return replacement
                }
            )
            session = peer.map { LiveAudioSession(client: client, peer: $0) }
                ?? makeSession(client)
            directSession = nil
        }
        guard !stopRequested else {
            if let peer {
                await peer.close()
                await releaseAttachedPeerIfNeeded()
            }
            return
        }
        let sessionID = UUID()
        let identity = LiveSessionIdentity(
            requestID: sessionID.uuidString.lowercased(),
            threadID: UUID().uuidString.lowercased(),
            generation: 1
        )
        await receive(.state(.connecting))
        guard !stopRequested else {
            if let peer {
                await peer.close()
                await releaseAttachedPeerIfNeeded()
            }
            return
        }
        do {
            if let directSession {
                try await directSession.run(
                    identity: identity,
                    credential: credential,
                    permission: permission,
                    onActive: {
                        await self.markClientSessionActive()
                        await receive(.sessionAdmitted(id: sessionID))
                    },
                    onCleanupPending: {
                        await self.markTerminalFailurePresented()
                        await receive(.failed(code: "cleanup_pending"))
                    },
                    receive: { event in
                        if case .failed = event {
                            await self.markTerminalFailurePresented()
                        }
                        await Self.present(event, receive: receive)
                    }
                )
            } else if let session {
                try await session.run(
                    identity: identity,
                    credential: credential,
                    permission: permission,
                    onActive: {
                        await self.markClientSessionActive()
                        await receive(.sessionAdmitted(id: sessionID))
                    },
                    onCleanupPending: {
                        await self.markTerminalFailurePresented()
                        await receive(.failed(code: "cleanup_pending"))
                    }
                ) { event in
                    if case .failed = event {
                        await self.markTerminalFailurePresented()
                    }
                    await Self.present(event, receive: receive)
                }
            }
            await releaseAttachedPeerIfNeeded()
        } catch {
            await releaseAttachedPeerIfNeeded()
            guard !stopRequested || clientSessionBecameActive else { return }
            if !terminalFailurePresented {
                await receive(.failed(code: Self.failureCode(error)))
            }
            throw error
        }
    }

    func shutdown() async {
        await stop(interrupting: false)
        await releaseAttachedPeerIfNeeded()
    }

    private func stop(interrupting: Bool) async {
        stopRequested = true
        credentialRefreshRace?.cancel()
        if let directSession {
            if interrupting { await directSession.interrupt() }
            else { await directSession.end() }
        } else if interrupting {
            await session?.interrupt()
        } else {
            await session?.end()
        }
        await waitForStartCompletion()
    }

    private func refreshCredentialForAdmission() async throws {
        let race = GPTLiveCredentialRefreshRace()
        credentialRefreshRace = race
        defer {
            if credentialRefreshRace === race {
                credentialRefreshRace = nil
            }
        }
        try await race.run(timeout: credentialRefreshTimeout, operation: refreshCredential)
    }

    private func waitForStartCompletion() async {
        guard startInProgress else { return }
        await withCheckedContinuation { continuation in
            guard startInProgress else {
                continuation.resume()
                return
            }
            startCompletionWaiters.append(continuation)
        }
    }

    private func finishStart() {
        session = nil
        directSession = nil
        startInProgress = false
        stopRequested = false
        clientSessionBecameActive = false
        terminalFailurePresented = false
        let waiters = startCompletionWaiters
        startCompletionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func releaseAttachedPeerIfNeeded() async {
        guard hasAttachedPeer else { return }
        hasAttachedPeer = false
        await releasePeer()
    }

    nonisolated private static func sameCredentialAuthority(
        _ admitted: ProviderProfile,
        _ current: ProviderProfile
    ) -> Bool {
        admitted.id == current.id
            && admitted.kind == .codexOAuth
            && current.kind == admitted.kind
            && current.credentialReference == admitted.credentialReference
            && current.isSelected
    }

    private static func present(
        _ event: LiveSessionEvent,
        receive: @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async {
        switch event {
        case .started:
            await receive(.state(.listening))
        case let .transcriptDelta(_, role, text):
            await receive(.state(.responding))
            await receive(.transcriptDelta(role: role == "user" ? .user : .assistant, text: text))
        case let .transcriptDone(_, role, text):
            await receive(.transcriptDone(role: role == "user" ? .user : .assistant, text: text))
        case .outputAudio:
            await receive(.state(.speaking))
        case .closed:
            await receive(.state(.closed))
        case let .failed(_, message):
            await receive(.failed(code: Self.directFailureCode(message)))
        case .sdp:
            await receive(.failed(code: "voice_failed"))
        }
    }

    private func markClientSessionActive() { clientSessionBecameActive = true }

    private func markTerminalFailurePresented() { terminalFailurePresented = true }

    private static func failureCode(_ error: Error) -> String {
        if let audio = error as? LiveAudioError {
            switch audio {
            case .audioBackpressure: return "audio_backpressure"
            case .captureFailed: return "capture_failed"
            case .microphoneUnavailable: return "device_unavailable"
            case .permissionDenied: return "microphone_denied"
            case .playbackFailed: return "playback_failed"
            default: return "voice_failed"
            }
        }
        if let client = error as? CodexAppServerClientError {
            switch client {
            case .audioBackpressure: return "audio_backpressure"
            case .credentialRejected, .refreshUnavailable: return "credential_rejected"
            case .initializeProtocolMismatch: return "protocol_initialize_mismatch"
            case .loginProtocolMismatch: return "protocol_login_mismatch"
            case let .loginFrameProtocolMismatch(kind, reason):
                return Self.loginFrameFailureCode(kind, reason)
            case .loginSequenceProtocolMismatch: return "protocol_login_sequence_mismatch"
            case .missingTerminal, .unexpectedMessage, .wrongResponse:
                return "protocol_mismatch"
            case .realtimeStartProtocolMismatch: return "protocol_realtime_mismatch"
            case let .realtimeStartDiagnostic(diagnostic): return diagnostic.rawValue
            case .sessionFailed: return "provider_failed"
            case .sessionAlreadyActive: return "voice_unavailable"
            case .threadStartProtocolMismatch: return "protocol_thread_mismatch"
            case .timeout: return "voice_timeout"
            }
        }
        if let process = error as? LiveProcessError {
            switch process {
            case .invalidFrame: return "protocol_mismatch"
            case .timeout: return "voice_timeout"
            case .helperExited, .invalidConfiguration, .processUnavailable:
                return "helper_failed"
            }
        }
        if error is LiveProtocolError { return "protocol_mismatch" }
        if let wire = error as? GPTLiveWireError {
            switch wire {
            case .oauthRequired, .invalidCredential, .unauthorized:
                return "credential_rejected"
            case .badRequest: return "live_bad_request"
            case .forbidden: return "live_forbidden"
            case .serverFailure: return "live_server_failure"
            case .unexpectedStatus, .networkFailure, .invalidProviderEndpoint:
                return "live_network_failure"
            case .invalidRequestID: return "protocol_mismatch"
            case .invalidSDPOffer, .invalidSDPAnswer, .oversizedSDPAnswer:
                return "live_invalid_sdp"
            case .missingCallID, .invalidCallID: return "live_invalid_call_id"
            }
        }
        if let live = error as? GPTLiveSessionError {
            switch live {
            case .sessionAlreadyActive: return "voice_unavailable"
            case .sidebandStartup: return "live_sideband_startup"
            case .sidebandClosed: return "live_sideband_closed"
            case .expired: return "live_expired"
            case .protocolFailure: return "protocol_mismatch"
            }
        }
        return "voice_failed"
    }

    private static func directFailureCode(_ value: String) -> String {
        switch value {
        case "live_expired", "live_sideband_closed", "live_sideband_failed":
            return value
        default:
            return "provider_failed"
        }
    }

    private static func loginFrameFailureCode(
        _ kind: CodexLoginFrameKind,
        _ reason: LiveProtocolError?
    ) -> String {
        let prefix: String
        switch kind {
        case .response: prefix = "protocol_login_response"
        case .responseRoot: prefix = "protocol_login_response_root"
        case .responseResult: prefix = "protocol_login_response_result"
        case .loginCompleted: prefix = "protocol_login_completed"
        case .accountUpdated: prefix = "protocol_login_updated"
        case .credentialRefresh: prefix = "protocol_login_refresh"
        case .accountOther: prefix = "protocol_login_account_other"
        case .thread: prefix = "protocol_login_thread"
        case .methodOther: prefix = "protocol_login_method_other"
        case .other: prefix = "protocol_login_frame"
        }
        switch reason {
        case .unknownMethod: return "\(prefix)_unknown_method"
        case .unknownField: return "\(prefix)_unknown_field"
        case .missingField: return "\(prefix)_missing_field"
        case .invalidField: return "\(prefix)_invalid_field"
        default: return "\(prefix)_mismatch"
        }
    }
}

private final class GPTLiveCredentialRefreshRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var resolved = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            let operationTask = Task { [weak self] in
                do {
                    try await operation()
                    self?.resolve(.success(()))
                } catch {
                    self?.resolve(.failure(error))
                }
            }
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                    self?.resolve(.failure(LiveProcessError.timeout))
                } catch {}
            }
            lock.withLock {
                self.operationTask = operationTask
                self.timeoutTask = timeoutTask
                if resolved {
                    operationTask.cancel()
                    timeoutTask.cancel()
                }
            }
        }
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Void, Error>) {
        let pending: (
            CheckedContinuation<Void, Error>?,
            Task<Void, Never>?,
            Task<Void, Never>?
        ) = lock.withLock {
            guard !resolved else { return (nil, nil, nil) }
            resolved = true
            let pending = (continuation, operationTask, timeoutTask)
            continuation = nil
            operationTask = nil
            timeoutTask = nil
            return pending
        }
        pending.1?.cancel()
        pending.2?.cancel()
        pending.0?.resume(with: result)
    }
}

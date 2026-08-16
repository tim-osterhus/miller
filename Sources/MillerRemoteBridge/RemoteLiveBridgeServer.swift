import Foundation
import Darwin
import MillerLiveAudio

public enum RemoteLiveBridgeHostError: Error, Equatable, Sendable {
    case busy
    case unavailable
    case providerUnavailable
    case timeout
    case notFound
    case conflict
    case invalidRequest
}

public struct MillerRemoteBridgeHost: Sendable {
    public let start: @Sendable (UUID, String) async throws -> String
    public let connected: @Sendable (UUID) async throws -> Void
    public let activity: @Sendable (UUID) async throws -> Void
    public let interrupt: @Sendable (UUID) async throws -> Void
    public let end: @Sendable (UUID, RemoteLiveTerminalReason) async throws -> Void

    public init(
        start: @escaping @Sendable (UUID, String) async throws -> String,
        connected: @escaping @Sendable (UUID) async throws -> Void,
        activity: @escaping @Sendable (UUID) async throws -> Void = { _ in },
        interrupt: @escaping @Sendable (UUID) async throws -> Void,
        end: @escaping @Sendable (UUID, RemoteLiveTerminalReason) async throws -> Void
    ) {
        self.start = start
        self.connected = connected
        self.activity = activity
        self.interrupt = interrupt
        self.end = end
    }
}

public actor MillerRemoteBridgeServer {
    fileprivate struct SocketIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct ReplayEntry {
        let connectionID: UUID
        let request: RemoteLiveRequest
        let response: RemoteLiveResponse
        let recordedAt: ContinuousClock.Instant
    }

    private let host: MillerRemoteBridgeHost
    public let socketPath: URL
    private let homeDirectory: URL
    private let generation: UUID
    private let clientHandshakeTimeout: Duration
    private let clientIdleTimeout: Duration
    private let clientWriteTimeout: Duration
    private let bufferBudget: RemoteLiveBufferBudget
    private var socketFD: Int32 = -1
    private var boundSocketIdentity: SocketIdentity?
    private var acceptSource: DispatchSourceRead?
    private var clients: [UUID: RemoteLiveBridgeClientConnection] = [:]
    private var replayEntries: [UUID: ReplayEntry] = [:]
    private var replayOrder: [UUID] = []
    private var activeConnectionID: UUID?
    private var activeSessionID: UUID?
    private var admissionEpoch: UInt64 = 0
    private var state: RemoteLiveLifecycleState = .idle
    private var terminalReason: RemoteLiveTerminalReason?
    private var terminalizingSessionID: UUID?
    private var terminalizingReason: RemoteLiveTerminalReason?
    private var connectedRequestInFlight = false
    private var started = false
    private var stopped = false

    public init(
        host: MillerRemoteBridgeHost,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        socketPath: URL? = nil,
        generation: UUID = UUID(),
        clientHandshakeTimeout: Duration = RemoteLiveBridgeContract.clientHandshakeTimeout,
        clientIdleTimeout: Duration = RemoteLiveBridgeContract.clientIdleTimeout,
        clientWriteTimeout: Duration = RemoteLiveBridgeContract.clientWriteTimeout
    ) {
        self.host = host
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.socketPath = (socketPath ?? RemoteLiveBridgeContract.socketURL(
            homeDirectory: homeDirectory
        )).standardizedFileURL
        self.generation = generation
        self.clientHandshakeTimeout = clientHandshakeTimeout
        self.clientIdleTimeout = clientIdleTimeout
        self.clientWriteTimeout = clientWriteTimeout
        bufferBudget = RemoteLiveBufferBudget(
            limit: RemoteLiveBridgeContract.maximumBufferedBytes
        )
    }

    public var hostGeneration: UUID { generation }

    public func start() throws {
        guard !started else { return }
        guard !stopped else { throw RemoteLiveBridgeError.hostUnavailable }
        try RemoteLiveSocketSafety.prepare(
            socketPath: socketPath,
            homeDirectory: homeDirectory
        )
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteLiveBridgeError.hostUnavailable }
        var boundIdentity: SocketIdentity?
        do {
            try RemoteLiveSocketSafety.configure(fd: fd)
            try RemoteLiveSocketSafety.bind(fd: fd, to: socketPath)
            var pathInfo = RemoteLiveSocketSafety.statBuffer()
            guard lstat(socketPath.path, &pathInfo) == 0 else {
                throw RemoteLiveBridgeError.hostUnavailable
            }
            let pathIdentity = SocketIdentity(
                device: UInt64(bitPattern: Int64(pathInfo.st_dev)),
                inode: UInt64(pathInfo.st_ino)
            )
            boundIdentity = pathIdentity
            guard (pathInfo.st_mode & S_IFMT) == S_IFSOCK,
                  pathInfo.st_uid == getuid()
            else {
                throw RemoteLiveBridgeError.hostUnavailable
            }
            var descriptorInfo = RemoteLiveSocketSafety.statBuffer()
            guard Darwin.fstat(fd, &descriptorInfo) == 0 else {
                throw RemoteLiveBridgeError.hostUnavailable
            }
            let descriptorIdentity = SocketIdentity(
                device: UInt64(bitPattern: Int64(descriptorInfo.st_dev)),
                inode: UInt64(descriptorInfo.st_ino)
            )
            if RemoteLiveSocketSafety.hasVnodeIdentity(descriptorInfo) {
                guard (descriptorInfo.st_mode & S_IFMT) == S_IFSOCK,
                      descriptorInfo.st_uid == getuid(),
                      descriptorIdentity == pathIdentity else {
                    throw RemoteLiveBridgeError.conflict
                }
            }
            guard Darwin.chmod(socketPath.path, mode_t(0o600)) == 0 else {
                throw RemoteLiveBridgeError.hostUnavailable
            }
            guard RemoteLiveSocketSafety.matches(
                socketPath: socketPath,
                identity: pathIdentity
            ) else {
                throw RemoteLiveBridgeError.conflict
            }
            guard Darwin.listen(fd, Int32(SOMAXCONN)) == 0 else {
                throw RemoteLiveBridgeError.hostUnavailable
            }
        } catch {
            Darwin.close(fd)
            try? RemoteLiveSocketSafety.removeOwnedSocket(
                socketPath: socketPath,
                homeDirectory: homeDirectory,
                identity: boundIdentity
            )
            throw error
        }
        socketFD = fd
        boundSocketIdentity = boundIdentity
        started = true
        let handshakeTimeout = clientHandshakeTimeout
        let idleTimeout = clientIdleTimeout
        let writeTimeout = clientWriteTimeout
        acceptSource = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        acceptSource?.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    if errno == EINTR { continue }
                    break
                }
                guard (try? RemoteLiveSocketSafety.configure(fd: clientFD)) != nil else {
                    Darwin.close(clientFD)
                    continue
                }
                let connectionID = UUID()
                let connection = RemoteLiveBridgeClientConnection(
                    id: connectionID,
                    fileDescriptor: clientFD,
                    handshakeTimeout: handshakeTimeout,
                    idleTimeout: idleTimeout,
                    writeTimeout: writeTimeout,
                    bufferBudget: bufferBudget,
                    receive: { [weak self] connectionID, data in
                        guard let self else { return }
                        await self.receive(data: data, connectionID: connectionID)
                    },
                    disconnected: { [weak self] connectionID in
                        guard let self else { return }
                        Task { await self.disconnect(connectionID: connectionID) }
                    }
                )
                Task { await self.register(connection: connection) }
            }
        }
        acceptSource?.setCancelHandler { Darwin.close(fd) }
        acceptSource?.resume()
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        let sessionID = activeSessionID
        let terminalizationInFlight = terminalizingSessionID != nil
        if let sessionID, !terminalizationInFlight {
            terminalizingSessionID = sessionID
            terminalizingReason = .hostShutdown
        }
        activeConnectionID = nil
        let connections = clients.values
        clients.removeAll()
        for connection in connections { connection.close() }
        acceptSource?.cancel()
        acceptSource = nil
        socketFD = -1
        let identity = boundSocketIdentity
        boundSocketIdentity = nil
        if let sessionID, !terminalizationInFlight {
            try? await host.end(sessionID, .hostShutdown)
            finishSession(reason: .hostShutdown)
        } else if sessionID == nil {
            state = .closed
            terminalReason = .hostShutdown
        }
        try? RemoteLiveSocketSafety.removeOwnedSocket(
            socketPath: socketPath,
            homeDirectory: homeDirectory,
            identity: identity
        )
    }

    public func status() -> (
        clientSessionID: UUID?,
        state: RemoteLiveLifecycleState,
        reason: RemoteLiveTerminalReason?
    ) {
        (activeSessionID, state, terminalReason)
    }

    /// Records a provider-side terminal result after the host has completed
    /// its normal Live cleanup. The bridge owns the remote lease and status;
    /// this hook only closes that bridge-side session exactly once.
    public func providerDidTerminate(
        sessionID: UUID,
        reason: RemoteLiveTerminalReason
    ) {
        guard activeSessionID == sessionID else { return }
        if terminalizingSessionID == nil {
            guard !stopped else { return }
            terminalizingSessionID = sessionID
            terminalizingReason = reason
        }
        guard terminalizingSessionID == sessionID,
              terminalizingReason == reason else { return }
        finishSession(reason: terminalizingReason ?? reason)
    }

    /// Reserves the server-side terminal fence before provider-owned cleanup
    /// begins. The caller must publish completion with `providerDidTerminate`.
    public func beginProviderTermination(
        sessionID: UUID,
        reason: RemoteLiveTerminalReason
    ) -> Bool {
        guard activeSessionID == sessionID,
              !stopped,
              terminalizingSessionID == nil
        else { return false }
        return beginTerminalization(sessionID: sessionID, reason: reason)
    }

    /// In-process request entry point used by focused tests and by the socket
    /// adapter. The connection identifier is the one-session fence.
    public func handle(
        _ request: RemoteLiveRequest,
        connectionID: UUID
    ) async -> RemoteLiveResponse {
        pruneReplay()
        if let replay = replayEntries[request.requestID] {
            guard replay.connectionID == connectionID else {
                return .error(
                    requestID: request.requestID,
                    hostGeneration: generation,
                    code: .replay
                )
            }
            guard replay.request != request else { return replay.response }
            if Self.isAlteredEndReason(replay.request, request) {
                return .error(
                    requestID: request.requestID,
                    hostGeneration: generation,
                    code: .conflict
                )
            }
            return .error(
                requestID: request.requestID,
                hostGeneration: generation,
                code: .replay
            )
        }

        let response: RemoteLiveResponse
        switch request {
        case let .hello(requestID, clientID):
            response = await handleHello(
                requestID: requestID,
                clientID: clientID,
                connectionID: connectionID
            )
        default:
            response = await handlePostHandshake(request, connectionID: connectionID)
        }
        recordReplay(request: request, response: response, connectionID: connectionID)
        return response
    }

    private func handleHello(
        requestID: UUID,
        clientID: String,
        connectionID: UUID
    ) async -> RemoteLiveResponse {
        guard !stopped else {
            return .error(requestID: requestID, hostGeneration: generation, code: .hostUnavailable)
        }
        guard clientID.utf8.count <= RemoteLiveBridgeContract.maximumClientIDBytes else {
            return .error(requestID: requestID, hostGeneration: generation, code: .invalidRequest)
        }
        guard activeConnectionID == nil || activeConnectionID == connectionID else {
            return .error(requestID: requestID, hostGeneration: generation, code: .busy)
        }
        activeConnectionID = connectionID
        return .helloAck(requestID: requestID, hostGeneration: generation)
    }

    private func handlePostHandshake(
        _ request: RemoteLiveRequest,
        connectionID: UUID
    ) async -> RemoteLiveResponse {
        guard activeConnectionID == connectionID else {
            return .error(
                requestID: request.requestID,
                hostGeneration: generation,
                code: .unauthorized
            )
        }
        guard request.hostGeneration == generation else {
            return .error(
                requestID: request.requestID,
                hostGeneration: generation,
                code: .staleGeneration
            )
        }
        switch request {
        case .hello:
            return .error(requestID: request.requestID, hostGeneration: generation, code: .invalidRequest)
        case let .status(requestID, _):
            return .statusResult(
                requestID: requestID,
                hostGeneration: generation,
                clientSessionID: activeSessionID,
                state: state,
                reason: terminalReason
            )
        case let .start(requestID, _, sessionID, offer):
            guard activeSessionID == nil else {
                return .error(requestID: requestID, hostGeneration: generation, code: .busy)
            }
            let priorState = state
            let priorReason = terminalReason
            admissionEpoch &+= 1
            let startEpoch = admissionEpoch
            activeSessionID = sessionID
            state = .starting
            do {
                let answer = try await host.start(sessionID, offer)
                guard admissionEpoch == startEpoch,
                      activeSessionID == sessionID,
                      activeConnectionID == connectionID,
                      !stopped,
                      state == .starting,
                      terminalizingSessionID == nil else {
                    return .error(
                        requestID: requestID,
                        hostGeneration: generation,
                        code: .staleGeneration
                    )
                }
                terminalReason = nil
                state = .connecting
                return .startResult(
                    requestID: requestID,
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    answerSDP: answer
                )
            } catch {
                if admissionEpoch == startEpoch,
                   activeSessionID == sessionID,
                   terminalizingSessionID == nil,
                   !stopped
                {
                    activeSessionID = nil
                    state = priorState
                    terminalReason = priorReason
                }
                return .error(
                    requestID: requestID,
                    hostGeneration: generation,
                    code: Self.errorCode(for: error)
                )
            }
        case let .connected(requestID, _, sessionID):
            guard activeSessionID == sessionID else {
                return .error(requestID: requestID, hostGeneration: generation, code: .notFound)
            }
            guard state == .connecting || state == .listening else {
                return .error(requestID: requestID, hostGeneration: generation, code: .conflict)
            }
            if state == .listening {
                return .operationResult(
                    requestID: requestID,
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    outcome: "ok"
                )
            }
            guard !connectedRequestInFlight else {
                return .error(requestID: requestID, hostGeneration: generation, code: .conflict)
            }
            connectedRequestInFlight = true
            do {
                try await host.connected(sessionID)
                connectedRequestInFlight = false
                guard activeSessionID == sessionID,
                      terminalizingSessionID == nil else {
                    return .error(requestID: requestID, hostGeneration: generation, code: .conflict)
                }
                state = .listening
                return .operationResult(
                    requestID: requestID,
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    outcome: "ok"
                )
            } catch {
                connectedRequestInFlight = false
                return .error(
                    requestID: requestID,
                    hostGeneration: generation,
                    code: Self.errorCode(for: error)
                )
            }
        case let .activity(requestID, _, sessionID):
            guard activeSessionID == sessionID else {
                return .error(requestID: requestID, hostGeneration: generation, code: .notFound)
            }
            guard [.listening, .responding, .speaking].contains(state) else {
                return .error(requestID: requestID, hostGeneration: generation, code: .conflict)
            }
            let activityEpoch = admissionEpoch
            let activityConnectionID = connectionID
            let activityState = state
            do {
                try await host.activity(sessionID)
                guard admissionEpoch == activityEpoch,
                      activeSessionID == sessionID,
                      activeConnectionID == activityConnectionID,
                      !stopped,
                      terminalizingSessionID == nil,
                      state == activityState else {
                    return .error(
                        requestID: requestID,
                        hostGeneration: generation,
                        code: .conflict
                    )
                }
                return .operationResult(
                    requestID: requestID,
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    outcome: "ok"
                )
            } catch {
                return .error(
                    requestID: requestID,
                    hostGeneration: generation,
                    code: Self.errorCode(for: error)
                )
            }
        case let .interrupt(requestID, _, sessionID):
            guard activeSessionID == sessionID else {
                return .error(requestID: requestID, hostGeneration: generation, code: .notFound)
            }
            guard beginTerminalization(sessionID: sessionID, reason: .interrupted) else {
                return .error(requestID: requestID, hostGeneration: generation, code: .conflict)
            }
            do {
                try await host.interrupt(sessionID)
                finishSession(reason: .interrupted)
                return .operationResult(
                    requestID: requestID,
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    outcome: "ok"
                )
            } catch {
                finishSession(reason: terminalizingReason ?? .providerFailed)
                return .error(
                    requestID: requestID,
                    hostGeneration: generation,
                    code: Self.errorCode(for: error)
                )
            }
        case let .end(requestID, _, sessionID, reason):
            guard activeSessionID == sessionID else {
                return .error(requestID: requestID, hostGeneration: generation, code: .notFound)
            }
            guard beginTerminalization(sessionID: sessionID, reason: reason) else {
                return .error(requestID: requestID, hostGeneration: generation, code: .conflict)
            }
            do {
                try await host.end(sessionID, reason)
                finishSession(reason: reason)
                return .operationResult(
                    requestID: requestID,
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    outcome: "ok"
                )
            } catch {
                finishSession(reason: terminalizingReason ?? .providerFailed)
                return .error(
                    requestID: requestID,
                    hostGeneration: generation,
                    code: Self.errorCode(for: error)
                )
            }
        }
    }

    private func finishSession(reason: RemoteLiveTerminalReason) {
        activeSessionID = nil
        connectedRequestInFlight = false
        state = Self.terminalState(for: reason)
        terminalReason = reason
        terminalizingSessionID = nil
        terminalizingReason = nil
    }

    private func beginTerminalization(
        sessionID: UUID,
        reason: RemoteLiveTerminalReason
    ) -> Bool {
        guard terminalizingSessionID == nil else { return false }
        terminalizingSessionID = sessionID
        terminalizingReason = reason
        state = .ending
        return true
    }

    private static func terminalState(
        for reason: RemoteLiveTerminalReason
    ) -> RemoteLiveLifecycleState {
        switch reason {
        case .peerFailed, .trackEnded, .dataChannelClosed, .providerFailed, .timeout:
            .failed
        default:
            .closed
        }
    }

    private func recordReplay(
        request: RemoteLiveRequest,
        response: RemoteLiveResponse,
        connectionID: UUID
    ) {
        let id = request.requestID
        replayEntries[id] = ReplayEntry(
            connectionID: connectionID,
            request: request,
            response: response,
            recordedAt: ContinuousClock.now
        )
        replayOrder.removeAll { $0 == id }
        replayOrder.append(id)
        while replayOrder.count > RemoteLiveBridgeContract.replayCapacity {
            let oldest = replayOrder.removeFirst()
            replayEntries.removeValue(forKey: oldest)
        }
    }

    private func pruneReplay() {
        let cutoff = ContinuousClock.now - RemoteLiveBridgeContract.replayRetention
        let expired = replayOrder.filter {
            guard let entry = replayEntries[$0] else { return true }
            return entry.recordedAt < cutoff
        }
        for id in expired {
            replayEntries.removeValue(forKey: id)
            replayOrder.removeAll { $0 == id }
        }
    }

    private static func isAlteredEndReason(
        _ original: RemoteLiveRequest,
        _ replay: RemoteLiveRequest
    ) -> Bool {
        guard case let .end(_, originalGeneration, originalSession, originalReason) = original,
              case let .end(_, replayGeneration, replaySession, replayReason) = replay
        else { return false }
        return originalGeneration == replayGeneration
            && originalSession == replaySession
            && originalReason != replayReason
    }

    private func register(connection: RemoteLiveBridgeClientConnection) {
        guard !stopped else {
            connection.close()
            return
        }
        guard clients.count < RemoteLiveBridgeContract.maximumActiveClients else {
            connection.close()
            return
        }
        clients[connection.id] = connection
        guard connection.start() else {
            clients.removeValue(forKey: connection.id)
            return
        }
    }

    private func receive(
        data: Data,
        connectionID: UUID
    ) async {
        guard let connection = clients[connectionID], !stopped else { return }
        do {
            let message = try RemoteLiveBridgeCodec.decodeFrame(data)
            guard case let .request(request) = message else {
                connection.close()
                return
            }
            let response = await handle(request, connectionID: connectionID)
            connection.send(try RemoteLiveBridgeCodec.encodeFrame(response))
        } catch {
            connection.close()
        }
    }

    private func disconnect(connectionID: UUID) async {
        clients.removeValue(forKey: connectionID)
        guard activeConnectionID == connectionID else { return }
        activeConnectionID = nil
        if let sessionID = activeSessionID,
           terminalizingSessionID == nil,
           !stopped
        {
            terminalizingSessionID = sessionID
            terminalizingReason = .bridgeDisconnected
            state = .ending
            try? await host.end(sessionID, .bridgeDisconnected)
            finishSession(reason: .bridgeDisconnected)
        }
    }

    private static func errorCode(for error: Error) -> RemoteLiveErrorCode {
        switch error {
        case let error as RemoteLiveBridgeHostError:
            switch error {
            case .busy: .busy
            case .unavailable: .hostUnavailable
            case .providerUnavailable: .providerUnavailable
            case .timeout: .timeout
            case .notFound: .notFound
            case .conflict: .conflict
            case .invalidRequest: .invalidRequest
            }
        case let error as LiveAudioPeerError:
            switch error {
            case .unavailable: .hostUnavailable
            case .invalidState, .invalidOffer, .invalidAnswer: .invalidRequest
            case .connectionFailed: .providerUnavailable
            }
        default: .internalFailure
        }
    }
}

private final class RemoteLiveBufferBudget: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var reserved = 0

    init(limit: Int) {
        self.limit = limit
    }

    func reserve(_ amount: Int) -> Bool {
        guard amount >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard amount <= limit - reserved else { return false }
        reserved += amount
        return true
    }

    func release(_ amount: Int) {
        guard amount > 0 else { return }
        lock.lock()
        reserved = max(0, reserved - amount)
        lock.unlock()
    }
}

private final class RemoteLiveBridgeClientConnection: @unchecked Sendable {
    let id: UUID
    private let fileDescriptor: Int32
    private let handshakeTimeout: Duration
    private let idleTimeout: Duration
    private let writeTimeout: Duration
    private let bufferBudget: RemoteLiveBufferBudget
    private let receiveHandler: @Sendable (UUID, Data) async -> Void
    private let disconnectedHandler: @Sendable (UUID) -> Void
    private let writeLock = NSLock()
    private var source: DispatchSourceRead?
    private var monitorTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var receiveBuffer = Data()
    private var queuedFrames: [Data] = []
    private var closed = false
    private var fdClosed = false
    private var hasReceivedFrame = false
    private var lastActivity = ContinuousClock.now
    private let startedAt = ContinuousClock.now

    init(
        id: UUID,
        fileDescriptor: Int32,
        handshakeTimeout: Duration,
        idleTimeout: Duration,
        writeTimeout: Duration,
        bufferBudget: RemoteLiveBufferBudget,
        receive: @escaping @Sendable (UUID, Data) async -> Void,
        disconnected: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.fileDescriptor = fileDescriptor
        self.handshakeTimeout = handshakeTimeout
        self.idleTimeout = idleTimeout
        self.writeTimeout = writeTimeout
        self.bufferBudget = bufferBudget
        receiveHandler = receive
        disconnectedHandler = disconnected
    }

    func start() -> Bool {
        guard (try? RemoteLiveSocketSafety.configure(fd: fileDescriptor)) != nil else {
            Darwin.close(fileDescriptor)
            fdClosed = true
            return false
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fileDescriptor] in Darwin.close(fileDescriptor) }
        self.source = source
        monitorTask = Task { [weak self] in await self?.monitorConnection() }
        source.resume()
        return true
    }

    func send(_ data: Data) {
        writeLock.lock()
        guard !closed else {
            writeLock.unlock()
            return
        }
        var failed = false
        let writeDeadline = ContinuousClock.now.advanced(by: writeTimeout)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var becameWritable = false
                    while true {
                        let timeout = Self.remainingMilliseconds(until: writeDeadline)
                        guard timeout > 0 else { break }
                        var writable = pollfd(
                            fd: fileDescriptor,
                            events: Int16(POLLOUT),
                            revents: 0
                        )
                        let polled = Darwin.poll(&writable, 1, timeout)
                        if polled == 1 {
                            becameWritable = true
                            break
                        }
                        if polled < 0, errno == EINTR { continue }
                        break
                    }
                    guard becameWritable else {
                        failed = true
                        break
                    }
                    continue
                }
                failed = true
                break
            }
            if offset != rawBuffer.count { failed = true }
        }
        writeLock.unlock()
        if failed { close() }
    }

    func close() {
        writeLock.lock()
        guard !closed else {
            writeLock.unlock()
            return
        }
        closed = true
        let source = self.source
        self.source = nil
        let monitor = monitorTask
        monitorTask = nil
        let processing = processingTask
        processingTask = nil
        let bufferedBytes = receiveBuffer.count
            + queuedFrames.reduce(into: 0) { $0 += $1.count }
        receiveBuffer.removeAll()
        queuedFrames.removeAll()
        let closeFD = source == nil && !fdClosed
        if closeFD { fdClosed = true }
        writeLock.unlock()
        bufferBudget.release(bufferedBytes)
        monitor?.cancel()
        processing?.cancel()
        if let source {
            source.cancel()
        } else if closeFD {
            Darwin.close(fileDescriptor)
        }
        disconnectedHandler(id)
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                guard bufferBudget.reserve(count) else {
                    close()
                    return
                }
                writeLock.lock()
                guard !closed else {
                    writeLock.unlock()
                    bufferBudget.release(count)
                    return
                }
                receiveBuffer.append(contentsOf: chunk.prefix(count))
                let valid = parseFramesLocked()
                writeLock.unlock()
                if !valid { close(); return }
                continue
            }
            if count == 0 { close() }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK { close() }
            return
        }
    }

    private func parseFramesLocked() -> Bool {
        while true {
            guard receiveBuffer.count >= 4 else {
                return receiveBuffer.count <= RemoteLiveBridgeContract.maximumFrameBytes + 4
            }
            let length = receiveBuffer.prefix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0,
                  Int(length) <= RemoteLiveBridgeContract.maximumFrameBytes
            else { return false }
            let frameLength = 4 + Int(length)
            guard receiveBuffer.count >= frameLength else { return true }
            let frame = Data(receiveBuffer.prefix(frameLength))
            receiveBuffer.removeFirst(frameLength)
            guard queuedFrames.count < RemoteLiveBridgeContract.maximumQueuedFrames else {
                bufferBudget.release(frame.count)
                return false
            }
            queuedFrames.append(frame)
            hasReceivedFrame = true
            lastActivity = ContinuousClock.now
            if processingTask == nil {
                processingTask = Task { [weak self] in await self?.drainFrames() }
            }
        }
    }

    private func drainFrames() async {
        while let frame = dequeueFrame() {
            await receiveHandler(id, frame)
        }
    }

    private func monitorConnection() async {
        while true {
            guard let deadline = connectionDeadline() else { return }
            do {
                try await Task.sleep(until: deadline, clock: ContinuousClock())
            } catch {
                return
            }
            if isExpired(deadline) {
                close()
                return
            }
        }
    }

    private func dequeueFrame() -> Data? {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return nil }
        guard !queuedFrames.isEmpty else {
            processingTask = nil
            return nil
        }
        let frame = queuedFrames.removeFirst()
        bufferBudget.release(frame.count)
        return frame
    }

    private func connectionDeadline() -> ContinuousClock.Instant? {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return nil }
        let reference = hasReceivedFrame ? lastActivity : startedAt
        let timeout = hasReceivedFrame ? idleTimeout : handshakeTimeout
        return reference.advanced(by: timeout)
    }

    private func isExpired(_ deadline: ContinuousClock.Instant) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        return connectionDeadlineLocked() == deadline
            && ContinuousClock.now >= deadline
    }

    private func connectionDeadlineLocked() -> ContinuousClock.Instant {
        let reference = hasReceivedFrame ? lastActivity : startedAt
        let timeout = hasReceivedFrame ? idleTimeout : handshakeTimeout
        return reference.advanced(by: timeout)
    }

    private static func remainingMilliseconds(
        until deadline: ContinuousClock.Instant
    ) -> Int32 {
        let components = ContinuousClock.now.duration(to: deadline).components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let seconds = min(components.seconds, Int64(Int32.max / 1_000))
        let milliseconds = seconds * 1_000
            + Int64(max(components.attoseconds, 0) / 1_000_000_000_000_000)
        return Int32(min(milliseconds, Int64(Int32.max)))
    }
}

private enum RemoteLiveSocketSafety {
    static func prepare(socketPath: URL, homeDirectory: URL) throws {
        let home = homeDirectory.standardizedFileURL
        let path = socketPath.standardizedFileURL
        try validatePath(socketPath: path, homeDirectory: home)
        try ensureDirectory(home)
        var current = home
        for component in ["Library", "Application Support", "ai.millrace.miller"] {
            current.appendPathComponent(component, isDirectory: true)
            if !FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.createDirectory(
                    at: current,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try ensureDirectory(current)
        }
        var existing = statBuffer()
        if lstat(path.path, &existing) == 0 {
            _ = existing
            throw RemoteLiveBridgeError.conflict
        } else if errno != ENOENT {
            throw RemoteLiveBridgeError.conflict
        }
    }

    static func configure(fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0 else {
            throw RemoteLiveBridgeError.hostUnavailable
        }
        var noSignal: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw RemoteLiveBridgeError.hostUnavailable
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
        else {
            throw RemoteLiveBridgeError.hostUnavailable
        }
    }

    static func bind(fd: Int32, to path: URL) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw RemoteLiveBridgeError.conflict
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        guard result == 0 else { throw RemoteLiveBridgeError.conflict }
    }

    static func removeOwnedSocket(
        socketPath: URL,
        homeDirectory: URL,
        identity: MillerRemoteBridgeServer.SocketIdentity?
    ) throws {
        guard let identity else { return }
        try validatePath(
            socketPath: socketPath.standardizedFileURL,
            homeDirectory: homeDirectory.standardizedFileURL
        )
        var info = statBuffer()
        guard lstat(socketPath.path, &info) == 0 else {
            guard errno == ENOENT else { throw RemoteLiveBridgeError.conflict }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(),
              UInt64(bitPattern: Int64(info.st_dev)) == identity.device,
              UInt64(info.st_ino) == identity.inode
        else { throw RemoteLiveBridgeError.conflict }
        guard lstat(socketPath.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(),
              UInt64(bitPattern: Int64(info.st_dev)) == identity.device,
              UInt64(info.st_ino) == identity.inode
        else { throw RemoteLiveBridgeError.conflict }
        guard unlink(socketPath.path) == 0 || errno == ENOENT else {
            throw RemoteLiveBridgeError.conflict
        }
    }

    static func matches(
        socketPath: URL,
        identity: MillerRemoteBridgeServer.SocketIdentity
    ) -> Bool {
        var info = statBuffer()
        guard lstat(socketPath.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(),
              UInt64(bitPattern: Int64(info.st_dev)) == identity.device,
              UInt64(info.st_ino) == identity.inode,
              info.st_mode & 0o777 == 0o600
        else { return false }
        return true
    }

    private static func validatePath(socketPath: URL, homeDirectory: URL) throws {
        let expectedParent = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ai.millrace.miller", isDirectory: true)
        guard socketPath.deletingLastPathComponent() == expectedParent,
              socketPath.lastPathComponent == RemoteLiveBridgeContract.socketFileName,
              socketPath.path == homeDirectory.path
                  || socketPath.path.hasPrefix(homeDirectory.path + "/")
        else { throw RemoteLiveBridgeError.conflict }
    }

    private static func ensureDirectory(_ url: URL) throws {
        var info = statBuffer()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o022) == 0
        else { throw RemoteLiveBridgeError.conflict }
        _ = chmod(url.path, mode_t(0o700))
    }

    static func hasVnodeIdentity(_ info: stat) -> Bool {
        info.st_dev >= 0 && info.st_ino != 0
    }

    fileprivate static func statBuffer() -> stat { stat() }
}

import Foundation

// Modified donor-derived behavior: OpenClaw PR #115226 at commit
// f78ba091207b33c3bb79f1bd9879d0e56be91a16 supplied startup retry,
// early-frame buffering, and teardown behavior. Miller adapts it to
// URLSessionWebSocketTask and bounded terminal outcomes.

public enum GPTLiveSidebandError: Error, Equatable, Sendable {
    case startupFailed
    case closed
    case cancelled
}

public enum GPTLiveSidebandTerminal: Equatable, Sendable {
    case error
    case closed
    case protocolViolation
}

public enum GPTLiveWebSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

public protocol GPTLiveWebSocket: AnyObject, Sendable {
    func open() async throws
    func receive() async throws -> GPTLiveWebSocketMessage
    func send(_ text: String) async throws
    func close()
}

public typealias GPTLiveWebSocketFactory = @Sendable (
    _ url: URL,
    _ headers: [String: String]
) -> any GPTLiveWebSocket

final class URLSessionGPTLiveWebSocket: GPTLiveWebSocket, @unchecked Sendable {
    private let delegate: GPTLiveWebSocketDelegate
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let openTimeout: Duration

    init(
        url: URL,
        headers: [String: String],
        openTimeout: Duration = .seconds(10)
    ) {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = 10
        let delegate = GPTLiveWebSocketDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = GPTLiveWireLimits.maximumEventBytes
        self.delegate = delegate
        self.session = session
        self.task = task
        self.openTimeout = openTimeout
    }

    func open() async throws {
        task.resume()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.delegate.waitUntilOpen() }
                group.addTask {
                    try await Task.sleep(for: self.openTimeout)
                    throw GPTLiveSidebandError.startupFailed
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            close()
            throw CancellationError()
        } catch {
            close()
            throw GPTLiveSidebandError.startupFailed
        }
    }

    func receive() async throws -> GPTLiveWebSocketMessage {
        let message = try await task.receive()
        switch message {
        case let .string(text): return .text(text)
        case let .data(data): return .binary(data)
        @unknown default: return .binary(Data())
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

private final class GPTLiveWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func waitUntilOpen() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }, onCancel: {
            finish(.failure(CancellationError()))
        })
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        finish(.success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(.failure(GPTLiveSidebandError.closed))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if error != nil { finish(.failure(GPTLiveSidebandError.startupFailed)) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(GPTLiveSidebandError.startupFailed))
    }

    private func finish(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(with: value) }
    }
}

public struct GPTLiveSidebandOptions: Equatable, Sendable {
    public let maximumStartupAttempts: Int
    public let retryBaseMilliseconds: Int
    public let maximumBufferedFrames: Int
    public let maximumFrameBytes: Int

    public init(
        maximumStartupAttempts: Int = 5,
        retryBaseMilliseconds: Int = 200,
        maximumBufferedFrames: Int = 32,
        maximumFrameBytes: Int = GPTLiveWireLimits.maximumEventBytes
    ) {
        self.maximumStartupAttempts = max(1, maximumStartupAttempts)
        self.retryBaseMilliseconds = max(0, retryBaseMilliseconds)
        self.maximumBufferedFrames = max(1, maximumBufferedFrames)
        self.maximumFrameBytes = max(1, maximumFrameBytes)
    }

    public static let `default` = Self()
}

public final class GPTLiveSidebandConnection: @unchecked Sendable {
    private let socket: any GPTLiveWebSocket
    private let options: GPTLiveSidebandOptions
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "ai.millrace.miller.gpt-live-sideband")
    private var bufferedFrames: [GPTLiveWebSocketMessage] = []
    private var frameHandler: (@Sendable (GPTLiveWebSocketMessage) -> Void)?
    private var terminalHandler: (@Sendable (GPTLiveSidebandTerminal) -> Void)?
    private var terminalValue: GPTLiveSidebandTerminal?
    private var ownerClosed = false
    private var providerOpened = false
    private var receiveTask: Task<Void, Never>?

    init(socket: any GPTLiveWebSocket, options: GPTLiveSidebandOptions) {
        self.socket = socket
        self.options = options
    }

    public var bufferedFrameCount: Int {
        lock.withLock { bufferedFrames.count }
    }

    public var terminal: GPTLiveSidebandTerminal? {
        lock.withLock { terminalValue }
    }

    func startReceiving() {
        lock.lock()
        guard receiveTask == nil, !ownerClosed else { lock.unlock(); return }
        providerOpened = true
        let socket = self.socket
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    if case let .text(text) = message,
                       text.utf8.count > self.options.maximumFrameBytes {
                        self.finish(.protocolViolation)
                        return
                    }
                    if case .binary = message {
                        self.finish(.protocolViolation)
                        return
                    }
                    self.deliver(message)
                }
            } catch is CancellationError {
                return
            } catch let error as GPTLiveSidebandError {
                if error == .closed { self.finish(.closed) }
                else if error == .cancelled { return }
                else { self.finish(.error) }
            } catch {
                self.finish(.error)
            }
        }
        receiveTask = task
        lock.unlock()
    }

    @discardableResult
    public func attach(
        onFrame: @escaping @Sendable (GPTLiveWebSocketMessage) -> Void,
        onTerminal: @escaping @Sendable (GPTLiveSidebandTerminal) -> Void
    ) -> GPTLiveSidebandTerminal? {
        let frames: [GPTLiveWebSocketMessage]
        let terminal: GPTLiveSidebandTerminal?
        lock.lock()
        frameHandler = onFrame
        terminalHandler = onTerminal
        frames = bufferedFrames
        bufferedFrames.removeAll()
        terminal = terminalValue
        for frame in frames { callbackQueue.async { onFrame(frame) } }
        if let terminal { callbackQueue.async { onTerminal(terminal) } }
        lock.unlock()
        return terminal
    }

    public func send(_ text: String) async throws {
        guard text.utf8.count <= options.maximumFrameBytes else {
            throw GPTLiveSidebandError.startupFailed
        }
        guard lock.withLock({ !ownerClosed && terminalValue == nil }) else {
            throw GPTLiveSidebandError.closed
        }
        try await socket.send(text)
    }

    public func close() async {
        let closeState = lock.withLock { () -> (Bool, Task<Void, Never>?)? in
            guard !ownerClosed else { return nil }
            ownerClosed = true
            let state = (providerOpened && terminalValue == nil, receiveTask)
            receiveTask = nil
            return state
        }
        guard let (shouldNotifyProvider, task) = closeState else { return }
        if shouldNotifyProvider {
            try? await socket.send(#"{"type":"session.close"}"#)
        }
        task?.cancel()
        socket.close()
    }

    private func deliver(_ message: GPTLiveWebSocketMessage) {
        let handler: (@Sendable (GPTLiveWebSocketMessage) -> Void)?
        lock.lock()
        guard terminalValue == nil, !ownerClosed else {
            lock.unlock()
            return
        }
        var overflow = false
        if let frameHandler {
            handler = frameHandler
        } else {
            if bufferedFrames.count < options.maximumBufferedFrames {
                bufferedFrames.append(message)
            } else {
                overflow = true
            }
            handler = nil
        }
        lock.unlock()
        if overflow {
            finish(.protocolViolation)
        } else if let handler {
            callbackQueue.async { handler(message) }
        }
    }

    private func finish(_ terminal: GPTLiveSidebandTerminal) {
        let handler: (@Sendable (GPTLiveSidebandTerminal) -> Void)?
        lock.lock()
        guard terminalValue == nil, !ownerClosed else {
            lock.unlock()
            return
        }
        terminalValue = terminal
        handler = terminalHandler
        if let handler { callbackQueue.async { handler(terminal) } }
        lock.unlock()
        socket.close()
    }
}

public struct GPTLiveSidebandConnector: Sendable {
    private let factory: GPTLiveWebSocketFactory
    private let sleep: @Sendable (Duration) async throws -> Void
    private let options: GPTLiveSidebandOptions

    public init(
        factory: @escaping GPTLiveWebSocketFactory,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        options: GPTLiveSidebandOptions = .default
    ) {
        self.factory = factory
        self.sleep = sleep
        self.options = options
    }

    public init() {
        self.init(factory: { url, headers in
            URLSessionGPTLiveWebSocket(url: url, headers: headers)
        })
    }

    public func connect(
        url: URL,
        auth: GPTLiveAuth,
        requestIDs: GPTLiveRequestIDs
    ) async throws -> GPTLiveSidebandConnection {
        guard url.scheme?.lowercased() == "wss",
              url.host?.lowercased() == "api.openai.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.hasPrefix("/v1/live/")
        else { throw GPTLiveSidebandError.startupFailed }
        let headers = try GPTLiveCallCreator.authHeaders(auth: auth, requestIDs: requestIDs)
        var lastFailure: Error = GPTLiveSidebandError.startupFailed
        for attempt in 0..<options.maximumStartupAttempts {
            try Task.checkCancellation()
            let socket = factory(url, headers)
            let connection = GPTLiveSidebandConnection(socket: socket, options: options)
            do {
                try await socket.open()
                try Task.checkCancellation()
                connection.startReceiving()
                return connection
            } catch is CancellationError {
                await connection.close()
                throw CancellationError()
            } catch let error as GPTLiveSidebandError where error == .cancelled {
                await connection.close()
                throw CancellationError()
            } catch {
                lastFailure = GPTLiveSidebandError.startupFailed
                await connection.close()
                if attempt + 1 < options.maximumStartupAttempts {
                    let multiplier = 1 << min(attempt, 10)
                    let delay = Duration.milliseconds(
                        Int64(options.retryBaseMilliseconds * multiplier)
                    )
                    do {
                        try await sleep(delay)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw GPTLiveSidebandError.cancelled
                    }
                }
            }
        }
        throw lastFailure
    }
}

import Foundation
@testable import MillerLive
import Testing

struct GPTLiveSidebandTests {
    @Test
    func retriesStartupOnlyAndSendsBoundedAuthHeaders() async throws {
        let sockets = SocketFactoryProbe(plans: [.failOpen, .failOpen, .open])
        let connector = GPTLiveSidebandConnector(
            factory: sockets.make,
            sleep: { _ in }
        )
        let connection = try await connector.connect(
            url: URL(string: "wss://api.openai.com/v1/live/rtc_retry")!,
            auth: .oauth(accessToken: Data("oauth-secret".utf8), accountID: "account-secret"),
            requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
        )
        #expect(sockets.count == 3)
        #expect(sockets.headers.allSatisfy { $0["OpenAI-Alpha"] == "quicksilver=v2" })
        #expect(sockets.headers.allSatisfy { $0["chatgpt-account-id"] == "account-secret" })
        #expect(sockets.headers.allSatisfy { $0["Authorization"] == "Bearer oauth-secret" })
        await connection.close()
    }

    @Test
    func buffersEarlyFramesAndPreservesCancellationAndUnexpectedClosure() async throws {
        let socket = ScriptedGPTLiveSocket(openPlan: .open)
        socket.queue(.text(#"{"type":"session.started","session":{}}"#))
        socket.queue(.text(#"{"type":"input_transcript.added","item":{"text":"hello"}}"#))
        let connector = GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in })
        let connection = try await connector.connect(
            url: URL(string: "wss://api.openai.com/v1/live/rtc_frames")!,
            auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
            requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
        )
        try await Task.sleep(for: .milliseconds(10))
        #expect(connection.bufferedFrameCount == 2)
        let frames = FrameProbe()
        let terminal = connection.attach(
            onFrame: { frame in Task { await frames.append(frame) } },
            onTerminal: { _ in }
        )
        #expect(terminal == nil)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await frames.count == 2)
        socket.emitClosure()
        try await Task.sleep(for: .milliseconds(20))
        #expect(connection.terminal == .closed)
        await connection.close()
    }

    @Test
    func cancellationStopsRetryWithoutExposingTheUnderlyingError() async {
        let sockets = SocketFactoryProbe(plans: [.failOpen, .failOpen, .failOpen])
        let connector = GPTLiveSidebandConnector(
            factory: sockets.make,
            sleep: { _ in try await Task.sleep(for: .seconds(10)) }
        )
        let task = Task {
            try await connector.connect(
                url: URL(string: "wss://api.openai.com/v1/live/rtc_cancel")!,
                auth: .oauth(accessToken: Data("secret".utf8), accountID: "account"),
                requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
            )
        }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        let result = await task.result
        #expect({
            if case .failure = result { return true }
            return false
        }())
        #expect(String(describing: result).contains("secret") == false)
    }

    @Test
    func binaryAndOversizedFramesTerminateWithFixedProtocolOutcome() async throws {
        let socket = ScriptedGPTLiveSocket(openPlan: .open)
        let connector = GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in })
        let connection = try await connector.connect(
            url: URL(string: "wss://api.openai.com/v1/live/rtc_protocol")!,
            auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
            requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
        )
        socket.queue(.binary(Data([1, 2, 3])))
        try await Task.sleep(for: .milliseconds(20))
        #expect(connection.terminal == .protocolViolation)
        await connection.close()

        let oversizedSocket = ScriptedGPTLiveSocket(openPlan: .open)
        let oversizedConnection = try await GPTLiveSidebandConnector(
            factory: { _, _ in oversizedSocket },
            sleep: { _ in }
        ).connect(
            url: URL(string: "wss://api.openai.com/v1/live/rtc_oversized")!,
            auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
            requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
        )
        oversizedSocket.queue(.text(String(repeating: "x", count: GPTLiveWireLimits.maximumEventBytes + 1)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(oversizedConnection.terminal == .protocolViolation)
        await oversizedConnection.close()
    }

    @Test
    func ownerCloseSendsSessionCloseExactlyOnceAndRejectsLaterSends() async throws {
        let socket = ScriptedGPTLiveSocket(openPlan: .open)
        let connection = try await GPTLiveSidebandConnector(
            factory: { _, _ in socket }, sleep: { _ in }
        ).connect(
            url: URL(string: "wss://api.openai.com/v1/live/rtc_close")!,
            auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
            requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
        )

        await connection.close()
        await connection.close()

        #expect(socket.sentMessages == [#"{"type":"session.close"}"#])
        await #expect(throws: GPTLiveSidebandError.closed) {
            try await connection.send(#"{"type":"delegation.context.append"}"#)
        }
    }

    @Test
    func rejectsNonOpenAIWebSocketEndpointBeforeCreatingSocket() async {
        let factory = SocketFactoryProbe(plans: [.open])
        await #expect(throws: GPTLiveSidebandError.startupFailed) {
            _ = try await GPTLiveSidebandConnector(
                factory: factory.make, sleep: { _ in }
            ).connect(
                url: URL(string: "wss://example.com/v1/live/rtc_wrong")!,
                auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
                requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
            )
        }
        #expect(factory.count == 0)
    }

    @Test
    func productionSocketOpenWaitsForHandshakeFailure() async {
        let socket = URLSessionGPTLiveWebSocket(
            url: URL(string: "wss://127.0.0.1:1/v1/live/rtc_unreachable")!,
            headers: [:],
            openTimeout: .milliseconds(250)
        )
        await #expect(throws: (any Error).self) { try await socket.open() }
        socket.close()
    }

    @Test
    func bufferedFramesAreDeliveredBeforeTerminalAndOverflowIsTerminal() async throws {
        let socket = ScriptedGPTLiveSocket(openPlan: .open)
        let connection = try await GPTLiveSidebandConnector(
            factory: { _, _ in socket },
            sleep: { _ in },
            options: .init(maximumBufferedFrames: 2)
        ).connect(
            url: URL(string: "wss://api.openai.com/v1/live/rtc_order")!,
            auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
            requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
        )
        socket.queue(.text("one"))
        socket.queue(.text("two"))
        socket.queue(.text("overflow"))
        try await Task.sleep(for: .milliseconds(20))

        let order = CallbackOrderProbe()
        _ = connection.attach(
            onFrame: { message in order.append(message == .text("one") ? "one" : "two") },
            onTerminal: { _ in order.append("terminal") }
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(order.values == ["one", "two", "terminal"])
        #expect(connection.terminal == .protocolViolation)
        await connection.close()
    }
}

private final class SocketFactoryProbe: @unchecked Sendable {
    enum Plan { case failOpen, open }
    private let plans: [Plan]
    private(set) var count = 0
    private(set) var headers: [[String: String]] = []

    init(plans: [Plan]) { self.plans = plans }

    func make(_ url: URL, _ headers: [String: String]) -> any GPTLiveWebSocket {
        let index = count
        count += 1
        self.headers.append(headers)
        return ScriptedGPTLiveSocket(
            openPlan: plans[min(index, plans.count - 1)] == .open ? .open : .failOpen
        )
    }
}

private final class ScriptedGPTLiveSocket: GPTLiveWebSocket, @unchecked Sendable {
    enum OpenPlan { case failOpen, open }
    private let lock = NSLock()
    private let openPlan: OpenPlan
    private var queue: [GPTLiveWebSocketMessage] = []
    private var waiters: [CheckedContinuation<GPTLiveWebSocketMessage, Error>] = []
    private var sent: [String] = []
    private(set) var closed = false

    init(openPlan: OpenPlan) { self.openPlan = openPlan }

    func open() async throws {
        if openPlan == .failOpen { throw GPTLiveSidebandError.startupFailed }
    }

    func receive() async throws -> GPTLiveWebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let message = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: GPTLiveSidebandError.closed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func send(_ text: String) async throws {
        lock.withLock { sent.append(text) }
    }

    var sentMessages: [String] { lock.withLock { sent } }

    func close() {
        lock.lock()
        closed = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(throwing: GPTLiveSidebandError.closed) }
    }

    func queue(_ message: GPTLiveWebSocketMessage) {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: message)
        } else {
            queue.append(message)
            lock.unlock()
        }
    }

    func emitClosure() { close() }
}

private final class CallbackOrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

private actor FrameProbe {
    private var values: [GPTLiveWebSocketMessage] = []
    func append(_ value: GPTLiveWebSocketMessage) { values.append(value) }
    var count: Int { values.count }
}

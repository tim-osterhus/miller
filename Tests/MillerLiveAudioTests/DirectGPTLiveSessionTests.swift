import Foundation
import MillerLive
import MillerLiveAudio
import Testing

@MainActor
@Suite(.serialized)
struct DirectGPTLiveSessionTests {
    @Test
    func directSessionUsesPeerMediaPlaneAndProjectsTranscriptInOrder() async throws {
        let peer = DirectTestPeer()
        let loader = DirectSessionLoader()
        let socket = DirectSessionSocket()
        let session = DirectGPTLiveSession(
            peer: peer,
            callCreator: GPTLiveCallCreator(loader: loader),
            sidebandConnector: GPTLiveSidebandConnector(
                factory: { _, _ in socket },
                sleep: { _ in }
            )
        )
        let events = EventRecorder()
        let run = Task {
            try await session.run(
                identity: .init(requestID: "request-1", threadID: "thread-1", generation: 7),
                credential: .init(
                    accessToken: Data("oauth-secret".utf8),
                    accountID: "account-secret",
                    planType: nil
                ),
                permission: .authorized,
                receive: { event in await events.append(event) }
            )
        }

        try await waitUntil { await events.containsStarted }
        socket.queue(.text(#"{"type":"input_transcript.added","item":{"text":"hel"}}"#))
        socket.queue(.text(#"{"type":"turn.done","turn":{"role":"user","transcript":"hello"}}"#))
        socket.queue(.text(#"{"type":"output_transcript.added","item":{"text":"world"}}"#))
        try await waitUntil { await events.count >= 4 }

        await session.end()
        _ = await run.result

        #expect(peer.operations == [.prepare, .answer, .close])
        #expect(await events.snapshot().contains { event in
            if case .transcriptDone(_, "user", "hello") = event { return true }
            return false
        })
        #expect(await events.snapshot().contains { event in
            if case .transcriptDelta(_, "assistant", "world") = event { return true }
            return false
        })
        #expect(String(describing: await events.snapshot()).contains("oauth-secret") == false)
    }

    @Test
    func muteInterruptCleanupStaleCallbacksAndFreshSessionAreBounded() async throws {
        let firstPeer = DirectTestPeer()
        let socket = DirectSessionSocket()
        let session = DirectGPTLiveSession(
            peer: firstPeer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in })
        )
        let events = EventRecorder()
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "first", threadID: "thread-first", generation: 1),
                credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                permission: .authorized,
                receive: { event in await events.append(event) }
            )
        }
        try await waitUntil { await events.containsStarted }
        await session.setMuted(true)
        await session.setMuted(false)
        await session.interrupt()
        _ = await run.result
        #expect(firstPeer.operations.contains(.mute(true)))
        #expect(firstPeer.operations.contains(.mute(false)))
        #expect(firstPeer.operations.filter { $0 == .close }.count == 1)

        // A new session owns a new peer; callbacks from the first socket cannot
        // change the second session's state.
        let secondPeer = DirectTestPeer()
        let secondSocket = DirectSessionSocket()
        let second = DirectGPTLiveSession(
            peer: secondPeer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(
                factory: { _, _ in secondSocket },
                sleep: { _ in }
            )
        )
        let secondEvents = EventRecorder()
        let secondRun = Task {
            try? await second.run(
                identity: .init(requestID: "second", threadID: "thread-second", generation: 2),
                credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                permission: .authorized,
                receive: { event in await secondEvents.append(event) }
            )
        }
        try await waitUntil { await secondEvents.containsStarted }
        socket.queue(.text(#"{"type":"output_transcript.added","item":{"text":"stale"}}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await secondEvents.snapshot().contains { event in
            if case .transcriptDelta(_, _, "stale") = event { return true }
            return false
        } == false)
        await second.end()
        _ = await secondRun.result
    }

    @Test
    func delegationUsesInjectableConsultationWithChunkingAndSupersession() async throws {
        let peer = DirectTestPeer()
        let socket = DirectSessionSocket()
        let tokens = ConsultationTokenProbe()
        let consultation: GPTLiveConsultation = { request in
            await tokens.append(request.cancellation)
            while !request.cancellation.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        let session = DirectGPTLiveSession(
            peer: peer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in }),
            consultation: consultation
        )
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "delegation", threadID: "thread", generation: 1),
                credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                permission: .authorized,
                receive: { _ in }
            )
        }
        try await waitUntil { await MainActor.run { peer.operations.contains(.answer) } }
        socket.queue(.text(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"one","content":[{"type":"input_text","text":"first"}]}}"#))
        try await waitUntil { await tokens.count == 1 }
        socket.queue(.text(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"two","content":[{"type":"input_text","text":"second"}]}}"#))
        try await waitUntil { await tokens.count == 2 }
        #expect(await tokens.cancelledCount == 1)
        await session.end()
        _ = await run.result
    }

    @Test
    func nonfatalProviderErrorKeepsSessionAliveAndFatalAuthTerminates() async throws {
        let peer = DirectTestPeer()
        let socket = DirectSessionSocket()
        let session = DirectGPTLiveSession(
            peer: peer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in })
        )
        let events = EventRecorder()
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "error", threadID: "thread", generation: 1),
                credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                permission: .authorized,
                receive: { event in await events.append(event) }
            )
        }
        try await waitUntil { await events.containsStarted }
        socket.queue(.text(#"{"type":"error","error":{"message":"transient"}}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(peer.operations.filter { $0 == .close }.isEmpty)
        #expect(await events.snapshot().contains { event in
            if case .failed = event { return true }
            return false
        } == false)
        socket.queue(.text(#"{"type":"error","error":{"status":401,"message":"oauth-secret-value"}}"#))
        try await waitUntil {
            await events.snapshot().contains { event in
                if case .failed(_, "live_sideband_failed") = event { return true }
                return false
            }
        }
        _ = await run.result
        #expect(peer.operations == [.prepare, .answer, .close])
        #expect(String(describing: await events.snapshot()).contains("oauth-secret-value") == false)
    }

    @Test
    func explicitSessionCloseProjectsClosedOutcome() async throws {
        let peer = DirectTestPeer()
        let socket = DirectSessionSocket()
        let session = DirectGPTLiveSession(
            peer: peer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in })
        )
        let events = EventRecorder()
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "closed", threadID: "thread", generation: 1),
                credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                permission: .authorized,
                receive: { event in await events.append(event) }
            )
        }
        try await waitUntil { await events.containsStarted }
        socket.queue(.text(#"{"type":"session.closed"}"#))
        _ = await run.result
        #expect(await events.snapshot().contains { event in
            if case .closed(_, "provider_closed") = event { return true }
            return false
        })
        #expect(await events.snapshot().contains { event in
            if case .failed = event { return true }
            return false
        } == false)
    }

    @Test
    func sidebandClosureDuringPeerAnswerNeverPublishesStarted() async throws {
        let peer = BlockingAnswerPeer()
        let socket = DirectSessionSocket()
        let session = DirectGPTLiveSession(
            peer: peer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in })
        )
        let events = EventRecorder()
        let run = Task { () -> Bool in
            do {
                try await session.run(
                    identity: .init(requestID: "early-close", threadID: "thread", generation: 1),
                    credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                    permission: .authorized,
                    receive: { event in await events.append(event) }
                )
                return true
            } catch {
                return false
            }
        }
        try await waitUntil { await MainActor.run { peer.answerStarted } }
        socket.emitClosure()
        try await Task.sleep(for: .milliseconds(20))
        peer.releaseAnswer()
        #expect(await run.value == false)
        #expect(await events.containsStarted == false)
    }

    @Test
    func slowPeerCleanupReportsPendingThenCompletes() async throws {
        let peer = BlockingClosePeer()
        let socket = DirectSessionSocket()
        let session = DirectGPTLiveSession(
            peer: peer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in }),
            cleanupPendingDelay: .milliseconds(20)
        )
        let pending = BooleanProbe()
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "cleanup", threadID: "thread", generation: 1),
                credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                permission: .authorized,
                onCleanupPending: { await pending.setTrue() },
                receive: { _ in }
            )
        }
        try await waitUntil("peer answer") { await MainActor.run { peer.didAnswer } }
        let ending = Task { await session.end() }
        try await waitUntil("cleanup pending callback") { await pending.value }
        peer.releaseClose()
        await ending.value
        _ = await run.result
        #expect(await pending.value)
        #expect(await MainActor.run { peer.closeCount } == 1)
    }

    @Test
    func delegationEscapesXMLAndBoundsReturnedText() async throws {
        let peer = DirectTestPeer()
        let socket = DirectSessionSocket()
        let prompts = StringProbe()
        let session = DirectGPTLiveSession(
            peer: peer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in }),
            consultation: { request in
                await prompts.append(request.prompt)
                return String(repeating: "x", count: 20_000)
            },
            consultationTimeout: .seconds(1)
        )
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "escape", threadID: "thread", generation: 1),
                credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                permission: .authorized,
                receive: { _ in }
            )
        }
        try await waitUntil { await MainActor.run { peer.operations.contains(.answer) } }
        socket.queue(.text(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"one","content":[{"type":"input_text","text":"<unsafe>&"}]}}"#))
        try await waitUntil { !socket.sentMessages().isEmpty }
        #expect(await prompts.values == ["<realtime_delegation>\n  <input>&lt;unsafe&gt;&amp;</input>\n</realtime_delegation>"])
        let speakableBytes = socket.sentMessages().reduce(0) { partial, message in
            let data = message.data(using: .utf8) ?? Data()
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let content = root?["content"] as? [[String: Any]]
            return partial + (content?.first?["text"] as? String ?? "").utf8.count
        }
        #expect(speakableBytes == 8_000)
        await session.end()
        _ = await run.result
    }

    @Test
    func unsupportedDelegationReturnsFixedSpeakableOutcome() async throws {
        let peer = DirectTestPeer()
        let socket = DirectSessionSocket()
        let session = DirectGPTLiveSession(
            peer: peer,
            callCreator: GPTLiveCallCreator(loader: DirectSessionLoader()),
            sidebandConnector: GPTLiveSidebandConnector(factory: { _, _ in socket }, sleep: { _ in })
        )
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "unsupported", threadID: "thread", generation: 1),
                credential: .init(accessToken: Data("token".utf8), accountID: "account", planType: nil),
                permission: .authorized,
                receive: { _ in }
            )
        }
        try await waitUntil { await MainActor.run { peer.operations.contains(.answer) } }
        socket.queue(.text(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"one","content":[{"type":"input_text","text":"consult"}]}}"#))
        try await waitUntil { !socket.sentMessages().isEmpty }
        let sent = socket.sentMessages()
        #expect(sent.count == 1)
        #expect(sent[0].contains("delegation.context.append"))
        #expect(sent[0].contains("speakable"))
        #expect(sent[0].contains("agent consultation is unavailable"))
        await session.end()
        _ = await run.result
    }
}

private final class DirectSessionLoader: GPTLiveURLLoading, @unchecked Sendable {
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            Data("v=0\r\ns=-\r\n".utf8),
            HTTPURLResponse(
                url: URL(string: "https://api.openai.com/v1/live")!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Location": "/v1/live/rtc_direct"]
            )!
        )
    }
}

@MainActor
private final class DirectTestPeer: LiveAudioPeer {
    enum Operation: Equatable { case prepare, answer, mute(Bool), close }
    private(set) var operations: [Operation] = []

    func prepareOffer() async throws -> String {
        operations.append(.prepare)
        return "v=0\r\ns=-\r\n"
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        operations.append(.answer)
    }

    func setMuted(_ muted: Bool) async throws { operations.append(.mute(muted)) }
    func close() async { operations.append(.close) }
}

private final class DirectSessionSocket: GPTLiveWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [GPTLiveWebSocketMessage] = []
    private var waiters: [CheckedContinuation<GPTLiveWebSocketMessage, Error>] = []
    private var sent: [String] = []
    private var closed = false

    func open() async throws {}

    func receive() async throws -> GPTLiveWebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let item = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: item)
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

    func sentMessages() -> [String] {
        lock.withLock { sent }
    }

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

@MainActor
private final class BlockingAnswerPeer: LiveAudioPeer {
    private var answerContinuation: CheckedContinuation<Void, Never>?
    private(set) var answerStarted = false

    func prepareOffer() async throws -> String { "v=0\r\ns=-\r\n" }
    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        answerStarted = true
        await withCheckedContinuation { answerContinuation = $0 }
    }
    func setMuted(_ muted: Bool) async throws {}
    func close() async {}
    func releaseAnswer() { answerContinuation?.resume(); answerContinuation = nil }
}

@MainActor
private final class BlockingClosePeer: LiveAudioPeer {
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private(set) var didAnswer = false
    private(set) var closeCount = 0

    func prepareOffer() async throws -> String { "v=0\r\ns=-\r\n" }
    func applyAnswerAndWaitForConnected(_ answer: String) async throws { didAnswer = true }
    func setMuted(_ muted: Bool) async throws {}
    func close() async {
        closeCount += 1
        await withCheckedContinuation { closeContinuation = $0 }
    }
    func releaseClose() { closeContinuation?.resume(); closeContinuation = nil }
}

private actor EventRecorder {
    private(set) var values: [LiveSessionEvent] = []
    func append(_ event: LiveSessionEvent) { values.append(event) }
    var containsStarted: Bool {
        values.contains { event in
            if case .started = event { return true }
            return false
        }
    }
    func snapshot() -> [LiveSessionEvent] { values }
    var count: Int { values.count }
}

private actor ConsultationTokenProbe {
    private(set) var values: [GPTLiveCancellationToken] = []
    func append(_ token: GPTLiveCancellationToken) { values.append(token) }
    var count: Int { values.count }
    var cancelledCount: Int { values.filter(\.isCancelled).count }
}

private actor BooleanProbe {
    private(set) var value = false
    func setTrue() { value = true }
}

private actor StringProbe {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TimeoutError()
}

private func waitUntil(
    _ label: String,
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LabeledTimeoutError(label: label)
}

private struct TimeoutError: Error {}
private struct LabeledTimeoutError: Error, CustomStringConvertible {
    let label: String
    var description: String { "timeout: \(label)" }
}

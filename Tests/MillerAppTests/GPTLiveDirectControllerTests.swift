import Foundation
import MillerCore
import MillerLive
import MillerLiveAudio
import Testing
@testable import MillerApp

@MainActor
struct GPTLiveDirectControllerTests {
    @Test
    func noHelperSelectsDirectGPTLiveAndKeepsPeerLifecycleBounded() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let peer = DirectControllerPeer()
        let socket = DirectControllerSocket()
        let credentialLoads = DirectControllerCounter()
        let credentialAdmission = DirectControllerCredentialAdmission()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                await credentialLoads.increment()
                await credentialAdmission.record(.load)
                return envelope
            }),
            refreshCredential: {
                await credentialAdmission.record(.refresh)
            },
            microphonePermission: { .authorized },
            makePeer: { peer },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(
                    peer: peer,
                    callCreator: GPTLiveCallCreator(loader: DirectControllerLoader()),
                    sidebandConnector: GPTLiveSidebandConnector(
                        factory: { _, _ in socket },
                        sleep: { _ in }
                    ),
                    configuration: configuration
                )
            }
        )
        #expect(await controller.availability() == .available)
        #expect(await credentialLoads.value == 0)
        let dependencies = controller.dependencies()
        let states = DirectControllerStateProbe()
        let run = Task {
            try? await dependencies.start(LiveVoiceStartContext.manual) { event in
                if case let .state(state) = event {
                    states.append(state)
                }
            }
        }

        try await waitUntilDirectController { states.contains(.listening) }
        await dependencies.end()
        await run.value

        #expect(peer.operations == [.prepare, .answer, .close])
        #expect(states.valuesSnapshot == [.connecting, .listening])
        #expect(await credentialLoads.value == 1)
        #expect(await credentialAdmission.events == [.refresh, .load])
    }

    @Test
    func directFactoryReceivesWakeInstructionOnlyForWakeStarts() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let configurations = DirectControllerConfigurationRecorder()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            makePeer: { DirectControllerPeer(failPrepare: true) },
            makeDirectSession: { peer, configuration in
                configurations.record(configuration)
                return DirectGPTLiveSession(peer: peer, configuration: configuration)
            }
        )

        let dependencies = controller.dependencies()
        try? await dependencies.start(LiveVoiceStartContext.wakeword) { _ in }
        try? await dependencies.start(LiveVoiceStartContext.manual) { _ in }

        let values = configurations.values
        #expect(values.count == 2)
        #expect(values[0].instructions.contains(
            GPTLiveSessionInstructions.wakeAcknowledgement
        ))
        #expect(values[1].instructions.contains(
            GPTLiveSessionInstructions.wakeAcknowledgement
        ) == false)
    }

    @Test
    func endCancelsAStalledCredentialRefresh() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let refresh = DirectControllerRefreshGate()
        let stop = DirectControllerCompletionProbe()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                throw GPTLiveCredentialError.invalidCredential
            }),
            refreshCredential: { await refresh.wait() },
            microphonePermission: { .authorized },
            makePeer: { DirectControllerPeer() },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(peer: peer, configuration: configuration)
            }
        )
        let dependencies = controller.dependencies()
        let run = Task {
            try? await dependencies.start(LiveVoiceStartContext.manual) { _ in }
        }
        try await waitUntilDirectControllerAsync { await refresh.entered }

        let end = Task {
            await dependencies.end()
            await stop.complete()
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await stop.completed)

        await refresh.release()
        await end.value
        await run.value
    }

    @Test
    func stalledCredentialRefreshTimesOut() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let refresh = DirectControllerRefreshGate()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                throw GPTLiveCredentialError.invalidCredential
            }),
            refreshCredential: { await refresh.wait() },
            microphonePermission: { .authorized },
            credentialRefreshTimeout: .milliseconds(20),
            makePeer: { DirectControllerPeer() },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(peer: peer, configuration: configuration)
            }
        )
        let dependencies = controller.dependencies()
        let result = await Task {
            do {
                try await dependencies.start(LiveVoiceStartContext.manual) { _ in }
                return false
            } catch let error as LiveProcessError {
                return error == .timeout
            } catch {
                return false
            }
        }.value

        #expect(result)
        await refresh.release()
    }

    @Test
    func failedCredentialRefreshStopsAdmissionBeforeCredentialLoad() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let credentialLoads = DirectControllerCounter()
        let peer = DirectControllerPeer()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                await credentialLoads.increment()
                throw GPTLiveCredentialError.invalidCredential
            }),
            refreshCredential: { throw DirectControllerRefreshFailure() },
            microphonePermission: { .authorized },
            makePeer: { peer },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(peer: peer, configuration: configuration)
            }
        )

        await #expect(throws: DirectControllerRefreshFailure.self) {
            try await controller.dependencies().start(LiveVoiceStartContext.manual) { _ in }
        }
        #expect(await credentialLoads.value == 0)
        #expect(peer.operations.isEmpty)
    }
}

private actor DirectControllerCredentialAdmission {
    enum Event: Equatable, Sendable { case refresh, load }

    private(set) var events: [Event] = []

    func record(_ event: Event) { events.append(event) }
}

private final class DirectControllerConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values = [GPTLiveConfiguration]()

    func record(_ configuration: GPTLiveConfiguration) {
        lock.withLock { values.append(configuration) }
    }
}

@MainActor
private final class DirectControllerPeer: LiveAudioPeer {
    enum Operation: Equatable { case prepare, answer, close }
    private(set) var operations: [Operation] = []
    private let failPrepare: Bool

    nonisolated init(failPrepare: Bool = false) {
        self.failPrepare = failPrepare
    }

    func prepareOffer() async throws -> String {
        if failPrepare { throw DirectControllerPeerFailure.prepare }
        operations.append(.prepare)
        return "v=0\r\ns=-\r\n"
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        operations.append(.answer)
    }

    func setMuted(_ muted: Bool) async throws {}
    func close() async { operations.append(.close) }
}

private enum DirectControllerPeerFailure: Error {
    case prepare
}

private final class DirectControllerLoader: GPTLiveURLLoading, @unchecked Sendable {
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            Data("v=0\r\ns=-\r\n".utf8),
            HTTPURLResponse(
                url: URL(string: "https://api.openai.com/v1/live")!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Location": "/v1/live/rtc_controller"]
            )!
        )
    }
}

private final class DirectControllerSocket: GPTLiveWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<GPTLiveWebSocketMessage, Error>] = []
    private var closed = false

    func open() async throws {}

    func receive() async throws -> GPTLiveWebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: GPTLiveSidebandError.closed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func send(_ text: String) async throws {}

    func close() {
        lock.lock()
        closed = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(throwing: GPTLiveSidebandError.closed) }
    }
}

@MainActor
private final class DirectControllerStateProbe {
    private(set) var values: [LiveVoiceState] = []
    func append(_ value: LiveVoiceState) { values.append(value) }
    func contains(_ value: LiveVoiceState) -> Bool { values.contains(value) }
    var valuesSnapshot: [LiveVoiceState] { values }
}

private func waitUntilDirectController(
    _ predicate: @escaping @MainActor @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await MainActor.run(body: predicate) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DirectControllerTimeout()
}

private func waitUntilDirectControllerAsync(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DirectControllerTimeout()
}

private struct DirectControllerTimeout: Error {}

private struct DirectControllerRefreshFailure: Error {}

private actor DirectControllerCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor DirectControllerRefreshGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DirectControllerCompletionProbe {
    private(set) var completed = false
    func complete() { completed = true }
}

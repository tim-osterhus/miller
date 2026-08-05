import Foundation
import MillerLive
import Testing
@testable import MillerLiveAudio

@MainActor
struct WebRTCLiveAudioSessionTests {
    @Test
    func preparesOfferBeforeStartingHelperAndConnectsBeforeActive() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let marker = repository.appendingPathComponent(
            ".artifacts/webrtc-offer-order-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let peer = FakeLiveAudioPeer()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "record-helper-launch",
                marker.path,
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(client: CodexAppServerClient(process: process), peer: peer)
        let active = ActiveCallRecorder()

        let run = Task {
            try await session.run(
                identity: .init(requestID: "offer-order", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                onActive: { await active.record() },
                onCleanupPending: {},
                receive: { _ in }
            )
        }

        try await waitUntil { await peer.didStartPreparing }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        peer.finishPreparing()
        try await run.value

        #expect(peer.operations == [.prepare, .answer, .close])
        #expect(await active.count == 1)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func ignoresLateMuteAfterThePeerIsClosed() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let marker = repository.appendingPathComponent(
            ".artifacts/late-mute-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let peer = FakeLiveAudioPeer()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "record-helper-launch",
                marker.path,
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(client: CodexAppServerClient(process: process), peer: peer)
        let run = Task {
            try await session.run(
                identity: .init(requestID: "late-mute", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                receive: { _ in }
            )
        }

        try await waitUntil { await peer.didStartPreparing }
        peer.finishPreparing()
        try await run.value
        await session.setMuted(true)

        #expect(peer.operations == [.prepare, .answer, .close])
    }

    @Test
    func cancellationClosesThePreparingPeerBeforeItCanStartTheHelper() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let peer = FakeLiveAudioPeer()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "hang",
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(client: CodexAppServerClient(process: process), peer: peer)
        let run = Task<Result<Void, Error>, Never> {
            do {
                try await session.run(
                    identity: .init(requestID: "cancel", threadID: "thread-1", generation: 1),
                    credential: .init(
                        accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                    ),
                    permission: .authorized,
                    receive: { _ in }
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        try await waitUntil { await peer.didStartPreparing }
        run.cancel()
        let closedBeforeOffer = await eventually {
            await peer.operations.contains(.close)
        }
        peer.finishPreparing()
        _ = await run.value

        #expect(closedBeforeOffer)
        #expect(peer.operations == [.prepare, .close])
        #expect(!process.isRunning)
    }

    @Test(arguments: [LiveAudioPeerError.invalidAnswer, .connectionFailed])
    func answerOrConnectionFailurePreventsActiveAndClosesOnce(
        failure: LiveAudioPeerError
    ) async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let peer = FakeLiveAudioPeer(answerFailure: failure)
        let active = ActiveCallRecorder()
        let captureDriver = WebRTCCaptureDriver()
        let playbackDriver = WebRTCPlaybackDriver()
        let marker = repository.appendingPathComponent(
            ".artifacts/failed-answer-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "record-helper-launch",
                marker.path,
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(
            client: CodexAppServerClient(process: process),
            peer: peer,
            capture: LiveAudioCapture(driver: captureDriver),
            playback: LiveAudioPlayback(driver: playbackDriver)
        )
        let run = Task<Result<Void, Error>, Never> {
            do {
                try await session.run(
                    identity: .init(requestID: "failed-answer", threadID: "thread-1", generation: 1),
                    credential: .init(
                        accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                    ),
                    permission: .authorized,
                    onActive: { await active.record() },
                    onCleanupPending: {},
                    receive: { _ in }
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        try await waitUntil { await peer.didStartPreparing }
        peer.finishPreparing()
        let result = await run.value

        #expect(result.failure as? LiveAudioPeerError == failure)
        #expect(await active.count == 0)
        #expect(peer.operations == [.prepare, .answer, .close])
        #expect(await captureDriver.starts == 0)
        #expect(await playbackDriver.plays == 0)
        #expect(await playbackDriver.interrupts == 0)
        #expect(!process.isRunning)
    }

    @Test
    func muteUnmuteAndEndUseOnlyThePeerTrack() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let peer = FakeLiveAudioPeer()
        let captureDriver = WebRTCCaptureDriver()
        let playbackDriver = WebRTCPlaybackDriver()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "wait-stop",
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(
            client: CodexAppServerClient(process: process),
            peer: peer,
            capture: LiveAudioCapture(driver: captureDriver),
            playback: LiveAudioPlayback(driver: playbackDriver)
        )
        let run = Task {
            try await session.run(
                identity: .init(requestID: "mute", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                receive: { _ in }
            )
        }

        try await waitUntil { await peer.didStartPreparing }
        peer.finishPreparing()
        try await waitUntil { await peer.operations.contains(.answer) }
        await session.setMuted(true)
        await session.setMuted(false)
        await session.end()
        try await run.value

        #expect(peer.operations == [.prepare, .answer, .mute(true), .mute(false), .close])
        #expect(await captureDriver.starts == 0)
        #expect(await playbackDriver.plays == 0)
        #expect(await playbackDriver.interrupts == 0)
        #expect(!process.isRunning)
    }

    @Test
    func muteFailureTerminatesTheSessionAndStopsTheHelperExactlyOnce() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let marker = repository.appendingPathComponent(
            ".artifacts/mute-failure-stop-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let peer = FakeLiveAudioPeer(muteFailure: .connectionFailed)
        let active = ActiveCallRecorder()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "stop-on-sdp",
                marker.path,
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(client: CodexAppServerClient(process: process), peer: peer)
        let run = Task<Result<Void, Error>, Never> {
            do {
                try await session.run(
                    identity: .init(requestID: "mute-failure", threadID: "thread-1", generation: 1),
                    credential: .init(
                        accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                    ),
                    permission: .authorized,
                    onActive: { await active.record() },
                    onCleanupPending: {},
                    receive: { _ in }
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        try await waitUntil { await peer.didStartPreparing }
        peer.finishPreparing()
        try await waitUntil { await peer.operations.contains(.answer) }
        try await waitUntil { await active.count == 1 }
        await session.setMuted(true)
        let result = await run.value

        #expect(result.failure as? LiveAudioPeerError == .connectionFailed)
        #expect(await active.count == 1)
        #expect(peer.operations == [.prepare, .answer, .mute(true), .close])
        #expect(try String(contentsOf: marker, encoding: .utf8) == "stop\n")
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func postAdmissionPeerLossTerminatesTheSessionAndStopsTheHelperExactlyOnce() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let marker = repository.appendingPathComponent(
            ".artifacts/peer-loss-stop-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let peer = ConnectionLossLiveAudioPeer()
        let active = ActiveCallRecorder()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "stop-on-sdp",
                marker.path,
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(client: CodexAppServerClient(process: process), peer: peer)
        let run = Task<Result<Void, Error>, Never> {
            do {
                try await session.run(
                    identity: .init(requestID: "peer-loss", threadID: "thread-1", generation: 1),
                    credential: .init(
                        accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                    ),
                    permission: .authorized,
                    onActive: { await active.record() },
                    onCleanupPending: {},
                    receive: { _ in }
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        try await waitUntil { await peer.didStartPreparing }
        peer.finishPreparing()
        try await waitUntil { await active.count == 1 }
        try await waitUntil { await peer.isMonitoringConnection }
        peer.failConnection()
        let result = await run.value

        #expect(result.failure as? LiveAudioPeerError == .connectionFailed)
        #expect(await active.count == 1)
        #expect(peer.operations == [.prepare, .answer, .monitor, .close])
        #expect(try String(contentsOf: marker, encoding: .utf8) == "stop\n")
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func deniedPeerAdmissionDoesNotBeginTheConnectionMonitor() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let marker = repository.appendingPathComponent(
            ".artifacts/denied-peer-admission-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let identity = LiveSessionIdentity(
            requestID: "denied-peer-admission", threadID: "thread-1", generation: 1
        )
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "stop-on-sdp",
                marker.path,
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let client = CodexAppServerClient(process: process)
        let peer = ConnectionLossLiveAudioPeer(onAnswer: {
            _ = try? client.requestStop(identity: identity)
        })
        let session = LiveAudioSession(client: client, peer: peer)

        let run = Task {
            try await session.run(
                identity: identity,
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                receive: { _ in }
            )
        }
        try await waitUntil { await peer.didStartPreparing }
        peer.finishPreparing()
        try await run.value

        #expect(peer.operations == [.prepare, .answer, .close])
        #expect(try String(contentsOf: marker, encoding: .utf8) == "stop\n")
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func normalEndFencesALatePeerMonitorFailure() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let peer = ConnectionLossLiveAudioPeer()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "wait-stop",
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(client: CodexAppServerClient(process: process), peer: peer)
        let active = ActiveCallRecorder()
        let run = Task {
            try await session.run(
                identity: .init(requestID: "normal-end", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                onActive: { await active.record() },
                onCleanupPending: {},
                receive: { _ in }
            )
        }

        try await waitUntil { await peer.didStartPreparing }
        peer.finishPreparing()
        try await waitUntil { await active.count == 1 }
        try await waitUntil { await peer.isMonitoringConnection }
        await session.end()
        try await run.value
        try await waitUntil { !(await peer.isMonitoringConnection) }
        peer.failConnection()
        try await Task.sleep(for: .milliseconds(20))

        #expect(peer.operations == [.prepare, .answer, .monitor, .close])
        #expect(peer.lateFailureSignals == 1)
        #expect(await active.count == 1)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func sidebandAudioIsOnlyForwardedAsACueAndInterruptClosesOnce() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let peer = FakeLiveAudioPeer()
        let events = SidebandEventRecorder()
        let captureDriver = WebRTCCaptureDriver()
        let playbackDriver = WebRTCPlaybackDriver()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                repository.appendingPathComponent(
                    "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
                ).path,
                "wait-output",
            ],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let client = CodexAppServerClient(process: process)
        let session = LiveAudioSession(
            client: client,
            peer: peer,
            capture: LiveAudioCapture(driver: captureDriver),
            playback: LiveAudioPlayback(driver: playbackDriver)
        )
        let run = Task {
            try await session.run(
                identity: .init(requestID: "sideband", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                receive: { event in await events.record(event) }
            )
        }

        try await waitUntil { await peer.didStartPreparing }
        peer.finishPreparing()
        try await waitUntil { await events.sidebandCount == 1 }
        await session.interrupt()
        try await run.value

        #expect(peer.operations == [.prepare, .answer, .close])
        #expect(await captureDriver.starts == 0)
        #expect(await playbackDriver.plays == 0)
        #expect(await playbackDriver.interrupts == 0)
        #expect(client.unacknowledgedAudioCount == 0)
        #expect(!process.isRunning)
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw LiveAudioError.captureFailed }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func eventually(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private actor ActiveCallRecorder {
    private(set) var count = 0

    func record() { count += 1 }
}

private actor SidebandEventRecorder {
    private(set) var sidebandCount = 0

    func record(_ event: LiveSessionEvent) {
        if case .outputAudio = event { sidebandCount += 1 }
    }
}

private actor WebRTCCaptureDriver: LiveAudioCaptureDriving {
    private(set) var starts = 0

    func start(
        _ receive: @escaping @Sendable (Result<Data, Error>) -> Void
    ) async throws {
        starts += 1
    }

    func stop() async {}
}

private actor WebRTCPlaybackDriver: LiveAudioPlaybackDriving {
    private(set) var plays = 0
    private(set) var interrupts = 0

    func play(_ frame: LiveAudioFrame) async throws { plays += 1 }
    func interrupt() async { interrupts += 1 }
}

private let syntheticOffer = """
v=0\r
o=- 0 0 IN IP4 0.0.0.0\r
s=-\r
t=0 0\r
a=group:BUNDLE 0 1\r
m=audio 9 UDP/TLS/RTP/SAVPF 111\r
a=mid:0\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r
a=setup:actpass\r
a=rtpmap:111 opus/48000/2\r
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
a=mid:1\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r
a=setup:actpass\r
a=sctp-port:5000\r
a=max-message-size:262144\r
"""

private extension Result where Success == Void, Failure == Error {
    var failure: Error? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

@MainActor
private final class FakeLiveAudioPeer: LiveAudioPeer {
    enum Operation: Equatable, Sendable {
        case prepare
        case answer
        case mute(Bool)
        case close
    }

    private var preparing = false
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private(set) var operations: [Operation] = []
    private let answerFailure: LiveAudioPeerError?
    private let muteFailure: LiveAudioPeerError?

    init(
        answerFailure: LiveAudioPeerError? = nil,
        muteFailure: LiveAudioPeerError? = nil
    ) {
        self.answerFailure = answerFailure
        self.muteFailure = muteFailure
    }

    var didStartPreparing: Bool { preparing }

    func prepareOffer() async throws -> String {
        preparing = true
        operations.append(.prepare)
        await withCheckedContinuation { prepareContinuation = $0 }
        return syntheticOffer
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        operations.append(.answer)
        if let answerFailure { throw answerFailure }
    }

    func setMuted(_ muted: Bool) async throws {
        operations.append(.mute(muted))
        if let muteFailure { throw muteFailure }
    }

    func close() async {
        operations.append(.close)
    }

    func finishPreparing() {
        prepareContinuation?.resume()
        prepareContinuation = nil
    }
}

@MainActor
private final class ConnectionLossLiveAudioPeer: LiveAudioPeer, LiveAudioPeerConnectionMonitoring {
    enum Operation: Equatable, Sendable {
        case prepare
        case answer
        case monitor
        case close
    }

    private var preparing = false
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private var connectionLossContinuation: CheckedContinuation<Void, Error>?
    private(set) var operations: [Operation] = []
    private(set) var lateFailureSignals = 0
    private let onAnswer: (@MainActor () -> Void)?

    init(onAnswer: (@MainActor () -> Void)? = nil) {
        self.onAnswer = onAnswer
    }

    var didStartPreparing: Bool { preparing }
    var isMonitoringConnection: Bool { connectionLossContinuation != nil }

    func prepareOffer() async throws -> String {
        preparing = true
        operations.append(.prepare)
        await withCheckedContinuation { prepareContinuation = $0 }
        return syntheticOffer
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        operations.append(.answer)
        onAnswer?()
    }

    func setMuted(_ muted: Bool) async throws {}

    func waitForConnectionFailure() async throws {
        operations.append(.monitor)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                connectionLossContinuation = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelConnectionMonitor() }
        })
    }

    func close() async {
        operations.append(.close)
    }

    func finishPreparing() {
        prepareContinuation?.resume()
        prepareContinuation = nil
    }

    func failConnection() {
        guard let connectionLossContinuation else {
            lateFailureSignals += 1
            return
        }
        connectionLossContinuation.resume(throwing: LiveAudioPeerError.connectionFailed)
        self.connectionLossContinuation = nil
    }

    private func cancelConnectionMonitor() {
        connectionLossContinuation?.resume(throwing: CancellationError())
        connectionLossContinuation = nil
    }
}

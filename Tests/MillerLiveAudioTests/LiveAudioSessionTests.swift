import Foundation
import MillerLive
import Testing
@testable import MillerLiveAudio

struct LiveAudioSessionTests {
    @Test
    func missingPeerFailsClosedWithoutTouchingLegacyAudio() async throws {
        let captureDriver = CountingCaptureDriver()
        let playbackDriver = CountingPlaybackDriver()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [],
            temporaryParentURL: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(
            client: CodexAppServerClient(process: process),
            capture: LiveAudioCapture(driver: captureDriver),
            playback: LiveAudioPlayback(driver: playbackDriver)
        )

        await #expect(throws: LiveAudioPeerError.unavailable) {
            try await session.run(
                identity: .init(requestID: "missing-peer", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                receive: { _ in }
            )
        }

        #expect(await captureDriver.starts == 0)
        #expect(await playbackDriver.plays == 0)
        #expect(await playbackDriver.interrupts == 0)
        #expect(!process.isRunning)
    }

    @Test
    func webRTCEntryRequiresAuthorizedPermissionBeforePreparingThePeer() async throws {
        let peer = PermissionTestPeer()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [],
            temporaryParentURL: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(
            client: CodexAppServerClient(process: process),
            peer: peer
        )

        await #expect(throws: LiveAudioError.permissionDenied) {
            try await session.run(
                identity: .init(requestID: "permission", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .denied,
                receive: { _ in }
            )
        }

        #expect(await peer.prepareCalls == 0)
        #expect(!process.isRunning)
    }

    @Test @MainActor
    func omittedResponseRequestFailsClosed() async {
        let peer = OmittedResponsePeer()

        await #expect(throws: LiveAudioPeerError.unavailable) {
            try await peer.requestResponse()
        }
    }

    @Test @MainActor
    func stoppingInFlightWakeResponseFencesTheLateHelperPeerSend() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repository.appendingPathComponent(
            "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
        )
        let peer = BlockingResponseSessionPeer()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, "wait-stop"],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(
            client: CodexAppServerClient(process: process),
            peer: peer
        )
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "helper-stop-in-flight", threadID: "thread", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                requestInitialResponse: true,
                receive: { _ in }
            )
        }

        try await waitUntilLiveAudioSession { peer.responseStarted }
        let ending = Task { await session.end() }
        try await waitUntilLiveAudioSession { peer.responseInvalidationCount == 1 }
        peer.releaseResponse()
        await ending.value
        await run.value

        #expect(peer.responseSent == false)
        #expect(peer.responseInvalidationCount == 1)
    }

    @Test @MainActor
    func wakeHelperSessionRequestsExactlyOneResponseAfterPeerConnection() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repository.appendingPathComponent(
            "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
        )
        let peer = PermissionTestPeer()
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, "wait-stop"],
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(
            client: CodexAppServerClient(process: process),
            peer: peer
        )
        let run = Task {
            try? await session.run(
                identity: .init(requestID: "wake-response", threadID: "thread", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                permission: .authorized,
                requestInitialResponse: true,
                receive: { _ in }
            )
        }

        try await waitUntilLiveAudioSession { peer.operations.contains(.response) }
        await session.end()
        await run.value

        #expect(peer.operations == [.prepare, .answer, .response, .close])
    }

    @Test
    func permissionStatesRemainTruthfulForTheLegacyCaptureGroundwork() {
        #expect(!MicrophonePermission.notDetermined.mayRequestCapture)
        #expect(MicrophonePermission.authorized.mayRequestCapture)
        #expect(!MicrophonePermission.denied.mayRequestCapture)
        #expect(!MicrophonePermission.restricted.mayRequestCapture)
    }

    @Test
    func outputValidationRequiresPCM16LittleEndianMetadata() throws {
        #expect(throws: (any Error).self) {
            _ = try LiveAudioFrame(
                data: Data([0]),
                sampleRate: 24_000,
                numChannels: 1,
                samplesPerChannel: 1,
                itemID: nil
            )
        }
        #expect(throws: (any Error).self) {
            _ = try LiveAudioFrame(
                data: Data([0, 0]),
                sampleRate: 0,
                numChannels: 1,
                samplesPerChannel: 1,
                itemID: nil
            )
        }
    }
}

private actor CountingCaptureDriver: LiveAudioCaptureDriving {
    private(set) var starts = 0

    func start(
        _ receive: @escaping @Sendable (Result<Data, Error>) -> Void
    ) async throws {
        starts += 1
    }

    func stop() async {}
}

private actor CountingPlaybackDriver: LiveAudioPlaybackDriving {
    private(set) var plays = 0
    private(set) var interrupts = 0

    func play(_ frame: LiveAudioFrame) async throws { plays += 1 }
    func interrupt() async { interrupts += 1 }
}

@MainActor
private final class PermissionTestPeer: LiveAudioPeer {
    enum Operation: Equatable { case prepare, answer, response, close }
    private(set) var prepareCalls = 0
    private(set) var operations = [Operation]()

    nonisolated init() {}

    func prepareOffer() async throws -> String {
        prepareCalls += 1
        operations.append(.prepare)
        return liveAudioSessionSyntheticOffer
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        operations.append(.answer)
    }
    func requestResponse() async throws { operations.append(.response) }
    func setMuted(_ muted: Bool) async throws {}
    func close() async { operations.append(.close) }
}

@MainActor
private final class OmittedResponsePeer: LiveAudioPeer {
    nonisolated init() {}

    func prepareOffer() async throws -> String { liveAudioSessionSyntheticOffer }
    func applyAnswerAndWaitForConnected(_ answer: String) async throws {}
    func setMuted(_ muted: Bool) async throws {}
    func close() async {}
}

@MainActor
private final class BlockingResponseSessionPeer: LiveAudioPeerResponseFencing {
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private(set) var responseStarted = false
    private(set) var responseSent = false
    private(set) var responseInvalidationCount = 0
    private var responseInvalidated = false

    func prepareOffer() async throws -> String { liveAudioSessionSyntheticOffer }
    func applyAnswerAndWaitForConnected(_ answer: String) async throws {}
    func requestResponse() async throws {
        responseStarted = true
        await withCheckedContinuation { responseContinuation = $0 }
        if !responseInvalidated {
            responseSent = true
        }
    }
    func requestResponse(for generation: UInt64) async throws {
        try await requestResponse()
    }
    func cancelResponseRequest(for generation: UInt64) async {
        guard !responseInvalidated else { return }
        responseInvalidated = true
        responseInvalidationCount += 1
    }
    func setMuted(_ muted: Bool) async throws {}
    func close() async {}
    func releaseResponse() {
        responseContinuation?.resume()
        responseContinuation = nil
    }
}

@MainActor
private func waitUntilLiveAudioSession(
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LiveAudioPeerError.connectionFailed
}

private let liveAudioSessionSyntheticOffer = """
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

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
    private(set) var prepareCalls = 0

    nonisolated init() {}

    func prepareOffer() async throws -> String {
        prepareCalls += 1
        return "v=0\r\ns=-\r\n"
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {}
    func setMuted(_ muted: Bool) async throws {}
    func close() async {}
}

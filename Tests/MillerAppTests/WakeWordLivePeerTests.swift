import Foundation
import MillerLiveAudio
import MillerWake
import Testing
@testable import MillerApp

@Suite("Wakeword Live handoff")
struct WakeWordLivePeerTests {
    @Test @MainActor
    func preparedCommandAudioIsInjectedOnceAfterThePeerConnects() async throws {
        let evaluator = PreparedAudioEvaluator()
        let peer = WebKitLivePeer(evaluator: evaluator)
        _ = try await peer.prepareOffer()
        let audio = WakeWordPreparedCommandAudio(
            id: UUID(),
            generation: 1,
            samples: ContiguousArray([1, 2, 3]),
            sampleRate: 16_000
        )

        try await peer.preparePreparedCommandAudio(audio)
        try await peer.applyAnswerAndWaitForConnected("v=0\r\n")
        await #expect(throws: LiveAudioPeerError.invalidState) {
            try await peer.preparePreparedCommandAudio(audio)
        }

        #expect(evaluator.injected == [audio])
    }

    @Test @MainActor
    func webKitPeerMixesThePreparedPCMIntoItsExistingOutboundTrack() {
        #expect(WebKitLivePeer.localHTML.contains("createMediaStreamDestination"))
        #expect(WebKitLivePeer.localHTML.contains("injectPreparedCommandAudio"))
        #expect(WebKitLivePeer.localHTML.contains("createBuffer"))
    }
}

@MainActor
private final class PreparedAudioEvaluator:
    WebKitLivePeerScriptEvaluating,
    WebKitLivePeerPreparedAudioEvaluating
{
    private(set) var injected = [WakeWordPreparedCommandAudio]()

    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String {
        switch operation {
        case .prepareOffer:
            "v=0\r\n"
        case .applyAnswer:
            answer == "v=0\r\n" ? "connected" : "failed"
        case .setMuted, .connectionState, .close:
            "ok"
        }
    }

    func injectPreparedAudio(_ audio: WakeWordPreparedCommandAudio) async throws {
        injected.append(audio)
    }
}

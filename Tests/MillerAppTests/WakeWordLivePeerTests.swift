import Foundation
import MillerLiveAudio
import Testing
@testable import MillerApp

@Suite("Wakeword Live microphone")
struct WakeWordLivePeerTests {
    @Test @MainActor
    func ordinaryMicrophonePeerConnectsWithoutPreparedAudioInjection() async throws {
        let evaluator = OrdinaryLiveEvaluator()
        let peer = WebKitLivePeer(evaluator: evaluator)

        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\n")
        try await peer.setMuted(true)
        await peer.close()

        #expect(evaluator.operations == [
            .prepareOffer,
            .applyAnswer,
            .setMuted(true),
            .close,
        ])
    }

    @Test @MainActor
    func webKitPeerContainsOnlyOrdinaryMicrophoneMixingPlumbing() {
        #expect(WebKitLivePeer.localHTML.contains("getUserMedia"))
        #expect(WebKitLivePeer.localHTML.contains("createMediaStreamDestination"))
        #expect(!WebKitLivePeer.localHTML.contains("injectPreparedCommandAudio"))
        #expect(!WebKitLivePeer.localHTML.contains("createBuffer"))
        #expect(!WebKitLivePeer.localHTML.contains("base64"))
    }
}

@MainActor
private final class OrdinaryLiveEvaluator: WebKitLivePeerScriptEvaluating {
    private(set) var operations = [WebKitLivePeerScriptOperation]()

    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String {
        operations.append(operation)
        switch operation {
        case .prepareOffer:
            return "v=0\r\n"
        case .applyAnswer:
            return answer == "v=0\r\n" ? "connected" : "failed"
        case .setMuted, .close:
            return "ok"
        case .connectionState:
            return "connected"
        }
    }
}

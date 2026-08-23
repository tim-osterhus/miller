import AppKit
import Foundation
import MillerLiveAudio
import Testing
@testable import MillerApp

@MainActor
struct WebKitLivePeerContractTests {
    @Test
    func installedPeerHostDoesNotInstantiateAWebKitPeerBeforeAnExplicitLiveStart() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        let overlayContent = NSView(frame: container.bounds)
        container.addSubview(overlayContent)
        let factory = PeerFactoryProbe()
        let host = OverlayLiveVoicePeerHost(makePeer: { factory.makePeer() })

        host.install(overlayContent: overlayContent, in: container)

        #expect(factory.calls == 0)
        #expect(!host.isPeerAttached)
    }

    @Test
    func attachedPeerHostKeepsThePeerVisibleButNoninteractiveAndRemovesItAfterCleanup() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        let overlayContent = NSView(frame: container.bounds)
        container.addSubview(overlayContent)
        let peerView = NSView(frame: .zero)
        let peer = WebKitLivePeer(
            evaluator: FakeScriptEvaluator(results: [:]),
            peerView: peerView
        )
        let host = OverlayLiveVoicePeerHost(makePeer: { peer })
        host.install(overlayContent: overlayContent, in: container)

        let attached = try host.makePeer()

        #expect(attached === peer)
        #expect(host.isPeerAttached)
        #expect(peerView.superview === container)
        #expect(!peerView.isHidden)
        #expect(peerView.alphaValue > 0)
        #expect(!peerView.isAccessibilityElement())
        #expect(container.subviews.last === overlayContent)

        host.removePeer()

        #expect(!host.isPeerAttached)
        #expect(peerView.superview == nil)
    }

    @Test
    func localPageCreatesOnlyTheRequiredAudioPeerPrimitives() {
        let html = WebKitLivePeer.localHTML

        #expect(WebKitLivePeer.baseOrigin.absoluteString == "https://miller.invalid/")
        #expect(html.contains("new RTCPeerConnection()"))
        #expect(html.contains("getUserMedia({ audio: true, video: false })"))
        #expect(html.contains("createDataChannel(\"oai-events\")"))
        #expect(html.contains("channel.readyState === \"open\""))
        #expect(html.contains("JSON.stringify({type: \"response.create\"})"))
        #expect(html.contains("createOffer()"))
        #expect(html.contains("setLocalDescription(offer)"))
        #expect(html.contains("setRemoteDescription"))
        #expect(html.contains("track.enabled = !muted"))
        #expect(html.contains("createMediaStreamSource(remoteStream)"))
        #expect(html.contains("createAnalyser()"))
        #expect(html.components(separatedBy: "createAnalyser()").count - 1 == 1)
        #expect(html.contains("outputSource.connect(outputAnalyser)"))
        #expect(!html.contains("microphoneSource.connect(outputAnalyser)"))
        #expect(html.contains("globalThis.millerLipSyncAnalysis"))
        #expect(html.contains("millerLipSyncAnalysis.classify"))
        #expect(html.contains("outputAnalyser.fftSize = 2048"))
        #expect(html.contains("getFloatTimeDomainData"))
        #expect(html.contains("getByteFrequencyData"))
        #expect(html.components(separatedBy: "new Float32Array").count - 1 == 1)
        #expect(html.components(separatedBy: "new Uint8Array").count - 1 == 1)
        #expect(html.contains("outputTimeDomain = null"))
        #expect(html.contains("outputFrequencyDomain = null"))
        #expect(html.contains("vowels = null"))
        #expect(html.contains("outputSample()"))
        #expect(html.contains("output_audio_buffer.started"))
        #expect(html.contains("output_audio_buffer.stopped"))
        #expect(html.contains("output_audio_buffer.cleared"))
        #expect(html.contains("outputBufferActive"))
        #expect(html.contains("outputSource.disconnect()"))
        #expect(html.contains("outputAnalyser.disconnect()"))
        #expect(!html.contains("createMediaStreamSource(localStream).connect"))
        #expect(html.contains("audio.srcObject = null"))
        #expect(!html.contains("<form"))
        #expect(!html.contains("<iframe"))
        #expect(!html.contains("src=\"http"))
        #expect(!html.contains("window.open"))
    }

    @Test
    func outputSampleDecodingPreservesScalarPlaybackWhenVowelsAreAbsentOrInvalid() async throws {
        let payloads = [
            "{\"isPlaying\":true,\"outputBufferActive\":true,\"offsetMilliseconds\":12,\"envelope\":0.5}",
            "{\"isPlaying\":true,\"outputBufferActive\":true,\"offsetMilliseconds\":12,\"envelope\":0.5,\"vowels\":{\"aa\":0.1}}",
            "{\"isPlaying\":true,\"outputBufferActive\":true,\"offsetMilliseconds\":12,\"envelope\":0.5,\"vowels\":{\"aa\":2,\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5}}",
            "{\"isPlaying\":true,\"outputBufferActive\":true,\"offsetMilliseconds\":12,\"envelope\":0.5,\"vowels\":{\"aa\":\"NaN\",\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5}}",
            "{\"isPlaying\":true,\"outputBufferActive\":true,\"offsetMilliseconds\":12,\"envelope\":0.5,\"vowels\":{\"aa\":1e400,\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5}}",
        ]

        for payload in payloads {
            let evaluator = FakeScriptEvaluator(results: [
                .prepareOffer: syntheticOffer,
                .applyAnswer: "connected",
                .outputSample: payload,
                .close: "ok",
            ])
            let peer = WebKitLivePeer(evaluator: evaluator)
            _ = try await peer.prepareOffer()
            try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")

            let stream = peer.outputSamples()
            let sample = await Task<LiveAudioOutputSample?, Never> { @MainActor in
                for await sample in stream {
                    return sample
                }
                return nil
            }.value

            let requiredSample = try #require(sample)
            #expect(requiredSample.isPlaying)
            #expect(requiredSample.outputBufferActive == true)
            #expect(requiredSample.offsetMilliseconds == 12)
            #expect(requiredSample.envelope == 0.5)
            #expect(requiredSample.vowels == nil)
            await peer.close()
        }
    }

    @Test
    func outputSampleDecodingAcceptsACompleteBoundedVowelObject() async throws {
        let evaluator = FakeScriptEvaluator(results: [
            .prepareOffer: syntheticOffer,
            .applyAnswer: "connected",
            .outputSample: "{\"isPlaying\":true,\"outputBufferActive\":true,\"offsetMilliseconds\":12,\"envelope\":0.5,\"vowels\":{\"aa\":0.1,\"ih\":0.2,\"ou\":0.3,\"ee\":0.4,\"oh\":0.5}}",
            .close: "ok",
        ])
        let peer = WebKitLivePeer(evaluator: evaluator)
        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")

        let stream = peer.outputSamples()
        let sample = await Task<LiveAudioOutputSample?, Never> { @MainActor in
            for await sample in stream {
                return sample
            }
            return nil
        }.value

        #expect(sample?.vowels == AvatarVowelWeights(
            aa: 0.1,
            ih: 0.2,
            ou: 0.3,
            ee: 0.4,
            oh: 0.5
        ))
        #expect(sample?.envelope == 0.5)
        #expect(sample?.isPlaying == true)
        #expect(sample?.offsetMilliseconds == 12)
        await peer.close()
    }

    @Test
    func packagedLipSyncClassifierIsReadableAndPure() throws {
        let resourceURL = try #require(
            Bundle.module.url(
                forResource: "lip-sync-analysis",
                withExtension: "js"
            )
        )
        let source = try String(contentsOf: resourceURL, encoding: .utf8)

        #expect(source.contains("globalThis.millerLipSyncAnalysis"))
        #expect(source.contains("Object.freeze({ classify })"))
        #expect(source.contains("function classify("))
        for forbidden in [
            "navigator.mediaDevices",
            "MediaStream",
            "RTCPeerConnection",
            "fetch(",
            "XMLHttpRequest",
            "WebSocket",
            "localStorage",
            "sessionStorage",
            "setTimeout",
            "setInterval",
            "console.",
        ] {
            #expect(!source.contains(forbidden), "classifier must remain pure: \(forbidden)")
        }
    }

    @Test
    func outputSampleIsAClosedTypedOperationOnTheExistingPeer() async throws {
        let evaluator = FakeScriptEvaluator(results: [
            .prepareOffer: syntheticOffer,
            .applyAnswer: "connected",
            .outputSample: "{\"isPlaying\":true,\"offsetMilliseconds\":12,\"envelope\":0.5}",
            .close: "ok",
        ])
        let peer = WebKitLivePeer(evaluator: evaluator)

        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\n s=-\r\n")
        _ = peer.outputSamples()
        try await Task.sleep(for: .milliseconds(50))
        await peer.close()
        #expect(evaluator.calls.contains(.outputSample))
    }

    @Test
    func samplingFailureClosesThePeerAndTerminatesTheOutputStreamOnce() async throws {
        let evaluator = FailingOutputSampleEvaluator()
        let peer = WebKitLivePeer(evaluator: evaluator)

        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\n s=-\r\n")
        let stream = peer.outputSamples()
        let samples = Task { @MainActor in
            var samples = [LiveAudioOutputSample]()
            for await sample in stream {
                samples.append(sample)
            }
            return samples
        }

        try await waitUntil { await MainActor.run { evaluator.closeCalls == 1 } }
        let captured = await samples.value
        #expect(captured.count == 1)
        #expect(captured.first?.outputBufferActive == true)
        await peer.close()
        try await Task.sleep(for: .milliseconds(20))

        #expect(evaluator.closeCalls == 1)
        #expect(evaluator.outputSampleCalls == 2)
        #expect(await samples.value.count == 1)
    }

    @Test
    func cancelledOutputConsumerStopsPollingWithoutClosingTheConnectedPeer() async throws {
        let evaluator = PollingOutputSampleEvaluator()
        let peer = WebKitLivePeer(evaluator: evaluator)

        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\n s=-\r\n")
        let stream = peer.outputSamples()
        let probe = OutputConsumerProbe()
        let consumer = Task { @MainActor in
            for await sample in stream {
                probe.firstSample = sample
            }
        }

        try await waitUntil {
            await MainActor.run {
                probe.firstSample != nil && evaluator.outputSampleCalls >= 3
            }
        }
        let callsAtCancellation = evaluator.outputSampleCalls
        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(120))

        #expect(evaluator.outputSampleCalls == callsAtCancellation)
        #expect(evaluator.closeCalls == 0)
        try await peer.setMuted(true)
        await peer.close()
        #expect(evaluator.closeCalls == 1)
    }

    @Test(arguments: [
        (true, "https", "miller.invalid", true, WebKitLivePeerMediaRequest.microphone, WebKitLivePeerPermissionDecision.grant),
        (false, "https", "miller.invalid", true, WebKitLivePeerMediaRequest.microphone, WebKitLivePeerPermissionDecision.deny),
        (true, "https", "miller.invalid", true, WebKitLivePeerMediaRequest.camera, WebKitLivePeerPermissionDecision.deny),
        (true, "https", "miller.invalid", true, WebKitLivePeerMediaRequest.cameraAndMicrophone, WebKitLivePeerPermissionDecision.deny),
        (true, "http", "miller.invalid", true, WebKitLivePeerMediaRequest.microphone, WebKitLivePeerPermissionDecision.deny),
        (true, "https", "other.invalid", true, WebKitLivePeerMediaRequest.microphone, WebKitLivePeerPermissionDecision.deny),
        (true, "https", "miller.invalid", false, WebKitLivePeerMediaRequest.microphone, WebKitLivePeerPermissionDecision.deny),
    ] as [(Bool, String, String, Bool, WebKitLivePeerMediaRequest, WebKitLivePeerPermissionDecision)])
    func mediaPermissionPolicyAllowsOnlyAuthorizedMainFrameMicrophone(
        authorized: Bool,
        scheme: String,
        host: String,
        isMainFrame: Bool,
        request: WebKitLivePeerMediaRequest,
        expected: WebKitLivePeerPermissionDecision
    ) {
        #expect(WebKitLivePeer.mediaPermissionDecision(
            nativeMicrophoneAuthorized: authorized,
            originScheme: scheme,
            originHost: host,
            isMainFrame: isMainFrame,
            request: request
        ) == expected)
    }

    @Test(arguments: [
        ("https://miller.invalid/", true, false, WebKitLivePeerNavigationDecision.allowInitialDocument),
        ("https://miller.invalid/", true, true, WebKitLivePeerNavigationDecision.deny),
        ("https://miller.invalid/other", true, false, WebKitLivePeerNavigationDecision.deny),
        ("https://other.invalid/", true, false, WebKitLivePeerNavigationDecision.deny),
        ("https://miller.invalid/", false, false, WebKitLivePeerNavigationDecision.deny),
    ] as [(String, Bool, Bool, WebKitLivePeerNavigationDecision)])
    func navigationPolicyAllowsOnlyTheInitialLocalDocument(
        value: String,
        isMainFrame: Bool,
        didFinishInitialLoad: Bool,
        expected: WebKitLivePeerNavigationDecision
    ) {
        #expect(WebKitLivePeer.navigationDecision(
            url: URL(string: value),
            isMainFrame: isMainFrame,
            didFinishInitialLoad: didFinishInitialLoad
        ) == expected)
    }

    @Test
    func peerUsesTypedOperationsOnceAndNeverRetainsNegotiationStrings() async throws {
        let evaluator = FakeScriptEvaluator(results: [
            .prepareOffer: syntheticOffer,
            .applyAnswer: "connected",
            .setMuted(true): "ok",
            .close: "ok",
        ])
        let peer = WebKitLivePeer(evaluator: evaluator)

        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")
        try await peer.setMuted(true)
        await peer.close()
        await peer.close()

        #expect(evaluator.calls == [.prepareOffer, .applyAnswer, .setMuted(true), .close])
        await #expect(throws: (any Error).self) {
            _ = try await peer.prepareOffer()
        }
        await #expect(throws: (any Error).self) {
            try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")
        }
    }

    @Test
    func peerRequestsOneFixedResponseOnlyAfterItIsConnected() async throws {
        let evaluator = FakeScriptEvaluator(results: [
            .prepareOffer: syntheticOffer,
            .applyAnswer: "connected",
            .close: "ok",
        ])
        let peer = WebKitLivePeer(evaluator: evaluator)

        await #expect(throws: LiveAudioPeerError.invalidState) {
            try await peer.requestResponse()
        }
        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")
        try await peer.requestResponse()
        await peer.close()

        #expect(evaluator.responseCalls == 1)
        #expect(evaluator.calls == [.prepareOffer, .applyAnswer, .close])
    }

    @Test
    func closingAnInFlightResponseFencesTheFinalPeerSend() async throws {
        let evaluator = BlockingResponseScriptEvaluator()
        let peer = WebKitLivePeer(evaluator: evaluator)

        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")
        let response = Task { try? await peer.requestResponse() }
        await evaluator.waitUntilResponseStarted()

        await peer.close()
        evaluator.releaseResponse()
        _ = await response.value

        #expect(evaluator.responseSent == false)
    }

    @Test
    func peerTurnsMuteScriptFailureIntoATypedTerminalFailure() async throws {
        let evaluator = FakeScriptEvaluator(results: [
            .prepareOffer: syntheticOffer,
            .applyAnswer: "connected",
            .close: "ok",
        ])
        let peer = WebKitLivePeer(evaluator: evaluator)

        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")

        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await peer.setMuted(true)
        }
        #expect(evaluator.calls == [.prepareOffer, .applyAnswer, .setMuted(true), .close])
    }

    @Test(arguments: ["failed", "closed"])
    func peerReportsPostAdmissionConnectionLossThroughItsTypedMonitor(
        connectionState: String
    ) async throws {
        let evaluator = FakeScriptEvaluator(results: [
            .prepareOffer: syntheticOffer,
            .applyAnswer: "connected",
            .connectionState: connectionState,
            .close: "ok",
        ])
        let peer = WebKitLivePeer(evaluator: evaluator)

        _ = try await peer.prepareOffer()
        try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")

        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await peer.waitForConnectionFailure()
        }
        await peer.close()
        #expect(evaluator.calls == [.prepareOffer, .applyAnswer, .connectionState, .close])
    }

    @Test
    func peerRejectsInvalidAndOutOfOrderAnswersWithoutCallingTheEvaluator() async throws {
        let evaluator = FakeScriptEvaluator(results: [.prepareOffer: syntheticOffer])
        let peer = WebKitLivePeer(evaluator: evaluator)

        await #expect(throws: (any Error).self) {
            try await peer.applyAnswerAndWaitForConnected("v=0\r\ns=-\r\n")
        }
        _ = try await peer.prepareOffer()
        await #expect(throws: (any Error).self) {
            try await peer.applyAnswerAndWaitForConnected("\u{0000}")
        }
        await #expect(throws: (any Error).self) {
            _ = try await peer.prepareOffer()
        }

        #expect(evaluator.calls == [.prepareOffer])
    }

    @Test
    func peerBoundsTheEvaluatorOfferBeforeTheClientCanStart() async {
        let evaluator = FakeScriptEvaluator(results: [
            .prepareOffer: String(repeating: "x", count: WebKitLivePeer.maximumSDPBytes + 1),
        ])
        let peer = WebKitLivePeer(evaluator: evaluator)

        await #expect(throws: (any Error).self) {
            _ = try await peer.prepareOffer()
        }
        #expect(evaluator.calls == [.prepareOffer, .close])
    }

    @Test
    func peerTimesOutAnEvaluatorThatIgnoresCancellation() async {
        let evaluator = SlowScriptEvaluator()
        let peer = WebKitLivePeer(
            evaluator: evaluator,
            operationTimeout: .milliseconds(20)
        )

        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            _ = try await peer.prepareOffer()
        }
        #expect(evaluator.calls.first == .prepareOffer)
    }

    @Test
    func pageReadinessWaitsForTheInitialDocumentAndThenUnblocks() async throws {
        let readiness = WebKitLivePeerPageReadiness(timeout: .seconds(5))
        let wait = Task { try await readiness.waitUntilReady() }

        try await waitUntil { await readiness.waiterCount == 1 }
        readiness.finish()
        try await wait.value
        #expect(readiness.waiterCount == 0)
    }

    @Test
    func pageReadinessFailsAndCancelsWithoutLeavingWaiters() async throws {
        let failed = WebKitLivePeerPageReadiness(timeout: .seconds(5))
        let failureWait = Task<Result<Void, Error>, Never> {
            do {
                try await failed.waitUntilReady()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil { await failed.waiterCount == 1 }
        failed.fail()
        #expect((await failureWait.value).failure as? LiveAudioPeerError == .connectionFailed)
        #expect(failed.waiterCount == 0)

        let cancelled = WebKitLivePeerPageReadiness(timeout: .seconds(5))
        let cancellationWait = Task<Result<Void, Error>, Never> {
            do {
                try await cancelled.waitUntilReady()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil { await cancelled.waiterCount == 1 }
        cancellationWait.cancel()
        #expect((await cancellationWait.value).failure is CancellationError)
        try await waitUntil { await cancelled.waiterCount == 0 }
    }

    @Test
    func pageReadinessTimeoutDoesNotLeaveAContinuation() async {
        let readiness = WebKitLivePeerPageReadiness(timeout: .milliseconds(10))

        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await readiness.waitUntilReady()
        }
        #expect(readiness.waiterCount == 0)
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw LiveAudioPeerError.connectionFailed }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class FakeScriptEvaluator: WebKitLivePeerScriptEvaluating {
    private var results: [WebKitLivePeerScriptOperation: String]
    private(set) var calls: [WebKitLivePeerScriptOperation] = []
    private(set) var responseCalls = 0

    init(results: [WebKitLivePeerScriptOperation: String]) {
        self.results = results
    }

    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String {
        calls.append(operation)
        guard let result = results[operation] else { throw FakeEvaluatorError.missingResult }
        return result
    }

    func requestResponse() async throws -> String {
        responseCalls += 1
        return "ok"
    }
}

@MainActor
private final class FailingOutputSampleEvaluator: WebKitLivePeerScriptEvaluating {
    private(set) var outputSampleCalls = 0
    private(set) var closeCalls = 0

    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String {
        switch operation {
        case .prepareOffer:
            return syntheticOffer
        case .applyAnswer:
            return "connected"
        case .outputSample:
            outputSampleCalls += 1
            if outputSampleCalls == 1 {
                return "{\"isPlaying\":true,\"outputBufferActive\":true,\"offsetMilliseconds\":12,\"envelope\":0.5}"
            }
            throw FakeEvaluatorError.missingResult
        case .close:
            closeCalls += 1
            return "ok"
        default:
            throw FakeEvaluatorError.missingResult
        }
    }
}

@MainActor
private final class PollingOutputSampleEvaluator: WebKitLivePeerScriptEvaluating {
    private(set) var outputSampleCalls = 0
    private(set) var closeCalls = 0

    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String {
        switch operation {
        case .prepareOffer:
            return syntheticOffer
        case .applyAnswer:
            return "connected"
        case .outputSample:
            outputSampleCalls += 1
            return "{\"isPlaying\":true,\"offsetMilliseconds\":\(outputSampleCalls),\"envelope\":0.5}"
        case .setMuted:
            return "ok"
        case .close:
            closeCalls += 1
            return "ok"
        default:
            throw FakeEvaluatorError.missingResult
        }
    }
}

@MainActor
private final class OutputConsumerProbe {
    var firstSample: LiveAudioOutputSample?
}

@MainActor
private final class BlockingResponseScriptEvaluator: WebKitLivePeerScriptEvaluating {
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private var responseStartContinuation: CheckedContinuation<Void, Never>?
    private(set) var responseStarted = false
    private(set) var responseSent = false
    private var responseInvalidated = false

    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String {
        switch operation {
        case .prepareOffer:
            return syntheticOffer
        case .applyAnswer:
            return "connected"
        case .close:
            return "ok"
        default:
            throw FakeEvaluatorError.missingResult
        }
    }

    func requestResponse() async throws -> String {
        try await requestResponse(for: 1)
    }

    func requestResponse(for generation: UInt64) async throws -> String {
        responseStarted = true
        responseStartContinuation?.resume()
        responseStartContinuation = nil
        await withCheckedContinuation { responseContinuation = $0 }
        if !responseInvalidated {
            responseSent = true
        }
        return "ok"
    }

    func invalidateResponse(generation: UInt64) {
        responseInvalidated = true
    }

    func waitUntilResponseStarted() async {
        guard !responseStarted else { return }
        await withCheckedContinuation { continuation in
            responseStartContinuation = continuation
        }
    }

    func releaseResponse() {
        responseContinuation?.resume()
        responseContinuation = nil
    }
}

@MainActor
private final class SlowScriptEvaluator: WebKitLivePeerScriptEvaluating {
    private(set) var calls: [WebKitLivePeerScriptOperation] = []

    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String {
        calls.append(operation)
        try await Task.sleep(for: .milliseconds(200))
        return syntheticOffer
    }
}

private enum FakeEvaluatorError: Error {
    case missingResult
}

@MainActor
private final class PeerFactoryProbe {
    private(set) var calls = 0

    func makePeer() -> WebKitLivePeer {
        calls += 1
        return WebKitLivePeer(
            evaluator: FakeScriptEvaluator(results: [:]),
            peerView: NSView(frame: .zero)
        )
    }
}

private extension Result where Success == Void, Failure == Error {
    var failure: Error? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

private let syntheticOffer = "v=0\r\ns=-\r\n"

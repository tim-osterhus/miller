import AppKit
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
        #expect(html.contains("createOffer()"))
        #expect(html.contains("setLocalDescription(offer)"))
        #expect(html.contains("setRemoteDescription"))
        #expect(html.contains("track.enabled = !muted"))
        #expect(html.contains("audio.srcObject = null"))
        #expect(!html.contains("<form"))
        #expect(!html.contains("<iframe"))
        #expect(!html.contains("src=\"http"))
        #expect(!html.contains("window.open"))
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

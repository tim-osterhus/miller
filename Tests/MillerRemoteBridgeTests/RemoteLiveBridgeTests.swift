import Foundation
import Darwin
import MillerLiveAudio
@testable import MillerRemoteBridge
import Testing

@Suite
struct RemoteLiveBridgeTests {
    private let generation = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let requestID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let sessionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let offer = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"

    @Test
    func strictCodecRoundTripsLengthPrefixedFrames() throws {
        let request = RemoteLiveRequest.start(
            requestID: requestID,
            hostGeneration: generation,
            clientSessionID: sessionID,
            offerSDP: offer
        )

        let lengthPrefixed = try RemoteLiveBridgeCodec.encodeFrame(request)
        let decodedLengthPrefixed = try RemoteLiveBridgeCodec.decodeFrame(lengthPrefixed)
        #expect(decodedLengthPrefixed == .request(request))
    }

    @Test
    func codecRejectsSemanticallyDuplicateKeysAndBooleanNegotiatedVersion() throws {
        let duplicate = #"{"protocol":"miller.remote-live","version":1,"type":"start","request_id":"11111111-1111-4111-8111-111111111111","host_generation":"22222222-2222-4222-8222-222222222222","payload":{"client_session_id":"33333333-3333-4333-8333-333333333333","offer_sdp":"v=0","\u006ffer_sdp":"v=1"}}"#
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(frame(Data(duplicate.utf8)))
        }

        let booleanVersion = #"{"protocol":"miller.remote-live","version":1,"type":"hello_ack","request_id":"11111111-1111-4111-8111-111111111111","host_generation":"22222222-2222-4222-8222-222222222222","payload":{"negotiated_version":true}}"#
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(frame(Data(booleanVersion.utf8)))
        }

        let decimalVersion = booleanVersion.replacingOccurrences(
            of: "true", with: "1.0"
        )
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(frame(Data(decimalVersion.utf8)))
        }
    }

    @Test
    func codecRejectsUnknownFieldsInvalidCorrelationAndOversizedSDP() throws {
        let base = #"{"protocol":"miller.remote-live","version":1,"type":"start","request_id":"11111111-1111-4111-8111-111111111111","host_generation":"22222222-2222-4222-8222-222222222222","payload":{"client_session_id":"33333333-3333-4333-8333-333333333333","offer_sdp":"v=0"}}"#
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(frame(Data((base.dropLast() + ",\"extra\":true}").utf8)))
        }
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(frame(Data(base.replacingOccurrences(of: "11111111-1111-4111-8111-111111111111", with: "not-a-uuid").utf8)))
        }
        let oversized = String(repeating: "x", count: RemoteLiveBridgeContract.maximumSDPBytes + 1)
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(frame(Data(base.replacingOccurrences(of: "v=0", with: oversized).utf8)))
        }
    }

    @Test
    func codecRejectsFrameBoundsAndInvalidClientIdentifiers() throws {
        var oversizedLength = UInt32(RemoteLiveBridgeContract.maximumFrameBytes + 1).bigEndian
        var oversizedFrame = Data()
        withUnsafeBytes(of: &oversizedLength) { oversizedFrame.append(contentsOf: $0) }
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(oversizedFrame)
        }

        let truncated = Data([0, 0, 0, 1])
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(truncated)
        }

        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(Data([0, 0, 0, 0]))
        }
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(Data([0, 0, 0, 1, 0xFF]))
        }

        let tooLongClientID = RemoteLiveRequest.hello(
            requestID: requestID,
            clientID: String(repeating: "x", count: RemoteLiveBridgeContract.maximumClientIDBytes + 1)
        )
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(
                RemoteLiveBridgeCodec.encodeFrame(tooLongClientID)
            )
        }

        let invalidClientID = RemoteLiveRequest.hello(
            requestID: requestID,
            clientID: "miller/remote"
        )
        #expect(throws: RemoteLiveBridgeError.self) {
            try RemoteLiveBridgeCodec.decodeFrame(
                RemoteLiveBridgeCodec.encodeFrame(invalidClientID)
            )
        }
    }

    @Test
    func terminalReasonsMapToHistoryOutcomes() {
        let completed: [RemoteLiveTerminalReason] = [.completed, .clientClosed, .providerClosed]
        let stopped: [RemoteLiveTerminalReason] = [
            .interrupted, .pageHidden, .offline, .leaseExpired,
            .sessionExpired, .gatewayShutdown, .bridgeDisconnected,
        ]
        let failed: [RemoteLiveTerminalReason] = [
            .peerFailed, .trackEnded, .dataChannelClosed, .providerFailed, .timeout,
        ]
        let abandoned: [RemoteLiveTerminalReason] = [.hostShutdown, .startCancelled]
        for reason in completed {
            #expect(reason.historyOutcome(afterAdmission: true) == .completed)
        }
        for reason in stopped {
            #expect(reason.historyOutcome(afterAdmission: true) == .stopped)
        }
        for reason in failed {
            #expect(reason.historyOutcome(afterAdmission: true) == .failed)
        }
        for reason in abandoned {
            #expect(reason.historyOutcome(afterAdmission: true) == .abandoned)
        }
        #expect(RemoteLiveTerminalReason.pageHidden.historyOutcome(afterAdmission: false) == .abandoned)
        #expect(RemoteLiveTerminalReason.peerFailed.historyOutcome(afterAdmission: false) == .abandoned)
    }

    @Test
    func routerFencesGenerationReplayAndOneActiveSession() async throws {
        let recorder = RemoteLiveHostRecorder()
        let root = URL(fileURLWithPath: "/tmp/miller-remote-router")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            homeDirectory: root,
            generation: generation
        )
        let connection = UUID()
        let otherConnection = UUID()
        let hello = await server.handle(
            .hello(requestID: requestID, clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        #expect(hello == .helloAck(requestID: requestID, hostGeneration: generation))

        let started = await server.handle(
            .start(
                requestID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        #expect(started == .startResult(
            requestID: started.requestID,
            hostGeneration: generation,
            clientSessionID: sessionID,
            answerSDP: recorder.answer
        ))

        let busyHello = await server.handle(
            .hello(requestID: UUID(), clientID: "second.gateway"),
            connectionID: otherConnection
        )
        #expect(busyHello == .error(
            requestID: busyHello.requestID,
            hostGeneration: generation,
            code: .busy
        ))

        let stale = await server.handle(
            .activity(
                requestID: UUID(),
                hostGeneration: UUID(),
                clientSessionID: sessionID
            ),
            connectionID: connection
        )
        #expect(stale == .error(
            requestID: stale.requestID,
            hostGeneration: generation,
            code: .staleGeneration
        ))

        let connected = await server.handle(
            .connected(requestID: UUID(), hostGeneration: generation, clientSessionID: sessionID),
            connectionID: connection
        )
        #expect(connected.hostGeneration == generation)
        let interruptRequest = RemoteLiveRequest.interrupt(
            requestID: UUID(),
            hostGeneration: generation,
            clientSessionID: sessionID
        )
        let interrupted = await server.handle(interruptRequest, connectionID: connection)
        #expect(interrupted == .operationResult(
            requestID: interruptRequest.requestID,
            hostGeneration: generation,
            clientSessionID: sessionID,
            outcome: "ok"
        ))
        #expect(await server.handle(interruptRequest, connectionID: connection) == interrupted)
        #expect(await recorder.interruptCount() == 1)
    }

    @Test
    func routerEndsSessionOnceAndReportsTerminalStatus() async throws {
        let recorder = RemoteLiveHostRecorder()
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: requestID, clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        let start = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        guard case .startResult = start else {
            Issue.record("Session did not start: \(start)")
            return
        }

        let end = RemoteLiveRequest.end(
            requestID: UUID(),
            hostGeneration: generation,
            clientSessionID: sessionID,
            reason: .clientClosed
        )
        let ended = await server.handle(end, connectionID: connection)
        #expect(ended == .operationResult(
            requestID: end.requestID,
            hostGeneration: generation,
            clientSessionID: sessionID,
            outcome: "ok"
        ))
        #expect(await recorder.endReasons() == [.clientClosed])

        let status = await server.handle(
            .status(requestID: UUID(), hostGeneration: generation),
            connectionID: connection
        )
        #expect(status == .statusResult(
            requestID: status.requestID,
            hostGeneration: generation,
            clientSessionID: nil,
            state: .closed,
            reason: .clientClosed
        ))
        #expect(await server.handle(end, connectionID: connection) == ended)
        #expect(await recorder.endReasons() == [.clientClosed])
    }

    @Test
    func replayingEndWithAlteredReasonIsAConflict() async throws {
        let recorder = RemoteLiveHostRecorder()
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )

        let requestID = UUID()
        let first = RemoteLiveRequest.end(
            requestID: requestID,
            hostGeneration: generation,
            clientSessionID: sessionID,
            reason: .clientClosed
        )
        _ = await server.handle(first, connectionID: connection)
        let altered = await server.handle(
            .end(
                requestID: requestID,
                hostGeneration: generation,
                clientSessionID: sessionID,
                reason: .timeout
            ),
            connectionID: connection
        )

        #expect(altered == .error(
            requestID: requestID,
            hostGeneration: generation,
            code: .conflict
        ))
    }

    @Test
    func busyStartClearsOnlyItsProvisionalStateAndAllowsNextAdmission() async throws {
        let script = RemoteLiveStartScript()
        let server = MillerRemoteBridgeServer(
            host: MillerRemoteBridgeHost(
                start: { [script] _, _ in try await script.start() },
                connected: { _ in },
                interrupt: { _ in },
                end: { _, _ in }
            ),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )

        let first = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        #expect(first == .error(
            requestID: first.requestID,
            hostGeneration: generation,
            code: .busy
        ))
        let afterBusy = await server.handle(
            .status(requestID: UUID(), hostGeneration: generation),
            connectionID: connection
        )
        #expect(afterBusy == .statusResult(
            requestID: afterBusy.requestID,
            hostGeneration: generation,
            clientSessionID: nil,
            state: .idle,
            reason: nil
        ))

        let nextSessionID = UUID()
        let next = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: nextSessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        #expect(next == .startResult(
            requestID: next.requestID,
            hostGeneration: generation,
            clientSessionID: nextSessionID,
            answerSDP: "v=0"
        ))
    }

    @Test
    func activityCannotSucceedAfterAConcurrentTerminalization() async throws {
        let activityGate = RemoteLiveTestGate()
        let recorder = RemoteLiveHostRecorder(activityGate: activityGate)
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        _ = await server.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID
            ),
            connectionID: connection
        )

        let activityRequest = RemoteLiveRequest.activity(
            requestID: UUID(),
            hostGeneration: generation,
            clientSessionID: sessionID
        )
        let activity = Task {
            await server.handle(activityRequest, connectionID: connection)
        }
        await activityGate.waitUntilBlocked()

        let end = await server.handle(
            .end(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                reason: .clientClosed
            ),
            connectionID: connection
        )
        #expect(end == .operationResult(
            requestID: end.requestID,
            hostGeneration: generation,
            clientSessionID: sessionID,
            outcome: "ok"
        ))

        await activityGate.open()
        let response = await activity.value
        #expect(response == .error(
            requestID: activityRequest.requestID,
            hostGeneration: generation,
            code: .conflict
        ))
    }

    @Test
    func sameClientSessionIDCannotAdmitAStaleStartCallback() async throws {
        let host = RemoteLiveStartRaceHost()
        let server = MillerRemoteBridgeServer(
            host: host.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )

        let firstStart = Task {
            await server.handle(
                .start(
                    requestID: UUID(),
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    offerSDP: offer
                ),
                connectionID: connection
            )
        }
        await host.waitForFirstStart()

        let ended = await server.handle(
            .end(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                reason: .clientClosed
            ),
            connectionID: connection
        )
        #expect(ended == .operationResult(
            requestID: ended.requestID,
            hostGeneration: generation,
            clientSessionID: sessionID,
            outcome: "ok"
        ))

        let secondStart = Task {
            await server.handle(
                .start(
                    requestID: UUID(),
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    offerSDP: offer
                ),
                connectionID: connection
            )
        }
        await host.waitForSecondStart()

        await host.openFirstStart()
        let stale = await firstStart.value
        #expect(stale == .error(
            requestID: stale.requestID,
            hostGeneration: generation,
            code: .staleGeneration
        ))

        await host.openSecondStart()
        let admitted = await secondStart.value
        #expect(admitted == .startResult(
            requestID: admitted.requestID,
            hostGeneration: generation,
            clientSessionID: sessionID,
            answerSDP: "v=2"
        ))
    }

    @Test
    func sameClientSessionIDCannotAdmitAStaleActivityCallback() async throws {
        let activityGate = RemoteLiveTestGate()
        let recorder = RemoteLiveHostRecorder(activityGate: activityGate)
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        _ = await server.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID
            ),
            connectionID: connection
        )

        let activityRequest = RemoteLiveRequest.activity(
            requestID: UUID(),
            hostGeneration: generation,
            clientSessionID: sessionID
        )
        let activity = Task {
            await server.handle(activityRequest, connectionID: connection)
        }
        await activityGate.waitUntilBlocked()

        _ = await server.handle(
            .end(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                reason: .clientClosed
            ),
            connectionID: connection
        )
        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        _ = await server.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID
            ),
            connectionID: connection
        )

        await activityGate.open()
        let stale = await activity.value
        #expect(stale == .error(
            requestID: activityRequest.requestID,
            hostGeneration: generation,
            code: .conflict
        ))
        let status = await server.status()
        #expect(status.clientSessionID == sessionID)
        #expect(status.state == .listening)
        #expect(status.reason == nil)
    }

    @Test
    func providerTerminalReleasesSessionWithExactReasonAndAllowsNextStart() async throws {
        let recorder = RemoteLiveHostRecorder()
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )

        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        await server.providerDidTerminate(
            sessionID: sessionID,
            reason: .providerClosed
        )
        let closed = await server.handle(
            .status(requestID: UUID(), hostGeneration: generation),
            connectionID: connection
        )
        #expect(closed == .statusResult(
            requestID: closed.requestID,
            hostGeneration: generation,
            clientSessionID: nil,
            state: .closed,
            reason: .providerClosed
        ))

        let nextSessionID = UUID()
        let next = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: nextSessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        guard case let .startResult(_, nextGeneration, returnedSessionID, _) = next else {
            Issue.record("Next provider session did not start: \(next)")
            return
        }
        #expect(nextGeneration == generation)
        #expect(returnedSessionID == nextSessionID)

        await server.providerDidTerminate(
            sessionID: nextSessionID,
            reason: .providerFailed
        )
        let failed = await server.handle(
            .status(requestID: UUID(), hostGeneration: generation),
            connectionID: connection
        )
        #expect(failed == .statusResult(
            requestID: failed.requestID,
            hostGeneration: generation,
            clientSessionID: nil,
            state: .failed,
            reason: .providerFailed
        ))
    }

    @Test
    func providerTerminalFenceWinsEndAndPublishesAfterCleanup() async throws {
        let recorder = RemoteLiveHostRecorder()
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )

        #expect(await server.beginProviderTermination(
            sessionID: sessionID,
            reason: .providerClosed
        ))
        let end = await server.handle(
            .end(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                reason: .clientClosed
            ),
            connectionID: connection
        )
        #expect(end == .error(
            requestID: end.requestID,
            hostGeneration: generation,
            code: .conflict
        ))
        #expect(await recorder.endReasons().isEmpty)

        await server.providerDidTerminate(
            sessionID: sessionID,
            reason: .providerClosed
        )
        let status = await server.handle(
            .status(requestID: UUID(), hostGeneration: generation),
            connectionID: connection
        )
        #expect(status == .statusResult(
            requestID: status.requestID,
            hostGeneration: generation,
            clientSessionID: nil,
            state: .closed,
            reason: .providerClosed
        ))
    }

    @Test
    func concurrentDistinctTerminalRequestsCallHostCleanupOnceWithStableReason() async throws {
        let endGate = RemoteLiveTestGate()
        let recorder = RemoteLiveHostRecorder(endGate: endGate)
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )

        let first = Task {
            await server.handle(
                .end(
                    requestID: UUID(),
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    reason: .clientClosed
                ),
                connectionID: connection
            )
        }
        let second = Task {
            await server.handle(
                .end(
                    requestID: UUID(),
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    reason: .timeout
                ),
                connectionID: connection
            )
        }
        await endGate.waitUntilBlocked()
        await endGate.open()
        let responses = await [first.value, second.value]
        #expect(responses.filter {
            if case .operationResult = $0 { return true }
            return false
        }.count == 1)
        #expect(responses.filter {
            if case let .error(_, _, code) = $0 { return code == .conflict }
            return false
        }.count == 1)
        #expect(await recorder.endReasons().count == 1)
        let status = await server.handle(
            .status(requestID: UUID(), hostGeneration: generation),
            connectionID: connection
        )
        guard case let .statusResult(_, _, _, _, reason) = status else {
            Issue.record("Terminal status was not returned: \(status)")
            return
        }
        #expect(reason == .clientClosed || reason == .timeout)
    }

    @Test
    func stopDuringTerminalRequestDoesNotDuplicateCleanupOrReplaceReason() async throws {
        let endGate = RemoteLiveTestGate()
        let recorder = RemoteLiveHostRecorder(endGate: endGate)
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )

        let ending = Task {
            await server.handle(
                .end(
                    requestID: UUID(),
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    reason: .clientClosed
                ),
                connectionID: connection
            )
        }
        await endGate.waitUntilBlocked()
        await server.stop()
        await endGate.open()
        _ = await ending.value

        #expect(await recorder.endReasons() == [.clientClosed])
        let status = await server.status()
        #expect(status.clientSessionID == nil)
        #expect(status.reason == .clientClosed)
    }

    @Test
    func connectedRequiresProviderAnswerAndConnectingLifecycle() async throws {
        let recorder = RemoteLiveHostRecorder()
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            generation: generation
        )
        let connection = UUID()
        _ = await server.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connection
        )
        let early = await server.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID
            ),
            connectionID: connection
        )
        #expect(early == .error(
            requestID: early.requestID,
            hostGeneration: generation,
            code: .notFound
        ))

        _ = await server.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID,
                offerSDP: offer
            ),
            connectionID: connection
        )
        let connected = await server.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: sessionID
            ),
            connectionID: connection
        )
        guard case let .operationResult(_, _, returnedSessionID, _) = connected else {
            Issue.record("Connected operation did not succeed: \(connected)")
            return
        }
        #expect(returnedSessionID == sessionID)
        #expect(await recorder.connectedCount() == 1)
    }

    @Test
    func unixSocketParentAndSocketAreCurrentUserOnlyAndRemovedOnStop() async throws {
        let root = URL(fileURLWithPath: "/tmp/miller-remote-uds")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: generation
        )
        try await server.start()
        let socketPath = (await server.socketPath).path
        var info = stat()
        #expect(lstat(socketPath, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFSOCK)
        #expect(info.st_uid == getuid())
        #expect(info.st_mode & 0o777 == 0o600)
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    func unixSocketRejectsClientsBeyondTheActiveClientCap() async throws {
        let root = URL(fileURLWithPath: "/tmp/mrv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: generation
        )
        try await server.start()
        let socketPath = (await server.socketPath).path
        var fileDescriptors = try (0...RemoteLiveBridgeContract.maximumActiveClients)
            .map { _ in try connectUnixSocket(to: socketPath) }
        defer {
            for fd in fileDescriptors where fd >= 0 { Darwin.close(fd) }
        }

        for index in fileDescriptors.indices {
            try? writeAll(
                fd: fileDescriptors[index],
                data: try RemoteLiveBridgeCodec.encodeFrame(
                    .hello(requestID: UUID(), clientID: "cap-\(index)")
                )
            )
        }

        var rejected = false
        for index in fileDescriptors.indices {
            guard waitForReadable(fd: fileDescriptors[index], timeoutMilliseconds: 1_000)
            else { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(fileDescriptors[index], &byte, 1)
            if count == 0 || (count < 0 && errno == ECONNRESET) {
                rejected = true
            }
        }
        #expect(rejected)
        await server.stop()
        fileDescriptors.removeAll()
    }

    @Test
    func unixSocketRejectsAggregateBufferedBytesBeyondTheServerBudget() async throws {
        let root = URL(fileURLWithPath: "/tmp/mrw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: generation,
            clientHandshakeTimeout: .seconds(60)
        )
        try await server.start()
        let socketPath = (await server.socketPath).path
        var fileDescriptors = try (0..<RemoteLiveBridgeContract.maximumActiveClients)
            .map { _ in try connectUnixSocket(to: socketPath) }
        defer {
            for fd in fileDescriptors where fd >= 0 { Darwin.close(fd) }
        }

        let partialFrame = Data([0x00, 0x02, 0x00, 0x00])
            + Data(repeating: 0x78, count: RemoteLiveBridgeContract.maximumFrameBytes - 5)
        #expect(
            partialFrame.count * RemoteLiveBridgeContract.maximumActiveClients + 9
                > RemoteLiveBridgeContract.maximumBufferedBytes
        )
        for fd in fileDescriptors {
            try writeAll(fd: fd, data: partialFrame)
        }
        try writeAll(
            fd: fileDescriptors[0],
            data: Data(repeating: 0x78, count: 9)
        )

        var rejected = false
        for fd in fileDescriptors {
            guard waitForReadable(fd: fd, timeoutMilliseconds: 1_000) else {
                continue
            }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 || (count < 0 && errno == ECONNRESET) {
                rejected = true
                break
            }
        }
        #expect(rejected)
        await server.stop()
        fileDescriptors.removeAll()
    }

    @Test
    @MainActor
    func remotePeerReturnsOfferPublishesAnswerAndWaitsForSeparateConnectedFence() async throws {
        let peer = RemoteBrowserLivePeer(clientSessionID: sessionID, offerSDP: offer)
        #expect(try await peer.prepareOffer() == offer)
        let connection = Task { @MainActor in
            try await peer.applyAnswerAndWaitForConnected("v=0")
        }
        #expect(try await peer.providerAnswer() == "v=0")
        #expect(!connection.isCancelled)
        #expect(peer.markConnected())
        try await connection.value
        #expect(peer.isConnected)
    }

    @Test
    @MainActor
    func remotePeerCannotConnectBeforeAnswer() async throws {
        let peer = RemoteBrowserLivePeer(clientSessionID: sessionID, offerSDP: offer)
        _ = try await peer.prepareOffer()
        #expect(!peer.markConnected())
        #expect(!peer.isConnected)
    }

    @Test
    @MainActor
    func remotePeerRejectsCachedAnswerAfterFailure() async throws {
        let peer = RemoteBrowserLivePeer(clientSessionID: sessionID, offerSDP: offer)
        _ = try await peer.prepareOffer()
        let connection = Task { @MainActor in
            try await peer.applyAnswerAndWaitForConnected("v=0")
        }
        #expect(try await peer.providerAnswer() == "v=0")
        peer.fail(.trackEnded)
        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await peer.providerAnswer()
        }
        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await connection.value
        }
    }

    @Test
    @MainActor
    func remotePeerConnectedWaitHasDeterministicTimeout() async throws {
        let timeoutGate = RemoteLiveTestGate()
        let peer = RemoteBrowserLivePeer(
            clientSessionID: sessionID,
            offerSDP: offer,
            connectedTimeout: .milliseconds(20),
            connectedTimeoutWaiter: { _ in
                await timeoutGate.wait()
            }
        )
        _ = try await peer.prepareOffer()
        let connection = Task { @MainActor in
            try await peer.applyAnswerAndWaitForConnected("v=0")
        }
        await timeoutGate.waitUntilBlocked()
        await timeoutGate.open()
        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await connection.value
        }
        #expect(peer.terminalReason == .timeout)
    }

    @Test
    @MainActor
    func remotePeerFailureReleasesWaitersWithoutAudioOrWebKit() async throws {
        let peer = RemoteBrowserLivePeer(clientSessionID: sessionID, offerSDP: offer)
        _ = try await peer.prepareOffer()
        let connection = Task { @MainActor in
            try await peer.applyAnswerAndWaitForConnected("v=0")
        }
        #expect(try await peer.providerAnswer() == "v=0")
        peer.fail(.trackEnded)
        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await connection.value
        }
        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await peer.waitForConnectionFailure()
        }
    }

    @Test
    @MainActor
    func cancellingOneFailureWaiterOnlyReleasesThatCaller() async throws {
        let readiness = RemoteLiveReadiness()
        let peer = RemoteBrowserLivePeer(
            clientSessionID: sessionID,
            offerSDP: offer,
            connectedTimeout: .seconds(45),
            connectedTimeoutWaiter: { try await Task.sleep(for: $0) },
            failureWaiterReady: {
                Task { await readiness.signal() }
            }
        )
        _ = try await peer.prepareOffer()
        let first = Task { @MainActor in
            try await peer.waitForConnectionFailure()
        }
        await readiness.waitUntil(count: 1)
        let second = Task { @MainActor in
            try await peer.waitForConnectionFailure()
        }
        await readiness.waitUntil(count: 2)
        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        peer.fail(.trackEnded)

        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await first.value
        }
    }

    @Test
    @MainActor
    func duplicateProviderAnswerWaiterFailsClosedWithoutReplacingTheFirst() async throws {
        let readiness = RemoteLiveReadiness()
        let peer = RemoteBrowserLivePeer(
            clientSessionID: sessionID,
            offerSDP: offer,
            connectedTimeout: .seconds(45),
            connectedTimeoutWaiter: { try await Task.sleep(for: $0) },
            providerAnswerWaiterReady: {
                Task { await readiness.signal() }
            }
        )
        _ = try await peer.prepareOffer()
        let first = Task { @MainActor in
            try await peer.providerAnswer()
        }
        await readiness.waitUntil(count: 1)
        await #expect(throws: LiveAudioPeerError.invalidState) {
            try await peer.providerAnswer()
        }
        peer.fail(.trackEnded)
        await #expect(throws: LiveAudioPeerError.connectionFailed) {
            try await first.value
        }
    }

    @Test
    @MainActor
    func timeoutCannotTerminalizeAConnectionThatAlreadyConnected() async throws {
        let timeoutGate = RemoteLiveTestGate()
        let peer = RemoteBrowserLivePeer(
            clientSessionID: sessionID,
            offerSDP: offer,
            connectedTimeout: .seconds(45),
            connectedTimeoutWaiter: { _ in await timeoutGate.wait() }
        )
        _ = try await peer.prepareOffer()
        let connection = Task { @MainActor in
            try await peer.applyAnswerAndWaitForConnected("v=0")
        }
        await timeoutGate.waitUntilBlocked()
        #expect(peer.markConnected())
        await timeoutGate.open()
        try await connection.value
        peer.fail(.timeout)
        #expect(peer.terminalReason == nil)
        #expect(peer.isConnected)
    }

    @Test
    @MainActor
    func remotePeerCancellationReleasesConnectedWaiter() async throws {
        let peer = RemoteBrowserLivePeer(clientSessionID: sessionID, offerSDP: offer)
        _ = try await peer.prepareOffer()
        let connection = Task { @MainActor in
            try await peer.applyAnswerAndWaitForConnected("v=0")
        }
        #expect(try await peer.providerAnswer() == "v=0")
        connection.cancel()
        await #expect(throws: CancellationError.self) {
            try await connection.value
        }
    }

    @Test
    func unixSocketDisconnectTerminatesActiveSession() async throws {
        let endGate = RemoteLiveTestGate()
        let recorder = RemoteLiveHostRecorder(endGate: endGate)
        let root = URL(fileURLWithPath: "/tmp/mrd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MillerRemoteBridgeServer(
            host: recorder.host(),
            homeDirectory: root,
            generation: generation
        )
        try await server.start()
        var fd = try connectUnixSocket(to: (await server.socketPath).path)
        defer {
            if fd >= 0 { Darwin.close(fd) }
        }
        try writeAll(
            fd: fd,
            data: try RemoteLiveBridgeCodec.encodeFrame(
                .hello(requestID: UUID(), clientID: "miller-remote.gateway")
            )
        )
        try writeAll(
            fd: fd,
            data: try RemoteLiveBridgeCodec.encodeFrame(
                .start(
                    requestID: UUID(),
                    hostGeneration: generation,
                    clientSessionID: sessionID,
                    offerSDP: offer
                )
            )
        )
        await recorder.waitForStart()
        #expect(await recorder.startCount() == 1)
        try setAbortiveClose(fd)
        Darwin.close(fd)
        fd = -1
        await endGate.waitUntilBlocked()
        await server.stop()
        await endGate.open()
        await recorder.waitForEndReasons([.bridgeDisconnected])
        #expect(await recorder.endReasons() == [.bridgeDisconnected])
    }

    @Test
    func competingOrUnstartedServersNeverRemoveAnotherLiveSocket() async throws {
        let root = URL(fileURLWithPath: "/tmp/mro-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: generation
        )
        let second = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: UUID()
        )
        try await first.start()
        let socketPath = (await first.socketPath).path
        var before = stat()
        #expect(lstat(socketPath, &before) == 0)
        await #expect(throws: RemoteLiveBridgeError.self) { try await second.start() }
        var after = stat()
        #expect(lstat(socketPath, &after) == 0)
        #expect(before.st_dev == after.st_dev)
        #expect(before.st_ino == after.st_ino)
        await second.stop()
        #expect(FileManager.default.fileExists(atPath: socketPath))
        await first.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    func unstartedStopNeverRemovesAnotherLiveSocket() async throws {
        let root = URL(fileURLWithPath: "/tmp/mru-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: generation
        )
        let unstarted = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: UUID()
        )
        try await first.start()
        let socketPath = (await first.socketPath).path
        await unstarted.stop()
        #expect(FileManager.default.fileExists(atPath: socketPath))
        await first.stop()
    }

    @Test
    func slowlorisHandshakeIsBoundedAndLengthPrefixedOnly() async throws {
        let root = URL(fileURLWithPath: "/tmp/mrs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: generation,
            clientHandshakeTimeout: .milliseconds(20),
            clientIdleTimeout: .milliseconds(20)
        )
        try await server.start()
        var fd = try connectUnixSocket(to: (await server.socketPath).path)
        defer { if fd >= 0 { Darwin.close(fd) } }
        try writeAll(fd: fd, data: Data([0]))
        #expect(waitForReadable(fd: fd, timeoutMilliseconds: 500))
        var buffer = [UInt8](repeating: 0, count: 1)
        #expect(Darwin.read(fd, &buffer, 1) == 0)
        Darwin.close(fd)
        fd = -1
        await server.stop()
    }

    @Test
    func newlineFramingIsRejectedByUnixSocketTransport() async throws {
        let root = URL(fileURLWithPath: "/tmp/mrn-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MillerRemoteBridgeServer(
            host: RemoteLiveHostRecorder().host(),
            homeDirectory: root,
            generation: generation
        )
        try await server.start()
        var fd = try connectUnixSocket(to: (await server.socketPath).path)
        defer { if fd >= 0 { Darwin.close(fd) } }
        var newlineFrame = Data(
            try RemoteLiveBridgeCodec.encodeFrame(
                .hello(requestID: UUID(), clientID: "miller-remote.gateway")
            ).dropFirst(4)
        )
        newlineFrame.append(0x0A)
        try writeAll(fd: fd, data: newlineFrame)
        #expect(waitForReadable(fd: fd, timeoutMilliseconds: 500))
        var buffer = [UInt8](repeating: 0, count: 1)
        #expect(Darwin.read(fd, &buffer, 1) == 0)
        Darwin.close(fd)
        fd = -1
        await server.stop()
    }
}

private actor RemoteLiveTestGate {
    private var opened = false
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        if !blocked {
            blocked = true
            let pending = blockedWaiters
            blockedWaiters.removeAll()
            pending.forEach { $0.resume() }
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func open() {
        opened = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let blockedWaiters = blockedWaiters
        self.blockedWaiters.removeAll()
        for waiter in blockedWaiters { waiter.resume() }
    }
}

private actor RemoteLiveReadiness {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        let pending = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        pending.forEach { $0.1.resume() }
    }

    func waitUntil(count expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { continuation in
            waiters.append((expected, continuation))
        }
    }
}

private actor RemoteLiveStartRaceHost {
    private let firstStartGate = RemoteLiveTestGate()
    private let secondStartGate = RemoteLiveTestGate()
    private var startCalls = 0

    nonisolated func host() -> MillerRemoteBridgeHost {
        MillerRemoteBridgeHost(
            start: { [self] _, _ in
                let call = await nextStartCall()
                if call == 1 {
                    await firstStartGate.wait()
                } else {
                    await secondStartGate.wait()
                }
                return "v=\(call)"
            },
            connected: { _ in },
            interrupt: { _ in },
            end: { _, _ in }
        )
    }

    func waitForFirstStart() async {
        await firstStartGate.waitUntilBlocked()
    }

    func waitForSecondStart() async {
        await secondStartGate.waitUntilBlocked()
    }

    func openFirstStart() async {
        await firstStartGate.open()
    }

    func openSecondStart() async {
        await secondStartGate.open()
    }

    private func nextStartCall() -> Int {
        startCalls += 1
        return startCalls
    }
}

private actor RemoteLiveHostRecorder {
    let answer = "v=0\r\no=- 3 4 IN IP4 127.0.0.1\r\n"
    private let endGate: RemoteLiveTestGate?
    private let activityGate: RemoteLiveTestGate?
    private var starts = 0
    private var connected = 0
    private var interrupts = 0
    private var ends: [RemoteLiveTerminalReason] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var endWaiters: [([RemoteLiveTerminalReason], CheckedContinuation<Void, Never>)] = []

    init(
        endGate: RemoteLiveTestGate? = nil,
        activityGate: RemoteLiveTestGate? = nil
    ) {
        self.endGate = endGate
        self.activityGate = activityGate
    }

    nonisolated func host() -> MillerRemoteBridgeHost {
        MillerRemoteBridgeHost(
            start: { [self] _, _ in
                await incrementStarts()
                return answer
            },
            connected: { [self] _ in await incrementConnected() },
            activity: { [self] _ in
                await activityGate?.wait()
            },
            interrupt: { [self] _ in await incrementInterrupts() },
            end: { [self] _, reason in
                await endGate?.wait()
                await recordEnd(reason)
            }
        )
    }

    func startCount() -> Int { starts }
    func connectedCount() -> Int { connected }
    func interruptCount() -> Int { interrupts }
    func endReasons() -> [RemoteLiveTerminalReason] { ends }

    func waitForStart() async {
        guard starts == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForEndReasons(_ reasons: [RemoteLiveTerminalReason]) async {
        guard ends != reasons else { return }
        await withCheckedContinuation { endWaiters.append((reasons, $0)) }
    }

    private func incrementStarts() {
        starts += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    private func incrementConnected() { connected += 1 }
    private func incrementInterrupts() { interrupts += 1 }
    private func recordEnd(_ reason: RemoteLiveTerminalReason) {
        ends.append(reason)
        let matching = endWaiters.filter { $0.0 == ends }
        endWaiters.removeAll { $0.0 == ends }
        matching.forEach { $0.1.resume() }
    }
}

private actor RemoteLiveStartScript {
    private var isFirst = true

    func start() throws -> String {
        if isFirst {
            isFirst = false
            throw RemoteLiveBridgeHostError.busy
        }
        return "v=0"
    }
}

private func connectUnixSocket(to path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var noSignal: Int32 = 1
    guard Darwin.setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        Darwin.close(fd)
        throw POSIXError(.EIO)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        Darwin.close(fd)
        throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        buffer.copyBytes(from: bytes)
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                fd,
                $0,
                socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
            )
        }
    }
    guard result == 0 else {
        Darwin.close(fd)
        throw POSIXError(.ECONNREFUSED)
    }
    return fd
}

private func writeAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(
                fd,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}

private func setAbortiveClose(_ fd: Int32) throws {
    var option = linger()
    option.l_onoff = 1
    option.l_linger = 0
    guard Darwin.setsockopt(
        fd,
        SOL_SOCKET,
        SO_LINGER,
        &option,
        socklen_t(MemoryLayout<linger>.size)
    ) == 0 else {
        throw POSIXError(.EIO)
    }
}

private func frame(_ body: Data) -> Data {
    var length = UInt32(body.count).bigEndian
    var result = Data()
    withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
    result.append(body)
    return result
}

private func waitForReadable(fd: Int32, timeoutMilliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return Darwin.poll(&descriptor, 1, timeoutMilliseconds) == 1
}

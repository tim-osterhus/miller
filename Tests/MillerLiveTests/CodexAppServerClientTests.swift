@testable import MillerLive
import Darwin
import Foundation
import MillerCore
import Testing

private actor RefreshRecorder {
    private(set) var calls = 0

    func refresh(accountID: String) -> CodexOAuthCredential {
        calls += 1
        return .init(
            accessToken: Data("replacement-token".utf8),
            accountID: accountID,
            planType: "plus"
        )
    }
}

private actor CleanupCompletionFlag {
    private(set) var isComplete = false
    private(set) var pendingReports = 0

    func markComplete() { isComplete = true }
    func reportPending() { pendingReports += 1 }
}

private actor CapabilityEventRecorder {
    private(set) var activities: [CodexCapabilityActivity] = []
    private(set) var approvals: [CapabilityApprovalRequest] = []

    func record(_ activity: CodexCapabilityActivity) {
        activities.append(activity)
    }

    func approve(_ request: CapabilityApprovalRequest) -> CapabilityApprovalDecision {
        approvals.append(request)
        return .allowOnce
    }
}

private let syntheticSHA256Fingerprint = "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"

private let syntheticWebRTCOffer = """
v=0\r
o=- 0 0 IN IP4 0.0.0.0\r
s=-\r
t=0 0\r
a=group:BUNDLE 0 1\r
m=audio 9 UDP/TLS/RTP/SAVPF 111\r
a=mid:0\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 \(syntheticSHA256Fingerprint)\r
a=setup:actpass\r
a=rtpmap:111 opus/48000/2\r
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
a=mid:1\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 \(syntheticSHA256Fingerprint)\r
a=setup:actpass\r
a=sctp-port:5000\r
a=max-message-size:262144\r
"""

@Suite(.serialized)
struct CodexAppServerClientTests {
    @Test
    func inventoriesPagedCodexAppsAndMCPWithoutDuplicatingTheMillerBridge() async throws {
        let profileID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let existing = try CapabilityDescriptor(
            id: CapabilityID(rawValue: "miller_mcp/calendar/list"),
            source: .millerMCP,
            serverID: "calendar",
            toolName: "list",
            displayName: "List events",
            summary: "Lists events",
            inputSchemaJSON: Data("{}".utf8),
            readOnlyHint: true,
            providerProfileIDs: [profileID],
            isAvailable: true
        )
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "typed-capability-inventory"
        ))
        let client = CodexAppServerClient(process: process)

        let catalog = try await client.inventoryCapabilities(
            requestID: "inventory-1",
            credential: credential,
            codexProviderProfileID: profileID,
            existingMillerCapabilities: [existing],
            timeout: .seconds(2)
        )

        #expect(catalog.descriptors.contains { descriptor in
            descriptor.id.rawValue == "codex_account/gmail/search"
                && descriptor.visibility == .providerManaged
                && descriptor.isCallable
        })
        #expect(catalog.descriptors.contains(existing))
        #expect(catalog.descriptors.filter {
            $0.id.rawValue == existing.id.rawValue
        }.count == 1)
        #expect(!catalog.descriptors.contains {
            $0.id.rawValue.contains("miller-capability-bridge")
        })
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func typedProviderApprovalUsesInjectedMillerResolverAndResponseChannel() async throws {
        let recorder = CapabilityEventRecorder()
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "typed-provider-approval"
        ))
        let client = CodexAppServerClient(
            process: process,
            resolveProviderApproval: { request in await recorder.approve(request) }
        )

        var messages: [CodexTypedMessage] = []
        for try await message in client.typedEvents(
            requestID: "typed-approval-1",
            credential: credential,
            model: "gpt-5.6-terra",
            cwd: repository.path,
            context: [],
            userText: "perform approved action",
            timeout: .seconds(2)
        ) {
            messages.append(message)
        }

        #expect(await recorder.approvals.count == 1)
        #expect(await recorder.approvals.first?.policy.requiresApproval == true)
        #expect(messages.contains {
            if case .turnCompleted(_, _, .completed) = $0 { true } else { false }
        })
        #expect(!process.isRunning)
    }

    @Test
    func realtimeCapabilityLifecycleIsSanitizedAndDoesNotEnterTranscriptEvents() async throws {
        let recorder = CapabilityEventRecorder()
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "realtime-capability"
        ))
        let client = CodexAppServerClient(
            process: process,
            onCapabilityActivity: { activity in await recorder.record(activity) }
        )

        let events = try await client.runUntilClosed(
            identity: identity,
            credential: credential,
            timeout: .seconds(2)
        )

        let activities = await recorder.activities
        #expect(activities.count == 2)
        #expect(activities.allSatisfy { activity in
            activity.visibility == .opaqueProviderActivity
                && !activity.summary.text.contains("private")
        })
        #expect(events.last == .closed(
            threadID: identity.threadID,
            reason: "synthetic-complete"
        ))
    }

    @Test
    func typedCapabilityWithWrongAuthorityCannotReachActivityCallback() async throws {
        let recorder = CapabilityEventRecorder()
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "typed-capability-wrong-authority"
        ))
        let client = CodexAppServerClient(
            process: process,
            onCapabilityActivity: { activity in await recorder.record(activity) }
        )

        await #expect(throws: (any Error).self) {
            for try await _ in client.typedEvents(
                requestID: "typed-wrong-authority-1",
                credential: credential,
                model: "gpt-5.6-terra",
                cwd: repository.path,
                context: [],
                userText: "do not execute",
                timeout: .seconds(2)
            ) {}
        }

        #expect(await recorder.activities.isEmpty)
        #expect(!process.isRunning)
    }

    @Test
    func realtimeCapabilityWithWrongAuthorityCannotReachActivityCallback() async throws {
        let recorder = CapabilityEventRecorder()
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "realtime-capability-wrong-authority"
        ))
        let client = CodexAppServerClient(
            process: process,
            onCapabilityActivity: { activity in await recorder.record(activity) }
        )

        await #expect(throws: (any Error).self) {
            _ = try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .seconds(2)
            )
        }

        #expect(await recorder.activities.isEmpty)
        #expect(!process.isRunning)
    }

    @Test(arguments: [
        "",
        "v=0\u{0000}\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n",
        String(repeating: "x", count: 65_537),
        """
        v=0\r
        o=- 0 0 IN IP4 0.0.0.0\r
        s=-\r
        t=0 0\r
        m=audio 9 UDP/TLS/RTP/SAVPF 111\r
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
        """,
    ])
    func preflightsInvalidOffersBeforeLaunchingTheHelper(offerSDP: String) async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/preflight-client-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "record-helper-launch", extraArguments: [marker.path]
        ))
        let root = process.temporaryRootURL
        let client = CodexAppServerClient(process: process)

        await #expect(throws: (any Error).self) {
            _ = try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                offerSDP: offerSDP,
                timeout: .seconds(2)
            )
        }

        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func missingOfferRefusalNeverLaunchesTheHelper() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/missing-offer-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "record-helper-launch", extraArguments: [marker.path]
        ))
        let root = process.temporaryRootURL
        let client = CodexAppServerClient(process: process)
        var iterator = client.eventsWithoutWebRTCOffer(
            identity: identity,
            credential: credential,
            timeout: .seconds(2)
        ).makeAsyncIterator()

        await #expect(throws: LiveProtocolError.invalidField) {
            _ = try await iterator.next()
        }

        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func malformedExactFingerprintAndSetupOffersNeverLaunchTheHelper() async throws {
        let malformedOffers = [
            syntheticWebRTCOffer.replacingOccurrences(
                of: syntheticSHA256Fingerprint, with: "00:11"
            ),
            syntheticWebRTCOffer.replacingOccurrences(
                of: syntheticSHA256Fingerprint, with: "\(syntheticSHA256Fingerprint):00"
            ),
            syntheticWebRTCOffer.replacingOccurrences(
                of: syntheticSHA256Fingerprint, with: "GG:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"
            ),
            syntheticWebRTCOffer.replacingOccurrences(
                of: "a=setup:actpass\r\n", with: "a=setup:actpass-suffix\r\n"
            ),
        ]
        for offerSDP in malformedOffers {
            let marker = repository.appendingPathComponent(
                ".artifacts/preflight-exact-sdp-\(UUID().uuidString.lowercased()).txt"
            )
            defer { try? FileManager.default.removeItem(at: marker) }
            let process = CodexAppServerProcess(configuration: try configuration(
                mode: "record-helper-launch", extraArguments: [marker.path]
            ))
            let client = CodexAppServerClient(process: process)

            await #expect(throws: LiveProtocolError.invalidField) {
                _ = try await client.runUntilClosed(
                    identity: identity,
                    credential: credential,
                    offerSDP: offerSDP,
                    timeout: .seconds(2)
                )
            }

            #expect(!process.isRunning)
            #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test
    func negotiationYieldsAcceptedAnswerBeforeActiveAdmission() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "webrtc-started-sdp-response-last"
        ))
        let client = CodexAppServerClient(process: process)
        let stream = client.events(
            identity: identity,
            credential: credential,
            offerSDP: syntheticWebRTCOffer,
            timeout: .seconds(2)
        )
        var received: [LiveSessionEvent] = []
        for try await event in stream {
            received.append(event)
            if case .sdp = event {
                #expect(client.sessionState == .starting)
                #expect(client.confirmPeerConnected(identity: identity))
            }
        }
        #expect(received.first == .sdp(threadID: identity.threadID, value: "v=0\r\ns=-\r\n"))
        #expect(received.dropFirst().first == .started(threadID: identity.threadID))
        #expect(received.last == .closed(threadID: identity.threadID, reason: "synthetic-complete"))
    }

    @Test
    func acceptsAnOpaqueUpstreamRealtimeContinuationID() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "upstream-session"))
        let client = CodexAppServerClient(process: process)
        let stream = client.events(
            identity: identity,
            credential: credential,
            offerSDP: syntheticWebRTCOffer,
            timeout: .seconds(2)
        )
        var received: [LiveSessionEvent] = []
        for try await event in stream {
            received.append(event)
            if case .sdp = event {
                #expect(client.confirmPeerConnected(identity: identity))
            }
        }
        #expect(received.first == .sdp(threadID: identity.threadID, value: "v=0\r\ns=-\r\n"))
        #expect(received.dropFirst().first == .started(threadID: identity.threadID))
        #expect(received.last == .closed(threadID: identity.threadID, reason: "synthetic-complete"))
    }

    @Test
    func stopOnSDPSendsOneStopSuppressesPublicStartedAndCleansUp() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/stop-on-sdp-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "stop-on-sdp", extraArguments: [marker.path]
        ))
        let client = CodexAppServerClient(process: process)
        var events: [LiveSessionEvent] = []

        for try await event in client.events(
            identity: identity,
            credential: credential,
            offerSDP: syntheticWebRTCOffer,
            timeout: .seconds(2)
        ) {
            events.append(event)
            if case .sdp = event {
                #expect(client.sessionState == .starting)
                #expect(try client.requestStop(identity: identity))
                #expect(!client.confirmPeerConnected(identity: identity))
            }
        }

        #expect(events.first == .sdp(threadID: identity.threadID, value: "v=0\r\ns=-\r\n"))
        #expect(!events.contains(.started(threadID: identity.threadID)))
        #expect(events.last == .closed(threadID: identity.threadID, reason: "stopped"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "stop\n")
        #expect(client.sessionState == .closed)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func closedEventTerminatesPersistentHelperWithoutWaitingForEOF() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "persistent"))
        let client = CodexAppServerClient(process: process)
        let events = try await client.runUntilClosed(
            identity: identity,
            credential: credential,
            timeout: .seconds(2)
        )
        #expect(events.last == .closed(threadID: "thread-1", reason: "synthetic-complete"))
        #expect(client.sessionState == .closed)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func streamingSurfacePublishesBeforeTheSessionCloses() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "wait-stream-close"))
        let client = CodexAppServerClient(process: process)
        let stream = client.events(
            identity: identity,
            credential: credential,
            timeout: .seconds(2)
        )
        var received: [LiveSessionEvent] = []
        for try await event in stream {
            received.append(event)
            if case .sdp = event {
                #expect(client.confirmPeerConnected(identity: identity))
            }
            if case .transcriptDelta = event {
                #expect(process.isRunning)
                #expect(try client.requestStop(identity: identity))
            }
        }
        #expect(received.first == .sdp(threadID: identity.threadID, value: "v=0\r\ns=-\r\n"))
        #expect(received.dropFirst().first == .started(threadID: identity.threadID))
        #expect(received.contains(.transcriptDelta(
            threadID: identity.threadID,
            role: "assistant",
            delta: "streaming"
        )))
        #expect(received.last == .closed(threadID: identity.threadID, reason: "stopped"))
    }

    @Test
    func appendAudioIsActiveOnlyBoundedAndResponseCorrelated() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "wait-append"))
        let client = CodexAppServerClient(process: process)
        let run = Task {
            try await client.runUntilClosed(
                identity: identity, credential: credential, timeout: .seconds(2)
            )
        }
        let frame = try inputFrame()
        #expect(throws: LiveSessionError.invalidSequence) {
            try client.appendAudio(frame, identity: identity)
        }
        try await waitUntil { client.sessionState == .active }
        for _ in 0..<4 { try client.appendAudio(frame, identity: identity) }
        try await waitUntil { client.unacknowledgedAudioCount == 0 }
        #expect(try client.requestStop(identity: identity))
        _ = try await run.value
    }

    @Test
    func fifthUnacknowledgedChunkFailsWithSanitizedBackpressure() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "hold-append"))
        let client = CodexAppServerClient(process: process)
        let run = Task {
            try await client.runUntilClosed(
                identity: identity, credential: credential, timeout: .seconds(2)
            )
        }
        try await waitUntil { client.sessionState == .active }
        let frame = try inputFrame()
        for _ in 0..<4 { try client.appendAudio(frame, identity: identity) }
        #expect(throws: CodexAppServerClientError.audioBackpressure) {
            try client.appendAudio(frame, identity: identity)
        }
        await #expect(throws: (any Error).self) { _ = try await run.value }
        #expect(client.sessionState == .failed)
        #expect(!process.isRunning)
    }

    @Test
    func createsTransientHelperThreadBeforeRealtimeAndKeepsMillerIdentitySeparate() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "require-thread-start"))
        let client = CodexAppServerClient(process: process)
        let events = try await client.runUntilClosed(
            identity: identity, credential: credential, timeout: .seconds(2)
        )
        #expect(events.first == .sdp(threadID: "thread-1", value: "v=0\r\ns=-\r\n"))
        #expect(events.dropFirst().first == .started(threadID: "thread-1"))
        #expect(client.sessionState == .closed)
    }

    @Test(arguments: [
        "thread-response-before-login-notifications",
        "realtime-response-before-thread-started",
        "realtime-notification-before-response",
        "startup-out-of-band-notifications",
        "active-profile-exact",
        "forward-thread-metadata",
        "account-completed-unknown-field",
        "account-updated-unknown-field",
        "thread-shape-missing",
        "thread-shape-extra",
    ])
    func acceptsCorrelatedStartupResponsesBeforeRequiredNotifications(mode: String) async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: mode))
        let client = CodexAppServerClient(process: process)
        let events = try await client.runUntilClosed(
            identity: identity, credential: credential, timeout: .seconds(2)
        )
        #expect(events.first == .sdp(threadID: identity.threadID, value: "v=0\r\ns=-\r\n"))
        #expect(events.dropFirst().first == .started(threadID: identity.threadID))
        #expect(events.last == .closed(threadID: identity.threadID, reason: "synthetic-complete"))
        #expect(client.sessionState == .closed)
    }

    @Test(arguments: [
        ("unknown-field", "initializeProtocolMismatch"),
        ("account-updated-invalid", "threadStartProtocolMismatch"),
    ])
    func startupProtocolMismatchReportsOnlyItsPhase(
        mode: String,
        expectedCase: String
    ) async throws {
        let client = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: mode))
        )

        do {
            _ = try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .seconds(2)
            )
            Issue.record("Expected a startup protocol mismatch")
        } catch {
            #expect(String(reflecting: error).contains(expectedCase))
        }
    }

    @Test(arguments: [
        ("realtime-start-rejected", ".rejected"),
        ("realtime-start-error", ".failed"),
        ("realtime-start-closed", ".closed"),
        ("realtime-start-malformed", ".decodeOrFrameMismatch"),
        ("duplicate-realtime-response", ".responseOrder"),
        ("realtime-duplicate-thread-started", ".threadStartOrder"),
        ("started-v1", ".startedOrderOrVersion"),
        ("sdp-wrong-thread", ".sdpOrderOrThread"),
        ("refresh", ".credentialRefresh"),
        ("realtime-item-before-start", ".other"),
        ("realtime-start-eof", ".eof"),
    ])
    func realtimeStartFailuresExposeOnlyFixedDiagnosticClasses(
        mode: String,
        expectedDetail: String
    ) async throws {
        let client = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: mode))
        )

        do {
            _ = try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .seconds(2)
            )
            Issue.record("Expected a realtime-start diagnostic")
        } catch {
            #expect(String(reflecting: error).contains(expectedDetail))
            #expect(!String(reflecting: error).contains("synthetic provider diagnostic"))
        }
    }

    @Test(arguments: [
        ("login-response-extra", "loginFrameProtocolMismatch(MillerLive.CodexLoginFrameKind.responseResult, Optional(MillerLive.LiveProtocolError.unknownField))"),
        ("login-unexpected-notification", "loginSequenceProtocolMismatch"),
    ])
    func loginProtocolMismatchDistinguishesFrameFromSequence(
        mode: String,
        expectedCase: String
    ) async throws {
        let client = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: mode))
        )

        do {
            _ = try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .seconds(2)
            )
            Issue.record("Expected a login protocol mismatch")
        } catch {
            #expect(String(reflecting: error).contains(expectedCase))
        }
    }

    @Test
    func refusesMissingOrIncorrectTaskPrivateRealtimeFeatureConfiguration() async throws {
        let rejectedConfigurations: [Data?] = [
            nil,
            Data("[features]\nrealtime_conversation = false\n".utf8),
            Data("[features]\nrealtime_conversation = true\n\n[realtime]\nversion = \"v2\"\n".utf8),
        ]
        for featureConfig in rejectedConfigurations {
            let configuration = try CodexAppServerProcess.Configuration(
                executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
                arguments: [fixture.path, "require-thread-start"],
                temporaryParentURL: repository.appendingPathComponent(".artifacts"),
                terminationGrace: .milliseconds(100),
                testRealtimeFeatureConfig: featureConfig
            )
            let client = CodexAppServerClient(process: .init(configuration: configuration))
            await #expect(throws: (any Error).self) {
                _ = try await client.runUntilClosed(
                    identity: identity, credential: credential, timeout: .seconds(2)
                )
            }
        }
    }

    @Test(arguments: ["wait-stop", "wait-stop-close-first"])
    func publicStopIsFencedIdempotentAndWaitsForResponseAndClose(mode: String) async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: mode))
        let client = CodexAppServerClient(process: process)
        let run = Task {
            try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .seconds(2)
            )
        }
        try await waitUntil { client.sessionState == .active }
        #expect(throws: LiveSessionError.staleGeneration) {
            try client.requestStop(identity: .init(
                requestID: "request-1",
                threadID: "thread-1",
                generation: 3
            ))
        }
        #expect(try client.requestStop(identity: identity))
        #expect(try !client.requestStop(identity: identity))
        let events = try await run.value
        #expect(events.last == .closed(threadID: "thread-1", reason: "stopped"))
        #expect(!process.isRunning)
    }

    @Test
    func refreshUsesNewHostCredentialAndFencesAccountAndReason() async throws {
        let recorder = RefreshRecorder()
        let success = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: "refresh")),
            refreshProvider: { accountID in await recorder.refresh(accountID: accountID) }
        )
        _ = try await success.runUntilClosed(
            identity: identity,
            credential: credential,
            timeout: .seconds(2)
        )
        #expect(await recorder.calls == 1)

        for mode in ["refresh-mismatch", "refresh-invalid-reason"] {
            let client = CodexAppServerClient(
                process: CodexAppServerProcess(configuration: try configuration(mode: mode)),
                refreshProvider: { accountID in await recorder.refresh(accountID: accountID) }
            )
            await #expect(throws: (any Error).self) {
                _ = try await client.runUntilClosed(
                    identity: identity,
                    credential: credential,
                    timeout: .seconds(2)
                )
            }
        }

        let rejected = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: "refresh")),
            refreshProvider: { _ in throw CodexAppServerClientError.credentialRejected }
        )
        await #expect(throws: CodexAppServerClientError.credentialRejected) {
            _ = try await rejected.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .seconds(2)
            )
        }
    }

    @Test
    func integerServerRefreshIDIsReturnedAsAnInteger() async throws {
        let recorder = RefreshRecorder()
        let client = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: "refresh-integer-id")),
            refreshProvider: { accountID in await recorder.refresh(accountID: accountID) }
        )
        _ = try await client.runUntilClosed(
            identity: identity, credential: credential, timeout: .seconds(2)
        )
        #expect(await recorder.calls == 1)
    }

    @Test
    func newRunResetsRetainedTerminalStateOnlyWhenItBegins() async throws {
        let first = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: "persistent"))
        )
        _ = try await first.runUntilClosed(identity: identity, credential: credential, timeout: .seconds(2))
        #expect(first.sessionState == .closed)
        let nextIdentity = LiveSessionIdentity(
            requestID: "request-2", threadID: "thread-2", generation: 5
        )
        _ = try await first.runUntilClosed(
            identity: nextIdentity, credential: credential, timeout: .seconds(2)
        )
        #expect(first.sessionState == .closed)

        let failed = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: "realtime-error"))
        )
        await #expect(throws: CodexAppServerClientError.sessionFailed) {
            _ = try await failed.runUntilClosed(identity: identity, credential: credential, timeout: .seconds(2))
        }
        #expect(failed.sessionState == .failed)

        let startupFailure = CodexAppServerClient(
            process: CodexAppServerProcess(configuration: try configuration(mode: "login-error"))
        )
        await #expect(throws: (any Error).self) {
            _ = try await startupFailure.runUntilClosed(
                identity: identity, credential: credential, timeout: .seconds(2)
            )
        }
        #expect(startupFailure.sessionState == .failed)
    }

    @Test
    func concurrentSecondStartIsRejectedWithoutMutatingAdmittedSession() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "wait-stop"))
        let client = CodexAppServerClient(process: process)
        let admitted = Task {
            try await client.runUntilClosed(
                identity: identity, credential: credential, timeout: .seconds(2)
            )
        }
        try await waitUntil { client.sessionState == .active }

        let rejectedIdentity = LiveSessionIdentity(
            requestID: "request-2", threadID: "thread-2", generation: 5
        )
        await #expect(throws: CodexAppServerClientError.sessionAlreadyActive) {
            _ = try await client.runUntilClosed(
                identity: rejectedIdentity, credential: credential, timeout: .seconds(2)
            )
        }
        #expect(client.sessionState == .active)
        #expect(process.isRunning)
        #expect(try client.requestStop(identity: identity))
        let events = try await admitted.value
        #expect(events.last == .closed(threadID: "thread-1", reason: "stopped"))
        #expect(client.sessionState == .closed)
    }

    @Test
    func privateRootRemovalFailureRetainsClientAdmissionUntilCleanupSucceeds() async throws {
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/cleanup-fence-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent,
            withIntermediateDirectories: true
        )
        defer {
            _ = chmod(temporaryParent.path, 0o700)
            try? FileManager.default.removeItem(at: temporaryParent)
        }
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, "wait-stop"],
            temporaryParentURL: temporaryParent,
            terminationGrace: .milliseconds(100),
            cleanupPendingDelay: .milliseconds(100)
        ))
        let client = CodexAppServerClient(process: process)
        let completion = CleanupCompletionFlag()
        let first = Task {
            do {
                let events = try await client.runUntilClosed(
                    identity: identity,
                    credential: credential,
                    timeout: .seconds(2),
                    onCleanupPending: { await completion.reportPending() }
                )
                await completion.markComplete()
                return events
            } catch {
                await completion.markComplete()
                throw error
            }
        }
        try await waitUntil { client.sessionState == .active }
        #expect(chmod(temporaryParent.path, 0o500) == 0)
        #expect(try client.requestStop(identity: identity))
        try await waitUntil { client.sessionState == .closed }
        try await Task.sleep(for: .milliseconds(300))

        #expect(!(await completion.isComplete))
        #expect(await completion.pendingReports == 1)
        #expect(FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
        let secondIdentity = LiveSessionIdentity(
            requestID: "request-2",
            threadID: "thread-2",
            generation: 5
        )
        await #expect(throws: CodexAppServerClientError.sessionAlreadyActive) {
            _ = try await client.runUntilClosed(
                identity: secondIdentity,
                credential: credential,
                timeout: .milliseconds(300)
            )
        }

        #expect(chmod(temporaryParent.path, 0o700) == 0)
        let events = try await first.value
        #expect(await completion.pendingReports == 1)
        #expect(events.last == .closed(threadID: identity.threadID, reason: "stopped"))
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func stopBeforeClientAdmissionIsRetainedAndPreventsHelperStartup() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "wait-stop"))
        let client = CodexAppServerClient(process: process)

        _ = try? client.requestStop(identity: identity)
        let events = try await client.runUntilClosed(
            identity: identity,
            credential: credential,
            timeout: .milliseconds(300)
        )

        #expect(events.last == .closed(
            threadID: identity.threadID,
            reason: "stopped-during-startup"
        ))
        #expect(client.sessionState == .closed)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func invalidOfferClearsItsRetainedStopBeforeTheNextSessionStarts() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "persistent"))
        let client = CodexAppServerClient(process: process)
        #expect(try client.requestStop(identity: identity))

        await #expect(throws: LiveProtocolError.invalidField) {
            _ = try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                offerSDP: "",
                timeout: .seconds(2)
            )
        }

        let nextIdentity = LiveSessionIdentity(
            requestID: "request-2", threadID: "thread-2", generation: 5
        )
        let events = try await client.runUntilClosed(
            identity: nextIdentity,
            credential: credential,
            timeout: .seconds(2)
        )

        #expect(events.first == .sdp(threadID: nextIdentity.threadID, value: "v=0\r\ns=-\r\n"))
        #expect(events.dropFirst().first == .started(threadID: nextIdentity.threadID))
        #expect(events.last == .closed(threadID: nextIdentity.threadID, reason: "synthetic-complete"))
        #expect(client.sessionState == .closed)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func invalidOfferDoesNotClearAnUnrelatedRetainedStop() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "persistent"))
        let client = CodexAppServerClient(process: process)
        let retainedIdentity = LiveSessionIdentity(
            requestID: "request-2", threadID: "thread-2", generation: 5
        )
        #expect(try client.requestStop(identity: retainedIdentity))

        await #expect(throws: LiveProtocolError.invalidField) {
            _ = try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                offerSDP: "",
                timeout: .seconds(2)
            )
        }

        let events = try await client.runUntilClosed(
            identity: retainedIdentity,
            credential: credential,
            timeout: .seconds(2)
        )

        #expect(events.last == .closed(
            threadID: retainedIdentity.threadID,
            reason: "stopped-during-startup"
        ))
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func reusedClientRetainsSecondSessionStopBeforeAdmission() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/reused-client-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "reuse-second-wait-stop",
            extraArguments: [marker.path]
        ))
        let client = CodexAppServerClient(process: process)
        _ = try await client.runUntilClosed(
            identity: identity,
            credential: credential,
            timeout: .seconds(2)
        )
        let secondIdentity = LiveSessionIdentity(
            requestID: "request-2",
            threadID: "thread-2",
            generation: 5
        )

        _ = try? client.requestStop(identity: secondIdentity)
        let events = try await client.runUntilClosed(
            identity: secondIdentity,
            credential: credential,
            timeout: .milliseconds(300)
        )

        #expect(events.last == .closed(
            threadID: secondIdentity.threadID,
            reason: "stopped-during-startup"
        ))
        #expect(client.sessionState == .closed)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test(arguments: [
        "wait-initialize", "wait-login", "wait-thread-start",
        "wait-after-thread-created", "wait-realtime-response",
        "wait-after-realtime-response",
    ])
    func stopDuringStartupIsGenerationFencedAndTerminal(mode: String) async throws {
        let marker = repository.appendingPathComponent(".artifacts/\(mode)-phase.txt")
        try? FileManager.default.removeItem(at: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = CodexAppServerProcess(
            configuration: try configuration(mode: mode, extraArguments: [marker.path])
        )
        let client = CodexAppServerClient(process: process)
        let run = Task {
            try await client.runUntilClosed(
                identity: identity, credential: credential, timeout: .seconds(2)
            )
        }
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        #expect(throws: LiveSessionError.staleGeneration) {
            try client.requestStop(identity: .init(
                requestID: identity.requestID,
                threadID: identity.threadID,
                generation: identity.generation + 1
            ))
        }
        #expect(try client.requestStop(identity: identity))
        await #expect(throws: (any Error).self) { _ = try await run.value }
        #expect(client.sessionState == .closed)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test(arguments: [
        "wrong-request", "wrong-thread", "duplicate-terminal",
        "late-event", "login-error", "malformed", "unknown-method",
        "unknown-field", "oversized", "realtime-error", "crash-after-start",
        "hang-client", "feature-missing", "feature-incorrect", "unsafe-thread-response",
        "started-v1",
        "account-completed-invalid",
        "account-updated-invalid",
        "login-notifications-before-response", "account-updated-before-completed",
        "duplicate-account-completed",
        "thread-started-wrong-thread", "thread-started-unknown-field",
        "thread-notification-before-response", "duplicate-thread-started",
        "duplicate-realtime-started",
        "item-wrong-thread", "item-unknown-field",
        "thread-shape-wrong",
        "unexpected-sdp", "sdp-wrong-thread", "duplicate-sdp", "missing-sdp",
    ])
    func rejectsSyntheticProtocolLifecycleAndTimeoutFailures(mode: String) async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: mode))
        let client = CodexAppServerClient(process: process)
        await #expect(throws: (any Error).self) {
            _ = try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .milliseconds(500)
            )
        }
        #expect(!process.isRunning)
    }

    @Test
    func cancellationTerminatesHelperAndCleansRoot() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "hang-client"))
        let client = CodexAppServerClient(process: process)
        let run = Task {
            try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .seconds(5)
            )
        }
        try await waitUntil { process.isRunning }
        run.cancel()
        await #expect(throws: (any Error).self) { _ = try await run.value }
        try await waitUntil { !process.isRunning }
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func cancellationDuringNegotiationBeforeAnswerCleansTheHelper() async throws {
        let marker = repository.appendingPathComponent(".artifacts/negotiation-marker.txt")
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "wait-after-realtime-started", extraArguments: [marker.path]
        ))
        let client = CodexAppServerClient(process: process)
        let run = Task {
            try await client.runUntilClosed(
                identity: identity, credential: credential, timeout: .seconds(2)
            )
        }
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        run.cancel()
        await #expect(throws: (any Error).self) { _ = try await run.value }
        try await waitUntil { !process.isRunning }
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func startupTimeoutDoesNotTerminateAnActiveSession() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "wait-stop"))
        let client = CodexAppServerClient(process: process)
        let run = Task {
            try await client.runUntilClosed(
                identity: identity,
                credential: credential,
                timeout: .milliseconds(300)
            )
        }

        try await waitUntil { client.sessionState == .active }
        try await Task.sleep(for: .milliseconds(450))

        #expect(client.sessionState == .active)
        #expect(process.isRunning)
        #expect(try client.requestStop(identity: identity))
        let events = try await run.value
        #expect(events.last == .closed(threadID: identity.threadID, reason: "stopped"))
    }

    private var identity: LiveSessionIdentity {
        .init(requestID: "request-1", threadID: "thread-1", generation: 4)
    }

    private var credential: CodexOAuthCredential {
        .init(accessToken: Data("initial-token".utf8), accountID: "account-1", planType: nil)
    }

    private func inputFrame() throws -> LiveAudioFrame {
        try LiveAudioFrame(
            data: Data(repeating: 0, count: 4_800),
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: 2_400,
            itemID: nil
        )
    }

    private func configuration(
        mode: String, extraArguments: [String] = []
    ) throws -> CodexAppServerProcess.Configuration {
        try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, mode] + extraArguments,
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100)
        )
    }

    private var fixture: URL {
        Bundle.module.url(
            forResource: "fake-codex-app-server",
            withExtension: "mjs",
            subdirectory: "Fixtures"
        )!
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func waitUntil(
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw LiveProcessError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}

private extension CodexAppServerClient {
    func runUntilClosed(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        timeout: Duration = .seconds(30),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) async throws -> [LiveSessionEvent] {
        var received: [LiveSessionEvent] = []
        for try await event in events(
            identity: identity,
            credential: credential,
            timeout: timeout,
            onCleanupPending: onCleanupPending
        ) {
            if case .sdp = event {
                _ = confirmPeerConnected(identity: identity)
            }
            received.append(event)
        }
        try Task.checkCancellation()
        return received
    }

    func events(
        identity: LiveSessionIdentity,
        credential: CodexOAuthCredential,
        timeout: Duration = .seconds(30),
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) -> AsyncThrowingStream<LiveSessionEvent, Error> {
        events(
            identity: identity,
            credential: credential,
            offerSDP: syntheticWebRTCOffer,
            timeout: timeout,
            onCleanupPending: onCleanupPending
        )
    }
}

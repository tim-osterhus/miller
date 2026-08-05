@testable import MillerLive
import Foundation
import Testing

private let syntheticSHA256Fingerprint = "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"

private let syntheticBrowserWebRTCOffer = """
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

struct CodexAppServerProtocolTests {
    private let protocolCodec = CodexAppServerProtocol(
        maximumFrameBytes: 2_048,
        maximumTextBytes: 32,
        maximumAudioBytes: 32
    )

    @Test
    func encodesOnlyExactWebRTCStartFieldsWithANullUpstreamContinuationID() throws {
        let codec = CodexAppServerProtocol(
            maximumFrameBytes: 2_048,
            maximumTextBytes: 768,
            maximumAudioBytes: 32
        )
        let offer = syntheticBrowserWebRTCOffer

        let start = try object(codec.realtimeStartRequest(
            id: "request-1:start",
            threadID: "thread-1",
            offerSDP: offer
        ))
        let params = try #require(start["params"] as? [String: Any])
        #expect(params.keys.sorted() == [
            "outputModality", "prompt", "realtimeSessionId", "threadId", "transport", "version", "voice",
        ])
        #expect(params["threadId"] as? String == "thread-1")
        #expect(params["version"] as? String == "v3")
        #expect(params["realtimeSessionId"] is NSNull)
        #expect(params["voice"] is NSNull)
        let prompt = try #require(params["prompt"] as? String)
        #expect(prompt.contains("You are Miller"))
        #expect(prompt.contains("current local date and time"))
        #expect(prompt.contains("Do not invent"))
        let transport = try #require(params["transport"] as? [String: Any])
        #expect(transport.keys.sorted() == ["sdp", "type"])
        #expect(transport["type"] as? String == "webrtc")
        #expect(transport["sdp"] as? String == offer)

        for invalidOffer in ["", "not-sdp", "v=0\u{0000}\r\nm=audio"] {
            #expect(throws: LiveProtocolError.invalidField) {
                try codec.realtimeStartRequest(
                    id: "request-1:start",
                    threadID: "thread-1",
                    offerSDP: invalidOffer
                )
            }
        }
        #expect(throws: LiveProtocolError.payloadTooLarge) {
            try codec.realtimeStartRequest(
                id: "request-1:start",
                threadID: "thread-1",
                offerSDP: String(repeating: "x", count: 769)
            )
        }
    }

    @Test
    func realtimePromptUsesTheSuppliedLocalClockAndTimeZone() throws {
        let timeZone = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 0, minute: 45
        )))

        let prompt = CodexRealtimePrompt.make(now: now, timeZone: timeZone)

        #expect(prompt.contains("Tuesday, August 4, 2026 at 12:45 AM HST"))
        #expect(prompt.contains("Pacific/Honolulu"))
    }

    @Test
    func rejectsWebRTCOffersMissingEssentialBrowserTransportShape() throws {
        let codec = CodexAppServerProtocol(
            maximumFrameBytes: 2_048,
            maximumTextBytes: 768,
            maximumAudioBytes: 32
        )
        let invalidOffers = [
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: "a=group:BUNDLE 0 1\r\n", with: ""
            ),
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: "a=group:BUNDLE 0 1\r\n", with: "a=group:BUNDLE 0\r\n"
            ),
            syntheticBrowserWebRTCOffer.replacingOccurrences(of: "a=ice-ufrag:u\r\n", with: ""),
            syntheticBrowserWebRTCOffer.replacingOccurrences(of: "a=ice-pwd:p\r\n", with: ""),
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: "a=fingerprint:sha-256 \(syntheticSHA256Fingerprint)\r\n", with: ""
            ),
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: syntheticSHA256Fingerprint, with: ":"
            ),
            syntheticBrowserWebRTCOffer.replacingOccurrences(of: "a=setup:actpass\r\n", with: ""),
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: "a=rtpmap:111 opus/48000/2\r\n", with: ""
            ),
            syntheticBrowserWebRTCOffer.replacingOccurrences(of: "a=sctp-port:5000\r\n", with: ""),
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: "a=max-message-size:262144", with: ""
            ),
        ]

        for offer in invalidOffers {
            #expect(throws: LiveProtocolError.invalidField) {
                try codec.realtimeStartRequest(
                    id: "request-1:start",
                    threadID: "thread-1",
                    offerSDP: offer
                )
            }
        }
    }

    @Test
    func rejectsMalformedExactSHA256FingerprintAndSetupLines() throws {
        let codec = CodexAppServerProtocol(
            maximumFrameBytes: 2_048,
            maximumTextBytes: 768,
            maximumAudioBytes: 32
        )
        let malformedOffers = [
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: syntheticSHA256Fingerprint, with: "00:11"
            ),
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: syntheticSHA256Fingerprint, with: "\(syntheticSHA256Fingerprint):00"
            ),
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: syntheticSHA256Fingerprint, with: "GG:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"
            ),
            syntheticBrowserWebRTCOffer.replacingOccurrences(
                of: "a=setup:actpass\r\n", with: "a=setup:actpass-suffix\r\n"
            ),
        ]

        for offer in malformedOffers {
            #expect(throws: LiveProtocolError.invalidField) {
                try codec.realtimeStartRequest(
                    id: "request-1:start",
                    threadID: "thread-1",
                    offerSDP: offer
                )
            }
        }
    }

    @Test
    func encodesExperimentalInitializationAndRealtimeStart() throws {
        let initialize = try object(protocolCodec.initializeRequest(id: "request-1:initialize"))
        #expect(initialize["method"] as? String == "initialize")
        let params = try #require(initialize["params"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(capabilities.keys.sorted() == ["experimentalApi"])
        #expect(capabilities["experimentalApi"] as? Bool == true)

        let startCodec = CodexAppServerProtocol(
            maximumFrameBytes: 2_048,
            maximumTextBytes: 768,
            maximumAudioBytes: 32
        )
        let start = try object(startCodec.realtimeStartRequest(
            id: "request-1:start",
            threadID: "thread-1",
            offerSDP: syntheticBrowserWebRTCOffer
        ))
        #expect(start["method"] as? String == "thread/realtime/start")
        let startParams = try #require(start["params"] as? [String: Any])
        #expect(startParams.keys.sorted() == [
            "outputModality", "prompt", "realtimeSessionId", "threadId", "transport", "version", "voice",
        ])
        #expect(startParams["threadId"] as? String == "thread-1")
        #expect(startParams["version"] as? String == "v3")
        #expect(startParams["realtimeSessionId"] is NSNull)
        let transport = try #require(startParams["transport"] as? [String: Any])
        #expect(transport["type"] as? String == "webrtc")

        let frame = try LiveAudioFrame(
            data: Data(repeating: 0x01, count: 4_800),
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: 2_400,
            itemID: nil
        )
        let appendCodec = CodexAppServerProtocol(
            maximumFrameBytes: 10_000,
            maximumTextBytes: 32,
            maximumAudioBytes: 4_800
        )
        let append = try object(appendCodec.realtimeAppendAudioRequest(
            id: "request-1:append:0",
            threadID: "thread-1",
            audio: frame
        ))
        #expect(append["method"] as? String == "thread/realtime/appendAudio")
        let appendParams = try #require(append["params"] as? [String: Any])
        #expect(appendParams.keys.sorted() == ["audio", "threadId"])
        let encodedAudio = try #require(appendParams["audio"] as? [String: Any])
        #expect(encodedAudio.keys.sorted() == [
            "data", "itemId", "numChannels", "sampleRate", "samplesPerChannel",
        ])
        #expect(encodedAudio["sampleRate"] as? Int == 24_000)
        #expect(encodedAudio["numChannels"] as? Int == 1)
        #expect(encodedAudio["samplesPerChannel"] as? Int == 2_400)
    }

    @Test
    func encodesEphemeralSafeThreadStartAndDecodesStrictHelperThreadIdentity() throws {
        let request = try object(protocolCodec.threadStartRequest(
            id: "request-1:thread-start",
            cwd: "/private/tmp/miller-live"
        ))
        #expect(request["method"] as? String == "thread/start")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params.keys.sorted() == ["approvalPolicy", "cwd", "ephemeral", "sandbox"])
        #expect(params["ephemeral"] as? Bool == true)
        #expect(params["approvalPolicy"] as? String == "never")
        #expect(params["sandbox"] as? String == "read-only")

        let response = try protocolCodec.decode(line(threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        )))
        #expect(response == .threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        ))
    }

    @Test
    func rejectsMissingOrInvalidExactPinThreadStartFields() throws {
        let source = try object(Data(threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        ).utf8))
        for field in [
            "runtimeWorkspaceRoots", "multiAgentMode", "serviceTier", "instructionSources",
            "activePermissionProfile", "reasoningEffort",
        ] {
            var root = source
            var result = try #require(root["result"] as? [String: Any])
            result.removeValue(forKey: field)
            root["result"] = result
            let data = try JSONSerialization.data(withJSONObject: root)
            #expect(throws: LiveProtocolError.missingField) { try protocolCodec.decode(data) }
        }
        for (field, value) in [
            ("runtimeWorkspaceRoots", [7] as Any),
            ("multiAgentMode", 7 as Any),
            ("reasoningEffort", 7 as Any),
        ] {
            var root = source
            var result = try #require(root["result"] as? [String: Any])
            result[field] = value
            root["result"] = result
            let data = try JSONSerialization.data(withJSONObject: root)
            #expect(throws: LiveProtocolError.invalidField) { try protocolCodec.decode(data) }
        }
        var malformedMetadata = source
        var malformedMetadataResult = try #require(malformedMetadata["result"] as? [String: Any])
        malformedMetadataResult["activePermissionProfile"] = 7
        malformedMetadata["result"] = malformedMetadataResult
        #expect(throws: LiveProtocolError.invalidField) {
            try protocolCodec.decode(try JSONSerialization.data(withJSONObject: malformedMetadata))
        }

        var invented = source
        var inventedResult = try #require(invented["result"] as? [String: Any])
        inventedResult["permissionProfile"] = NSNull()
        invented["result"] = inventedResult
        #expect(throws: LiveProtocolError.unknownField) {
            try protocolCodec.decode(try JSONSerialization.data(withJSONObject: invented))
        }
    }

    @Test
    func requiresExactExperimentalThreadShapeWithoutLooseningUnknownFields() throws {
        let source = try object(Data(threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        ).utf8))
        let exactFields = [
            "extra", "parentThreadId", "recencyAt", "historyMode", "canAcceptDirectInput",
        ]
        for field in exactFields {
            var root = source
            var result = try #require(root["result"] as? [String: Any])
            var thread = try #require(result["thread"] as? [String: Any])
            thread.removeValue(forKey: field)
            result["thread"] = thread
            root["result"] = result
            #expect(throws: LiveProtocolError.missingField) {
                try protocolCodec.decode(try JSONSerialization.data(withJSONObject: root))
            }
        }

        let hostile: [(String, Any)] = [
            ("extra", "not-an-object"),
            ("parentThreadId", 7),
            ("recencyAt", "now"),
            ("historyMode", 7),
            ("canAcceptDirectInput", "yes"),
        ]
        for (field, value) in hostile {
            var root = source
            var result = try #require(root["result"] as? [String: Any])
            var thread = try #require(result["thread"] as? [String: Any])
            thread[field] = value
            result["thread"] = thread
            root["result"] = result
            #expect(throws: LiveProtocolError.invalidField) {
                try protocolCodec.decode(try JSONSerialization.data(withJSONObject: root))
            }
        }

        var extraRoot = source
        var extraResult = try #require(extraRoot["result"] as? [String: Any])
        var extraThread = try #require(extraResult["thread"] as? [String: Any])
        extraThread["future"] = true
        extraResult["thread"] = extraThread
        extraRoot["result"] = extraResult
        #expect(throws: LiveProtocolError.unknownField) {
            try protocolCodec.decode(try JSONSerialization.data(withJSONObject: extraRoot))
        }
    }

    @Test
    func admitsExactNonNullVariantsInThePinnedThreadResponse() throws {
        var root = try object(Data(threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        ).utf8))
        var result = try #require(root["result"] as? [String: Any])
        result["serviceTier"] = "default"
        result["instructionSources"] = ["file:///private/tmp/AGENTS.md"]
        result["activePermissionProfile"] = [
            "id": ":read-only", "extends": NSNull(),
        ]
        result["reasoningEffort"] = "high"
        var thread = try #require(result["thread"] as? [String: Any])
        thread["extra"] = NSNull()
        thread["forkedFromId"] = "parent-fork"
        thread["parentThreadId"] = "parent-thread"
        thread["historyMode"] = "paginated"
        thread["recencyAt"] = 2
        thread["canAcceptDirectInput"] = true
        thread["threadSource"] = NSNull()
        thread["gitInfo"] = ["sha": "abc", "branch": NSNull(), "originUrl": "https://example.invalid"]
        result["thread"] = thread
        root["result"] = result

        #expect(try protocolCodec.decode(try JSONSerialization.data(withJSONObject: root)) ==
            .threadStartResponse(id: "request-1:thread-start", threadID: "helper-thread-7"))
    }

    @Test
    func admitsOfficialVscodeSourceAndBoundedForwardCompatibleThreadMetadata() throws {
        var root = try object(Data(threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        ).utf8))
        var result = try #require(root["result"] as? [String: Any])
        result["approvalsReviewer"] = "future-reviewer"
        result["multiAgentMode"] = "future-mode"
        result["runtimeWorkspaceRoots"] = ["relative-but-informational"]
        result["activePermissionProfile"] = [
            "future": ["nested": true],
        ]
        var thread = try #require(result["thread"] as? [String: Any])
        thread["source"] = "vscode"
        thread["cliVersion"] = "future-version"
        thread["threadSource"] = "future-source"
        thread["historyMode"] = "future-history"
        thread["preview"] = "bounded preview"
        thread["createdAt"] = 10
        thread["updatedAt"] = 11
        thread["recencyAt"] = 12
        thread["status"] = ["type": "future", "metadata": ["ready": true]]
        thread["extra"] = ["future": ["enabled": true]]
        thread["gitInfo"] = ["future": ["branch": "main"]]
        thread["agentNickname"] = "nickname"
        thread["agentRole"] = "role"
        thread["name"] = "name"
        result["thread"] = thread
        root["result"] = result

        #expect(try protocolCodec.decode(try JSONSerialization.data(withJSONObject: root)) ==
            .threadStartResponse(id: "request-1:thread-start", threadID: "helper-thread-7"))
    }

    @Test
    func rejectsViolationsOfActualThreadIsolationAndCapabilityInvariants() throws {
        let source = try object(Data(threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        ).utf8))
        let mutations: [([String: Any], String)] = [
            (["thread.id": ""], "nonempty thread ID"),
            (["thread.ephemeral": false], "ephemeral thread"),
            (["result.cwd": "relative"], "absolute result cwd"),
            (["thread.cwd": "relative"], "absolute matching thread cwd"),
            (["thread.cwd": "/private/tmp/other"], "matching thread cwd"),
            (["result.modelProvider": ""], "nonempty result provider"),
            (["thread.modelProvider": ""], "nonempty thread provider"),
            (["thread.modelProvider": "other"], "matching provider"),
            (["result.approvalPolicy": "on-request"], "never approval policy"),
            (["sandbox.type": "workspaceWrite"], "read-only sandbox"),
            (["sandbox.networkAccess": true], "network disabled"),
            (["thread.turns": [["id": "turn-1"]]], "empty turns"),
        ]

        for (mutation, label) in mutations {
            var root = source
            var result = try #require(root["result"] as? [String: Any])
            var thread = try #require(result["thread"] as? [String: Any])
            var sandbox = try #require(result["sandbox"] as? [String: Any])
            for (path, value) in mutation {
                switch path {
                case "result.cwd": result["cwd"] = value
                case "result.modelProvider": result["modelProvider"] = value
                case "result.approvalPolicy": result["approvalPolicy"] = value
                case "sandbox.type": sandbox["type"] = value
                case "sandbox.networkAccess": sandbox["networkAccess"] = value
                case "thread.id": thread["id"] = value
                case "thread.ephemeral": thread["ephemeral"] = value
                case "thread.cwd": thread["cwd"] = value
                case "thread.modelProvider": thread["modelProvider"] = value
                case "thread.turns": thread["turns"] = value
                default: Issue.record("unknown mutation \(path)")
                }
            }
            result["sandbox"] = sandbox
            result["thread"] = thread
            root["result"] = result
            #expect(throws: LiveProtocolError.invalidField, Comment(rawValue: label)) {
                try protocolCodec.decode(try JSONSerialization.data(withJSONObject: root))
            }
        }
    }

    @Test(arguments: ["max", "ultra", "custom-effort"])
    func admitsBoundedOpaqueReasoningEffort(effort: String) throws {
        var root = try object(Data(threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        ).utf8))
        var result = try #require(root["result"] as? [String: Any])
        result["reasoningEffort"] = effort
        root["result"] = result

        #expect(try protocolCodec.decode(try JSONSerialization.data(withJSONObject: root)) ==
            .threadStartResponse(id: "request-1:thread-start", threadID: "helper-thread-7"))
    }

    @Test
    func rejectsNonObjectActivePermissionProfileMetadata() throws {
        let source = try object(Data(threadStartResponse(
            id: "request-1:thread-start", threadID: "helper-thread-7"
        ).utf8))
        for profile: Any in [7, "profile", true, []] {
            var root = source
            var result = try #require(root["result"] as? [String: Any])
            result["activePermissionProfile"] = profile
            root["result"] = result
            #expect(throws: (any Error).self) {
                try protocolCodec.decode(try JSONSerialization.data(withJSONObject: root))
            }
        }
    }

    @Test
    func decodesStrictRealtimeNotifications() throws {
        let started = try protocolCodec.decode(line("""
        {"method":"thread/realtime/started","params":{"threadId":"thread-1","realtimeSessionId":"session-1","version":"v3"}}
        """))
        guard case let .started(threadID, version) = started else {
            Issue.record("Expected a realtime started notification")
            return
        }
        #expect(threadID == "thread-1")
        #expect(version.rawValue == "v3")

        let nullContinuation = try protocolCodec.decode(line("""
        {"method":"thread/realtime/started","params":{"threadId":"thread-1","realtimeSessionId":null,"version":"v1"}}
        """))
        #expect(nullContinuation == .started(threadID: "thread-1", version: .v1))

        let omittedContinuation = try protocolCodec.decode(line("""
        {"method":"thread/realtime/started","params":{"threadId":"thread-1","version":"v1"}}
        """))
        #expect(omittedContinuation == .started(threadID: "thread-1", version: .v1))

        let transcript = try protocolCodec.decode(line("""
        {"method":"thread/realtime/transcript/delta","params":{"threadId":"thread-1","role":"assistant","delta":"hello"}}
        """))
        #expect(transcript == .transcriptDelta(threadID: "thread-1", role: "assistant", delta: "hello"))

        let audio = Data([1, 2, 3]).base64EncodedString()
        let output = try protocolCodec.decode(line("""
        {"method":"thread/realtime/outputAudio/delta","params":{"threadId":"thread-1","audio":{"data":"\(audio)","sampleRate":24000,"numChannels":1,"samplesPerChannel":3,"itemId":null}}}
        """))
        #expect(output == .outputAudio(
            threadID: "thread-1",
            audio: try LiveAudioFrame(
                data: Data([1, 2, 3]),
                sampleRate: 24_000,
                numChannels: 1,
                samplesPerChannel: 3,
                itemID: nil,
                requirePCM16Alignment: false
            )
        ))

        #expect(try protocolCodec.decode(line("""
        {"method":"account/login/completed","params":{"loginId":null,"success":true,"error":null}}
        """)) == .accountLoginCompleted)
        #expect(try protocolCodec.decode(line("""
        {"method":"account/updated","params":{"authMode":"chatgptAuthTokens","planType":"plus"}}
        """)) == .accountUpdated)
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/started","params":{"thread":\(threadObject(threadID: "helper-thread-7"))}}
        """)) == .threadStarted(threadID: "helper-thread-7"))
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/realtime/itemAdded","params":{"threadId":"helper-thread-7","item":{"type":"message","text":"discard me"}}}
        """)) == .realtimeItemAdded(threadID: "helper-thread-7"))
    }

    @Test
    func rejectsAnOversizedOpaqueRealtimeContinuationID() {
        let oversized = String(repeating: "x", count: 33)
        #expect(throws: LiveProtocolError.payloadTooLarge) {
            try protocolCodec.decode(line("""
            {"method":"thread/realtime/started","params":{"threadId":"thread-1","realtimeSessionId":"\(oversized)","version":"v1"}}
            """))
        }
    }

    @Test
    func rejectsEmptyNulOrFabricatedRealtimeAnswers() throws {
        for answer in ["", "not-sdp", "v=0\u{0000}\r\n", String(repeating: "x", count: 33)] {
            #expect(throws: (any Error).self) {
                try protocolCodec.decode(line("""
                {"method":"thread/realtime/sdp","params":{"threadId":"thread-1","sdp":"\(answer)"}}
                """))
            }
        }
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/realtime/sdp","params":{"threadId":"thread-1","sdp":"v=0\\r\\ns=-\\r\\n"}}
        """)) == .sdp(threadID: "thread-1", value: "v=0\r\ns=-\r\n"))
    }

    @Test
    func decodesAndDiscardsOnlyExactHarmlessStartupNotifications() throws {
        #expect(try protocolCodec.decode(line("""
        {"method":"remoteControl/status/changed","params":{"status":"disabled","serverName":"discard-server","installationId":"discard-installation","environmentId":null},"emittedAtMs":1785758400123}
        """)) == .outOfBandStartupNotification)
        #expect(try protocolCodec.decode(line("""
        {"method":"configWarning","params":{"summary":"discard-summary","details":"discard-details","path":"/private/tmp/config.toml","range":{"start":{"line":1,"column":2},"end":{"line":3,"column":4}}},"emittedAtMs":1785758400123}
        """)) == .outOfBandStartupNotification)
    }

    @Test
    func acceptsIntegerTimestampOnEveryKnownNotificationEnvelope() throws {
        #expect(try protocolCodec.decode(line("""
        {"method":"account/login/completed","params":{"loginId":null,"success":true,"error":null},"emittedAtMs":1}
        """)) == .accountLoginCompleted)
        #expect(try protocolCodec.decode(line("""
        {"method":"account/updated","params":{"authMode":"chatgptAuthTokens","planType":"future-plan"},"emittedAtMs":2}
        """)) == .accountUpdated)
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/started","params":{"thread":\(threadObject(threadID: "helper-thread-7"))},"emittedAtMs":3}
        """)) == .threadStarted(threadID: "helper-thread-7"))
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/realtime/started","params":{"threadId":"thread-1","realtimeSessionId":"session-1","version":"v1"},"emittedAtMs":4}
        """)) == .started(threadID: "thread-1", version: .v1))
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/realtime/itemAdded","params":{"threadId":"thread-1","item":{}},"emittedAtMs":5}
        """)) == .realtimeItemAdded(threadID: "thread-1"))
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/realtime/transcript/delta","params":{"threadId":"thread-1","role":"assistant","delta":"hello"},"emittedAtMs":6}
        """)) == .transcriptDelta(threadID: "thread-1", role: "assistant", delta: "hello"))
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/realtime/transcript/done","params":{"threadId":"thread-1","role":"assistant","text":"hello"},"emittedAtMs":7}
        """)) == .transcriptDone(threadID: "thread-1", role: "assistant", text: "hello"))
        #expect(try protocolCodec.decode(line("""
        {"method":"thread/realtime/outputAudio/delta","params":{"threadId":"thread-1","audio":{"data":"AQID","sampleRate":24000,"numChannels":1}},"emittedAtMs":8}
        """)) == .outputAudio(
            threadID: "thread-1",
            audio: try LiveAudioFrame(
                data: Data([1, 2, 3]), sampleRate: 24_000, numChannels: 1,
                samplesPerChannel: nil, itemID: nil, requirePCM16Alignment: false
            )
        ))
    }

    @Test
    func discardsBoundedUnknownAmbientNotificationButRejectsItsRequestForm() throws {
        #expect(try protocolCodec.decode(line("""
        {"method":"future/ambient","params":{"opaque":"discard"},"emittedAtMs":9}
        """)) == .outOfBandStartupNotification)
        #expect(throws: (any Error).self) {
            try protocolCodec.decode(line("""
            {"id":"server-ambient-1","method":"future/ambient","params":{"opaque":"discard"},"emittedAtMs":9}
            """))
        }
    }

    @Test(arguments: [
        "{\"method\":\"remoteControl/status/changed\",\"params\":{\"status\":\"future\",\"serverName\":\"server\",\"installationId\":\"id\",\"environmentId\":null}}",
        "{\"method\":\"remoteControl/status/changed\",\"params\":{\"status\":\"disabled\",\"serverName\":\"server\",\"installationId\":\"id\",\"environmentId\":null,\"future\":true}}",
        "{\"method\":\"configWarning\",\"params\":{\"summary\":\"warning\",\"details\":null,\"future\":true}}",
        "{\"method\":\"configWarning\",\"params\":{\"summary\":\"warning\",\"details\":null},\"emittedAtMs\":true}",
        "{\"method\":\"configWarning\",\"params\":{\"summary\":\"warning\",\"details\":null},\"emittedAtMs\":1.5}",
        "{\"method\":\"configWarning\",\"params\":{\"summary\":\"warning\",\"details\":null},\"emittedAtMs\":-1}",
        "{\"method\":\"configWarning\",\"params\":{\"summary\":\"warning\",\"details\":null},\"emittedAtMs\":9007199254740992}",
    ])
    func rejectsLoosenedHarmlessStartupNotificationShapes(frame: String) {
        #expect(throws: (any Error).self) {
            try protocolCodec.decode(line(frame))
        }
    }

    @Test(arguments: [
        "{\"id\":\"server-1\",\"method\":\"requestAttestation\",\"params\":{}}",
        "{\"id\":\"server-2\",\"method\":\"currentTime\",\"params\":{}}",
    ])
    func rejectsUnsupportedServerRequests(frame: String) {
        #expect(throws: (any Error).self) {
            try protocolCodec.decode(line(frame))
        }
    }

    @Test
    func rejectsMalformedUnknownOversizedAndUnknownFields() throws {
        #expect(throws: LiveProtocolError.malformedJSON) {
            try protocolCodec.decode(Data("{".utf8))
        }
        #expect(throws: (any Error).self) {
            try protocolCodec.decode(line("""
            {"id":"server-future-1","method":"thread/realtime/future","params":{}}
            """))
        }
        #expect(throws: LiveProtocolError.unknownField) {
            try protocolCodec.decode(line("""
            {"method":"thread/realtime/closed","params":{"threadId":"thread-1","reason":null,"future":true}}
            """))
        }
        #expect(throws: LiveProtocolError.frameTooLarge) {
            try protocolCodec.decode(Data(repeating: 1, count: 2_049))
        }
    }

    @Test
    func rejectsBoundViolationsAndInvalidBase64() throws {
        let oversized = String(repeating: "x", count: 33)
        #expect(throws: LiveProtocolError.payloadTooLarge) {
            try protocolCodec.decode(line("""
            {"method":"thread/realtime/transcript/delta","params":{"threadId":"thread-1","role":"assistant","delta":"\(oversized)"}}
            """))
        }
        #expect(throws: LiveProtocolError.invalidField) {
            try protocolCodec.decode(line("""
            {"method":"thread/realtime/outputAudio/delta","params":{"threadId":"thread-1","audio":{"data":"%%%","sampleRate":24000,"numChannels":1}}}
            """))
        }
    }

    @Test(arguments: [
        "{\"method\":\"thread/realtime/started\",\"params\":{\"threadId\":\"thread-1\",\"realtimeSessionId\":\"session-1\",\"version\":\"v5\"}}",
        "{\"method\":\"thread/realtime/started\",\"params\":{\"threadId\":\"thread-1\",\"realtimeSessionId\":\"session-1\",\"version\":\"v4\"}}",
        "{\"method\":\"thread/realtime/started\",\"params\":{\"threadId\":\"thread-1\",\"realtimeSessionId\":\"session-1\",\"version\":1}}",
        "{\"method\":\"thread/realtime/started\",\"params\":{\"threadId\":\"thread-1\",\"realtimeSessionId\":1,\"version\":\"v1\"}}",
        "{\"method\":\"thread/realtime/outputAudio/delta\",\"params\":{\"threadId\":\"thread-1\",\"audio\":{\"data\":\"AQID\",\"sampleRate\":0,\"numChannels\":1}}}",
        "{\"method\":\"thread/realtime/outputAudio/delta\",\"params\":{\"threadId\":\"thread-1\",\"audio\":{\"data\":\"AQID\",\"sampleRate\":24000,\"numChannels\":0}}}",
        "{\"method\":\"thread/realtime/outputAudio/delta\",\"params\":{\"threadId\":\"thread-1\",\"audio\":{\"data\":\"AQID\",\"sampleRate\":24000,\"numChannels\":1,\"samplesPerChannel\":-1}}}",
        "{\"method\":\"thread/realtime/outputAudio/delta\",\"params\":{\"threadId\":\"thread-1\",\"audio\":{\"data\":\"AQID\",\"sampleRate\":24000,\"numChannels\":1,\"itemId\":7}}}",
        "{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":\"request-1:refresh\",\"params\":{\"reason\":\"expired\",\"previousAccountId\":\"account-1\"}}"
        ,"{\"method\":\"thread/realtime/transcript/delta\",\"params\":{\"threadId\":\"thread-1\",\"role\":\"system\",\"delta\":\"no\"}}"
        ,"{\"method\":\"thread/realtime/transcript/done\",\"params\":{\"threadId\":\"thread-1\",\"role\":\"tool\",\"text\":\"no\"}}"
    ])
    func rejectsUnsupportedPinnedFieldValues(frame: String) {
        #expect(throws: LiveProtocolError.invalidField) {
            try protocolCodec.decode(line(frame))
        }
    }

    @Test
    func validatesExactResponseResultShapes() throws {
        let initialized = try protocolCodec.decode(line("""
        {"id":"request-1:initialize","result":{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex"}}
        """))
        #expect(initialized == .initializeResponse(id: "request-1:initialize"))
        let login = try protocolCodec.decode(line("""
        {"id":"request-1:login","result":{"type":"chatgptAuthTokens"}}
        """))
        #expect(login == .loginResponse(id: "request-1:login"))
        let empty = try protocolCodec.decode(line("""
        {"id":"request-1:start","result":{}}
        """))
        #expect(empty == .emptyResponse(id: "request-1:start"))

        #expect(throws: LiveProtocolError.unknownField) {
            try protocolCodec.decode(line("""
            {"id":"request-1:start","result":{"future":true}}
            """))
        }
        #expect(throws: LiveProtocolError.missingField) {
            try protocolCodec.decode(line("""
            {"id":"request-1:initialize","result":{"codexHome":"/tmp/codex"}}
            """))
        }
    }

    private func line(_ value: String) -> Data { Data(value.utf8) }

    private func threadStartResponse(id: String, threadID: String) -> String {
        """
        {"id":"\(id)","result":{"thread":\(threadObject(threadID: threadID)),"model":"gpt-live","modelProvider":"openai","serviceTier":null,"cwd":"/private/tmp/miller-live","instructionSources":[],"approvalPolicy":"never","approvalsReviewer":"user","sandbox":{"type":"readOnly","networkAccess":false},"activePermissionProfile":null,"reasoningEffort":null,"runtimeWorkspaceRoots":["/private/tmp/miller-live"],"multiAgentMode":"explicitRequestOnly"}}
        """
    }

    private func threadObject(threadID: String) -> String {
        """
        {"id":"\(threadID)","extra":{},"sessionId":"helper-session","forkedFromId":null,"parentThreadId":null,"preview":"","ephemeral":true,"historyMode":"legacy","modelProvider":"openai","createdAt":1,"updatedAt":1,"recencyAt":null,"status":{"type":"idle"},"path":null,"cwd":"/private/tmp/miller-live","cliVersion":"0.145.0","source":"vscode","canAcceptDirectInput":null,"threadSource":"user","agentNickname":null,"agentRole":null,"gitInfo":null,"name":null,"turns":[]}
        """
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

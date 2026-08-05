import Foundation
import MillerLive
import Testing

struct GPTLiveWireTests {
    @Test
    func buildsBoundedOAuthMultipartRequestWithoutLeakingCredentials() async throws {
        let loader = RecordingGPTLiveLoader(response: .success(
            (
                Data("v=0\r\ns=-\r\n".utf8),
                HTTPURLResponse(
                    url: URL(string: "https://api.openai.com/v1/live")!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Location": "/v1/live/rtc_wire-test"]
                )!
            )
        ))
        let creator = GPTLiveCallCreator(loader: loader)
        let auth = GPTLiveAuth.oauth(
            accessToken: Data("oauth-secret-value".utf8),
            accountID: "account-secret-value"
        )
        let result = try await creator.create(
            offerSDP: "v=0\r\ns=-\r\n",
            configuration: .init(model: .codex, voice: .marin),
            auth: auth,
            requestIDs: .init(
                realtimeSessionID: "realtime-1",
                sessionID: "session-1",
                threadID: "thread-1"
            )
        )

        #expect(result.callID == "rtc_wire-test")
        #expect(result.answerSDP.hasPrefix("v=0"))
        let request = await loader.request
        #expect(request?.url?.absoluteString == "https://api.openai.com/v1/live")
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "OpenAI-Alpha") == "quicksilver=v2")
        #expect(request?.value(forHTTPHeaderField: "chatgpt-account-id") == "account-secret-value")
        #expect(request?.value(forHTTPHeaderField: "session-id") == "session-1")
        #expect(request?.value(forHTTPHeaderField: "thread-id") == "thread-1")
        #expect(request?.value(forHTTPHeaderField: "x-session-id") == "realtime-1")
        #expect(request?.timeoutInterval == 30)
        let body = String(data: request?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("name=\"sdp\""))
        #expect(body.contains("Content-Type: application/sdp"))
        #expect(body.contains("name=\"session\""))
        #expect(body.contains("\"model\":\"gpt-live-1-codex\""))
        #expect(body.contains("\"voice\":\"marin\""))
        #expect(body.contains("Delegate any request that requires real work"))
        #expect(!body.contains("oauth-secret-value"))
        #expect(!body.contains("account-secret-value"))
        #expect(!String(describing: result).contains("oauth-secret-value"))
        #expect(!String(describing: result).contains("account-secret-value"))
    }

    @Test
    func acceptsSuccessfulTwoHundredResponseAndRejectsWrongFinalHost() async throws {
        let success = RecordingGPTLiveLoader(response: .success((
            Data("v=0\r\ns=-\r\n".utf8),
            HTTPURLResponse(
                url: URL(string: "https://api.openai.com/v1/live")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Location": "/v1/live/rtc_success"]
            )!
        )))
        _ = try await GPTLiveCallCreator(loader: success).create(
            offerSDP: "v=0\r\ns=-\r\n",
            auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
            requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
        )

        let redirected = RecordingGPTLiveLoader(response: .success((
            Data("v=0\r\ns=-\r\n".utf8),
            HTTPURLResponse(
                url: URL(string: "https://example.com/v1/live")!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Location": "/v1/live/rtc_redirected"]
            )!
        )))
        await #expect(throws: GPTLiveWireError.invalidProviderEndpoint) {
            _ = try await GPTLiveCallCreator(loader: redirected).create(
                offerSDP: "v=0\r\ns=-\r\n",
                auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
                requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
            )
        }
    }

    @Test
    func rejectsControlCharactersInCredentialsAndRequestIDs() async {
        let loader = RecordingGPTLiveLoader(response: .failure(
            RecordingGPTLiveLoader.Failure.shouldNotLoad
        ))
        await #expect(throws: GPTLiveWireError.invalidCredential) {
            _ = try await GPTLiveCallCreator(loader: loader).create(
                offerSDP: "v=0\r\n",
                auth: .oauth(accessToken: Data("token\nvalue".utf8), accountID: "account"),
                requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
            )
        }
        await #expect(throws: GPTLiveWireError.invalidRequestID) {
            _ = try await GPTLiveCallCreator(loader: loader).create(
                offerSDP: "v=0\r\n",
                auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
                requestIDs: .init(realtimeSessionID: "r\n", sessionID: "s", threadID: "t")
            )
        }
        #expect(await loader.request == nil)
    }

    @Test
    func refusesNonOAuthAuthBeforeLoadingTheProvider() async {
        let loader = RecordingGPTLiveLoader(response: .failure(RecordingGPTLiveLoader.Failure.shouldNotLoad))
        let creator = GPTLiveCallCreator(loader: loader)

        await #expect(throws: GPTLiveWireError.oauthRequired) {
            _ = try await creator.create(
                offerSDP: "v=0\r\ns=-\r\n",
                configuration: .default,
                auth: .apiKey("platform-secret"),
                requestIDs: .init(
                    realtimeSessionID: "r",
                    sessionID: "s",
                    threadID: "t"
                )
            )
        }
        #expect(await loader.request == nil)
    }

    @Test(arguments: [
        (400, GPTLiveWireError.badRequest),
        (401, GPTLiveWireError.unauthorized),
        (403, GPTLiveWireError.forbidden),
        (500, GPTLiveWireError.serverFailure),
        (503, GPTLiveWireError.serverFailure),
    ])
    func mapsHTTPFailuresToFixedSanitizedErrors(
        status: Int,
        expected: GPTLiveWireError
    ) async {
        let loader = RecordingGPTLiveLoader(response: .success(
            (
                Data("provider secret body".utf8),
                HTTPURLResponse(
                    url: URL(string: "https://api.openai.com/v1/live")!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        ))

        await #expect(throws: expected) {
            _ = try await GPTLiveCallCreator(loader: loader).create(
                offerSDP: "v=0\r\ns=-\r\n",
                configuration: .default,
                auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
                requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
            )
        }
    }

    @Test
    func fallsBackFromLocationToOpenAISessionIDAndValidatesAnswerAndCallID() async throws {
        let loader = RecordingGPTLiveLoader(response: .success(
            (
                Data("v=0\r\ns=-\r\n".utf8),
                HTTPURLResponse(
                    url: URL(string: "https://api.openai.com/v1/live")!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: [
                        "Location": "/v1/live/not-a-call",
                        "openai-session-id": "019eb97d-8e9a-7ff3-94b0-ea019babd5d7",
                    ]
                )!
            )
        ))
        let result = try await GPTLiveCallCreator(loader: loader).create(
            offerSDP: "v=0\r\ns=-\r\n",
            configuration: .default,
            auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
            requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
        )
        #expect(result.callID == "019eb97d-8e9a-7ff3-94b0-ea019babd5d7")
        #expect(result.sidebandURL.absoluteString.hasSuffix(result.callID))
    }

    @Test(arguments: [
        GPTLiveWireError.invalidSDPAnswer,
        GPTLiveWireError.oversizedSDPAnswer,
        GPTLiveWireError.missingCallID,
        GPTLiveWireError.invalidCallID,
    ])
    func rejectsUnsupportedAnswerOrCallID(error: GPTLiveWireError) async {
        let response: (Data, HTTPURLResponse)
        switch error {
        case .invalidSDPAnswer:
            response = (
                Data("not-sdp".utf8),
                makeResponse(status: 201, headers: ["Location": "/v1/live/rtc_bad"])
            )
        case .oversizedSDPAnswer:
            response = (
                Data(repeating: 0x78, count: GPTLiveWireLimits.maximumSDPBytes + 1),
                makeResponse(status: 201, headers: ["Location": "/v1/live/rtc_big"])
            )
        case .missingCallID:
            response = (Data("v=0\r\n".utf8), makeResponse(status: 201, headers: nil))
        case .invalidCallID:
            response = (
                Data("v=0\r\n".utf8),
                makeResponse(status: 201, headers: ["Location": "/v1/live/not-a-call"])
            )
        default:
            Issue.record("unexpected test case")
            return
        }
        let loader = RecordingGPTLiveLoader(response: .success(response))
        await #expect(throws: error) {
            _ = try await GPTLiveCallCreator(loader: loader).create(
                offerSDP: "v=0\r\n",
                configuration: .default,
                auth: .oauth(accessToken: Data("token".utf8), accountID: "account"),
                requestIDs: .init(realtimeSessionID: "r", sessionID: "s", threadID: "t")
            )
        }
    }

    @Test
    func eventProjectionBoundsUnknownMalformedAndSecretBearingErrors() {
        #expect(GPTLiveEventParser.parse("not-json") == nil)
        #expect(GPTLiveEventParser.parse(#"{"type":"session.expired"}"#) == .sessionExpired)
        #expect(GPTLiveEventParser.parse(#"{"type":"session.closed"}"#) == .sessionClosed)
        #expect(GPTLiveEventParser.parse(#"{"type":"session.started"}"#) == .unknown)
        #expect(
            GPTLiveEventParser.parse(
                String(repeating: "x", count: GPTLiveWireLimits.maximumEventBytes + 1)
            ) == nil
        )
        #expect(
            GPTLiveEventParser.parse(#"{"type":"future.event","secret":"do-not-retain"}"#)
                == .unknown
        )
        #expect(
            GPTLiveEventParser.parse(
                #"{"type":"error","error":{"code":"invalid_token","message":"oauth-secret-value"}}"#
            ) == .error(fatalAuth: true)
        )
        #expect(
            GPTLiveEventParser.parse(
                #"{"type":"error","error":{"status":"401","message":"expired"}}"#
            ) == .error(fatalAuth: true)
        )
        #expect(
            String(describing: GPTLiveEventParser.parse(
                #"{"type":"error","error":{"message":"oauth-secret-value"}}"#
            )).contains("oauth-secret-value") == false
        )
    }

    @Test
    func chunksSpeakableDelegationTextByUTF8Bytes() {
        let source = String(repeating: "a", count: 499) + "🙂" + String(repeating: "b", count: 30)
        let chunks = GPTLiveEventParser.chunkSpeakableText(source)
        #expect(chunks.joined() == source)
        #expect(chunks.allSatisfy { $0.utf8.count <= GPTLiveWireLimits.maximumAppendBytes })
    }
}

private actor RecordingGPTLiveLoader: GPTLiveURLLoading {
    enum Failure: Error { case shouldNotLoad }

    private let result: Result<(Data, HTTPURLResponse), Error>
    private(set) var request: URLRequest?

    init(response: Result<(Data, HTTPURLResponse), Error>) {
        self.result = response
    }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try result.get()
    }
}

private func makeResponse(status: Int, headers: [String: String]?) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.openai.com/v1/live")!,
        statusCode: status,
        httpVersion: nil,
        headerFields: headers
    )!
}

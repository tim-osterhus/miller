import Foundation

// Modified donor-derived behavior: OpenClaw PR #115226 at commit
// f78ba091207b33c3bb79f1bd9879d0e56be91a16 supplied the bounded GPT-Live
// multipart, OAuth-header, response, and event contracts. Miller adapts those
// contracts to Foundation URL loading and its fixed, sanitized error boundary.

public enum GPTLiveModel: String, CaseIterable, Equatable, Sendable {
    case codex = "gpt-live-1-codex"
    case boulderAlpha = "gpt-live-1-boulder-alpha"
}

public enum GPTLiveVoice: String, CaseIterable, Equatable, Sendable {
    case alloy
    case ash
    case ballad
    case cedar
    case coral
    case echo
    case marin
    case sage
    case shimmer
    case verse
}

public enum GPTLiveSessionInstructions {
    public static let wakeAcknowledgement =
        "Immediately acknowledge you’re ready and listening."
}

public struct GPTLiveConfiguration: Equatable, Sendable {
    public static let maximumInstructionsBytes = 8_000
    public static let delegationInstructions = """
    You are Miller's realtime voice layer. You have no tools of your own.
    Delegate any request that requires real work, reasoning, current information, or actions to the client through a delegation.
    Keep the conversation natural while delegated work runs.
    Context on the commentary channel is silent background. You may use it, but never read it aloud.
    Context on the speakable channel is your answer to deliver naturally in your own words. Never mention the channel or the delegation.
    """

    public let model: GPTLiveModel
    public let voice: GPTLiveVoice
    public let instructions: String

    public init(
        model: GPTLiveModel = .codex,
        voice: GPTLiveVoice = .marin,
        instructions: String = ""
    ) {
        self.model = model
        self.voice = voice
        let operatorInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = operatorInstructions.isEmpty
            ? Self.delegationInstructions
            : "\(Self.delegationInstructions)\n\n\(operatorInstructions)"
        self.instructions = Self.boundInstructions(combined)
    }

    public static let `default` = Self()

    private static func boundInstructions(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maximumInstructionsBytes else { return trimmed }
        var result = ""
        var bytes = 0
        for character in trimmed {
            let characterBytes = String(character).utf8.count
            guard bytes + characterBytes <= maximumInstructionsBytes else { break }
            result.append(character)
            bytes += characterBytes
        }
        return result
    }
}

public enum GPTLiveAuth: Equatable, Sendable, CustomStringConvertible {
    case oauth(accessToken: Data, accountID: String)
    case apiKey(String)

    public var redactedDescription: String {
        switch self {
        case .oauth: "GPTLiveAuth.oauth(redacted)"
        case .apiKey: "GPTLiveAuth.apiKey(redacted)"
        }
    }

    public var description: String { redactedDescription }
}

public struct GPTLiveRequestIDs: Equatable, Sendable {
    public let realtimeSessionID: String
    public let sessionID: String
    public let threadID: String

    public init(realtimeSessionID: String, sessionID: String, threadID: String) {
        self.realtimeSessionID = realtimeSessionID
        self.sessionID = sessionID
        self.threadID = threadID
    }
}

public struct GPTLiveCallResponse: Equatable, Sendable, CustomStringConvertible {
    public let statusCode: Int
    public let answerSDP: String
    public let callID: String
    public let sidebandURL: URL

    public init(statusCode: Int, answerSDP: String, callID: String, sidebandURL: URL) {
        self.statusCode = statusCode
        self.answerSDP = answerSDP
        self.callID = callID
        self.sidebandURL = sidebandURL
    }

    public var description: String {
        "GPTLiveCallResponse(statusCode: \(statusCode), redacted: true)"
    }
}

public enum GPTLiveWireError: Error, Equatable, Sendable {
    case oauthRequired
    case invalidCredential
    case invalidRequestID
    case invalidProviderEndpoint
    case badRequest
    case unauthorized
    case forbidden
    case serverFailure
    case unexpectedStatus
    case networkFailure
    case invalidSDPOffer
    case invalidSDPAnswer
    case oversizedSDPAnswer
    case missingCallID
    case invalidCallID
}

public enum GPTLiveSessionError: Error, Equatable, Sendable {
    case sessionAlreadyActive
    case sidebandStartup
    case sidebandClosed
    case expired
    case protocolFailure
}

public enum GPTLiveWireLimits {
    public static let maximumSDPBytes = 65_536
    public static let maximumEventBytes = 65_536
    public static let maximumTranscriptBytes = 65_536
    public static let maximumAppendBytes = 500
    public static let maximumCallIDBytes = 256
    public static let maximumCredentialBytes = 65_536
    public static let maximumAccountIDBytes = 1_024
}

public protocol GPTLiveURLLoading: Sendable {
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct GPTLiveURLSessionLoader: GPTLiveURLLoading, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 30
            configuration.httpMaximumConnectionsPerHost = 1
            self.session = URLSession(
                configuration: configuration,
                delegate: GPTLiveRedirectRejectingDelegate(),
                delegateQueue: nil
            )
        }
    }

    public func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GPTLiveWireError.networkFailure
            }
            guard Self.isProviderURL(response.url) else {
                throw GPTLiveWireError.invalidProviderEndpoint
            }
            guard data.count <= GPTLiveWireLimits.maximumSDPBytes else {
                throw GPTLiveWireError.oversizedSDPAnswer
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GPTLiveWireError {
            throw error
        } catch {
            throw GPTLiveWireError.networkFailure
        }
    }

    private static func isProviderURL(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" &&
            url?.host?.lowercased() == "api.openai.com" &&
            url?.port == nil
    }
}

private final class GPTLiveRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct GPTLiveCallCreator: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/live")!

    private let loader: any GPTLiveURLLoading

    public init(loader: any GPTLiveURLLoading = GPTLiveURLSessionLoader()) {
        self.loader = loader
    }

    public func create(
        offerSDP: String,
        configuration: GPTLiveConfiguration = .default,
        auth: GPTLiveAuth,
        requestIDs: GPTLiveRequestIDs
    ) async throws -> GPTLiveCallResponse {
        try Task.checkCancellation()
        guard case let .oauth(accessToken, accountID) = auth else {
            throw GPTLiveWireError.oauthRequired
        }
        guard let token = String(data: accessToken, encoding: .utf8),
              !token.isEmpty,
              token.utf8.count <= GPTLiveWireLimits.maximumCredentialBytes,
              Self.hasNoControlCharacters(token),
              !accountID.isEmpty,
              accountID.utf8.count <= GPTLiveWireLimits.maximumAccountIDBytes,
              Self.hasNoControlCharacters(accountID)
        else {
            throw GPTLiveWireError.invalidCredential
        }
        guard Self.validRequestIDs(requestIDs) else {
            throw GPTLiveWireError.invalidRequestID
        }
        guard isSDP(offerSDP) else {
            throw GPTLiveWireError.invalidSDPOffer
        }

        let sessionJSON = try sessionJSON(configuration)
        let multipart = try multipartBody(offerSDP: offerSDP, sessionJSON: sessionJSON)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = multipart.body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("quicksilver=v2", forHTTPHeaderField: "OpenAI-Alpha")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue(requestIDs.sessionID, forHTTPHeaderField: "session-id")
        request.setValue(requestIDs.threadID, forHTTPHeaderField: "thread-id")
        request.setValue(requestIDs.realtimeSessionID, forHTTPHeaderField: "x-session-id")
        request.setValue("MillerGPTLive/1", forHTTPHeaderField: "User-Agent")
        request.setValue("miller", forHTTPHeaderField: "originator")
        request.setValue("1", forHTTPHeaderField: "version")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await loader.load(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GPTLiveWireError {
            throw error
        } catch {
            throw GPTLiveWireError.networkFailure
        }
        guard response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == "api.openai.com",
              response.url?.port == nil
        else { throw GPTLiveWireError.invalidProviderEndpoint }
        guard (200..<300).contains(response.statusCode) else {
            throw mapStatus(response.statusCode)
        }
        guard data.count <= GPTLiveWireLimits.maximumSDPBytes else {
            throw GPTLiveWireError.oversizedSDPAnswer
        }
        guard let answer = String(data: data, encoding: .utf8), isSDP(answer) else {
            throw data.isEmpty ? GPTLiveWireError.invalidSDPAnswer : GPTLiveWireError.invalidSDPAnswer
        }
        guard let callID = callID(from: response) else {
            throw response.value(forHTTPHeaderField: "Location") == nil
                && response.value(forHTTPHeaderField: "openai-session-id") == nil
                ? GPTLiveWireError.missingCallID
                : GPTLiveWireError.invalidCallID
        }
        guard let sidebandURL = URL(string: "wss://api.openai.com/v1/live/\(callID)") else {
            throw GPTLiveWireError.invalidCallID
        }
        return GPTLiveCallResponse(
            statusCode: response.statusCode,
            answerSDP: answer,
            callID: callID,
            sidebandURL: sidebandURL
        )
    }

    public static func authHeaders(
        auth: GPTLiveAuth,
        requestIDs: GPTLiveRequestIDs
    ) throws -> [String: String] {
        guard case .oauth = auth else { throw GPTLiveWireError.oauthRequired }
        guard case let .oauth(accessToken, accountID) = auth,
              let token = String(data: accessToken, encoding: .utf8),
              !token.isEmpty,
              token.utf8.count <= GPTLiveWireLimits.maximumCredentialBytes,
              Self.hasNoControlCharacters(token),
              !accountID.isEmpty,
              accountID.utf8.count <= GPTLiveWireLimits.maximumAccountIDBytes,
              Self.hasNoControlCharacters(accountID),
              Self.validRequestIDs(requestIDs)
        else { throw GPTLiveWireError.invalidCredential }
        return [
            "Authorization": "Bearer \(token)",
            "OpenAI-Alpha": "quicksilver=v2",
            "chatgpt-account-id": accountID,
            "session-id": requestIDs.sessionID,
            "thread-id": requestIDs.threadID,
            "x-session-id": requestIDs.realtimeSessionID,
            "User-Agent": "MillerGPTLive/1",
            "originator": "miller",
            "version": "1",
        ]
    }

    private func sessionJSON(_ configuration: GPTLiveConfiguration) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": configuration.model.rawValue,
            "instructions": configuration.instructions,
            "audio": ["output": ["voice": configuration.voice.rawValue]],
            "delegation": ["type": "client"],
        ], options: [.sortedKeys])
    }

    private func multipartBody(
        offerSDP: String,
        sessionJSON: Data
    ) throws -> (body: Data, contentType: String) {
        guard let session = String(data: sessionJSON, encoding: .utf8) else {
            throw GPTLiveWireError.invalidCredential
        }
        var boundary = "miller-gpt-live-\(UUID().uuidString.lowercased())"
        while offerSDP.contains(boundary) || session.contains(boundary) {
            boundary = "miller-gpt-live-\(UUID().uuidString.lowercased())"
        }
        let body = [
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"sdp\"\r\n",
            "Content-Type: application/sdp\r\n\r\n",
            offerSDP,
            "\r\n",
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"session\"\r\n",
            "Content-Type: application/json\r\n\r\n",
            session,
            "\r\n",
            "--\(boundary)--\r\n",
        ].joined()
        guard let data = body.data(using: .utf8) else {
            throw GPTLiveWireError.invalidCredential
        }
        return (data, "multipart/form-data; boundary=\(boundary)")
    }

    private func callID(from response: HTTPURLResponse) -> String? {
        if let location = response.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location, relativeTo: Self.endpoint)?.absoluteURL,
           let candidate = url.path.split(separator: "/").map(String.init).first(where: isCallID) {
            return candidate
        }
        if let header = response.value(forHTTPHeaderField: "openai-session-id") {
            let candidate = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if isCallID(candidate) { return candidate }
        }
        return nil
    }

    private func isCallID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= GPTLiveWireLimits.maximumCallIDBytes else {
            return false
        }
        if value.hasPrefix("rtc_") {
            let suffix = value.dropFirst(4)
            guard !suffix.isEmpty else { return false }
            return suffix.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
            }
        }
        return UUID(uuidString: value) != nil
    }

    private func isSDP(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= GPTLiveWireLimits.maximumSDPBytes,
              !value.utf8.contains(0)
        else { return false }
        return value.split(whereSeparator: \.isNewline).first == "v=0"
    }

    private static func validRequestIDs(_ ids: GPTLiveRequestIDs) -> Bool {
        [ids.realtimeSessionID, ids.sessionID, ids.threadID].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && Self.hasNoControlCharacters($0)
        }
    }

    private static func hasNoControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func mapStatus(_ status: Int) -> GPTLiveWireError {
        switch status {
        case 400: .badRequest
        case 401: .unauthorized
        case 403: .forbidden
        case 500...599: .serverFailure
        default: .unexpectedStatus
        }
    }
}

public enum GPTLiveTranscriptRole: String, Equatable, Sendable {
    case user
    case assistant
}

public struct GPTLiveTranscriptEntry: Equatable, Sendable {
    public let role: GPTLiveTranscriptRole
    public let text: String

    public init(role: GPTLiveTranscriptRole, text: String) {
        self.role = role
        self.text = text
    }
}

public enum GPTLiveInboundEvent: Equatable, Sendable {
    case sessionStarted(expiresAt: Int64?)
    case sessionExpired
    case sessionClosed
    case transcriptDelta(role: GPTLiveTranscriptRole, text: String)
    case transcriptDone(role: GPTLiveTranscriptRole, text: String)
    case delegation(id: String, prompt: String)
    case error(fatalAuth: Bool)
    case unknown
}

public enum GPTLiveEventParser {
    public static func parse(_ text: String) -> GPTLiveInboundEvent? {
        guard text.utf8.count <= GPTLiveWireLimits.maximumEventBytes,
              let data = text.data(using: .utf8)
        else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> GPTLiveInboundEvent? {
        guard data.count <= GPTLiveWireLimits.maximumEventBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let type = root["type"] as? String,
              !type.isEmpty,
              type.utf8.count <= 128
        else { return nil }

        switch type {
        case "session.started":
            guard let session = root["session"] as? [String: Any] else { return .unknown }
            let expiresAt = session["expires_at"] as? NSNumber
            return .sessionStarted(expiresAt: expiresAt?.int64Value)
        case "session.expired":
            return .sessionExpired
        case "session.closed":
            return .sessionClosed
        case "input_transcript.added", "input_transcript.delta":
            return transcript(root, role: .user)
        case "output_transcript.added", "output_transcript.delta":
            return transcript(root, role: .assistant)
        case "turn.done":
            guard let turn = root["turn"] as? [String: Any],
                  let roleValue = turn["role"] as? String,
                  let role = GPTLiveTranscriptRole(rawValue: roleValue),
                  let text = turn["transcript"] as? String,
                  boundedText(text)
            else { return .unknown }
            return .transcriptDone(role: role, text: text)
        case "delegation.created":
            return delegation(root)
        case "error":
            return .error(fatalAuth: fatalAuth(root))
        case "session.updated", "output_audio.delta":
            return .unknown
        default:
            return .unknown
        }
    }

    public static func chunkSpeakableText(_ text: String) -> [String] {
        guard text.utf8.count > GPTLiveWireLimits.maximumAppendBytes else { return [text] }
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let bytes = String(character).utf8.count
            if !current.isEmpty && currentBytes + bytes > GPTLiveWireLimits.maximumAppendBytes {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += bytes
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func transcript(
        _ root: [String: Any],
        role: GPTLiveTranscriptRole
    ) -> GPTLiveInboundEvent {
        guard let item = root["item"] as? [String: Any],
              let text = item["text"] as? String,
              boundedText(text)
        else { return .unknown }
        return .transcriptDelta(role: role, text: text)
    }

    private static func delegation(_ root: [String: Any]) -> GPTLiveInboundEvent {
        guard let item = root["item"] as? [String: Any],
              item["type"] as? String == "delegation",
              item["target"] as? String == "client",
              let id = item["id"] as? String,
              !id.isEmpty,
              id.utf8.count <= 256,
              let content = item["content"] as? [[String: Any]]
        else { return .unknown }
        let prompt = content.compactMap { part -> String? in
            guard part["type"] as? String == "input_text" else { return nil }
            return part["text"] as? String
        }.joined()
        guard boundedText(prompt) else { return .unknown }
        return .delegation(id: id, prompt: prompt)
    }

    private static func fatalAuth(_ root: [String: Any]) -> Bool {
        let error = root["error"] as? [String: Any]
        let status = integerStatus(root["status"]) ?? integerStatus(error?["status"])
        if status == 401 { return true }
        let code = ((root["code"] as? String) ?? (error?["code"] as? String))?.lowercased()
        return ["authentication_error", "invalid_api_key", "invalid_token", "token_expired"].contains(code)
    }

    private static func integerStatus(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boundedText(_ value: String) -> Bool {
        value.utf8.count <= GPTLiveWireLimits.maximumTranscriptBytes && !value.utf8.contains(0)
    }
}

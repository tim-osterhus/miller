import Foundation
import CoreFoundation
import MillerCore

public enum LiveProtocolError: Error, Equatable, Sendable {
    case frameTooLarge
    case malformedJSON
    case unknownMethod
    case unknownField
    case missingField
    case invalidField
    case payloadTooLarge
}

public enum RealtimeConversationVersion: String, Equatable, Sendable {
    case v1
    case v2
    case v3
}

public enum CodexRealtimePrompt {
    public static func make(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        additionalInstructions: String? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        let localDateTime = formatter.string(from: now)
        let base = """
        You are Miller, a local voice assistant. The current local date and time is \
        \(localDateTime) (\(timeZone.identifier)). Use this supplied date and time when \
        answering questions about the current date or time. Do not invent or substitute a \
        different current date or time. Respond naturally and concisely.
        """
        guard let additionalInstructions, !additionalInstructions.isEmpty else {
            return base
        }
        return base + "\n\nEnabled portable skills for this session:\n" + additionalInstructions
    }
}

public enum JSONRPCRequestID: Hashable, Sendable {
    case string(String)
    case integer(Int64)
}

public enum CodexAppServerMessage: Equatable, Sendable {
    case initializeResponse(id: String)
    case loginResponse(id: String)
    case threadStartResponse(id: String, threadID: String)
    case accountLoginCompleted
    case accountUpdated
    case threadStarted(threadID: String)
    case outOfBandStartupNotification
    case realtimeItemAdded(threadID: String)
    case emptyResponse(id: String)
    case requestError(id: String, code: Int, message: String)
    case started(threadID: String, version: RealtimeConversationVersion)
    case sdp(threadID: String, value: String)
    case transcriptDelta(threadID: String, role: String, delta: String)
    case transcriptDone(threadID: String, role: String, text: String)
    case outputAudio(threadID: String, audio: LiveAudioFrame)
    case error(threadID: String, message: String)
    case closed(threadID: String, reason: String?)
    case credentialRefresh(id: JSONRPCRequestID, previousAccountID: String?)
    case capabilityActivity(CodexCapabilityActivity)
    case providerApproval(CodexProviderApproval)
    case ignoredCapabilityActivity
}

public struct CodexAppServerProtocol: Sendable {
    public let maximumFrameBytes: Int
    public let maximumTextBytes: Int
    public let maximumAudioBytes: Int
    private let existingMillerCapabilities: [CapabilityDescriptor]

    public init(
        maximumFrameBytes: Int = 1_048_576,
        maximumTextBytes: Int = 65_536,
        maximumAudioBytes: Int = 1_048_576,
        existingMillerCapabilities: [CapabilityDescriptor] = []
    ) {
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumTextBytes = maximumTextBytes
        self.maximumAudioBytes = maximumAudioBytes
        self.existingMillerCapabilities = existingMillerCapabilities
    }

    public func initializeRequest(id: String) throws -> Data {
        try encode([
            "id": id,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": MillerAppServerClientInfo.name,
                    "version": MillerAppServerClientInfo.version,
                ],
                "capabilities": ["experimentalApi": true],
            ],
        ])
    }

    public func initializedNotification() throws -> Data {
        try encode(["method": "initialized"])
    }

    public func threadStartRequest(id: String, cwd: String) throws -> Data {
        guard cwd.hasPrefix("/") else { throw LiveProtocolError.invalidField }
        return try encode([
            "id": id,
            "method": "thread/start",
            "params": [
                "approvalPolicy": "never",
                "cwd": cwd,
                "ephemeral": true,
                "sandbox": "read-only",
            ] as [String: Any],
        ])
    }

    public func realtimeStartRequest(
        id: String,
        threadID: String,
        offerSDP: String,
        prompt: String = CodexRealtimePrompt.make()
    ) throws -> Data {
        try validateWebRTCOffer(offerSDP)
        guard !prompt.isEmpty, prompt.utf8.count <= maximumTextBytes else {
            throw LiveProtocolError.invalidField
        }
        return try encode([
            "id": id,
            "method": "thread/realtime/start",
            "params": [
                "threadId": threadID,
                "outputModality": "audio",
                "prompt": prompt,
                "realtimeSessionId": NSNull(),
                "transport": ["type": "webrtc", "sdp": offerSDP],
                "version": RealtimeConversationVersion.v3.rawValue,
                "voice": NSNull(),
            ] as [String: Any],
        ])
    }

    public func realtimeStopRequest(id: String, threadID: String) throws -> Data {
        try encode([
            "id": id,
            "method": "thread/realtime/stop",
            "params": ["threadId": threadID],
        ])
    }

    public func realtimeAppendAudioRequest(
        id: String,
        threadID: String,
        audio: LiveAudioFrame
    ) throws -> Data {
        guard audio.data.count <= maximumAudioBytes else {
            throw LiveProtocolError.payloadTooLarge
        }
        return try encode([
            "id": id,
            "method": "thread/realtime/appendAudio",
            "params": [
                "threadId": threadID,
                "audio": [
                    "data": audio.data.base64EncodedString(),
                    "sampleRate": audio.sampleRate,
                    "numChannels": audio.numChannels,
                    "samplesPerChannel": audio.samplesPerChannel ?? NSNull(),
                    "itemId": audio.itemID ?? NSNull(),
                ] as [String: Any],
            ] as [String: Any],
        ])
    }

    public func decode(_ data: Data) throws -> CodexAppServerMessage {
        guard data.count <= maximumFrameBytes else { throw LiveProtocolError.frameTooLarge }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LiveProtocolError.malformedJSON
        }
        guard let root = value as? [String: Any] else {
            throw LiveProtocolError.malformedJSON
        }
        if let method = root["method"] as? String {
            return try decodeMethod(method, root: root)
        }
        if root["error"] != nil {
            try requireFields(root, required: ["id", "error"], optional: [])
            guard let id = root["id"] as? String,
                  let error = root["error"] as? [String: Any]
            else { throw LiveProtocolError.invalidField }
            try requireFields(error, required: ["code", "message"], optional: ["data"])
            guard let code = error["code"] as? Int else { throw LiveProtocolError.invalidField }
            return .requestError(id: id, code: code, message: try boundedText(error, "message"))
        }
        try requireRequiredFields(root, required: ["id", "result"])
        guard let id = root["id"] as? String,
              let result = root["result"] as? [String: Any]
        else {
            throw LiveProtocolError.invalidField
        }
        if id.hasSuffix(":initialize") {
            try requireRequiredFields(
                result,
                required: ["codexHome", "platformFamily", "platformOs", "userAgent"]
            )
            let codexHome = try string(result, "codexHome")
            guard codexHome.hasPrefix("/") else { throw LiveProtocolError.invalidField }
            _ = try string(result, "platformFamily")
            _ = try string(result, "platformOs")
            _ = try string(result, "userAgent")
            return .initializeResponse(id: id)
        }
        if id.hasSuffix(":login") {
            try requireRequiredFields(result, required: ["type"])
            guard try string(result, "type") == "chatgptAuthTokens" else {
                throw LiveProtocolError.invalidField
            }
            return .loginResponse(id: id)
        }
        if id.hasSuffix(":thread-start") {
            try requireRequiredFields(
                result,
                required: [
                    "thread", "model", "modelProvider", "cwd", "approvalPolicy",
                    "approvalsReviewer", "sandbox",
                ]
            )
            let threadID = try validatedThread(result["thread"])
            _ = try string(result, "model")
            let modelProvider = try string(result, "modelProvider")
            let cwd = try string(result, "cwd")
            guard !modelProvider.isEmpty,
                  cwd.hasPrefix("/"),
                  result["approvalPolicy"] as? String == "never",
                  let sandbox = result["sandbox"] as? [String: Any]
            else { throw LiveProtocolError.invalidField }
            try requireFields(sandbox, required: ["type"], optional: ["networkAccess"])
            guard sandbox["type"] as? String == "readOnly" else {
                throw LiveProtocolError.invalidField
            }
            if let networkAccess = sandbox["networkAccess"],
               networkAccess as? Bool != false {
                throw LiveProtocolError.invalidField
            }
            guard let thread = result["thread"] as? [String: Any],
                  thread["cwd"] as? String == cwd,
                  thread["modelProvider"] as? String == modelProvider
            else { throw LiveProtocolError.invalidField }
            if let serviceTier = result["serviceTier"] {
                try validateNullableString(serviceTier)
            }
            if let instructionSources = result["instructionSources"] {
                try validateStringList(instructionSources)
            }
            if let runtimeWorkspaceRoots = result["runtimeWorkspaceRoots"] {
                try validateStringList(runtimeWorkspaceRoots)
            }
            if let activePermissionProfile = result["activePermissionProfile"] {
                try validateNullableJSONObject(activePermissionProfile)
            }
            if let reasoningEffort = result["reasoningEffort"] {
                try validateNullableString(reasoningEffort)
            }
            try validateNullableString(result["approvalsReviewer"])
            if result["multiAgentMode"] != nil {
                _ = try string(result, "multiAgentMode")
            }
            return .threadStartResponse(id: id, threadID: threadID)
        }
        guard result.isEmpty else { throw LiveProtocolError.unknownField }
        return .emptyResponse(id: id)
    }

    private func decodeMethod(
        _ method: String,
        root: [String: Any]
    ) throws -> CodexAppServerMessage {
        if method == "item/started" || method == "item/completed"
            || method == "thread/realtime/itemAdded"
            || method == "item/commandExecution/requestApproval"
            || method == "item/fileChange/requestApproval"
            || method == "item/tool/requestUserInput"
        {
            let frame = try JSONSerialization.data(
                withJSONObject: root, options: [.sortedKeys]
            )
            switch try CodexCapabilityProtocol(
                maximumFrameBytes: maximumFrameBytes,
                maximumTextBytes: maximumTextBytes
            ).decodeActivity(
                frame,
                existingMillerCapabilities: existingMillerCapabilities
            ) {
            case .activity(let activity):
                return .capabilityActivity(activity)
            case .approval(let approval):
                return .providerApproval(approval)
            case .ignored:
                return .ignoredCapabilityActivity
            case .notCapability:
                break
            }
        }
        let isRequest = method == "account/chatgptAuthTokens/refresh"
        let isNotification = root["id"] == nil
        try requireFields(
            root,
            required: isRequest ? ["id", "method", "params"] : ["method", "params"],
            optional: isNotification ? ["emittedAtMs"] : []
        )
        if isNotification, let emittedAtMs = root["emittedAtMs"] {
            try validateEmittedAtMs(emittedAtMs)
        }
        guard let params = root["params"] as? [String: Any] else {
            throw LiveProtocolError.invalidField
        }
        switch method {
        case "remoteControl/status/changed":
            try requireRequiredFields(
                params,
                required: ["status", "serverName", "installationId"]
            )
            guard let status = params["status"] as? String,
                  ["disabled", "connecting", "connected", "errored"].contains(status),
                  !(try string(params, "serverName")).isEmpty,
                  !(try string(params, "installationId")).isEmpty
            else { throw LiveProtocolError.invalidField }
            if let environmentID = params["environmentId"] {
                try validateNullableNonemptyString(environmentID)
            }
            return .outOfBandStartupNotification
        case "configWarning":
            try requireRequiredFields(params, required: ["summary"])
            _ = try boundedText(params, "summary")
            if let details = params["details"] {
                try validateNullableString(details)
            }
            if let path = params["path"] {
                guard !(path is NSNull) else { throw LiveProtocolError.invalidField }
                _ = try string(params, "path")
            }
            if let range = params["range"] {
                try validateTextRange(range)
            }
            return .outOfBandStartupNotification
        case "account/login/completed":
            try requireRequiredFields(params, required: ["success"])
            guard params["success"] as? Bool == true else {
                throw LiveProtocolError.invalidField
            }
            if let loginID = params["loginId"] {
                try validateNullableString(loginID)
            }
            if let error = params["error"] {
                guard error is NSNull else { throw LiveProtocolError.invalidField }
            }
            return .accountLoginCompleted
        case "account/updated":
            if let authMode = params["authMode"] {
                try validateNullableEnum(
                    authMode, values: ["apikey", "chatgpt", "chatgptAuthTokens", "agentIdentity"]
                )
            }
            if let planType = params["planType"] {
                try validateNullableString(planType)
            }
            return .accountUpdated
        case "thread/started":
            try requireFields(params, required: ["thread"], optional: [])
            return .threadStarted(threadID: try validatedThread(params["thread"]))
        case "thread/realtime/itemAdded":
            try requireFields(params, required: ["threadId", "item"], optional: [])
            guard let item = params["item"] as? [String: Any] else {
                throw LiveProtocolError.invalidField
            }
            try validateBoundedJSON(item)
            return .realtimeItemAdded(threadID: try string(params, "threadId"))
        case "thread/realtime/started":
            try requireFields(params, required: ["threadId", "version"], optional: ["realtimeSessionId"])
            guard let version = RealtimeConversationVersion(
                rawValue: try string(params, "version")
            ) else { throw LiveProtocolError.invalidField }
            if let continuationID = try optionalString(params, "realtimeSessionId"),
               continuationID.utf8.count > maximumTextBytes {
                throw LiveProtocolError.payloadTooLarge
            }
            return .started(
                threadID: try string(params, "threadId"),
                version: version
            )
        case "thread/realtime/sdp":
            try requireFields(params, required: ["threadId", "sdp"], optional: [])
            return .sdp(threadID: try string(params, "threadId"), value: try boundedSDP(params, "sdp"))
        case "thread/realtime/transcript/delta":
            try requireFields(params, required: ["threadId", "role", "delta"], optional: [])
            return .transcriptDelta(
                threadID: try string(params, "threadId"),
                role: try transcriptRole(params),
                delta: try boundedText(params, "delta")
            )
        case "thread/realtime/transcript/done":
            try requireFields(params, required: ["threadId", "role", "text"], optional: [])
            return .transcriptDone(
                threadID: try string(params, "threadId"),
                role: try transcriptRole(params),
                text: try boundedText(params, "text")
            )
        case "thread/realtime/outputAudio/delta":
            try requireFields(params, required: ["threadId", "audio"], optional: [])
            guard let audio = params["audio"] as? [String: Any] else {
                throw LiveProtocolError.invalidField
            }
            try requireFields(
                audio,
                required: ["data", "numChannels", "sampleRate"],
                optional: ["itemId", "samplesPerChannel"]
            )
            guard let encoded = audio["data"] as? String,
                  let bytes = Data(base64Encoded: encoded)
            else { throw LiveProtocolError.invalidField }
            let sampleRate = try integer(audio, "sampleRate")
            let channels = try integer(audio, "numChannels")
            guard sampleRate > 0, sampleRate <= Int(UInt32.max),
                  channels > 0, channels <= Int(UInt16.max)
            else { throw LiveProtocolError.invalidField }
            let samples = try optionalInteger(audio, "samplesPerChannel")
            guard samples.map({ $0 >= 0 && $0 <= Int(UInt32.max) }) ?? true else {
                throw LiveProtocolError.invalidField
            }
            let itemID = try optionalString(audio, "itemId")
            guard bytes.count <= maximumAudioBytes else { throw LiveProtocolError.payloadTooLarge }
            return .outputAudio(
                threadID: try string(params, "threadId"),
                audio: try LiveAudioFrame(
                    data: bytes,
                    sampleRate: sampleRate,
                    numChannels: channels,
                    samplesPerChannel: samples,
                    itemID: itemID,
                    requirePCM16Alignment: false
                )
            )
        case "thread/realtime/error":
            try requireFields(params, required: ["threadId", "message"], optional: [])
            return .error(threadID: try string(params, "threadId"), message: try boundedText(params, "message"))
        case "thread/realtime/closed":
            try requireFields(params, required: ["threadId"], optional: ["reason"])
            return .closed(threadID: try string(params, "threadId"), reason: try optionalString(params, "reason"))
        case "account/chatgptAuthTokens/refresh":
            try requireFields(params, required: ["reason"], optional: ["previousAccountId"])
            let id = try requestID(root["id"])
            guard try string(params, "reason") == "unauthorized"
            else { throw LiveProtocolError.invalidField }
            return .credentialRefresh(
                id: id,
                previousAccountID: try optionalString(params, "previousAccountId")
            )
        default:
            return .outOfBandStartupNotification
        }
    }

    private func encode(_ value: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= maximumFrameBytes else { throw LiveProtocolError.frameTooLarge }
        return data + Data([0x0A])
    }

    private func boundedText(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key)
        guard value.utf8.count <= maximumTextBytes else { throw LiveProtocolError.payloadTooLarge }
        return value
    }

    func validateWebRTCOffer(_ offerSDP: String) throws {
        guard !offerSDP.isEmpty,
              !offerSDP.utf8.contains(0),
              offerSDP.utf8.count <= maximumTextBytes
        else {
            if offerSDP.utf8.count > maximumTextBytes { throw LiveProtocolError.payloadTooLarge }
            throw LiveProtocolError.invalidField
        }
        let lines = offerSDP.split(whereSeparator: \.isNewline)
        guard lines.first == "v=0" else { throw LiveProtocolError.invalidField }

        var sections: [[Substring]] = []
        for line in lines {
            if line.hasPrefix("m=") {
                sections.append([line])
            } else if !sections.isEmpty {
                sections[sections.count - 1].append(line)
            }
        }
        guard let audio = sections.first(where: {
            $0.first?.hasPrefix("m=audio ") == true
                && $0.first?.contains(" UDP/TLS/RTP/SAVPF ") == true
        }),
        let data = sections.first(where: {
            $0.first?.hasPrefix("m=application ") == true
                && $0.first?.contains(" UDP/DTLS/SCTP ") == true
                && $0.first?.contains(" webrtc-datachannel") == true
        }),
        let audioMID = attributeValue("a=mid:", in: audio),
        let dataMID = attributeValue("a=mid:", in: data),
        audioMID != dataMID
        else { throw LiveProtocolError.invalidField }

        let bundledMIDs = Set(lines
            .filter { $0.hasPrefix("a=group:BUNDLE ") }
            .flatMap { $0.dropFirst("a=group:BUNDLE ".count).split(separator: " ") }
            .map(String.init))
        guard bundledMIDs.contains(String(audioMID)), bundledMIDs.contains(String(dataMID)),
              hasNonemptyAttribute("a=ice-ufrag:", in: audio),
              hasNonemptyAttribute("a=ice-pwd:", in: audio),
              hasSHA256Fingerprint(in: audio),
              hasExactLine("a=setup:actpass", in: audio),
              hasNonemptyAttribute("a=rtpmap:", in: audio),
              hasNonemptyAttribute("a=ice-ufrag:", in: data),
              hasNonemptyAttribute("a=ice-pwd:", in: data),
              hasSHA256Fingerprint(in: data),
              hasExactLine("a=setup:actpass", in: data),
              hasDecimalAttribute("a=sctp-port:", in: data),
              hasDecimalAttribute("a=max-message-size:", in: data)
        else { throw LiveProtocolError.invalidField }
    }

    private func attributeValue(_ prefix: String, in section: [Substring]) -> Substring? {
        section.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count)
    }

    private func hasNonemptyAttribute(_ prefix: String, in section: [Substring]) -> Bool {
        guard let value = attributeValue(prefix, in: section) else { return false }
        return !value.isEmpty
    }

    private func hasExactLine(_ line: String, in section: [Substring]) -> Bool {
        section.contains { $0 == line }
    }

    private func hasSHA256Fingerprint(in section: [Substring]) -> Bool {
        guard let value = attributeValue("a=fingerprint:sha-256 ", in: section),
              !value.isEmpty
        else { return false }
        let bytes = value.split(separator: ":", omittingEmptySubsequences: false)
        return bytes.count == 32 && bytes.allSatisfy { octet in
            octet.utf8.count == 2 && octet.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 70)
                    || (byte >= 97 && byte <= 102)
            }
        }
    }

    private func hasDecimalAttribute(_ prefix: String, in section: [Substring]) -> Bool {
        guard let value = attributeValue(prefix, in: section), !value.isEmpty else { return false }
        return value.allSatisfy(\.isNumber)
    }

    private func boundedSDP(_ object: [String: Any], _ key: String) throws -> String {
        let value = try boundedText(object, key)
        guard !value.isEmpty,
              !value.utf8.contains(0),
              value.split(whereSeparator: \.isNewline).first == "v=0"
        else { throw LiveProtocolError.invalidField }
        return value
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw LiveProtocolError.invalidField }
        guard value.utf8.count <= maximumTextBytes else {
            throw LiveProtocolError.payloadTooLarge
        }
        return value
    }

    private func transcriptRole(_ object: [String: Any]) throws -> String {
        let role = try string(object, "role")
        guard role == "user" || role == "assistant" else {
            throw LiveProtocolError.invalidField
        }
        return role
    }

    private func validateNullableEnum(_ value: Any?, values: Set<String>) throws {
        if value is NSNull { return }
        guard let value = value as? String, values.contains(value) else {
            throw LiveProtocolError.invalidField
        }
    }

    private func validateStringList(_ value: Any?) throws {
        guard let values = value as? [String], values.count <= 64 else {
            throw LiveProtocolError.invalidField
        }
        var bytes = 0
        for value in values {
            bytes += value.utf8.count
            guard bytes <= maximumTextBytes else { throw LiveProtocolError.payloadTooLarge }
        }
    }

    private func validateNullableString(_ value: Any?) throws {
        if value is NSNull { return }
        guard let value = value as? String else { throw LiveProtocolError.invalidField }
        guard value.utf8.count <= maximumTextBytes else {
            throw LiveProtocolError.payloadTooLarge
        }
    }

    private func validateNullableNonemptyString(_ value: Any?) throws {
        if value is NSNull { return }
        guard let value = value as? String, !value.isEmpty else {
            throw LiveProtocolError.invalidField
        }
        guard value.utf8.count <= maximumTextBytes else {
            throw LiveProtocolError.payloadTooLarge
        }
    }

    private func validatedThread(_ value: Any?) throws -> String {
        guard let thread = value as? [String: Any] else { throw LiveProtocolError.invalidField }
        try requireRequiredFields(
            thread,
            required: [
                "id", "sessionId", "preview", "ephemeral", "modelProvider", "createdAt",
                "updatedAt", "status", "cwd", "cliVersion", "source", "turns",
            ]
        )
        let threadID = try string(thread, "id")
        let modelProvider = try string(thread, "modelProvider")
        let cwd = try string(thread, "cwd")
        guard !threadID.isEmpty,
              thread["ephemeral"] as? Bool == true,
              !modelProvider.isEmpty,
              cwd.hasPrefix("/"),
              let turns = thread["turns"] as? [Any], turns.isEmpty,
              let status = thread["status"] as? [String: Any]
        else { throw LiveProtocolError.invalidField }
        if let extra = thread["extra"] {
            try validateNullableJSONObject(extra)
        }
        _ = try string(thread, "sessionId")
        if thread["historyMode"] != nil {
            _ = try string(thread, "historyMode")
        }
        _ = try string(thread, "preview")
        try validateBoundedJSON(status)
        _ = try integer(thread, "createdAt")
        _ = try integer(thread, "updatedAt")
        if let recencyAt = thread["recencyAt"] {
            try validateNullableInteger(recencyAt)
        }
        for key in [
            "forkedFromId", "parentThreadId", "path", "agentNickname", "agentRole", "name",
        ] {
            if let value = thread[key] {
                try validateNullableString(value)
            }
        }
        if let directInput = thread["canAcceptDirectInput"] {
            guard directInput is NSNull || directInput is Bool else {
                throw LiveProtocolError.invalidField
            }
        }
        if let isPinned = thread["isPinned"], !(isPinned is Bool) {
            throw LiveProtocolError.invalidField
        }
        _ = try string(thread, "cliVersion")
        _ = try string(thread, "source")
        if let threadSource = thread["threadSource"] {
            try validateNullableString(threadSource)
        }
        if let gitInfo = thread["gitInfo"] {
            try validateNullableJSONObject(gitInfo)
        }
        return threadID
    }

    private func validateNullableJSONObject(_ value: Any?) throws {
        if value is NSNull { return }
        guard let object = value as? [String: Any] else {
            throw LiveProtocolError.invalidField
        }
        try validateBoundedJSON(object)
    }

    private func validateBoundedJSON(_ value: Any, depth: Int = 0) throws {
        guard depth <= 16 else { throw LiveProtocolError.payloadTooLarge }
        if value is NSNull || value is Bool { return }
        if let string = value as? String {
            guard string.utf8.count <= maximumTextBytes else {
                throw LiveProtocolError.payloadTooLarge
            }
            return
        }
        if let number = value as? NSNumber {
            guard number.doubleValue.isFinite else { throw LiveProtocolError.invalidField }
            return
        }
        if let values = value as? [Any] {
            guard values.count <= 256 else { throw LiveProtocolError.payloadTooLarge }
            for child in values {
                try validateBoundedJSON(child, depth: depth + 1)
            }
            return
        }
        if let object = value as? [String: Any] {
            guard object.count <= 256 else { throw LiveProtocolError.payloadTooLarge }
            for (key, child) in object {
                guard key.utf8.count <= maximumTextBytes else {
                    throw LiveProtocolError.payloadTooLarge
                }
                try validateBoundedJSON(child, depth: depth + 1)
            }
            return
        }
        throw LiveProtocolError.invalidField
    }

    private func validateNullableInteger(_ value: Any?) throws {
        if value is NSNull { return }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int64.min), number.doubleValue <= Double(Int64.max)
        else { throw LiveProtocolError.invalidField }
    }

    private func validateEmittedAtMs(_ value: Any) throws {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0,
              number.doubleValue <= 9_007_199_254_740_991
        else { throw LiveProtocolError.invalidField }
    }

    private func validateTextRange(_ value: Any) throws {
        guard let range = value as? [String: Any] else {
            throw LiveProtocolError.invalidField
        }
        try requireFields(range, required: ["start", "end"], optional: [])
        for key in ["start", "end"] {
            guard let position = range[key] as? [String: Any] else {
                throw LiveProtocolError.invalidField
            }
            try requireFields(position, required: ["line", "column"], optional: [])
            guard try integer(position, "line") > 0,
                  try integer(position, "column") > 0
            else { throw LiveProtocolError.invalidField }
        }
    }

    private func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max)
        else {
            throw LiveProtocolError.invalidField
        }
        return number.intValue
    }

    private func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        if value is NSNull { return nil }
        guard let string = value as? String else { throw LiveProtocolError.invalidField }
        return string
    }

    private func optionalInteger(_ object: [String: Any], _ key: String) throws -> Int? {
        guard let value = object[key] else { return nil }
        if value is NSNull { return nil }
        return try integer(object, key)
    }

    private func requestID(_ value: Any?) throws -> JSONRPCRequestID {
        if let value = value as? String { return .string(value) }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int64.min),
              number.doubleValue <= Double(Int64.max)
        else { throw LiveProtocolError.invalidField }
        return .integer(number.int64Value)
    }

    private func requireFields(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String>
    ) throws {
        guard required.isSubset(of: Set(object.keys)) else { throw LiveProtocolError.missingField }
        guard Set(object.keys).isSubset(of: required.union(optional)) else {
            throw LiveProtocolError.unknownField
        }
    }

    private func requireRequiredFields(
        _ object: [String: Any],
        required: Set<String>
    ) throws {
        guard required.isSubset(of: Set(object.keys)) else {
            throw LiveProtocolError.missingField
        }
    }
}

import Foundation

public enum RemoteLiveBridgeContract {
    public static let protocolName = "miller.remote-live"
    public static let version = 1
    public static let maximumFrameBytes = 131_072
    public static let maximumSDPBytes = 65_536
    public static let maximumClientIDBytes = 64
    public static let maximumTerminalReasonBytes = 64
    public static let replayCapacity = 256
    public static let replayRetention: Duration = .seconds(5 * 60)
    public static let maximumQueuedFrames = 64
    public static let clientHandshakeTimeout: Duration = .seconds(5)
    public static let clientIdleTimeout: Duration = .seconds(30)
    public static let clientWriteTimeout: Duration = .seconds(1)
    public static let socketFileName = "remote-live-v1.sock"
    public static let maximumActiveClients = 8
    public static let maximumBufferedBytes = maximumFrameBytes * 8

    public static func socketURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ai.millrace.miller", isDirectory: true)
            .appendingPathComponent(socketFileName, isDirectory: false)
    }
}

public enum RemoteLiveBridgeError: Error, Equatable, Sendable {
    case invalidFrame
    case invalidJSON
    case unsupportedVersion
    case unknownField(String)
    case missingField(String)
    case invalidField(String)
    case duplicateField(String)
    case oversizedFrame
    case oversizedSDP
    case oversizedQueue
    case staleGeneration
    case replay
    case busy
    case hostUnavailable
    case providerUnavailable
    case timeout
    case notFound
    case conflict
    case expired
    case unauthorized
    case internalFailure
}

public enum RemoteLiveLifecycleState: String, Codable, Equatable, Sendable {
    case idle
    case starting
    case connecting
    case listening
    case responding
    case speaking
    case ending
    case closed
    case failed
}

public enum RemoteLiveTerminalReason: String, Codable, Equatable, Sendable, CaseIterable {
    case completed
    case interrupted
    case clientClosed = "client_closed"
    case pageHidden = "page_hidden"
    case offline
    case peerFailed = "peer_failed"
    case trackEnded = "track_ended"
    case dataChannelClosed = "data_channel_closed"
    case leaseExpired = "lease_expired"
    case sessionExpired = "session_expired"
    case gatewayShutdown = "gateway_shutdown"
    case bridgeDisconnected = "bridge_disconnected"
    case providerClosed = "provider_closed"
    case providerFailed = "provider_failed"
    case hostShutdown = "host_shutdown"
    case startCancelled = "start_cancelled"
    case timeout

    public func historyOutcome(afterAdmission: Bool) -> RemoteLiveHistoryOutcome {
        switch self {
        case .completed, .clientClosed, .providerClosed:
            return .completed
        case .interrupted:
            return .stopped
        case .pageHidden, .offline, .leaseExpired, .sessionExpired,
             .gatewayShutdown, .bridgeDisconnected:
            return afterAdmission ? .stopped : .abandoned
        case .peerFailed, .trackEnded, .dataChannelClosed, .providerFailed, .timeout:
            return afterAdmission ? .failed : .abandoned
        case .hostShutdown, .startCancelled:
            return .abandoned
        }
    }
}

public enum RemoteLiveHistoryOutcome: String, Equatable, Sendable {
    case completed
    case stopped
    case failed
    case abandoned
}

public enum RemoteLiveErrorCode: String, Codable, Equatable, Sendable, CaseIterable {
    case busy
    case unauthorized
    case invalidRequest = "invalid_request"
    case unsupportedVersion = "unsupported_version"
    case staleGeneration = "stale_generation"
    case replay
    case notFound = "not_found"
    case conflict
    case expired
    case hostUnavailable = "host_unavailable"
    case providerUnavailable = "provider_unavailable"
    case timeout
    case internalFailure = "internal_failure"
}

public enum RemoteLiveRequest: Equatable, Sendable {
    case hello(requestID: UUID, clientID: String)
    case status(requestID: UUID, hostGeneration: UUID)
    case start(
        requestID: UUID,
        hostGeneration: UUID,
        clientSessionID: UUID,
        offerSDP: String
    )
    case connected(requestID: UUID, hostGeneration: UUID, clientSessionID: UUID)
    case activity(requestID: UUID, hostGeneration: UUID, clientSessionID: UUID)
    case interrupt(requestID: UUID, hostGeneration: UUID, clientSessionID: UUID)
    case end(
        requestID: UUID,
        hostGeneration: UUID,
        clientSessionID: UUID,
        reason: RemoteLiveTerminalReason
    )

    public var requestID: UUID {
        switch self {
        case let .hello(requestID, _), let .status(requestID, _),
             let .start(requestID, _, _, _), let .connected(requestID, _, _),
             let .activity(requestID, _, _), let .interrupt(requestID, _, _),
             let .end(requestID, _, _, _):
            return requestID
        }
    }

    public var hostGeneration: UUID? {
        switch self {
        case .hello: nil
        case let .status(_, generation), let .start(_, generation, _, _),
             let .connected(_, generation, _), let .activity(_, generation, _),
             let .interrupt(_, generation, _), let .end(_, generation, _, _):
            generation
        }
    }

    public var typeName: String {
        switch self {
        case .hello: "hello"
        case .status: "status"
        case .start: "start"
        case .connected: "connected"
        case .activity: "activity"
        case .interrupt: "interrupt"
        case .end: "end"
        }
    }
}

public enum RemoteLiveResponse: Equatable, Sendable {
    case helloAck(requestID: UUID, hostGeneration: UUID)
    case statusResult(
        requestID: UUID,
        hostGeneration: UUID,
        clientSessionID: UUID?,
        state: RemoteLiveLifecycleState,
        reason: RemoteLiveTerminalReason?
    )
    case startResult(
        requestID: UUID,
        hostGeneration: UUID,
        clientSessionID: UUID,
        answerSDP: String
    )
    case operationResult(
        requestID: UUID,
        hostGeneration: UUID,
        clientSessionID: UUID?,
        outcome: String
    )
    case error(
        requestID: UUID,
        hostGeneration: UUID,
        code: RemoteLiveErrorCode
    )

    public var requestID: UUID {
        switch self {
        case let .helloAck(requestID, _), let .statusResult(requestID, _, _, _, _),
             let .startResult(requestID, _, _, _),
             let .operationResult(requestID, _, _, _), let .error(requestID, _, _):
            return requestID
        }
    }

    public var hostGeneration: UUID {
        switch self {
        case let .helloAck(_, generation), let .statusResult(_, generation, _, _, _),
             let .startResult(_, generation, _, _),
             let .operationResult(_, generation, _, _), let .error(_, generation, _):
            return generation
        }
    }
}

public enum RemoteLiveMessage: Equatable, Sendable {
    case request(RemoteLiveRequest)
    case response(RemoteLiveResponse)
}

public enum RemoteLiveBridgeCodec {
    public static func encodeFrame(_ message: RemoteLiveMessage) throws -> Data {
        let body = try encodeJSON(message)
        guard body.count <= RemoteLiveBridgeContract.maximumFrameBytes else {
            throw RemoteLiveBridgeError.oversizedFrame
        }
        var frame = Data()
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    public static func encodeFrame(_ request: RemoteLiveRequest) throws -> Data {
        try encodeFrame(.request(request))
    }

    public static func encodeFrame(_ response: RemoteLiveResponse) throws -> Data {
        try encodeFrame(.response(response))
    }

    public static func decodeFrame(_ frame: Data) throws -> RemoteLiveMessage {
        guard frame.count >= 4 else { throw RemoteLiveBridgeError.invalidFrame }
        let length = frame.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length > 0 else { throw RemoteLiveBridgeError.invalidFrame }
        guard Int(length) <= RemoteLiveBridgeContract.maximumFrameBytes else {
            throw RemoteLiveBridgeError.oversizedFrame
        }
        guard frame.count == Int(length) + 4 else {
            throw RemoteLiveBridgeError.invalidFrame
        }
        return try decodeJSON(Data(frame.dropFirst(4)))
    }

    private static func encodeJSON(_ message: RemoteLiveMessage) throws -> Data {
        let object: [String: Any]
        switch message {
        case let .request(request): object = requestObject(request)
        case let .response(response): object = responseObject(response)
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw RemoteLiveBridgeError.invalidJSON
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        } catch {
            throw RemoteLiveBridgeError.invalidJSON
        }
    }

    private static func requestObject(_ request: RemoteLiveRequest) -> [String: Any] {
        var object: [String: Any] = [
            "protocol": RemoteLiveBridgeContract.protocolName,
            "version": RemoteLiveBridgeContract.version,
            "type": request.typeName,
            "request_id": request.requestID.uuidString.lowercased(),
        ]
        switch request {
        case let .hello(_, clientID):
            object["host_generation"] = NSNull()
            object["payload"] = ["client_id": clientID]
        case let .status(_, generation):
            object["host_generation"] = generation.uuidString.lowercased()
            object["payload"] = [:]
        case let .start(_, generation, sessionID, offer):
            object["host_generation"] = generation.uuidString.lowercased()
            object["payload"] = [
                "client_session_id": sessionID.uuidString.lowercased(),
                "offer_sdp": offer,
            ]
        case let .connected(_, generation, sessionID),
             let .activity(_, generation, sessionID),
             let .interrupt(_, generation, sessionID):
            object["host_generation"] = generation.uuidString.lowercased()
            object["payload"] = ["client_session_id": sessionID.uuidString.lowercased()]
        case let .end(_, generation, sessionID, reason):
            object["host_generation"] = generation.uuidString.lowercased()
            object["payload"] = [
                "client_session_id": sessionID.uuidString.lowercased(),
                "reason": reason.rawValue,
            ]
        }
        return object
    }

    private static func responseObject(_ response: RemoteLiveResponse) -> [String: Any] {
        var object: [String: Any] = [
            "protocol": RemoteLiveBridgeContract.protocolName,
            "version": RemoteLiveBridgeContract.version,
            "request_id": response.requestID.uuidString.lowercased(),
            "host_generation": response.hostGeneration.uuidString.lowercased(),
        ]
        switch response {
        case .helloAck:
            object["type"] = "hello_ack"
            object["payload"] = ["negotiated_version": RemoteLiveBridgeContract.version]
        case let .statusResult(_, _, sessionID, state, reason):
            object["type"] = "status_result"
            var payload: [String: Any] = ["state": state.rawValue]
            if let sessionID { payload["client_session_id"] = sessionID.uuidString.lowercased() }
            if let reason { payload["reason"] = reason.rawValue }
            object["payload"] = payload
        case let .startResult(_, _, sessionID, answer):
            object["type"] = "start_result"
            object["payload"] = [
                "client_session_id": sessionID.uuidString.lowercased(),
                "answer_sdp": answer,
            ]
        case let .operationResult(_, _, sessionID, outcome):
            object["type"] = "operation_result"
            var payload: [String: Any] = ["outcome": outcome]
            if let sessionID { payload["client_session_id"] = sessionID.uuidString.lowercased() }
            object["payload"] = payload
        case let .error(_, _, code):
            object["type"] = "error"
            object["payload"] = ["code": code.rawValue]
        }
        return object
    }

    private static func decodeJSON(_ data: Data) throws -> RemoteLiveMessage {
        guard data.count <= RemoteLiveBridgeContract.maximumFrameBytes else {
            throw RemoteLiveBridgeError.oversizedFrame
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty,
              UniqueJSONKeyValidator.validate(text)
        else { throw RemoteLiveBridgeError.invalidJSON }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RemoteLiveBridgeError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw RemoteLiveBridgeError.invalidField("envelope")
        }
        try exactKeys(object, required: ["protocol", "version", "type", "request_id", "host_generation", "payload"])
        guard object["protocol"] as? String == RemoteLiveBridgeContract.protocolName else {
            throw RemoteLiveBridgeError.invalidField("protocol")
        }
        guard let version = strictInteger(object["version"]),
              version == RemoteLiveBridgeContract.version
        else {
            if let version = strictInteger(object["version"]),
               version != RemoteLiveBridgeContract.version {
                throw RemoteLiveBridgeError.unsupportedVersion
            }
            throw RemoteLiveBridgeError.invalidField("version")
        }
        guard let type = object["type"] as? String else {
            throw RemoteLiveBridgeError.invalidField("type")
        }
        let requestID = try uuid(object["request_id"], field: "request_id")
        let hostValue = object["host_generation"]
        if type == "hello" {
            guard hostValue is NSNull else {
                throw RemoteLiveBridgeError.invalidField("host_generation")
            }
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["client_id"])
            guard let clientID = payload["client_id"] as? String,
                  clientID.utf8.count <= RemoteLiveBridgeContract.maximumClientIDBytes,
                  clientID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
            else { throw RemoteLiveBridgeError.invalidField("client_id") }
            return .request(.hello(requestID: requestID, clientID: clientID))
        }
        let hostGeneration = try uuid(hostValue, field: "host_generation")
        switch type {
        case "status":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: [])
            return .request(.status(requestID: requestID, hostGeneration: hostGeneration))
        case "start":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["client_session_id", "offer_sdp"])
            let sessionID = try uuid(payload["client_session_id"], field: "client_session_id")
            let offer = try sdp(payload["offer_sdp"], field: "offer_sdp")
            return .request(.start(
                requestID: requestID,
                hostGeneration: hostGeneration,
                clientSessionID: sessionID,
                offerSDP: offer
            ))
        case "connected", "activity", "interrupt":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["client_session_id"])
            let sessionID = try uuid(payload["client_session_id"], field: "client_session_id")
            let request: RemoteLiveRequest = switch type {
            case "connected": .connected(requestID: requestID, hostGeneration: hostGeneration, clientSessionID: sessionID)
            case "activity": .activity(requestID: requestID, hostGeneration: hostGeneration, clientSessionID: sessionID)
            default: .interrupt(requestID: requestID, hostGeneration: hostGeneration, clientSessionID: sessionID)
            }
            return .request(request)
        case "end":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["client_session_id", "reason"])
            let sessionID = try uuid(payload["client_session_id"], field: "client_session_id")
            guard let rawReason = payload["reason"] as? String,
                  let reason = RemoteLiveTerminalReason(rawValue: rawReason),
                  rawReason.utf8.count <= RemoteLiveBridgeContract.maximumTerminalReasonBytes
            else { throw RemoteLiveBridgeError.invalidField("reason") }
            return .request(.end(
                requestID: requestID,
                hostGeneration: hostGeneration,
                clientSessionID: sessionID,
                reason: reason
            ))
        case "hello_ack":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["negotiated_version"])
            guard let negotiated = strictInteger(payload["negotiated_version"]),
                  negotiated == RemoteLiveBridgeContract.version
            else { throw RemoteLiveBridgeError.invalidField("negotiated_version") }
            return .response(.helloAck(requestID: requestID, hostGeneration: hostGeneration))
        case "status_result":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["state"], optional: ["client_session_id", "reason"])
            guard let rawState = payload["state"] as? String,
                  let state = RemoteLiveLifecycleState(rawValue: rawState)
            else { throw RemoteLiveBridgeError.invalidField("state") }
            let sessionID = try optionalUUID(payload["client_session_id"], field: "client_session_id")
            let reason = try optionalReason(payload["reason"])
            return .response(.statusResult(
                requestID: requestID,
                hostGeneration: hostGeneration,
                clientSessionID: sessionID,
                state: state,
                reason: reason
            ))
        case "start_result":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["client_session_id", "answer_sdp"])
            return .response(.startResult(
                requestID: requestID,
                hostGeneration: hostGeneration,
                clientSessionID: try uuid(payload["client_session_id"], field: "client_session_id"),
                answerSDP: try sdp(payload["answer_sdp"], field: "answer_sdp")
            ))
        case "operation_result":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["outcome"], optional: ["client_session_id"])
            guard payload["outcome"] as? String == "ok" else {
                throw RemoteLiveBridgeError.invalidField("outcome")
            }
            return .response(.operationResult(
                requestID: requestID,
                hostGeneration: hostGeneration,
                clientSessionID: try optionalUUID(payload["client_session_id"], field: "client_session_id"),
                outcome: "ok"
            ))
        case "error":
            let payload = try payloadObject(object["payload"])
            try exactKeys(payload, required: ["code"])
            guard let rawCode = payload["code"] as? String,
                  let code = RemoteLiveErrorCode(rawValue: rawCode)
            else { throw RemoteLiveBridgeError.invalidField("code") }
            return .response(.error(
                requestID: requestID,
                hostGeneration: hostGeneration,
                code: code
            ))
        default:
            throw RemoteLiveBridgeError.invalidField("type")
        }
    }

    private static func payloadObject(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw RemoteLiveBridgeError.invalidField("payload")
        }
        return object
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
                  .contains(String(cString: number.objCType)),
              number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.intValue
    }

    private static func exactKeys(
        _ object: [String: Any],
        required: [String],
        optional: [String] = []
    ) throws {
        let allowed = Set(required).union(optional)
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
            throw RemoteLiveBridgeError.unknownField(unknown)
        }
        if let missing = required.first(where: { object[$0] == nil }) {
            throw RemoteLiveBridgeError.missingField(missing)
        }
        for key in optional where object[key] is NSNull {
            throw RemoteLiveBridgeError.invalidField(key)
        }
    }

    private static func uuid(_ value: Any?, field: String) throws -> UUID {
        guard let value = value as? String,
              value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil,
              let uuid = UUID(uuidString: value)
        else { throw RemoteLiveBridgeError.invalidField(field) }
        return uuid
    }

    private static func optionalUUID(_ value: Any?, field: String) throws -> UUID? {
        guard value != nil else { return nil }
        return try uuid(value, field: field)
    }

    private static func optionalReason(_ value: Any?) throws -> RemoteLiveTerminalReason? {
        guard value != nil else { return nil }
        guard let raw = value as? String, let reason = RemoteLiveTerminalReason(rawValue: raw)
        else { throw RemoteLiveBridgeError.invalidField("reason") }
        return reason
    }

    private static func sdp(_ value: Any?, field: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw RemoteLiveBridgeError.invalidField(field)
        }
        guard value.utf8.count <= RemoteLiveBridgeContract.maximumSDPBytes else {
            throw RemoteLiveBridgeError.oversizedSDP
        }
        return value
    }
}

private enum UniqueJSONKeyValidator {
    static func validate(_ text: String) -> Bool {
        var parser = Parser(bytes: Array(text.utf8))
        return parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() -> Bool {
            guard parseValue(depth: 0) else { return false }
            skipWhitespace()
            return index == bytes.count
        }

        mutating func parseValue(depth: Int) -> Bool {
            guard depth <= 64 else { return false }
            skipWhitespace()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case 0x7B: return parseObject(depth: depth + 1)
            case 0x5B: return parseArray(depth: depth + 1)
            case 0x22: return parseString() != nil
            case 0x74: return parseLiteral(Array("true".utf8))
            case 0x66: return parseLiteral(Array("false".utf8))
            case 0x6E: return parseLiteral(Array("null".utf8))
            default: return parseNumber()
            }
        }

        mutating func parseObject(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            var keys = Set<String>()
            if consume(0x7D) { return true }
            while index < bytes.count {
                skipWhitespace()
                guard let key = parseString(), keys.insert(key).inserted else { return false }
                skipWhitespace()
                guard consume(0x3A), parseValue(depth: depth) else { return false }
                skipWhitespace()
                if consume(0x7D) { return true }
                guard consume(0x2C) else { return false }
            }
            return false
        }

        mutating func parseArray(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return true }
            while index < bytes.count {
                guard parseValue(depth: depth) else { return false }
                skipWhitespace()
                if consume(0x5D) { return true }
                guard consume(0x2C) else { return false }
            }
            return false
        }

        mutating func parseString() -> String? {
            guard consume(0x22) else { return nil }
            let start = index - 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte < 0x20 && !escaped { return nil }
                if escaped {
                    if byte == 0x75 {
                        guard index + 4 <= bytes.count,
                              bytes[index..<(index + 4)].allSatisfy({
                                  ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66)
                              }) else { return nil }
                        index += 4
                    } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte) {
                        return nil
                    }
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    let raw = Data(Array(bytes[start..<index]))
                    guard let value = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]),
                          let decoded = value as? String
                    else { return nil }
                    return decoded
                }
            }
            return nil
        }

        mutating func parseLiteral(_ literal: [UInt8]) -> Bool {
            guard bytes[index...].prefix(literal.count).elementsEqual(literal) else { return false }
            index += literal.count
            return true
        }

        mutating func parseNumber() -> Bool {
            let start = index
            if index < bytes.count && bytes[index] == 0x2D { index += 1 }
            if index < bytes.count && bytes[index] == 0x30 {
                index += 1
            } else {
                guard index < bytes.count, bytes[index] >= 0x31, bytes[index] <= 0x39 else { return false }
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            }
            if consume(0x2E) {
                guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return false }
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return false }
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            }
            return index > start
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}

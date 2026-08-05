import Foundation

public enum GatewayProtocol {
    public static let name = "miller.gateway"
    public static let version = 1
    public static let maximumRecordBytes = 1_048_576
}

public enum GatewayProtocolError: Error, Equatable, Sendable {
    case invalidFraming
    case incompleteRecord
    case recordTooLarge
    case invalidUTF8
    case invalidJSON
    case duplicateKey
    case unknownRecordType
    case unknownField
    case missingField
    case invalidField
    case invalidSequence
    case processUnavailable
    case readinessTimeout
    case cancellationTimeout
    case retryCircuitOpen
    case authenticationFailed(String)
}

public enum JSONValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(foundation value: Any) throws {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                let number = value.doubleValue
                guard number.isFinite, number.rounded() == number,
                      number >= Double(Int.min), number <= Double(Int.max)
                else {
                    throw GatewayProtocolError.invalidField
                }
                self = .integer(value.intValue)
            }
        case is NSNull:
            self = .null
        case let value as [Any]:
            self = .array(try value.map(JSONValue.init(foundation:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(JSONValue.init(foundation:)))
        default:
            throw GatewayProtocolError.invalidField
        }
    }

    var foundationValue: Any {
        switch self {
        case let .string(value): value
        case let .integer(value): value
        case let .bool(value): value
        case .null: NSNull()
        case let .array(values): values.map(\.foundationValue)
        case let .object(values): values.mapValues(\.foundationValue)
        }
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var integerValue: Int? {
        guard case let .integer(value) = self else { return nil }
        return value
    }
}

public struct GatewayRecord: Equatable, Sendable {
    public let type: String
    public let sessionID: String
    public let requestID: String?
    public let fields: [String: JSONValue]

    public static func make(
        type: String,
        sessionID: String,
        requestID: String? = nil,
        fields: [String: JSONValue] = [:]
    ) throws -> GatewayRecord {
        var object = fields
        object["protocol"] = .string(GatewayProtocol.name)
        object["version"] = .integer(GatewayProtocol.version)
        object["type"] = .string(type)
        object["session_id"] = .string(sessionID)
        if let requestID {
            object["request_id"] = .string(requestID)
        }
        return try validate(object)
    }

    public static func decode(_ data: Data) throws -> GatewayRecord {
        try StrictJSONScanner.validate(data)
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GatewayProtocolError.invalidJSON
        }
        guard let object = raw as? [String: Any] else {
            throw GatewayProtocolError.invalidJSON
        }
        let values = try object.mapValues(JSONValue.init(foundation:))
        return try validate(values)
    }

    var object: [String: JSONValue] {
        var object = fields
        object["protocol"] = .string(GatewayProtocol.name)
        object["version"] = .integer(GatewayProtocol.version)
        object["type"] = .string(type)
        object["session_id"] = .string(sessionID)
        if let requestID {
            object["request_id"] = .string(requestID)
        }
        return object
    }

    public subscript(_ field: String) -> JSONValue? {
        fields[field]
    }

    private static func validate(
        _ object: [String: JSONValue]
    ) throws -> GatewayRecord {
        guard object["protocol"] == .string(GatewayProtocol.name),
              object["version"] == .integer(GatewayProtocol.version),
              let type = object["type"]?.stringValue,
              let sessionID = object["session_id"]?.stringValue,
              isCanonicalV4UUID(sessionID)
        else {
            throw GatewayProtocolError.invalidField
        }
        guard let schema = schemas[type] else {
            throw GatewayProtocolError.unknownRecordType
        }
        let requestID = object["request_id"]?.stringValue
        if schema.requiresRequest {
            guard let requestID, isCanonicalV4UUID(requestID) else {
                throw GatewayProtocolError.missingField
            }
        } else if requestID != nil {
            throw GatewayProtocolError.unknownField
        }

        let base = Set(["protocol", "version", "type", "session_id"])
            .union(schema.requiresRequest ? ["request_id"] : [])
        let allowed = base.union(schema.required.keys).union(schema.optional.keys)
        guard Set(object.keys).isSubset(of: allowed) else {
            throw GatewayProtocolError.unknownField
        }
        for (key, kind) in schema.required {
            guard let value = object[key] else {
                throw GatewayProtocolError.missingField
            }
            try validate(value, as: kind, field: key)
        }
        for (key, kind) in schema.optional {
            if let value = object[key] {
                try validate(value, as: kind, field: key)
            }
        }
        try rejectNUL(in: .object(object))

        var fields = object
        for key in base {
            fields.removeValue(forKey: key)
        }
        return GatewayRecord(
            type: type,
            sessionID: sessionID,
            requestID: requestID,
            fields: fields
        )
    }

    private enum FieldKind {
        case string
        case uuid
        case nonnegativeInteger
        case optionalNonnegativeInteger
        case readinessStatus
        case stringArray
        case integerArray
        case object
        case objectArray
        case modelChoices
        case anyArray
        case nullableString
    }

    private struct RecordSchema {
        let requiresRequest: Bool
        let required: [String: FieldKind]
        let optional: [String: FieldKind]

        init(
            request: Bool = true,
            required: [String: FieldKind],
            optional: [String: FieldKind] = [:]
        ) {
            requiresRequest = request
            self.required = required
            self.optional = optional
        }
    }

    private static let schemas: [String: RecordSchema] = [
        "gateway.ready": .init(
            request: false,
            required: [
                "helper_version": .string,
                "supported_protocols": .integerArray,
            ]
        ),
        "provider.readiness": .init(required: [
            "provider_profile": .object,
            "credential_ref": .uuid,
        ]),
        "provider.readiness_result": .init(
            required: ["status": .readinessStatus],
            optional: ["error_code": .string]
        ),
        "provider.models": .init(required: [
            "provider_kind": .string,
        ]),
        "provider.models_result": .init(required: [
            "provider_kind": .string,
            "default_model": .string,
            "models": .modelChoices,
        ]),
        "auth.begin": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "credential_ref": .uuid, "provider_kind": .string,
        ]),
        "auth.refresh": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "credential_ref": .uuid,
        ]),
        "auth.open_url": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "url": .string,
        ]),
        "auth.credential_candidate": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "credential_ref": .uuid, "credential": .object,
        ]),
        "auth.persisted": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "credential_ref": .uuid,
        ]),
        "auth.persist_failed": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "credential_ref": .uuid,
        ]),
        "auth.restore": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "credential_ref": .uuid, "credential": .object,
        ]),
        "auth.cancel": .init(required: [
            "operation_id": .uuid, "target_generation": .nonnegativeInteger,
        ]),
        "auth.clear": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "credential_ref": .uuid,
        ]),
        "auth.completed": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "credential_ref": .uuid,
        ]),
        "auth.stopped": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
        ]),
        "auth.failed": .init(required: [
            "operation_id": .uuid, "generation": .nonnegativeInteger,
            "error_code": .string,
        ]),
        "reasoning.start": .init(required: [
            "conversation_id": .uuid, "turn_id": .uuid,
            "generation": .nonnegativeInteger, "provider_profile": .object,
            "context": .objectArray, "user_text": .string, "tools": .anyArray,
        ]),
        "reasoning.cancel": .init(required: [
            "turn_id": .uuid, "target_generation": .nonnegativeInteger,
        ]),
        "reasoning.accepted": .init(required: [
            "turn_id": .uuid, "generation": .nonnegativeInteger,
        ]),
        "reasoning.text_delta": .init(required: [
            "turn_id": .uuid, "generation": .nonnegativeInteger,
            "ordinal": .nonnegativeInteger, "text": .string,
        ]),
        "reasoning.usage": .init(
            required: ["turn_id": .uuid, "generation": .nonnegativeInteger],
            optional: [
                "input_tokens": .optionalNonnegativeInteger,
                "output_tokens": .optionalNonnegativeInteger,
            ]
        ),
        "reasoning.completed": .init(required: [
            "turn_id": .uuid, "generation": .nonnegativeInteger,
        ]),
        "reasoning.stopped": .init(required: [
            "turn_id": .uuid, "generation": .nonnegativeInteger,
        ]),
        "reasoning.failed": .init(required: [
            "turn_id": .uuid, "generation": .nonnegativeInteger,
            "error_code": .string,
        ]),
    ]

    private static func validate(
        _ value: JSONValue,
        as kind: FieldKind,
        field: String
    ) throws {
        switch (kind, value) {
        case (.string, .string),
             (.object, .object),
             (.objectArray, .array),
             (.modelChoices, .array),
             (.anyArray, .array),
             (.stringArray, .array),
             (.integerArray, .array):
            break
        case let (.uuid, .string(value)):
            guard isCanonicalV4UUID(value) else {
                throw GatewayProtocolError.invalidField
            }
        case let (.nonnegativeInteger, .integer(value)):
            guard value >= 0 else { throw GatewayProtocolError.invalidField }
        case let (.optionalNonnegativeInteger, .integer(value)):
            guard value >= 0 else { throw GatewayProtocolError.invalidField }
        case let (.readinessStatus, .string(value)):
            guard readinessStatuses.contains(value) else {
                throw GatewayProtocolError.invalidField
            }
        case (.optionalNonnegativeInteger, .null),
             (.nullableString, .null),
             (.nullableString, .string):
            break
        default:
            throw GatewayProtocolError.invalidField
        }
        if case .integerArray = kind,
           case let .array(values) = value,
           !values.allSatisfy({ $0.integerValue != nil })
        {
            throw GatewayProtocolError.invalidField
        }
        if case .stringArray = kind,
           case let .array(values) = value,
           !values.allSatisfy({ $0.stringValue != nil })
        {
            throw GatewayProtocolError.invalidField
        }
        if case .objectArray = kind,
           case let .array(values) = value,
           !values.allSatisfy({
               if case .object = $0 { return true }
               return false
           })
        {
            throw GatewayProtocolError.invalidField
        }
        if case .modelChoices = kind,
           case let .array(values) = value
        {
            for value in values {
                guard case let .object(choice) = value,
                      Set(choice.keys) == ["id", "name"],
                      choice["id"]?.stringValue != nil,
                      choice["name"]?.stringValue != nil
                else {
                    throw GatewayProtocolError.invalidField
                }
            }
        }
        if field == "text", case let .string(text) = value,
           text.unicodeScalars.count > 8_192
        {
            throw GatewayProtocolError.invalidField
        }
        if field == "user_text", case let .string(text) = value,
           text.unicodeScalars.count > 65_536
        {
            throw GatewayProtocolError.invalidField
        }
        if field == "provider_profile" {
            try validateProviderProfile(value)
        }
        if field == "context", case let .array(messages) = value {
            for message in messages {
                try validateContextMessage(message)
            }
        }
        if field == "supported_protocols",
           case let .array(versions) = value,
           !versions.contains(.integer(GatewayProtocol.version))
        {
            throw GatewayProtocolError.invalidField
        }
    }

    static let readinessStatuses: Set<String> = [
        "ready",
        "refresh_required",
        "authentication_required",
        "configuration_invalid",
        "network_unavailable",
        "provider_unavailable",
        "unsupported_model",
        "failed",
    ]

    static let providerKinds: Set<String> = [
        "codex_oauth",
        "openai_compatible",
        "fake",
    ]

    static let contextRoles: Set<String> = [
        "user",
        "assistant",
    ]

    static let enumAuthority: [String: Set<String>] = [
        "provider.readiness_result/status": readinessStatuses,
        "provider.readiness/provider_profile.kind": providerKinds,
        "reasoning.start/provider_profile.kind": providerKinds,
        "reasoning.start/context[].role": contextRoles,
    ]

    static func enumValues(
        recordType: String,
        propertyPath: String
    ) -> Set<String>? {
        enumAuthority["\(recordType)/\(propertyPath)"]
    }

    private static func validateProviderProfile(_ value: JSONValue) throws {
        guard case let .object(profile) = value,
              Set(profile.keys).isSubset(
                  of: ["kind", "base_url", "model", "credential_ref"]
              ),
              let kind = profile["kind"]?.stringValue,
              providerKinds.contains(kind),
              profile["model"]?.stringValue != nil,
              let credential = profile["credential_ref"]?.stringValue,
              isCanonicalV4UUID(credential)
        else {
            throw GatewayProtocolError.invalidField
        }
        if let baseURL = profile["base_url"],
           baseURL != .null,
           baseURL.stringValue == nil
        {
            throw GatewayProtocolError.invalidField
        }
    }

    private static func validateContextMessage(_ value: JSONValue) throws {
        guard case let .object(message) = value,
              Set(message.keys) == ["role", "text"],
              let role = message["role"]?.stringValue,
              contextRoles.contains(role),
              message["text"]?.stringValue != nil
        else {
            throw GatewayProtocolError.invalidField
        }
    }

    private static func rejectNUL(in value: JSONValue) throws {
        switch value {
        case let .string(value):
            if value.unicodeScalars.contains(where: { $0.value == 0 }) {
                throw GatewayProtocolError.invalidField
            }
        case let .array(values):
            for value in values { try rejectNUL(in: value) }
        case let .object(values):
            for (key, value) in values {
                try rejectNUL(in: .string(key))
                try rejectNUL(in: value)
            }
        case .integer, .bool, .null:
            break
        }
    }

    private static func isCanonicalV4UUID(_ value: String) -> Bool {
        guard value.count == 36, value == value.lowercased(),
              value[value.index(value.startIndex, offsetBy: 14)] == "4",
              "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]),
              let uuid = UUID(uuidString: value)
        else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }
}

public struct GatewaySessionValidator: Sendable {
    private struct RequestState: Sendable {
        enum Phase: Sendable {
            case awaitingAccepted
            case streaming
            case terminal
        }

        let turnID: String
        let generation: Int
        var nextOrdinal = 0
        var phase: Phase = .awaitingAccepted
    }

    public private(set) var sessionID: String?
    private var requests: [String: RequestState] = [:]

    public init() {}

    public mutating func register(
        requestID: String,
        turnID: String,
        generation: Int
    ) throws {
        guard sessionID != nil, requests[requestID] == nil, generation >= 0 else {
            throw GatewayProtocolError.invalidSequence
        }
        requests[requestID] = RequestState(
            turnID: turnID,
            generation: generation
        )
    }

    public mutating func accept(_ record: GatewayRecord) throws {
        if record.type == "gateway.ready" {
            guard sessionID == nil else {
                throw GatewayProtocolError.invalidSequence
            }
            sessionID = record.sessionID
            return
        }
        guard record.sessionID == sessionID, let requestID = record.requestID,
              var state = requests[requestID], state.phase != .terminal
        else {
            throw GatewayProtocolError.invalidSequence
        }
        let generation = record["generation"]?.integerValue
        guard generation == state.generation else {
            throw GatewayProtocolError.invalidSequence
        }
        if record.type.hasPrefix("auth.") {
            guard record["operation_id"]?.stringValue == state.turnID else {
                throw GatewayProtocolError.invalidSequence
            }
            switch record.type {
            case "auth.open_url", "auth.credential_candidate":
                state.phase = .streaming
            case "auth.completed", "auth.stopped", "auth.failed":
                state.phase = .terminal
            default:
                throw GatewayProtocolError.invalidSequence
            }
            requests[requestID] = state
            return
        }
        guard record["turn_id"]?.stringValue == state.turnID else {
            throw GatewayProtocolError.invalidSequence
        }
        switch record.type {
        case "reasoning.accepted":
            guard state.phase == .awaitingAccepted else {
                throw GatewayProtocolError.invalidSequence
            }
            state.phase = .streaming
        case "reasoning.text_delta":
            guard state.phase == .streaming else {
                throw GatewayProtocolError.invalidSequence
            }
            guard record["ordinal"]?.integerValue == state.nextOrdinal else {
                throw GatewayProtocolError.invalidSequence
            }
            state.nextOrdinal += 1
        case "reasoning.usage":
            guard state.phase == .streaming else {
                throw GatewayProtocolError.invalidSequence
            }
        case "reasoning.completed", "reasoning.stopped", "reasoning.failed":
            guard state.phase == .streaming else {
                throw GatewayProtocolError.invalidSequence
            }
            state.phase = .terminal
        default:
            throw GatewayProtocolError.invalidSequence
        }
        requests[requestID] = state
    }
}

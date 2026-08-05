import Foundation
import MillerCore

public enum CapabilityRPCError: Error, Equatable, Sendable {
    case invalidToken
    case frameTooLarge
    case malformedFrame
    case authenticationFailed
    case invalidRequestID
    case timedOut
    case peerDisconnected
    case unsafeRuntimeRoot
    case socketFailure
}

public enum CapabilityRPCEnvironment {
    public static let socketPath = "MILLER_CAPABILITY_RPC_SOCKET"
    public static let sessionToken = "MILLER_CAPABILITY_RPC_TOKEN"
    public static let providerProfileID = "MILLER_CAPABILITY_PROVIDER_PROFILE_ID"
}

public struct CapabilityRPCSessionToken: Equatable, Sendable {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 32 else { throw CapabilityRPCError.invalidToken }
        self.bytes = bytes
    }

    public static func random() -> Self {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return try! Self(bytes: bytes)
    }

    public init(environmentValue: String) throws {
        guard let data = Data(base64Encoded: environmentValue) else {
            throw CapabilityRPCError.invalidToken
        }
        try self.init(bytes: data)
    }

    public var environmentValue: String { bytes.base64EncodedString() }
}

public enum CapabilityRPCRequest: Codable, Equatable, Sendable {
    case list(providerProfileID: UUID)
    case call(
        CapabilityCallID,
        capabilityID: CapabilityID,
        argumentsJSON: Data
    )
    case cancel(CapabilityCallID)

    private enum Kind: String, Codable { case list, call, cancel }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, providerProfileID, callID, capabilityID, argumentsJSON
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyRPCKey.self)
        let kind = try container.decode(Kind.self, forKey: .init("kind"))
        let allowed: Set<String>
        switch kind {
        case .list:
            allowed = ["kind", "providerProfileID"]
            try Self.rejectUnknown(container, allowed: allowed)
            self = .list(providerProfileID: try container.decode(
                UUID.self, forKey: .init("providerProfileID")
            ))
        case .call:
            allowed = ["kind", "callID", "capabilityID", "argumentsJSON"]
            try Self.rejectUnknown(container, allowed: allowed)
            let arguments = try container.decode(
                Data.self, forKey: .init("argumentsJSON")
            )
            guard arguments.count <= 64 * 1_024,
                  let object = try? JSONSerialization.jsonObject(with: arguments),
                  object is [String: Any]
            else { throw CapabilityRPCError.malformedFrame }
            self = .call(
                try container.decode(CapabilityCallID.self, forKey: .init("callID")),
                capabilityID: try container.decode(
                    CapabilityID.self, forKey: .init("capabilityID")
                ),
                argumentsJSON: arguments
            )
        case .cancel:
            allowed = ["kind", "callID"]
            try Self.rejectUnknown(container, allowed: allowed)
            self = .cancel(try container.decode(
                CapabilityCallID.self, forKey: .init("callID")
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .list(let providerProfileID):
            try container.encode(Kind.list, forKey: .kind)
            try container.encode(providerProfileID, forKey: .providerProfileID)
        case .call(let callID, let capabilityID, let argumentsJSON):
            guard argumentsJSON.count <= 64 * 1_024,
                  let object = try? JSONSerialization.jsonObject(with: argumentsJSON),
                  object is [String: Any]
            else { throw CapabilityRPCError.malformedFrame }
            try container.encode(Kind.call, forKey: .kind)
            try container.encode(callID, forKey: .callID)
            try container.encode(capabilityID, forKey: .capabilityID)
            try container.encode(argumentsJSON, forKey: .argumentsJSON)
        case .cancel(let callID):
            try container.encode(Kind.cancel, forKey: .kind)
            try container.encode(callID, forKey: .callID)
        }
    }

    private static func rejectUnknown(
        _ container: KeyedDecodingContainer<AnyRPCKey>,
        allowed: Set<String>
    ) throws {
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw CapabilityRPCError.malformedFrame
        }
    }
}

public enum CapabilityRPCResponse: Codable, Equatable, Sendable {
    case catalog([CapabilityDescriptor])
    case result(CapabilityCallID, contentJSON: Data, isError: Bool)
    case failed(CapabilityCallID?, code: String)

    private enum Kind: String, Codable { case catalog, result, failed }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, descriptors, callID, contentJSON, isError, code
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyRPCKey.self)
        let kind = try container.decode(Kind.self, forKey: .init("kind"))
        switch kind {
        case .catalog:
            try Self.rejectUnknown(container, allowed: ["kind", "descriptors"])
            let descriptors = try container.decode(
                [CapabilityDescriptor].self, forKey: .init("descriptors")
            )
            guard descriptors.count <= 2_048 else {
                throw CapabilityRPCError.malformedFrame
            }
            self = .catalog(descriptors)
        case .result:
            try Self.rejectUnknown(
                container,
                allowed: ["kind", "callID", "contentJSON", "isError"]
            )
            let content = try container.decode(Data.self, forKey: .init("contentJSON"))
            guard content.count <= 256 * 1_024,
                  (try? JSONSerialization.jsonObject(with: content)) != nil
            else { throw CapabilityRPCError.malformedFrame }
            self = .result(
                try container.decode(CapabilityCallID.self, forKey: .init("callID")),
                contentJSON: content,
                isError: try container.decode(Bool.self, forKey: .init("isError"))
            )
        case .failed:
            try Self.rejectUnknown(container, allowed: ["kind", "callID", "code"])
            let code = try container.decode(String.self, forKey: .init("code"))
            guard Self.validFailureCode(code) else {
                throw CapabilityRPCError.malformedFrame
            }
            self = .failed(
                try container.decodeIfPresent(
                    CapabilityCallID.self, forKey: .init("callID")
                ),
                code: code
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .catalog(let descriptors):
            guard descriptors.count <= 2_048 else {
                throw CapabilityRPCError.malformedFrame
            }
            try container.encode(Kind.catalog, forKey: .kind)
            try container.encode(descriptors, forKey: .descriptors)
        case .result(let callID, let contentJSON, let isError):
            guard contentJSON.count <= 256 * 1_024,
                  (try? JSONSerialization.jsonObject(with: contentJSON)) != nil
            else { throw CapabilityRPCError.malformedFrame }
            try container.encode(Kind.result, forKey: .kind)
            try container.encode(callID, forKey: .callID)
            try container.encode(contentJSON, forKey: .contentJSON)
            try container.encode(isError, forKey: .isError)
        case .failed(let callID, let code):
            guard Self.validFailureCode(code) else {
                throw CapabilityRPCError.malformedFrame
            }
            try container.encode(Kind.failed, forKey: .kind)
            try container.encodeIfPresent(callID, forKey: .callID)
            try container.encode(code, forKey: .code)
        }
    }

    private static func validFailureCode(_ code: String) -> Bool {
        !code.isEmpty && code.utf8.count <= 64 && code.unicodeScalars.allSatisfy {
            $0.isASCII && (($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57) || $0 == "_")
        }
    }

    private static func rejectUnknown(
        _ container: KeyedDecodingContainer<AnyRPCKey>,
        allowed: Set<String>
    ) throws {
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw CapabilityRPCError.malformedFrame
        }
    }
}

public struct CapabilityRPCAuthenticationFrame: Codable, Equatable, Sendable {
    public let token: Data

    public init(token: CapabilityRPCSessionToken) { self.token = token.bytes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyRPCKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["token"] else {
            throw CapabilityRPCError.malformedFrame
        }
        let bytes = try container.decode(Data.self, forKey: .init("token"))
        self.token = try CapabilityRPCSessionToken(bytes: bytes).bytes
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyRPCKey.self)
        try container.encode(token, forKey: .init("token"))
    }
}

public struct CapabilityRPCRequestEnvelope: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let request: CapabilityRPCRequest

    public init(requestID: UUID, request: CapabilityRPCRequest) {
        self.requestID = requestID
        self.request = request
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyRPCKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["requestID", "request"] else {
            throw CapabilityRPCError.malformedFrame
        }
        requestID = try container.decode(UUID.self, forKey: .init("requestID"))
        request = try container.decode(
            CapabilityRPCRequest.self, forKey: .init("request")
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyRPCKey.self)
        try container.encode(requestID, forKey: .init("requestID"))
        try container.encode(request, forKey: .init("request"))
    }
}

public struct CapabilityRPCResponseEnvelope: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let response: CapabilityRPCResponse

    public init(requestID: UUID, response: CapabilityRPCResponse) {
        self.requestID = requestID
        self.response = response
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyRPCKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["requestID", "response"] else {
            throw CapabilityRPCError.malformedFrame
        }
        requestID = try container.decode(UUID.self, forKey: .init("requestID"))
        response = try container.decode(
            CapabilityRPCResponse.self, forKey: .init("response")
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyRPCKey.self)
        try container.encode(requestID, forKey: .init("requestID"))
        try container.encode(response, forKey: .init("response"))
    }
}

public enum CapabilityRPCCodec {
    public static let maximumFrameBytes = 1 * 1_024 * 1_024

    public static func encode<T: Encodable>(
        _ value: T,
        maximumFrameBytes: Int = maximumFrameBytes
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw error as? CapabilityRPCError ?? .malformedFrame }
        guard !data.isEmpty, data.count <= maximumFrameBytes,
              !data.contains(UInt8(ascii: "\n"))
        else { throw CapabilityRPCError.frameTooLarge }
        return data
    }

    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        maximumFrameBytes: Int = maximumFrameBytes
    ) throws -> T {
        guard !data.isEmpty, data.count <= maximumFrameBytes else {
            throw CapabilityRPCError.frameTooLarge
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw error as? CapabilityRPCError ?? .malformedFrame }
    }
}

private struct AnyRPCKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

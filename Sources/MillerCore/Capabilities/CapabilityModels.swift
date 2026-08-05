import Foundation

public enum CapabilityContractError: Error, Equatable, Sendable {
    case invalidCapabilityID
    case capabilityIDTooLarge
    case catalogTooLarge
    case voiceHistoryAttachmentTooLarge
    case capabilitySummaryTooLarge
}

public struct CapabilityID:
    Hashable, Codable, Sendable, CustomStringConvertible
{
    public let rawValue: String

    public var description: String { rawValue }

    public init(
        source: CapabilitySource,
        serverID: String,
        toolName: String
    ) throws {
        try self.init(
            rawValue: [source.rawValue, serverID, toolName]
                .joined(separator: "/")
        )
    }

    public init(rawValue: String) throws {
        let components = rawValue
            .split(separator: "/", omittingEmptySubsequences: false)
            .map {
                String($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
        guard components.count == 3,
              CapabilitySource(rawValue: components[0]) != nil,
              components.allSatisfy(Self.isValidComponent)
        else {
            throw CapabilityContractError.invalidCapabilityID
        }

        let normalized = components.joined(separator: "/")
        guard normalized.utf8.count <= 192 else {
            throw CapabilityContractError.capabilityIDTooLarge
        }
        self.rawValue = normalized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (33...126).contains($0.value)
                && $0 != "/"
                && !(65...90).contains($0.value)
        }
    }
}

public enum CapabilitySource: String, Codable, Sendable {
    case codexAccount = "codex_account"
    case millerMCP = "miller_mcp"
    case providerNative = "provider_native"
}

public enum CapabilityPolicy: String, Codable, Sendable, CaseIterable {
    case readOnlyAutomatic = "read_only_automatic"
    case askBeforeChanges = "ask_before_changes"
    case fullyTrusted = "fully_trusted"
}

public enum CapabilityTerminalOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case declined
    case cancelled
    case timedOut = "timed_out"
}

public struct CapabilityCallID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct CapabilityDescriptor: Codable, Equatable, Sendable {
    public let id: CapabilityID
    public let source: CapabilitySource
    public let serverID: String
    public let toolName: String
    public let displayName: String
    public let summary: String
    public let inputSchemaJSON: Data
    public let readOnlyHint: Bool?
    public let providerProfileIDs: Set<UUID>
    public let isAvailable: Bool

    public init(
        id: CapabilityID,
        source: CapabilitySource,
        serverID: String,
        toolName: String,
        displayName: String,
        summary: String,
        inputSchemaJSON: Data,
        readOnlyHint: Bool?,
        providerProfileIDs: Set<UUID>,
        isAvailable: Bool
    ) {
        self.id = id
        self.source = source
        self.serverID = serverID
        self.toolName = toolName
        self.displayName = displayName
        self.summary = summary
        self.inputSchemaJSON = inputSchemaJSON
        self.readOnlyHint = readOnlyHint
        self.providerProfileIDs = providerProfileIDs
        self.isAvailable = isAvailable
    }

    public func isAvailable(to providerProfileID: UUID) -> Bool {
        isAvailable && providerProfileIDs.contains(providerProfileID)
    }
}

public struct EffectiveCapabilityPolicy: Equatable, Sendable {
    public let value: CapabilityPolicy
    public let requiresApproval: Bool
    public let reason: String

    public init(
        value: CapabilityPolicy,
        requiresApproval: Bool,
        reason: String
    ) {
        self.value = value
        self.requiresApproval = requiresApproval
        self.reason = reason
    }
}

public struct CapabilityCatalogSnapshot: Codable, Equatable, Sendable {
    public static let empty = Self(unchecked: [])

    public let descriptors: [CapabilityDescriptor]

    public init(_ descriptors: [CapabilityDescriptor]) throws {
        guard descriptors.count <= 2_048 else {
            throw CapabilityContractError.catalogTooLarge
        }
        self.descriptors = descriptors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode([CapabilityDescriptor].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(descriptors)
    }

    private init(unchecked descriptors: [CapabilityDescriptor]) {
        self.descriptors = descriptors
    }
}

public struct VoiceHistoryAttachment: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) throws {
        guard text.utf8.count <= 32 * 1_024 else {
            throw CapabilityContractError.voiceHistoryAttachmentTooLarge
        }
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(text: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public struct CapabilitySummary: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) throws {
        guard text.utf8.count <= 1_024 else {
            throw CapabilityContractError.capabilitySummaryTooLarge
        }
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(text: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public enum CapabilityLifecycleState: String, Codable, Sendable {
    case started
    case awaitingApproval = "awaiting_approval"
    case running
    case terminal
}

public struct CapabilityLifecycleEvent: Equatable, Sendable {
    public let callID: CapabilityCallID
    public let capabilityID: CapabilityID
    public let summary: CapabilitySummary
    public let state: CapabilityLifecycleState
    public let outcome: CapabilityTerminalOutcome?
    public let policy: EffectiveCapabilityPolicy

    public init(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        summary: CapabilitySummary,
        state: CapabilityLifecycleState,
        outcome: CapabilityTerminalOutcome?,
        policy: EffectiveCapabilityPolicy
    ) {
        self.callID = callID
        self.capabilityID = capabilityID
        self.summary = summary
        self.state = state
        self.outcome = outcome
        self.policy = policy
    }
}

public enum CapabilityApprovalDecision:
    String, Codable, Equatable, Sendable, CaseIterable
{
    case allowOnce = "allow_once"
    case decline
}

public struct CapabilityApprovalRequest: Equatable, Sendable {
    public let callID: CapabilityCallID
    public let capabilityID: CapabilityID
    public let summary: CapabilitySummary
    public let policy: EffectiveCapabilityPolicy

    public init(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        summary: CapabilitySummary,
        policy: EffectiveCapabilityPolicy
    ) {
        self.callID = callID
        self.capabilityID = capabilityID
        self.summary = summary
        self.policy = policy
    }
}

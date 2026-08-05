import Foundation

public enum CapabilityContractError: Error, Equatable, Sendable {
    case invalidCapabilityID
    case capabilityIDTooLarge
    case catalogTooLarge
    case voiceHistoryAttachmentTooLarge
    case capabilitySummaryTooLarge
    case capabilityDescriptorIdentityMismatch
    case invalidEffectiveCapabilityPolicy
    case invalidCapabilityLifecycle
    case approvalNotRequired
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
        let identity = try Self.parse(rawValue)
        let normalized = [
            identity.source.rawValue,
            identity.serverID,
            identity.toolName,
        ].joined(separator: "/")
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

    fileprivate var identity: Identity? {
        try? Self.parse(rawValue)
    }

    fileprivate static func normalizeComponent(
        _ value: String
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({
                  (33...126).contains($0.value) && $0 != "/"
              })
        else {
            throw CapabilityContractError.invalidCapabilityID
        }
        return trimmed.lowercased()
    }

    private static func parse(_ rawValue: String) throws -> Identity {
        let components = rawValue.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else {
            throw CapabilityContractError.invalidCapabilityID
        }
        let sourceValue = try normalizeComponent(String(components[0]))
        guard let source = CapabilitySource(rawValue: sourceValue) else {
            throw CapabilityContractError.invalidCapabilityID
        }
        return Identity(
            source: source,
            serverID: try normalizeComponent(String(components[1])),
            toolName: try normalizeComponent(String(components[2]))
        )
    }

    fileprivate struct Identity {
        let source: CapabilitySource
        let serverID: String
        let toolName: String
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
    ) throws {
        let normalizedServerID = try CapabilityID.normalizeComponent(serverID)
        let normalizedToolName = try CapabilityID.normalizeComponent(toolName)
        guard let identity = id.identity,
              identity.source == source,
              identity.serverID == normalizedServerID,
              identity.toolName == normalizedToolName
        else {
            throw CapabilityContractError.capabilityDescriptorIdentityMismatch
        }
        self.id = id
        self.source = source
        self.serverID = normalizedServerID
        self.toolName = normalizedToolName
        self.displayName = displayName
        self.summary = summary
        self.inputSchemaJSON = inputSchemaJSON
        self.readOnlyHint = readOnlyHint
        self.providerProfileIDs = providerProfileIDs
        self.isAvailable = isAvailable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(CapabilityID.self, forKey: .id),
            source: container.decode(CapabilitySource.self, forKey: .source),
            serverID: container.decode(String.self, forKey: .serverID),
            toolName: container.decode(String.self, forKey: .toolName),
            displayName: container.decode(String.self, forKey: .displayName),
            summary: container.decode(String.self, forKey: .summary),
            inputSchemaJSON: container.decode(
                Data.self,
                forKey: .inputSchemaJSON
            ),
            readOnlyHint: container.decodeIfPresent(
                Bool.self,
                forKey: .readOnlyHint
            ),
            providerProfileIDs: container.decode(
                Set<UUID>.self,
                forKey: .providerProfileIDs
            ),
            isAvailable: container.decode(Bool.self, forKey: .isAvailable)
        )
    }

    public func isAvailable(to providerProfileID: UUID) -> Bool {
        isAvailable && providerProfileIDs.contains(providerProfileID)
    }
}

public enum CapabilityPolicyReason: String, Codable, Equatable, Sendable {
    case declaredReadOnly = "declared_read_only"
    case policyDisabled = "policy_disabled"
    case ownerApprovalRequired = "owner_approval_required"
    case fullyTrusted = "fully_trusted"
    case providerApprovalRequired = "provider_approval_required"

    fileprivate var requiresApproval: Bool {
        self == .ownerApprovalRequired || self == .providerApprovalRequired
    }

    fileprivate func supports(_ value: CapabilityPolicy) -> Bool {
        switch self {
        case .declaredReadOnly, .providerApprovalRequired:
            true
        case .policyDisabled:
            value == .readOnlyAutomatic
        case .ownerApprovalRequired:
            value == .askBeforeChanges
        case .fullyTrusted:
            value == .fullyTrusted
        }
    }
}

public struct EffectiveCapabilityPolicy: Codable, Equatable, Sendable {
    public let value: CapabilityPolicy
    public let requiresApproval: Bool
    public let reason: CapabilityPolicyReason

    init(
        value: CapabilityPolicy,
        reason: CapabilityPolicyReason
    ) {
        precondition(reason.supports(value))
        self.value = value
        self.requiresApproval = reason.requiresApproval
        self.reason = reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(CapabilityPolicy.self, forKey: .value)
        let requiresApproval = try container.decode(
            Bool.self,
            forKey: .requiresApproval
        )
        let reason = try container.decode(
            CapabilityPolicyReason.self,
            forKey: .reason
        )
        guard reason.supports(value),
              requiresApproval == reason.requiresApproval
        else {
            throw CapabilityContractError.invalidEffectiveCapabilityPolicy
        }
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

public struct CapabilityLifecycleEvent: Codable, Equatable, Sendable {
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
    ) throws {
        guard (state == .terminal) == (outcome != nil) else {
            throw CapabilityContractError.invalidCapabilityLifecycle
        }
        guard state != .awaitingApproval || policy.requiresApproval else {
            throw CapabilityContractError.approvalNotRequired
        }
        self.callID = callID
        self.capabilityID = capabilityID
        self.summary = summary
        self.state = state
        self.outcome = outcome
        self.policy = policy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            callID: container.decode(CapabilityCallID.self, forKey: .callID),
            capabilityID: container.decode(
                CapabilityID.self,
                forKey: .capabilityID
            ),
            summary: container.decode(CapabilitySummary.self, forKey: .summary),
            state: container.decode(
                CapabilityLifecycleState.self,
                forKey: .state
            ),
            outcome: container.decodeIfPresent(
                CapabilityTerminalOutcome.self,
                forKey: .outcome
            ),
            policy: container.decode(
                EffectiveCapabilityPolicy.self,
                forKey: .policy
            )
        )
    }
}

public enum CapabilityApprovalDecision:
    String, Codable, Equatable, Sendable, CaseIterable
{
    case allowOnce = "allow_once"
    case decline
}

public struct CapabilityApprovalRequest: Codable, Equatable, Sendable {
    public let callID: CapabilityCallID
    public let capabilityID: CapabilityID
    public let summary: CapabilitySummary
    public let policy: EffectiveCapabilityPolicy

    public init(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        summary: CapabilitySummary,
        policy: EffectiveCapabilityPolicy
    ) throws {
        guard policy.requiresApproval else {
            throw CapabilityContractError.approvalNotRequired
        }
        self.callID = callID
        self.capabilityID = capabilityID
        self.summary = summary
        self.policy = policy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            callID: container.decode(CapabilityCallID.self, forKey: .callID),
            capabilityID: container.decode(
                CapabilityID.self,
                forKey: .capabilityID
            ),
            summary: container.decode(CapabilitySummary.self, forKey: .summary),
            policy: container.decode(
                EffectiveCapabilityPolicy.self,
                forKey: .policy
            )
        )
    }
}

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
    case invalidPortableSkill
    case portableSkillAttachmentTooLarge
    case invalidTargetIdentity
    case bundleIdentifierTooLarge
    case invalidObservationIntent
    case observationIntentTooLarge
    case invalidDerivedObservationDescription
    case derivedObservationDescriptionTooLarge
    case invalidComputerText
    case computerTextTooLarge
    case invalidSemanticElementIdentifier
    case semanticElementIdentifierTooLarge
    case invalidKeyChord
    case keyChordTooLarge
    case invalidScrollDelta
    case invalidClickPoint
    case invalidComputerAction
}

public struct PortableSkillSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let pluginID: String?
    public let name: String
    public let description: String
    public let markdown: String
    public let sourceHash: String
    public let enabled: Bool

    public init(
        id: String,
        pluginID: String?,
        name: String,
        description: String,
        markdown: String,
        sourceHash: String,
        enabled: Bool = false
    ) {
        self.id = id
        self.pluginID = pluginID
        self.name = name
        self.description = description
        self.markdown = markdown
        self.sourceHash = sourceHash
        self.enabled = enabled
    }
}

public struct PortableSkillAttachment: Codable, Equatable, Sendable {
    public static let maximumBytes = 128 * 1_024

    public let skills: [PortableSkillSnapshot]
    public let omittedCount: Int

    public init(skills: [PortableSkillSnapshot], omittedCount: Int = 0) throws {
        guard skills.count <= 128, omittedCount >= 0,
              Set(skills.map(\.id)).count == skills.count,
              skills.allSatisfy(Self.valid)
        else {
            throw CapabilityContractError.invalidPortableSkill
        }
        let data = try JSONEncoder().encode(skills)
        guard data.count <= Self.maximumBytes else {
            throw CapabilityContractError.portableSkillAttachmentTooLarge
        }
        self.skills = skills
        self.omittedCount = omittedCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            skills: container.decode([PortableSkillSnapshot].self, forKey: .skills),
            omittedCount: container.decode(Int.self, forKey: .omittedCount)
        )
    }

    public var omissionNotice: String? {
        omittedCount == 0
            ? nil : "\(omittedCount) enabled skill(s) omitted to stay within the 128 KiB limit."
    }

    public var instructionText: String {
        var sections = skills.map {
            "Portable skill [\($0.id)] — \($0.name)\n\($0.description)\n\($0.markdown)"
        }
        if let omissionNotice { sections.append(omissionNotice) }
        return sections.joined(separator: "\n\n")
    }

    public func instructionText(maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var admitted: [String] = []
        for skill in skills {
            let section = "Portable skill [\(skill.id)] — \(skill.name)\n"
                + "\(skill.description)\n\(skill.markdown)"
            let candidate = (admitted + [section]).joined(separator: "\n\n")
            guard candidate.utf8.count <= maximumBytes else { break }
            admitted.append(section)
        }
        var omitted = omittedCount + skills.count - admitted.count
        while omitted > 0 {
            let notice = "\(omitted) enabled skill(s) omitted to stay within the session limit."
            let candidate = (admitted + [notice]).joined(separator: "\n\n")
            if candidate.utf8.count <= maximumBytes { return candidate }
            guard !admitted.isEmpty else {
                return notice.utf8.count <= maximumBytes ? notice : ""
            }
            admitted.removeLast()
            omitted += 1
        }
        return admitted.joined(separator: "\n\n")
    }

    private static func valid(_ skill: PortableSkillSnapshot) -> Bool {
        func safeID(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 96 && value.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic
                    || (48...57).contains($0.value) || $0 == "-" || $0 == "_" || $0 == ".")
            }
        }
        return safeID(skill.id)
            && skill.pluginID.map(safeID) != false
            && !skill.name.isEmpty && skill.name.utf8.count <= 256
            && !skill.description.isEmpty && skill.description.utf8.count <= 1_024
            && skill.markdown.utf8.count <= 64 * 1_024
            && skill.sourceHash.utf8.count <= 128
            && !skill.name.contains("\0") && !skill.description.contains("\0")
            && !skill.markdown.contains("\0")
    }
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
        if source == .millerSystem {
            let normalizedServerID = try Self.normalizeComponent(serverID)
            let normalizedToolName = try Self.normalizeComponent(toolName)
            guard normalizedServerID == "system",
                  let capability = MillerSystemCapability(
                      rawValue: "miller.system.\(normalizedToolName)"
                  )
            else {
                throw CapabilityContractError.invalidCapabilityID
            }
            try self.init(rawValue: capability.rawValue)
            return
        }
        try self.init(
            rawValue: [source.rawValue, serverID, toolName]
                .joined(separator: "/")
        )
    }

    public init(rawValue: String) throws {
        let normalizedRawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let capability = MillerSystemCapability(rawValue: normalizedRawValue) {
            self.rawValue = capability.rawValue
            return
        }
        if normalizedRawValue.hasPrefix("miller.system.") {
            throw CapabilityContractError.invalidCapabilityID
        }
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

    public init(millerSystem capability: MillerSystemCapability) {
        self.rawValue = capability.rawValue
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
        let normalizedRawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let capability = MillerSystemCapability(rawValue: normalizedRawValue) {
            return Identity(
                source: .millerSystem,
                serverID: "system",
                toolName: capability.shortName
            )
        }
        if normalizedRawValue.hasPrefix("miller.system.") {
            throw CapabilityContractError.invalidCapabilityID
        }
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
        guard source != .millerSystem else {
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
    case millerSystem = "miller_system"
}

public enum CapabilityVisibility: String, Codable, Sendable {
    case ownerManaged = "owner_managed"
    case providerManaged = "provider_managed"
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
    case uncertain
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
    public let isAccessible: Bool
    public let isEnabled: Bool
    public let isCallable: Bool
    public let visibility: CapabilityVisibility

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
        isAvailable: Bool,
        isAccessible: Bool = true,
        isEnabled: Bool = true,
        isCallable: Bool = true,
        visibility: CapabilityVisibility = .ownerManaged
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
        self.isAccessible = isAccessible
        self.isEnabled = isEnabled
        self.isCallable = isCallable
        self.visibility = visibility
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
            isAvailable: container.decode(Bool.self, forKey: .isAvailable),
            isAccessible: try container.decodeIfPresent(
                Bool.self, forKey: .isAccessible
            ) ?? true,
            isEnabled: try container.decodeIfPresent(
                Bool.self, forKey: .isEnabled
            ) ?? true,
            isCallable: try container.decodeIfPresent(
                Bool.self, forKey: .isCallable
            ) ?? true,
            visibility: try container.decodeIfPresent(
                CapabilityVisibility.self, forKey: .visibility
            ) ?? .ownerManaged
        )
    }

    public func isAvailable(to providerProfileID: UUID) -> Bool {
        isAvailable && isAccessible && isEnabled && isCallable
            && providerProfileIDs.contains(providerProfileID)
    }

    public var bridgeProjectedToolName: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let suffix = toolName.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII,
               scalar.properties.isAlphabetic
                    || (48...57).contains(scalar.value)
                    || scalar == "_"
                    || scalar == "-"
            {
                return Character(String(scalar))
            }
            return "_"
        }
        return "miller_\(String(hash, radix: 16))_\(String(suffix).prefix(72))"
    }
}

enum CapabilityPolicyReason: String, Sendable {
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
    public let reason: String

    init(
        value: CapabilityPolicy,
        reason: CapabilityPolicyReason
    ) {
        precondition(reason.supports(value))
        self.value = value
        self.requiresApproval = reason.requiresApproval
        self.reason = reason.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(CapabilityPolicy.self, forKey: .value)
        let requiresApproval = try container.decode(
            Bool.self,
            forKey: .requiresApproval
        )
        let reason = try container.decode(String.self, forKey: .reason)
        guard reason.utf8.count <= 64,
              let reasonCode = CapabilityPolicyReason(rawValue: reason),
              reasonCode.supports(value),
              requiresApproval == reasonCode.requiresApproval
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

public enum CapabilityPolicyDecision: Equatable, Sendable {
    case executeAutomatically
    case requestApproval
    case decline
}

public struct CapabilityPolicyResolution: Equatable, Sendable {
    public let effectivePolicy: EffectiveCapabilityPolicy
    public let decision: CapabilityPolicyDecision

    public init(
        effectivePolicy: EffectiveCapabilityPolicy,
        decision: CapabilityPolicyDecision
    ) {
        self.effectivePolicy = effectivePolicy
        self.decision = decision
    }
}

public struct CapabilityPolicyResolver: Sendable {
    public init() {}

    public func resolve(
        serverPolicy: CapabilityPolicy,
        toolOverride: CapabilityPolicy? = nil,
        readOnlyHint: Bool?,
        mandatoryProviderApproval: Bool = false
    ) -> CapabilityPolicyResolution {
        let value = toolOverride ?? serverPolicy

        if readOnlyHint != true && value == .readOnlyAutomatic {
            return resolution(
                value: value,
                requiresApproval: false,
                reason: "policy_disabled",
                decision: .decline
            )
        }

        if mandatoryProviderApproval {
            return resolution(
                value: value,
                requiresApproval: true,
                reason: "provider_approval_required",
                decision: .requestApproval
            )
        }

        if readOnlyHint == true {
            return resolution(
                value: value,
                requiresApproval: false,
                reason: "declared_read_only",
                decision: .executeAutomatically
            )
        }

        switch value {
        case .readOnlyAutomatic:
            return resolution(
                value: value,
                requiresApproval: false,
                reason: "policy_disabled",
                decision: .decline
            )
        case .askBeforeChanges:
            return resolution(
                value: value,
                requiresApproval: true,
                reason: "owner_approval_required",
                decision: .requestApproval
            )
        case .fullyTrusted:
            return resolution(
                value: value,
                requiresApproval: false,
                reason: "fully_trusted",
                decision: .executeAutomatically
            )
        }
    }

    private func resolution(
        value: CapabilityPolicy,
        requiresApproval: Bool,
        reason: String,
        decision: CapabilityPolicyDecision
    ) -> CapabilityPolicyResolution {
        CapabilityPolicyResolution(
            effectivePolicy: EffectiveCapabilityPolicy(
                value: value,
                requiresApproval: requiresApproval,
                reason: reason
            ),
            decision: decision
        )
    }
}

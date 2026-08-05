public enum CapabilityPolicyDecision: Equatable, Sendable {
    case executeAutomatically
    case requestApproval
    case decline
}

public struct CapabilityPolicyResolution: Equatable, Sendable {
    public let effectivePolicy: EffectiveCapabilityPolicy
    public let decision: CapabilityPolicyDecision

    fileprivate init(
        effectivePolicy: EffectiveCapabilityPolicy,
        reason: CapabilityPolicyReason
    ) {
        self.effectivePolicy = effectivePolicy
        if reason == .policyDisabled {
            decision = .decline
        } else if effectivePolicy.requiresApproval {
            decision = .requestApproval
        } else {
            decision = .executeAutomatically
        }
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
                reason: .policyDisabled
            )
        }

        if mandatoryProviderApproval {
            return resolution(
                value: value,
                reason: .providerApprovalRequired
            )
        }

        if readOnlyHint == true {
            return resolution(
                value: value,
                reason: .declaredReadOnly
            )
        }

        switch value {
        case .readOnlyAutomatic:
            return resolution(
                value: value,
                reason: .policyDisabled
            )
        case .askBeforeChanges:
            return resolution(
                value: value,
                reason: .ownerApprovalRequired
            )
        case .fullyTrusted:
            return resolution(
                value: value,
                reason: .fullyTrusted
            )
        }
    }

    private func resolution(
        value: CapabilityPolicy,
        reason: CapabilityPolicyReason
    ) -> CapabilityPolicyResolution {
        let effectivePolicy = EffectiveCapabilityPolicy(
            value: value,
            reason: reason
        )
        return CapabilityPolicyResolution(
            effectivePolicy: effectivePolicy,
            reason: reason
        )
    }
}

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

    public func resolveFirstParty(
        _ request: FirstPartyCapabilityAdmissionRequest
    ) -> FirstPartyCapabilityResolution {
        guard request.featureEnabled else {
            return declined(.featureDisabled)
        }

        switch request.context {
        case .local:
            if request.capability == .computerAct,
               !request.localComputerControlEnabled
            {
                return declined(.featureDisabled)
            }
        case .remote(let admission):
            guard admission.settingEnabled,
                  admission.ownerAdmitted,
                  admission.sessionAdmitted
            else {
                return declined(.remoteAdmissionMissing)
            }
        }

        guard request.macOSPermissionGranted else {
            return declined(.macOSPermissionMissing)
        }
        guard request.imageInputAuthorityAvailable else {
            return declined(.imageInputAuthorityMissing)
        }
        guard request.targetGenerationCurrent,
              request.observationGenerationCurrent
        else {
            return declined(.staleGeneration)
        }
        guard request.executableBackendAvailable else {
            return declined(.noExecutableBackend)
        }

        let actionClass = request.admittedAction?.actionClass
        let requiresAllowOnce: Bool
        switch actionClass {
        case .sensitive, .unclassified:
            requiresAllowOnce = true
        case .safeNavigation, .reversibleEdit:
            requiresAllowOnce = false
        case nil:
            requiresAllowOnce = request.capability == .computerAct
        }
        let policyResolution: CapabilityPolicyResolution

        if request.capability == .screenObserve {
            policyResolution = resolve(
                serverPolicy: request.ownerPolicy,
                readOnlyHint: true
            )
        } else {
            policyResolution = resolve(
                serverPolicy: request.ownerPolicy,
                readOnlyHint: requiresAllowOnce ? true : false,
                mandatoryProviderApproval: requiresAllowOnce
            )
        }

        switch policyResolution.decision {
        case .decline:
            return FirstPartyCapabilityResolution(
                decision: .decline(.ownerPolicyDisabled),
                declineReason: .ownerPolicyDisabled,
                policyResolution: policyResolution,
                requiresAllowOnce: false
            )
        case .requestApproval:
            return FirstPartyCapabilityResolution(
                decision: requiresAllowOnce
                    ? .requestAllowOnce
                    : .requestOwnerApproval,
                declineReason: nil,
                policyResolution: policyResolution,
                requiresAllowOnce: requiresAllowOnce
            )
        case .executeAutomatically:
            return FirstPartyCapabilityResolution(
                decision: .executeAutomatically,
                declineReason: nil,
                policyResolution: policyResolution,
                requiresAllowOnce: requiresAllowOnce
            )
        }
    }

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

    private func declined(
        _ reason: FirstPartyCapabilityDeclineReason
    ) -> FirstPartyCapabilityResolution {
        FirstPartyCapabilityResolution(
            decision: .decline(reason),
            declineReason: reason,
            policyResolution: nil,
            requiresAllowOnce: false
        )
    }
}

public struct RemoteFirstPartyAdmission: Equatable, Sendable {
    public let settingEnabled: Bool
    public let ownerAdmitted: Bool
    public let sessionAdmitted: Bool

    public init(
        settingEnabled: Bool,
        ownerAdmitted: Bool,
        sessionAdmitted: Bool
    ) {
        self.settingEnabled = settingEnabled
        self.ownerAdmitted = ownerAdmitted
        self.sessionAdmitted = sessionAdmitted
    }
}

public enum FirstPartyCapabilityContext: Equatable, Sendable {
    case local
    case remote(RemoteFirstPartyAdmission)
}

public struct FirstPartyCapabilityAdmissionRequest: Equatable, Sendable {
    public let capability: MillerSystemCapability
    public let context: FirstPartyCapabilityContext
    public let featureEnabled: Bool
    public let localComputerControlEnabled: Bool
    public let macOSPermissionGranted: Bool
    public let imageInputAuthorityAvailable: Bool
    public let targetGenerationCurrent: Bool
    public let observationGenerationCurrent: Bool
    public let executableBackendAvailable: Bool
    public let ownerPolicy: CapabilityPolicy
    public let admittedAction: MillerAdmittedComputerAction?

    public init(
        capability: MillerSystemCapability,
        context: FirstPartyCapabilityContext,
        featureEnabled: Bool,
        localComputerControlEnabled: Bool,
        macOSPermissionGranted: Bool,
        imageInputAuthorityAvailable: Bool,
        targetGenerationCurrent: Bool,
        observationGenerationCurrent: Bool,
        executableBackendAvailable: Bool,
        ownerPolicy: CapabilityPolicy,
        admittedAction: MillerAdmittedComputerAction? = nil
    ) {
        self.capability = capability
        self.context = context
        self.featureEnabled = featureEnabled
        self.localComputerControlEnabled = localComputerControlEnabled
        self.macOSPermissionGranted = macOSPermissionGranted
        self.imageInputAuthorityAvailable = imageInputAuthorityAvailable
        self.targetGenerationCurrent = targetGenerationCurrent
        self.observationGenerationCurrent = observationGenerationCurrent
        self.executableBackendAvailable = executableBackendAvailable
        self.ownerPolicy = ownerPolicy
        self.admittedAction = admittedAction
    }
}

public enum FirstPartyCapabilityDeclineReason: Equatable, Sendable {
    case featureDisabled
    case remoteAdmissionMissing
    case macOSPermissionMissing
    case imageInputAuthorityMissing
    case staleGeneration
    case noExecutableBackend
    case ownerPolicyDisabled
}

public enum FirstPartyCapabilityDecision: Equatable, Sendable {
    case executeAutomatically
    case requestOwnerApproval
    case requestAllowOnce
    case decline(FirstPartyCapabilityDeclineReason)
}

public struct FirstPartyCapabilityResolution: Equatable, Sendable {
    public let decision: FirstPartyCapabilityDecision
    public let declineReason: FirstPartyCapabilityDeclineReason?
    public let policyResolution: CapabilityPolicyResolution?
    public let requiresAllowOnce: Bool

    fileprivate init(
        decision: FirstPartyCapabilityDecision,
        declineReason: FirstPartyCapabilityDeclineReason?,
        policyResolution: CapabilityPolicyResolution?,
        requiresAllowOnce: Bool
    ) {
        self.decision = decision
        self.declineReason = declineReason
        self.policyResolution = policyResolution
        self.requiresAllowOnce = requiresAllowOnce
    }
}

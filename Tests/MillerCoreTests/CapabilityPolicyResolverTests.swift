@testable import MillerCore
import Testing

@Suite
struct CapabilityPolicyResolverTests {
    private let resolver = CapabilityPolicyResolver()

    @Test
    func firstPartyAdmissionUsesTheRequiredDeclinePrecedence() throws {
        let resolution = resolver.resolveFirstParty(
            firstPartyRequest(
                featureEnabled: false,
                context: .remote(
                    RemoteFirstPartyAdmission(
                        settingEnabled: false,
                        ownerAdmitted: false,
                        sessionAdmitted: false
                    )
                ),
                macOSPermissionGranted: false,
                imageInputAuthorityAvailable: false,
                targetGenerationCurrent: false,
                observationGenerationCurrent: false,
                executableBackendAvailable: false
            )
        )

        #expect(resolution.decision == .decline(.featureDisabled))
        #expect(resolution.declineReason == .featureDisabled)
    }

    @Test
    func firstPartyAdmissionKeepsRemoteRequirementsOutOfLocalSessions() throws {
        let local = resolver.resolveFirstParty(
            firstPartyRequest(context: .local)
        )
        #expect(local.declineReason == nil)

        let remote = resolver.resolveFirstParty(
            firstPartyRequest(
                context: .remote(
                    RemoteFirstPartyAdmission(
                        settingEnabled: false,
                        ownerAdmitted: true,
                        sessionAdmitted: true
                    )
                )
            )
        )
        #expect(remote.declineReason == .remoteAdmissionMissing)
    }

    @Test(arguments: [
        ("permission", FirstPartyCapabilityDeclineReason.macOSPermissionMissing),
        ("image", FirstPartyCapabilityDeclineReason.imageInputAuthorityMissing),
        ("generation", FirstPartyCapabilityDeclineReason.staleGeneration),
        ("backend", FirstPartyCapabilityDeclineReason.noExecutableBackend),
    ])
    func firstPartyAdmissionExposesTypedReasonsInOrder(
        _ scenario: (String, FirstPartyCapabilityDeclineReason)
    ) throws {
        let request: FirstPartyCapabilityAdmissionRequest
        switch scenario.0 {
        case "permission":
            request = firstPartyRequest(macOSPermissionGranted: false)
        case "image":
            request = firstPartyRequest(imageInputAuthorityAvailable: false)
        case "generation":
            request = firstPartyRequest(targetGenerationCurrent: false)
        case "backend":
            request = firstPartyRequest(executableBackendAvailable: false)
        default:
            Issue.record("unknown test scenario")
            return
        }

        let resolution = resolver.resolveFirstParty(request)
        #expect(resolution.declineReason == scenario.1)
        #expect(resolution.decision == .decline(scenario.1))
    }

    @Test
    func firstPartySensitiveAndUnclassifiedActionsAlwaysRequireAllowOnce() throws {
        let sensitive = resolver.resolveFirstParty(
            firstPartyRequest(
                ownerPolicy: .fullyTrusted,
                actionClass: .sensitive
            )
        )
        #expect(sensitive.decision == .requestAllowOnce)
        #expect(sensitive.requiresAllowOnce)
        #expect(
            sensitive.policyResolution?.effectivePolicy.reason
                == "provider_approval_required"
        )

        let unclassified = resolver.resolveFirstParty(
            firstPartyRequest(ownerPolicy: .fullyTrusted, actionClass: nil)
        )
        #expect(unclassified.decision == .requestAllowOnce)
        #expect(unclassified.requiresAllowOnce)

        let explicitlyUnclassified = resolver.resolveFirstParty(
            firstPartyRequest(
                ownerPolicy: .fullyTrusted,
                actionClass: .unclassified
            )
        )
        #expect(explicitlyUnclassified.decision == .requestAllowOnce)
        #expect(explicitlyUnclassified.requiresAllowOnce)
    }

    @Test
    func firstPartySafeActionsUseTheExistingOwnerPolicy() throws {
        let automatic = resolver.resolveFirstParty(
            firstPartyRequest(
                ownerPolicy: .fullyTrusted,
                actionClass: .safeNavigation
            )
        )
        #expect(automatic.decision == .executeAutomatically)
        #expect(!automatic.requiresAllowOnce)
        #expect(
            automatic.policyResolution?.effectivePolicy.reason == "fully_trusted"
        )

        let approval = resolver.resolveFirstParty(
            firstPartyRequest(
                ownerPolicy: .askBeforeChanges,
                actionClass: .reversibleEdit
            )
        )
        #expect(approval.decision == .requestOwnerApproval)
        #expect(!approval.requiresAllowOnce)

        let disabled = resolver.resolveFirstParty(
            firstPartyRequest(
                ownerPolicy: .readOnlyAutomatic,
                actionClass: .safeNavigation
            )
        )
        #expect(disabled.decision == .decline(.ownerPolicyDisabled))
    }

    @Test
    func serverPolicyIsInheritedWithoutAToolOverride() {
        let resolution = resolver.resolve(
            serverPolicy: .askBeforeChanges,
            toolOverride: nil,
            readOnlyHint: false
        )

        #expect(resolution.effectivePolicy.value == .askBeforeChanges)
        #expect(resolution.decision == .requestApproval)
        #expect(resolution.effectivePolicy.requiresApproval)
    }

    @Test
    func perToolPolicyOverridesTheServerDefault() {
        let resolution = resolver.resolve(
            serverPolicy: .readOnlyAutomatic,
            toolOverride: .fullyTrusted,
            readOnlyHint: false
        )

        #expect(resolution.effectivePolicy.value == .fullyTrusted)
        #expect(resolution.decision == .executeAutomatically)
        #expect(!resolution.effectivePolicy.requiresApproval)
    }

    @Test(arguments: [false, nil] as [Bool?])
    func unknownOrChangingCallsAreDeclinedByReadOnlyAutomatic(
        readOnlyHint: Bool?
    ) {
        let resolution = resolver.resolve(
            serverPolicy: .readOnlyAutomatic,
            readOnlyHint: readOnlyHint
        )

        #expect(resolution.decision == .decline)
        #expect(!resolution.effectivePolicy.requiresApproval)
        #expect(resolution.effectivePolicy.reason == "policy_disabled")
    }

    @Test(arguments: [false, nil] as [Bool?])
    func unknownOrChangingCallsPromptUnderAskBeforeChanges(
        readOnlyHint: Bool?
    ) {
        let resolution = resolver.resolve(
            serverPolicy: .askBeforeChanges,
            readOnlyHint: readOnlyHint
        )

        #expect(resolution.decision == .requestApproval)
        #expect(resolution.effectivePolicy.requiresApproval)
        #expect(resolution.effectivePolicy.reason == "owner_approval_required")
    }

    @Test(arguments: [false, nil] as [Bool?])
    func unknownOrChangingCallsExecuteUnderFullyTrusted(
        readOnlyHint: Bool?
    ) {
        let resolution = resolver.resolve(
            serverPolicy: .fullyTrusted,
            readOnlyHint: readOnlyHint
        )

        #expect(resolution.decision == .executeAutomatically)
        #expect(!resolution.effectivePolicy.requiresApproval)
        #expect(resolution.effectivePolicy.reason == "fully_trusted")
    }

    @Test(arguments: CapabilityPolicy.allCases)
    func declaredReadOnlyCallsExecuteUnderEveryOwnerPolicy(
        policy: CapabilityPolicy
    ) {
        let resolution = resolver.resolve(
            serverPolicy: policy,
            readOnlyHint: true
        )

        #expect(resolution.decision == .executeAutomatically)
        #expect(!resolution.effectivePolicy.requiresApproval)
        #expect(resolution.effectivePolicy.reason == "declared_read_only")
    }

    @Test(arguments: CapabilityPolicy.allCases)
    func mandatoryProviderApprovalCannotBeWeakened(
        policy: CapabilityPolicy
    ) {
        let resolution = resolver.resolve(
            serverPolicy: .readOnlyAutomatic,
            toolOverride: policy,
            readOnlyHint: true,
            mandatoryProviderApproval: true
        )

        #expect(resolution.effectivePolicy.value == policy)
        #expect(resolution.decision == .requestApproval)
        #expect(resolution.effectivePolicy.requiresApproval)
        #expect(resolution.effectivePolicy.reason == "provider_approval_required")
    }

    @Test(arguments: [false, nil] as [Bool?])
    func mandatoryProviderApprovalDoesNotWeakenALocalPolicyDenial(
        readOnlyHint: Bool?
    ) {
        let resolution = resolver.resolve(
            serverPolicy: .readOnlyAutomatic,
            readOnlyHint: readOnlyHint,
            mandatoryProviderApproval: true
        )

        #expect(resolution.decision == .decline)
        #expect(!resolution.effectivePolicy.requiresApproval)
        #expect(resolution.effectivePolicy.reason == "policy_disabled")
    }
}

private func firstPartyRequest(
    featureEnabled: Bool = true,
    localComputerControlEnabled: Bool = true,
    context: FirstPartyCapabilityContext = .local,
    macOSPermissionGranted: Bool = true,
    imageInputAuthorityAvailable: Bool = true,
    targetGenerationCurrent: Bool = true,
    observationGenerationCurrent: Bool = true,
    executableBackendAvailable: Bool = true,
    ownerPolicy: CapabilityPolicy = .askBeforeChanges,
    actionClass: ComputerActionClass? = .safeNavigation
) -> FirstPartyCapabilityAdmissionRequest {
    let target = try! TargetIdentity(
        processID: 1,
        windowID: 1,
        bundleIdentifier: "com.example.App"
    )
    let action = ComputerAction.focusWindow(FocusWindowAction(target: target))
    let admittedAction = actionClass.map {
        MillerAdmittedComputerAction(
            action: action,
            actionClass: $0,
            verificationPredicate: .targetActivated
        )
    }
    return FirstPartyCapabilityAdmissionRequest(
        capability: .computerAct,
        context: context,
        featureEnabled: featureEnabled,
        localComputerControlEnabled: localComputerControlEnabled,
        macOSPermissionGranted: macOSPermissionGranted,
        imageInputAuthorityAvailable: imageInputAuthorityAvailable,
        targetGenerationCurrent: targetGenerationCurrent,
        observationGenerationCurrent: observationGenerationCurrent,
        executableBackendAvailable: executableBackendAvailable,
        ownerPolicy: ownerPolicy,
        admittedAction: admittedAction
    )
}

@testable import MillerCore
import Testing

@Suite
struct CapabilityPolicyResolverTests {
    private let resolver = CapabilityPolicyResolver()

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

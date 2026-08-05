public actor CapabilityRegistry {
    private var values: [MillerCapability: CapabilityReadiness]

    public init() {
        values = Dictionary(
            uniqueKeysWithValues: MillerCapability.allCases.map {
                (
                    $0,
                    CapabilityReadiness(capability: $0, status: .unavailable)
                )
            }
        )
    }

    public func update(_ readiness: CapabilityReadiness) {
        values[readiness.capability] = readiness
    }

    public func readiness(
        for capability: MillerCapability
    ) -> CapabilityReadiness {
        values[capability]
            ?? CapabilityReadiness(
                capability: capability,
                status: .unavailable
            )
    }

    public var snapshot: [CapabilityReadiness] {
        MillerCapability.allCases.map(readiness(for:))
    }

    public var isTextReady: Bool {
        MillerCapability.allCases
            .filter(\.isRequiredForText)
            .allSatisfy { readiness(for: $0).status == .ready }
    }
}

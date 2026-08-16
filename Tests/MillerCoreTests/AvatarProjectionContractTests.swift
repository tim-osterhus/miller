import CoreFoundation
import Foundation
@testable import MillerCore
import Testing

@Suite
struct AvatarProjectionContractTests {
    private let generationA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let generationB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let playbackP = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let playbackQ = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let maximumSafeInteger: UInt64 = 9_007_199_254_740_991

    @Test
    func vocabularyIsClosed() {
        #expect(AvatarVisibility.allCases == [.visible, .occluded, .hidden])
        #expect(AvatarPresentationPhase.allCases == [
            .idle, .listening, .transcribing, .thinking, .responding,
            .speaking, .succeeded, .stopped, .failed,
        ])
    }

    @Test
    func phaseIdentityRulesAreValidatedAtConstruction() throws {
        let valid: [(AvatarPresentationPhase, UUID?, UUID?)] = [
            (.idle, nil, nil),
            (.listening, nil, nil),
            (.transcribing, nil, nil),
            (.thinking, generationA, nil),
            (.responding, generationA, nil),
            (.speaking, generationA, playbackP),
            (.succeeded, generationA, nil),
            (.stopped, generationA, nil),
            (.failed, generationA, nil),
        ]

        for (phase, generationID, playbackID) in valid {
            #expect(
                (try? projection(
                    phase: phase,
                    generationID: generationID,
                    playbackID: playbackID
                )) != nil
            )
        }

        #expect(throws: AvatarProjectionError.invalidPhaseIdentity) {
            try projection(phase: .idle, generationID: generationA)
        }
        #expect(throws: AvatarProjectionError.invalidPhaseIdentity) {
            try projection(phase: .listening, playbackID: playbackP)
        }
        #expect(throws: AvatarProjectionError.invalidPhaseIdentity) {
            try projection(phase: .thinking, generationID: generationA, playbackID: playbackP)
        }
        #expect(throws: AvatarProjectionError.invalidPhaseIdentity) {
            try projection(phase: .succeeded, generationID: nil)
        }
        #expect(throws: AvatarProjectionError.invalidPhaseIdentity) {
            try projection(phase: .speaking, generationID: generationA)
        }
    }

    @Test
    func countersArePositiveAndJavaScriptSafe() throws {
        #expect(
            try projection(
                sequence: maximumSafeInteger,
                phase: .idle
            ).projectionSequence == maximumSafeInteger
        )
        #expect(throws: AvatarProjectionError.invalidProjectionSequence) {
            try projection(sequence: 0, phase: .idle)
        }
        #expect(throws: AvatarProjectionError.unsafeInteger) {
            try projection(sequence: maximumSafeInteger + 1, phase: .idle)
        }

        let cue = try AvatarMouthCue(
            generationID: generationA,
            playbackID: playbackP,
            cueIndex: maximumSafeInteger,
            playbackOffsetMilliseconds: maximumSafeInteger,
            envelope: 0.5
        )
        #expect(cue.cueIndex == maximumSafeInteger)
        #expect(cue.playbackOffsetMilliseconds == maximumSafeInteger)

        #expect(throws: AvatarProjectionError.invalidCueIndex) {
            try AvatarMouthCue(
                generationID: generationA,
                playbackID: playbackP,
                cueIndex: 0,
                playbackOffsetMilliseconds: 0,
                envelope: 0.5
            )
        }
        #expect(throws: AvatarProjectionError.unsafeInteger) {
            try AvatarMouthCue(
                generationID: generationA,
                playbackID: playbackP,
                cueIndex: maximumSafeInteger + 1,
                playbackOffsetMilliseconds: 0,
                envelope: 0.5
            )
        }
        #expect(throws: AvatarProjectionError.unsafeInteger) {
            try AvatarMouthCue(
                generationID: generationA,
                playbackID: playbackP,
                cueIndex: 1,
                playbackOffsetMilliseconds: maximumSafeInteger + 1,
                envelope: 0.5
            )
        }
    }

    @Test
    func envelopeIsBoundedAndNonFiniteValuesAreRejected() throws {
        let high = try cue(envelope: 2)
        let low = try cue(envelope: -1)
        #expect(high.envelope == 1)
        #expect(low.envelope == 0)

        #expect(throws: AvatarProjectionError.nonFiniteEnvelope) {
            try cue(envelope: .nan)
        }
        #expect(throws: AvatarProjectionError.nonFiniteEnvelope) {
            try cue(envelope: .infinity)
        }
        #expect(throws: AvatarProjectionError.nonFiniteEnvelope) {
            try cue(envelope: -.infinity)
        }
    }

    @Test
    func mouthCueRequiresAnActiveVisibleUnreducedMatchingLease() throws {
        let cue = try cue()
        let admitted = try projection(
            phase: .speaking,
            generationID: generationA,
            playbackID: playbackP,
            mouthCue: cue
        )
        #expect(admitted.mouthCue == cue)

        for visibility in [AvatarVisibility.occluded, .hidden] {
            #expect(throws: AvatarProjectionError.mouthCueNotAdmitted) {
                try projection(
                    phase: .speaking,
                    generationID: generationA,
                    visibility: visibility,
                    playbackID: playbackP,
                    mouthCue: cue
                )
            }
        }
        #expect(throws: AvatarProjectionError.mouthCueNotAdmitted) {
            try projection(
                phase: .speaking,
                generationID: generationA,
                reduceMotion: true,
                playbackID: playbackP,
                mouthCue: cue
            )
        }
        #expect(throws: AvatarProjectionError.mouthCueNotAdmitted) {
            try projection(
                phase: .thinking,
                generationID: generationA,
                mouthCue: cue
            )
        }
        #expect(throws: AvatarProjectionError.mouthCueNotAdmitted) {
            try projection(
                phase: .speaking,
                generationID: generationB,
                playbackID: playbackP,
                mouthCue: cue
            )
        }
        #expect(throws: AvatarProjectionError.mouthCueNotAdmitted) {
            try projection(
                phase: .speaking,
                generationID: generationA,
                playbackID: playbackQ,
                mouthCue: cue
            )
        }
    }

    @Test
    func codableRoundTripRetainsValidatedContract() throws {
        let original = try projection(
            phase: .speaking,
            generationID: generationA,
            playbackID: playbackP,
            mouthCue: try cue(envelope: 0.75)
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AvatarProjection.self, from: data) == original)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["projectionSequence"] = maximumSafeInteger + 1
        let unsafeData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: AvatarProjectionError.unsafeInteger) {
            try JSONDecoder().decode(AvatarProjection.self, from: unsafeData)
        }
    }

    @Test
    func neutralValidFixtureBytesAndInputsStayContractShaped() throws {
        let data = try AvatarFixtureDecoder.resourceData(named: "valid")
        let sourceData = try AvatarFixtureDecoder.sourceData(named: "valid")
        #expect(data == sourceData)

        let document = try AvatarFixtureDecoder.decode(data: data)
        #expect(document.schema == "miller-avatar.integration-fixture/v1")
        #expect(document.operations.count == 18)

        let projects = document.operations.compactMap { operation -> AvatarFixtureProjectInput? in
            guard case .project(let input) = operation.input else { return nil }
            return input
        }
        #expect(Set(projects.map(\.phase)) == Set(AvatarPresentationPhase.allCases))
        for input in projects {
            let projection = try makeProjection(from: input)
            #expect(projection.phase == input.phase)
            #expect(projection.generationID == input.generationID)
            #expect(projection.playbackID == input.playbackID)
        }

        let speaking = try #require(projects.first { $0.phase == .speaking })
        let mouthInputs = document.operations.compactMap { operation -> AvatarFixtureMouthInput? in
            guard case .mouth(let input) = operation.input else { return nil }
            return input
        }
        #expect(mouthInputs.count == 2)
        for input in mouthInputs {
            let admitted = try makeProjection(
                from: speaking,
                mouthCue: try makeCue(from: input)
            )
            #expect(admitted.mouthCue != nil)
        }

        let visibilityInputs = document.operations.compactMap { operation -> AvatarVisibility? in
            guard case .visibility(let visibility) = operation.input else { return nil }
            return visibility
        }
        #expect(visibilityInputs == [.occluded, .visible, .hidden, .visible])
        let policyInputs = document.operations.compactMap { operation -> Bool? in
            guard case .reducedMotion(let enabled) = operation.input else { return nil }
            return enabled
        }
        #expect(policyInputs == [true, false])

        let cue = try makeCue(from: mouthInputs[0])
        for visibility in visibilityInputs {
            let result = try? makeProjection(
                from: speaking,
                visibility: visibility,
                mouthCue: cue
            )
            if visibility == .visible {
                #expect(result?.mouthCue == cue)
            } else {
                #expect(result == nil)
            }
        }
        for enabled in policyInputs {
            let result = try? makeProjection(
                from: speaking,
                reduceMotion: enabled,
                mouthCue: cue
            )
            if enabled {
                #expect(result == nil)
            } else {
                #expect(result?.mouthCue == cue)
            }
        }
    }

    @Test
    func reducedMotionRejectsNumericJSONBooleans() throws {
        for value in [1, 0] {
            let data = Data("""
            {
              "schema": "miller-avatar.integration-fixture/v1",
              "operations": [
                {
                  "name": "numeric-reduced-motion",
                  "input": {
                    "type": "set_reduced_motion",
                    "enabled": \(value)
                  }
                }
              ],
              "cases": []
            }
            """.utf8)

            #expect(throws: AvatarFixtureError.invalid) {
                try AvatarFixtureDecoder.decode(data: data)
            }
        }
    }

    @Test
    func neutralInvalidFixtureValidatesStaleIdentityWithoutReplayingReducer() throws {
        let data = try AvatarFixtureDecoder.resourceData(named: "invalid")
        let sourceData = try AvatarFixtureDecoder.sourceData(named: "invalid")
        #expect(data == sourceData)

        let document = try AvatarFixtureDecoder.decode(data: data)
        #expect(document.cases.count == 8)

        for testCase in document.cases {
            switch testCase.name {
            case "duplicate-projection-sequence", "decreasing-projection-sequence":
                let input = try projectInput(from: testCase.input)
                #expect((try? makeProjection(from: input)) != nil)
            case "stale-generation", "stale-playback", "mouth-outside-speaking":
                let active = try projectInput(from: testCase.prelude[0])
                let mouth = try mouthInput(from: testCase.input)
                #expect(throws: AvatarProjectionError.mouthCueNotAdmitted) {
                    try makeProjection(
                        from: active,
                        mouthCue: try makeCue(from: mouth)
                    )
                }
            case "duplicate-cue-index", "decreasing-playback-offset":
                let active = try projectInput(from: testCase.prelude[0])
                let mouth = try mouthInput(from: testCase.input)
                #expect(
                    (try? makeProjection(
                        from: active,
                        mouthCue: try makeCue(from: mouth)
                    )) != nil
                )
            case "nonfinite-equivalent-scalar-type":
                let mouth = try mouthInput(from: testCase.input)
                guard case .string(let scalar) = mouth.envelope else {
                    Issue.record("The nonfinite fixture must retain its string scalar")
                    continue
                }
                #expect(scalar == "NaN")
                #expect(throws: AvatarFixtureError.nonNumericEnvelope) {
                    try makeCue(from: mouth)
                }
            default:
                Issue.record("Unexpected neutral fixture case: \(testCase.name)")
            }
        }
    }

    private func projection(
        sequence: UInt64 = 1,
        phase: AvatarPresentationPhase,
        generationID: UUID? = nil,
        visibility: AvatarVisibility = .visible,
        reduceMotion: Bool = false,
        playbackID: UUID? = nil,
        mouthCue: AvatarMouthCue? = nil
    ) throws -> AvatarProjection {
        try AvatarProjection(
            projectionSequence: sequence,
            generationID: generationID,
            phase: phase,
            visibility: visibility,
            reduceMotion: reduceMotion,
            playbackID: playbackID,
            mouthCue: mouthCue
        )
    }

    private func cue(
        generationID: UUID? = nil,
        playbackID: UUID? = nil,
        envelope: Double = 0.5
    ) throws -> AvatarMouthCue {
        try AvatarMouthCue(
            generationID: generationID ?? generationA,
            playbackID: playbackID ?? playbackP,
            cueIndex: 1,
            playbackOffsetMilliseconds: 100,
            envelope: envelope
        )
    }
}

private struct AvatarFixtureDocument {
    let schema: String
    let operations: [AvatarFixtureOperation]
    let cases: [AvatarFixtureCase]
}

private struct AvatarFixtureOperation {
    let name: String
    let input: AvatarFixtureInput
}

private struct AvatarFixtureCase {
    let name: String
    let prelude: [AvatarFixtureInput]
    let input: AvatarFixtureInput
}

private enum AvatarFixtureInput {
    case project(AvatarFixtureProjectInput)
    case mouth(AvatarFixtureMouthInput)
    case visibility(AvatarVisibility)
    case reducedMotion(Bool)
    case reset(generationID: UUID?, reason: String)
}

private struct AvatarFixtureProjectInput {
    let projectionSequence: UInt64
    let generationID: UUID?
    let phase: AvatarPresentationPhase
    let playbackID: UUID?
}

private struct AvatarFixtureMouthInput {
    let generationID: UUID
    let playbackID: UUID
    let cueIndex: UInt64
    let playbackOffsetMilliseconds: UInt64
    let envelope: AvatarFixtureEnvelope
}

private enum AvatarFixtureEnvelope: Equatable {
    case numeric(Double)
    case string(String)
}

private enum AvatarFixtureError: Error, Equatable {
    case invalid
    case nonNumericEnvelope
}

private enum AvatarFixtureDecoder {
    private static let maximumSafeInteger: Double = 9_007_199_254_740_991

    static func resourceData(named name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Avatar"
        ) else {
            throw AvatarFixtureError.invalid
        }
        return try Data(contentsOf: url)
    }

    static func sourceData(named name: String) throws -> Data {
        let millerRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = millerRoot
            .deletingLastPathComponent()
            .appendingPathComponent("miller-avatar")
            .appendingPathComponent("Tests/IntegrationFixtures")
            .appendingPathComponent(name)
            .appendingPathComponent("\(name == "valid" ? "miller-owned-presentation" : "stale-miller-owned-presentation").json")
        return try Data(contentsOf: url)
    }

    static func decode(data: Data) throws -> AvatarFixtureDocument {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = root["schema"] as? String
        else { throw AvatarFixtureError.invalid }

        let operations = try objects(root["operations"]).map(decodeOperation)
        let cases = try objects(root["cases"]).map(decodeCase)
        return AvatarFixtureDocument(schema: schema, operations: operations, cases: cases)
    }

    private static func decodeOperation(_ value: [String: Any]) throws -> AvatarFixtureOperation {
        guard let name = value["name"] as? String else { throw AvatarFixtureError.invalid }
        return AvatarFixtureOperation(
            name: name,
            input: try decodeInput(value["input"])
        )
    }

    private static func decodeCase(_ value: [String: Any]) throws -> AvatarFixtureCase {
        guard let name = value["name"] as? String else { throw AvatarFixtureError.invalid }
        return AvatarFixtureCase(
            name: name,
            prelude: try objects(value["prelude"]).map { try decodeInput($0) },
            input: try decodeInput(value["input"])
        )
    }

    private static func decodeInput(_ value: Any?) throws -> AvatarFixtureInput {
        guard let input = value as? [String: Any],
              let type = input["type"] as? String
        else { throw AvatarFixtureError.invalid }

        switch type {
        case "project":
            guard let projectionSequence = safeUInt(input["projection_sequence"]),
                  let phaseRawValue = input["phase"] as? String,
                  let phase = AvatarPresentationPhase(rawValue: phaseRawValue)
            else { throw AvatarFixtureError.invalid }
            return .project(AvatarFixtureProjectInput(
                projectionSequence: projectionSequence,
                generationID: try optionalUUID(input["generation_id"]),
                phase: phase,
                playbackID: try optionalUUID(input["playback_id"])
            ))
        case "mouth":
            guard let generationID = try optionalUUID(input["generation_id"]),
                  let playbackID = try optionalUUID(input["playback_id"]),
                  let cueIndex = safeUInt(input["cue_index"]),
                  let playbackOffsetMilliseconds = safeUInt(input["playback_offset_ms"])
            else { throw AvatarFixtureError.invalid }
            let envelope: AvatarFixtureEnvelope
            if let number = input["scalar"] as? NSNumber,
               !isBoolean(input["scalar"]) {
                envelope = .numeric(number.doubleValue)
            } else if let string = input["scalar"] as? String {
                envelope = .string(string)
            } else {
                throw AvatarFixtureError.invalid
            }
            return .mouth(AvatarFixtureMouthInput(
                generationID: generationID,
                playbackID: playbackID,
                cueIndex: cueIndex,
                playbackOffsetMilliseconds: playbackOffsetMilliseconds,
                envelope: envelope
            ))
        case "suspend", "resume":
            guard let rawValue = input["visibility"] as? String,
                  let visibility = AvatarVisibility(rawValue: rawValue)
            else { throw AvatarFixtureError.invalid }
            return .visibility(visibility)
        case "set_reduced_motion":
            guard isBoolean(input["enabled"]),
                  let enabled = input["enabled"] as? Bool
            else { throw AvatarFixtureError.invalid }
            return .reducedMotion(enabled)
        case "reset":
            guard let reason = input["reason"] as? String else { throw AvatarFixtureError.invalid }
            return .reset(
                generationID: try optionalUUID(input["generation_id"]),
                reason: reason
            )
        default:
            throw AvatarFixtureError.invalid
        }
    }

    private static func objects(_ value: Any?) throws -> [[String: Any]] {
        guard let values = value as? [Any] else {
            if value == nil { return [] }
            throw AvatarFixtureError.invalid
        }
        return try values.map { value in
            guard let object = value as? [String: Any] else { throw AvatarFixtureError.invalid }
            return object
        }
    }

    private static func optionalUUID(_ value: Any?) throws -> UUID? {
        if value == nil || value is NSNull { return nil }
        guard let string = value as? String,
              let uuid = UUID(uuidString: string)
        else { throw AvatarFixtureError.invalid }
        return uuid
    }

    private static func safeUInt(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              !isBoolean(value),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0,
              number.doubleValue <= maximumSafeInteger
        else { return nil }
        return number.uint64Value
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

private func projectInput(
    from input: AvatarFixtureInput
) throws -> AvatarFixtureProjectInput {
    guard case .project(let project) = input else { throw AvatarFixtureError.invalid }
    return project
}

private func mouthInput(
    from input: AvatarFixtureInput
) throws -> AvatarFixtureMouthInput {
    guard case .mouth(let mouth) = input else { throw AvatarFixtureError.invalid }
    return mouth
}

private func makeProjection(
    from input: AvatarFixtureProjectInput,
    visibility: AvatarVisibility = .visible,
    reduceMotion: Bool = false,
    mouthCue: AvatarMouthCue? = nil
) throws -> AvatarProjection {
    try AvatarProjection(
        projectionSequence: input.projectionSequence,
        generationID: input.generationID,
        phase: input.phase,
        visibility: visibility,
        reduceMotion: reduceMotion,
        playbackID: input.playbackID,
        mouthCue: mouthCue
    )
}

private func makeCue(from input: AvatarFixtureMouthInput) throws -> AvatarMouthCue {
    guard case .numeric(let envelope) = input.envelope else {
        throw AvatarFixtureError.nonNumericEnvelope
    }
    return try AvatarMouthCue(
        generationID: input.generationID,
        playbackID: input.playbackID,
        cueIndex: input.cueIndex,
        playbackOffsetMilliseconds: input.playbackOffsetMilliseconds,
        envelope: envelope
    )
}

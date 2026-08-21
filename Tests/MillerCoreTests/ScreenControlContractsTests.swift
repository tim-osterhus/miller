import Foundation
@testable import MillerCore
import Testing

@Suite
struct ScreenControlContractsTests {
    @Test
    func firstPartyCapabilityIDsAreFixedAndRoundTrip() throws {
        #expect(CapabilitySource.millerSystem.rawValue == "miller_system")

        let screen = try CapabilityID(
            rawValue: "miller.system.screen_observe"
        )
        let computer = try CapabilityID(
            rawValue: "miller.system.computer_act"
        )

        #expect(screen.rawValue == MillerSystemCapability.screenObserve.rawValue)
        #expect(computer.rawValue == MillerSystemCapability.computerAct.rawValue)
        #expect(
            try CapabilityID(
                source: .millerSystem,
                serverID: "system",
                toolName: "screen_observe"
            ) == screen
        )
        #expect(
            try CapabilityID(
                source: .millerSystem,
                serverID: "system",
                toolName: "computer_act"
            ) == computer
        )

        let encoded = try JSONEncoder().encode(screen)
        #expect(try JSONDecoder().decode(CapabilityID.self, from: encoded) == screen)

        for rawValue in [
            "miller.system.other",
            "miller.system.screen_observe.extra",
            "miller_system/system/screen_observe",
        ] {
            #expect(throws: CapabilityContractError.invalidCapabilityID) {
                try CapabilityID(rawValue: rawValue)
            }
        }
    }

    @Test
    func terminalOutcomeUncertainIsTypedAndCodable() throws {
        let outcome = CapabilityTerminalOutcome.uncertain
        #expect(outcome.rawValue == "uncertain")
        let encoded = try JSONEncoder().encode(outcome)
        #expect(
            try JSONDecoder().decode(
                CapabilityTerminalOutcome.self,
                from: encoded
            ) == outcome
        )
    }

    @Test
    func generationsAreDistinctUUIDBackedTypes() {
        let operation = OperationGeneration()
        let session = SessionGeneration()
        let target = TargetGeneration()
        let observation = ObservationGeneration()

        #expect(operation.rawValue.uuidString.count == 36)
        #expect(session.rawValue.uuidString.count == 36)
        #expect(target.rawValue.uuidString.count == 36)
        #expect(observation.rawValue.uuidString.count == 36)
        #expect(operation.rawValue != session.rawValue)
        #expect(session.rawValue != target.rawValue)
        #expect(target.rawValue != observation.rawValue)
    }

    @Test
    func targetIdentityEnforcesPositiveIDsAndBundleIdentifierCeiling() throws {
        let exactBundle = String(
            repeating: "b",
            count: TargetIdentity.maximumBundleIdentifierBytes
        )
        let target = try TargetIdentity(
            processID: 1,
            windowID: 1,
            bundleIdentifier: exactBundle
        )

        #expect(target.processID == 1)
        #expect(target.windowID == 1)
        #expect(target.bundleIdentifier == exactBundle)

        #expect(throws: CapabilityContractError.invalidTargetIdentity) {
            try TargetIdentity(
                processID: 0,
                windowID: 1,
                bundleIdentifier: "com.example.App"
            )
        }
        #expect(throws: CapabilityContractError.invalidTargetIdentity) {
            try TargetIdentity(
                processID: 1,
                windowID: 0,
                bundleIdentifier: "com.example.App"
            )
        }
        #expect(throws: CapabilityContractError.bundleIdentifierTooLarge) {
            try TargetIdentity(
                processID: 1,
                windowID: 1,
                bundleIdentifier: exactBundle + "b"
            )
        }
        #expect(throws: CapabilityContractError.invalidTargetIdentity) {
            try TargetIdentity(
                processID: 1,
                windowID: 1,
                bundleIdentifier: "com.example\0App"
            )
        }
        #expect(throws: CapabilityContractError.invalidTargetIdentity) {
            try TargetIdentity(
                processID: 1,
                windowID: 1,
                bundleIdentifier: "com.example\u{1f}App"
            )
        }

        let fields = Mirror(reflecting: target).children.map(\.label)
        #expect(!fields.contains("title"))
        #expect(!fields.contains("path"))
    }

    @Test
    func observationIntentAndDerivedDescriptionUseNamedUTF8Ceilings() throws {
        let exactIntent = String(
            repeating: "i",
            count: ObservationIntent.maximumUTF8Bytes
        )
        let exactDescription = String(
            repeating: "d",
            count: DerivedObservationDescription.maximumUTF8Bytes
        )

        #expect(try ObservationIntent(exactIntent).text == exactIntent)
        #expect(
            try DerivedObservationDescription(exactDescription).text
                == exactDescription
        )

        #expect(throws: CapabilityContractError.observationIntentTooLarge) {
            try ObservationIntent(exactIntent + "i")
        }
        #expect(
            throws: CapabilityContractError.derivedObservationDescriptionTooLarge
        ) {
            try DerivedObservationDescription(exactDescription + "d")
        }
        #expect(throws: CapabilityContractError.invalidObservationIntent) {
            try ObservationIntent("")
        }
        #expect(
            throws: CapabilityContractError.invalidDerivedObservationDescription
        ) {
            try DerivedObservationDescription("visible\0content")
        }
    }

    @Test
    func boundedActionValuesRejectOversizedOrUnsafeInput() throws {
        let exactText = String(
            repeating: "t",
            count: BoundedComputerText.maximumUTF8Bytes
        )
        let exactElementID = String(
            repeating: "e",
            count: SemanticElementIdentifier.maximumUTF8Bytes
        )

        #expect(try BoundedComputerText(exactText).text == exactText)
        #expect(
            try SemanticElementIdentifier(exactElementID).rawValue
                == exactElementID
        )
        #expect(throws: CapabilityContractError.computerTextTooLarge) {
            try BoundedComputerText(exactText + "t")
        }
        #expect(
            throws: CapabilityContractError.semanticElementIdentifierTooLarge
        ) {
            try SemanticElementIdentifier(exactElementID + "e")
        }
        #expect(throws: CapabilityContractError.invalidComputerText) {
            try BoundedComputerText("unsafe\0text")
        }
        #expect(
            throws: CapabilityContractError.invalidSemanticElementIdentifier
        ) {
            try SemanticElementIdentifier("unsafe\u{1f}id")
        }
    }

    @Test
    func keyChordsAreFiniteAndNormalizeUniqueKeys() throws {
        let chord = try KeyChord(keys: [" Command ", "SHIFT", "x", "y"])
        #expect(chord.keys == ["command", "shift", "x", "y"])

        #expect(
            throws: CapabilityContractError.invalidKeyChord
        ) {
            try KeyChord(keys: ["Command", " command "])
        }
        #expect(throws: CapabilityContractError.keyChordTooLarge) {
            try KeyChord(keys: Array(repeating: "x", count: 5))
        }

        let exactKey = String(
            repeating: "k",
            count: KeyChord.maximumKeyUTF8Bytes
        )
        #expect(try KeyChord(keys: [exactKey]).keys == [exactKey])
        #expect(throws: CapabilityContractError.keyChordTooLarge) {
            try KeyChord(keys: [exactKey + "k"])
        }
    }

    @Test
    func scrollAndClickGeometryAreFiniteAndBounded() throws {
        let delta = try ScrollDelta(
            horizontal: -ScrollDelta.maximumAbsoluteComponent,
            vertical: ScrollDelta.maximumAbsoluteComponent
        )
        #expect(delta.horizontal == -1_000)
        #expect(delta.vertical == 1_000)
        #expect(
            throws: CapabilityContractError.invalidScrollDelta
        ) {
            try ScrollDelta(
                horizontal: ScrollDelta.maximumAbsoluteComponent + 1,
                vertical: 0
            )
        }
        #expect(throws: CapabilityContractError.invalidScrollDelta) {
            try ScrollDelta(horizontal: .infinity, vertical: 0)
        }

        let point = try NormalizedClickPoint(x: 0, y: 1)
        #expect(point.x == 0)
        #expect(point.y == 1)
        #expect(throws: CapabilityContractError.invalidClickPoint) {
            try NormalizedClickPoint(x: -0.001, y: 0.5)
        }
        #expect(throws: CapabilityContractError.invalidClickPoint) {
            try NormalizedClickPoint(x: 0.5, y: 1.001)
        }
        #expect(throws: CapabilityContractError.invalidClickPoint) {
            try NormalizedClickPoint(x: .nan, y: 0.5)
        }
    }

    @Test
    func computerActionHasExactlyNineTypedCases() throws {
        let target = try TargetIdentity(
            processID: 11,
            windowID: 22,
            bundleIdentifier: "com.example.App"
        )
        let element = try SemanticElementIdentifier("submit")
        let text = try BoundedComputerText("hello")
        let chord = try KeyChord(keys: ["command", "s"])
        let actions: [ComputerAction] = [
            .activateApplication(
                try ActivateApplicationAction(bundleIdentifier: "com.example.App")
            ),
            .focusWindow(try FocusWindowAction(target: target)),
            .focusElement(
                try FocusElementAction(target: target, elementIdentifier: element)
            ),
            .scroll(try ScrollAction(target: target, delta: ScrollDelta(horizontal: 0, vertical: 10))),
            .setText(
                try SetTextAction(
                    target: target,
                    elementIdentifier: element,
                    text: text
                )
            ),
            .insertText(
                try InsertTextAction(
                    target: target,
                    elementIdentifier: element,
                    text: text
                )
            ),
            .invokeElement(
                try InvokeElementAction(target: target, elementIdentifier: element)
            ),
            .pressKeyChord(
                try PressKeyChordAction(target: target, chord: chord)
            ),
            .clickInTarget(
                try ClickInTargetAction(
                    target: target,
                    point: NormalizedClickPoint(x: 0.5, y: 0.5)
                )
            ),
        ]

        #expect(actions.count == 9)
        for action in actions {
            let encoded = try JSONEncoder().encode(action)
            #expect(
                try JSONDecoder().decode(ComputerAction.self, from: encoded)
                    == action
            )
            #expect(
                String(data: encoded, encoding: .utf8)?
                    .contains("actionClass") == false
            )
        }
    }

    @Test
    func actionClassIsOnlyAttachedByMillerOwnedWrapper() throws {
        let target = try TargetIdentity(
            processID: 11,
            windowID: 22,
            bundleIdentifier: "com.example.App"
        )
        let action = ComputerAction.focusWindow(
            try FocusWindowAction(target: target)
        )
        let admitted = MillerAdmittedComputerAction(
            action: action,
            actionClass: .sensitive,
            verificationPredicate: .targetActivated
        )

        #expect(admitted.action == action)
        #expect(admitted.actionClass == .sensitive)
        #expect(admitted.verificationPredicate == .targetActivated)

        let object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(action)
            ) as? [String: Any]
        )
        for (unknownKey, value) in [
            "actionClass": "sensitive",
            "unexpected": "value",
        ] {
            var object = object
            object[unknownKey] = value
            #expect(throws: CapabilityContractError.invalidComputerAction) {
                try JSONDecoder().decode(
                    ComputerAction.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            }
        }
    }

    @Test
    func backendPhasesAreExactlyTheBoundedSet() throws {
        #expect(
            ComputerBackendPhase.allCases == [
                .notStarted,
                .started,
                .partial,
                .completed,
                .timedOut,
                .uncertain,
            ]
        )
        for phase in ComputerBackendPhase.allCases {
            let encoded = try JSONEncoder().encode(phase)
            #expect(
                try JSONDecoder().decode(
                    ComputerBackendPhase.self,
                    from: encoded
                ) == phase
            )
        }
    }

    @Test
    func missingVerificationPredicateCanOnlyBeUncertain() {
        let missing = ComputerVerificationResult(
            predicate: nil,
            satisfied: true
        )
        #expect(missing.outcome == .uncertain)
        #expect(!missing.isVerified)

        let verified = ComputerVerificationResult(
            predicate: .targetActivated,
            satisfied: true
        )
        #expect(verified.outcome == .succeeded)
        #expect(verified.isVerified)
    }
}

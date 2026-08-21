import Foundation

public enum MillerSystemCapability: String, Codable, Equatable, Sendable,
    CaseIterable
{
    case screenObserve = "miller.system.screen_observe"
    case computerAct = "miller.system.computer_act"

    public var capabilityID: CapabilityID {
        CapabilityID(millerSystem: self)
    }

    var shortName: String {
        switch self {
        case .screenObserve: "screen_observe"
        case .computerAct: "computer_act"
        }
    }
}

public struct OperationGeneration: MillerIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SessionGeneration: MillerIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TargetGeneration: MillerIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ObservationGeneration: MillerIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TargetIdentity: Codable, Equatable, Hashable, Sendable {
    /// Reverse-DNS bundle identifiers are kept well below any system limit.
    public static let maximumBundleIdentifierBytes = 128

    public let processID: Int
    public let windowID: Int
    public let bundleIdentifier: String

    public init(
        processID: Int,
        windowID: Int,
        bundleIdentifier: String
    ) throws {
        guard processID > 0, windowID > 0 else {
            throw CapabilityContractError.invalidTargetIdentity
        }
        try ScreenControlValidation.validateBundleIdentifier(
            bundleIdentifier,
            maximumBytes: Self.maximumBundleIdentifierBytes
        )
        self.processID = processID
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            processID: container.decode(Int.self, forKey: .processID),
            windowID: container.decode(Int.self, forKey: .windowID),
            bundleIdentifier: container.decode(
                String.self,
                forKey: .bundleIdentifier
            )
        )
    }
}

public struct ObservationIntent: Codable, Equatable, Sendable {
    /// A short owner request that fits comfortably in one capability call.
    public static let maximumUTF8Bytes = 512

    public let text: String

    public init(_ text: String) throws {
        try ScreenControlValidation.validateNonEmptyText(
            text,
            maximumBytes: Self.maximumUTF8Bytes,
            emptyOrUnsafe: .invalidObservationIntent,
            tooLarge: .observationIntentTooLarge
        )
        self.text = text
    }

    public init(text: String) throws {
        try self.init(text)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public struct DerivedObservationDescription: Codable, Equatable, Sendable {
    /// Derived screen prose is bounded before it can reach a Miller response.
    public static let maximumUTF8Bytes = 4 * 1_024

    public let text: String

    public init(_ text: String) throws {
        try ScreenControlValidation.validateNonEmptyText(
            text,
            maximumBytes: Self.maximumUTF8Bytes,
            emptyOrUnsafe: .invalidDerivedObservationDescription,
            tooLarge: .derivedObservationDescriptionTooLarge
        )
        self.text = text
    }

    public init(text: String) throws {
        try self.init(text)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public struct BoundedComputerText: Codable, Equatable, Sendable {
    /// Four KiB is enough for one normal text-field interaction.
    public static let maximumUTF8Bytes = 4 * 1_024

    public let text: String

    public init(_ text: String) throws {
        try ScreenControlValidation.validateBoundedText(
            text,
            maximumBytes: Self.maximumUTF8Bytes,
            tooLarge: .computerTextTooLarge
        )
        self.text = text
    }

    public init(text: String) throws {
        try self.init(text)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public struct SemanticElementIdentifier: Codable, Equatable, Hashable, Sendable {
    /// Accessibility identifiers are intentionally much smaller than labels.
    public static let maximumUTF8Bytes = 256

    public let rawValue: String

    public init(_ rawValue: String) throws {
        try ScreenControlValidation.validateNonEmptyText(
            rawValue,
            maximumBytes: Self.maximumUTF8Bytes,
            emptyOrUnsafe: .invalidSemanticElementIdentifier,
            tooLarge: .semanticElementIdentifierTooLarge
        )
        self.rawValue = rawValue
    }

    public init(rawValue: String) throws {
        try self.init(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct KeyChord: Codable, Equatable, Sendable {
    public static let maximumKeyCount = 4
    public static let maximumKeyUTF8Bytes = 32

    public let keys: [String]

    public init(keys: [String]) throws {
        guard !keys.isEmpty else {
            throw CapabilityContractError.invalidKeyChord
        }
        guard keys.count <= Self.maximumKeyCount else {
            throw CapabilityContractError.keyChordTooLarge
        }

        var normalized: [String] = []
        var seen = Set<String>()
        for key in keys {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !value.isEmpty,
                  value.utf8.count <= Self.maximumKeyUTF8Bytes,
                  !ScreenControlValidation.containsControl(value),
                  value.unicodeScalars.allSatisfy(\.isASCII),
                  seen.insert(value).inserted
            else {
                if value.utf8.count > Self.maximumKeyUTF8Bytes {
                    throw CapabilityContractError.keyChordTooLarge
                }
                throw CapabilityContractError.invalidKeyChord
            }
            normalized.append(value)
        }
        self.keys = normalized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(keys: container.decode([String].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(keys)
    }
}

public struct ScrollDelta: Codable, Equatable, Sendable {
    /// A single action may move at most one thousand logical scroll units.
    public static let maximumAbsoluteComponent = 1_000.0

    public let horizontal: Double
    public let vertical: Double

    public init(horizontal: Double, vertical: Double) throws {
        guard horizontal.isFinite,
              vertical.isFinite,
              abs(horizontal) <= Self.maximumAbsoluteComponent,
              abs(vertical) <= Self.maximumAbsoluteComponent
        else {
            throw CapabilityContractError.invalidScrollDelta
        }
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            horizontal: container.decode(Double.self, forKey: .horizontal),
            vertical: container.decode(Double.self, forKey: .vertical)
        )
    }
}

public struct NormalizedClickPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y)
        else {
            throw CapabilityContractError.invalidClickPoint
        }
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y)
        )
    }
}

public struct ActivateApplicationAction: Codable, Equatable, Sendable {
    public let bundleIdentifier: String

    public init(bundleIdentifier: String) throws {
        try ScreenControlValidation.validateBundleIdentifier(
            bundleIdentifier,
            maximumBytes: TargetIdentity.maximumBundleIdentifierBytes
        )
        self.bundleIdentifier = bundleIdentifier
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bundleIdentifier: container.decode(
                String.self,
                forKey: .bundleIdentifier
            )
        )
    }
}

public struct FocusWindowAction: Codable, Equatable, Sendable {
    public let target: TargetIdentity

    public init(target: TargetIdentity) {
        self.target = target
    }
}

public struct FocusElementAction: Codable, Equatable, Sendable {
    public let target: TargetIdentity
    public let elementIdentifier: SemanticElementIdentifier

    public init(
        target: TargetIdentity,
        elementIdentifier: SemanticElementIdentifier
    ) {
        self.target = target
        self.elementIdentifier = elementIdentifier
    }
}

public struct ScrollAction: Codable, Equatable, Sendable {
    public let target: TargetIdentity
    public let delta: ScrollDelta

    public init(target: TargetIdentity, delta: ScrollDelta) {
        self.target = target
        self.delta = delta
    }
}

public struct SetTextAction: Codable, Equatable, Sendable {
    public let target: TargetIdentity
    public let elementIdentifier: SemanticElementIdentifier
    public let text: BoundedComputerText

    public init(
        target: TargetIdentity,
        elementIdentifier: SemanticElementIdentifier,
        text: BoundedComputerText
    ) {
        self.target = target
        self.elementIdentifier = elementIdentifier
        self.text = text
    }
}

public struct InsertTextAction: Codable, Equatable, Sendable {
    public let target: TargetIdentity
    public let elementIdentifier: SemanticElementIdentifier
    public let text: BoundedComputerText

    public init(
        target: TargetIdentity,
        elementIdentifier: SemanticElementIdentifier,
        text: BoundedComputerText
    ) {
        self.target = target
        self.elementIdentifier = elementIdentifier
        self.text = text
    }
}

public struct InvokeElementAction: Codable, Equatable, Sendable {
    public let target: TargetIdentity
    public let elementIdentifier: SemanticElementIdentifier

    public init(
        target: TargetIdentity,
        elementIdentifier: SemanticElementIdentifier
    ) {
        self.target = target
        self.elementIdentifier = elementIdentifier
    }
}

public struct PressKeyChordAction: Codable, Equatable, Sendable {
    public let target: TargetIdentity
    public let chord: KeyChord

    public init(target: TargetIdentity, chord: KeyChord) {
        self.target = target
        self.chord = chord
    }
}

public struct ClickInTargetAction: Codable, Equatable, Sendable {
    public let target: TargetIdentity
    public let point: NormalizedClickPoint

    public init(target: TargetIdentity, point: NormalizedClickPoint) {
        self.target = target
        self.point = point
    }
}

public enum ComputerAction: Codable, Equatable, Sendable {
    case activateApplication(ActivateApplicationAction)
    case focusWindow(FocusWindowAction)
    case focusElement(FocusElementAction)
    case scroll(ScrollAction)
    case setText(SetTextAction)
    case insertText(InsertTextAction)
    case invokeElement(InvokeElementAction)
    case pressKeyChord(PressKeyChordAction)
    case clickInTarget(ClickInTargetAction)

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case activateApplication = "activate_application"
        case focusWindow = "focus_window"
        case focusElement = "focus_element"
        case scroll
        case setText = "set_text"
        case insertText = "insert_text"
        case invokeElement = "invoke_element"
        case pressKeyChord = "press_key_chord"
        case clickInTarget = "click_in_target"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set([.kind, .payload]) else {
            throw CapabilityContractError.invalidComputerAction
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .activateApplication:
            self = .activateApplication(
                try container.decode(
                    ActivateApplicationAction.self,
                    forKey: .payload
                )
            )
        case .focusWindow:
            self = .focusWindow(
                try container.decode(FocusWindowAction.self, forKey: .payload)
            )
        case .focusElement:
            self = .focusElement(
                try container.decode(FocusElementAction.self, forKey: .payload)
            )
        case .scroll:
            self = .scroll(
                try container.decode(ScrollAction.self, forKey: .payload)
            )
        case .setText:
            self = .setText(
                try container.decode(SetTextAction.self, forKey: .payload)
            )
        case .insertText:
            self = .insertText(
                try container.decode(InsertTextAction.self, forKey: .payload)
            )
        case .invokeElement:
            self = .invokeElement(
                try container.decode(
                    InvokeElementAction.self,
                    forKey: .payload
                )
            )
        case .pressKeyChord:
            self = .pressKeyChord(
                try container.decode(
                    PressKeyChordAction.self,
                    forKey: .payload
                )
            )
        case .clickInTarget:
            self = .clickInTarget(
                try container.decode(
                    ClickInTargetAction.self,
                    forKey: .payload
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .activateApplication(let payload):
            try container.encode(Kind.activateApplication, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .focusWindow(let payload):
            try container.encode(Kind.focusWindow, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .focusElement(let payload):
            try container.encode(Kind.focusElement, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .scroll(let payload):
            try container.encode(Kind.scroll, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .setText(let payload):
            try container.encode(Kind.setText, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .insertText(let payload):
            try container.encode(Kind.insertText, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .invokeElement(let payload):
            try container.encode(Kind.invokeElement, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .pressKeyChord(let payload):
            try container.encode(Kind.pressKeyChord, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .clickInTarget(let payload):
            try container.encode(Kind.clickInTarget, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}

public enum ComputerActionClass: String, Equatable, Sendable, CaseIterable {
    case safeNavigation = "safe_navigation"
    case reversibleEdit = "reversible_edit"
    case sensitive
    case unclassified
}

public enum ComputerVerificationPredicate: String, Equatable, Sendable {
    case targetActivated = "target_activated"
    case elementFocused = "element_focused"
    case scrollPositionChanged = "scroll_position_changed"
    case textValuePresent = "text_value_present"
    case elementStateChanged = "element_state_changed"
    case menuOrKeyEffectObserved = "menu_or_key_effect_observed"
    case clickEffectObserved = "click_effect_observed"
}

public struct MillerAdmittedComputerAction: Equatable, Sendable {
    public let action: ComputerAction
    public let actionClass: ComputerActionClass
    public let verificationPredicate: ComputerVerificationPredicate

    public init(
        action: ComputerAction,
        actionClass: ComputerActionClass,
        verificationPredicate: ComputerVerificationPredicate
    ) {
        self.action = action
        self.actionClass = actionClass
        self.verificationPredicate = verificationPredicate
    }
}

public struct ComputerVerificationResult: Equatable, Sendable {
    public let predicate: ComputerVerificationPredicate?
    public let satisfied: Bool
    public let outcome: CapabilityTerminalOutcome

    public var isVerified: Bool {
        outcome == .succeeded
    }

    public init(
        predicate: ComputerVerificationPredicate?,
        satisfied: Bool
    ) {
        self.predicate = predicate
        self.satisfied = satisfied
        if predicate == nil {
            outcome = .uncertain
        } else if satisfied {
            outcome = .succeeded
        } else {
            outcome = .failed
        }
    }
}

public enum ComputerBackendPhase: String, Codable, Equatable, Sendable,
    CaseIterable
{
    case notStarted = "not_started"
    case started
    case partial
    case completed
    case timedOut = "timed_out"
    case uncertain
}

private enum ScreenControlValidation {
    static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }

    static func validateNonEmptyText(
        _ value: String,
        maximumBytes: Int,
        emptyOrUnsafe: CapabilityContractError,
        tooLarge: CapabilityContractError
    ) throws {
        guard !value.isEmpty, !containsControl(value) else {
            throw emptyOrUnsafe
        }
        guard value.utf8.count <= maximumBytes else {
            throw tooLarge
        }
    }

    static func validateBoundedText(
        _ value: String,
        maximumBytes: Int,
        tooLarge: CapabilityContractError
    ) throws {
        guard !containsControl(value) else {
            throw CapabilityContractError.invalidComputerText
        }
        guard value.utf8.count <= maximumBytes else {
            throw tooLarge
        }
    }

    static func validateBundleIdentifier(
        _ value: String,
        maximumBytes: Int
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              !containsControl(value),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && scalar.properties.isAlphabetic
                      || scalar.isASCII && (48...57).contains(scalar.value)
                      || scalar == "."
                      || scalar == "-"
              }),
              value.first != ".",
              value.last != "."
        else {
            if value.utf8.count > maximumBytes {
                throw CapabilityContractError.bundleIdentifierTooLarge
            }
            throw CapabilityContractError.invalidTargetIdentity
        }
    }
}

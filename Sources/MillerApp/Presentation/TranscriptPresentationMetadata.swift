import MillerCore

enum TranscriptSurfaceNamespace: String, Equatable, Sendable {
    case conversation
    case overlay
}

struct TranscriptContentRevision: Equatable, Sendable {
    private(set) var typed: UInt64 = 0
    private(set) var live: UInt64 = 0

    mutating func advance(
        typedContentChanged: Bool = false,
        liveContentChanged: Bool = false
    ) {
        if typedContentChanged {
            typed &+= 1
        }
        if liveContentChanged {
            live &+= 1
        }
    }
}

enum TranscriptDisplayedContent {
    static func typedChanged(
        from current: [Turn],
        to proposed: [Turn]
    ) -> Bool {
        guard current.count == proposed.count else { return true }
        return zip(current, proposed).contains { current, proposed in
            current.id != proposed.id
                || current.userText != proposed.userText
                || current.assistantText != proposed.assistantText
                || current.errorMessage != proposed.errorMessage
        }
    }

    static func liveChanged(
        from current: [LiveTranscriptTurn],
        to proposed: [LiveTranscriptTurn]
    ) -> Bool {
        guard current.count == proposed.count else { return true }
        return zip(current, proposed).contains { current, proposed in
            current.id != proposed.id
                || current.role != proposed.role
                || current.text != proposed.text
        }
    }
}

enum TranscriptVoiceStatusToken: Equatable, Sendable {
    case persistenceFailure
    case state(
        LiveVoiceState,
        failureCode: String?,
        portableSkillsOmitted: Bool
    )

    init(
        state: LiveVoiceState,
        failureCode: String? = nil,
        persistenceFailure: Bool = false,
        reasoningStatus: ReasoningStatus? = nil
    ) {
        if persistenceFailure {
            self = .persistenceFailure
        } else {
            self = .state(
                state,
                failureCode: state == .failed ? failureCode : nil,
                portableSkillsOmitted:
                    state.isActive && reasoningStatus == .portableSkillsOmitted
            )
        }
    }

    var state: LiveVoiceState? {
        guard case let .state(state, _, _) = self else { return nil }
        return state
    }
}

struct TranscriptContentChange: Equatable, Sendable {
    let typedRevision: UInt64
    let liveRevision: UInt64
    let voiceStatus: TranscriptVoiceStatusToken
}

enum TranscriptAccessibilityIdentifier {
    static func typedUser(
        surface: TranscriptSurfaceNamespace,
        turnID: TurnID
    ) -> String {
        "\(prefix(surface)).typed.user.\(turnID.description)"
    }

    static func typedAssistantBlock(
        surface: TranscriptSurfaceNamespace,
        turnID: TurnID,
        blockIndex: Int
    ) -> String {
        "\(prefix(surface)).typed.assistant.\(turnID.description).block.\(blockIndex)"
    }

    static func live(
        surface: TranscriptSurfaceNamespace,
        turnID: Int
    ) -> String {
        "\(prefix(surface)).live.\(turnID)"
    }

    static func bottomAnchor(surface: TranscriptSurfaceNamespace) -> String {
        "\(prefix(surface)).bottom"
    }

    static func jumpToLatest(surface: TranscriptSurfaceNamespace) -> String {
        "\(prefix(surface)).jump-to-latest"
    }

    private static func prefix(_ surface: TranscriptSurfaceNamespace) -> String {
        "miller.transcript.\(surface.rawValue)"
    }
}

struct TranscriptAccessibilityMetadata: Equatable, Sendable {
    let roleLabel: String
    let transcriptElementIdentifier: String

    static func live(
        surface: TranscriptSurfaceNamespace,
        turnID: Int,
        role: LiveTranscriptRole
    ) -> Self {
        Self(
            roleLabel: roleLabel(for: role),
            transcriptElementIdentifier: TranscriptAccessibilityIdentifier.live(
                surface: surface,
                turnID: turnID
            )
        )
    }

    private static func roleLabel(for role: LiveTranscriptRole) -> String {
        role == .user
            ? "Live voice user transcript"
            : "Live voice assistant transcript"
    }
}

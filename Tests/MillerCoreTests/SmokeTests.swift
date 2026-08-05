import Foundation
@testable import MillerCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw CheckFailure(description: message)
    }
}

private func requireThrows(
    _ expected: CoreError,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
        throw CheckFailure(description: "Expected \(expected), but no error was thrown")
    } catch let error as CoreError {
        try require(error == expected, "Expected \(expected), received \(error)")
    }
}

private enum CoreDomainChecks {
    static func identifiersAreTypedUUIDValues() throws {
        let uuid = UUID(uuidString: "7C6E8299-58C1-4D29-A367-20EC29D36A3A")!
        let conversationID = ConversationID(rawValue: uuid)
        let turnID = TurnID(rawValue: uuid)

        try require(
            conversationID.description == uuid.uuidString.lowercased(),
            "Identifier descriptions must use lowercase UUID strings"
        )
        try require(
            conversationID.rawValue == turnID.rawValue,
            "Typed identifiers must preserve their UUID values"
        )
        try require(
            OperationID() != OperationID(),
            "Generated operation identifiers must be independent"
        )
    }

    static func conversationTitleNormalizesAndTruncatesUnicodeScalars() throws {
        let title = Conversation.initialTitle(
            from: " \n  Hello\t\tMiller   " + String(repeating: "é", count: 70)
        )
        try require(title?.hasPrefix("Hello Miller ") == true, "Whitespace was not normalized")
        try require(
            title?.unicodeScalars.count == 60,
            "The title must be limited to 60 Unicode scalar values"
        )
        try require(
            Conversation.initialTitle(from: " \n\t ") == nil,
            "Whitespace-only input must not create a title"
        )
    }

    static func acceptedTurnStreamsAndAppendsText() throws {
        var turn = acceptedTurn()
        try turn.apply(.textDelta("Hello", generation: 1))
        try require(turn.state == .streaming, "The first delta must start streaming")
        try require(turn.assistantText == "Hello", "The admitted delta was not retained")
        try turn.apply(.textDelta(" there", generation: 1))
        try require(turn.state == .streaming, "A later delta must remain streaming")
        try require(turn.assistantText == "Hello there", "Deltas must append in order")
    }

    static func acceptedTurnCanCompleteWithoutText() throws {
        var turn = acceptedTurn()
        try turn.apply(.completed(at: .distantFuture))
        try require(turn.state == .completed, "An accepted turn may complete")
        try require(turn.assistantText.isEmpty, "Empty completion must not invent text")
        try require(
            turn.completionCode == "completed_without_text",
            "Empty completion must expose its stable presentation code"
        )
    }

    static func acceptedTurnCanStopOrFail() throws {
        var stopped = acceptedTurn()
        try stopped.apply(.stopped(at: .distantFuture, nextGeneration: 2))
        try require(stopped.state == .stopped, "An accepted turn may stop")
        try require(stopped.generation == 2, "Stopping must advance the generation fence")

        var failed = acceptedTurn()
        try failed.apply(
            .failed(
                code: "gateway_unavailable",
                message: "untrusted provider text",
                at: .distantFuture,
                nextGeneration: 2
            )
        )
        try require(failed.state == .failed, "An accepted turn may fail")
        try require(failed.generation == 2, "Failure must advance the generation fence")
        try require(
            failed.errorCode == "gateway_unavailable",
            "A known failure code must be retained"
        )
        try require(
            failed.errorMessage == "The reasoning service is unavailable. Try again.",
            "Failure messages must be Miller-authored"
        )
    }

    static func streamingTurnCanCompleteStopOrFail() throws {
        var completed = try streamingTurn(text: "complete")
        try completed.apply(.completed(at: .distantFuture))
        try require(completed.state == .completed, "A streaming turn may complete")
        try require(completed.assistantText == "complete", "Completion must retain text")

        var stopped = try streamingTurn(text: "stopped partial")
        try stopped.apply(.stopped(at: .distantFuture, nextGeneration: 2))
        try require(stopped.state == .stopped, "A streaming turn may stop")
        try require(
            stopped.assistantText == "stopped partial",
            "Stopping must preserve admitted partial text"
        )

        var failed = try streamingTurn(text: "failed partial")
        try failed.apply(
            .failed(
                code: "provider_unavailable",
                message: "raw backend response",
                at: .distantFuture,
                nextGeneration: 2
            )
        )
        try require(failed.state == .failed, "A streaming turn may fail")
        try require(
            failed.assistantText == "failed partial",
            "Failure must preserve admitted partial text"
        )
        try require(
            failed.errorMessage == "The provider is unavailable. Try again.",
            "Raw backend messages must not cross the Core boundary"
        )
    }

    static func generationMismatchRejectsDeltaAndFence() throws {
        var turn = acceptedTurn()
        try requireThrows(
            .generationMismatch(expected: 1, received: 2)
        ) {
            try turn.apply(.textDelta("wrong generation", generation: 2))
        }
        try require(turn.state == .accepted, "A rejected delta must not mutate state")

        try requireThrows(
            .generationMismatch(expected: 2, received: 3)
        ) {
            try turn.apply(.stopped(at: .distantFuture, nextGeneration: 3))
        }
        try require(turn.generation == 1, "A rejected fence must not mutate generation")
    }

    static func terminalTurnsRejectEveryEvent() throws {
        let terminalTurns = try makeTerminalTurns()
        let events: [TurnEvent] = [
            .textDelta("late", generation: 2),
            .completed(at: .distantFuture),
            .stopped(at: .distantFuture, nextGeneration: 3),
            .failed(
                code: "failed",
                message: "late",
                at: .distantFuture,
                nextGeneration: 3
            ),
        ]

        for terminalTurn in terminalTurns {
            for event in events {
                var turn = terminalTurn
                try requireThrows(.turnAlreadyTerminal) {
                    try turn.apply(event)
                }
                try require(
                    turn == terminalTurn,
                    "A rejected terminal event must not mutate the turn"
                )
            }
        }
    }

    static func unknownFailuresUseTheGenericAllowlistedPair() throws {
        var turn = acceptedTurn()
        try turn.apply(
            .failed(
                code: "provider_secret_error",
                message: "secret-bearing raw dependency text",
                at: .distantFuture,
                nextGeneration: 2
            )
        )
        try require(turn.errorCode == "failed", "Unknown codes must be replaced")
        try require(
            turn.errorMessage == "The request failed. Try again.",
            "Unknown messages must be replaced"
        )
    }

    static func capabilityReadinessIsIndependent() throws {
        let storage = CapabilityReadiness(
            capability: .durableStorage,
            status: .ready
        )
        let avatar = CapabilityReadiness(
            capability: .avatarPresentation,
            status: .failed,
            failureCode: "avatar_unavailable"
        )
        try require(storage.isReadyForText, "Ready storage is a text prerequisite")
        try require(!avatar.isRequiredForText, "Avatar readiness must not gate text")
    }

    static func speechOperationsHaveIndependentIdentitiesAndGenerations() throws {
        let operations = [
            SpeechOperation(id: OperationID(), generation: 1, kind: .capture),
            SpeechOperation(id: OperationID(), generation: 2, kind: .transcription),
            SpeechOperation(id: OperationID(), generation: 3, kind: .synthesis),
            SpeechOperation(id: OperationID(), generation: 4, kind: .playback),
        ]

        try require(
            Set(operations.map(\.id)).count == 4,
            "Each speech operation must have an independent identity"
        )
        try require(
            operations.map(\.generation) == [1, 2, 3, 4],
            "Each speech operation must retain its own generation"
        )
        try require(
            operations.map(\.kind) == [.capture, .transcription, .synthesis, .playback],
            "All four speech operation kinds must remain distinct"
        )
        try require(
            TranscriptState.allCases == [
                .empty, .partial, .final, .editable, .submitted, .cancelled,
            ],
            "The transcript lifecycle must remain closed"
        )
    }

    static func avatarProjectionIsBoundedAndContainsNoAuthority() throws {
        let aboveRange = AvatarProjection(
            generation: 7,
            phase: .speaking,
            isVisible: true,
            reduceMotion: true,
            animationIntent: .speaking,
            gazeIntent: .center,
            mouthEnvelope: 2
        )
        try require(aboveRange.mouthEnvelope == 1, "Mouth envelope must clamp above the range")

        let belowRange = AvatarProjection(
            generation: 7,
            phase: .speaking,
            isVisible: true,
            reduceMotion: true,
            animationIntent: .speaking,
            mouthEnvelope: -1
        )
        try require(belowRange.mouthEnvelope == 0, "Mouth envelope must clamp below the range")

        let notANumber = AvatarProjection(
            generation: 7,
            phase: .speaking,
            isVisible: true,
            reduceMotion: true,
            animationIntent: .speaking,
            mouthEnvelope: .nan
        )
        try require(notANumber.mouthEnvelope == nil, "A non-finite mouth envelope must be omitted")
        _ = try JSONEncoder().encode(notANumber)

        let labels = Set(Mirror(reflecting: aboveRange).children.compactMap(\.label))
        let forbidden = Set([
            "text", "audio", "credential", "credentials", "command", "commands",
            "providerPayload", "conversationHistory", "renderer",
        ])
        try require(
            labels.isDisjoint(with: forbidden),
            "Avatar projection must not carry content, credentials, commands, or a renderer"
        )
    }

    private static func acceptedTurn() -> Turn {
        Turn.accepted(
            id: TurnID(),
            conversationID: ConversationID(),
            sequence: 1,
            inputMode: .text,
            userText: "Hello",
            generation: 1,
            at: .distantPast
        )
    }

    private static func streamingTurn(text: String) throws -> Turn {
        var turn = acceptedTurn()
        try turn.apply(.textDelta(text, generation: 1))
        return turn
    }

    private static func makeTerminalTurns() throws -> [Turn] {
        var completed = acceptedTurn()
        try completed.apply(.completed(at: .distantFuture))

        var stopped = acceptedTurn()
        try stopped.apply(.stopped(at: .distantFuture, nextGeneration: 2))

        var failed = acceptedTurn()
        try failed.apply(
            .failed(
                code: "failed",
                message: "The request failed. Try again.",
                at: .distantFuture,
                nextGeneration: 2
            )
        )
        return [completed, stopped, failed]
    }
}

#if canImport(XCTest)
import XCTest

final class SmokeTests: XCTestCase {
    func testIdentifiersAreTypedUUIDValues() throws {
        try CoreDomainChecks.identifiersAreTypedUUIDValues()
    }

    func testConversationTitleNormalizesAndTruncatesUnicodeScalars() throws {
        try CoreDomainChecks.conversationTitleNormalizesAndTruncatesUnicodeScalars()
    }

    func testAcceptedTurnStreamsAndAppendsText() throws {
        try CoreDomainChecks.acceptedTurnStreamsAndAppendsText()
    }

    func testAcceptedTurnCanCompleteWithoutText() throws {
        try CoreDomainChecks.acceptedTurnCanCompleteWithoutText()
    }

    func testAcceptedTurnCanStopOrFail() throws {
        try CoreDomainChecks.acceptedTurnCanStopOrFail()
    }

    func testStreamingTurnCanCompleteStopOrFail() throws {
        try CoreDomainChecks.streamingTurnCanCompleteStopOrFail()
    }

    func testGenerationMismatchRejectsDeltaAndFence() throws {
        try CoreDomainChecks.generationMismatchRejectsDeltaAndFence()
    }

    func testTerminalTurnsRejectEveryEvent() throws {
        try CoreDomainChecks.terminalTurnsRejectEveryEvent()
    }

    func testUnknownFailuresUseTheGenericAllowlistedPair() throws {
        try CoreDomainChecks.unknownFailuresUseTheGenericAllowlistedPair()
    }

    func testCapabilityReadinessIsIndependent() throws {
        try CoreDomainChecks.capabilityReadinessIsIndependent()
    }

    func testSpeechOperationsHaveIndependentIdentitiesAndGenerations() throws {
        try CoreDomainChecks.speechOperationsHaveIndependentIdentitiesAndGenerations()
    }

    func testAvatarProjectionIsBoundedAndContainsNoAuthority() throws {
        try CoreDomainChecks.avatarProjectionIsBoundedAndContainsNoAuthority()
    }
}
#else
import Testing

@Test func identifiersAreTypedUUIDValues() throws {
    try CoreDomainChecks.identifiersAreTypedUUIDValues()
}

@Test func conversationTitleNormalizesAndTruncatesUnicodeScalars() throws {
    try CoreDomainChecks.conversationTitleNormalizesAndTruncatesUnicodeScalars()
}

@Test func acceptedTurnStreamsAndAppendsText() throws {
    try CoreDomainChecks.acceptedTurnStreamsAndAppendsText()
}

@Test func acceptedTurnCanCompleteWithoutText() throws {
    try CoreDomainChecks.acceptedTurnCanCompleteWithoutText()
}

@Test func acceptedTurnCanStopOrFail() throws {
    try CoreDomainChecks.acceptedTurnCanStopOrFail()
}

@Test func streamingTurnCanCompleteStopOrFail() throws {
    try CoreDomainChecks.streamingTurnCanCompleteStopOrFail()
}

@Test func generationMismatchRejectsDeltaAndFence() throws {
    try CoreDomainChecks.generationMismatchRejectsDeltaAndFence()
}

@Test func terminalTurnsRejectEveryEvent() throws {
    try CoreDomainChecks.terminalTurnsRejectEveryEvent()
}

@Test func unknownFailuresUseTheGenericAllowlistedPair() throws {
    try CoreDomainChecks.unknownFailuresUseTheGenericAllowlistedPair()
}

@Test func capabilityReadinessIsIndependent() throws {
    try CoreDomainChecks.capabilityReadinessIsIndependent()
}

@Test func speechOperationsHaveIndependentIdentitiesAndGenerations() throws {
    try CoreDomainChecks.speechOperationsHaveIndependentIdentitiesAndGenerations()
}

@Test func avatarProjectionIsBoundedAndContainsNoAuthority() throws {
    try CoreDomainChecks.avatarProjectionIsBoundedAndContainsNoAuthority()
}
#endif

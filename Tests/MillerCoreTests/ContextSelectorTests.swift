import Foundation
@testable import MillerCore
import Testing

@Suite
struct ContextSelectorTests {
    @Test
    func onlyCompletedPairsEnterContext() throws {
        let turns = [
            makeTurn(sequence: 1, state: .completed, user: "u1", assistant: "a1"),
            makeTurn(sequence: 2, state: .stopped, user: "u2", assistant: "visible stop"),
            makeTurn(sequence: 3, state: .failed, user: "u3", assistant: "visible failure"),
            makeTurn(sequence: 4, state: .completed, user: "u4", assistant: "a4"),
        ]

        #expect(ContextSelector().select(from: turns) == [
            ReasoningMessage(role: .user, text: "u1"),
            ReasoningMessage(role: .assistant, text: "a1"),
            ReasoningMessage(role: .user, text: "u4"),
            ReasoningMessage(role: .assistant, text: "a4"),
        ])
    }

    @Test
    func selectsAtMostTwentyNewestPairsInChronologicalOrder() throws {
        let turns = (1...25).map {
            makeTurn(
                sequence: $0,
                state: .completed,
                user: "u\($0)",
                assistant: "a\($0)"
            )
        }

        let messages = ContextSelector().select(from: turns)
        #expect(messages.count == 40)
        #expect(messages.first == ReasoningMessage(role: .user, text: "u6"))
        #expect(messages.last == ReasoningMessage(role: .assistant, text: "a25"))
    }

    @Test
    func skipsOversizedPairsWithoutTruncatingOrStoppingSelection() throws {
        let fits = makeTurn(
            sequence: 1,
            state: .completed,
            user: "older",
            assistant: "pair"
        )
        let oversized = makeTurn(
            sequence: 2,
            state: .completed,
            user: String(repeating: "😀", count: 32_001),
            assistant: "too large"
        )

        #expect(ContextSelector().select(from: [fits, oversized]) == [
            ReasoningMessage(role: .user, text: "older"),
            ReasoningMessage(role: .assistant, text: "pair"),
        ])
    }

    @Test
    func countsUnicodeScalarsAcrossCompletePairs() throws {
        let older = makeTurn(
            sequence: 1,
            state: .completed,
            user: "x",
            assistant: "y"
        )
        let exactBound = makeTurn(
            sequence: 2,
            state: .completed,
            user: String(repeating: "é", count: 16_000),
            assistant: String(repeating: "😀", count: 16_000)
        )

        let messages = ContextSelector().select(from: [older, exactBound])
        #expect(messages.count == 2)
        #expect(messages[0].text.unicodeScalars.count == 16_000)
        #expect(messages[1].text.unicodeScalars.count == 16_000)
    }

    @Test
    func validatesCurrentInputSeparatelyAtItsOwnBound() throws {
        let selector = ContextSelector()
        let maximum = String(repeating: "😀", count: 65_536)
        try selector.validateCurrentInput(maximum)

        #expect(throws: CoreError.requestTooLarge) {
            try selector.validateCurrentInput(maximum + "x")
        }
        #expect(selector.select(from: []).isEmpty)
    }
}

private func makeTurn(
    sequence: Int,
    state: TurnState,
    user: String,
    assistant: String
) -> Turn {
    Turn(
        id: TurnID(),
        conversationID: ConversationID(),
        sequence: sequence,
        inputMode: .text,
        userText: user,
        assistantText: assistant,
        state: state,
        generation: state == .completed ? 1 : 2,
        errorCode: state == .failed ? "failed" : nil,
        errorMessage: state == .failed ? "The request failed. Try again." : nil,
        startedAt: .distantPast,
        terminalAt: .distantFuture
    )
}

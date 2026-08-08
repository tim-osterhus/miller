import Foundation
import MillerCore
import Testing
@testable import MillerApp

@Suite
struct TranscriptPresentationMetadataTests {
    @Test
    @MainActor
    func liveCompletionStoresFullRowWithoutAdvancingDisplayRevision() async {
        let model = AppPresentationModel(
            dependencies: transcriptTestDependencies()
        )

        await model.applyLiveEvent(
            .transcriptDelta(role: .assistant, text: "same response")
        )
        let beforeCompletion = model.transcriptContentChange.liveRevision

        await model.applyLiveEvent(
            .transcriptDone(role: .assistant, text: "same response")
        )

        #expect(model.liveTranscriptTurns.count == 1)
        #expect(model.liveTranscriptTurns[0].isComplete)
        #expect(
            model.transcriptContentChange.liveRevision == beforeCompletion
        )
    }

    @Test
    @MainActor
    func typedTerminalStateStoresFullRowWithoutAdvancingDisplayRevision() async throws {
        let startedAt = Date(timeIntervalSince1970: 0)
        let accepted = Turn(
            id: TurnID(
                rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
            ),
            conversationID: ConversationID(
                rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
            ),
            sequence: 1,
            inputMode: .text,
            userText: "same question",
            assistantText: "same response",
            state: .accepted,
            generation: 1,
            errorCode: nil,
            errorMessage: nil,
            startedAt: startedAt,
            terminalAt: nil
        )
        var completed = accepted
        try completed.apply(.completed(at: startedAt))
        let loads = TurnLoadSequence(values: [[accepted], [completed]])
        let model = AppPresentationModel(
            dependencies: transcriptTestDependencies(loads: loads)
        )

        await model.refresh()
        let beforeCompletion = model.transcriptContentChange.typedRevision

        await model.refresh()

        #expect(model.visibleTurns == [completed])
        #expect(model.visibleTurns[0].state == .completed)
        #expect(
            model.transcriptContentChange.typedRevision == beforeCompletion
        )
    }

    @Test
    func displayedContentComparisonIgnoresNonDisplayedTurnState() throws {
        let startedAt = Date(timeIntervalSince1970: 0)
        let current = Turn(
            id: TurnID(
                rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            ),
            conversationID: ConversationID(
                rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            ),
            sequence: 1,
            inputMode: .text,
            userText: "",
            assistantText: "",
            state: .accepted,
            generation: 1,
            errorCode: nil,
            errorMessage: nil,
            startedAt: startedAt,
            terminalAt: nil
        )
        var completed = current
        try completed.apply(.completed(at: startedAt))

        #expect(
            !TranscriptDisplayedContent.typedChanged(
                from: [current],
                to: [completed]
            )
        )

        let live = LiveTranscriptTurn(
            id: 4,
            role: .user,
            text: "",
            isComplete: false
        )
        let completedLive = LiveTranscriptTurn(
            id: 4,
            role: .user,
            text: "",
            isComplete: true
        )
        #expect(
            !TranscriptDisplayedContent.liveChanged(
                from: [live],
                to: [completedLive]
            )
        )
    }

    @Test
    func transcriptRevisionIgnoresUnchangedInputAndTracksTypedAndLiveDeltas() {
        var revision = TranscriptContentRevision()
        let unchanged = revision

        revision.advance()
        #expect(revision == unchanged)

        revision.advance(typedContentChanged: true)
        #expect(revision.typed == unchanged.typed + 1)
        #expect(revision.live == unchanged.live)

        revision.advance(liveContentChanged: true)
        #expect(revision.typed == unchanged.typed + 1)
        #expect(revision.live == unchanged.live + 1)
    }

    @Test
    func transcriptRevisionTracksConversationResetAndReplacement() {
        var revision = TranscriptContentRevision()

        revision.advance(typedContentChanged: true)
        let beforeReplacement = revision
        revision.advance(typedContentChanged: true)

        #expect(revision.typed == beforeReplacement.typed + 1)
        #expect(revision.live == beforeReplacement.live)

        let beforeLiveReset = revision
        revision.advance(liveContentChanged: true)
        #expect(revision.live == beforeLiveReset.live + 1)
    }

    @Test
    func voiceStatusTokenChangesOnlyForDisplayedStatusChanges() {
        let available = TranscriptVoiceStatusToken(state: .available)
        #expect(available == TranscriptVoiceStatusToken(state: .available))

        #expect(
            available
                != TranscriptVoiceStatusToken(state: .connecting)
        )
        #expect(
            TranscriptVoiceStatusToken(
                state: .responding,
                reasoningStatus: .portableSkillsOmitted
            )
                != TranscriptVoiceStatusToken(state: .responding)
        )
        #expect(
            TranscriptVoiceStatusToken(
                state: .available,
                reasoningStatus: .portableSkillsOmitted
            ) == available
        )
        #expect(
            TranscriptVoiceStatusToken(
                state: .failed,
                failureCode: "voice_timeout"
            )
                != TranscriptVoiceStatusToken(state: .failed)
        )
        #expect(
            TranscriptVoiceStatusToken(
                state: .available,
                persistenceFailure: true
            ) != available
        )
    }

    @Test
    func contentChangeRetainsOnlyCompactRevisionsAndStatusToken() {
        let change = TranscriptContentChange(
            typedRevision: 3,
            liveRevision: 5,
            voiceStatus: TranscriptVoiceStatusToken(state: .listening)
        )

        #expect(change.typedRevision == 3)
        #expect(change.liveRevision == 5)
        #expect(change.voiceStatus.state == .listening)
    }

    @Test
    func transcriptIdentifiersAreNamespacedStableAndUniqueAcrossSurfaces() {
        let turnID = TurnID(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let conversation = [
            TranscriptAccessibilityIdentifier.typedUser(
                surface: .conversation,
                turnID: turnID
            ),
            TranscriptAccessibilityIdentifier.typedAssistantBlock(
                surface: .conversation,
                turnID: turnID,
                blockIndex: 0
            ),
            TranscriptAccessibilityIdentifier.live(
                surface: .conversation,
                turnID: 7
            ),
            TranscriptAccessibilityIdentifier.bottomAnchor(surface: .conversation),
            TranscriptAccessibilityIdentifier.jumpToLatest(surface: .conversation),
        ]
        let overlay = [
            TranscriptAccessibilityIdentifier.typedUser(
                surface: .overlay,
                turnID: turnID
            ),
            TranscriptAccessibilityIdentifier.typedAssistantBlock(
                surface: .overlay,
                turnID: turnID,
                blockIndex: 0
            ),
            TranscriptAccessibilityIdentifier.live(
                surface: .overlay,
                turnID: 7
            ),
            TranscriptAccessibilityIdentifier.bottomAnchor(surface: .overlay),
            TranscriptAccessibilityIdentifier.jumpToLatest(surface: .overlay),
        ]

        #expect(Set(conversation).count == conversation.count)
        #expect(Set(overlay).count == overlay.count)
        let combinedCount = Set(conversation + overlay).count
        let expectedCombinedCount = conversation.count + overlay.count
        #expect(combinedCount == expectedCombinedCount)
        #expect(
            TranscriptAccessibilityIdentifier.typedUser(
                surface: .conversation,
                turnID: turnID
            ) == TranscriptAccessibilityIdentifier.typedUser(
                surface: .conversation,
                turnID: turnID
            )
        )
        #expect(
            TranscriptAccessibilityIdentifier.typedUser(
                surface: .conversation,
                turnID: turnID
            ) != TranscriptAccessibilityIdentifier.typedUser(
                surface: .overlay,
                turnID: turnID
            )
        )
        #expect(conversation.allSatisfy { !$0.contains(" ") })
        #expect(overlay.allSatisfy { !$0.contains(" ") })
    }

    @Test
    func liveAccessibilityMetadataSeparatesRoleFromTranscriptElement() {
        let user = TranscriptAccessibilityMetadata.live(
            surface: .conversation,
            turnID: 2,
            role: .user
        )
        let assistant = TranscriptAccessibilityMetadata.live(
            surface: .conversation,
            turnID: 3,
            role: .assistant
        )

        #expect(user.roleLabel == "Live voice user transcript")
        #expect(assistant.roleLabel == "Live voice assistant transcript")
        #expect(
            user.transcriptElementIdentifier
                == TranscriptAccessibilityIdentifier.live(
                    surface: .conversation,
                    turnID: 2
                )
        )
        #expect(
            assistant.transcriptElementIdentifier
                != user.transcriptElementIdentifier
        )
    }

    private func transcriptTestDependencies(
        loads: TurnLoadSequence? = nil
    ) -> HostDependencies {
        let loads = loads ?? TurnLoadSequence(values: [[]])
        return HostDependencies(
            submit: { _, _ in TurnID() },
            stop: {},
            loadTurn: { _ in nil },
            loadConversations: { [] },
            loadTurns: { _ in await loads.next() },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }
}

private actor TurnLoadSequence {
    private var values: [[Turn]]

    init(values: [[Turn]]) {
        self.values = values
    }

    func next() -> [Turn] {
        values.removeFirst()
    }
}

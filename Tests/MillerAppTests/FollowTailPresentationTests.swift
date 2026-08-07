import Foundation
import Testing
@testable import MillerApp

@Suite
struct FollowTailPresentationTests {
    @Test
    func sharedSurfaceOwnsTheScrollObservationContract() throws {
        let source = try source(named: "FollowTailScrollView.swift")

        #expect(source.contains("ScrollViewReader"))
        #expect(source.contains("onScrollGeometryChange"))
        #expect(source.contains("onScrollPhaseChange"))
        #expect(source.contains(".id(Self.bottomAnchorID)"))
        #expect(source.contains("accessibilityReduceMotion"))
    }

    @Test
    func bothTranscriptSurfacesUseTheSharedFollowTailView() throws {
        let conversation = try source(named: "ConversationView.swift")
        let overlay = try source(named: "OverlayView.swift")

        #expect(conversation.contains("FollowTailScrollView("))
        #expect(overlay.contains("FollowTailScrollView("))
    }

    @Test
    func jumpToLatestHasAStableAccessibleContract() throws {
        let source = try source(named: "FollowTailScrollView.swift")

        #expect(source.contains(".accessibilityLabel(\"Jump to latest\")"))
        #expect(source.contains(
            ".accessibilityIdentifier(\"miller.transcript.jump-to-latest\")"
        ))
    }

    @Test
    func selectionSuspensionActionFlowsThroughEveryTranscriptRenderer() throws {
        let followTail = try source(named: "FollowTailScrollView.swift")
        let conversation = try source(named: "ConversationView.swift")
        let surface = try source(named: "SelectableTranscriptSurface.swift")

        #expect(followTail.contains("@MainActor"))
        #expect(followTail.contains("selectionBegan"))
        #expect(followTail.contains("followState.transcriptSelectionBegan()"))
        #expect(conversation.contains("selectionBegan in"))
        #expect(conversation.contains("TranscriptTurnView("))
        #expect(conversation.contains("selectionBegan: selectionBegan"))
        #expect(conversation.contains(
            "source: turn.assistantText,\n                    selectionBegan: selectionBegan"
        ))
        #expect(conversation.contains("LiveTranscriptTurnView("))
        #expect(surface.contains("DragGesture(minimumDistance: 0)"))
    }

    @Test
    func fullConversationFollowTailChangesWithTypedLiveAndVoiceContent() throws {
        let conversation = try source(named: "ConversationView.swift")

        #expect(conversation.contains("ConversationTranscriptContentChange"))
        #expect(conversation.contains("typedTurns: model.visibleTurns"))
        #expect(conversation.contains("liveTurns: model.liveTranscriptTurns"))
        #expect(conversation.contains("voiceStatus: model.voiceStatusText"))
    }

    private func source(named name: String) throws -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = tests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repository
                .appendingPathComponent("Sources/MillerApp/Presentation")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}

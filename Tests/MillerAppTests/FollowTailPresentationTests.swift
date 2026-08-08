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
        #expect(source.contains(".id(bottomAnchorID)"))
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
        #expect(source.contains("TranscriptAccessibilityIdentifier.jumpToLatest"))
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
    func bothFollowTailSurfacesUseCompactTranscriptContentChange() throws {
        let conversation = try source(named: "ConversationView.swift")
        let overlay = try source(named: "OverlayView.swift")

        #expect(conversation.contains("contentChange: model.transcriptContentChange"))
        #expect(overlay.contains("contentChange: model.transcriptContentChange"))
        #expect(!conversation.contains("typedTurns: model.visibleTurns"))
        #expect(!conversation.contains("liveTurns: model.liveTranscriptTurns"))
        #expect(!overlay.contains("typedTurns: model.visibleTurns"))
        #expect(!overlay.contains("liveTurns: model.liveTranscriptTurns"))
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

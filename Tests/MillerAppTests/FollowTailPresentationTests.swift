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
    func followTailTrailingClosuresEndBeforeCapabilityActivity() throws {
        for surfaceName in ["ConversationView.swift", "OverlayView.swift"] {
            let surface = try source(named: surfaceName)
            let followTailEnd = trailingClosureEnd(in: surface)
            let activityStart = surface.range(
                of: "CapabilityActivityView(rows: model.capabilityActivityRows)"
            )?.lowerBound

            #expect(followTailEnd != nil)
            #expect(activityStart != nil)
            if let followTailEnd, let activityStart {
                #expect(followTailEnd < activityStart)
            }
        }
    }

    @Test
    func capabilityActivityIsBoundedOutsideBothTranscriptSurfaces() throws {
        let conversation = try source(named: "ConversationView.swift")
        let overlay = try source(named: "OverlayView.swift")
        let activity = try source(named: "CapabilityActivityView.swift")

        #expect(conversation.contains("FollowTailScrollView("))
        #expect(overlay.contains("FollowTailScrollView("))
        #expect(conversation.contains("CapabilityActivityView(rows: model.capabilityActivityRows)"))
        #expect(overlay.contains("CapabilityActivityView(rows: model.capabilityActivityRows)"))
        #expect(activity.contains("ScrollView(.vertical)"))
        #expect(activity.contains(".frame(maxHeight:"))
        #expect(!activity.contains("FollowTailScrollView("))
        #expect(!activity.contains("SelectableTranscriptSurface"))
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
        #expect(surface.contains("mouseDown(with event"))
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

    private func trailingClosureEnd(in source: String) -> String.Index? {
        guard let callStart = source.range(of: "FollowTailScrollView(")?.lowerBound else {
            return nil
        }

        var parentheses = 0
        var callClosed = false
        var index = callStart
        while index < source.endIndex {
            switch source[index] {
            case "(": parentheses += 1
            case ")":
                parentheses -= 1
                callClosed = parentheses == 0
            case "{" where callClosed && parentheses == 0:
                return balancedBraceEnd(in: source, startingAt: index)
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func balancedBraceEnd(
        in source: String,
        startingAt openingBrace: String.Index
    ) -> String.Index? {
        var braces = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": braces += 1
            case "}": braces -= 1
            default: break
            }
            if braces == 0 {
                return source.index(after: index)
            }
            index = source.index(after: index)
        }
        return nil
    }
}

import Foundation
import Testing
@testable import MillerApp

@Suite
struct TranscriptSelectionPresentationTests {
    @Test
    func sharedSurfaceUsesNativeSelectionAndNonConsumingPointerObservation() {
        let surface = source(named: "SelectableTranscriptSurface.swift")

        #expect(surface.contains("struct SelectableTranscriptSurface"))
        #expect(surface.contains(".textSelection(.enabled)"))
        #expect(surface.contains(".simultaneousGesture"))
        #expect(surface.contains("DragGesture(minimumDistance: 0)"))
        #expect(surface.contains("selectionBegan()"))
        #expect(!surface.contains("NSPasteboard"))
        #expect(!surface.contains("generalPasteboard"))
        #expect(!surface.contains("ScrollView"))
        #expect(!surface.contains("firstResponder"))
    }

    @Test
    func allEightTranscriptSurfacesUseSharedStablePresentation() {
        let conversation = source(named: "ConversationView.swift")
        let overlay = source(named: "OverlayView.swift")
        let shared = source(named: "SelectableTranscriptSurface.swift")

        #expect(conversation.contains("TranscriptTurnView("))
        #expect(overlay.contains("TranscriptTurnView("))
        #expect(conversation.contains("LiveTranscriptTurnView("))
        #expect(overlay.contains("LiveTranscriptTurnView("))
        #expect(conversation.contains("selectionBegan: selectionBegan"))
        #expect(overlay.contains("selectionBegan: selectionBegan"))
        #expect(conversation.contains("ForEach(model.visibleTurns, id: \\.id)"))
        #expect(overlay.contains("ForEach(model.visibleTurns, id: \\.id)"))
        #expect(conversation.contains("ForEach(model.liveTranscriptTurns, id: \\.id)"))
        #expect(overlay.contains("ForEach(model.liveTranscriptTurns, id: \\.id)"))
        #expect(conversation.contains("miller.transcript.typed.user.\\(turn.id)"))
        #expect(conversation.contains("miller.transcript.typed.assistant.\\(turn.id)"))
        #expect(shared.contains("miller.transcript.live.\\(turn.id)"))
        #expect(shared.contains("Live voice user transcript"))
        #expect(shared.contains("Live voice assistant transcript"))
    }

    @Test
    func transcriptSelectionDoesNotExpandIntoCapabilityProviderOrCredentialInternals() {
        let sources = [
            source(named: "CapabilityActivityView.swift"),
            source(named: "Settings/ToolsIntegrationsSettingsTab.swift"),
            source(named: "Settings/ProvidersSettingsTab.swift"),
            source(named: "../Security/KeychainCredentialStore.swift"),
        ]

        #expect(sources.allSatisfy { !$0.contains("SelectableTranscriptSurface") })
    }

    private func source(named name: String) -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = tests.deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repository
                .appendingPathComponent("Sources/MillerApp/Presentation")
                .appendingPathComponent(name),
            encoding: .utf8
        )) ?? ""
    }
}

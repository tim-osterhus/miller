import Foundation
import SwiftUI
import Testing
@testable import MillerApp

@MainActor
private protocol MainActorSelectionCallbackProviding {
    var selectionBegan: @MainActor () -> Void { get }
}

extension SelectableTranscriptSurface: MainActorSelectionCallbackProviding {}

@Suite
struct TranscriptSelectionPresentationTests {
    @Test
    @MainActor
    func selectableSurfaceForwardsMainActorSelectionCallback() {
        var callbackCount = 0
        let surface = SelectableTranscriptSurface(
            accessibilityIdentifier: "miller.test.transcript",
            selectionBegan: {
                callbackCount += 1
            }
        ) {
            Text("Transcript")
        }

        let contract: any MainActorSelectionCallbackProviding = surface
        contract.selectionBegan()

        #expect(callbackCount == 1)
    }

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
        #expect(conversation.contains("TranscriptAccessibilityIdentifier.typedUser"))
        #expect(conversation.contains("typedAssistantBlock("))
        #expect(shared.contains("TranscriptAccessibilityMetadata.live"))
    }

    @Test
    func liveTranscriptKeepsRoleAndTextAsSeparateAccessibilityElements() {
        let conversation = source(named: "ConversationView.swift")
        let shared = source(named: "SelectableTranscriptSurface.swift")

        #expect(shared.contains("Text(speaker)"))
        #expect(shared.contains(".accessibilityLabel(metadata.roleLabel)"))
        #expect(shared.contains("Text(turn.text)"))
        #expect(!shared.contains(".accessibilityLabel(accessibilityLabel)"))
        #expect(!conversation.contains(".accessibilityElement(children: .combine)"))
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

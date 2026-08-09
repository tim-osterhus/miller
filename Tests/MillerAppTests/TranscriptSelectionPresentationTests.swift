import Foundation
import AppKit
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
            text: "Transcript",
            accessibilityIdentifier: "miller.test.transcript",
            selectionBegan: {
                callbackCount += 1
            }
        )

        let contract: any MainActorSelectionCallbackProviding = surface
        contract.selectionBegan()

        #expect(callbackCount == 1)
    }

    @Test
    @MainActor
    func nativeTranscriptResponderCopiesOnlyTheActiveMessageSelection() {
        let textView = TranscriptNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: "first line\nsecond line")
        )
        textView.setSelectedRange(NSRange(location: 11, length: 11))

        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            if let previousItems {
                pasteboard.writeObjects(previousItems)
            }
        }

        #expect(
            textView.tryToPerform(
                #selector(NSText.copy(_:)),
                with: nil
            )
        )
        #expect(pasteboard.string(forType: .string) == "second line")
        #expect(textView.selectedRange == NSRange(location: 11, length: 11))
    }

    @Test
    @MainActor
    func oneMarkdownMessageKeepsRenderedBlocksInOnePlainTextAndLinkDomain() {
        let rendered = AssistantMarkdown.transcriptAttributedString(
            "# Heading\n\nfirst line\nsecond line\n\n[linked](https://example.com)"
        )

        #expect(rendered.string == "Heading\n\nfirst line\nsecond line\n\nlinked")
        let linkLocation = (rendered.string as NSString).range(of: "linked").location
        #expect(linkLocation != NSNotFound)
        #expect(rendered.attribute(.link, at: linkLocation, effectiveRange: nil) != nil)
    }

    @Test
    @MainActor
    func codeBlockKeepsMonospacedClippedParagraphMetadataForHorizontalScrolling() {
        let rendered = AssistantMarkdown.transcriptAttributedString(
            "```swift\nlet value = 1\n```"
        )
        let codeLocation = (rendered.string as NSString).range(of: "let value").location
        let font = rendered.attribute(.font, at: codeLocation, effectiveRange: nil)
            as? NSFont
        let paragraph = rendered.attribute(
            .paragraphStyle,
            at: codeLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle

        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(paragraph?.lineBreakMode == .byClipping)
    }

    @Test
    @MainActor
    func nativeSurfaceMeasuresSoftWrappedAndExplicitLineContent() {
        let surface = SelectableTranscriptSurface(
            text: "A deliberately long soft-wrapped line that continues\nnext line",
            accessibilityIdentifier: "miller.test.transcript",
            selectionBegan: {}
        )
        let hostingView = NSHostingView(rootView: surface)
        hostingView.frame = NSRect(x: 0, y: 0, width: 90, height: 120)
        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize.height > 22)
    }

    @Test
    @MainActor
    func codeBlockPreservesLiteralMarkdownCharactersAsPlainText() {
        let rendered = AssistantMarkdown.transcriptAttributedString(
            "```swift\nlet value = `raw`\n```"
        )

        #expect(rendered.string == "swift\nlet value = `raw`")
    }

    @Test
    @MainActor
    func nativeCodeSurfaceProvidesHorizontalScrollingForLongLines() {
        let source = "```swift\n" + String(repeating: "let value = 1; ", count: 40) + "\n```"
        let surface = SelectableTranscriptSurface(
            attributedText: AssistantMarkdown.transcriptAttributedString(source),
            accessibilityIdentifier: "miller.test.code",
            selectionBegan: {}
        )
        let hostingView = NSHostingView(rootView: surface)
        hostingView.frame = NSRect(x: 0, y: 0, width: 180, height: 120)
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = descendants(of: hostingView).compactMap {
            $0 as? TranscriptScrollView
        }.first

        #expect(scrollView?.hasHorizontalScroller == true)
        #expect(
            (scrollView?.documentView?.frame.width ?? 0)
                > (scrollView?.contentView.bounds.width ?? 0)
        )
    }

    @Test
    func sharedSurfaceUsesNativeSelectionAndNonConsumingPointerObservation() {
        let surface = source(named: "SelectableTranscriptSurface.swift")

        #expect(surface.contains("struct SelectableTranscriptSurface"))
        #expect(surface.contains("NativeTranscriptTextView"))
        #expect(surface.contains("selectionBegan"))
        #expect(!surface.contains(".textSelection(.enabled)"))
        #expect(!surface.contains("DragGesture(minimumDistance: 0)"))
        #expect(!surface.contains("NSPasteboard"))
        #expect(!surface.contains("generalPasteboard"))
        #expect(!surface.contains("firstResponder"))
    }

    @Test
    func perMessageSurfaceUsesAppKitResponderOwnedSelection() {
        let surface = source(named: "SelectableTranscriptSurface.swift")

        #expect(surface.contains("import AppKit"))
        #expect(surface.contains("NSViewRepresentable"))
        #expect(surface.contains("NSTextView"))
        #expect(surface.contains("isSelectable = true"))
        #expect(surface.contains("isEditable = false"))
        #expect(surface.contains("mouseDown(with event"))
        #expect(surface.contains("setAccessibilityIdentifier"))
        #expect(!surface.contains("NSPasteboard"))
        #expect(!surface.contains("generalPasteboard"))
    }

    @Test
    func assistantMarkdownUsesOneSelectionDomainPerVisibleMessage() {
        let conversation = source(named: "ConversationView.swift")

        #expect(conversation.contains("AssistantMarkdown.transcriptAttributedString"))
        #expect(conversation.contains(
            "attributedText: AssistantMarkdown.transcriptAttributedString(source)"
        ))
        #expect(!conversation.contains("private func blockView("))
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
        #expect(shared.contains("text: turn.text"))
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

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}

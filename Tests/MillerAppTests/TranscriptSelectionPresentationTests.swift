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
    func plainTypedAndLiveTranscriptTextUsesDynamicSystemTextColor() {
        for (text, identifier) in [
            ("Typed user message", "miller.test.typed-user"),
            ("Live transcript", "miller.test.live"),
        ] {
            let surface = SelectableTranscriptSurface(
                text: text,
                accessibilityIdentifier: identifier,
                selectionBegan: {}
            )
            let fullRange = NSRange(location: 0, length: surface.attributedText.length)
            var effectiveRange = NSRange()
            let color = surface.attributedText.attribute(
                .foregroundColor,
                at: 0,
                longestEffectiveRange: &effectiveRange,
                in: fullRange
            ) as? NSColor

            #expect(color == NSColor.textColor)
            #expect(effectiveRange == fullRange)
        }
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
        let previousItems = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type: type, data: $0) }
            }
        }
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            if let previousItems {
                let restoredItems = previousItems.map { contents in
                    let item = NSPasteboardItem()
                    for content in contents {
                        item.setData(content.data, forType: content.type)
                    }
                    return item
                }
                pasteboard.writeObjects(restoredItems)
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
    func oneMarkdownMessageKeepsInlineEmphasisInTheNativeSurface() {
        let rendered = AssistantMarkdown.transcriptAttributedString(
            "**Bold** and *italic* and `inline code`"
        )
        let boldLocation = (rendered.string as NSString).range(of: "Bold").location
        let boldFont = rendered.attribute(
            .font,
            at: boldLocation,
            effectiveRange: nil
        ) as? NSFont
        let italicLocation = (rendered.string as NSString).range(of: "italic").location
        let italicFont = rendered.attribute(
            .font,
            at: italicLocation,
            effectiveRange: nil
        ) as? NSFont
        let codeLocation = (rendered.string as NSString).range(of: "inline code").location
        let codeFont = rendered.attribute(
            .font,
            at: codeLocation,
            effectiveRange: nil
        ) as? NSFont

        #expect(
            boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true
        )
        #expect(
            italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true
        )
        #expect(
            codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
        )
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
    func codeBlockKeepsPriorBackgroundAndPaddingPresentation() {
        let rendered = AssistantMarkdown.transcriptAttributedString(
            "```swift\nlet value = 1\n```"
        )
        let codeLocation = (rendered.string as NSString).range(of: "let value").location
        let paragraph = rendered.attribute(
            .paragraphStyle,
            at: codeLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let codeBlock = paragraph?.textBlocks.first

        #expect(codeBlock?.backgroundColor != nil)
        #expect(
            codeBlock?.width(for: .padding, edge: .minX) == 8
        )
        #expect(
            codeBlock?.width(for: .padding, edge: .maxX) == 8
        )
        #expect(
            codeBlock?.width(for: .padding, edge: .minY) == 8
        )
        #expect(
            codeBlock?.width(for: .padding, edge: .maxY) == 8
        )
    }

    @Test
    @MainActor
    func multilineCodeKeepsLinesContiguousInsideThePaddedBlock() {
        let rendered = AssistantMarkdown.transcriptAttributedString(
            "```swift\nfirst line\nsecond line\n```"
        )
        let firstLocation = (rendered.string as NSString).range(of: "first line").location
        let secondLocation = (rendered.string as NSString).range(of: "second line").location
        let firstParagraph = rendered.attribute(
            .paragraphStyle,
            at: firstLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let secondParagraph = rendered.attribute(
            .paragraphStyle,
            at: secondLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle

        #expect(firstParagraph?.paragraphSpacingBefore == 0)
        #expect(firstParagraph?.paragraphSpacing == 0)
        #expect(secondParagraph?.paragraphSpacing == 6)
    }

    @Test
    @MainActor
    func codeBlockPreservesTrailingBlankLines() {
        let rendered = AssistantMarkdown.transcriptAttributedString(
            "```swift\nfirst line\n\n```"
        )

        #expect(rendered.string == "swift\nfirst line\n")
    }

    @Test
    @MainActor
    func markdownBlocksKeepPriorParagraphSpacing() {
        let rendered = AssistantMarkdown.transcriptAttributedString(
            "# Heading\n- First\n> Quoted\nsecond paragraph"
        )

        for text in ["Heading", "•", "│", "second paragraph"] {
            let location = (rendered.string as NSString).range(of: text).location
            let paragraph = rendered.attribute(
                .paragraphStyle,
                at: location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect(paragraph?.paragraphSpacing == 6)
        }

        let headingLocation = (rendered.string as NSString).range(of: "Heading").location
        let headingParagraph = rendered.attribute(
            .paragraphStyle,
            at: headingLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(headingParagraph?.paragraphSpacingBefore == 4)
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
            "let rendered = AssistantMarkdown.transcriptAttributedString(source)"
        ))
        #expect(conversation.contains("attributedText: rendered"))
        #expect(!conversation.contains("private func blockView("))
    }

    @Test
    func assistantMarkdownUsesOneTruthfulMessageAccessibilityElement() {
        let conversation = source(named: "ConversationView.swift")
        let metadata = source(named: "TranscriptPresentationMetadata.swift")

        #expect(conversation.contains(
            "TranscriptAccessibilityMetadata.typedAssistant"
        ))
        #expect(conversation.contains(
            "accessibilityLabel: metadata.transcriptElementLabel"
        ))
        #expect(!conversation.contains("typedAssistantBlock("))
        #expect(!conversation.contains("blockIndex: 0"))
        #expect(metadata.contains("static func typedAssistant("))
        #expect(!metadata.contains("typedAssistantBlock("))
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
        #expect(conversation.contains(
            "TranscriptAccessibilityMetadata.typedAssistant"
        ))
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

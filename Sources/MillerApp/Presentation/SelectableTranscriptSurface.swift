import AppKit
import SwiftUI

typealias TranscriptSelectionAction = @MainActor () -> Void

enum TranscriptTextAttribute {
    static let codeBlock = NSAttributedString.Key(
        "miller.transcript.code-block"
    )
}

struct SelectableTranscriptSurface: View {
    let accessibilityIdentifier: String
    let accessibilityLabel: String?
    let attributedText: NSAttributedString
    let selectionBegan: TranscriptSelectionAction

    init(
        text: String,
        accessibilityIdentifier: String,
        accessibilityLabel: String? = nil,
        selectionBegan: @escaping TranscriptSelectionAction
    ) {
        self.init(
            attributedText: NSAttributedString(string: text),
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityLabel: accessibilityLabel,
            selectionBegan: selectionBegan
        )
    }

    init(
        attributedText: NSAttributedString,
        accessibilityIdentifier: String,
        accessibilityLabel: String? = nil,
        selectionBegan: @escaping TranscriptSelectionAction
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.attributedText = attributedText
        self.selectionBegan = selectionBegan
    }

    var body: some View {
        NativeTranscriptTextView(
            attributedText: attributedText,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityLabel: accessibilityLabel,
            selectionBegan: selectionBegan
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct NativeTranscriptTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let accessibilityIdentifier: String
    let accessibilityLabel: String?
    let selectionBegan: TranscriptSelectionAction

    func makeNSView(context: Context) -> TranscriptScrollView {
        let textView = TranscriptNSTextView()
        configure(textView)

        let scrollView = TranscriptScrollView(documentView: textView)
        update(scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(
        _ scrollView: TranscriptScrollView,
        context: Context
    ) {
        guard let textView = scrollView.documentView as? TranscriptNSTextView
        else {
            return
        }
        configure(textView)
        update(scrollView, textView: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: TranscriptScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = nsView.documentView as? TranscriptNSTextView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else {
            return nil
        }

        let width = proposal.width ?? 320
        let documentWidth = max(width, codeContentWidth(in: attributedText))
        textView.frame.size.width = documentWidth
        textContainer.containerSize = NSSize(
            width: documentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textContainer.widthTracksTextView = true
        textView.layoutDelegate.wrappingWidth = width
        layoutManager.ensureLayout(for: textContainer)

        let height = layoutManager.usedRect(for: textContainer).height
            + textView.textContainerInset.height * 2
        textView.frame.size.height = max(22, ceil(height))
        return CGSize(width: width, height: max(22, ceil(height)))
    }

    private func configure(_ textView: TranscriptNSTextView) {
        textView.selectionBegan = selectionBegan
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.layoutManager?.delegate = textView.layoutDelegate
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
    }

    private func codeContentWidth(in text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        var width = 0.0
        text.enumerateAttribute(
            TranscriptTextAttribute.codeBlock,
            in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            guard value != nil else { return }
            let font = text.attribute(
                .font,
                at: range.location,
                effectiveRange: nil
            ) as? NSFont ?? NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
            for line in text.attributedSubstring(from: range).string.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ) {
                width = max(
                    width,
                    (String(line) as NSString)
                        .size(withAttributes: [.font: font])
                        .width
                )
            }
        }
        return ceil(width + 8)
    }

    private func update(
        _ scrollView: TranscriptScrollView,
        textView: TranscriptNSTextView
    ) {
        let selectedRanges = textView.selectedRanges.map(\.rangeValue)
        textView.textStorage?.setAttributedString(attributedText)
        textView.selectedRanges = selectedRanges.compactMap { range in
            guard range.location <= attributedText.length else { return nil }
            let length = min(range.length, attributedText.length - range.location)
            return NSValue(range: NSRange(location: range.location, length: length))
        }
        scrollView.invalidateIntrinsicContentSize()
    }
}

@MainActor
final class TranscriptNSTextView: NSTextView {
    var selectionBegan: TranscriptSelectionAction = {}
    let layoutDelegate = TranscriptTextLayoutDelegate()

    override func mouseDown(with event: NSEvent) {
        selectionBegan()
        super.mouseDown(with: event)
    }
}

final class TranscriptTextLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    var wrappingWidth = 320.0

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        guard characterRange.location != NSNotFound,
              characterRange.location < (layoutManager.textStorage?.length ?? 0)
        else {
            return true
        }
        let value = layoutManager.textStorage?.attribute(
            TranscriptTextAttribute.codeBlock,
            at: characterRange.location,
            effectiveRange: nil
        )
        guard value == nil else { return true }

        lineFragmentRect.pointee.size.width = wrappingWidth
        lineFragmentUsedRect.pointee.size.width = min(
            lineFragmentUsedRect.pointee.width,
            wrappingWidth
        )
        return true
    }
}

@MainActor
final class TranscriptScrollView: NSScrollView {
    init(documentView: NSView) {
        super.init(frame: .zero)
        self.documentView = documentView
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }
}

struct LiveTranscriptTurnView: View {
    let turn: LiveTranscriptTurn
    let surface: TranscriptSurfaceNamespace
    let selectionBegan: TranscriptSelectionAction

    var body: some View {
        let metadata = TranscriptAccessibilityMetadata.live(
            surface: surface,
            turnID: turn.id,
            role: turn.role
        )
        VStack(alignment: .leading, spacing: 5) {
            Text(speaker)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(metadata.roleLabel)
            SelectableTranscriptSurface(
                text: turn.text,
                accessibilityIdentifier: metadata.transcriptElementIdentifier,
                selectionBegan: selectionBegan
            )
        }
    }

    private var speaker: String {
        turn.role == .user ? "You" : "Miller"
    }

}

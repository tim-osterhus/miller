import AppKit
import SwiftUI
import MillerCore

enum AssistantMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unorderedItem(String)
        case orderedItem(marker: String, text: String)
        case quote(String)
        case code(language: String?, text: String)
        case spacer
    }

    static func attributedString(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }

    static func transcriptAttributedString(_ source: String) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        for (index, block) in blocks(source).enumerated() {
            if index > 0 {
                rendered.append(NSAttributedString(string: "\n"))
            }
            rendered.append(transcriptBlock(block))
        }
        return rendered
    }

    static func blocks(_ source: String) -> [Block] {
        let lines = source.split(
            separator: "\n",
            maxSplits: .max,
            omittingEmptySubsequences: false
        ).map(String.init)
        var result: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3))
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                result.append(.code(
                    language: language.isEmpty ? nil : language,
                    text: codeLines.joined(separator: "\n")
                ))
            } else if line.isEmpty {
                result.append(.spacer)
            } else if let heading = heading(line) {
                result.append(heading)
            } else if ["- ", "* ", "+ "].contains(where: line.hasPrefix) {
                result.append(.unorderedItem(String(line.dropFirst(2))))
            } else if let ordered = orderedItem(line) {
                result.append(ordered)
            } else if line.hasPrefix("> ") {
                result.append(.quote(String(line.dropFirst(2))))
            } else {
                result.append(.paragraph(line))
            }
            index += 1
        }
        return result
    }

    private static func heading(_ line: String) -> Block? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level),
              line.dropFirst(level).hasPrefix(" ")
        else {
            return nil
        }
        return .heading(
            level: level,
            text: String(line.dropFirst(level + 1))
        )
    }

    private static func orderedItem(_ line: String) -> Block? {
        guard let separator = line.firstIndex(of: " ") else {
            return nil
        }
        let marker = String(line[..<separator])
        let digits = marker.dropLast()
        guard (marker.hasSuffix(".") || marker.hasSuffix(")")),
              !digits.isEmpty,
              digits.allSatisfy(\.isNumber)
        else {
            return nil
        }
        return .orderedItem(
            marker: marker,
            text: String(line[line.index(after: separator)...])
        )
    }

    private static func transcriptBlock(_ block: Block) -> NSAttributedString {
        switch block {
        case let .heading(level, text):
            return inlineTranscriptText(
                text,
                font: .systemFont(
                    ofSize: level == 1 ? 22 : level == 2 ? 17 : 14,
                    weight: .semibold
                ),
                paragraphStyle: headingParagraphStyle(level: level)
            )
        case let .paragraph(text):
            return inlineTranscriptText(text)
        case let .unorderedItem(text):
            let paragraphStyle = listParagraphStyle()
            let rendered = NSMutableAttributedString(
                string: "• ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraphStyle,
                ]
            )
            rendered.append(
                inlineTranscriptText(text, paragraphStyle: paragraphStyle)
            )
            return rendered
        case let .orderedItem(marker, text):
            let paragraphStyle = listParagraphStyle()
            let rendered = NSMutableAttributedString(
                string: "\(marker) ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraphStyle,
                ]
            )
            rendered.append(
                inlineTranscriptText(text, paragraphStyle: paragraphStyle)
            )
            return rendered
        case let .quote(text):
            let paragraphStyle = quoteParagraphStyle()
            let rendered = NSMutableAttributedString(
                string: "│ ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraphStyle,
                ]
            )
            rendered.append(
                inlineTranscriptText(
                    text,
                    color: NSColor.secondaryLabelColor,
                    paragraphStyle: paragraphStyle
                )
            )
            return rendered
        case let .code(language, text):
            let codeBlock = TranscriptCodeTextBlock()
            let rendered = NSMutableAttributedString()
            if let language {
                rendered.append(
                    inlineTranscriptText(
                        language,
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                        color: NSColor.secondaryLabelColor,
                        paragraphStyle: codeParagraphStyle(
                            block: codeBlock,
                            paragraphSpacing: 4
                        ),
                        preserveMarkdown: false
                    )
                )
                rendered.append(NSAttributedString(string: "\n"))
            }
            let code = inlineTranscriptText(
                text,
                font: NSFont.monospacedSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                ),
                paragraphStyle: codeParagraphStyle(block: codeBlock),
                preserveMarkdown: false
            )
            let codeRange = NSRange(location: rendered.length, length: code.length)
            rendered.append(code)
            if code.length > 0 {
                let lastLineStart = (code.string as NSString).range(
                    of: "\n",
                    options: .backwards
                ).location
                let finalLineStart = lastLineStart == NSNotFound
                    ? 0
                    : lastLineStart + 1
                let finalLineLength = code.length - finalLineStart
                if finalLineLength > 0 {
                    let finalRange = NSRange(
                        location: codeRange.location + finalLineStart,
                        length: finalLineLength
                    )
                    rendered.addAttribute(
                        .paragraphStyle,
                        value: codeParagraphStyle(
                            block: codeBlock,
                            paragraphSpacing: 6
                        ),
                        range: finalRange
                    )
                }
            }
            rendered.addAttribute(
                TranscriptTextAttribute.codeBlock,
                value: true,
                range: codeRange
            )
            return rendered
        case .spacer:
            return NSAttributedString()
        }
    }

    private static func inlineTranscriptText(
        _ text: String,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        color: NSColor = .textColor,
        paragraphStyle: NSParagraphStyle = paragraphStyle(),
        preserveMarkdown: Bool = true
    ) -> NSAttributedString {
        let rendered: NSAttributedString
        if preserveMarkdown {
            rendered = NSAttributedString(
                AssistantMarkdown.attributedString(text)
            )
        } else {
            rendered = NSAttributedString(string: text)
        }
        let mutable = NSMutableAttributedString(attributedString: rendered)
        guard mutable.length > 0 else { return mutable }
        mutable.addAttributes(
            [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ],
            range: NSRange(location: 0, length: mutable.length)
        )
        let inlinePresentationIntent = NSAttributedString.Key(
            "NSInlinePresentationIntent"
        )
        mutable.enumerateAttribute(
            inlinePresentationIntent,
            in: NSRange(location: 0, length: mutable.length)
        ) { value, range, _ in
            let rawValue = (value as? NSNumber)?.intValue ?? 0
            guard rawValue != 0 else { return }
            let inlineFont: NSFont
            if rawValue & 4 != 0 {
                inlineFont = NSFont.monospacedSystemFont(
                    ofSize: font.pointSize,
                    weight: .regular
                )
            } else if rawValue & 2 != 0 {
                inlineFont = NSFontManager.shared.convert(
                    font,
                    toHaveTrait: .boldFontMask
                )
            } else if rawValue & 1 != 0 {
                inlineFont = NSFontManager.shared.convert(
                    font,
                    toHaveTrait: .italicFontMask
                )
            } else {
                return
            }
            mutable.addAttribute(.font, value: inlineFont, range: range)
        }
        return mutable
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacing = 6
        return style
    }

    private static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let style = paragraphStyle().mutableCopy() as! NSMutableParagraphStyle
        if level == 1 {
            style.paragraphSpacingBefore = 4
        }
        return style
    }

    private static func listParagraphStyle() -> NSParagraphStyle {
        let style = paragraphStyle().mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = 8
        style.headIndent = 8
        return style
    }

    private static func quoteParagraphStyle() -> NSParagraphStyle {
        let style = paragraphStyle().mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = 4
        style.headIndent = 4
        return style
    }

    private static func codeParagraphStyle(
        block: NSTextBlock,
        paragraphSpacing: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.paragraphSpacing = paragraphSpacing
        style.textBlocks = [block]
        return style
    }
}

struct AssistantMarkdownView: View {
    let source: String
    let selectionBegan: TranscriptSelectionAction
    let surface: TranscriptSurfaceNamespace
    let turnID: TurnID

    var body: some View {
        let rendered = AssistantMarkdown.transcriptAttributedString(source)
        let metadata = TranscriptAccessibilityMetadata.typedAssistant(
            surface: surface,
            turnID: turnID,
            visibleText: rendered.string
        )
        SelectableTranscriptSurface(
            attributedText: rendered,
            accessibilityIdentifier: metadata.transcriptElementIdentifier,
            accessibilityLabel: metadata.transcriptElementLabel,
            selectionBegan: selectionBegan
        )
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppPresentationModel
    @State private var confirmDelete = false
    @State private var showVoiceHistory = false

    var body: some View {
        HSplitView {
            ConversationListView(model: model)
                .frame(minWidth: 220, idealWidth: 260)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.statusText)
                        .accessibilityLabel(AccessibilityLabel.status)
                    Spacer()
                    Button(AccessibilityLabel.newConversation) {
                        model.newConversation()
                    }
                    .disabled(!model.menuState.canCreateConversation)
                    Button("Voice History") {
                        showVoiceHistory = true
                    }
                }

                FollowTailScrollView(
                    surface: .conversation,
                    conversationIdentity: model.selectedConversationID,
                    contentChange: model.transcriptContentChange
                ) { selectionBegan in
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.visibleTurns, id: \.id) { turn in
                            TranscriptTurnView(
                                turn: turn,
                                surface: .conversation,
                                selectionBegan: selectionBegan
                            )
                        }
                        if model.voiceState != .unavailable {
                            Divider()
                            LabeledContent("Live voice") {
                                Text(model.voiceStatusText)
                            }
                            ForEach(model.liveTranscriptTurns, id: \.id) { turn in
                                LiveTranscriptTurnView(
                                    turn: turn,
                                    surface: .conversation,
                                    selectionBegan: selectionBegan
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CapabilityActivityView(rows: model.capabilityActivityRows)

                if let approval = model.pendingCapabilityApproval {
                    CapabilityApprovalView(presentation: approval) {
                        model.resolveCapabilityApproval($0)
                    }
                }

                if let attachment = model.pendingVoiceHistoryAttachment {
                    HStack(spacing: 8) {
                        Label(
                            voiceHistoryAttachmentLabel(attachment),
                            systemImage: "waveform.badge.plus"
                        )
                        .font(.caption)
                        Spacer()
                        Button("Remove") {
                            model.cancelVoiceHistoryAttachment()
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                HStack {
                    TextField(AccessibilityLabel.input, text: $model.draft)
                        .onSubmit { Task { await model.submit() } }
                        .accessibilityIdentifier(AccessibilityIdentifier.conversationInput)
                    if model.isActiveTurn {
                        Button(AccessibilityLabel.stop) {
                            Task { await model.stop() }
                        }
                        .accessibilityIdentifier(AccessibilityIdentifier.conversationStop)
                    } else {
                        Button(AccessibilityLabel.send) {
                            Task { await model.submit() }
                        }
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier(AccessibilityIdentifier.conversationSend)
                    }
                }

                HStack {
                    Button("Archive") {
                        Task { await model.archiveSelected() }
                    }
                    .disabled(model.isActiveTurn || model.visibleTurns.isEmpty)
                    Button("Unarchive") {
                        Task { await model.unarchiveSelected() }
                    }
                    .disabled(model.isActiveTurn || model.visibleTurns.isEmpty)
                    Button("Delete", role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(model.isActiveTurn || model.visibleTurns.isEmpty)
                }
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 500)
        .alert("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelected() }
            }
        } message: {
            Text("This removes the conversation from Miller's database.")
        }
        .sheet(isPresented: $showVoiceHistory) {
            VoiceHistoryView(model: model)
        }
        .task { await model.refresh() }
    }

    private func voiceHistoryAttachmentLabel(
        _ attachment: PreparedVoiceHistoryAttachment
    ) -> String {
        let count = attachment.sessionIDs.count
        let noun = count == 1 ? "session" : "sessions"
        let truncation = attachment.truncated ? " (truncated)" : ""
        return "\(count) voice \(noun) attached\(truncation)"
    }
}

struct TranscriptTurnView: View {
    let turn: Turn
    let surface: TranscriptSurfaceNamespace
    let selectionBegan: TranscriptSelectionAction

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("You")
                .font(.caption)
                .foregroundStyle(.secondary)
            SelectableTranscriptSurface(
                text: turn.userText,
                accessibilityIdentifier: TranscriptAccessibilityIdentifier.typedUser(
                    surface: surface,
                    turnID: turn.id
                ),
                selectionBegan: selectionBegan
            )
            if !turn.assistantText.isEmpty {
                Text("Miller")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AssistantMarkdownView(
                    source: turn.assistantText,
                    selectionBegan: selectionBegan,
                    surface: surface,
                    turnID: turn.id
                )
            }
            if let error = turn.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }
}

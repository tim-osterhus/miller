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
}

struct AssistantMarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(
                Array(AssistantMarkdown.blocks(source).enumerated()),
                id: \.offset
            ) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMarkdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(AssistantMarkdown.attributedString(text))
                .font(level == 1 ? .title2 : level == 2 ? .headline : .body)
                .fontWeight(.semibold)
                .padding(.top, level == 1 ? 4 : 0)
        case let .paragraph(text):
            Text(AssistantMarkdown.attributedString(text))
        case let .unorderedItem(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(AssistantMarkdown.attributedString(text))
            }
            .padding(.leading, 8)
        case let .orderedItem(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                Text(AssistantMarkdown.attributedString(text))
            }
            .padding(.leading, 8)
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 3)
                Text(AssistantMarkdown.attributedString(text))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .spacer:
            Color.clear.frame(height: 2)
        }
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppPresentationModel
    @State private var confirmDelete = false

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
                }

                FollowTailScrollView(
                    conversationIdentity: model.selectedConversationID,
                    contentChange: model.visibleTurns
                ) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.visibleTurns, id: \.id) { turn in
                            TranscriptTurnView(turn: turn)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .task { await model.refresh() }
    }
}

struct TranscriptTurnView: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("You")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(turn.userText)
                .textSelection(.enabled)
            if !turn.assistantText.isEmpty {
                Text("Miller")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AssistantMarkdownView(source: turn.assistantText)
                    .textSelection(.enabled)
            }
            if let error = turn.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI

struct SelectableTranscriptSurface<Content: View>: View {
    let accessibilityIdentifier: String
    let selectionBegan: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .textSelection(.enabled)
            .accessibilityIdentifier(accessibilityIdentifier)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        selectionBegan()
                    }
            )
    }
}

struct LiveTranscriptTurnView: View {
    let turn: LiveTranscriptTurn
    let selectionBegan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(speaker)
                .font(.caption)
                .foregroundStyle(.secondary)
            SelectableTranscriptSurface(
                accessibilityIdentifier: "miller.transcript.live.\(turn.id)",
                selectionBegan: selectionBegan
            ) {
                Text(turn.text)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var speaker: String {
        turn.role == .user ? "You" : "Miller"
    }

    private var accessibilityLabel: String {
        turn.role == .user
            ? "Live voice user transcript"
            : "Live voice assistant transcript"
    }
}

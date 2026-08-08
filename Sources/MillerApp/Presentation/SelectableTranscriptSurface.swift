import SwiftUI

typealias TranscriptSelectionAction = @MainActor () -> Void

struct SelectableTranscriptSurface<Content: View>: View {
    let accessibilityIdentifier: String
    let selectionBegan: TranscriptSelectionAction
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
                accessibilityIdentifier: metadata.transcriptElementIdentifier,
                selectionBegan: selectionBegan
            ) {
                Text(turn.text)
            }
        }
    }

    private var speaker: String {
        turn.role == .user ? "You" : "Miller"
    }

}

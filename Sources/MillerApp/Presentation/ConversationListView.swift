import SwiftUI
import MillerCore

struct ConversationListView: View {
    @ObservedObject var model: AppPresentationModel

    var body: some View {
        List(model.conversations) { item in
            Button {
                Task { await model.selectConversation(item.id) }
            } label: {
                VStack(alignment: .leading) {
                    Text(item.title)
                        .lineLimit(2)
                    Text(item.state == .active ? "Active" : "Archived")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("miller.conversation.\(item.id.description)")
        }
        .accessibilityLabel(AccessibilityLabel.conversationList)
    }
}

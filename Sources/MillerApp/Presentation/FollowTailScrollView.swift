import SwiftUI

@MainActor
struct FollowTailScrollView<
    ConversationIdentity: Equatable,
    ContentChange: Equatable,
    Content: View
>: View {
    static var bottomAnchorID: String { "miller.transcript.bottom" }

    let conversationIdentity: ConversationIdentity
    let contentChange: ContentChange
    @ViewBuilder let content: (_ selectionBegan: @escaping () -> Void) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followState = FollowTailState()
    @State private var distanceFromBottom = 0.0
    @State private var isUserScrolling = false

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    content {
                        followState.transcriptSelectionBegan()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .onScrollGeometryChange(for: Double.self) { geometry in
                    max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                } action: { _, newDistance in
                    distanceFromBottom = newDistance
                    guard isUserScrolling else { return }
                    followState.userScrolled(distanceFromBottom: newDistance)
                }
                .onScrollPhaseChange { oldPhase, newPhase in
                    let wasUserScrolling = Self.isUserScrollPhase(oldPhase)
                    isUserScrolling = Self.isUserScrollPhase(newPhase)
                    if isUserScrolling || (wasUserScrolling && newPhase == .idle) {
                        followState.userScrolled(
                            distanceFromBottom: distanceFromBottom
                        )
                    }
                }
                .onChange(of: contentChange) { _, _ in
                    guard followState.shouldFollowContentChange() else { return }
                    scrollToLatest(proxy)
                }
                .onChange(of: conversationIdentity) { _, _ in
                    followState.conversationReplaced()
                    scrollToLatest(proxy)
                }
                .onAppear {
                    scrollToLatest(proxy)
                }

                if !followState.isFollowing {
                    Button("Jump to latest") {
                        followState.jumpToLatest()
                        scrollToLatest(proxy)
                    }
                    .accessibilityLabel("Jump to latest")
                    .accessibilityIdentifier("miller.transcript.jump-to-latest")
                    .padding(12)
                }
            }
        }
    }

    private static func isUserScrollPhase(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .decelerating
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if followState.shouldAnimateScroll(reduceMotion: reduceMotion) {
            withAnimation {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }
}

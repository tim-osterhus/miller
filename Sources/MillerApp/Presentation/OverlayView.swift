import SwiftUI
import MillerCore

struct OverlayView: View {
    @ObservedObject var model: AppPresentationModel
    let dismiss: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Miller")
                    .font(.headline)
                Spacer()
                Text(model.statusText)
                    .accessibilityLabel(AccessibilityLabel.status)
            }

            FollowTailScrollView(
                conversationIdentity: model.selectedConversationID,
                contentChange: OverlayTranscriptContentChange(
                    typedTurns: model.visibleTurns,
                    liveTurns: model.liveTranscriptTurns,
                    voiceStatus: model.voiceStatusText
                )
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.visibleTurns, id: \.id) { turn in
                        TranscriptTurnView(turn: turn)
                    }
                    if model.voiceState != .unavailable {
                        Divider()
                        LabeledContent("Live voice") {
                            Text(model.voiceStatusText)
                        }
                        ForEach(model.liveTranscriptTurns) { turn in
                            LiveTranscriptTurnView(turn: turn)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField(AccessibilityLabel.input, text: $model.draft)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .accessibilityIdentifier(AccessibilityIdentifier.input)
                .onSubmit { Task { await model.submit() } }

            HStack {
                Button(AccessibilityLabel.newConversation) {
                    model.newConversation()
                }
                .disabled(!model.menuState.canCreateConversation)
                .accessibilityIdentifier(AccessibilityIdentifier.newConversation)

                Spacer()

                Button("Open Conversation") {
                    NotificationCenter.default.post(
                        name: .millerOpenConversationWindow,
                        object: nil
                    )
                }
                .accessibilityLabel(AccessibilityLabel.openConversation)

                Button("Settings") {
                    NotificationCenter.default.post(
                        name: .millerOpenSettings,
                        object: nil
                    )
                }
                .accessibilityLabel(AccessibilityLabel.settings)

                if model.isActiveTurn {
                    Button(AccessibilityLabel.stop) {
                        Task { await model.stop() }
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier(AccessibilityIdentifier.stop)
                } else {
                    Button(AccessibilityLabel.send) {
                        Task { await model.submit() }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier(AccessibilityIdentifier.send)
                }
            }

            if model.voiceState != .unavailable {
                HStack {
                    if model.voiceState.isActive {
                        Button(model.liveVoiceMuted ? "Unmute" : "Mute") {
                            Task { await model.toggleLiveMute() }
                        }
                        .accessibilityLabel(
                            model.liveVoiceMuted
                                ? AccessibilityLabel.unmuteLiveVoice
                                : AccessibilityLabel.muteLiveVoice
                        )
                        Button("Interrupt") {
                            Task { await model.interruptLiveVoice() }
                        }
                        .accessibilityLabel(AccessibilityLabel.interruptLiveVoice)
                        Button("End Live Voice") {
                            Task { await model.endLiveVoice() }
                        }
                        .accessibilityLabel(AccessibilityLabel.endLiveVoice)
                    } else {
                        Button("Start Live Voice") {
                            Task { await model.startLiveVoice() }
                        }
                        .disabled(!model.canStartLiveVoice)
                        .accessibilityLabel(AccessibilityLabel.startLiveVoice)
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 480, minHeight: 320)
        .onExitCommand(perform: dismiss)
        .onAppear { inputFocused = true }
        .onChange(of: model.focusRequest) { _, _ in
            inputFocused = true
        }
    }
}

private struct OverlayTranscriptContentChange: Equatable {
    let typedTurns: [Turn]
    let liveTurns: [LiveTranscriptTurn]
    let voiceStatus: String
}

private struct LiveTranscriptTurnView: View {
    let turn: LiveTranscriptTurn

    var body: some View {
        Text("\(speaker): \(turn.text)")
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

extension Notification.Name {
    static let millerOpenConversationWindow = Notification.Name(
        "ai.millrace.miller.open-conversation-window"
    )
    static let millerOpenSettings = Notification.Name(
        "ai.millrace.miller.open-settings"
    )
}

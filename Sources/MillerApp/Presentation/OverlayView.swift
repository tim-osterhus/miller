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
                surface: .overlay,
                conversationIdentity: model.selectedConversationID,
                contentChange: model.transcriptContentChange
            ) { selectionBegan in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.visibleTurns, id: \.id) { turn in
                        TranscriptTurnView(
                            turn: turn,
                            surface: .overlay,
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
                                surface: .overlay,
                                selectionBegan: selectionBegan
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CapabilityActivityView(rows: model.capabilityActivityRows)

            if let message = model.liveCapabilityConfirmationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(message)
            }

            if let approval = model.pendingCapabilityApproval {
                CapabilityApprovalView(presentation: approval) {
                    model.resolveCapabilityApproval($0)
                }
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
        .onExitCommand {
            handleExitCommand()
        }
        .onAppear { inputFocused = true }
        .onChange(of: model.focusRequest) { _, _ in
            inputFocused = true
        }
    }

    func handleExitCommand() {
        model.declineCapabilityApprovalForDismissal()
        dismiss()
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

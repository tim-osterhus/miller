import AppKit
import SwiftUI
import MillerStorage

struct VoiceHistoryView: View {
    @ObservedObject var model: AppPresentationModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var useDateRange = false
    @State private var rangeStart = Calendar.current.date(
        byAdding: .day,
        value: -30,
        to: Date()
    ) ?? Date()
    @State private var rangeEnd = Date()
    @State private var pendingDeletion: PendingDeletion?

    private enum PendingDeletion: Equatable {
        case session(UUID)
        case range
        case all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Live Voice History")
                    .font(.title2)
                Spacer()
                Button("Done") { dismiss() }
            }

            Toggle("Select by date range", isOn: $useDateRange)
            if useDateRange {
                HStack {
                    DatePicker("From", selection: $rangeStart)
                    DatePicker("Through", selection: $rangeEnd)
                }
            } else if model.voiceHistorySessions.isEmpty {
                ContentUnavailableView(
                    "No Saved Voice History",
                    systemImage: "waveform"
                )
            } else {
                List(model.voiceHistorySessions, id: \.id) { session in
                    HStack {
                        Toggle(
                            isOn: selectionBinding(for: session.id)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.startedAt, format: .dateTime)
                                Text(sessionLabel(session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Delete", role: .destructive) {
                            pendingDeletion = .session(session.id)
                        }
                    }
                }
            }

            if let status = model.voiceHistoryStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Ask Miller about these conversations") {
                    Task {
                        if useDateRange {
                            await model.prepareVoiceHistoryAttachment(
                                from: rangeStart,
                                through: rangeEnd
                            )
                        } else {
                            await model.prepareVoiceHistoryAttachment(
                                sessionIDs: Array(selectedSessionIDs)
                            )
                        }
                        if model.pendingVoiceHistoryAttachment != nil {
                            dismiss()
                        }
                    }
                }
                .disabled(!hasSelection)

                Button("Export") { exportSelection() }
                    .disabled(!hasSelection)

                Spacer()

                if useDateRange {
                    Button("Delete Range", role: .destructive) {
                        pendingDeletion = .range
                    }
                }
                Button("Delete All", role: .destructive) {
                    pendingDeletion = .all
                }
            }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 480)
        .task { await model.refreshVoiceHistory() }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                performDeletion()
            }
        } message: {
            Text("This permanently removes the selected transcript text from Miller's database.")
        }
    }

    private var hasSelection: Bool {
        useDateRange ? rangeStart <= rangeEnd : !selectedSessionIDs.isEmpty
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .session: "Delete this voice session?"
        case .range: "Delete voice history in this date range?"
        case .all: "Delete all voice history?"
        case nil: "Delete voice history?"
        }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedSessionIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedSessionIDs.insert(id)
                } else {
                    selectedSessionIDs.remove(id)
                }
            }
        )
    }

    private func sessionLabel(_ session: VoiceHistorySession) -> String {
        let source = session.activationSource == .wakeword ? "Wake phrase" : "Manual"
        let outcome = session.terminalOutcome?.rawValue.capitalized ?? "In progress"
        return "\(source) · \(outcome)"
    }

    private func exportSelection() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "miller-voice-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if useDateRange {
                await model.exportVoiceHistory(
                    from: rangeStart,
                    through: rangeEnd,
                    to: url
                )
            } else {
                await model.exportVoiceHistory(
                    sessionIDs: Array(selectedSessionIDs),
                    to: url
                )
            }
        }
    }

    private func performDeletion() {
        let deletion = pendingDeletion
        pendingDeletion = nil
        Task {
            switch deletion {
            case let .session(id):
                selectedSessionIDs.remove(id)
                await model.deleteVoiceHistorySession(id)
            case .range:
                await model.deleteVoiceHistory(from: rangeStart, through: rangeEnd)
                selectedSessionIDs.formIntersection(
                    Set(model.voiceHistorySessions.map(\.id))
                )
            case .all:
                selectedSessionIDs.removeAll()
                await model.deleteAllVoiceHistory()
            case nil:
                break
            }
        }
    }
}

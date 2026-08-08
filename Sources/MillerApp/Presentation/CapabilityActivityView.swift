import SwiftUI

struct CapabilityActivityPresentationState: Equatable {
    static let retainedRowLimit = 8
    static let visibleRowLimit = 3
    static let autoCollapseDelay = Duration.seconds(15)

    private(set) var isExpanded = false

    mutating func receivedNewActivity() {
        isExpanded = true
    }

    mutating func toggle() {
        isExpanded.toggle()
    }

    mutating func inactivityElapsed() {
        isExpanded = false
    }
}

struct CapabilityActivityView: View {
    let rows: [CapabilityActivityRow]

    @State private var presentationState = CapabilityActivityPresentationState()

    var retainedRows: ArraySlice<CapabilityActivityRow> {
        rows.suffix(CapabilityActivityPresentationState.retainedRowLimit)
    }

    var maximumExpandedHeight: CGFloat {
        CGFloat(CapabilityActivityPresentationState.visibleRowLimit * 32)
    }

    var body: some View {
        if retainedRows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Capability activity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(actionSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(actionSummary)
                    }

                    Spacer(minLength: 8)

                    Button(
                        presentationState.isExpanded
                            ? "Hide capability activity"
                            : "Show capability activity"
                    ) {
                        presentationState.toggle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        presentationState.isExpanded
                            ? "Hide capability activity"
                            : "Show capability activity"
                    )
                }

                if presentationState.isExpanded {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(retainedRows) { row in
                                Text(row.displayText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: maximumExpandedHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: rows.last?.id) {
                guard !Task.isCancelled else { return }

                presentationState.receivedNewActivity()
                do {
                    try await Task.sleep(for: CapabilityActivityPresentationState.autoCollapseDelay)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                presentationState.inactivityElapsed()
            }
        }
    }

    private var actionSummary: String {
        let count = retainedRows.count
        return "\(count) recent action\(count == 1 ? "" : "s")"
    }
}

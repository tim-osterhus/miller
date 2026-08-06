import SwiftUI

struct CapabilityActivityView: View {
    let rows: [CapabilityActivityRow]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capability activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(rows.suffix(8)) { row in
                    Text(row.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

import SwiftUI

struct VoiceSettingsTab: View {
    let section = SettingsSection.voice
    @ObservedObject var model: AppPresentationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                GroupBox("Live Voice") {
                    LabeledContent("Readiness") {
                        Text(model.voiceStatusText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
    }
}

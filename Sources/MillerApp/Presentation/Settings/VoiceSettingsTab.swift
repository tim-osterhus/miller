import SwiftUI
import MillerWake

struct VoiceSettingsTab: View {
    let section = SettingsSection.voice
    @ObservedObject var model: AppPresentationModel
    @ObservedObject var wakeSettings: WakeWordSettingsController
    @State private var phraseDraft = ""

    init(
        model: AppPresentationModel,
        wakeSettings: WakeWordSettingsController = .init(
            enable: { .disabled },
            disable: { .disabled }
        )
    ) {
        self.model = model
        self.wakeSettings = wakeSettings
    }

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
                GroupBox("Wake Listening") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Enable wake listening",
                            isOn: Binding(
                                get: { wakeSettings.isEnabled },
                                set: { wakeSettings.setEnabled($0) }
                            )
                        )
                        .disabled(wakeSettings.isWorking)

                        HStack {
                            TextField("Wake phrase", text: $phraseDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Save phrase") {
                                wakeSettings.updatePhrase(phraseDraft)
                            }
                            .disabled(
                                wakeSettings.isWorking
                                    || phraseDraft == wakeSettings.phrase
                            )
                        }

                        LabeledContent("Status") {
                            Text(wakeSettings.statusText)
                        }
                        if let guidance = permissionGuidance {
                            Text(guidance)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let errorMessage = wakeSettings.errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        if isRetryAvailable {
                            Button("Retry") {
                                wakeSettings.retry()
                            }
                            .disabled(wakeSettings.isWorking)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
        .onAppear { phraseDraft = wakeSettings.phrase }
        .onChange(of: wakeSettings.phrase) { _, phrase in
            phraseDraft = phrase
        }
    }

    private var isRetryAvailable: Bool {
        if case .unavailable = wakeSettings.state { return true }
        return false
    }

    private var permissionGuidance: String? {
        guard case .unavailable(let reason) = wakeSettings.state else {
            return nil
        }
        switch reason {
        case .microphonePermission:
            return "Allow Miller to use the system microphone in System Settings, then retry."
        case .model, .detectorRuntime:
            return "Wake listening requires the verified local wake model."
        case .inputDevice:
            return "The system-default microphone is unavailable. Connect it and retry."
        case .assistantMode:
            return "Select a reasoning provider before enabling wake listening."
        case .capture:
            return "Wake capture stopped. Check microphone access and retry."
        }
    }
}

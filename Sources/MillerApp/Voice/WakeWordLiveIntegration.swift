import MillerWake
import MillerStorage

@MainActor
final class WakeWordLiveIntegration {
    weak var model: AppPresentationModel?
    weak var production: WakeWordProductionController?
    var openMiller: @MainActor @Sendable () -> Void = {}
    private(set) var liveSessionActive = false

    func wakeDetected() {
        openMiller()
    }

    func commandAudio(_ audio: WakeWordPreparedCommandAudio) async {
        liveSessionActive = true
        guard let model else {
            liveSessionActive = false
            await production?.resumeAfterLiveCleanup()
            return
        }
        await model.startLiveVoice(
            activationSource: .wakeword,
            preparedAudio: audio
        )
    }

    func prepareLiveStart(_ source: VoiceActivationSource) async {
        guard source == .manual else { return }
        liveSessionActive = true
        await production?.suspend(.foregroundSession)
    }

    func liveVoiceFinished() async {
        guard liveSessionActive else { return }
        liveSessionActive = false
        await production?.resumeAfterLiveCleanup()
    }
}

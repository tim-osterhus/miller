import MillerWake
import MillerStorage

@MainActor
final class WakeWordLiveIntegration {
    weak var model: AppPresentationModel?
    weak var production: WakeWordProductionController?
    var openMiller: @MainActor @Sendable () -> Void = {}
    private(set) var liveSessionActive = false

    func wakeDetected() async {
        openMiller()
        liveSessionActive = true
        guard let model else {
            liveSessionActive = false
            await production?.resumeAfterLiveCleanup()
            return
        }
        await model.startLiveVoice(activationSource: .wakeword)
    }

    func prepareLiveStart(_ source: VoiceActivationSource) async -> Bool {
        if source == .wakeword {
            return liveSessionActive
        }
        guard let production else { return false }
        let stateBeforeSuspension = production.state
        await production.suspend(.foregroundSession)
        guard stateBeforeSuspension != production.state,
              production.state == .suspended(.foregroundSession) else {
            return false
        }
        liveSessionActive = true
        return true
    }

    func liveVoiceFinished() async {
        guard liveSessionActive else { return }
        liveSessionActive = false
        await production?.resumeAfterLiveCleanup()
    }
}

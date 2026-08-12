import MillerWake
import MillerStorage

@MainActor
final class WakeWordLiveIntegration {
    weak var model: AppPresentationModel?
    weak var production: WakeWordProductionController?
    var openMiller: @MainActor @Sendable () -> Void = {}
    private(set) var liveSessionActive = false
    private var wakeAdmission: WakeWordAdmission?

    func wakeDetected() async {
        await startWakeSession(admission: nil)
    }

    func wakeDetected(_ admission: WakeWordAdmission) async {
        await startWakeSession(admission: admission)
    }

    private func startWakeSession(admission: WakeWordAdmission?) async {
        wakeAdmission = admission
        openMiller()
        liveSessionActive = true
        guard let model else {
            liveSessionActive = false
            await completeWakeAdmission()
            return
        }
        await model.startLiveVoice(activationSource: .wakeword)
    }

    func prepareLiveStart(_ source: VoiceActivationSource) async -> Bool {
        if source == .wakeword {
            return liveSessionActive && (wakeAdmission?.isValid ?? true)
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

    func validateLiveStart(_ source: VoiceActivationSource) async -> Bool {
        guard source == .wakeword else { return true }
        return liveSessionActive && (wakeAdmission?.isValid ?? true)
    }

    func liveVoiceFinished() async {
        guard liveSessionActive else { return }
        liveSessionActive = false
        await completeWakeAdmission()
    }

    private func completeWakeAdmission() async {
        if let wakeAdmission {
            self.wakeAdmission = nil
            await wakeAdmission.complete()
        } else {
            await production?.resumeAfterLiveCleanup()
        }
    }
}

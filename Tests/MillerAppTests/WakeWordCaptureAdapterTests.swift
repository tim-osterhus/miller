import MillerLiveAudio
import Testing
@testable import MillerApp

@Suite("Wakeword capture adapter")
struct WakeWordCaptureAdapterTests {
    @Test @MainActor
    func deniedPermissionDoesNotAcquireOrStartWakeCapture() async {
        let ownership = MicrophoneOwnership()
        let adapter = WakeWordAVAudioCaptureAdapter(
            ownership: ownership,
            permissionStatus: { .denied },
            requestPermission: { .denied }
        )

        await #expect(throws: WakeWordCaptureError.permissionDenied) {
            try await adapter.startWakeMonitoring()
        }
        #expect(adapter.isWakeMonitoring == false)
        let lease = try? ownership.acquire(.wake)
        #expect(lease != nil)
        lease?.release()
    }
}

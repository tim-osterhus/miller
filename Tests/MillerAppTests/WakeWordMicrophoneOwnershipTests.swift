import Testing
@testable import MillerApp

@Suite("Wakeword microphone ownership")
struct WakeWordMicrophoneOwnershipTests {
    @Test
    func wakeAndLiveCannotHoldTheMicrophoneAtTheSameTime() throws {
        let ownership = MicrophoneOwnership()
        let wake = try ownership.acquire(.wake)

        #expect(throws: MicrophoneOwnershipError.busy) {
            try ownership.acquire(.live)
        }

        wake.release()
        let live = try ownership.acquire(.live)
        #expect(throws: MicrophoneOwnershipError.busy) {
            try ownership.acquire(.wake)
        }
        live.release()
    }
}

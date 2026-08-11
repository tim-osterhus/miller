import AVFoundation
import Foundation
import MillerLiveAudio
import Testing
@testable import MillerApp

@Suite("Wakeword capture adapter")
struct WakeWordCaptureAdapterTests {
    @Test
    func realtimeCallbackHandsActorWorkToMainActor() async {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "MillerWakeTests.realtime").async {
                WakeWordRealtimeHandoff.deliver(42) { value in
                    MainActor.preconditionIsolated()
                    #expect(value == 42)
                    continuation.resume()
                }
            }
        }
    }

    @Test
    func audioTapCopiesBoundedSamplesBeforeTheMainActorHandoff() async throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 2
        ))
        buffer.frameLength = 2
        buffer.floatChannelData?[0][0] = 0.25
        buffer.floatChannelData?[0][1] = -0.5
        let sourceIdentity = ObjectIdentifier(buffer)
        #expect(WakeWordAudioBufferSnapshot(
            copying: buffer,
            maximumFrameCount: 1
        ) == nil)

        await withCheckedContinuation { continuation in
            let tap = WakeWordRealtimeAudioTap.make { snapshot in
                MainActor.preconditionIsolated()
                #expect(ObjectIdentifier(snapshot.buffer) != sourceIdentity)
                #expect(snapshot.buffer.frameLength == 2)
                #expect(snapshot.buffer.floatChannelData?[0][0] == 0.25)
                #expect(snapshot.buffer.floatChannelData?[0][1] == -0.5)
                continuation.resume()
            }
            let invocation = UncheckedSendableBox((tap, buffer))
            DispatchQueue(label: "MillerWakeTests.audio-tap").async {
                invocation.value.0(invocation.value.1, AVAudioTime())
            }
        }
    }

    @Test
    func adapterInstallsTheRealtimeHandoffTapFactory() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/MillerApp/Voice/WakeWordAVAudioCaptureAdapter.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("let tap = WakeWordRealtimeAudioTap.make"))
        #expect(source.contains("block: tap"))
    }

    @Test
    func lifecycleFenceRejectsInactiveAndStaleRealtimeBuffers() {
        let fence = WakeWordCaptureLifecycleFence()

        fence.prepare(generation: 1)
        #expect(!fence.accepts(generation: 1))
        fence.activate(generation: 1)
        #expect(fence.accepts(generation: 1))

        fence.prepare(generation: 2)
        #expect(!fence.accepts(generation: 1))
        #expect(!fence.accepts(generation: 2))
        fence.activate(generation: 2)
        #expect(fence.accepts(generation: 2))

        fence.invalidate()
        #expect(!fence.accepts(generation: 2))
    }

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

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
